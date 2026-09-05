import Foundation
import SnipSnapCore

package enum CloudRecordKind: String, Codable, Equatable, Sendable {
  case snip, list

  var prefix: String { self == .snip ? "s-" : "l-" }
}

package enum CloudRecordBinding: Codable, Equatable, Sendable {
  case canonical
  case legacyQuarantined
  case invalid
}

package extension CloudRecordID {
  static func snip(_ id: UUID, in zone: CloudZoneID) -> CloudRecordID {
    canonical(id, kind: .snip, in: zone)
  }

  static func list(_ id: UUID, in zone: CloudZoneID) -> CloudRecordID {
    canonical(id, kind: .list, in: zone)
  }

  func binding(for id: UUID, kind: CloudRecordKind) -> CloudRecordBinding {
    if name == "\(kind.prefix)\(id.uuidString.lowercased())" { return .canonical }
    if UUID(uuidString: name) != nil { return .legacyQuarantined }
    return .invalid
  }

  private static func canonical(
    _ id: UUID,
    kind: CloudRecordKind,
    in zone: CloudZoneID
  ) -> CloudRecordID {
    CloudRecordID(zone: zone, name: "\(kind.prefix)\(id.uuidString.lowercased())")
  }
}

package enum CloudFieldPresence<Value: Equatable & Sendable>: Equatable, Sendable {
  case missing
  case value(Value)
}

extension CloudFieldPresence: Codable where Value: Codable {}

package struct CloudSnipPlacement: Codable, Equatable, Sendable {
  package var listID: UUID
  package var orderKey: SnipOrderKey

  package init(listID: UUID, orderKey: SnipOrderKey) {
    self.listID = listID
    self.orderKey = orderKey
  }
}

package struct CloudTypedSnipRecord: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let id: CloudRecordID
  package let domainID: UUID
  package let binding: CloudRecordBinding
  package let schemaVersion: Int
  package let requestID: CloudFieldPresence<UUID>
  package let createdAt: CloudFieldPresence<Date>
  package let updatedAt: CloudFieldPresence<Date>
  package let origin: CloudFieldPresence<String>
  package let text: CloudFieldPresence<String>
  package let source: CloudFieldPresence<SnipSource?>
  package let isDone: CloudFieldPresence<Bool>
  package let placement: CloudFieldPresence<CloudSnipPlacement>
  package let shadow: CloudRecordShadow

  package var localOriginFallback: SnipOrigin {
    guard case .value(let rawValue) = origin else { return .quickEntry }
    return SnipOrigin(rawValue: rawValue) ?? .quickEntry
  }
}

package struct CloudTypedListRecord: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let id: CloudRecordID
  package let domainID: UUID
  package let binding: CloudRecordBinding
  package let schemaVersion: Int
  package let desiredName: CloudFieldPresence<String>
  package let systemImage: CloudFieldPresence<String>
  package let color: CloudFieldPresence<SnipListColor?>?
  package let orderKey: CloudFieldPresence<SnipOrderKey>
  package let updatedAt: CloudFieldPresence<Date>
  package let shadow: CloudRecordShadow
}

