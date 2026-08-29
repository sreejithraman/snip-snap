import Foundation

public enum SnipOrigin: String, Codable, Sendable {
    case selection
    case quickEntry
    case clipboard
    case share
}

public struct SnipList: Identifiable, Codable, Equatable, Sendable, Hashable {
    public static let inboxID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public let id: UUID
    public var name: String
    public var systemImage: String
    public var position: Int

    public static let inbox = SnipList(
        id: inboxID,
        name: "Inbox",
        systemImage: "tray.fill",
        position: 0
    )

    public init(id: UUID, name: String, systemImage: String, position: Int) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.position = position
    }
}

public struct SnipAttachment: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public var fileName: String
    package var relativePath: String
    public var contentType: String?
    public var byteCount: Int64

    package init(
        id: UUID,
        fileName: String,
        relativePath: String,
        contentType: String?,
        byteCount: Int64
    ) {
        self.id = id
        self.fileName = fileName
        self.relativePath = relativePath
        self.contentType = contentType
        self.byteCount = byteCount
    }
}

public enum SnipSortMode: String, CaseIterable, Codable, Sendable, Hashable {
    case chronological
    case manual
}

public enum SnipCompletionFilter: String, CaseIterable, Sendable, Hashable {
    case all
    case done
    case notDone

    public var title: String {
        switch self {
        case .all: "All"
        case .done: "Done"
        case .notDone: "Not Done"
        }
    }

    public var emptyStateTitle: String {
        switch self {
        case .all: "Nothing captured yet"
        case .done: "No done snips"
        case .notDone: "No unfinished snips"
        }
    }
}

public struct SnipSource: Codable, Equatable, Sendable {
    public var applicationName: String
    public var windowTitle: String?
    public var url: String?

    public var conciseLabel: String {
        [applicationName, windowTitle]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " — ")
    }

    public init(
        applicationName: String,
        windowTitle: String? = nil,
        url: String? = nil
    ) {
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.url = url
    }
}

public struct Snip: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let requestID: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var content: String
    public var origin: SnipOrigin
    public var source: SnipSource?
    public var listID: UUID
    public var isDone: Bool
    public var manualPosition: Int64
    public var attachments: [SnipAttachment]

    public var displaySourceLabel: String {
        if let source {
            let label = source.conciseLabel
            if !label.isEmpty { return label }
        }
        return switch origin {
        case .selection: "Captured Selection"
        case .quickEntry: "Snip Snap — Quick Entry"
        case .clipboard: "Clipboard"
        case .share: "Shared"
        }
    }

    public init(
        id: UUID = UUID(),
        requestID: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        content: String,
        origin: SnipOrigin,
        source: SnipSource? = nil,
        listID: UUID = SnipList.inboxID,
        isDone: Bool = false,
        manualPosition: Int64 = 0,
        attachments: [SnipAttachment] = []
    ) {
        self.id = id
        self.requestID = requestID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.content = content
        self.origin = origin
        self.source = source
        self.listID = listID
        self.isDone = isDone
        self.manualPosition = manualPosition
        self.attachments = attachments
    }

    public static func sorted(_ snips: [Snip], by mode: SnipSortMode) -> [Snip] {
        snips.sorted { lhs, rhs in
            switch mode {
            case .chronological:
                if lhs.isDone != rhs.isDone {
                    return !lhs.isDone
                }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            case .manual:
                if lhs.isDone != rhs.isDone {
                    return !lhs.isDone
                }
                if lhs.manualPosition != rhs.manualPosition {
                    return lhs.manualPosition < rhs.manualPosition
                }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, requestID, createdAt, updatedAt, content, origin, source, listID, isDone
        // TODO: Remove after the 1.0 migration window.
        case legacySectionID = "sectionID"
        case manualPosition, attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        content = try container.decode(String.self, forKey: .content)
        origin = try container.decode(SnipOrigin.self, forKey: .origin)
        source = try container.decodeIfPresent(SnipSource.self, forKey: .source)
        listID = try container.decodeIfPresent(UUID.self, forKey: .listID)
            ?? container.decode(UUID.self, forKey: .legacySectionID)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        manualPosition = try container.decode(Int64.self, forKey: .manualPosition)
        attachments = try container.decode([SnipAttachment].self, forKey: .attachments)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(content, forKey: .content)
        try container.encode(origin, forKey: .origin)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(listID, forKey: .listID)
        try container.encode(isDone, forKey: .isDone)
        try container.encode(manualPosition, forKey: .manualPosition)
        try container.encode(attachments, forKey: .attachments)
    }
}
