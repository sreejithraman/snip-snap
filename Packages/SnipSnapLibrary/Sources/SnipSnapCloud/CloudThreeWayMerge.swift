import CryptoKit
import Foundation
import SnipSnapCore

package struct CloudSnipMergeFields: Codable, Equatable, Sendable {
  package var id: UUID
  package var requestID: UUID
  package var createdAt: Date
  package var originRaw: String
  package var text: String
  package var source: SnipSource?
  package var isDone: Bool
  package var placement: CloudSnipPlacement
  package var updatedAt: Date

  package init(
    id: UUID,
    requestID: UUID,
    createdAt: Date,
    originRaw: String,
    text: String,
    source: SnipSource?,
    isDone: Bool,
    placement: CloudSnipPlacement,
    updatedAt: Date
  ) {
    self.id = id
    self.requestID = requestID
    self.createdAt = createdAt
    self.originRaw = originRaw
    self.text = text
    self.source = source
    self.isDone = isDone
    self.placement = placement
    self.updatedAt = updatedAt
  }
}

package struct CloudListMergeFields: Codable, Equatable, Sendable {
  package var id: UUID
  package var desiredName: String
  package var systemImage: String
  package var orderKey: SnipOrderKey
  package var updatedAt: Date

  package init(
    id: UUID,
    desiredName: String,
    systemImage: String,
    orderKey: SnipOrderKey,
    updatedAt: Date
  ) {
    self.id = id
    self.desiredName = desiredName
    self.systemImage = systemImage
    self.orderKey = orderKey
    self.updatedAt = updatedAt
  }
}

package enum CloudSnipConflictField: String, Codable, Equatable, Hashable, Sendable {
  case text, source, isDone, placement
}

package enum CloudListConflictField: String, Codable, Equatable, Hashable, Sendable {
  case desiredName, systemImage
}

package struct CloudSnipConflictPayload: Codable, Equatable, Sendable {
  package let fields: Set<CloudSnipConflictField>
  package let local: CloudSnipMergeFields
  package let server: CloudSnipMergeFields
}

package struct CloudListConflictPayload: Codable, Equatable, Sendable {
  package let fields: Set<CloudListConflictField>
  package let local: CloudListMergeFields
  package let server: CloudListMergeFields
}

package struct CloudSnipDeleteConflictPayload: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let localWasDeleted: Bool
  package let server: CloudSnipMergeFields

  package init(server: CloudSnipMergeFields) {
    storageVersion = 1
    localWasDeleted = true
    self.server = server
  }
}

package struct CloudSnipRemoteDeleteConflictPayload: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let local: CloudSnipMergeFields
  package let attachmentIDs: [UUID]

  package init(local: CloudSnipMergeFields, attachmentIDs: [UUID]) {
    storageVersion = 1
    self.local = local
    self.attachmentIDs = attachmentIDs.sorted { $0.uuidString < $1.uuidString }
  }
}

package struct CloudListDeleteConflictPayload: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let localWasDeleted: Bool
  package let server: CloudListMergeFields

  package init(server: CloudListMergeFields) {
    storageVersion = 1
    localWasDeleted = true
    self.server = server
  }
}

package struct CloudSnipMergeResult: Equatable, Sendable {
  package let merged: CloudSnipMergeFields
  package let conflict: CloudSnipConflictPayload?
}

package struct CloudListMergeResult: Equatable, Sendable {
  package let merged: CloudListMergeFields
  package let conflict: CloudListConflictPayload?
}

package enum CloudMergeError: Error, Codable, Equatable, Sendable {
  case immutableMetadata
}

package enum CloudConflictKey {
  package static func make(
    namespaceKey: String,
    recordID: CloudRecordID,
    ancestorSystemFields: Data,
    serverSystemFields: Data
  ) -> String {
    var bytes = Data("snipsnap-conflict-v1".utf8)
    append(namespaceKey, to: &bytes)
    append(recordID.zone.ownerName, to: &bytes)
    append(recordID.zone.name, to: &bytes)
    append(recordID.name, to: &bytes)
    append(ancestorSystemFields, to: &bytes)
    append(serverSystemFields, to: &bytes)
    return Data(SHA256.hash(data: bytes)).base64EncodedString()
  }

  package static func recoveryID(for key: String) -> UUID {
    let bytes = Array(SHA256.hash(data: Data("snipsnap-recovery|\(key)".utf8)).prefix(16))
    var uuid: uuid_t = (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    )
    uuid.6 = (uuid.6 & 0x0F) | 0x50
    uuid.8 = (uuid.8 & 0x3F) | 0x80
    return UUID(uuid: uuid)
  }

  private static func append(_ value: String, to data: inout Data) {
    append(Data(value.utf8), to: &data)
  }

  private static func append(_ value: Data, to data: inout Data) {
    var count = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
    data.append(value)
  }
}

