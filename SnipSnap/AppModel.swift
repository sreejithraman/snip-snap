import AppKit
import Combine
import Foundation
import SnipSnapCore
import UniformTypeIdentifiers

enum MacBackupImportPickerPolicy {
    static let allowedContentTypes: [UTType] = [.folder, .json]
    static let canChooseFiles = true
    static let canChooseDirectories = true
    static let message = "Choose a backup folder to include attachments, or a plain JSON file for a text-only backup."
}

private actor AppModelCommandLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

@MainActor
final class AppModel: ObservableObject {

    private struct HistoryPresentation {
        let beforeSortMode: SnipSortMode
        let afterSortMode: SnipSortMode
        let beforeSelection: Set<UUID>
        let afterSelection: Set<UUID>
    }

    static let sortModeDefaultsKey = "snipSortMode"
    static let activeListDefaultsKey = "activeListID"
    static let listDraftsDefaultsKey = "listDrafts"
    static let appearanceDefaultsKey = "appAppearance"
    private static let legacySortModeDefaultsKey = "clipSortMode"
    private static let legacyActiveListDefaultsKey = "activeSectionID"
    private static let legacyListDraftsDefaultsKey = "sectionDrafts"

    @Published private(set) var snips: [Snip] = []
    @Published private(set) var lists: [SnipList] = [.inbox]
    @Published var activeListID: UUID
    @Published var isShowingClipboard = false
    @Published var query = ""
    @Published var completionFilter: SnipCompletionFilter = .all
    @Published var selection: Set<UUID> = []
    @Published var editingID: UUID?
    @Published var presentedError: String?
    @Published var isAccessibilityAccessExplanationPresented = false
    @Published private(set) var latestAddedSnipID: UUID?
    @Published private(set) var sortMode: SnipSortMode
    @Published private(set) var appearance: AppAppearance
    @Published private(set) var recoverySnapshot: SnipRecoverySnapshot = .empty
    @Published private var deviceActionState = SnipDeviceActionState(
        undoTitle: "Undo",
        redoTitle: "Redo"
    )
    private var historyPresentations: [UUID: HistoryPresentation] = [:]
    @Published private(set) var pendingImportPreview: SnipImportPreview?

    var undoTitle: String {
        deviceActionState.undoTitle
    }

    var redoTitle: String {
        deviceActionState.redoTitle
    }

    var canUndo: Bool { deviceActionState.canUndo }
    var canRedo: Bool { deviceActionState.canRedo }
    var canReorderSelection: Bool { canReorder(ids: selection) }

    func canReorder(ids: Set<UUID>) -> Bool {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              completionFilter == .all,
              !ids.isEmpty else { return false }
        return Set(snips.filter { ids.contains($0.id) }.map(\.listID)).count == 1
    }

    private var library: any SnipLibrary
    private var recoveryScope: SnipRecoveryScope?
    @Published private var attachmentURLs: [UUID: URL] = [:]
    private var cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private var userActions: any SnipLibraryUserActions
    private let rebindUserActions: SnipLibraryUserActionsRebinder
    private let defaults: UserDefaults
    private let commandLock = AppModelCommandLock()
    private let composerDrafts: ComposerDraftStore
    let clipboardHistory: ClipboardHistory

