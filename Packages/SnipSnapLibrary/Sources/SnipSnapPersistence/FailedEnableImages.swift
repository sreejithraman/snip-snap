import CryptoKit
import Foundation
import SnipSnapCore

package enum FailedEnableEvidenceError: Error, Equatable, Sendable {
  case unavailable, unsupported, changed, reviewRequired
}

/// Required nullable fields encode an explicit null; a missing key fails decoding.
package struct FailedEnableNullable<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
  package let value: Value?
  package init(_ value: Value?) { self.value = value }
  package init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { value = nil } else { value = try container.decode(Value.self) }
  }
  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    if let value { try container.encode(value) } else { try container.encodeNil() }
  }
}

package enum FailedEnableEncoding {
  package static func json<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  package static func digest(_ bytes: Data) -> String {
    hex(checksum(bytes))
  }
  package static func checksum(_ bytes: Data) -> Data {
    Data(SHA256.hash(data: bytes))
  }
  package static func hex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
  package static func digest<Value: Encodable>(_ value: Value) throws -> String {
    digest(try json(value))
  }
  package static func uuid(_ value: UUID) -> String { value.uuidString.lowercased() }
  package static func uuid(_ value: String) throws -> UUID {
    guard let result = UUID(uuidString: value), uuid(result) == value else {
      throw FailedEnableEvidenceError.unsupported
    }
    return result
  }
  package static func date(_ value: Date) throws -> String {
    let seconds = value.timeIntervalSinceReferenceDate
    guard seconds.isFinite else { throw FailedEnableEvidenceError.unsupported }
    return String(format: "%016llx", seconds.bitPattern)
  }
  package static func date(_ value: String) throws -> Date {
    guard value.count == 16, let bits = UInt64(value, radix: 16),
      String(format: "%016llx", bits) == value,
      Double(bitPattern: bits).isFinite
    else { throw FailedEnableEvidenceError.unsupported }
    return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
  }
  package static func revision(_ value: String) throws -> UInt64 {
    guard let revision = UInt64(value), String(revision) == value else {
      throw FailedEnableEvidenceError.unsupported
    }
    return revision
  }
}

package struct FailedEnableSource: Codable, Equatable, Sendable {
  package struct AgentContext: Codable, Equatable, Sendable {
    let sessionTitle: FailedEnableNullable<String>
    let branchName: FailedEnableNullable<String>
    init(_ value: SnipAgentContext) {
      sessionTitle = .init(value.sessionTitle)
      branchName = .init(value.branchName)
    }
    var domain: SnipAgentContext {
      var result = SnipAgentContext()
      result.sessionTitle = sessionTitle.value
      result.branchName = branchName.value
      return result
    }
  }
  let applicationName: String
  let windowTitle: FailedEnableNullable<String>
  let url: FailedEnableNullable<String>
  let agentContext: FailedEnableNullable<AgentContext>
  package init(_ value: SnipSource) {
    applicationName = value.applicationName
    windowTitle = .init(value.windowTitle)
    url = .init(value.url)
    agentContext = .init(value.agentContext.map(AgentContext.init))
  }
  package var domain: SnipSource {
    SnipSource(applicationName: applicationName, windowTitle: windowTitle.value,
      url: url.value, agentContext: agentContext.value?.domain)
  }
}

package struct FailedEnableIdentity: Codable, Equatable, Hashable, Sendable {
  package let owner: String
  package let zone: String
  package let name: String
  package init(_ identity: CloudTextStorageIdentity) {
    owner = identity.ownerName
    zone = identity.zoneName
    name = identity.recordName
  }
  package var domain: CloudTextStorageIdentity {
    CloudTextStorageIdentity(zoneName: zone, ownerName: owner, recordName: name)
  }
}

