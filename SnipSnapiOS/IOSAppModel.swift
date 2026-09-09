import Foundation
import Observation
import SnipSnapCore

@MainActor
@Observable
final class IOSAppModel {
    private let session: SavedSnipsSession
    let haptics: IOSHapticFeedback
    private let cloudSyncHandler: (any OptionalCloudSyncHandling)?

    private(set) var snips: [Snip]
    private(set) var lists: [SnipList]
    private(set) var attachmentURLs: [UUID: URL]
    private(set) var recoverySnapshot: SnipRecoverySnapshot = .empty
    private var preparedAttachmentURLs: [UUID: URL] = [:]
    private(set) var attachmentTransferStates: [UUID: SyncedAttachmentTransferState] = [:]
    private(set) var isCloudSyncActive = false
    private var hasKnownCloudSyncActivity: Bool
    private var hasKnownCloudAttachmentStates = false
    private(set) var pendingImportPreview: SnipImportPreview?
    private var pendingImportPreviewID: UUID?
    var toast: AppToast?
    var selectedListID: UUID
    var editingListID: UUID?
    var newListID: UUID?
    private(set) var isCreatingList = false
    var selectedSnipID: UUID?
    var selectedSnipIDs: Set<UUID> = []
    var searchText = ""
    var completionFilter: SnipCompletionFilter = .all
    var sortMode: SnipSortMode = .chronological
    var errorMessage: String?

    init(
        library: any SnipLibrary,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsRebinder: SnipLibraryUserActionsRebinder = .direct,
        recoveryScope: SnipRecoveryScope? = nil,
        initialSnapshot: SnipLibrarySnapshot = SnipLibrarySnapshot(
            snips: [],
            lists: [.inbox]
        ),
        startupError: String? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil,
        haptics: IOSHapticFeedback = IOSHapticFeedback()
    ) {
        session = SavedSnipsSession(
            library: library,
            userActions: userActions,
            userActionsRebinder: userActionsRebinder,
            recoveryScope: recoveryScope
        )
        self.cloudSyncHandler = cloudSyncHandler
        self.haptics = haptics
        hasKnownCloudSyncActivity = cloudSyncHandler == nil
        snips = initialSnapshot.snips
        lists = initialSnapshot.lists
        attachmentURLs = initialSnapshot.attachmentURLs
        selectedListID = SnipList.inboxID
        errorMessage = startupError
    }

    var selectedList: SnipList {
        lists.first(where: { $0.id == selectedListID }) ?? .inbox
    }

    var selectedSnip: Snip? {
        guard let selectedSnipID else { return nil }
        return snips.first(where: { $0.id == selectedSnipID })
    }

    func selectList(_ listID: UUID) {
        haptics.invalidatePendingFeedback()
        selectedListID = listID
        selectedSnipID = nil
        selectedSnipIDs = []
    }

    func endSelectingSnips() {
        haptics.invalidatePendingFeedback()
        selectedSnipIDs = []
    }

    func beginEditingSnip(_ id: UUID) {
        haptics.invalidatePendingFeedback()
        selectedSnipID = id
    }

    func selectSnips(_ ids: Set<UUID>) {
        guard ids != selectedSnipIDs else { return }
        selectedSnipIDs = ids
        haptics.emit(.selection, for: haptics.beginInteraction())
    }

    var selectedVisibleSnips: [Snip] {
        visibleSnips.filter { selectedSnipIDs.contains($0.id) }
    }

    var visibleSnips: [Snip] {
        let selected = snips.filter { $0.listID == selectedListID }
        let matches = SnipFilter.apply(
            snips: selected,
            query: searchText,
            completionFilter: completionFilter,
            sourceLabel: { $0.displaySourceLabel }
        )
        return Snip.sorted(matches, by: sortMode)
    }

