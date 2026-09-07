import Foundation
import SnipSnapCore

public actor ClipboardHistoryStore {
    public nonisolated let url: URL
    private let files: ClipboardFileStore
    public init(url: URL, fileStore: ClipboardFileStore? = nil) {
        self.url = url
        files = fileStore ?? ClipboardFileStore(rootURL: url.deletingLastPathComponent().appendingPathComponent("ClipboardFiles", isDirectory: true))
    }

    public func load() throws -> ClipboardHistoryState {
        guard FileManager.default.fileExists(atPath: url.path) else { return ClipboardHistoryState() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid clipboard date")
        }
        if let state = try? decoder.decode(ClipboardHistoryState.self, from: data) {
            return ClipboardHistoryState(entries: state.entries, tombstones: state.tombstones)
        }
        // Decode legacy Mac history without rewriting it until a successful save.
        return ClipboardHistoryState(entries: try decoder.decode([ClipboardEntry].self, from: data))
    }

    public func save(_ state: ClipboardHistoryState) throws {
        let previous = try? load()
        if previous == state { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try encoder.encode(state).write(to: url, options: .atomic)
        if let previous { pruneRemovedFiles(previous: previous, current: state) }
    }

    private func pruneRemovedFiles(previous: ClipboardHistoryState, current: ClipboardHistoryState) {
        // Only remove files known to the previous committed history. Active imports
        // and failed saves must not lose bytes, and quarantine keeps its files.
        var retained = Set(current.entries.flatMap(\.ownedFiles).map(\.relativePath))
        let directory = url.deletingLastPathComponent()
        guard let backups = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for backup in backups where backup.lastPathComponent.hasPrefix("clipboard-quarantine-") {
            guard let data = try? Data(contentsOf: backup),
                  let state = try? JSONDecoder().decode(ClipboardHistoryState.self, from: data) else { return }
            retained.formUnion(state.entries.flatMap(\.ownedFiles).map(\.relativePath))
        }
        for file in previous.entries.flatMap(\.ownedFiles) where !retained.contains(file.relativePath) {
            guard let target = try? files.url(for: file) else { continue }
            try? FileManager.default.removeItem(at: target)
            let parent = target.deletingLastPathComponent()
            if parent != files.rootURL, (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: parent)
            }
        }
    }

    @discardableResult public func merge(_ remote: ClipboardHistoryState) throws -> ClipboardHistoryState {
        var local = try load(); local.merge(remote); try save(local); return local
    }

    @discardableResult public func insert(_ entry: ClipboardEntry) throws -> ClipboardHistoryState {
        var state = try load(); state.insert(entry); try save(state); return state
    }

    @discardableResult public func delete(id: UUID, at date: Date = Date()) throws -> ClipboardHistoryState {
        var state = try load(); state.delete(id: id, at: date); try save(state); return state
    }

    @discardableResult public func clearUnpinned(at date: Date = Date()) throws -> ClipboardHistoryState {
        var state = try load(); state.clearUnpinned(at: date); try save(state); return state
    }

    @discardableResult public func setPinned(_ pinned: Bool, id: UUID, at date: Date = Date(),
                                            fileStore: ClipboardFileStore? = nil) throws -> ClipboardHistoryState {
        var state = try load()
        guard var entry = state.entries.first(where: { $0.id == id }) else { return state }
        if pinned && !entry.fileURLs.isEmpty {
            guard let fileStore else { throw ClipboardFileStore.Failure.fileStoreRequired }
            entry = try fileStore.preserveFiles(of: entry)
        }
        entry.pinnedAt = pinned ? (entry.pinnedAt ?? date) : nil; entry.modifiedAt = date
        state.replace(entry); try save(state); return state
    }
}