    var filteredSnips: [Snip] {
        let matches = SnipFilter.apply(
            snips: snips,
            query: query,
            completionFilter: completionFilter,
            listNames: Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.name) })
        )
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return matches.filter { $0.listID == activeList.id }
        }
        return matches
    }

    var selectedSnips: [Snip] {
        let selected = selection
        return snips.filter { selected.contains($0.id) }
    }

    var clipboardSearchMatches: [ClipboardEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return clipboardHistory.entries.filter {
            $0.searchText.localizedCaseInsensitiveContains(needle)
        }
    }

    var activeList: SnipList {
        lists.first(where: { $0.id == activeListID }) ?? .inbox
    }

    func attachmentURL(for attachment: SnipAttachment) -> URL? {
        attachmentURLs[attachment.id]
    }

    init(
        library: any SnipLibrary,
        defaults: UserDefaults = .standard,
        clipboardHistory: ClipboardHistory? = nil,
        initialError: String? = nil,
        recoveryScope: SnipRecoveryScope? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil,
        userActions: (any SnipLibraryUserActions)? = nil,
        rebindUserActions: SnipLibraryUserActionsRebinder = .direct
    ) {
        Self.migrateRenamedDefaults(in: defaults)
        self.defaults = defaults
        composerDrafts = ComposerDraftStore(
            defaults: defaults,
            textDefaultsKey: Self.listDraftsDefaultsKey
        )
        self.clipboardHistory = clipboardHistory ?? ClipboardHistory()
        activeListID = defaults.string(forKey: Self.activeListDefaultsKey)
            .flatMap(UUID.init(uuidString:)) ?? SnipList.inboxID
        sortMode = SnipSortMode(
            rawValue: defaults.string(forKey: Self.sortModeDefaultsKey) ?? ""
        ) ?? .chronological
        appearance = AppAppearance(
            rawValue: defaults.string(forKey: Self.appearanceDefaultsKey) ?? ""
        ) ?? .system
        self.library = library
        self.rebindUserActions = rebindUserActions
        self.userActions = userActions ?? rebindUserActions.actions(for: library)
        self.recoveryScope = recoveryScope
        self.cloudSyncHandler = cloudSyncHandler
        presentedError = initialError
        Task { await reload() }
    }

    func setCloudSyncHandler(_ handler: (any OptionalCloudSyncHandling)?) {
        cloudSyncHandler = handler
    }

    func prepareAttachments(
        _ attachments: [SnipAttachment],
        for use: SyncedAttachmentUse
    ) async throws -> [UUID: URL] {
        var prepared: [UUID: URL] = [:]
        for attachment in uniqueAttachments(in: attachments) {
            if let cached = attachmentURLs[attachment.id],
               isAvailablePreparedAttachment(cached) {
                prepared[attachment.id] = cached
                continue
            }
            attachmentURLs[attachment.id] = nil
            guard let cloudSyncHandler else {
                throw SnipLibraryError.attachmentCopyFailed
            }
            let url = try await cloudSyncHandler.prepareSyncedAttachment(
                attachment.id,
                for: use
            )
            attachmentURLs[attachment.id] = url
            prepared[attachment.id] = url
        }
        return prepared
    }

    func prepareAttachmentPreview(
        _ attachments: [SnipAttachment],
        selected: SnipAttachment
    ) async throws -> (urls: [URL], selectedURL: URL)? {
        let prepared = try await prepareAttachments(attachments, for: .preview)
        let urls = uniqueAttachments(in: attachments).compactMap { prepared[$0.id] }
        guard let selectedURL = prepared[selected.id] else { return nil }
        return (urls, selectedURL)
    }

    private func uniqueAttachments(
        in attachments: [SnipAttachment]
    ) -> [SnipAttachment] {
        var seen: Set<UUID> = []
        return attachments.filter { seen.insert($0.id).inserted }
    }

    private func isAvailablePreparedAttachment(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    @discardableResult
    func prepareAttachmentsForExternalDrag(snipIDs: [UUID]) async -> Bool {
        let ids = Set(snipIDs)
        let attachments = snips
            .filter { ids.contains($0.id) }
            .flatMap(\.attachments)
        do {
            _ = try await prepareAttachments(attachments, for: .export)
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    private static func migrateRenamedDefaults(in defaults: UserDefaults) {
        // TODO: Remove legacy defaults migration after the 1.0 migration window.
        let renamedKeys = [
            (legacySortModeDefaultsKey, sortModeDefaultsKey),
            (legacyActiveListDefaultsKey, activeListDefaultsKey),
            (legacyListDraftsDefaultsKey, listDraftsDefaultsKey),
        ]
        for (oldKey, newKey) in renamedKeys
        where defaults.object(forKey: newKey) == nil {
            guard let value = defaults.object(forKey: oldKey) else { continue }
            defaults.set(value, forKey: newKey)
        }
    }

    func reload() async {
        await withCommandLock { await reloadUnlocked() }
    }

    func replaceLibrary(
        _ library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope?
    ) async {
        await withCommandLock {
            self.library = library
            self.recoveryScope = recoveryScope
            self.userActions = rebindUserActions.actions(for: library)
            selection = []
            editingID = nil
            await reloadUnlocked()
        }
    }

    func exportArchive() async throws -> SnipLibraryArchive {
        let prepared = try await prepareAttachments(
            snips.flatMap(\.attachments),
            for: .export
        )
        let archive = try await library.archive()
        return SnipLibraryArchive(
            snips: archive.snips,
            lists: archive.lists,
            seenRequestIDs: archive.seenRequestIDs,
            attachmentURLs: archive.attachmentURLs.merging(prepared) { _, ready in ready }
        )
    }

    private func reloadUnlocked() async {
        let snapshot = await library.snapshot(sortedBy: sortMode)
        await refreshDeviceActionStateUnlocked()
        apply(snapshot)
        await refreshRecoveryUnlocked()
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

    func refreshRecovery() async {
        await withCommandLock {
            let snapshot = await library.snapshot(sortedBy: sortMode)
            apply(snapshot)
            await refreshRecoveryUnlocked()
        }
    }

    @discardableResult
    func resolveRecovery(_ id: UUID, choice: SnipRecoveryChoice) async -> Bool {
        guard let recoveryScope else { return false }
        return await withCommandLock {
            do {
                apply(try await library.resolveRecovery(id, in: recoveryScope, choice: choice))
                await refreshRecoveryUnlocked()
                return true
            } catch {
                presentedError = error.localizedDescription
                await reloadUnlocked()
                return false
            }
        }
    }

    private func refreshRecoveryUnlocked() async {
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
        if !lists.contains(where: { $0.id == activeListID }) {
            activeListID = SnipList.inboxID
            defaults.set(SnipList.inboxID.uuidString, forKey: Self.activeListDefaultsKey)
        }
        selection.formIntersection(Set(snips.map(\.id)))
    }

    func setSortMode(_ mode: SnipSortMode) {
        guard sortMode != mode else { return }
        sortMode = mode
        defaults.set(mode.rawValue, forKey: Self.sortModeDefaultsKey)
        snips = Snip.sorted(snips, by: mode)
    }

    func setAppearance(_ appearance: AppAppearance) {
        guard self.appearance != appearance else { return }
        self.appearance = appearance
        defaults.set(appearance.rawValue, forKey: Self.appearanceDefaultsKey)
    }

    @discardableResult
    func add(
        content: String,
        origin: SnipOrigin,
        source: SnipSource? = nil,
        attachmentURLs: [URL] = [],
        listID: UUID? = nil,
        requestID: UUID = UUID()
    ) async -> Bool {
        switch await addResult(
            content: content,
            origin: origin,
            source: source,
            attachmentURLs: attachmentURLs,
            listID: listID,
            requestID: requestID
        ) {
        case .success(.added):
            return true
        case .success(.duplicate):
            return false
        case .failure(let error):
            presentedError = error.localizedDescription
            return false
        }
    }

    func addResult(
        content: String,
        origin: SnipOrigin,
        source: SnipSource? = nil,
        attachmentURLs: [URL] = [],
        listID: UUID? = nil,
        requestID: UUID = UUID()
    ) async -> Result<SnipAddOutcome, Error> {
        await withCommandLock {
            let result = await performMutationUnlocked(clearingHistory: false) {
                let update = try await library.perform(
                    .add(
                        content: content,
                        origin: origin,
                        source: source,
                        listID: listID ?? activeList.id,
                        attachmentURLs: attachmentURLs,
                        requestID: requestID,
                        now: Date()
                    ),
                    sortedBy: sortMode
                )
                return (update, update)
            }
            switch result {
            case .success(let update):
                guard case .add(let outcome) = update.outcome else {
                    preconditionFailure("The library returned the wrong add outcome.")
                }
                switch outcome {
                case .added(let id):
                    latestAddedSnipID = id
                    await clearHistory()
                    return .success(.added(id))
                case .duplicate:
                    return .success(.duplicate)
                }
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    func update(
        id: UUID,
        content: String,
        attachmentURLs: [URL]? = nil,
        expectedUpdatedAt: Date? = nil
    ) async -> Bool {
        switch await updateResult(
            id: id,
            content: content,
            attachmentURLs: attachmentURLs,
            expectedUpdatedAt: expectedUpdatedAt
        ) {
        case .success:
            return true
        case .failure(let error):
            presentedError = error.localizedDescription
            return false
        }
    }

    func updateResult(
        id: UUID,
        content: String,
        attachmentURLs: [URL]? = nil,
        expectedUpdatedAt: Date? = nil
    ) async -> Result<Void, Error> {
        await performMutation {
            let update = try await library.perform(
                .update(
                    id: id,
                    content: content,
                    attachmentURLs: attachmentURLs,
                    expectedUpdatedAt: expectedUpdatedAt,
                    now: Date()
                ),
                sortedBy: sortMode
            )
            return (update, ())
        }
    }

    func selectList(_ list: SnipList, preservingSelection: Bool = false) {
        activeListID = list.id
        defaults.set(list.id.uuidString, forKey: Self.activeListDefaultsKey)
        isShowingClipboard = false
        if !preservingSelection { selection = [] }
    }

    func showClipboard() {
        isShowingClipboard = true
        selection = []
    }

    func composerDraft(for listID: UUID) -> ComposerDraft {
        composerDrafts.draft(for: listID)
    }

    func saveComposerText(_ text: String, for listID: UUID) {
        composerDrafts.setText(text, for: listID)
    }

    func flushComposerDrafts() {
        composerDrafts.flushText()
    }

    func addDraftAttachments(_ urls: [URL], to listID: UUID) {
        composerDrafts.add(urls, to: listID)
    }

    func addTemporaryDraftAttachment(_ url: URL, to listID: UUID) {
        composerDrafts.addTemporary(url, to: listID)
    }

    func stageScreenCapture() -> URL {
        composerDrafts.stageScreenCapture()
    }

    func finishScreenCapture(_ url: URL, in listID: UUID, succeeded: Bool) {
        composerDrafts.finishScreenCapture(url, in: listID, succeeded: succeeded)
    }

    func removeDraftAttachment(_ url: URL, from listID: UUID) {
        composerDrafts.remove(url, from: listID)
    }

    func clearDraft(for listID: UUID) {
        composerDrafts.clear(listID: listID)
    }

    func saveComposerDraft(content: String, listID: UUID) async -> Bool {
        composerDrafts.setText(content, for: listID)
        let snapshot = composerDrafts.beginSave(listID: listID)
        let saved = await add(
            content: snapshot.draft.text,
            origin: .quickEntry,
            attachmentURLs: snapshot.draft.attachments,
            listID: listID
        )
        composerDrafts.finishSave(snapshot, saved: saved)
        return saved
    }

    func createList(
        name: String,
        systemImage: String,
        movingIDs: Set<UUID> = []
    ) async -> Bool {
        let result = await performMutation(clearingHistory: false) {
            let update = try await library.perform(
                .createList(name: name, systemImage: systemImage),
                sortedBy: sortMode
            )
            guard case .listCreated(let list) = update.outcome else {
                preconditionFailure("The library returned the wrong list outcome.")
            }
            return (update, list)
        }
        switch result {
        case .success(let list):
            selectList(list, preservingSelection: !movingIDs.isEmpty)
            guard !movingIDs.isEmpty else { return true }
            let orderedIDs = snips.filter { movingIDs.contains($0.id) }.map(\.id)
            return await moveToList(
                ids: orderedIDs,
                listID: list.id,
                selectionAfterMove: movingIDs
            )
        case .failure(let error):
            presentedError = error.localizedDescription
            return false
        }
    }

    func deleteList(_ list: SnipList) async {
        guard list.id != SnipList.inboxID else { return }
        let result = await performMutation {
            let update = try await library.perform(.deleteList(id: list.id), sortedBy: sortMode)
            return (update, ())
        }
        if case .failure(let error) = result {
            presentedError = error.localizedDescription
        } else {
            clearDraft(for: list.id)
        }
    }

    func updateList(_ list: SnipList, name: String, systemImage: String) async -> Bool {
        let result = await performMutation {
            let update = try await library.perform(
                .updateList(id: list.id, name: name, systemImage: systemImage),
                sortedBy: sortMode
            )
            return (update, ())
        }
        if case .failure(let error) = result {
            presentedError = error.localizedDescription
            return false
        }
        return true
    }

    func saveClipboardEntry(
        _ entry: ClipboardEntry,
        listID: UUID? = nil,
        before destinationID: UUID? = nil,
        placesManually: Bool = false
    ) async -> Bool {
        let materialization: ClipboardSnipMaterialization
        do {
            materialization = try await Task.detached(priority: .utility) {
                try entry.materializeForSnip()
            }.value
        } catch {
            presentedError = "Snip Snap could not prepare the clipboard image."
            return false
        }
        defer { materialization.removeTemporaryFiles() }
        let targetListID = listID ?? activeListID
        let result = await addResult(
            content: materialization.text,
            origin: .clipboard,
            source: materialization.source,
            attachmentURLs: materialization.fileURLs,
            listID: targetListID
        )
        switch result {
        case .success(.added(let id)):
            guard placesManually else { return true }
            return await move(ids: [id], to: targetListID, before: destinationID)
        case .success(.duplicate):
            return false
        case .failure(let error):
            presentedError = error.localizedDescription
            return false
        }
    }

    func deleteSelection() {
        Task { await deleteSelectionNow() }
    }

    func deleteSelectionNow() async {
        let ids = selection
        let snipsToDelete = selectedSnips
        guard !ids.isEmpty, !snipsToDelete.isEmpty else { return }
        let result = await performHistoryCommand(
            name: "Delete",
            command: .delete(ids: ids),
            afterSelection: { _ in [] }
        )
        switch result {
        case .success:
            selection = []
        case .failure(let error):
            presentedError = error.localizedDescription
        }
    }

    func undo() {
        Task { await undoNow() }
    }

    func undoNow() async {
        await withCommandLock {
            await refreshDeviceActionStateUnlocked()
            guard deviceActionState.canUndo else { return }
            do {
                guard let update = try await userActions.undo(sortedBy: sortMode) else {
                    await refreshDeviceActionStateUnlocked()
                    return
                }
                apply(update.snapshot)
                await refreshDeviceActionStateUnlocked()
                let presentation = deviceActionState.redoActionIDs.last.flatMap {
                    historyPresentations[$0]
                }
                if let presentation {
                    setSortMode(presentation.beforeSortMode)
                    selection = presentation.beforeSelection
                }
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    func redo() {
        Task { await redoNow() }
    }

    func redoNow() async {
        await withCommandLock {
            await refreshDeviceActionStateUnlocked()
            guard deviceActionState.canRedo else { return }
            do {
                guard let update = try await userActions.redo(sortedBy: sortMode) else {
                    await refreshDeviceActionStateUnlocked()
                    return
                }
                apply(update.snapshot)
                await refreshDeviceActionStateUnlocked()
                let presentation = deviceActionState.undoActionIDs.last.flatMap {
                    historyPresentations[$0]
                }
                if let presentation {
                    setSortMode(presentation.afterSortMode)
                    selection = presentation.afterSelection
                }
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

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

    func beginBackupImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Backup"
        panel.prompt = "Review Backup"
        panel.message = MacBackupImportPickerPolicy.message
        panel.allowedContentTypes = MacBackupImportPickerPolicy.allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = MacBackupImportPickerPolicy.canChooseFiles
        panel.canChooseDirectories = MacBackupImportPickerPolicy.canChooseDirectories
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in await self?.previewBackupImport(from: url) }
        }
    }

    func previewBackupImport(from url: URL) async {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            pendingImportPreview = try await userActions.previewImport(backupURL: url)
        } catch {
            pendingImportPreview = nil
            presentedError = error.localizedDescription
        }
    }

    func cancelBackupImport() {
        pendingImportPreview = nil
    }

    func confirmBackupImport() async {
        guard let preview = pendingImportPreview else { return }
        await withCommandLock {
            do {
                let result = try await userActions.applyImport(preview, sortedBy: sortMode)
                pendingImportPreview = nil
                apply(result.snapshot)
                await refreshDeviceActionStateUnlocked()
                await refreshRecoveryUnlocked()
            } catch {
                pendingImportPreview = nil
                presentedError = error.localizedDescription
                await reloadUnlocked()
            }
        }
    }

    func toggleDoneSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        Task {
            await performUserMutation {
                let update = try await library.perform(.toggleDoneMany(ids: ids), sortedBy: sortMode)
                return (update, ())
            }
        }
    }

    func toggleDone(id: UUID) {
        Task { await toggleDoneNow(id: id) }
    }

    func toggleDoneNow(id: UUID) async {
        await performUserMutation {
            let update = try await library.perform(.toggleDone(id: id), sortedBy: sortMode)
            return (update, ())
        }
    }

    func markDoneAfterExternalDrop(ids: [UUID]) {
        Task { await markDoneAfterExternalDropNow(ids: Set(ids)) }
    }

    func markDoneAfterExternalDropNow(ids: Set<UUID>) async {
        let unfinishedIDs = Set(
            snips.lazy
                .filter { ids.contains($0.id) && !$0.isDone }
                .map(\.id)
        )
        guard !unfinishedIDs.isEmpty else { return }
        await performUserMutation {
            let update = try await library.perform(
                .setDone(ids: unfinishedIDs, done: true),
                sortedBy: sortMode
            )
            return (update, ())
        }
    }

    func moveSelection(to listID: UUID) {
        let ids = snips.filter { selection.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            _ = await moveToList(ids: ids, listID: listID)
        }
    }

    @discardableResult
    func moveToList(
        ids: [UUID],
        listID: UUID,
        selectionAfterMove: Set<UUID>? = nil
    ) async -> Bool {
        if sortMode == .manual {
            let movingIDs = Set(ids)
            let firstID = snips.first {
                $0.listID == listID && !movingIDs.contains($0.id)
            }?.id
            return await move(
                ids: ids,
                to: listID,
                before: firstID,
                selectionAfterMove: selectionAfterMove
            )
        }
        return await moveChronologically(
            ids: ids,
            to: listID,
            selectionAfterMove: selectionAfterMove
        )
    }

    @discardableResult
    func move(
        ids: [UUID],
        to listID: UUID,
        before destinationID: UUID?,
        selectionAfterMove: Set<UUID>? = nil
    ) async -> Bool {
        let selectedIDs = Set(ids)
        guard !ids.isEmpty else { return false }
        let currentSortMode = sortMode
        let finalSelection = selectionAfterMove ?? selectedIDs
        let result = await performHistoryCommand(
            name: "Move",
            command: .place(
                ids: ids,
                in: listID,
                before: destinationID,
                basedOn: currentSortMode
            ),
            afterSelection: { _ in finalSelection },
            afterSortMode: .manual
        )
        if case .success = result {
            selection = finalSelection
            return true
        }
        if case .failure(let error) = result { presentedError = error.localizedDescription }
        return false
    }

    @discardableResult
    func moveChronologically(
        ids: [UUID],
        to listID: UUID,
        selectionAfterMove: Set<UUID>? = nil
    ) async -> Bool {
        let selectedIDs = Set(ids)
        guard !ids.isEmpty else { return false }
        let finalSelection = selectionAfterMove ?? selectedIDs
        let result = await performHistoryCommand(
            name: "Move",
            command: .moveChronologically(ids: ids, to: listID),
            afterSelection: { _ in finalSelection }
        )
        if case .success = result {
            selection = finalSelection
            return true
        }
        if case .failure(let error) = result { presentedError = error.localizedDescription }
        return false
    }

    func moveSelectionUp() { Task { await moveSelectionNow(by: -1) } }
    func moveSelectionDown() { Task { await moveSelectionNow(by: 1) } }

    func moveSelectionNow(by offset: Int) async {
        guard offset == -1 || offset == 1 else { return }
        let selectedIDs = Set(selection)
        guard canReorder(ids: selectedIDs) else { return }
        let lists = Set(snips.filter { selectedIDs.contains($0.id) }.map(\.listID))
        guard let listID = lists.first else { return }
        let ids = snips.filter { $0.listID == listID }.map(\.id)
        guard let firstSelectedIndex = ids.firstIndex(where: selectedIDs.contains) else { return }
        let movingIDs = ids.filter(selectedIDs.contains)
        let remainingIDs = ids.filter { !selectedIDs.contains($0) }
        let unselectedBefore = ids[..<firstSelectedIndex].filter { !selectedIDs.contains($0) }.count
        let insertionIndex = min(
            max(unselectedBefore + offset, 0),
            remainingIDs.count
        )
        guard insertionIndex != unselectedBefore else { return }
        let destinationID = insertionIndex < remainingIDs.count ? remainingIDs[insertionIndex] : nil
        _ = await move(ids: movingIDs, to: listID, before: destinationID)
    }

    func selectAllVisible() {
        selection = Set(filteredSnips.map(\.id))
    }

    func beginEditingSelection() {
        Task { await beginEditingSelectionNow() }
    }

    @discardableResult
    func beginEditingSelectionNow() async -> Bool {
        guard let snip = filteredSnips.first(where: { selection.contains($0.id) }) else {
            return false
        }
        return await beginEditing(snip.id)
    }

    @discardableResult
    func beginEditing(_ id: UUID) async -> Bool {
        guard let snip = snips.first(where: { $0.id == id }) else { return false }
        do {
            _ = try await prepareAttachments(snip.attachments, for: .open)
            editingID = id
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func copySelection() -> Bool {
        guard !selectedSnips.isEmpty else { return false }
        Task { await copySelectionNow() }
        return true
    }

    @discardableResult
    func copySelectionNow(to pasteboard: NSPasteboard = .general) async -> Bool {
        let selected = selectedSnips
        guard !selected.isEmpty else { return false }
        let attachments = uniqueAttachments(in: selected.flatMap(\.attachments))
        let prepared: [UUID: URL]
        do {
            prepared = try await prepareAttachments(attachments, for: .copy)
        } catch {
            presentedError = error.localizedDescription
            return false
        }
        let text = SnipFormatter.formatForClipboard(snips: selected)
        let textItem = NSPasteboardItem()
        textItem.setString(text, forType: .string)
        textItem.setData(Data(), forType: ClipboardHistory.internalType)
        var objects: [NSPasteboardWriting] = [textItem]
        objects.append(contentsOf: attachments.compactMap { prepared[$0.id] as NSURL? })
        pasteboard.clearContents()
        return pasteboard.writeObjects(objects)
    }

    func clearDownloadedFiles() async throws {
        guard let cloudSyncHandler else { throw SnipLibraryError.transferUnsupported }
        try await cloudSyncHandler.clearDownloadedFiles()
        await reload()
    }

    func mergeSelection() {
        Task { await mergeSelectionNow() }
    }

    func mergeSelectionNow() async {
        let ids = selection
        let snipsToMerge = selectedSnips
        guard ids.count >= 2, snipsToMerge.count >= 2 else { return }
        let result = await performHistoryCommand(
            name: "Merge",
            command: .merge(ids: ids, now: Date()),
            afterSelection: { outcome in
                guard case .merged(let snip) = outcome else { return [] }
                return [snip.id]
            }
        )
        switch result {
        case .success(.merged(let mergedSnip)):
            selection = [mergedSnip.id]
        case .success:
            preconditionFailure("The library returned the wrong merge outcome.")
        case .failure(let error):
            presentedError = error.localizedDescription
        }
    }

    private func performMutation<Value>(
        clearingHistory: Bool = true,
        _ mutation: () async throws -> (SnipLibraryUpdate, Value)
    ) async -> Result<Value, Error> {
        await withCommandLock {
            await performMutationUnlocked(clearingHistory: clearingHistory, mutation)
        }
    }

    private func performMutationUnlocked<Value>(
        clearingHistory: Bool,
        _ mutation: () async throws -> (SnipLibraryUpdate, Value)
    ) async -> Result<Value, Error> {
        do {
            let (update, value) = try await mutation()
            apply(update.snapshot)
            if clearingHistory {
                await clearHistory()
            }
            return .success(value)
        } catch {
            return .failure(error)
        }
    }

    private func performUserMutation(
        _ mutation: () async throws -> (SnipLibraryUpdate, Void)
    ) async {
        if case .failure(let error) = await performMutation(mutation) {
            presentedError = error.localizedDescription
        }
    }

    private func performHistoryCommand(
        name: String,
        command: SnipLibraryCommand,
        afterSelection: ((SnipLibraryOutcome) -> Set<UUID>)? = nil,
        afterSortMode: SnipSortMode? = nil,
    ) async -> Result<SnipLibraryOutcome, Error> {
        await withCommandLock {
            let beforeSortMode = sortMode
            let beforeSelection = selection
            let priorUndoActionIDs = Set(deviceActionState.undoActionIDs)
            do {
                let update = try await userActions.perform(
                    name: name,
                    command: command,
                    sortedBy: sortMode
                )
                apply(update.snapshot)
                await refreshDeviceActionStateUnlocked()
                if let actionID = deviceActionState.undoActionIDs.last,
                   !priorUndoActionIDs.contains(actionID) {
                    let savedAfterSortMode = afterSortMode ?? sortMode
                    setSortMode(savedAfterSortMode)
                    let savedSelection = afterSelection?(update.outcome) ?? selection
                    selection = savedSelection
                    historyPresentations[actionID] = HistoryPresentation(
                        beforeSortMode: beforeSortMode,
                        afterSortMode: savedAfterSortMode,
                        beforeSelection: beforeSelection,
                        afterSelection: savedSelection
                    )
                }
                return .success(update.outcome)
            } catch {
                return .failure(error)
            }
        }
    }

    private func withCommandLock<Value>(
        _ operation: () async -> Value
    ) async -> Value {
        await commandLock.acquire()
        let value = await operation()
        await commandLock.release()
        return value
    }

    private func clearHistory() async {
        try? await userActions.clear(sortedBy: sortMode)
        historyPresentations = [:]
        deviceActionState = SnipDeviceActionState(
            undoTitle: "Undo",
            redoTitle: "Redo"
        )
    }

    private func refreshDeviceActionStateUnlocked() async {
        do {
            deviceActionState = try await userActions.state(sortedBy: sortMode)
            let retainedActionIDs = Set(
                deviceActionState.undoActionIDs + deviceActionState.redoActionIDs
            )
            historyPresentations = historyPresentations.filter {
                retainedActionIDs.contains($0.key)
            }
        } catch {
            historyPresentations = [:]
            deviceActionState = SnipDeviceActionState(
                undoTitle: "Undo",
                redoTitle: "Redo"
            )
        }
    }
}
