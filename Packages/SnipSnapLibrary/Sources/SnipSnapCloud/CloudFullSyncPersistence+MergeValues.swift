import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  static func acceptedInput(_ entity: CloudAcceptedEntity) -> CloudAcceptedEntityInput {
    CloudAcceptedEntityInput(
      reference: entity.reference,
      identity: entity.identity,
      schemaVersion: entity.schemaVersion,
      acceptedData: entity.acceptedData,
      presenceData: entity.presenceData,
      shadowData: entity.shadowData,
      systemFields: entity.systemFields,
      dependencyListID: entity.dependencyListID
    )
  }

  static func snipRecord(_ entity: CloudAcceptedEntity) throws -> CloudTypedSnipRecord {
    try CloudFullRecordCodec.snip(from: snapshot(entity))
  }

  static func listRecord(_ entity: CloudAcceptedEntity) throws -> CloudTypedListRecord {
    try CloudFullRecordCodec.list(from: snapshot(entity))
  }

  private static func snapshot(_ entity: CloudAcceptedEntity) throws -> CloudRecordSnapshot {
    let shadow = try shadow(entity)
    guard shadow.systemFields == entity.systemFields else { throw CloudRecordError.invalidShadow }
    let decoded = try CloudKitRecordMapper.snapshot(shadow.record())
    return CloudRecordSnapshot(
      id: decoded.id,
      recordType: decoded.recordType,
      schemaVersion: decoded.schemaVersion,
      routingFields: decoded.routingFields,
      encryptedFields: decoded.encryptedFields,
      assetFields: decoded.assetFields,
      shadow: shadow,
      completeness: decoded.completeness
    )
  }

  static func shadow(_ entity: CloudAcceptedEntity) throws -> CloudRecordShadow {
    try CloudRecordShadow(data: entity.shadowData)
  }

  static func snipFields(_ record: CloudTypedSnipRecord) throws -> CloudSnipMergeFields {
    CloudSnipMergeFields(
      id: record.domainID,
      requestID: value(record.requestID, default: record.domainID),
      createdAt: value(record.createdAt, default: Date(timeIntervalSince1970: 0)),
      originRaw: value(record.origin, default: SnipOrigin.quickEntry.rawValue),
      text: try required(record.text, "text"),
      source: value(record.source, default: nil),
      isDone: value(record.isDone, default: false),
      placement: try value(record.placement, default: CloudSnipPlacement(
        listID: SnipList.inbox.id,
        orderKey: try legacyOrderKey(record.domainID)
      )),
      updatedAt: value(record.updatedAt, default: Date(timeIntervalSince1970: 0))
    )
  }

  static func snipFields(
    _ snip: Snip,
    accepted: CloudTypedSnipRecord?
  ) -> CloudSnipMergeFields {
    CloudSnipMergeFields(
      id: snip.id,
      requestID: accepted.map { value($0.requestID, default: snip.requestID) } ?? snip.requestID,
      createdAt: accepted.map { value($0.createdAt, default: snip.createdAt) } ?? snip.createdAt,
      originRaw: accepted.map { value($0.origin, default: snip.origin.rawValue) }
        ?? snip.origin.rawValue,
      text: snip.content,
      source: snip.source,
      isDone: snip.isDone,
      placement: CloudSnipPlacement(listID: snip.listID, orderKey: snip.manualSortKey),
      updatedAt: snip.updatedAt
    )
  }

  static func listFields(_ record: CloudTypedListRecord) throws -> CloudListMergeFields {
    CloudListMergeFields(
      id: record.domainID,
      desiredName: try required(record.desiredName, "desiredName"),
      systemImage: try required(record.systemImage, "systemImage"),
      orderKey: try required(record.orderKey, "orderKey"),
      updatedAt: value(record.updatedAt, default: Date(timeIntervalSince1970: 0))
    )
  }

  static func listFields(_ list: SnipList, updatedAt: Date) -> CloudListMergeFields {
    CloudListMergeFields(
      id: list.id,
      desiredName: list.desiredName,
      systemImage: list.systemImage,
      orderKey: list.sortKey,
      updatedAt: updatedAt
    )
  }

  static func sameSnipFields(
    _ lhs: CloudSnipMergeFields,
    _ rhs: CloudSnipMergeFields
  ) -> Bool {
    lhs.id == rhs.id
      && lhs.requestID == rhs.requestID
      && lhs.createdAt == rhs.createdAt
      && lhs.originRaw == rhs.originRaw
      && lhs.text == rhs.text
      && lhs.source == rhs.source
      && lhs.isDone == rhs.isDone
      && lhs.placement == rhs.placement
  }

  static func sameListFields(
    _ lhs: CloudListMergeFields,
    _ rhs: CloudListMergeFields
  ) -> Bool {
    lhs.id == rhs.id
      && lhs.desiredName == rhs.desiredName
      && lhs.systemImage == rhs.systemImage
      && lhs.orderKey == rhs.orderKey
  }

  static func localMutation(_ value: CloudSnipMergeFields) -> CloudLocalSnipMutation {
    CloudLocalSnipMutation(
      snipID: value.id,
      requestID: value.requestID,
      createdAt: value.createdAt,
      updatedAt: value.updatedAt,
      content: value.text,
      origin: SnipOrigin(rawValue: value.originRaw) ?? .quickEntry,
      source: value.source,
      listID: value.placement.listID,
      isDone: value.isDone,
      orderKey: value.placement.orderKey
    )
  }

  static func localList(_ value: CloudListMergeFields) -> SnipList {
    SnipList(
      id: value.id,
      desiredName: value.desiredName,
      resolvedName: value.desiredName,
      systemImage: value.systemImage,
      sortKey: value.orderKey
    )
  }

  static func recoveredSnip(
    _ payload: CloudSnipConflictPayload,
    key: String,
    attachments: [SnipAttachment]
  ) -> RecoveredSnip {
    let recoveryID = CloudConflictKey.recoveryID(for: key)
    let value = payload.local
    let snip = Snip(
      id: recoveryID,
      requestID: recoveryID,
      createdAt: value.createdAt,
      updatedAt: value.updatedAt,
      content: value.text,
      origin: SnipOrigin(rawValue: value.originRaw) ?? .quickEntry,
      source: value.source,
      listID: value.placement.listID,
      isDone: value.isDone,
      manualSortKey: value.placement.orderKey,
      attachments: attachments
    )
    return RecoveredSnip(
      id: recoveryID,
      currentSnipID: value.id,
      recovered: snip,
      conflictingFields: Set(payload.fields.map { field in
        switch field {
        case .text: .text
        case .source: .source
        case .isDone: .done
        case .placement: .placement
        }
      })
    )
  }

  static func recoveredList(
    _ payload: CloudListConflictPayload,
    key: String
  ) -> RecoveredListEdit {
    RecoveredListEdit(
      id: CloudConflictKey.recoveryID(for: key),
      currentListID: payload.local.id,
      recovered: localList(payload.local),
      conflictingFields: Set(payload.fields.map { field in
        switch field {
        case .desiredName: .name
        case .systemImage: .icon
        }
      })
    )
  }

  private static func legacyOrderKey(_ id: UUID) throws -> SnipOrderKey {
    var data = Data()
    withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
    data.append(0x80)
    return try SnipOrderKey(data: data)
  }

  private static func required<Value>(
    _ presence: CloudFieldPresence<Value>,
    _ key: String
  ) throws -> Value {
    guard case .value(let value) = presence else { throw CloudRecordError.missingField(key) }
    return value
  }

  private static func value<Value>(
    _ presence: CloudFieldPresence<Value>,
    default fallback: @autoclosure () throws -> Value
  ) rethrows -> Value {
    switch presence {
    case .missing: try fallback()
    case .value(let value): value
    }
  }

  static func storageIdentity(_ id: CloudRecordID) -> CloudTextStorageIdentity {
    CloudTextStorageIdentity(
      zoneName: id.zone.name,
      ownerName: id.zone.ownerName,
      recordName: id.name
    )
  }

  static func recordID(_ identity: CloudTextStorageIdentity) -> CloudRecordID {
    CloudRecordID(
      zone: CloudZoneID(name: identity.zoneName, ownerName: identity.ownerName),
      name: identity.recordName
    )
  }
}
