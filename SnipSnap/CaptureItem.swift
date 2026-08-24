import Foundation

enum CaptureOrigin: String, Codable, Sendable {
    case selection
    case quickEntry
    case clipboard
}

struct SnipSnapSection: Identifiable, Codable, Equatable, Sendable, Hashable {
    static let inboxID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    let id: UUID
    var name: String
    var systemImage: String
    var position: Int

    static let inbox = SnipSnapSection(
        id: inboxID,
        name: "Inbox",
        systemImage: "tray.fill",
        position: 0
    )
}

struct ClipAttachment: Identifiable, Codable, Equatable, Sendable, Hashable {
    let id: UUID
    var fileName: String
    var relativePath: String
    var contentType: String?
    var byteCount: Int64
}

enum ClipSortMode: String, CaseIterable, Codable, Sendable, Hashable {
    case chronological
    case manual
}

enum CompletionFilter: String, CaseIterable, Sendable, Hashable {
    case all
    case done
    case notDone

    var title: String {
        switch self {
        case .all: "All"
        case .done: "Done"
        case .notDone: "Not Done"
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .all: "Nothing captured yet"
        case .done: "No done clips"
        case .notDone: "No unfinished clips"
        }
    }
}

struct CaptureSource: Codable, Equatable, Sendable {
    var applicationName: String
    var windowTitle: String?
    var url: String?

    var conciseLabel: String {
        [applicationName, windowTitle]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " — ")
    }
}

struct CaptureItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let requestID: UUID
    let createdAt: Date
    var updatedAt: Date
    var content: String
    var origin: CaptureOrigin
    var source: CaptureSource?
    var sectionID: UUID
    var isDone: Bool
    var manualPosition: Int64
    var attachments: [ClipAttachment]

    var displaySourceLabel: String {
        if let source {
            let label = source.conciseLabel
            if !label.isEmpty { return label }
        }
        return switch origin {
        case .selection: "Captured Selection"
        case .quickEntry: "Snip Snap — Quick Entry"
        case .clipboard: "Clipboard"
        }
    }

    init(
        id: UUID = UUID(),
        requestID: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        content: String,
        origin: CaptureOrigin,
        source: CaptureSource? = nil,
        sectionID: UUID = SnipSnapSection.inboxID,
        isDone: Bool = false,
        manualPosition: Int64 = 0,
        attachments: [ClipAttachment] = []
    ) {
        self.id = id
        self.requestID = requestID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.content = content
        self.origin = origin
        self.source = source
        self.sectionID = sectionID
        self.isDone = isDone
        self.manualPosition = manualPosition
        self.attachments = attachments
    }

    static func sorted(_ items: [CaptureItem], by mode: ClipSortMode) -> [CaptureItem] {
        items.sorted { lhs, rhs in
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
        case id, requestID, createdAt, updatedAt, content, origin, source, sectionID, isDone
        case manualPosition, attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        content = try container.decode(String.self, forKey: .content)
        origin = try container.decode(CaptureOrigin.self, forKey: .origin)
        source = try container.decodeIfPresent(CaptureSource.self, forKey: .source)
        sectionID = try container.decode(UUID.self, forKey: .sectionID)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        manualPosition = try container.decode(Int64.self, forKey: .manualPosition)
        attachments = try container.decode([ClipAttachment].self, forKey: .attachments)
    }
}
