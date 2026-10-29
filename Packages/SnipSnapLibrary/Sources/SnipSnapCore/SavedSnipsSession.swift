import Foundation

public struct SavedSnipsSessionState: Sendable {
    public let library: SnipLibrarySnapshot
    public let recovery: SnipRecoverySnapshot

    public init(library: SnipLibrarySnapshot, recovery: SnipRecoverySnapshot) {
        self.library = library
        self.recovery = recovery
    }
}

public struct SavedSnipsImportPreview: Sendable {
    public let id: UUID
    public let value: SnipImportPreview

    public init(id: UUID, value: SnipImportPreview) {
        self.id = id
        self.value = value
    }
}

public struct SavedSnipsDoneUndo: Equatable, Sendable {
    public let id: UUID
    public let count: Int

    public init(id: UUID, count: Int) {
        self.id = id
        self.count = count
    }
}

public struct SavedSnipsDoneChange: Sendable {
    public let update: SnipLibraryUpdate
    public let undo: SavedSnipsDoneUndo?
    public let didChange: Bool

    public init(update: SnipLibraryUpdate, undo: SavedSnipsDoneUndo?, didChange: Bool) {
        self.update = update
        self.undo = undo
        self.didChange = didChange
    }
}

public actor SavedSnipsSession {
    private struct PendingDoneUndo {
        let token: UUID
        let snips: [Snip]
    }

    private var library: any SnipLibrary
    private var userActions: any SnipLibraryUserActions
    private let userActionsFactory: SnipLibraryUserActionsFactory
    private var recoveryScope: SnipRecoveryScope?
    private var pendingImportPreview: SavedSnipsImportPreview?
    private var pendingDeletionToken: UUID?
    private var pendingDoneUndo: PendingDoneUndo?
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        library: any SnipLibrary,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsFactory: @escaping SnipLibraryUserActionsFactory = { DirectSnipLibraryUserActions(library: $0) },
        recoveryScope: SnipRecoveryScope? = nil
    ) {
        self.library = library
        self.userActionsFactory = userActionsFactory
        self.userActions = userActions ?? userActionsFactory(library)
        self.recoveryScope = recoveryScope
    }

    public func withExclusiveAccess<Result: Sendable>(
        _ operation: @MainActor @Sendable (SavedSnipsSession) async throws -> Result
    ) async rethrows -> Result {
        await acquire()
        do {
            let result = try await operation(self)
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    public func state(sortedBy sortMode: SnipSortMode) async -> SavedSnipsSessionState {
        SavedSnipsSessionState(
            library: await library.snapshot(sortedBy: sortMode),
            recovery: await refreshRecovery()
        )
    }

    public func replaceLibrary(
        _ library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope?,
        sortedBy sortMode: SnipSortMode
    ) async -> SavedSnipsSessionState {
        await discardPendingDeletion(sortedBy: sortMode)
        pendingDoneUndo = nil
        self.library = library
        userActions = userActionsFactory(library)
        self.recoveryScope = recoveryScope
        pendingImportPreview = nil
        return await state(sortedBy: sortMode)
    }

    public func archive() async throws -> SnipLibraryArchive {
        try await library.archive()
    }

    public func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot {
        try await library.checkedSnapshot(sortedBy: sortMode)
    }

    public func performLibraryCommand(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate {
        try await performLibraryCommandWithResult(command, sortedBy: sortMode).update
    }

    public func performLibraryCommandWithResult(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryCommandResult {
        let before = try await library.checkedSnapshot(sortedBy: sortMode)
        let update = try await library.perform(command, sortedBy: sortMode)
        let didChange = before != update.snapshot
        if didChange {
            pendingDoneUndo = nil
            await discardPendingDeletion(sortedBy: sortMode)
        }
        return SnipLibraryCommandResult(update: update, didChange: didChange)
    }

    public func performUserCommand(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate {
        try await performUserCommandWithResult(command, sortedBy: sortMode).update
    }

    public func performUserCommandWithResult(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryCommandResult {
        let result = try await userActions.performWithResult(command: command, sortedBy: sortMode)
        if result.didChange {
            pendingDeletionToken = nil
            pendingDoneUndo = nil
        }
        return result
    }

    public func setDone(
        ids: Set<UUID>,
        done: Bool,
        expectation: SnipLibraryExpectation? = nil,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SavedSnipsDoneChange {
        let before = try await library.checkedSnapshot(sortedBy: sortMode)
        let changing = before.snips.filter {
            ids.contains($0.id) && !$0.isPinned && $0.isDone != done
        }
        guard !changing.isEmpty else {
            let update: SnipLibraryUpdate
            if let expectation {
                update = try await library.perform(
                    .guarded(expectation: expectation, command: .batch([])),
                    sortedBy: sortMode
                )
            } else {
                update = SnipLibraryUpdate(snapshot: before, outcome: .none)
            }
            return SavedSnipsDoneChange(
                update: update,
                undo: nil,
                didChange: false
            )
        }
        let changedIDs = Set(changing.map(\.id))
        let guardedChange = SnipLibraryCommand.guarded(
            expectation: SnipLibraryExpectation(expectedSnips: changing),
            command: .setDone(ids: changedIDs, done: done)
        )
        let command = expectation.map {
            SnipLibraryCommand.guarded(expectation: $0, command: guardedChange)
        } ?? guardedChange
        let update = try await performUserCommand(
            command,
            sortedBy: sortMode
        )
        guard done else { return SavedSnipsDoneChange(update: update, undo: nil, didChange: true) }
        let newlyDone = update.snapshot.snips.filter { changedIDs.contains($0.id) && $0.isDone }
        let token = UUID()
        pendingDoneUndo = PendingDoneUndo(token: token, snips: newlyDone)
        return SavedSnipsDoneChange(
            update: update,
            undo: SavedSnipsDoneUndo(id: token, count: newlyDone.count),
            didChange: true
        )
    }

    public func restoreDone(
        token: UUID,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate? {
        guard let pendingDoneUndo, pendingDoneUndo.token == token else { return nil }
        let current = try await library.checkedSnapshot(sortedBy: sortMode)
        guard self.pendingDoneUndo?.token == token else { return nil }
        let currentByID = Dictionary(uniqueKeysWithValues: current.snips.map { ($0.id, $0) })
        let unchanged = pendingDoneUndo.snips.filter {
            $0.isDone && !$0.isPinned && currentByID[$0.id] == $0
        }
        guard !unchanged.isEmpty else {
            self.pendingDoneUndo = nil
            return nil
        }
        return try await performUserCommand(
            .guarded(
                expectation: SnipLibraryExpectation(expectedSnips: unchanged),
                command: .setDone(ids: Set(unchanged.map(\.id)), done: false)
            ),
            sortedBy: sortMode
        )
    }

    public func discardDone(token: UUID) {
        if pendingDoneUndo?.token == token { pendingDoneUndo = nil }
    }

    /// Reports retained token identity; the inverse still validates current records when performed.
    public func retainsUndo(token: UUID) -> Bool {
        pendingDoneUndo?.token == token || pendingDeletionToken == token
    }

    public func delete(
        ids: Set<UUID>,
        token: UUID,
        expectation: SnipLibraryExpectation? = nil,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate {
        try await deleteWithResult(
            ids: ids, token: token, expectation: expectation, sortedBy: sortMode
        ).update
    }

    public func deleteWithResult(
        ids: Set<UUID>,
        token: UUID,
        expectation: SnipLibraryExpectation? = nil,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryCommandResult {
        let result = try await userActions.deleteWithResult(
            ids: ids, token: token, expectation: expectation, sortedBy: sortMode
        )
        if result.didChange {
            pendingDeletionToken = token
            pendingDoneUndo = nil
        }
        return result
    }

    public func restoreDeletion(
        token: UUID,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate? {
        let update = try await userActions.restoreDeletion(token: token, sortedBy: sortMode)
        if update != nil {
            pendingDeletionToken = nil
            pendingDoneUndo = nil
        }
        return update
    }

    public func discardDeletion(token: UUID, sortedBy sortMode: SnipSortMode) async {
        await userActions.discardDeletion(token: token, sortedBy: sortMode)
        if pendingDeletionToken == token { pendingDeletionToken = nil }
    }

    public func refreshRecovery() async -> SnipRecoverySnapshot {
        (try? await checkedRecovery()) ?? .empty
    }

    public func checkedRecovery() async throws -> SnipRecoverySnapshot {
        guard let recoveryScope else { return .empty }
        return try await library.recoverySnapshot(in: recoveryScope)
    }

    public func resolveRecovery(
        _ id: UUID,
        choice: SnipRecoveryChoice,
        expectation: SnipRecoveryExpectation? = nil,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SavedSnipsSessionState? {
        guard let recoveryScope else { return nil }
        _ = try await library.resolveRecovery(id, in: recoveryScope, choice: choice,
                                              expectation: expectation)
        pendingDoneUndo = nil
        await discardPendingDeletion(sortedBy: sortMode)
        return await state(sortedBy: sortMode)
    }

    public func previewImport(from url: URL) async throws -> SavedSnipsImportPreview {
        pendingImportPreview = nil
        let preview = SavedSnipsImportPreview(
            id: UUID(),
            value: try await userActions.previewImport(backupURL: url)
        )
        pendingImportPreview = preview
        return preview
    }

    public func cancelImport(id: UUID) {
        guard pendingImportPreview?.id == id else { return }
        pendingImportPreview = nil
    }

    public func applyPendingImport(
        id: UUID,
        sortedBy sortMode: SnipSortMode
    ) async throws -> (SnipImportResult, SnipRecoverySnapshot)? {
        guard let preview = pendingImportPreview, preview.id == id else { return nil }
        pendingImportPreview = nil
        let result = try await userActions.applyImport(preview.value, sortedBy: sortMode)
        pendingDeletionToken = nil
        pendingDoneUndo = nil
        return (result, await refreshRecovery())
    }

    private func discardPendingDeletion(sortedBy sortMode: SnipSortMode) async {
        guard let token = pendingDeletionToken else { return }
        pendingDeletionToken = nil
        await userActions.discardDeletion(token: token, sortedBy: sortMode)
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}
