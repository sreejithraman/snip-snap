import Foundation

public struct SavedSnipsSessionState: Sendable {
    public let library: SnipLibrarySnapshot
    public let recovery: SnipRecoverySnapshot

    public init(library: SnipLibrarySnapshot, recovery: SnipRecoverySnapshot) {
        self.library = library
        self.recovery = recovery
    }
}

public struct SavedSnipsImportPreview: Equatable, Sendable {
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
    fileprivate struct PendingDoneUndo {
        let token: UUID
        let snips: [Snip]
    }

    fileprivate enum ImportPreviewPhase {
        case none
        case previewing(UUID)
        case pending(SavedSnipsImportPreview)
    }

    private enum ExclusiveAccess {
        case available
        case held(waiters: [CheckedContinuation<Void, Never>])
    }

    fileprivate final class Binding: @unchecked Sendable {
        let library: any SnipLibrary
        let userActions: any SnipLibraryUserActions
        let recoveryScope: SnipRecoveryScope?
        var importPreview: ImportPreviewPhase = .none
        var pendingDeletionToken: UUID?
        var pendingDoneUndo: PendingDoneUndo?

        init(library: any SnipLibrary, userActions: any SnipLibraryUserActions, recoveryScope: SnipRecoveryScope?) {
            self.library = library
            self.userActions = userActions
            self.recoveryScope = recoveryScope
        }
    }

    fileprivate final class BindingOwner: @unchecked Sendable {
        let lock = NSLock()
        var current: Binding
        init(_ current: Binding) { self.current = current }
    }

    private let binding: BindingOwner
    private var library: any SnipLibrary { binding.lock.withLock { binding.current.library } }
    private var userActions: any SnipLibraryUserActions { binding.lock.withLock { binding.current.userActions } }
    private var recoveryScope: SnipRecoveryScope? { binding.lock.withLock { binding.current.recoveryScope } }
    private var importPreview: ImportPreviewPhase {
        get { binding.lock.withLock { binding.current.importPreview } }
        set { binding.lock.withLock { binding.current.importPreview = newValue } }
    }
    private var pendingDeletionToken: UUID? {
        get { binding.lock.withLock { binding.current.pendingDeletionToken } }
        set { binding.lock.withLock { binding.current.pendingDeletionToken = newValue } }
    }
    private var pendingDoneUndo: PendingDoneUndo? {
        get { binding.lock.withLock { binding.current.pendingDoneUndo } }
        set { binding.lock.withLock { binding.current.pendingDoneUndo = newValue } }
    }
    private let userActionsFactory: SnipLibraryUserActionsFactory
    private var exclusiveAccess: ExclusiveAccess = .available

    public init(
        library: any SnipLibrary,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsFactory: @escaping SnipLibraryUserActionsFactory = { DirectSnipLibraryUserActions(library: $0) },
        recoveryScope: SnipRecoveryScope? = nil
    ) {
        binding = BindingOwner(Binding(library: library,
            userActions: userActions ?? userActionsFactory(library), recoveryScope: recoveryScope))
        self.userActionsFactory = userActionsFactory
    }

    /// The real command owner and its checked presentation, prepared without changing either live root.
    public final class PreparedApplication: @unchecked Sendable {
        public let read: SnipLibraryReadObservation
        public let recovery: SnipRecoverySnapshot
        public let replaced: Bool
        private let owner: BindingOwner
        private let previous: Binding
        private let replacement: Binding
        private let sortMode: SnipSortMode
        private let deletionToken: UUID?

        fileprivate init(read: SnipLibraryReadObservation, recovery: SnipRecoverySnapshot,
                         owner: BindingOwner, previous: Binding, replacement: Binding,
                         replaced: Bool, sortMode: SnipSortMode, deletionToken: UUID?) {
            self.read = read; self.recovery = recovery; self.owner = owner
            self.previous = previous; self.replacement = replacement; self.replaced = replaced
            self.sortMode = sortMode; self.deletionToken = deletionToken
        }

        /// Invoke in the same synchronous closing operation as the model's authoritative install.
        public func install(within closing: SnipLibraryReadPublication.Application? = nil) throws {
            if let source = read.source {
                guard let publication = read.publication, let closing, closing.owns(publication),
                    read.target?.source == source else { throw SnipLibraryReadPublicationError.revoked }
            }
            try owner.lock.withLock {
                guard owner.current === previous else { throw SnipLibraryReadPublicationError.revoked }
                owner.current = replacement
            }
        }

        public func finishRetiredActions() async {
            guard replaced, let deletionToken else { return }
            await previous.userActions.discardDeletion(token: deletionToken, sortedBy: sortMode)
        }
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
        await bindLibrary(library, recoveryScope: recoveryScope, sortedBy: sortMode)
        return await state(sortedBy: sortMode)
    }

    public func replaceLibraryChecked(
        _ library: any SnipLibrary, recoveryScope: SnipRecoveryScope?, sortedBy sortMode: SnipSortMode
    ) async throws -> (read: SnipLibraryReadObservation, recovery: SnipRecoverySnapshot) {
        let prepared = try await prepareLibraryApplication(library, recoveryScope: recoveryScope,
            replacing: true, sortedBy: sortMode)
        if prepared.read.source != nil, prepared.read.publication == nil {
            throw SnipLibraryReadPublicationError.revoked
        }
        let closing = try prepared.read.publication?.beginApplication()
        do { try prepared.install(within: closing) } catch { closing?.finish(); throw error }
        closing?.finish()
        await prepared.finishRetiredActions()
        return (prepared.read, prepared.recovery)
    }

