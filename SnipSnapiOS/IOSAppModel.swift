import Foundation
import Observation
import SnipSnapCore

@MainActor
@Observable
final class IOSAppModel {
    private var library: any SnipLibrary
    private var recoveryScope: SnipRecoveryScope?
    private let cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private var userActions: any SnipLibraryUserActions
    private let rebindUserActions: SnipLibraryUserActionsRebinder
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var snips: [Snip]
    private(set) var lists: [SnipList]
    private(set) var attachmentURLs: [UUID: URL]
    private(set) var recoverySnapshot: SnipRecoverySnapshot = .empty
    private var preparedAttachmentURLs: [UUID: URL] = [:]
    private(set) var attachmentTransferStates: [UUID: SyncedAttachmentTransferState] = [:]
    private(set) var isCloudSyncActive = false
    private var hasKnownCloudSyncActivity: Bool
    private var hasKnownCloudAttachmentStates = false
    private(set) var deviceActionState = SnipDeviceActionState(
        undoTitle: "Undo",
        redoTitle: "Redo"
    )
    private(set) var pendingImportPreview: SnipImportPreview?
    var selectedListID: UUID
    var selectedSnipID: UUID?
    var selectedSnipIDs: Set<UUID> = []
    var searchText = ""
    var completionFilter: SnipCompletionFilter = .all
    var sortMode: SnipSortMode = .chronological
    var errorMessage: String?

    init(
        library: any SnipLibrary,
        userActions: (any SnipLibraryUserActions)? = nil,
        recoveryScope: SnipRecoveryScope? = nil,
        initialSnapshot: SnipLibrarySnapshot = SnipLibrarySnapshot(
            snips: [],
            lists: [.inbox]
        ),
        startupError: String? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil,
        rebindUserActions: SnipLibraryUserActionsRebinder = .direct
    ) {
        self.library = library
        self.rebindUserActions = rebindUserActions
        self.userActions = userActions ?? rebindUserActions.actions(for: library)
        self.recoveryScope = recoveryScope
        self.cloudSyncHandler = cloudSyncHandler
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

    var selectedVisibleSnips: [Snip] {
        visibleSnips.filter { selectedSnipIDs.contains($0.id) }
    }

    var visibleSnips: [Snip] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = snips.filter { snip in
            guard snip.listID == selectedListID else { return false }
            switch completionFilter {
            case .all: break
            case .done: guard snip.isDone else { return false }
            case .notDone: guard !snip.isDone else { return false }
            }
            guard !needle.isEmpty else { return true }
            return snip.content.localizedCaseInsensitiveContains(needle)
                || snip.attachments.contains { $0.fileName.localizedCaseInsensitiveContains(needle) }
                || snip.displaySourceLabel.localizedCaseInsensitiveContains(needle)
                || snip.source?.url?.localizedCaseInsensitiveContains(needle) == true
        }
        return Snip.sorted(matches, by: sortMode)
    }

    var canReorderVisibleSnips: Bool {
        sortMode == .manual && completionFilter == .all
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var needsAttentionCount: Int { recoverySnapshot.needsAttentionCount }
    var pendingRecoveredSnips: [RecoveredSnip] { recoverySnapshot.pendingSnips }
    var pendingRecoveredLists: [RecoveredListEdit] { recoverySnapshot.pendingLists }

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
        await withSerializedMutation {
            self.library = library
            self.recoveryScope = recoveryScope
            self.userActions = rebindUserActions.actions(for: library)
            selectedSnipID = nil
            await loadUnlocked()
        }
    }

    @discardableResult
    func resolveRecovery(_ id: UUID, choice: SnipRecoveryChoice) async -> Bool {
        await withSerializedMutation {
            await resolveRecoveryUnlocked(id, choice: choice)
        }
    }

