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
        let beforeItems: [CaptureItem]
        let afterItems: [CaptureItem]
        let beforeSortMode: ClipSortMode
        let afterSortMode: ClipSortMode
        let beforeSelection: Set<UUID>
        let afterSelection: Set<UUID>
    }

    static let sortModeDefaultsKey = "clipSortMode"
    static let activeSectionDefaultsKey = "activeSectionID"
    static let sectionDraftsDefaultsKey = "sectionDrafts"
    static let appearanceDefaultsKey = "appAppearance"

    @Published private(set) var items: [CaptureItem] = []
    @Published private(set) var sections: [SnipSnapSection] = [.inbox]
    @Published var activeSectionID: UUID
    @Published var isShowingClipboard = false
    @Published var query = ""
    @Published var completionFilter: CompletionFilter = .all
    @Published var selection: Set<UUID> = []
    @Published var editingID: UUID?
    @Published var presentedError: String?
    @Published private(set) var latestAddedClipID: UUID?
    @Published private(set) var sortMode: ClipSortMode
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
        return Set(items.filter { ids.contains($0.id) }.map(\.sectionID)).count == 1
    }

    private let repository: ItemRepository
    private let defaults: UserDefaults
    private let commandLock = AppModelCommandLock()
    private let composerDrafts: ComposerDraftStore
    let clipboardHistory: ClipboardHistory

    var filteredItems: [CaptureItem] {
        let matches = InboxFilter.apply(
            items: items,
            query: query,
            completionFilter: completionFilter,
            sectionNames: Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.name) })
        )
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return matches.filter { $0.sectionID == activeSection.id }
        }
        return matches
    }

    var selectedItems: [CaptureItem] {
        let selected = selection
        return items.filter { selected.contains($0.id) }
    }

    var clipboardSearchMatches: [ClipboardEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return clipboardHistory.entries.filter {
            $0.searchText.localizedCaseInsensitiveContains(needle)
        }
    }

    var activeSection: SnipSnapSection {
        sections.first(where: { $0.id == activeSectionID }) ?? .inbox
    }

    func attachmentURL(for attachment: ClipAttachment) -> URL {
        repository.attachmentURL(for: attachment)
    }

    init(
        repository: ItemRepository? = nil,
        defaults: UserDefaults = .standard,
        clipboardHistory: ClipboardHistory? = nil
    ) {
        self.defaults = defaults
        composerDrafts = ComposerDraftStore(
            defaults: defaults,
            textDefaultsKey: Self.sectionDraftsDefaultsKey
        )
        self.clipboardHistory = clipboardHistory ?? ClipboardHistory()
        activeSectionID = defaults.string(forKey: Self.activeSectionDefaultsKey)
            .flatMap(UUID.init(uuidString:)) ?? SnipSnapSection.inboxID
        sortMode = ClipSortMode(
            rawValue: defaults.string(forKey: Self.sortModeDefaultsKey) ?? ""
        ) ?? .chronological
        appearance = AppAppearance(
            rawValue: defaults.string(forKey: Self.appearanceDefaultsKey) ?? ""
        ) ?? .system
        if let repository {
            self.repository = repository
        } else {
            do {
                let result = try ItemRepository.openRecoveringCorruptStore()
                self.repository = result.repository
                if let backupURL = result.backupURL {
                    presentedError = "Snip Snap kept the unreadable items file as \(backupURL.lastPathComponent) and started a new one."
                }
            } catch {
                self.repository = ItemRepository.unavailable()
                presentedError = "Snip Snap could not read or safely back up its items file. Snip Snap cannot save new items."
            }
        }
        Task { await reload() }
    }

    func reload() async {
        await withCommandLock { await reloadUnlocked() }
    }

    private func reloadUnlocked() async {
        async let loadedItems = repository.allItems(sortMode: sortMode)
        async let loadedSections = repository.allSections()
        items = await loadedItems
        sections = await loadedSections
        if !sections.contains(where: { $0.id == activeSectionID }) {
            activeSectionID = SnipSnapSection.inboxID
            defaults.set(SnipSnapSection.inboxID.uuidString, forKey: Self.activeSectionDefaultsKey)
        }
        selection.formIntersection(Set(items.map(\.id)))
    }

    func setSortMode(_ mode: ClipSortMode) {
        guard sortMode != mode else { return }
        sortMode = mode
        defaults.set(mode.rawValue, forKey: Self.sortModeDefaultsKey)
        items = CaptureItem.sorted(items, by: mode)
    }

    func setAppearance(_ appearance: AppAppearance) {
        guard self.appearance != appearance else { return }
        self.appearance = appearance
        defaults.set(appearance.rawValue, forKey: Self.appearanceDefaultsKey)
    }

    @discardableResult
    func add(
        content: String,
        origin: CaptureOrigin,
        source: CaptureSource? = nil,
        attachmentURLs: [URL] = [],
        sectionID: UUID? = nil,
        requestID: UUID = UUID()
    ) async -> Bool {
        switch await addResult(
            content: content,
            origin: origin,
            source: source,
            attachmentURLs: attachmentURLs,
            sectionID: sectionID,
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
        origin: CaptureOrigin,
        source: CaptureSource? = nil,
        attachmentURLs: [URL] = [],
        sectionID: UUID? = nil,
        requestID: UUID = UUID()
    ) async -> Result<AddOutcome, Error> {
        await withCommandLock {
            let result = await performMutationUnlocked(clearingHistory: false) {
                try await repository.add(
                    content: content,
                    origin: origin,
                    source: source,
                    sectionID: sectionID ?? activeSection.id,
                    attachmentURLs: attachmentURLs,
                    requestID: requestID
                )
            }
            switch result {
            case .success(let item):
                if let item {
                    latestAddedClipID = item.id
                    clearHistory()
                    await reconcileAttachmentStorage()
                    return .success(.added(item.id))
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

    func selectSection(_ section: SnipSnapSection, preservingSelection: Bool = false) {
        activeSectionID = section.id
        defaults.set(section.id.uuidString, forKey: Self.activeSectionDefaultsKey)
        isShowingClipboard = false
        if !preservingSelection { selection = [] }
    }

    func showClipboard() {
        isShowingClipboard = true
        selection = []
    }

    func composerDraft(for sectionID: UUID) -> ComposerDraft {
        composerDrafts.draft(for: sectionID)
    }

    func saveComposerText(_ text: String, for sectionID: UUID) {
        composerDrafts.setText(text, for: sectionID)
    }

    func flushComposerDrafts() {
        composerDrafts.flushText()
    }

    func addDraftAttachments(_ urls: [URL], to sectionID: UUID) {
        composerDrafts.add(urls, to: sectionID)
    }

    func addTemporaryDraftAttachment(_ url: URL, to sectionID: UUID) {
        composerDrafts.addTemporary(url, to: sectionID)
    }

    func stageScreenCapture() -> URL {
        composerDrafts.stageScreenCapture()
    }

    func finishScreenCapture(_ url: URL, in sectionID: UUID, succeeded: Bool) {
        composerDrafts.finishScreenCapture(url, in: sectionID, succeeded: succeeded)
    }

    func removeDraftAttachment(_ url: URL, from sectionID: UUID) {
        composerDrafts.remove(url, from: sectionID)
    }

    func clearDraft(for sectionID: UUID) {
        composerDrafts.clear(sectionID: sectionID)
    }

    func saveComposerDraft(content: String, sectionID: UUID) async -> Bool {
        composerDrafts.setText(content, for: sectionID)
        let snapshot = composerDrafts.beginSave(sectionID: sectionID)
        let saved = await add(
            content: snapshot.draft.text,
            origin: .quickEntry,
            attachmentURLs: snapshot.draft.attachments,
            sectionID: sectionID
        )
        composerDrafts.finishSave(snapshot, saved: saved)
        return saved
    }

    func createSection(
        name: String,
        systemImage: String,
        movingIDs: Set<UUID> = []
    ) async -> Bool {
        let result = await performMutation(clearingHistory: false) {
            try await repository.createSection(name: name, systemImage: systemImage)
        }
        switch result {
        case .success(let section):
            selectSection(section, preservingSelection: !movingIDs.isEmpty)
            guard !movingIDs.isEmpty else { return true }
            let orderedIDs = items.filter { movingIDs.contains($0.id) }.map(\.id)
            return await moveToSection(
                ids: orderedIDs,
                sectionID: section.id,
                selectionAfterMove: movingIDs
            )
        case .failure(let error):
            presentedError = error.localizedDescription
            return false
        }
    }

    func deleteSection(_ section: SnipSnapSection) async {
        guard section.id != SnipSnapSection.inboxID else { return }
        let result = await performMutation {
            try await repository.deleteSection(id: section.id)
        }
        if case .failure(let error) = result {
            presentedError = error.localizedDescription
        } else {
            clearDraft(for: section.id)
        }
    }

    func updateSection(_ section: SnipSnapSection, name: String, systemImage: String) async -> Bool {
        let result = await performMutation {
            try await repository.updateSection(
                id: section.id,
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
        sectionID: UUID? = nil,
        before destinationID: UUID? = nil,
        placesManually: Bool = false
    ) async -> Bool {
        let materialization: ClipboardClipMaterialization
        do {
            materialization = try await Task.detached(priority: .utility) {
                try entry.materializeForClip()
            }.value
        } catch {
            presentedError = "Snip Snap could not prepare the clipboard image."
            return false
        }
        defer { materialization.removeTemporaryFiles() }
        let targetSectionID = sectionID ?? activeSectionID
        let result = await addResult(
            content: materialization.text,
            origin: .clipboard,
            source: materialization.source,
            attachmentURLs: materialization.fileURLs,
            sectionID: targetSectionID
        )
        switch result {
        case .success(.added(let id)):
            guard placesManually else { return true }
            return await move(ids: [id], to: targetSectionID, before: destinationID)
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
        let itemsToDelete = selectedItems
        guard !ids.isEmpty, !itemsToDelete.isEmpty else { return }
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
                try await repository.replaceAll(with: operation.beforeItems)
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
                try await repository.replaceAll(with: operation.afterItems)
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
            items.lazy
                .filter { ids.contains($0.id) && !$0.isDone }
                .map(\.id)
        )
        guard !unfinishedIDs.isEmpty else { return }
        await performUserMutation {
            try await repository.setDone(ids: unfinishedIDs, done: true)
        }
    }

    func moveSelection(to sectionID: UUID) {
        let ids = items.filter { selection.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            _ = await moveToSection(ids: ids, sectionID: sectionID)
        }
    }

    @discardableResult
    func moveToSection(
        ids: [UUID],
        sectionID: UUID,
        selectionAfterMove: Set<UUID>? = nil
    ) async -> Bool {
        if sortMode == .manual {
            let movingIDs = Set(ids)
            let firstID = items.first {
                $0.sectionID == sectionID && !movingIDs.contains($0.id)
            }?.id
            return await move(
                ids: ids,
                to: sectionID,
                before: firstID,
                selectionAfterMove: selectionAfterMove
            )
        }
        return await moveChronologically(
            ids: ids,
            to: sectionID,
            selectionAfterMove: selectionAfterMove
        )
    }

    @discardableResult
    func move(
        ids: [UUID],
        to sectionID: UUID,
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
                in: sectionID,
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
        to sectionID: UUID,
        selectionAfterMove: Set<UUID>? = nil
    ) async -> Bool {
        let selectedIDs = Set(ids)
        guard !ids.isEmpty else { return false }
        let finalSelection = selectionAfterMove ?? selectedIDs
        let result = await performHistoryMutation(name: "Move", afterSelection: { _ in finalSelection }) {
            try await repository.moveChronologically(ids: ids, to: sectionID)
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
        let sections = Set(items.filter { selectedIDs.contains($0.id) }.map(\.sectionID))
        guard let sectionID = sections.first else { return }
        let ids = items.filter { $0.sectionID == sectionID }.map(\.id)
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
        _ = await move(ids: movingIDs, to: sectionID, before: destinationID)
    }

    func selectAllVisible() {
        selection = Set(filteredItems.map(\.id))
    }

    func beginEditingSelection() {
        editingID = filteredItems.first(where: { selection.contains($0.id) })?.id
    }

    @discardableResult
    func copySelection() -> Bool {
        let selected = selectedItems
        guard !selected.isEmpty else { return false }
        let text = CopyFormatter.formatForClipboard(items: selected)
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
        let itemsToMerge = selectedItems
        guard ids.count >= 2, itemsToMerge.count >= 2 else { return }
        let result = await performHistoryMutation(name: "Merge", afterSelection: { [$0.id] }) {
            try await repository.merge(ids: ids)
        }
        switch result {
        case .success(let mergedItem):
            selection = [mergedItem.id]
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
        afterSortMode: ClipSortMode? = nil,
        _ mutation: () async throws -> Value
    ) async -> Result<Value, Error> {
        await withCommandLock {
            let beforeItems = items
            let beforeSortMode = sortMode
            let beforeSelection = selection
            let result = await performMutationUnlocked(clearingHistory: false, mutation)
            if case .success(let value) = result, beforeItems != items {
                let savedAfterSortMode = afterSortMode ?? sortMode
                setSortMode(savedAfterSortMode)
                let savedSelection = afterSelection?(value) ?? selection
                selection = savedSelection
                undoHistory.append(
                    HistoryOperation(
                        name: name,
                        beforeItems: beforeItems,
                        afterItems: items,
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
        let historyItems = undoHistory.flatMap { $0.beforeItems + $0.afterItems }
            + redoHistory.flatMap { $0.beforeItems + $0.afterItems }
        let retainedPaths = Set(historyItems.flatMap(\.attachments).map(\.relativePath))
        await repository.removeUnreferencedAttachments(keepingAdditional: retainedPaths)
    }
}
