import AppKit
import Combine
import Foundation

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
    private static let historyLimit = 100

    private struct HistoryOperation {
        let name: String
        let beforeSnips: [Snip]
        let afterSnips: [Snip]
        let beforeSortMode: SnipSortMode
        let afterSortMode: SnipSortMode
        let beforeSelection: Set<UUID>
        let afterSelection: Set<UUID>
    }

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
    @Published var isAccessibilityAccessExplanationPresented = false
    @Published private(set) var latestAddedSnipID: UUID?
    @Published private(set) var sortMode: SnipSortMode
    @Published private(set) var appearance: AppAppearance
    @Published private var undoHistory: [HistoryOperation] = []
    @Published private var redoHistory: [HistoryOperation] = []

    var undoTitle: String {
        undoHistory.last.map { "Undo \($0.name)" } ?? "Undo"
    }

    var redoTitle: String {
        redoHistory.last.map { "Redo \($0.name)" } ?? "Redo"
    }

    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var canReorderSelection: Bool { canReorder(ids: selection) }

    func canReorder(ids: Set<UUID>) -> Bool {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              completionFilter == .all,
              !ids.isEmpty else { return false }
        return Set(snips.filter { ids.contains($0.id) }.map(\.listID)).count == 1
    }

    private let repository: SnipRepository
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

    func attachmentURL(for attachment: SnipAttachment) -> URL {
        repository.attachmentURL(for: attachment)
    }

    init(
        repository: SnipRepository? = nil,
        defaults: UserDefaults = .standard,
        clipboardHistory: ClipboardHistory? = nil
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
        if let repository {
            self.repository = repository
        } else {
            do {
                let result = try SnipRepository.openRecoveringCorruptStore()
                self.repository = result.repository
                if let backupURL = result.backupURL {
                    presentedError = "Snip Snap kept the unreadable snips file as \(backupURL.lastPathComponent) and started a new one."
                }
            } catch {
                self.repository = SnipRepository.unavailable()
                presentedError = "Snip Snap could not read or safely back up its snips file. Snip Snap cannot save new snips."
            }
        }
        Task { await reload() }
    }

    func reload() async {
        await withCommandLock { await reloadUnlocked() }
    }

    private func reloadUnlocked() async {
        async let loadedSnips = repository.allSnips(sortMode: sortMode)
        async let loadedLists = repository.allLists()
        snips = await loadedSnips
        lists = await loadedLists
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
    ) async -> Result<AddOutcome, Error> {
        await withCommandLock {
            let result = await performMutationUnlocked(clearingHistory: false) {
                try await repository.add(
                    content: content,
                    origin: origin,
                    source: source,
                    listID: listID ?? activeList.id,
                    attachmentURLs: attachmentURLs,
                    requestID: requestID
                )
            }
            switch result {
            case .success(let snip):
                if let snip {
                    latestAddedSnipID = snip.id
                    clearHistory()
                    await reconcileAttachmentStorage()
                    return .success(.added(snip.id))
                }
                return .success(.duplicate)
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
            try await repository.update(
                id: id,
                content: content,
                attachmentURLs: attachmentURLs,
                expectedUpdatedAt: expectedUpdatedAt
            )
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
            try await repository.createList(name: name, systemImage: systemImage)
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
            try await repository.deleteList(id: list.id)
        }
        if case .failure(let error) = result {
            presentedError = error.localizedDescription
        } else {
            clearDraft(for: list.id)
        }
    }

    func updateList(_ list: SnipList, name: String, systemImage: String) async -> Bool {
        let result = await performMutation {
            try await repository.updateList(
                id: list.id,
                name: name,
                systemImage: systemImage
            )
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
        let result = await performHistoryMutation(name: "Delete", afterSelection: { _ in [] }) {
            try await repository.delete(ids: ids)
        }
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
            guard let operation = undoHistory.last else { return }
            switch await performMutationUnlocked(clearingHistory: false, {
                try await repository.replaceAll(with: operation.beforeSnips)
            }) {
            case .success:
                undoHistory.removeLast()
                redoHistory.append(operation)
                trimHistory(&redoHistory)
                setSortMode(operation.beforeSortMode)
                selection = operation.beforeSelection
                await reconcileAttachmentStorage()
            case .failure(let error):
                presentedError = error.localizedDescription
            }
        }
    }

    func redo() {
        Task { await redoNow() }
    }

    func redoNow() async {
        await withCommandLock {
            guard let operation = redoHistory.last else { return }
            switch await performMutationUnlocked(clearingHistory: false, {
                try await repository.replaceAll(with: operation.afterSnips)
            }) {
            case .success:
                redoHistory.removeLast()
                undoHistory.append(operation)
                trimHistory(&undoHistory)
                setSortMode(operation.afterSortMode)
                selection = operation.afterSelection
                await reconcileAttachmentStorage()
            case .failure(let error):
                presentedError = error.localizedDescription
            }
        }
    }

    func toggleDoneSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        Task {
            await performUserMutation {
                try await repository.toggleDone(ids: ids)
            }
        }
    }

    func toggleDone(id: UUID) {
        Task { await toggleDoneNow(id: id) }
    }

    func toggleDoneNow(id: UUID) async {
        await performUserMutation {
            try await repository.toggleDone(id: id)
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
            try await repository.setDone(ids: unfinishedIDs, done: true)
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
        let result = await performHistoryMutation(
            name: "Move",
            afterSelection: { _ in finalSelection },
            afterSortMode: .manual
        ) {
            try await repository.place(
                ids: ids,
                in: listID,
                before: destinationID,
                basedOn: currentSortMode
            )
        }
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
        let result = await performHistoryMutation(name: "Move", afterSelection: { _ in finalSelection }) {
            try await repository.moveChronologically(ids: ids, to: listID)
        }
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
        editingID = filteredSnips.first(where: { selection.contains($0.id) })?.id
    }

    @discardableResult
    func copySelection() -> Bool {
        let selected = selectedSnips
        guard !selected.isEmpty else { return false }
        let text = SnipFormatter.formatForClipboard(snips: selected)
        let pasteboard = NSPasteboard.general
        let textItem = NSPasteboardItem()
        textItem.setString(text, forType: .string)
        textItem.setData(Data(), forType: ClipboardHistory.internalType)
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = [textItem]
        objects.append(contentsOf: selected.flatMap(\.attachments).map {
            attachmentURL(for: $0) as NSURL
        })
        return pasteboard.writeObjects(objects)
    }

    func mergeSelection() {
        Task { await mergeSelectionNow() }
    }

    func mergeSelectionNow() async {
        let ids = selection
        let snipsToMerge = selectedSnips
        guard ids.count >= 2, snipsToMerge.count >= 2 else { return }
        let result = await performHistoryMutation(name: "Merge", afterSelection: { [$0.id] }) {
            try await repository.merge(ids: ids)
        }
        switch result {
        case .success(let mergedSnip):
            selection = [mergedSnip.id]
        case .failure(let error):
            presentedError = error.localizedDescription
        }
    }

    private func performMutation<Value>(
        clearingHistory: Bool = true,
        _ mutation: () async throws -> Value
    ) async -> Result<Value, Error> {
        await withCommandLock {
            await performMutationUnlocked(clearingHistory: clearingHistory, mutation)
        }
    }

    private func performMutationUnlocked<Value>(
        clearingHistory: Bool,
        _ mutation: () async throws -> Value
    ) async -> Result<Value, Error> {
        do {
            let value = try await mutation()
            await reloadUnlocked()
            if clearingHistory {
                clearHistory()
                await reconcileAttachmentStorage()
            }
            return .success(value)
        } catch {
            return .failure(error)
        }
    }

    private func performUserMutation(
        _ mutation: () async throws -> Void
    ) async {
        if case .failure(let error) = await performMutation(mutation) {
            presentedError = error.localizedDescription
        }
    }

    private func performHistoryMutation<Value>(
        name: String,
        afterSelection: ((Value) -> Set<UUID>)? = nil,
        afterSortMode: SnipSortMode? = nil,
        _ mutation: () async throws -> Value
    ) async -> Result<Value, Error> {
        await withCommandLock {
            let beforeSnips = snips
            let beforeSortMode = sortMode
            let beforeSelection = selection
            let result = await performMutationUnlocked(clearingHistory: false, mutation)
            if case .success(let value) = result, beforeSnips != snips {
                let savedAfterSortMode = afterSortMode ?? sortMode
                setSortMode(savedAfterSortMode)
                let savedSelection = afterSelection?(value) ?? selection
                selection = savedSelection
                undoHistory.append(
                    HistoryOperation(
                        name: name,
                        beforeSnips: beforeSnips,
                        afterSnips: snips,
                        beforeSortMode: beforeSortMode,
                        afterSortMode: savedAfterSortMode,
                        beforeSelection: beforeSelection,
                        afterSelection: savedSelection
                    )
                )
                trimHistory(&undoHistory)
                redoHistory = []
                await reconcileAttachmentStorage()
            }
            return result
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

    private func clearHistory() {
        undoHistory = []
        redoHistory = []
    }

    private func trimHistory(_ history: inout [HistoryOperation]) {
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    private func reconcileAttachmentStorage() async {
        let historySnips = undoHistory.flatMap { $0.beforeSnips + $0.afterSnips }
            + redoHistory.flatMap { $0.beforeSnips + $0.afterSnips }
        let retainedPaths = Set(historySnips.flatMap(\.attachments).map(\.relativePath))
        await repository.removeUnreferencedAttachments(keepingAdditional: retainedPaths)
    }
}
