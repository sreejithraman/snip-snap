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
    public var desiredName: String
    public var resolvedName: String
    public var name: String {
        get { resolvedName }
        set {
            let cleaned = SnipListNameAllocator.cleaned(newValue)
            desiredName = cleaned
            resolvedName = cleaned
        }
    }
    public var systemImage: String
    public var sortKey: SnipOrderKey
    public var position: Int {
        get { Int(sortKey.legacyProjection) }
        set { sortKey = .legacy(Int64(newValue)) }
    }

    public static let inbox = SnipList(
        id: inboxID,
        name: "Inbox",
        systemImage: "tray.fill",
        position: 0,
        sortKey: SnipOrderKey(rawDigits: [128, 0, 0, 0, 0, 0, 0, 0, 1, 128])
    )

    public init(
        id: UUID,
        name: String,
        systemImage: String,
        position: Int,
        sortKey: SnipOrderKey? = nil
    ) {
        self.id = id
        let cleaned = SnipListNameAllocator.cleaned(name)
        desiredName = cleaned
        resolvedName = cleaned
        self.systemImage = systemImage
        self.sortKey = sortKey ?? .legacy(Int64(position))
    }

    package init(
        id: UUID,
        desiredName: String,
        resolvedName: String,
        systemImage: String,
        sortKey: SnipOrderKey
    ) {
        self.id = id
        self.desiredName = desiredName
        self.resolvedName = resolvedName
        self.systemImage = systemImage
        self.sortKey = sortKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, desiredName, resolvedName, systemImage, position, sortKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let legacyName = try container.decodeIfPresent(String.self, forKey: .name)
        desiredName = SnipListNameAllocator.cleaned(
            try container.decodeIfPresent(String.self, forKey: .desiredName) ?? legacyName ?? ""
        )
        resolvedName = try container.decodeIfPresent(String.self, forKey: .resolvedName)
            ?? legacyName ?? desiredName
        systemImage = try container.decode(String.self, forKey: .systemImage)
        sortKey = try container.decodeIfPresent(SnipOrderKey.self, forKey: .sortKey)
            ?? .legacy(Int64(container.decode(Int.self, forKey: .position)))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(resolvedName, forKey: .name)
        try container.encode(desiredName, forKey: .desiredName)
        try container.encode(resolvedName, forKey: .resolvedName)
        try container.encode(systemImage, forKey: .systemImage)
        try container.encode(position, forKey: .position)
        try container.encode(sortKey, forKey: .sortKey)
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
    public var manualSortKey: SnipOrderKey
    public var manualPosition: Int64 {
        get { manualSortKey.legacyProjection }
        set { manualSortKey = .legacy(newValue) }
    }
    public var attachments: [SnipAttachment]

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
        manualSortKey: SnipOrderKey? = nil,
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
        self.manualSortKey = manualSortKey ?? .legacy(manualPosition)
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
                if lhs.manualSortKey != rhs.manualSortKey {
                    return lhs.manualSortKey < rhs.manualSortKey
                }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, requestID, createdAt, updatedAt, content, origin, source, listID, isDone
        case manualPosition, manualSortKey, attachments
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
        listID = try container.decode(UUID.self, forKey: .listID)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        manualSortKey = try container.decodeIfPresent(SnipOrderKey.self, forKey: .manualSortKey)
            ?? .legacy(container.decode(Int64.self, forKey: .manualPosition))
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
        try container.encode(manualSortKey, forKey: .manualSortKey)
        try container.encode(attachments, forKey: .attachments)
    }
}