    @discardableResult
    func createSnip(
        content: String,
        in listID: UUID,
        attachmentURLs: [URL] = []
    ) async -> Bool {
        await withSerializedMutation {
            await createSnipUnlocked(
                content: content,
                in: listID,
                attachmentURLs: attachmentURLs
            )
        }
    }

    @discardableResult
    func editSnip(
        _ snip: Snip,
        content: String,
        attachmentEdits: [SnipAttachmentEdit]? = nil
    ) async -> Bool {
        await withSerializedMutation {
            await editSnipUnlocked(
                snip,
                content: content,
                attachmentEdits: attachmentEdits
            )
        }
    }

    @discardableResult
    func deleteSnip(id: UUID) async -> Bool {
        await withSerializedMutation { await deleteSnips(ids: [id]) }
    }

    @discardableResult
    func deleteSelection() async -> Bool {
        await withSerializedMutation { await deleteSnips(ids: selectedVisibleSnipIDs) }
    }

    @discardableResult
    func moveSnip(id: UUID, to listID: UUID) async -> Bool {
        await withSerializedMutation { await moveSnipUnlocked(id: id, to: listID) }
    }

    @discardableResult
    func moveSelection(to listID: UUID) async -> Bool {
        await withSerializedMutation { await moveSelectionUnlocked(to: listID) }
    }

    @discardableResult
    func placeVisibleSnips(_ orderedIDs: [UUID]) async -> Bool {
        await withSerializedMutation { await placeVisibleSnipsUnlocked(orderedIDs) }
    }

    @discardableResult
    func moveSelection(by offset: Int) async -> Bool {
        await withSerializedMutation { await moveSelectionUnlocked(by: offset) }
    }

    @discardableResult
    func setSelectionDone(_ done: Bool) async -> Bool {
        await withSerializedMutation { await setSelectionDoneUnlocked(done) }
    }

    @discardableResult
    func toggleDone(id: UUID) async -> Bool {
        await withSerializedMutation { await toggleDoneUnlocked(id: id) }
    }

    @discardableResult
    func createList(name: String) async -> Bool {
        await withSerializedMutation { await createListUnlocked(name: name) }
    }

    @discardableResult
    func renameList(_ list: SnipList, name: String) async -> Bool {
        await withSerializedMutation { await renameListUnlocked(list, name: name) }
    }

    @discardableResult
    func deleteList(id: UUID) async -> Bool {
        await withSerializedMutation { await deleteListUnlocked(id: id) }
    }

    @discardableResult
    func undo() async -> Bool {
        await withSerializedMutation { await undoUnlocked() }
    }

    @discardableResult
    func redo() async -> Bool {
        await withSerializedMutation { await redoUnlocked() }
    }

    private func loadUnlocked() async {
        apply(await library.snapshot(sortedBy: sortMode))
        await loadDeviceActions()
        await loadRecoveries()
        await refreshAttachmentTransferStates()
    }

