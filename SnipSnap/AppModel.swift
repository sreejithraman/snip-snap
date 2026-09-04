import AppKit
import Combine
import Foundation
import SnipSnapCore
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {

    static let sortModeDefaultsKey = "snipSortMode"
    static let activeListDefaultsKey = "activeListID"
    static let listDraftsDefaultsKey = "listDrafts"
    static let appearanceDefaultsKey = "appAppearance"

    @Published private(set) var snips: [Snip] = []
    @Published private(set) var lists: [SnipList] = [.inbox]
    @Published var activeListID: UUID
    @Published var isShowingClipboard = false
    @Published var query = ""
    @Published var completionFilter: SnipCompletionFilter = .all
    @Published var selection: Set<UUID> = []
    @Published var editingID: UUID?
    @Published var presentedError: String?
    @Published private(set) var latestAddedSnipID: UUID?
    @Published private(set) var sortMode: SnipSortMode
    @Published private(set) var appearance: AppAppearance
    @Published private(set) var recoverySnapshot: SnipRecoverySnapshot = .empty
    @Published private(set) var pendingImportPreview: SnipImportPreview?
    private var pendingImportPreviewID: UUID?
    @Published var toast: AppToast?
    @Published var clipboardCopyPulse: ClipboardCopyPulse?
    var canReorderSelection: Bool { canReorder(ids: selection) }

    func canReorder(ids: Set<UUID>) -> Bool {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              completionFilter == .all,
              !ids.isEmpty else { return false }
        return Set(snips.filter { ids.contains($0.id) }.map(\.listID)).count == 1
    }

    private let session: SavedSnipsSession
    private let attachmentPreparation: AttachmentPreparationCoordinator
    private var cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private let defaults: UserDefaults
    private let composerDrafts: ComposerDraftStore
    let clipboardHistory: ClipboardHistory

    var filteredSnips: [Snip] {
        let matches = SnipFilter.apply(
            snips: snips,
            query: query,
            completionFilter: completionFilter,
            listNames: Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.name) }),
            sourceLabel: { $0.displaySourceLabel }
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
        attachmentPreparation.cachedURL(for: attachment)
    }

    init(
        library: any SnipLibrary,
        defaults: UserDefaults = .standard,
        clipboardHistory: ClipboardHistory? = nil,
        initialError: String? = nil,
        recoveryScope: SnipRecoveryScope? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsRebinder: SnipLibraryUserActionsRebinder = .direct
    ) {
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
        session = SavedSnipsSession(
            library: library,
            userActions: userActions,
            userActionsRebinder: userActionsRebinder,
            recoveryScope: recoveryScope
        )
        attachmentPreparation = AttachmentPreparationCoordinator(
            cloudSyncHandler: cloudSyncHandler
        )
        self.cloudSyncHandler = cloudSyncHandler
        presentedError = initialError
        Task { await reload() }
    }

    func setCloudSyncHandler(_ handler: (any OptionalCloudSyncHandling)?) {
        cloudSyncHandler = handler
        attachmentPreparation.setCloudSyncHandler(handler)
    }

    func prepareAttachments(
        _ attachments: [SnipAttachment],
        for use: SyncedAttachmentUse
    ) async throws -> [UUID: URL] {
        try await attachmentPreparation.prepare(attachments, for: use)
    }

    func prepareAttachmentPreview(
        _ attachments: [SnipAttachment],
        selected: SnipAttachment
    ) async throws -> (urls: [URL], selectedURL: URL)? {
        try await attachmentPreparation.preparePreview(attachments, selected: selected)
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

    func reload() async {
        await withCommandLock { await reloadUnlocked() }
    }

    func replaceLibrary(
        _ library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope?
    ) async {
        await withCommandLock {
            clearPendingDeletionToast()
            selection = []
            editingID = nil
            apply(await session.replaceLibrary(
                library,
                recoveryScope: recoveryScope,
                sortedBy: sortMode
            ))
        }
    }

    func exportArchive() async throws -> SnipLibraryArchive {
        let prepared = try await prepareAttachments(
            snips.flatMap(\.attachments),
            for: .export
        )
        let archive = try await session.withExclusiveAccess { session in
            try await session.archive()
        }
        return SnipLibraryArchive(
            snips: archive.snips,
            lists: archive.lists,
            seenRequestIDs: archive.seenRequestIDs,
            attachmentURLs: archive.attachmentURLs.merging(prepared) { _, ready in ready }
        )
    }

    private func reloadUnlocked() async {
        apply(await session.state(sortedBy: sortMode))
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
            apply(await session.state(sortedBy: sortMode))
        }
    }

    @discardableResult
    func resolveRecovery(_ id: UUID, choice: SnipRecoveryChoice) async -> Bool {
        return await withCommandLock {
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
                presentedError = error.localizedDescription
                await reloadUnlocked()
                return false
            }
        }
    }

    private func apply(_ state: SavedSnipsSessionState) {
        apply(state.library)
        recoverySnapshot = state.recovery
    }

    private func apply(_ snapshot: SnipLibrarySnapshot) {
        snips = snapshot.snips
        lists = snapshot.lists
        attachmentPreparation.replaceCachedURLs(with: snapshot.attachmentURLs)
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
            let result = await performMutationUnlocked {
                let update = try await session.performLibraryCommand(
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
            let update = try await session.performLibraryCommand(
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
        let result = await performMutation {
            let update = try await session.performLibraryCommand(
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
            let update = try await session.performLibraryCommand(
                .deleteList(id: list.id),
                sortedBy: sortMode
            )
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
            let update = try await session.performLibraryCommand(
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
            presentedError = String(localized: "Snip Snap could not prepare the clipboard image.")
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
        let token = UUID()
        await withCommandLock {
            do {
                let update = try await session.delete(
                    ids: ids,
                    token: token,
                    sortedBy: sortMode
                )
                apply(update.snapshot)
                selection = []
                toast = .deleted(count: snipsToDelete.count, id: token)
                scheduleCloudSync()
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    func performToastAction(_ presentedToast: AppToast) {
        Task { await performToastActionNow(presentedToast) }
    }

    func performToastActionNow(_ presentedToast: AppToast) async {
        guard presentedToast.action == .undoDelete else { return }
        await restoreDeletion(token: presentedToast.id)
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

    private func restoreDeletion(token: UUID) async {
        await withCommandLock {
            do {
                guard let update = try await session.restoreDeletion(
                    token: token,
                    sortedBy: sortMode
                ) else { return }
                apply(update.snapshot)
                if toast?.id == token { toast = nil }
                scheduleCloudSync()
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    var importPreviewSummary: String {
        pendingImportPreview?.localizedSummary ?? ""
    }

    func beginBackupImport() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Backup")
        panel.prompt = String(localized: "Review Backup")
        panel.message = String(localized: "Choose a backup folder to include attachments, or a plain JSON file for a text-only backup.")
        panel.allowedContentTypes = [.folder, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.previewBackupImport(from: url) }
        }
    }

    func previewBackupImport(from url: URL) async {
        await withCommandLock {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let preview = try await session.previewImport(from: url)
                pendingImportPreviewID = preview.id
                pendingImportPreview = preview.value
            } catch {
                pendingImportPreviewID = nil
                pendingImportPreview = nil
                presentedError = error.localizedDescription
            }
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
        guard pendingImportPreview != nil, let id = pendingImportPreviewID else { return }
        await withCommandLock {
            do {
                guard let (result, recovery) = try await session.applyPendingImport(
                    id: id,
                    sortedBy: sortMode
                ) else { return }
                clearPendingDeletionToast()
                pendingImportPreviewID = nil
                pendingImportPreview = nil
                apply(result.snapshot)
                recoverySnapshot = recovery
                scheduleCloudSync()
            } catch {
                pendingImportPreviewID = nil
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
                let update = try await session.performLibraryCommand(
                    .toggleDoneMany(ids: ids),
                    sortedBy: sortMode
                )
                return (update, ())
            }
        }
    }

    func toggleDone(id: UUID) {
        Task { await toggleDoneNow(id: id) }
    }

    func toggleDoneNow(id: UUID) async {
        await performUserMutation {
            let update = try await session.performLibraryCommand(
                .toggleDone(id: id),
                sortedBy: sortMode
            )
            return (update, ())
        }
    }

    func setDoneAfterExternalDrop(ids: [UUID]) {
        Task { await setDoneAfterExternalDropNow(ids: Set(ids)) }
    }

    func setDoneAfterExternalDropNow(ids: Set<UUID>) async {
        let unfinishedIDs = Set(
            snips.lazy
                .filter { ids.contains($0.id) && !$0.isDone }
                .map(\.id)
        )
        guard !unfinishedIDs.isEmpty else { return }
        await performUserMutation {
            let update = try await session.performLibraryCommand(
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
        let result = await performCommand(
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
        let result = await performCommand(
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
        placeOnClipboard(.snips(selectedSnips), feedback: .notify)
    }

    @discardableResult
    func copySelectionNow(to pasteboard: NSPasteboard = .general) async -> Bool {
        await placeOnClipboardNow(
            .snips(selectedSnips),
            feedback: .notify,
            to: pasteboard
        )
    }

    @discardableResult
    func placeOnClipboard(
        _ placement: ClipboardPlacement,
        feedback: ClipboardPlacementFeedback = .notify,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        switch placement {
        case .snips(let snips):
            guard !snips.isEmpty else { return false }
            Task { await placeOnClipboardNow(.snips(snips), feedback: feedback, to: pasteboard) }
            return true
        case .clipboardEntry(let entry):
            return placeClipboardEntry(entry, feedback: feedback)
        }
    }

    @discardableResult
    func placeOnClipboardNow(
        _ placement: ClipboardPlacement,
        feedback: ClipboardPlacementFeedback = .notify,
        to pasteboard: NSPasteboard = .general
    ) async -> Bool {
        switch placement {
        case .snips(let snips):
            return await placeSnipsOnClipboard(snips, feedback: feedback, to: pasteboard)
        case .clipboardEntry(let entry):
            return placeClipboardEntry(entry, feedback: feedback)
        }
    }

    @discardableResult
    func placeClipboardEntry(
        _ entry: ClipboardEntry,
        feedback: ClipboardPlacementFeedback = .notify
    ) -> Bool {
        guard clipboardHistory.restore(entry) else {
            presentedError = String(localized: "Snip Snap could not set the clipboard.")
            return false
        }
        if feedback == .notify {
            clipboardCopyPulse = ClipboardCopyPulse(entryID: entry.id)
        }
        return true
    }

    private func placeSnipsOnClipboard(
        _ snips: [Snip],
        feedback: ClipboardPlacementFeedback,
        to pasteboard: NSPasteboard
    ) async -> Bool {
        guard !snips.isEmpty else { return false }
        let attachments = attachmentPreparation.unique(snips.flatMap(\.attachments))
        let prepared: [UUID: URL]
        do {
            prepared = try await prepareAttachments(attachments, for: .copy)
        } catch {
            presentedError = error.localizedDescription
            return false
        }
        let text = SnipFormatter.formatForClipboard(snips: snips)
        let textItem = NSPasteboardItem()
        textItem.setString(text, forType: .string)
        var objects: [NSPasteboardWriting] = [textItem]
        objects.append(contentsOf: attachments.compactMap { prepared[$0.id] as NSURL? })
        pasteboard.clearContents()
        let copied = pasteboard.writeObjects(objects)
        if copied {
            clipboardHistory.captureNow(from: pasteboard)
            if feedback == .notify, toast?.action == nil {
                toast = .copied(count: snips.count)
            }
        }
        return copied
    }

    func clearDownloadedFiles() async throws {
        try await attachmentPreparation.clearDownloadedFiles()
        await reload()
    }

    func mergeSelection() {
        Task { await mergeSelectionNow() }
    }

    func mergeSelectionNow() async {
        let ids = selection
        let snipsToMerge = selectedSnips
        guard ids.count >= 2, snipsToMerge.count >= 2 else { return }
        let result = await performCommand(
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

    private func performMutation<Value: Sendable>(
        _ mutation: () async throws -> (SnipLibraryUpdate, Value)
    ) async -> Result<Value, Error> {
        await withCommandLock {
            await performMutationUnlocked(mutation)
        }
    }

    private func performMutationUnlocked<Value: Sendable>(
        _ mutation: () async throws -> (SnipLibraryUpdate, Value)
    ) async -> Result<Value, Error> {
        do {
            let (update, value) = try await mutation()
            clearPendingDeletionToast()
            apply(update.snapshot)
            scheduleCloudSync()
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

    private func performCommand(
        command: SnipLibraryCommand,
        afterSelection: ((SnipLibraryOutcome) -> Set<UUID>)? = nil,
        afterSortMode: SnipSortMode? = nil,
    ) async -> Result<SnipLibraryOutcome, Error> {
        await withCommandLock {
            do {
                let update = try await session.performUserCommand(
                    command,
                    sortedBy: sortMode
                )
                clearPendingDeletionToast()
                apply(update.snapshot)
                if let afterSortMode { setSortMode(afterSortMode) }
                if let afterSelection { selection = afterSelection(update.outcome) }
                scheduleCloudSync()
                return .success(update.outcome)
            } catch {
                return .failure(error)
            }
        }
    }

    private func withCommandLock<Value: Sendable>(
        _ operation: @MainActor @Sendable () async -> Value
    ) async -> Value {
        await session.withExclusiveAccess { _ in await operation() }
    }

    private func clearPendingDeletionToast() {
        guard let toast, toast.action == .undoDelete else { return }
        self.toast = nil
    }

    private func scheduleCloudSync() {
        guard let cloudSyncHandler else { return }
        Task { await cloudSyncHandler.scheduleSyncAfterLocalChange() }
    }
}