package enum CloudFullRecordCodec {
  package static let schemaVersion = 2

  package static func snipDraft(
    _ snip: Snip,
    in zone: CloudZoneID
  ) throws -> CloudRecordDraft {
    try snipDraft(
      snip,
      recordID: .snip(snip.id, in: zone),
      requestID: snip.requestID,
      createdAt: snip.createdAt,
      originRaw: snip.origin.rawValue,
      base: nil
    )
  }

  package static func snipDraft(
    _ snip: Snip,
    accepted: CloudTypedSnipRecord
  ) throws -> CloudRecordDraft {
    guard accepted.domainID == snip.id else {
      throw CloudRecordError.invalidField("recordName")
    }
    return try snipDraft(
      snip,
      recordID: accepted.id,
      requestID: accepted.requestID.value(or: snip.requestID),
      createdAt: accepted.createdAt.value(or: snip.createdAt),
      originRaw: accepted.origin.value(or: snip.origin.rawValue),
      base: accepted.shadow
    )
  }

  private static func snipDraft(
    _ snip: Snip,
    recordID: CloudRecordID,
    requestID: UUID,
    createdAt: Date,
    originRaw: String,
    base: CloudRecordShadow?
  ) throws -> CloudRecordDraft {
    guard recordID.binding(for: snip.id, kind: .snip) != .invalid else {
      throw CloudRecordError.invalidField("recordName")
    }
    var encrypted: [String: CloudFieldValue] = [
      "requestID": .string(requestID.uuidString.lowercased()),
      "createdAt": .data(try encode(createdAt)),
      "updatedAt": .data(try encode(snip.updatedAt)),
      "origin": .string(originRaw),
      "text": .string(snip.content),
      "sourceState": .int64(snip.source == nil ? 0 : 1),
      "isDone": .int64(snip.isDone ? 1 : 0),
      "listID": .string(snip.listID.uuidString.lowercased()),
      "orderKey": .data(snip.manualSortKey.data),
    ]
    var removedEncrypted: Set<String> = []
    if let source = snip.source {
      encrypted["sourceValue"] = .data(try encode(source))
    } else {
      removedEncrypted.insert("sourceValue")
    }
    return CloudRecordDraft(
      id: recordID,
      recordType: "Snip",
      schemaVersion: schemaVersion,
      routingFields: [
        "schemaVersion": .int64(Int64(schemaVersion)),
        "snipID": .string(snip.id.uuidString.lowercased()),
      ],
      encryptedFields: encrypted,
      removedEncryptedFields: removedEncrypted,
      base: base
    )
  }

  package static func listDraft(
    _ list: SnipList,
    updatedAt: Date,
    in zone: CloudZoneID
  ) throws -> CloudRecordDraft {
    try listDraft(
      list,
      updatedAt: updatedAt,
      recordID: .list(list.id, in: zone),
      base: nil
    )
  }

  package static func listDraft(
    _ list: SnipList,
    updatedAt: Date,
    accepted: CloudTypedListRecord
  ) throws -> CloudRecordDraft {
    guard accepted.domainID == list.id else {
      throw CloudRecordError.invalidField("recordName")
    }
    return try listDraft(
      list,
      updatedAt: updatedAt,
      recordID: accepted.id,
      base: accepted.shadow
    )
  }

  private static func listDraft(
    _ list: SnipList,
    updatedAt: Date,
    recordID: CloudRecordID,
    base: CloudRecordShadow?
  ) throws -> CloudRecordDraft {
    guard recordID.binding(for: list.id, kind: .list) != .invalid else {
      throw CloudRecordError.invalidField("recordName")
    }
    return CloudRecordDraft(
      id: recordID,
      recordType: "List",
      schemaVersion: schemaVersion,
      routingFields: [
        "schemaVersion": .int64(Int64(schemaVersion)),
        "listID": .string(list.id.uuidString.lowercased()),
      ],
      encryptedFields: [
        "desiredName": .string(list.desiredName),
        "systemImage": .string(list.systemImage),
        "color": .data(try encode(list.color)),
        "orderKey": .data(list.sortKey.data),
        "updatedAt": .data(try encode(updatedAt)),
      ],
      base: base
    )
  }

  package static func snip(from snapshot: CloudRecordSnapshot) throws -> CloudTypedSnipRecord {
    guard snapshot.completeness == .full else { throw CloudRecordError.projectedSnapshot }
    guard snapshot.recordType == "Snip" else { throw CloudRecordError.wrongRecordType }
    let domainID = try requiredUUID(snapshot.routingFields, key: "snipID")
    let binding = snapshot.id.binding(for: domainID, kind: .snip)
    guard binding != .invalid else { throw CloudRecordError.invalidField("recordName") }
    return CloudTypedSnipRecord(
      storageVersion: 1,
      id: snapshot.id,
      domainID: domainID,
      binding: binding,
      schemaVersion: snapshot.schemaVersion,
      requestID: try uuidPresence(snapshot.encryptedFields, key: "requestID"),
      createdAt: try codablePresence(snapshot.encryptedFields, key: "createdAt", as: Date.self),
      updatedAt: try codablePresence(snapshot.encryptedFields, key: "updatedAt", as: Date.self),
      origin: try stringPresence(snapshot.encryptedFields, key: "origin"),
      text: try stringPresence(snapshot.encryptedFields, key: "text"),
      source: try sourcePresence(snapshot.encryptedFields),
      isDone: try boolPresence(snapshot.encryptedFields, key: "isDone"),
      placement: try placementPresence(snapshot.encryptedFields),
      shadow: snapshot.shadow
    )
  }

  package static func list(from snapshot: CloudRecordSnapshot) throws -> CloudTypedListRecord {
    guard snapshot.completeness == .full else { throw CloudRecordError.projectedSnapshot }
    guard snapshot.recordType == "List" else { throw CloudRecordError.wrongRecordType }
    let domainID = try requiredUUID(snapshot.routingFields, key: "listID")
    let binding = snapshot.id.binding(for: domainID, kind: .list)
    guard binding != .invalid else { throw CloudRecordError.invalidField("recordName") }
    return CloudTypedListRecord(
      storageVersion: 1,
      id: snapshot.id,
      domainID: domainID,
      binding: binding,
      schemaVersion: snapshot.schemaVersion,
      desiredName: try stringPresence(snapshot.encryptedFields, key: "desiredName"),
      systemImage: try stringPresence(snapshot.encryptedFields, key: "systemImage"),
      color: try codablePresence(snapshot.encryptedFields, key: "color", as: SnipListColor?.self),
      orderKey: try orderKeyPresence(snapshot.encryptedFields, key: "orderKey"),
      updatedAt: try codablePresence(snapshot.encryptedFields, key: "updatedAt", as: Date.self),
      shadow: snapshot.shadow
    )
  }

  private static func requiredUUID(
    _ fields: [String: CloudFieldValue], key: String
  ) throws -> UUID {
    guard case .string(let value)? = fields[key], let id = UUID(uuidString: value) else {
      throw CloudRecordError.missingField(key)
    }
    return id
  }

  private static func stringPresence(
    _ fields: [String: CloudFieldValue], key: String
  ) throws -> CloudFieldPresence<String> {
    guard let field = fields[key] else { return .missing }
    guard case .string(let value) = field else { throw CloudRecordError.invalidField(key) }
    return .value(value)
  }

  private static func uuidPresence(
    _ fields: [String: CloudFieldValue], key: String
  ) throws -> CloudFieldPresence<UUID> {
    switch try stringPresence(fields, key: key) {
    case .missing: return .missing
    case .value(let value):
      guard let id = UUID(uuidString: value) else { throw CloudRecordError.invalidField(key) }
      return .value(id)
    }
  }

  private static func boolPresence(
    _ fields: [String: CloudFieldValue], key: String
  ) throws -> CloudFieldPresence<Bool> {
    guard let field = fields[key] else { return .missing }
    guard case .int64(let value) = field, value == 0 || value == 1 else {
      throw CloudRecordError.invalidField(key)
    }
    return .value(value == 1)
  }

  private static func sourcePresence(
    _ fields: [String: CloudFieldValue]
  ) throws -> CloudFieldPresence<SnipSource?> {
    guard let state = fields["sourceState"] else { return .missing }
    guard case .int64(let value) = state else {
      throw CloudRecordError.invalidField("sourceState")
    }
    if value == 0 { return .value(nil) }
    guard value == 1, case .data(let data)? = fields["sourceValue"] else {
      throw CloudRecordError.invalidField("sourceValue")
    }
    return .value(try decode(SnipSource.self, from: data))
  }

  private static func placementPresence(
    _ fields: [String: CloudFieldValue]
  ) throws -> CloudFieldPresence<CloudSnipPlacement> {
    let list = fields["listID"]
    let order = fields["orderKey"]
    if list == nil, order == nil { return .missing }
    guard case .string(let listValue)? = list, let listID = UUID(uuidString: listValue),
      case .data(let orderData)? = order
    else { throw CloudRecordError.invalidField("placement") }
    return .value(CloudSnipPlacement(
      listID: listID, orderKey: try SnipOrderKey(data: orderData)))
  }

  private static func orderKeyPresence(
    _ fields: [String: CloudFieldValue], key: String
  ) throws -> CloudFieldPresence<SnipOrderKey> {
    guard let field = fields[key] else { return .missing }
    guard case .data(let data) = field else { throw CloudRecordError.invalidField(key) }
    return .value(try SnipOrderKey(data: data))
  }

  private static func codablePresence<Value: Codable & Equatable & Sendable>(
    _ fields: [String: CloudFieldValue], key: String, as: Value.Type
  ) throws -> CloudFieldPresence<Value> {
    guard let field = fields[key] else { return .missing }
    guard case .data(let data) = field else { throw CloudRecordError.invalidField(key) }
    return .value(try decode(Value.self, from: data))
  }

  private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    try JSONEncoder().encode(value)
  }

  private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw CloudRecordError.invalidField("encodedValue") }
  }
}

private extension CloudFieldPresence {
  func value(or fallback: Value) -> Value {
    switch self {
    case .missing: fallback
    case .value(let value): value
    }
  }
}