    private func resolveRecoveryUnlocked(
        _ id: UUID,
        choice: SnipRecoveryChoice
    ) async -> Bool {
        guard let recoveryScope else { return false }
        do {
            apply(try await library.resolveRecovery(id, in: recoveryScope, choice: choice))
            await loadRecoveries()
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
        attachmentURLs: [URL] = []
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
            name: "Add Snip"
        ) { outcome in
            if case .add(.added(let id)) = outcome {
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

    var hasCloudSync: Bool { isCloudSyncActive }

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
                errorMessage = "Snip Snap could not download that attachment. Please try again."
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
        guard let cloudSyncHandler else { return }
        do {
            try await cloudSyncHandler.clearDownloadedFiles()
            apply(await library.snapshot(sortedBy: .chronological))
            await refreshAttachmentTransferStates()
        } catch {
            errorMessage = "Snip Snap could not clear the downloaded files."
        }
    }

    func syncWhenPossible() async {
        await cloudSyncHandler?.syncWhenPossible()
        await load()
    }

    private func editSnipUnlocked(
        _ snip: Snip,
        content: String,
        attachmentEdits: [SnipAttachmentEdit]?
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
        return await performUserAction(
            command,
            name: "Edit Snip"
        )
    }

    private func moveSnipUnlocked(id: UUID, to listID: UUID) async -> Bool {
        return await performUserAction(
            .moveChronologically(ids: [id], to: listID),
            name: "Move"
        ) { _ in
            selectedListID = listID
            selectedSnipID = id
        }
    }

    private func moveSelectionUnlocked(to listID: UUID) async -> Bool {
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
        return await performUserAction(
            command,
            name: "Move"
        ) { _ in
            selectedSnipIDs = []
            selectedSnipID = nil
        }
    }

    private func placeVisibleSnipsUnlocked(_ orderedIDs: [UUID]) async -> Bool {
        guard canReorderVisibleSnips,
            Set(orderedIDs) == Set(visibleSnips.map(\.id)),
            orderedIDs.count == visibleSnips.count
        else { return false }
        let listID = selectedListID
        return await performUserAction(
            .place(ids: orderedIDs, in: listID, before: nil, basedOn: .manual),
            name: "Reorder"
        )
    }

    private func moveSelectionUnlocked(by offset: Int) async -> Bool {
        guard offset == -1 || offset == 1, canReorderVisibleSnips else { return false }
        let selected = selectedVisibleSnipIDs
        let orderedIDs = visibleSnips.map(\.id)
        guard !selected.isEmpty,
            let firstSelectedIndex = orderedIDs.firstIndex(where: selected.contains)
        else { return false }
        let movingIDs = orderedIDs.filter(selected.contains)
        let remainingIDs = orderedIDs.filter { !selected.contains($0) }
        let unselectedBefore = orderedIDs[..<firstSelectedIndex]
            .filter { !selected.contains($0) }.count
        let insertionIndex = min(max(unselectedBefore + offset, 0), remainingIDs.count)
        guard insertionIndex != unselectedBefore else { return false }
        var reordered = remainingIDs
        reordered.insert(contentsOf: movingIDs, at: insertionIndex)
        return await placeVisibleSnipsUnlocked(reordered)
    }

    private func setSelectionDoneUnlocked(_ done: Bool) async -> Bool {
        let ids = selectedVisibleSnipIDs
        guard !ids.isEmpty else { return false }
        return await performUserAction(
            .setDone(ids: ids, done: done),
            name: done ? "Mark Done" : "Mark Not Done"
        )
    }

    private func toggleDoneUnlocked(id: UUID) async -> Bool {
        guard let snip = snips.first(where: { $0.id == id }) else { return false }
        return await performUserAction(
            .setDone(ids: [id], done: !snip.isDone),
            name: snip.isDone ? "Mark Not Done" : "Mark Done"
        )
    }

    private func createListUnlocked(name: String) async -> Bool {
        await performUserAction(
            .createList(name: name, systemImage: "list.bullet"),
            name: "Create List"
        ) { outcome in
            if case .listCreated(let list) = outcome {
                selectedListID = list.id
                selectedSnipID = nil
                selectedSnipIDs = []
            }
        }
    }

    private func renameListUnlocked(_ list: SnipList, name: String) async -> Bool {
        await performUserAction(
            .updateList(id: list.id, name: name, systemImage: list.systemImage),
            name: "Rename List"
        )
    }

    private func deleteListUnlocked(id: UUID) async -> Bool {
        guard lists.contains(where: { $0.id == id }) else { return false }
        return await performUserAction(
            .deleteList(id: id),
            name: "Delete List"
        ) { _ in
            selectedListID = SnipList.inboxID
            selectedSnipID = nil
            selectedSnipIDs = []
        }
    }

    private func undoUnlocked() async -> Bool {
        do {
            guard let update = try await userActions.undo(sortedBy: sortMode) else {
                await loadDeviceActions()
                return false
            }
            apply(update.snapshot)
            await loadDeviceActions()
            await loadRecoveries()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await loadDeviceActions()
            return false
        }
    }

    private func redoUnlocked() async -> Bool {
        do {
            guard let update = try await userActions.redo(sortedBy: sortMode) else {
                await loadDeviceActions()
                return false
            }
            apply(update.snapshot)
            await loadDeviceActions()
            await loadRecoveries()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await loadDeviceActions()
            return false
        }
    }

    private var selectedVisibleSnipIDs: Set<UUID> {
        selectedSnipIDs.intersection(visibleSnips.map(\.id))
    }

    private func deleteSnips(ids: Set<UUID>) async -> Bool {
        guard !ids.isEmpty else { return false }
        return await performUserAction(
            .delete(ids: ids),
            name: "Delete"
        ) { _ in
            if let selectedSnipID, ids.contains(selectedSnipID) { self.selectedSnipID = nil }
            selectedSnipIDs.subtract(ids)
        }
    }

    private func performUserAction(
        _ command: SnipLibraryCommand,
        name: String,
        afterSuccess: (SnipLibraryOutcome) -> Void = { _ in }
    ) async -> Bool {
        do {
            let update = try await userActions.perform(
                name: name,
                command: command,
                sortedBy: sortMode
            )
            apply(update.snapshot)
            await loadDeviceActions()
            await loadRecoveries()
            await refreshAttachmentTransferStates()
            afterSuccess(update.outcome)
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    var canUndo: Bool { deviceActionState.canUndo }
    var canRedo: Bool { deviceActionState.canRedo }
    var undoTitle: String { deviceActionState.undoTitle }
    var redoTitle: String { deviceActionState.redoTitle }

    var importPreviewSummary: String {
        guard let preview = pendingImportPreview else { return "" }
        var parts = ["\(preview.totalSnipCount) snips"]
        if preview.addedSnipCount > 0 { parts.append("\(preview.addedSnipCount) new") }
        if preview.recoveredSnipCount > 0 {
            parts.append("\(preview.recoveredSnipCount) recovered edits")
        }
        if preview.addedListCount > 0 {
            let noun = preview.addedListCount == 1 ? "list" : "lists"
            parts.append("\(preview.addedListCount) new \(noun)")
        }
        if preview.addedAttachmentCount > 0 {
            parts.append("\(preview.addedAttachmentCount) attachments")
        }
        return parts.joined(separator: ", ")
    }

    func previewBackupImport(from url: URL) async {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            pendingImportPreview = try await userActions.previewImport(backupURL: url)
        } catch {
            pendingImportPreview = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func cancelBackupImport() {
        pendingImportPreview = nil
    }

    func confirmBackupImport() async {
        guard let preview = pendingImportPreview else { return }
        do {
            let result = try await userActions.applyImport(preview, sortedBy: .chronological)
            pendingImportPreview = nil
            apply(result.snapshot)
            await loadDeviceActions()
            await loadRecoveries()
        } catch {
            pendingImportPreview = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await load()
        }
    }

    private func loadDeviceActions() async {
        do {
            deviceActionState = try await userActions.state(sortedBy: .chronological)
        } catch {
            deviceActionState = SnipDeviceActionState(
                undoTitle: "Undo",
                redoTitle: "Redo"
            )
        }
    }

    private func loadRecoveries() async {
        guard let recoveryScope else {
            recoverySnapshot = .empty
            return
        }
        do {
            recoverySnapshot = try await library.recoverySnapshot(in: recoveryScope)
        } catch {
            recoverySnapshot = .empty
        }
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

    private func withSerializedMutation<Result>(
        _ operation: () async -> Result
    ) async -> Result {
        await acquireMutationTurn()
        let result = await operation()
        releaseMutationTurn()
        return result
    }

    private func acquireMutationTurn() async {
        guard mutationInProgress else {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationTurn() {
        guard !mutationWaiters.isEmpty else {
            mutationInProgress = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }

}
