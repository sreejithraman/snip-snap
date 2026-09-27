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

public actor SavedSnipsSession {
    private var library: any SnipLibrary
    private var userActions: any SnipLibraryUserActions
    private let userActionsRebinder: SnipLibraryUserActionsRebinder
    private var recoveryScope: SnipRecoveryScope?
    private var pendingImportPreview: SavedSnipsImportPreview?
    private var pendingDeletionToken: UUID?
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        library: any SnipLibrary,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsRebinder: SnipLibraryUserActionsRebinder = .direct,
        recoveryScope: SnipRecoveryScope? = nil
    ) {
        self.library = library
        self.userActionsRebinder = userActionsRebinder
        self.userActions = userActions ?? userActionsRebinder.actions(for: library)
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
            recovery: await recoveryState()
        )
    }

    public func replaceLibrary(
        _ library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope?,
        sortedBy sortMode: SnipSortMode
    ) async -> SavedSnipsSessionState {
        await discardPendingDeletion(sortedBy: sortMode)
        self.library = library
        userActions = userActionsRebinder.actions(for: library)
        self.recoveryScope = recoveryScope
        pendingImportPreview = nil
        return await state(sortedBy: sortMode)
    }

    public func archive() async throws -> SnipLibraryArchive {
        try await library.archive()
    }

    public func performLibraryCommand(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate {
        let update = try await library.perform(command, sortedBy: sortMode)
        await discardPendingDeletion(sortedBy: sortMode)
        return update
    }

    public func performUserCommand(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate {
        let update = try await userActions.perform(command: command, sortedBy: sortMode)
        pendingDeletionToken = nil
        return update
    }

    public func delete(
        ids: Set<UUID>,
        token: UUID,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate {
        let update = try await userActions.delete(ids: ids, token: token, sortedBy: sortMode)
        pendingDeletionToken = token
        return update
    }

    public func restoreDeletion(
        token: UUID,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate? {
        let update = try await userActions.restoreDeletion(token: token, sortedBy: sortMode)
        if update != nil { pendingDeletionToken = nil }
        return update
    }

    public func discardDeletion(token: UUID, sortedBy sortMode: SnipSortMode) async {
        await userActions.discardDeletion(token: token, sortedBy: sortMode)
        if pendingDeletionToken == token { pendingDeletionToken = nil }
    }

    public func refreshRecovery() async -> SnipRecoverySnapshot {
        await recoveryState()
    }

    public func resolveRecovery(
        _ id: UUID,
        choice: SnipRecoveryChoice,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SavedSnipsSessionState? {
        guard let recoveryScope else { return nil }
        _ = try await library.resolveRecovery(id, in: recoveryScope, choice: choice)
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
        return (result, await recoveryState())
    }

    private func recoveryState() async -> SnipRecoverySnapshot {
        guard let recoveryScope else { return .empty }
        return (try? await library.recoverySnapshot(in: recoveryScope)) ?? .empty
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