package struct FailedEnableReference: Codable, Equatable, Hashable, Sendable {
  package let kind: CloudEntityKind
  package let domainID: String
  package init(_ reference: CloudEntityReference) {
    kind = reference.kind
    domainID = FailedEnableEncoding.uuid(reference.domainID)
  }
  package var domain: CloudEntityReference {
    get throws { CloudEntityReference(kind: kind, domainID: try FailedEnableEncoding.uuid(domainID)) }
  }
  package var sortKey: String { "\(kind.rawValue)|\(domainID)" }
}

package struct FailedEnableAttachment: Codable, Equatable, Sendable {
  package struct Availability: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable { case embedded, remote }
    package let kind: Kind
    package let sha256: String
    package let recordIdentity: FailedEnableNullable<FailedEnableIdentity>
    package let size: String
    private enum Keys: String, CodingKey { case kind, sha256, recordIdentity, size }
    init(kind: Kind, sha256: String, recordIdentity: FailedEnableNullable<FailedEnableIdentity>, size: String) {
      self.kind = kind
      self.sha256 = sha256
      self.recordIdentity = recordIdentity
      self.size = size
    }
    package init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: Keys.self)
      kind = try values.decode(Kind.self, forKey: .kind)
      sha256 = try values.decode(String.self, forKey: .sha256)
      switch kind {
      case .embedded: recordIdentity = .init(nil); size = ""
      case .remote:
        recordIdentity = .init(try values.decode(FailedEnableIdentity.self, forKey: .recordIdentity))
        size = try values.decode(String.self, forKey: .size)
      }
    }
    package func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: Keys.self)
      try values.encode(kind, forKey: .kind)
      try values.encode(sha256, forKey: .sha256)
      if kind == .remote {
        guard let identity = recordIdentity.value else { throw FailedEnableEvidenceError.unsupported }
        try values.encode(identity, forKey: .recordIdentity)
        try values.encode(size, forKey: .size)
      }
    }
  }
  package let id: String
  package let fileName: String
  package let relativePath: String
  package let contentType: FailedEnableNullable<String>
  package let byteCount: String
  package let availability: Availability

  init(_ attachment: SnipAttachment, bytes: Data) throws {
    guard Int64(bytes.count) == attachment.byteCount else { throw FailedEnableEvidenceError.unavailable }
    id = FailedEnableEncoding.uuid(attachment.id)
    fileName = attachment.fileName
    relativePath = attachment.relativePath
    contentType = .init(attachment.contentType)
    byteCount = String(attachment.byteCount)
    availability = Availability(kind: .embedded, sha256: FailedEnableEncoding.digest(bytes),
      recordIdentity: .init(nil), size: "")
  }
  var domain: SnipAttachment {
    get throws {
      guard let count = Int64(byteCount), count >= 0, String(count) == byteCount else {
        throw FailedEnableEvidenceError.unsupported
      }
      return SnipAttachment(id: try FailedEnableEncoding.uuid(id), fileName: fileName,
        relativePath: relativePath, contentType: contentType.value, byteCount: count)
    }
  }
}

package struct FailedEnableSnipImage: Codable, Equatable, Sendable {
  package let kind: String
  package let id: String
  package let requestID: String
  package let createdAt: String
  package let updatedAt: String
  package let originRaw: String
  package let text: String
  package let source: FailedEnableNullable<FailedEnableSource>
  package let isDone: Bool
  package let pinnedAt: FailedEnableNullable<String>
  package let listID: String
  package let orderKey: Data
  package let attachments: [FailedEnableAttachment]

  package init(_ snip: Snip, attachmentData: [UUID: Data]) throws {
    kind = "snip"
    id = FailedEnableEncoding.uuid(snip.id)
    requestID = FailedEnableEncoding.uuid(snip.requestID)
    createdAt = try FailedEnableEncoding.date(snip.createdAt)
    updatedAt = try FailedEnableEncoding.date(snip.updatedAt)
    originRaw = snip.origin.rawValue
    text = snip.content
    source = .init(snip.source.map(FailedEnableSource.init))
    isDone = snip.isDone
    pinnedAt = .init(try snip.pinnedAt.map(FailedEnableEncoding.date))
    listID = FailedEnableEncoding.uuid(snip.listID)
    orderKey = snip.manualSortKey.data
    attachments = try snip.attachments.map {
      guard let bytes = attachmentData[$0.id] else { throw FailedEnableEvidenceError.unavailable }
      return try FailedEnableAttachment($0, bytes: bytes)
    }
  }
  package var domain: Snip {
    get throws {
      guard kind == "snip", let origin = SnipOrigin(rawValue: originRaw),
        pinnedAt.value == nil || !isDone
      else { throw FailedEnableEvidenceError.unsupported }
      return try Snip(id: FailedEnableEncoding.uuid(id), requestID: FailedEnableEncoding.uuid(requestID),
        createdAt: FailedEnableEncoding.date(createdAt), updatedAt: FailedEnableEncoding.date(updatedAt),
        content: text, origin: origin, source: source.value?.domain,
        listID: FailedEnableEncoding.uuid(listID), isDone: isDone,
        pinnedAt: pinnedAt.value.map(FailedEnableEncoding.date),
        manualSortKey: SnipOrderKey(data: orderKey), attachments: attachments.map { try $0.domain })
    }
  }
}

