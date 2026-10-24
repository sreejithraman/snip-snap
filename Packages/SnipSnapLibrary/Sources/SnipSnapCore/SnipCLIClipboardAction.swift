import CryptoKit
import Foundation

public enum SnipCLIClipboardAction: Codable, Equatable, Sendable {
    case status
    case list(SnipCLIClipboardQuery)
    case show(id: UUID)
    case restore(id: UUID, expectedRevision: String)
    case save(id: UUID, list: String, expectedRevision: String)
    case setPinned(id: UUID, pinned: Bool, expectedRevision: String)
    case delete(id: UUID, expectedRevision: String)
    case setPaused(paused: Bool, expectedRevision: String)
    case clear(expectedRevision: String)

    public var isReadOnly: Bool {
        switch self {
        case .status, .list, .show: true
        default: false
        }
    }

    public var compacted: Self {
        let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        switch self {
        case .status: return .status
        case .list: return .list(.init())
        case .show: return .show(id: id)
        case .restore: return .restore(id: id, expectedRevision: "")
        case .save: return .save(id: id, list: "", expectedRevision: "")
        case .setPinned(_, let pinned, _):
            return .setPinned(id: id, pinned: pinned, expectedRevision: "")
        case .delete: return .delete(id: id, expectedRevision: "")
        case .setPaused(let paused, _): return .setPaused(paused: paused, expectedRevision: "")
        case .clear: return .clear(expectedRevision: "")
        }
    }
}

public struct SnipCLIClipboardQuery: Codable, Equatable, Sendable {
    public var search: String?
    public var onlyPinned: Bool
    public var newestFirst: Bool
    public var limit: Int?

    public init(search: String? = nil, onlyPinned: Bool = false,
                newestFirst: Bool = true, limit: Int? = nil) {
        self.search = search
        self.onlyPinned = onlyPinned
        self.newestFirst = newestFirst
        self.limit = limit
    }

    public func apply(to entries: [ClipboardEntry]) -> [ClipboardEntry] {
        let needle = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matches = entries.filter {
            needle.isEmpty || $0.searchText.localizedCaseInsensitiveContains(needle)
        }
        let ordered = ClipboardViewOptions(onlyPinned: onlyPinned, newestFirst: newestFirst)
            .apply(to: matches)
        return limit.map { Array(ordered.prefix(max(0, $0))) } ?? ordered
    }
}

public struct SnipCLIClipboardEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let revision: String
    public let text: String
    public let capturedAt: Date
    public let modifiedAt: Date
    public let pinnedAt: Date?
    public let sourceApplication: String?
    public let sourceDeviceName: String?
    public let fileURLs: [URL]
    public let representationTypes: [String]
    public let byteCount: Int

    public init(_ entry: ClipboardEntry) {
        id = entry.id
        revision = SnipCLIClipboardRevision.token(entry: entry)
        text = entry.text
        capturedAt = entry.capturedAt
        modifiedAt = entry.modifiedAt
        pinnedAt = entry.pinnedAt
        sourceApplication = entry.sourceApplication
        sourceDeviceName = entry.sourceDeviceName
        fileURLs = entry.fileURLs
        representationTypes = Array(Set(entry.items.flatMap(\.representations).map(\.type))).sorted()
        byteCount = entry.retentionByteCount
    }
}

public struct SnipCLIClipboardStatus: Codable, Equatable, Sendable {
    public let isPaused: Bool
    public let entryCount: Int
    public let pinnedCount: Int
    public let revision: String

    public init(entries: [ClipboardEntry], isPaused: Bool) {
        self.isPaused = isPaused
        entryCount = entries.count
        pinnedCount = entries.filter(\.isPinned).count
        revision = SnipCLIClipboardRevision.token(entries: entries, isPaused: isPaused)
    }
}

public struct SnipCLIClipboardResult: Codable, Equatable, Sendable {
    public let entries: [SnipCLIClipboardEntry]
    public let status: SnipCLIClipboardStatus

    public init(entries: [SnipCLIClipboardEntry] = [], status: SnipCLIClipboardStatus) {
        self.entries = entries
        self.status = status
    }
}

public enum SnipCLIClipboardRevision {
    public static func token(entry: ClipboardEntry) -> String { hash(entry) }

    public static func token(entries: [ClipboardEntry], isPaused: Bool) -> String {
        struct State: Encodable {
            let isPaused: Bool
            let entries: [ClipboardEntry]
        }
        return hash(State(isPaused: isPaused, entries: entries.sorted { $0.id.uuidString < $1.id.uuidString }))
    }

    private static func hash(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try! encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SnipCLIClipboardError: Error, LocalizedError, Equatable, Sendable {
    case entryNotFound
    case entryChanged
    case historyChanged
    case copyFailed

    public var errorDescription: String? {
        switch self {
        case .entryNotFound: "Clipboard entry not found. List clipboard history again."
        case .entryChanged: "Clipboard entry changed. Show it again and use its latest revision."
        case .historyChanged: "Clipboard history changed. Read its status again and use the latest revision."
        case .copyFailed: "Couldn’t restore the clipboard entry. Check that its files are available."
        }
    }
}
