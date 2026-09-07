import CryptoKit
import Foundation
import UniformTypeIdentifiers

public struct ClipboardRepresentation: Codable, Equatable, Sendable {
    public let type: String
    public let data: Data
    public init(type: String, data: Data) { self.type = type; self.data = data }
}

public struct ClipboardPayloadItem: Codable, Equatable, Sendable {
    public var representations: [ClipboardRepresentation]
    public init(representations: [ClipboardRepresentation]) { self.representations = representations }
}

public struct ClipboardOwnedFile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let relativePath: String
    public init(id: UUID = UUID(), name: String, relativePath: String) {
        self.id = id; self.name = name; self.relativePath = relativePath
    }
}

public struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var capturedAt: Date
    public var sourceApplication: String?
    public var sourceDeviceName: String?
    public var items: [ClipboardPayloadItem] {
        didSet { cachedPayloadFingerprint = Self.makeFingerprint(items) }
    }
    private var cachedPayloadFingerprint: String
    public var plainText: String
    public var pinnedAt: Date?
    public var modifiedAt: Date
    public var ownedFiles: [ClipboardOwnedFile]
    public var duplicateIDs: [UUID]
    public var hasBeenShared: Bool
    public var payloadFingerprint: String?

    public init(id: UUID = UUID(), capturedAt: Date = Date(), sourceApplication: String? = nil,
                items: [ClipboardPayloadItem], plainText: String? = nil, pinnedAt: Date? = nil,
                modifiedAt: Date? = nil, sourceDeviceName: String? = nil,
                ownedFiles: [ClipboardOwnedFile] = [], duplicateIDs: [UUID] = [], hasBeenShared: Bool = false, payloadFingerprint: String? = nil) {
        self.id = id; self.capturedAt = capturedAt; self.sourceApplication = sourceApplication
        self.items = items; self.cachedPayloadFingerprint = Self.makeFingerprint(items)
        self.plainText = plainText ?? Self.extractText(from: items)
        self.pinnedAt = pinnedAt; self.modifiedAt = modifiedAt ?? capturedAt
        self.sourceDeviceName = sourceDeviceName; self.ownedFiles = ownedFiles; self.duplicateIDs = duplicateIDs; self.hasBeenShared = hasBeenShared; self.payloadFingerprint = payloadFingerprint
    }

    public var isPinned: Bool { pinnedAt != nil }
    public var isSyncEligible: Bool { fileURLs.isEmpty || ((isPinned || hasBeenShared) && ownedFiles.count == fileURLs.count) }
    public var text: String { plainText.isEmpty ? fileURLs.map(\.lastPathComponent).joined(separator: ", ") : plainText }
    public var fileURLs: [URL] {
        items.flatMap(\.representations).filter { $0.type == "public.file-url" }
            .compactMap { String(data: $0.data, encoding: .utf8) }.compactMap(URL.init(string:))
    }
    public var imageRepresentations: [ClipboardRepresentation] {
        items.compactMap { Self.image(in: $0) }
    }
    public var standaloneImageRepresentations: [ClipboardRepresentation] {
        items.filter { !$0.representations.contains { $0.type == "public.file-url" } }.compactMap { Self.image(in: $0) }
    }
    public var searchText: String { [text, sourceApplication ?? "", fileURLs.map(\.lastPathComponent).joined(separator: " ")].joined(separator: " ") }
    public var byteCount: Int { items.flatMap(\.representations).reduce(0) { $0 + $1.data.count } }
    public var fingerprint: String { payloadFingerprint ?? cachedPayloadFingerprint }
    private static func makeFingerprint(_ items: [ClipboardPayloadItem]) -> String {
        var hash = SHA256()
        for item in items {
            hash.update(data: Data([0xfe]))
            for representation in item.representations.sorted(by: { $0.type < $1.type }) {
                hash.update(data: Data(representation.type.utf8)); hash.update(data: Data([0]))
                hash.update(data: representation.data); hash.update(data: Data([0xff]))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public func hasSamePayload(as other: ClipboardEntry) -> Bool { fingerprint == other.fingerprint }
    public static func extractText(from items: [ClipboardPayloadItem]) -> String {
        items.compactMap { item in
            item.representations.first { $0.type == "public.utf8-plain-text" || $0.type == "public.plain-text" }
                .flatMap { String(data: $0.data, encoding: .utf8) }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private static func image(in item: ClipboardPayloadItem) -> ClipboardRepresentation? {
        for preferred in ["public.png", "public.tiff", "public.jpeg"] {
            if let value = item.representations.first(where: { $0.type == preferred }) { return value }
        }
        return item.representations.first { UTType($0.type)?.conforms(to: .image) == true }
    }
    private enum CodingKeys: String, CodingKey { case id, capturedAt, sourceApplication, sourceDeviceName, items, plainText, pinnedAt, modifiedAt, ownedFiles, duplicateIDs, hasBeenShared, payloadFingerprint }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        sourceApplication = try c.decodeIfPresent(String.self, forKey: .sourceApplication)
        sourceDeviceName = try c.decodeIfPresent(String.self, forKey: .sourceDeviceName)
        items = try c.decode([ClipboardPayloadItem].self, forKey: .items)
        cachedPayloadFingerprint = Self.makeFingerprint(items)
        plainText = try c.decodeIfPresent(String.self, forKey: .plainText) ?? Self.extractText(from: items)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? capturedAt
        ownedFiles = try c.decodeIfPresent([ClipboardOwnedFile].self, forKey: .ownedFiles) ?? []
        duplicateIDs = try c.decodeIfPresent([UUID].self, forKey: .duplicateIDs) ?? []
        hasBeenShared = try c.decodeIfPresent(Bool.self, forKey: .hasBeenShared) ?? false
        payloadFingerprint = try c.decodeIfPresent(String.self, forKey: .payloadFingerprint)
    }
}