package enum CloudThreeWayMerge {
  package static func snip(
    base: CloudSnipMergeFields,
    local: CloudSnipMergeFields,
    server: CloudSnipMergeFields
  ) throws -> CloudSnipMergeResult {
    let baseMetadata = (base.id, base.requestID, base.createdAt, base.originRaw)
    guard metadata(local) == baseMetadata, metadata(server) == baseMetadata else {
      throw CloudMergeError.immutableMetadata
    }

    let text = field(base: base.text, local: local.text, server: server.text)
    let source = field(base: base.source, local: local.source, server: server.source)
    let isDone = field(base: base.isDone, local: local.isDone, server: server.isDone)
    let placement = placement(base: base.placement, local: local.placement, server: server.placement)
    var conflictFields: Set<CloudSnipConflictField> = []
    if text.conflict { conflictFields.insert(.text) }
    if source.conflict { conflictFields.insert(.source) }
    if isDone.conflict { conflictFields.insert(.isDone) }
    if placement.conflict { conflictFields.insert(.placement) }
    let merged = CloudSnipMergeFields(
      id: base.id,
      requestID: base.requestID,
      createdAt: base.createdAt,
      originRaw: base.originRaw,
      text: text.value,
      source: source.value,
      isDone: isDone.value,
      placement: placement.value,
      updatedAt: server.updatedAt
    )
    return CloudSnipMergeResult(
      merged: merged,
      conflict: conflictFields.isEmpty ? nil : CloudSnipConflictPayload(
        fields: conflictFields, local: local, server: server)
    )
  }

  package static func list(
    base: CloudListMergeFields,
    local: CloudListMergeFields,
    server: CloudListMergeFields
  ) throws -> CloudListMergeResult {
    guard local.id == base.id, server.id == base.id else {
      throw CloudMergeError.immutableMetadata
    }
    let desiredName = field(
      base: base.desiredName, local: local.desiredName, server: server.desiredName)
    let systemImage = field(
      base: base.systemImage, local: local.systemImage, server: server.systemImage)
    let orderKey = order(
      base: base.orderKey, local: local.orderKey, server: server.orderKey)
    var conflictFields: Set<CloudListConflictField> = []
    if desiredName.conflict { conflictFields.insert(.desiredName) }
    if systemImage.conflict { conflictFields.insert(.systemImage) }
    let merged = CloudListMergeFields(
      id: server.id,
      desiredName: desiredName.value,
      systemImage: systemImage.value,
      orderKey: orderKey,
      updatedAt: server.updatedAt
    )
    return CloudListMergeResult(
      merged: merged,
      conflict: conflictFields.isEmpty ? nil : CloudListConflictPayload(
        fields: conflictFields, local: local, server: server)
    )
  }

  private static func metadata(
    _ value: CloudSnipMergeFields
  ) -> (UUID, UUID, Date, String) {
    (value.id, value.requestID, value.createdAt, value.originRaw)
  }

  private static func field<Value: Equatable>(
    base: Value,
    local: Value,
    server: Value
  ) -> (value: Value, conflict: Bool) {
    if local == server { return (local, false) }
    if local == base { return (server, false) }
    if server == base { return (local, false) }
    return (server, true)
  }

  private static func placement(
    base: CloudSnipPlacement,
    local: CloudSnipPlacement,
    server: CloudSnipPlacement
  ) -> (value: CloudSnipPlacement, conflict: Bool) {
    if local == server { return (local, false) }
    if local == base { return (server, false) }
    if server == base { return (local, false) }
    if local.listID == server.listID { return (server, false) }
    return (server, true)
  }

  private static func order(
    base: SnipOrderKey,
    local: SnipOrderKey,
    server: SnipOrderKey
  ) -> SnipOrderKey {
    if local == server { return local }
    if local == base { return server }
    if server == base { return local }
    return server
  }
}