    public func prepareLibraryApplication(
        _ library: any SnipLibrary, recoveryScope: SnipRecoveryScope?,
        replacing: Bool, sortedBy sortMode: SnipSortMode
    ) async throws -> PreparedApplication {
        let previous = binding.lock.withLock { binding.current }
        let read = try await checkedRead(from: library, sortedBy: sortMode)
        let recovery = try await checkedRecovery(from: library, scope: recoveryScope)
        try Task.checkCancellation()
        let replacement = replacing
            ? Binding(library: read.target?.library ?? library, userActions: userActionsFactory(read.target?.library ?? library), recoveryScope: recoveryScope)
            : previous
        let token = binding.lock.withLock { previous.pendingDeletionToken }
        return PreparedApplication(read: read, recovery: recovery, owner: binding, previous: previous,
            replacement: replacement, replaced: replacing, sortMode: sortMode, deletionToken: token)
    }

    public func prepareLibraryReconciliation(
        _ library: any SnipLibrary, recoveryScope: SnipRecoveryScope?,
        replacing source: SnipLibraryReadSource?, sortedBy sortMode: SnipSortMode
    ) async throws -> PreparedApplication {
        let previous = binding.lock.withLock { binding.current }
        let read = try await checkedRead(from: library, sortedBy: sortMode)
        let recovery = try await checkedRecovery(from: library, scope: recoveryScope)
        try Task.checkCancellation()
        let sameBinding = (read.target?.library as? any SnipLibraryApplicationBinding)?
            .sharesApplicationBinding(with: previous.library) == true
        let replaced = read.source == nil || read.source != source || previous.recoveryScope != recoveryScope || !sameBinding
        let replacement = replaced
            ? Binding(library: read.target?.library ?? library, userActions: userActionsFactory(read.target?.library ?? library), recoveryScope: recoveryScope)
            : previous
        let token = binding.lock.withLock { previous.pendingDeletionToken }
        return PreparedApplication(read: read, recovery: recovery, owner: binding, previous: previous,
            replacement: replacement, replaced: replaced, sortMode: sortMode, deletionToken: token)
    }

    private func bindLibrary(
        _ library: any SnipLibrary, recoveryScope: SnipRecoveryScope?, sortedBy sortMode: SnipSortMode
    ) async {
        await discardPendingDeletion(sortedBy: sortMode)
        let replacement = Binding(library: library, userActions: userActionsFactory(library), recoveryScope: recoveryScope)
        binding.lock.withLock { binding.current = replacement }
    }

    public func archive() async throws -> SnipLibraryArchive {
        try await library.archive()
    }

    public func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot {
        try await library.checkedSnapshot(sortedBy: sortMode)
    }

    public func checkedRead(sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryReadObservation {
        try await checkedRead(from: library, sortedBy: sortMode)
    }

    private func checkedRead(
        from selectedLibrary: any SnipLibrary,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryReadObservation {
        if let observed = selectedLibrary as? any SnipLibraryReadObserving {
            return try await observed.checkedRead(sortedBy: sortMode)
        }
        return SnipLibraryReadObservation(
            snapshot: try await selectedLibrary.checkedSnapshot(sortedBy: sortMode),
            source: nil
        )
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
            expectation: SnipLibraryExpectation(expectedCompletionSnips: changing),
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
        try await checkedRecovery(from: library, scope: recoveryScope)
    }

    private func checkedRecovery(
        from selectedLibrary: any SnipLibrary,
        scope: SnipRecoveryScope?
    ) async throws -> SnipRecoverySnapshot {
        guard let scope else { return .empty }
        return try await selectedLibrary.recoverySnapshot(in: scope)
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

    /// Throws `CancellationError` when the library is replaced or a newer preview starts first.
    public func previewImport(from url: URL) async throws -> SavedSnipsImportPreview {
        let id = UUID()
        importPreview = .previewing(id)
        let value: SnipImportPreview
        do {
            value = try await userActions.previewImport(backupURL: url)
        } catch {
            if isPreviewing(id) { importPreview = .none }
            throw error
        }
        guard isPreviewing(id) else { throw CancellationError() }
        let preview = SavedSnipsImportPreview(id: id, value: value)
        importPreview = .pending(preview)
        return preview
    }

    public func hasPendingImport(id: UUID) -> Bool {
        pendingImport(id: id) != nil
    }

    @discardableResult
    public func cancelImport(id: UUID) -> Bool {
        guard hasPendingImport(id: id) else { return false }
        importPreview = .none
        return true
    }

    public func applyPendingImport(
        id: UUID,
        sortedBy sortMode: SnipSortMode
    ) async throws -> (SnipImportResult, SnipRecoverySnapshot)? {
        guard let preview = pendingImport(id: id) else { return nil }
        importPreview = .none
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

    private func isPreviewing(_ id: UUID) -> Bool {
        guard case .previewing(let current) = importPreview else { return false }
        return current == id
    }

    private func pendingImport(id: UUID) -> SavedSnipsImportPreview? {
        guard case .pending(let preview) = importPreview, preview.id == id else { return nil }
        return preview
    }

    private func acquire() async {
        guard case .held(let waiters) = exclusiveAccess else {
            exclusiveAccess = .held(waiters: [])
            return
        }
        await withCheckedContinuation { exclusiveAccess = .held(waiters: waiters + [$0]) }
    }

    private func release() {
        guard case .held(var waiters) = exclusiveAccess, !waiters.isEmpty else {
            exclusiveAccess = .available
            return
        }
        let next = waiters.removeFirst()
        exclusiveAccess = .held(waiters: waiters)
        next.resume()
    }
}
