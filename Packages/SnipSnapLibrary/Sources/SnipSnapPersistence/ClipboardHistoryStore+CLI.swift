import Foundation
import SnipSnapCore

public extension ClipboardHistoryStore {
    /// Check the revision and commit in one actor turn. Sync and capture writes
    /// cannot slip between the check and the mutation.
    @discardableResult
    func performCLI(_ action: SnipCLIClipboardAction, isPaused: Bool) throws -> ClipboardHistoryState {
        var state = try load()
        switch action {
        case .setPinned(let id, let pinned, let revision):
            var entry = try checkedCLIEntry(id: id, revision: revision, in: state)
            guard entry.isPinned != pinned else { return state }
            if pinned && !entry.fileURLs.isEmpty {
                entry = try files.preserveFiles(of: entry)
            }
            let date = max(Date(), entry.modifiedAt.addingTimeInterval(0.000001))
            entry.pinnedAt = pinned ? date : nil
            entry.modifiedAt = date
            state.replace(entry)
        case .delete(let id, let revision):
            _ = try checkedCLIEntry(id: id, revision: revision, in: state)
            state.delete(id: id)
        case .clear(let revision):
            guard SnipCLIClipboardRevision.token(entries: state.entries, isPaused: isPaused) == revision else {
                throw SnipCLIClipboardError.historyChanged
            }
            state.clearUnpinned()
        default:
            throw SnipLibraryError.invalidCommand
        }
        try save(state)
        return state
    }

    func checkedCLIEntry(id: UUID, revision: String) throws -> ClipboardEntry {
        try checkedCLIEntry(id: id, revision: revision, in: load())
    }

    private func checkedCLIEntry(id: UUID, revision: String,
                                 in state: ClipboardHistoryState) throws -> ClipboardEntry {
        guard let entry = state.entries.first(where: { $0.id == id }) else {
            throw SnipCLIClipboardError.entryNotFound
        }
        guard SnipCLIClipboardRevision.token(entry: entry) == revision else {
            throw SnipCLIClipboardError.entryChanged
        }
        return entry
    }
}
