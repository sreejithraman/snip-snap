import Foundation
import Observation
import SnipSnapCore

@MainActor
@Observable
final class IOSAppModel {
    private let library: any SnipLibrary
    private var undoHistory = IOSUndoHistory()
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var snips: [Snip]
    private(set) var lists: [SnipList]
    private(set) var attachmentURLs: [UUID: URL]
    var selectedListID: UUID
    var selectedSnipID: UUID?
    var selectedSnipIDs: Set<UUID> = []
    var searchText = ""
    var completionFilter: SnipCompletionFilter = .all
    var sortMode: SnipSortMode = .chronological
    var errorMessage: String?

    init(
        library: any SnipLibrary,
        initialSnapshot: SnipLibrarySnapshot = SnipLibrarySnapshot(snips: [], lists: [.inbox]),
        startupError: String? = nil
    ) {
        self.library = library
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

    var canUndo: Bool { undoHistory.canUndo }
    var undoTitle: String { undoHistory.title }
    var canReorderVisibleSnips: Bool {
        sortMode == .manual && completionFilter == .all
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load() async {
        await withSerializedMutation { await loadUnlocked() }
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

    private func loadUnlocked() async {
        apply(await library.snapshot(sortedBy: sortMode))
        await pruneAttachmentsRetainedByUndo()
    }

    private func createSnipUnlocked(
        content: String,
        in listID: UUID,
        attachmentURLs: [URL]
    ) async -> Bool {
        await performUndoable(
            .add(
                content: content,
                origin: .quickEntry,
                source: nil,
                listID: listID,
                attachmentURLs: attachmentURLs,
                requestID: UUID(),
                now: Date()
            ),
            name: "New Snip",
            inverse: { _, update in
                guard case .add(.added(let id)) = update.outcome else { return nil }
                return .delete(ids: [id])
            }
        ) { outcome in
            if case .add(.added(let id)) = outcome {
                selectedListID = listID
                selectedSnipID = id
            }
        }
    }

    func attachmentURL(for attachmentID: UUID) -> URL? {
        attachmentURLs[attachmentID]
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
        return await performUndoable(
            command,
            name: "Edit",
            inverse: { before, update in
                guard let old = before.snips.first(where: { $0.id == snip.id }),
                    let current = update.snapshot.snips.first(where: { $0.id == snip.id })
                else { return nil }
                return attachmentEdits == nil
                    ? .update(before: old, expectedUpdatedAt: current.updatedAt)
                    : .replace(before: old, expectedUpdatedAt: current.updatedAt)
            }
        )
    }

    private func moveSnipUnlocked(id: UUID, to listID: UUID) async -> Bool {
        let sourceListIDs = Set(snips.filter { $0.id == id }.map(\.listID))
        let touched = sourceListIDs.union([listID])
        return await performUndoable(
            .moveChronologically(ids: [id], to: listID),
            name: "Move",
            touchedListIDs: touched,
            inverse: { before, _ in
                .placements(IOSUndoHistory.placements(in: before, listIDs: touched))
            }
        ) { _ in
            selectedListID = listID
            selectedSnipID = id
        }
    }

    private func moveSelectionUnlocked(to listID: UUID) async -> Bool {
        let selected = selectedVisibleSnipIDs
        let ids = visibleSnips.map(\.id).filter(selected.contains)
        guard !ids.isEmpty else { return false }
        let sourceListIDs = Set(snips.filter { selected.contains($0.id) }.map(\.listID))
        let touched = sourceListIDs.union([listID])
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
        return await performUndoable(
            command,
            name: "Move",
            touchedListIDs: touched,
            inverse: { before, _ in
                .placements(IOSUndoHistory.placements(in: before, listIDs: touched))
            }
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
        return await performUndoable(
            .place(ids: orderedIDs, in: listID, before: nil, basedOn: .manual),
            name: "Reorder",
            touchedListIDs: [listID],
            inverse: { before, _ in
                .placements(IOSUndoHistory.placements(in: before, listIDs: [listID]))
            }
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
        return await performUndoable(
            .setDone(ids: ids, done: done),
            name: done ? "Mark Done" : "Mark Not Done",
            inverse: { before, _ in
                .setDone(states: Dictionary(uniqueKeysWithValues: before.snips
                    .filter { ids.contains($0.id) }.map { ($0.id, $0.isDone) }))
            }
        )
    }

    private func toggleDoneUnlocked(id: UUID) async -> Bool {
        guard let snip = snips.first(where: { $0.id == id }) else { return false }
        return await performUndoable(
            .setDone(ids: [id], done: !snip.isDone),
            name: snip.isDone ? "Mark Not Done" : "Mark Done",
            inverse: { before, _ in
                guard let prior = before.snips.first(where: { $0.id == id }) else { return nil }
                return .setDone(states: [id: prior.isDone])
            }
        )
    }

    private func createListUnlocked(name: String) async -> Bool {
        await performUndoable(
            .createList(name: name, systemImage: "list.bullet"),
            name: "New List",
            inverse: { _, update in
                guard case .listCreated(let list) = update.outcome else { return nil }
                return .deleteList(id: list.id)
            }
        ) { outcome in
            if case .listCreated(let list) = outcome {
                selectedListID = list.id
                selectedSnipID = nil
                selectedSnipIDs = []
            }
        }
    }

    private func renameListUnlocked(_ list: SnipList, name: String) async -> Bool {
        await performUndoable(
            .updateList(id: list.id, name: name, systemImage: list.systemImage),
            name: "Rename List",
            inverse: { before, _ in
                before.lists.first(where: { $0.id == list.id })
                    .map(IOSUndoHistory.InverseEdit.updateList)
            }
        )
    }

    private func deleteListUnlocked(id: UUID) async -> Bool {
        guard let deleted = lists.first(where: { $0.id == id }) else { return false }
        let touched: Set<UUID> = [SnipList.inboxID, id]
        return await performUndoable(
            .deleteList(id: id),
            name: "Delete List",
            touchedListIDs: touched,
            inverse: { before, _ in
                .restoreList(
                    deleted,
                    placements: IOSUndoHistory.placements(in: before, listIDs: touched)
                )
            }
        ) { _ in
            selectedListID = SnipList.inboxID
            selectedSnipID = nil
            selectedSnipIDs = []
        }
    }

    private func undoUnlocked() async -> Bool {
        guard let operation = undoHistory.latest else { return false }
        do {
            let update = try await library.perform(
                .guarded(
                    expectation: operation.expectation,
                    command: operation.inverse.command(now: Date())
                ),
                sortedBy: sortMode
            )
            undoHistory.discardLatest()
            apply(update.snapshot)
            selectedListID = lists.contains(where: { $0.id == operation.selection.listID })
                ? operation.selection.listID : SnipList.inboxID
            selectedSnipID = operation.selection.snipID.flatMap { id in
                snips.contains(where: { $0.id == id }) ? id : nil
            }
            selectedSnipIDs = operation.selection.snipIDs.intersection(snips.map(\.id))
            await pruneAttachmentsRetainedByUndo()
            return true
        } catch {
            if let libraryError = error as? SnipLibraryError,
                libraryError == .snipChanged
                    || libraryError == .duplicateList
                    || libraryError == .invalidList
            {
                undoHistory.discardLatest()
                errorMessage = "That change can no longer be undone because its snips or lists changed."
                await pruneAttachmentsRetainedByUndo()
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return false
        }
    }

    private var selectedVisibleSnipIDs: Set<UUID> {
        selectedSnipIDs.intersection(visibleSnips.map(\.id))
    }

    private func deleteSnips(ids: Set<UUID>) async -> Bool {
        guard !ids.isEmpty else { return false }
        return await performUndoable(
            .delete(ids: ids),
            name: "Delete",
            inverse: { before, _ in
                .restore(snips: before.snips.filter { ids.contains($0.id) })
            }
        ) { _ in
            if let selectedSnipID, ids.contains(selectedSnipID) { self.selectedSnipID = nil }
            selectedSnipIDs.subtract(ids)
        }
    }

    private func performUndoable(
        _ command: SnipLibraryCommand,
        name: String,
        touchedListIDs: Set<UUID> = [],
        inverse: (SnipLibrarySnapshot, SnipLibraryUpdate) -> IOSUndoHistory.InverseEdit?,
        afterSuccess: (SnipLibraryOutcome) -> Void = { _ in }
    ) async -> Bool {
        let before = currentSnapshot
        let selectionBefore = IOSUndoHistory.Selection(
            listID: selectedListID,
            snipID: selectedSnipID,
            snipIDs: selectedSnipIDs
        )
        do {
            let update = try await library.perform(command, sortedBy: sortMode)
            apply(update.snapshot)
            afterSuccess(update.outcome)
            if (before.snips != update.snapshot.snips || before.lists != update.snapshot.lists),
                let inverse = inverse(before, update)
            {
                undoHistory.record(
                    name: name,
                    before: before,
                    after: update.snapshot,
                    touchedListIDs: touchedListIDs,
                    inverse: inverse,
                    selection: selectionBefore
                )
            }
            await pruneAttachmentsRetainedByUndo()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private var currentSnapshot: SnipLibrarySnapshot {
        SnipLibrarySnapshot(
            snips: snips,
            lists: lists,
            attachmentURLs: attachmentURLs
        )
    }

    private func pruneAttachmentsRetainedByUndo() async {
        do {
            let update = try await library.perform(
                .pruneAttachments(retaining: undoHistory.retainedAttachmentIDs),
                sortedBy: sortMode
            )
            apply(update.snapshot)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func apply(_ snapshot: SnipLibrarySnapshot) {
        snips = snapshot.snips
        lists = snapshot.lists
        attachmentURLs = snapshot.attachmentURLs
        if !lists.contains(where: { $0.id == selectedListID }) {
            selectedListID = SnipList.inboxID
        }
        if let selectedSnipID, !snips.contains(where: { $0.id == selectedSnipID }) {
            self.selectedSnipID = nil
        }
        selectedSnipIDs.formIntersection(snips.map(\.id))
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