package struct FailedEnableListImage: Codable, Equatable, Sendable {
  package let kind: String
  package let id: String
  package let desiredName: String
  package let resolvedName: String
  package let systemImage: String
  package let colorPreset: FailedEnableNullable<String>
  package let orderKey: Data
  package init(_ list: SnipList) {
    kind = "list"
    id = FailedEnableEncoding.uuid(list.id)
    desiredName = list.desiredName
    resolvedName = list.resolvedName
    systemImage = list.systemImage
    colorPreset = .init(list.color?.rawValue)
    orderKey = list.sortKey.data
  }
  package var domain: SnipList {
    get throws {
      guard kind == "list", colorPreset.value == nil
        || colorPreset.value.flatMap(SnipListColorPreset.init(rawValue:)) != nil
      else { throw FailedEnableEvidenceError.unsupported }
      return try SnipList(id: FailedEnableEncoding.uuid(id), desiredName: desiredName,
        resolvedName: resolvedName, systemImage: systemImage,
        color: colorPreset.value.flatMap(SnipListColorPreset.init(rawValue:)),
        sortKey: SnipOrderKey(data: orderKey))
    }
  }
}

package enum FailedEnableImage: Codable, Equatable, Sendable {
  case snip(FailedEnableSnipImage), list(FailedEnableListImage)
  private enum KindKey: String, CodingKey { case kind }
  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: KindKey.self)
    switch try values.decode(String.self, forKey: .kind) {
    case "snip": self = .snip(try FailedEnableSnipImage(from: decoder))
    case "list": self = .list(try FailedEnableListImage(from: decoder))
    default: throw FailedEnableEvidenceError.unsupported
    }
  }
  package func encode(to encoder: any Encoder) throws {
    switch self {
    case .snip(let image): try image.encode(to: encoder)
    case .list(let image): try image.encode(to: encoder)
    }
  }
  package var reference: FailedEnableReference {
    switch self {
    case .snip(let image): FailedEnableReference(kind: .snip, domainID: image.id)
    case .list(let image): FailedEnableReference(kind: .list, domainID: image.id)
    }
  }
  package func validate(blobs: [String: Data]) throws {
    switch self {
    case .list(let image): _ = try image.domain
    case .snip(let image):
      _ = try image.domain
      guard Set(image.attachments.map(\.id)).count == image.attachments.count else {
        throw FailedEnableEvidenceError.unsupported
      }
      for attachment in image.attachments where attachment.availability.kind == .embedded {
        guard let bytes = blobs[attachment.availability.sha256],
          FailedEnableEncoding.digest(bytes) == attachment.availability.sha256,
          String(bytes.count) == attachment.byteCount
        else { throw FailedEnableEvidenceError.unavailable }
      }
    }
  }
}

private extension FailedEnableReference {
  init(kind: CloudEntityKind, domainID: String) { self.kind = kind; self.domainID = domainID }
}
