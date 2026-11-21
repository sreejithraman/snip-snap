import Foundation
import SnipSnapCore

#if os(macOS)
typealias SavedSnipsCommandModel = AppModel
#elseif os(iOS)
typealias SavedSnipsCommandModel = IOSAppModel
#endif

enum BackupImportPresentation {
    case idle
    case previewing(UUID, replacing: SavedSnipsImportPreview?)
    case awaitingConfirmation(SavedSnipsImportPreview)

    var preview: SavedSnipsImportPreview? {
        switch self {
        case .idle: nil
        case .previewing(_, let previous): previous
        case .awaitingConfirmation(let preview): preview
        }
    }

    mutating func beginPreview(keepingCurrentPreview: Bool = false) -> UUID {
        let operation = UUID()
        self = .previewing(operation, replacing: keepingCurrentPreview ? preview : nil)
        return operation
    }

    @discardableResult
    mutating func present(_ preview: SavedSnipsImportPreview, for operation: UUID) -> Bool {
        guard isPreviewing(operation) else { return false }
        self = .awaitingConfirmation(preview)
        return true
    }

    mutating func failPreview(_ operation: UUID) {
        if isPreviewing(operation) { self = .idle }
    }

    mutating func cancel(keepingActivePreview: Bool) -> UUID? {
        let id = preview?.id
        if keepingActivePreview, case .previewing(let operation, _) = self {
            guard id != nil else { return nil }
            self = .previewing(operation, replacing: nil)
        } else {
            self = .idle
        }
        return id
    }

    private func isPreviewing(_ operation: UUID) -> Bool {
        guard case .previewing(let current, _) = self else { return false }
        return current == operation
    }
}

@MainActor
extension SavedSnipsCommandModel {
    func currentSnip(for recovery: RecoveredSnip) -> Snip? {
        snips.first { $0.id == recovery.currentSnipID }
    }

    func currentList(for recovery: RecoveredListEdit) -> SnipList? {
        lists.first { $0.id == recovery.currentListID }
    }

    func isRecoveredSnip(_ snipID: UUID) -> Bool {
        recoverySnapshot.pendingSnips.contains { $0.id == snipID }
            || recoverySnapshot.promotedSnips.contains { $0.id == snipID }
    }

    func performToastAction(_ presentedToast: AppToast) {
        Task { await performToastActionNow(presentedToast) }
    }

    func retryPendingUndo(_ failure: AppFailure) {
        guard let undo = snackbarAndErrors.undoToRetry(for: failure) else { return }
        performToastAction(undo)
    }

    func retryPendingUndoNow(_ failure: AppFailure) async {
        guard let undo = snackbarAndErrors.undoToRetry(for: failure) else { return }
        await performToastActionNow(undo)
    }

    func performToastActionNow(_ presentedToast: AppToast) async {
        switch presentedToast.action {
        case .undoDelete, .undoDone:
            await performUndoAction(presentedToast)
        case .showErrorDetails(let id):
            snackbarAndErrors.showLatestErrorDetails(ifLatestIs: id)
        case nil:
            break
        }
    }

    func dismissToast(_ presentedToast: AppToast) {
        Task {
            await session.withExclusiveAccess { session in
                switch presentedToast.action {
                case .undoDelete:
                    await session.discardDeletion(token: presentedToast.id, sortedBy: sortMode)
                case .undoDone:
                    await session.discardDone(token: presentedToast.id)
                default:
                    break
                }
            }
            closeSnackbar(presentedToast)
        }
    }

    func closeSnackbar(_ snackbar: AppToast) {
        snackbarAndErrors.closeSnackbar(id: snackbar.id)
    }

    func clearPendingUndoToast() {
        snackbarAndErrors.endUndoWindow()
    }

    // Mutations run inside the caller's session lock, including their presentation effects.

    func restoreUndo(
        _ toast: AppToast,
        feedback: (Bool) -> Void = { _ in }
    ) async {
        let isDeletion = toast.action == .undoDelete
        let operation: StaticString = isDeletion ? "snip.undo_delete" : "snip.undo_done"
#if os(iOS)
        let priorFailureID = snackbarAndErrors.retryUndoFailure?.id
#endif
        do {
            let update = if isDeletion {
                try await session.restoreDeletion(token: toast.id, sortedBy: sortMode)
            } else {
                try await session.restoreDone(token: toast.id, sortedBy: sortMode)
            }
            guard let update else {
                expireUnavailableUndoRetry(token: toast.id, operation: operation)
                return
            }
#if os(macOS)
            apply(update.snapshot)
#endif
            snackbarAndErrors.undoSucceeded(toast)
            clearCommandFailure(operation)
#if os(iOS)
            apply(update.snapshot)
#endif
            feedback(true)
            await finishSavedSnipsCommand(refreshRecovery: isDeletion)
        } catch {
            if isDeletion { feedback(false) }
            presentError(error, operation: operation)
#if os(macOS)
            snackbarAndErrors.retainUndoFailure(of: toast)
#elseif os(iOS)
            snackbarAndErrors.retainUndoFailure(of: toast, movingDetailsFrom: priorFailureID)
#endif
            if !isDeletion { feedback(false) }
        }
    }

    func deleteSavedSnips(
        ids: Set<UUID>,
        afterDeletion: () -> Void = {},
        feedback: (Bool) -> Void = { _ in }
    ) async -> Bool {
        let count = snips.count { ids.contains($0.id) }
        guard count > 0 else { return false }
        let token = UUID()
        do {
            let result = try await session.deleteWithResult(ids: ids, token: token, sortedBy: sortMode)
            apply(result.update.snapshot)
            guard result.didChange else { return true }
            clearPendingUndoToast()
#if os(iOS)
            clearCommandFailure("snip.delete")
#endif
            afterDeletion()
            snackbarAndErrors.show(.deleted(count: count, id: token))
            feedback(true)
            await finishSavedSnipsCommand()
            return true
        } catch {
            presentError(error, operation: "snip.delete")
            feedback(false)
            return false
        }
    }

