import Foundation
import SnipSnapCore

public actor ClipboardHistoryStore {
    private static let setAsidePrefix = "clipboard-quarantine-"
    public nonisolated let url: URL
    public nonisolated let files: ClipboardFileStore
    public init(url: URL, fileStore: ClipboardFileStore? = nil) {
        self.url = url
        files = fileStore ?? ClipboardFileStore(rootURL: url.deletingLastPathComponent().appendingPathComponent("ClipboardFiles", isDirectory: true))
    }

    public func load() throws -> ClipboardHistoryState {
        guard FileManager.default.fileExists(atPath: url.path) else { return ClipboardHistoryState() }
        return try Self.decodeHistory(Data(contentsOf: url))
    }

    private static func decodeHistory(_ data: Data) throws -> ClipboardHistoryState {
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
            return ClipboardHistoryState(entries: state.entries, tombstones: state.tombstones, retentionTombstones: state.retentionTombstones)
        }
        // Decode legacy Mac history without rewriting it until a successful save.
        return ClipboardHistoryState(entries: try decoder.decode([ClipboardEntry].self, from: data))
    }

    /// Copies the history beside itself, then empties it, in one step, so no other store write
    /// lands between the copy and the empty save.
    public func setAside() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let copy = url.deletingLastPathComponent()
                .appendingPathComponent("\(Self.setAsidePrefix)\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: url, to: copy)
        }
        try save(ClipboardHistoryState())
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
        for backup in backups where backup.lastPathComponent.hasPrefix(Self.setAsidePrefix) {
            guard let data = try? Data(contentsOf: backup) else { return }
            if let state = try? Self.decodeHistory(data) {
                retained.formUnion(state.entries.flatMap(\.ownedFiles).map(\.relativePath))
                continue
            }
            // An undecodable copy keeps every file whose path appears in its text.
            for path in previous.entries.flatMap(\.ownedFiles).map(\.relativePath)
            where !retained.contains(path) && Self.text(data, mentions: path) {
                retained.insert(path)
            }
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

    private static func text(_ data: Data, mentions path: String) -> Bool {
        var forms = [Data(path.utf8)]
        if let quoted = try? JSONEncoder().encode(path) { forms.append(quoted.dropFirst().dropLast()) }
        return forms.contains { !$0.isEmpty && data.range(of: $0) != nil }
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

    @discardableResult public func togglePinned(id: UUID, at date: Date = Date()) throws -> ClipboardHistoryState {
        let state = try load()
        guard let entry = state.entries.first(where: { $0.id == id }) else { return state }
        return try setPinned(!entry.isPinned, id: id, at: date)
    }

    @discardableResult public func setPinned(_ pinned: Bool, id: UUID, at date: Date = Date()) throws -> ClipboardHistoryState {
        var state = try load()
        guard var entry = state.entries.first(where: { $0.id == id }) else { return state }
        if pinned && !entry.fileURLs.isEmpty {
            entry = try files.preserveFiles(of: entry)
        }
        entry.pinnedAt = pinned ? (entry.pinnedAt ?? date) : nil; entry.modifiedAt = date
        state.replace(entry); try save(state); return state
    }
}