    var canReorderVisibleSnips: Bool {
        completionFilter == .all
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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

    func load() async {
        await withSerializedMutation { await loadUnlocked() }
    }

    func replaceLibrary(
        _ library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope?
    ) async {
        haptics.invalidatePendingFeedback()
        await withSerializedMutation {
            clearPendingDeletionToast()
            selectedSnipID = nil
            apply(await session.replaceLibrary(
                library,
                recoveryScope: recoveryScope,
                sortedBy: sortMode
            ))
            await refreshAttachmentTransferStates()
        }
    }

    @discardableResult
    func resolveRecovery(_ id: UUID, choice: SnipRecoveryChoice) async -> Bool {
        await withUserMutation { _ in
            await resolveRecoveryUnlocked(id, choice: choice)
        }
    }

    @discardableResult
    func createSnip(
        content: String,
        in listID: UUID,
        attachmentURLs: [URL] = [],
        selectCreatedSnip: Bool = true
    ) async -> Bool {
        await withUserMutation { interaction in
            await createSnipUnlocked(
                content: content,
                in: listID,
                attachmentURLs: attachmentURLs,
                selectCreatedSnip: selectCreatedSnip,
                feedbackInteraction: interaction
            )
        }
    }

    @discardableResult
    func editSnip(
        _ snip: Snip,
        content: String,
        attachmentEdits: [SnipAttachmentEdit]? = nil
    ) async -> Bool {
        await withUserMutation { interaction in
            await editSnipUnlocked(
                snip,
                content: content,
                attachmentEdits: attachmentEdits,
                feedbackInteraction: interaction
            )
        }
    }

    @discardableResult
    func deleteSnip(id: UUID) async -> Bool {
        await withUserMutation { interaction in await deleteSnips(ids: [id], feedbackInteraction: interaction) }
    }

    @discardableResult
    func deleteSelection() async -> Bool {
        await withUserMutation { interaction in
            await deleteSnips(ids: selectedVisibleSnipIDs, feedbackInteraction: interaction)
        }
    }

    @discardableResult
    func mergeSelection() async -> Bool {
        await withUserMutation { interaction in
            let ids = selectedVisibleSnipIDs
            guard ids.count >= 2 else { return false }
            return await performUserAction(.merge(ids: ids, now: Date()), feedbackInteraction: interaction) { outcome in
                guard case .merged(let snip) = outcome else { return }
                selectedSnipID = snip.id
                selectedSnipIDs = [snip.id]
                if completionFilter == .done { completionFilter = .all }
            }
        }
    }

    @discardableResult
    func moveSnip(id: UUID, to listID: UUID) async -> Bool {
        await withUserMutation { interaction in
            await moveSnipUnlocked(id: id, to: listID, feedbackInteraction: interaction)
        }
    }

    @discardableResult
    func moveSelection(to listID: UUID) async -> Bool {
        await withUserMutation { interaction in
            await moveSelectionUnlocked(to: listID, feedbackInteraction: interaction)
        }
    }

    @discardableResult
    func placeVisibleSnips(_ orderedIDs: [UUID]) async -> Bool {
        await withUserMutation { _ in await placeVisibleSnipsUnlocked(orderedIDs) }
    }

    @discardableResult
    func setSelectionDone(_ done: Bool) async -> Bool {
        await withUserMutation { interaction in
            await setSelectionDoneUnlocked(done, feedbackInteraction: interaction)
        }
    }

    @discardableResult
    func toggleDone(id: UUID) async -> Bool {
        await withUserMutation { interaction in
            await toggleDoneUnlocked(id: id, feedbackInteraction: interaction)
        }
    }

    func openNewList() async {
        guard !isCreatingList else { return }
        isCreatingList = true
        defer { isCreatingList = false }
        if await createList(name: String(localized: "New List")) {
            searchText = ""
            newListID = selectedListID
            editingListID = selectedListID
        }
    }

    func editListInline(id: UUID) {
        guard id != SnipList.inboxID else { return }
        selectList(id)
        editingListID = id
    }

    @discardableResult
    func createList(name: String, systemImage: String = "list.bullet", color: SnipListColor? = nil) async -> Bool {
        await withUserMutation { _ in
            await createListUnlocked(name: name, systemImage: systemImage, color: color)
        }
    }

    @discardableResult
    func renameList(_ list: SnipList, name: String, systemImage: String, color: SnipListColorChange = .keep) async -> Bool {
        await withUserMutation { _ in
            await renameListUnlocked(list, name: name, systemImage: systemImage, color: color)
        }
    }

    @discardableResult
    func deleteList(id: UUID) async -> Bool {
        await withUserMutation { interaction in await deleteListUnlocked(id: id, feedbackInteraction: interaction) }
    }

    func presentToast(_ presentedToast: AppToast) {
        guard toast?.action == nil || presentedToast.action != nil else { return }
        toast = presentedToast
    }

    func performToastAction(_ presentedToast: AppToast) {
        Task { await performToastActionNow(presentedToast) }
    }

    func performToastActionNow(_ presentedToast: AppToast) async {
        guard presentedToast.action == .undoDelete else { return }
        await withUserMutation { interaction in
            await restoreDeletion(token: presentedToast.id, feedbackInteraction: interaction)
        }
    }

    func dismissToast(_ presentedToast: AppToast) {
        guard presentedToast.action == .undoDelete else { return }
        Task {
            await session.withExclusiveAccess { session in
                await session.discardDeletion(token: presentedToast.id, sortedBy: sortMode)
            }
            if toast?.id == presentedToast.id { toast = nil }
        }
    }

    private func loadUnlocked() async {
        apply(await session.state(sortedBy: sortMode))
        await refreshAttachmentTransferStates()
    }

    private func resolveRecoveryUnlocked(
        _ id: UUID,
        choice: SnipRecoveryChoice
    ) async -> Bool {
        do {
            guard let state = try await session.resolveRecovery(
                id,
                choice: choice,
                sortedBy: sortMode
            ) else { return false }
            apply(state)
            scheduleCloudSync()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await loadUnlocked()
            return false
    }
    }

    private func createSnipUnlocked(
        content: String,
        in listID: UUID,
        attachmentURLs: [URL] = [],
        selectCreatedSnip: Bool = true,
        feedbackInteraction: UUID?
    ) async -> Bool {
        return await performUserAction(
            .add(
                content: content,
                origin: .quickEntry,
                source: nil,
                listID: listID,
                attachmentURLs: attachmentURLs,
                requestID: UUID(),
                now: Date()
            ),
            feedbackInteraction: feedbackInteraction
        ) { outcome in
            if selectCreatedSnip, case .add(.added(let id)) = outcome {
                selectedListID = listID
                selectedSnipID = id
            }
        }
    }

    func attachmentURL(for attachmentID: UUID) -> URL? {
        if cloudSyncHandler != nil, !hasKnownCloudSyncActivity {
            return preparedAttachmentURLs[attachmentID]
        }
        if isCloudSyncActive,
           !hasKnownCloudAttachmentStates || attachmentTransferStates[attachmentID] != nil
        {
            return preparedAttachmentURLs[attachmentID]
        }
        return attachmentURLs[attachmentID]
    }

    func attachmentTransferState(for attachmentID: UUID) -> SyncedAttachmentTransferState {
        if let state = attachmentTransferStates[attachmentID] { return state }
        if cloudSyncHandler != nil, !hasKnownCloudSyncActivity { return .waiting }
        if isCloudSyncActive, !hasKnownCloudAttachmentStates { return .waiting }
        return attachmentURLs[attachmentID] == nil ? .waiting : .available
    }

    func prepareAttachment(_ attachmentID: UUID, for use: SyncedAttachmentUse) async -> URL? {
        if let preparedURL = preparedAttachmentURLs[attachmentID],
           isAvailablePreparedAttachment(preparedURL)
        {
            attachmentTransferStates[attachmentID] = .available
            return preparedURL
        }
        preparedAttachmentURLs[attachmentID] = nil
        guard let cloudSyncHandler else { return attachmentURLs[attachmentID] }
        if hasKnownCloudSyncActivity, !isCloudSyncActive {
            return attachmentURLs[attachmentID]
        }
        if hasKnownCloudSyncActivity,
           hasKnownCloudAttachmentStates,
           attachmentTransferStates[attachmentID] == nil
        {
            return attachmentURLs[attachmentID]
        }
        attachmentTransferStates[attachmentID] = .syncing
        do {
            let url = try await cloudSyncHandler.prepareSyncedAttachment(attachmentID, for: use)
            attachmentURLs[attachmentID] = url
            preparedAttachmentURLs[attachmentID] = url
            attachmentTransferStates[attachmentID] = .available
            return url
        } catch {
            attachmentTransferStates[attachmentID] = .failed
            switch use {
            case .preview, .open:
                errorMessage = String(localized: "Snip Snap could not download that attachment. Please try again.")
            case .copy, .export:
                break
            }
            return nil
        }
    }

    private func isAvailablePreparedAttachment(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    func clearDownloadedFiles() async {
        haptics.invalidatePendingFeedback()
        guard let cloudSyncHandler else { return }
        do {
            try await cloudSyncHandler.clearDownloadedFiles()
            apply(await session.state(sortedBy: .chronological))
            await refreshAttachmentTransferStates()
        } catch {
            errorMessage = String(localized: "Snip Snap could not clear the downloaded files.")
        }
    }

    func syncWhenPossible() async {
        haptics.invalidatePendingFeedback()
        await cloudSyncHandler?.syncWhenPossible()
        await load()
    }

    private func editSnipUnlocked(
        _ snip: Snip,
        content: String,
        attachmentEdits: [SnipAttachmentEdit]?,
        feedbackInteraction: UUID?
    ) async -> Bool {
        let command: SnipLibraryCommand
        if let attachmentEdits {
            command = .editAttachments(
                snipID: snip.id,
                content: content,
                edits: attachmentEdits,
                expectedUpdatedAt: snip.updatedAt,
                now: Date()
            )
        } else {
            command = .update(
                id: snip.id,
                content: content,
                attachmentURLs: nil,
                expectedUpdatedAt: snip.updatedAt,
                now: Date()
            )
        }
        return await performUserAction(command, feedbackInteraction: feedbackInteraction)
    }

    private func moveSnipUnlocked(id: UUID, to listID: UUID, feedbackInteraction: UUID?) async -> Bool {
        return await performUserAction(
            .moveChronologically(ids: [id], to: listID), feedbackInteraction: feedbackInteraction
        ) { _ in
            selectedListID = listID
            selectedSnipID = id
        }
    }

    private func moveSelectionUnlocked(to listID: UUID, feedbackInteraction: UUID?) async -> Bool {
        let selected = selectedVisibleSnipIDs
        let ids = visibleSnips.map(\.id).filter(selected.contains)
        guard !ids.isEmpty else { return false }
        let command: SnipLibraryCommand
        if sortMode == .manual {
            let moving = Set(ids)
            let firstDestinationID = Snip.sorted(
                snips.filter { $0.listID == listID && !moving.contains($0.id) },
                by: .manual
            ).first?.id
            command = .place(ids: ids, in: listID, before: firstDestinationID, basedOn: .manual)
        } else {
            command = .moveChronologically(ids: ids, to: listID)
        }
        return await performUserAction(command, feedbackInteraction: feedbackInteraction) { _ in
            selectedSnipIDs = []
            selectedSnipID = nil
        }
    }

    private func placeVisibleSnipsUnlocked(_ orderedIDs: [UUID]) async -> Bool {
        guard canReorderVisibleSnips,
            Set(orderedIDs) == Set(visibleSnips.map(\.id)),
            orderedIDs.count == visibleSnips.count
        else { return false }
        guard orderedIDs != visibleSnips.map(\.id) else { return true }
        let listID = selectedListID
        return await performUserAction(
            .place(ids: orderedIDs, in: listID, before: nil, basedOn: sortMode)
        ) { _ in
            sortMode = .manual
        }
    }

    private func setSelectionDoneUnlocked(_ done: Bool, feedbackInteraction: UUID?) async -> Bool {
        await setDoneUnlocked(ids: selectedVisibleSnipIDs, done: done, feedbackInteraction: feedbackInteraction)
    }

    private func toggleDoneUnlocked(id: UUID, feedbackInteraction: UUID?) async -> Bool {
        guard let snip = snips.first(where: { $0.id == id }) else { return false }
        return await setDoneUnlocked(ids: [id], done: !snip.isDone, feedbackInteraction: feedbackInteraction)
    }

    // Every completion control reaches this command, including batch actions.
    private func setDoneUnlocked(ids: Set<UUID>, done: Bool, feedbackInteraction: UUID?) async -> Bool {
        guard !ids.isEmpty else { return false }
        guard snips.contains(where: { ids.contains($0.id) && $0.isDone != done }) else { return true }
        return await performUserAction(.setDone(ids: ids, done: done), feedbackInteraction: feedbackInteraction)
    }

    private func createListUnlocked(name: String, systemImage: String, color: SnipListColor?) async -> Bool {
        await performUserAction(
            .createList(name: name, systemImage: systemImage, color: color)
        ) { outcome in
            if case .listCreated(let list) = outcome {
                selectedListID = list.id
                selectedSnipID = nil
                selectedSnipIDs = []
            }
        }
    }

    private func renameListUnlocked(
        _ list: SnipList,
        name: String,
        systemImage: String,
        color: SnipListColorChange
    ) async -> Bool {
        await performUserAction(
            .updateList(id: list.id, name: name, systemImage: systemImage, color: color)
        )
    }

    private func deleteListUnlocked(id: UUID, feedbackInteraction: UUID?) async -> Bool {
        guard lists.contains(where: { $0.id == id }) else { return false }
        return await performUserAction(
            .deleteList(id: id), feedbackInteraction: feedbackInteraction
        ) { _ in
            selectedListID = SnipList.inboxID
            selectedSnipID = nil
            selectedSnipIDs = []
        }
    }

    private var selectedVisibleSnipIDs: Set<UUID> {
        selectedSnipIDs.intersection(visibleSnips.map(\.id))
    }

    private func restoreDeletion(token: UUID, feedbackInteraction: UUID?) async {
        do {
            guard let update = try await session.restoreDeletion(
                token: token,
                sortedBy: sortMode
            ) else { return }
            apply(update.snapshot)
            haptics.emit(.restored, for: feedbackInteraction)
            if toast?.id == token { toast = nil }
            recoverySnapshot = await session.refreshRecovery()
            await refreshAttachmentTransferStates()
            scheduleCloudSync()
        } catch {
            haptics.emit(.error, for: feedbackInteraction)
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func deleteSnips(ids: Set<UUID>, feedbackInteraction: UUID?) async -> Bool {
        let ids = ids.intersection(snips.map(\.id))
        guard !ids.isEmpty else { return false }
        let count = ids.count
        let token = UUID()
        do {
            let update = try await session.delete(
                ids: ids,
                token: token,
                sortedBy: sortMode
            )
            apply(update.snapshot)
            if let selectedSnipID, ids.contains(selectedSnipID) { self.selectedSnipID = nil }
            selectedSnipIDs.subtract(ids)
            toast = .deleted(count: count, id: token)
            haptics.emit(.deleted, for: feedbackInteraction)
            recoverySnapshot = await session.refreshRecovery()
            await refreshAttachmentTransferStates()
            scheduleCloudSync()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            haptics.emit(.error, for: feedbackInteraction)
            return false
        }
    }

    private func feedbackKind(for command: SnipLibraryCommand) -> IOSHapticFeedback.Kind? {
        switch command {
        case .add, .update, .editAttachments: .saved
        case .setDone(_, let done): done ? .markedDone : .selection
        case .deleteList: .deleted
        case .merge: .merged
        case .moveChronologically(let ids, let listID):
            snips.contains { ids.contains($0.id) && $0.listID != listID } ? .moved : nil
        case .place(let ids, let listID, _, _):
            snips.contains { ids.contains($0.id) && $0.listID != listID } ? .moved : nil
        default: nil
        }
    }

    private func performUserAction(
        _ command: SnipLibraryCommand,
        feedbackInteraction: UUID? = nil,
        afterSuccess: (SnipLibraryOutcome) -> Void = { _ in }
    ) async -> Bool {
        let feedback = feedbackKind(for: command)
        do {
            let update = try await session.performUserCommand(
                command,
                sortedBy: sortMode
            )
            clearPendingDeletionToast()
            apply(update.snapshot)
            if let feedback, update.outcome != .add(.duplicate) {
                haptics.emit(feedback, for: feedbackInteraction)
            }
            recoverySnapshot = await session.refreshRecovery()
            await refreshAttachmentTransferStates()
            afterSuccess(update.outcome)
            scheduleCloudSync()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            haptics.emit(.error, for: feedbackInteraction)
            return false
        }
    }

    private func clearPendingDeletionToast() {
        guard let toast, toast.action == .undoDelete else { return }
        self.toast = nil
    }

    func previewBackupImport(from url: URL) async {
        haptics.invalidatePendingFeedback()
        do {
            let preview = try await session.withExclusiveAccess { session in
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                return try await session.previewImport(from: url)
            }
            pendingImportPreviewID = preview.id
            pendingImportPreview = preview.value
        } catch {
            pendingImportPreviewID = nil
            pendingImportPreview = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func cancelBackupImport() {
        let id = pendingImportPreviewID
        pendingImportPreviewID = nil
        pendingImportPreview = nil
        guard let id else { return }
        Task {
            await session.withExclusiveAccess { session in
                await session.cancelImport(id: id)
            }
        }
    }

    func confirmBackupImport() async {
        haptics.invalidatePendingFeedback()
        guard pendingImportPreview != nil, let id = pendingImportPreviewID else { return }
        do {
            guard let (result, recovery) = try await session.withExclusiveAccess({ session in
                try await session.applyPendingImport(id: id, sortedBy: .chronological)
            }) else { return }
            clearPendingDeletionToast()
            pendingImportPreviewID = nil
            pendingImportPreview = nil
            apply(result.snapshot)
            recoverySnapshot = recovery
        } catch {
            pendingImportPreviewID = nil
            pendingImportPreview = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await load()
        }
    }

    private func apply(_ state: SavedSnipsSessionState) {
        apply(state.library)
        recoverySnapshot = state.recovery
    }

    private func apply(_ snapshot: SnipLibrarySnapshot) {
        snips = snapshot.snips
        lists = snapshot.lists
        attachmentURLs = snapshot.attachmentURLs
        preparedAttachmentURLs.removeAll()
        if !lists.contains(where: { $0.id == selectedListID }) {
            selectedListID = SnipList.inboxID
        }
        if let selectedSnipID, !snips.contains(where: { $0.id == selectedSnipID }) {
            self.selectedSnipID = nil
        }
        selectedSnipIDs.formIntersection(snips.map(\.id))
    }

    private func refreshAttachmentTransferStates() async {
        guard let cloudSyncHandler else {
            isCloudSyncActive = false
            hasKnownCloudSyncActivity = true
            hasKnownCloudAttachmentStates = true
            attachmentTransferStates = Dictionary(uniqueKeysWithValues:
                attachmentURLs.keys.map { ($0, .available) }
            )
            return
        }
        hasKnownCloudSyncActivity = false
        do {
            isCloudSyncActive = try await cloudSyncHandler.isCloudSyncActive()
            hasKnownCloudSyncActivity = true
            guard isCloudSyncActive else {
                hasKnownCloudAttachmentStates = true
                attachmentTransferStates = [:]
                preparedAttachmentURLs.removeAll()
                return
            }
            attachmentTransferStates = try await cloudSyncHandler.syncedAttachmentStates()
            hasKnownCloudAttachmentStates = true
            preparedAttachmentURLs = preparedAttachmentURLs.filter {
                attachmentTransferStates[$0.key] != nil
            }
        } catch {
            if isCloudSyncActive { hasKnownCloudAttachmentStates = false }
            // Keep the last known states while iCloud is unavailable.
        }
    }

    private func withUserMutation<Result: Sendable>(
        _ operation: @MainActor @Sendable (UUID?) async -> Result
    ) async -> Result {
        let interaction = haptics.beginInteraction()
        return await withSerializedMutation { await operation(interaction) }
    }

    private func withSerializedMutation<Result: Sendable>(
        _ operation: @MainActor @Sendable () async -> Result
    ) async -> Result {
        await session.withExclusiveAccess { _ in await operation() }
    }

    private func scheduleCloudSync() {
        guard let cloudSyncHandler else { return }
        Task { await cloudSyncHandler.scheduleSyncAfterLocalChange() }
    }

}