    func completionCandidates(
        ids: Set<UUID>? = nil,
        excluding editedID: UUID? = nil,
        versions: [UUID: Date]? = nil
    ) -> [Snip] {
        snips.filter { snip in
            !snip.isPinned && snip.id != editedID
                && (ids?.contains(snip.id) ?? true)
                && (versions.map { $0[snip.id] == snip.updatedAt } ?? true)
        }
    }

    func changeCompletion(
        _ done: Bool,
        snips changing: [Snip],
        guardingChanges: Bool,
        copyToast: AppToast?,
        feedback: (Bool) -> Void = { _ in }
    ) async -> Bool {
        guard !changing.isEmpty else { return true }
        do {
            let change = try await session.setDone(
                ids: Set(changing.map(\.id)), done: done,
                expectation: guardingChanges ? .init(expectedCompletionSnips: changing) : nil,
                sortedBy: sortMode
            )
            guard change.didChange else {
                apply(change.update.snapshot)
                return true
            }
#if os(iOS)
            clearPendingUndoToast()
#endif
            clearCommandFailure("snip.completion")
            clearCommandFailure("snip.completion_after_copy")
#if os(macOS)
            clearPendingUndoToast()
#endif
            apply(change.update.snapshot)
            if let undo = change.undo {
                snackbarAndErrors.show(copyToast?.addingDoneUndo(undo) ?? .markedDone(count: undo.count, id: undo.id))
            } else {
#if os(macOS)
                if let copyToast { snackbarAndErrors.showUnlessActionable(copyToast) }
#endif
            }
            feedback(true)
            await finishSavedSnipsCommand()
            return true
        } catch {
            if copyToast != nil {
                presentError(
                    copiedButCouldNotMarkDone,
                    operation: "snip.completion_after_copy",
                    diagnosticCode: diagnosticErrorCode(error)
                )
            } else {
                presentError(error, operation: "snip.completion")
            }
            feedback(false)
            return false
        }
    }

    func resolveSavedSnipsRecovery(_ id: UUID, choice: SnipRecoveryChoice) async throws -> Bool {
        guard let state = try await session.resolveRecovery(id, choice: choice, sortedBy: sortMode) else {
            return false
        }
        clearPendingUndoToast()
        apply(state)
        scheduleCloudSync()
        return true
    }

    enum CommandRoute {
        case userActions
#if os(macOS)
        case library
#endif
    }

    func runSavedSnipsCommand(
        _ command: SnipLibraryCommand,
        route: CommandRoute = .userActions,
        afterApply: (SnipLibraryCommandResult) -> Void = { _ in }
    ) async -> Result<SnipLibraryOutcome, Error> {
#if os(macOS)
        if case .library = route {
            let mutation = await performMutationUnlocked {
                let result = try await session.performLibraryCommandWithResult(command, sortedBy: sortMode)
                return (result.update, result)
            }
            return mutation.map { result in
                afterApply(result)
                return result.update.outcome
            }
        }
#endif
        do {
            let result = try await session.performUserCommandWithResult(command, sortedBy: sortMode)
            if result.didChange { clearPendingUndoToast() }
#if os(iOS)
            clearCommandFailure(command.diagnosticOperation)
#endif
            apply(result.update.snapshot)
            afterApply(result)
            await finishSavedSnipsCommand()
            return .success(result.update.outcome)
        } catch {
            return .failure(error)
        }
    }

    func moveToListCommand(
        ids: [UUID], to listID: UUID, sortedBy moveSortMode: SnipSortMode, in currentSnips: [Snip]
    ) -> SnipLibraryCommand {
        guard moveSortMode == .manual else { return .moveChronologically(ids: ids, to: listID) }
        let moving = Set(ids)
        let firstDestinationID = currentSnips.first {
            $0.listID == listID && !moving.contains($0.id)
        }?.id
        return .place(ids: ids, in: listID, before: firstDestinationID, basedOn: .manual)
    }

    private func finishSavedSnipsCommand(refreshRecovery: Bool = true) async {
#if os(iOS)
        if refreshRecovery {
            await refreshAfterSavedSnipsCommand()
        }
#endif
        scheduleCloudSync()
    }

    func cancelBackupImport() {
#if os(macOS)
        guard let id = backupImport.cancel(keepingActivePreview: true) else { return }
#elseif os(iOS)
        guard let id = backupImport.cancel(keepingActivePreview: false) else { return }
#endif
        Task { await discardBackupImport(id) }
    }

    func stageBackupImport(from url: URL) async throws -> SavedSnipsImportPreview {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return try await session.previewImport(from: url)
    }

    func discardBackupImport(_ id: UUID) async {
        await session.withExclusiveAccess { session in
            _ = await session.cancelImport(id: id)
        }
    }

    func applyBackupImport(_ id: UUID, sortedBy sortMode: SnipSortMode) async throws
        -> (SnipImportResult, SnipRecoverySnapshot) {
        guard let result = try await session.applyPendingImport(id: id, sortedBy: sortMode) else {
            throw SnipLibraryError.importChanged
        }
        return result
    }

    func presentImportedBackup(_ imported: (SnipImportResult, SnipRecoverySnapshot)) {
        let (result, recovery) = imported
        clearPendingUndoToast()
#if os(macOS)
        backupImport = .idle
        apply(result.snapshot)
        recoverySnapshot = recovery
#elseif os(iOS)
        apply(SavedSnipsSessionState(library: result.snapshot, recovery: recovery))
#endif
    }
}
