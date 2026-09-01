import Foundation
import SnipSnapCore
import SwiftData

@Model
final class StoredSnipRecord {
  @Attribute(.unique) var id: UUID
  var requestID: UUID
  var createdAt: Date
  var updatedAt: Date
  var content: String
  var origin: String
  var sourceApplicationName: String?
  var sourceWindowTitle: String?
  var sourceURL: String?
  var listID: UUID
  var isDone: Bool
  var manualPosition: Int64

  init(_ snip: Snip) {
    id = snip.id
    requestID = snip.requestID
    createdAt = snip.createdAt
    updatedAt = snip.updatedAt
    content = snip.content
    origin = snip.origin.rawValue
    sourceApplicationName = snip.source?.applicationName
    sourceWindowTitle = snip.source?.windowTitle
    sourceURL = snip.source?.url
    listID = snip.listID
    isDone = snip.isDone
    manualPosition = snip.manualPosition
  }

  func update(from snip: Snip) {
    requestID = snip.requestID
    createdAt = snip.createdAt
    updatedAt = snip.updatedAt
    content = snip.content
    origin = snip.origin.rawValue
    sourceApplicationName = snip.source?.applicationName
    sourceWindowTitle = snip.source?.windowTitle
    sourceURL = snip.source?.url
    listID = snip.listID
    isDone = snip.isDone
    manualPosition = snip.manualPosition
  }
}

@Model
final class StoredListRecord {
  @Attribute(.unique) var id: UUID
  var name: String
  var systemImage: String
  var position: Int

  init(_ list: SnipList) {
    id = list.id
    name = list.name
    systemImage = list.systemImage
    position = list.position
  }

  func update(from list: SnipList) {
    name = list.name
    systemImage = list.systemImage
    position = list.position
  }
}

@Model
final class StoredAttachmentRecord {
  @Attribute(.unique) var id: UUID
  var fileName: String
  var relativePath: String
  var contentType: String?
  var byteCount: Int64

  init(_ attachment: SnipAttachment) {
    id = attachment.id
    fileName = attachment.fileName
    relativePath = attachment.relativePath
    contentType = attachment.contentType
    byteCount = attachment.byteCount
  }

  func update(from attachment: SnipAttachment) {
    fileName = attachment.fileName
    relativePath = attachment.relativePath
    contentType = attachment.contentType
    byteCount = attachment.byteCount
  }
}

@Model
final class StoredSnipAttachmentReference {
  @Attribute(.unique) var id: String
  var snipID: UUID
  var attachmentID: UUID
  var position: Int

  init(snipID: UUID, attachmentID: UUID, position: Int) {
    id = Self.identifier(snipID: snipID, attachmentID: attachmentID)
    self.snipID = snipID
    self.attachmentID = attachmentID
    self.position = position
  }

  static func identifier(snipID: UUID, attachmentID: UUID) -> String {
    "\(snipID.uuidString)/\(attachmentID.uuidString)"
  }

  func update(position: Int) {
    self.position = position
  }
}

@Model
final class StoredCloudAttachmentPublication {
  @Attribute(.unique) var id: String
  var namespaceKey: String
  var attachmentID: UUID
  var snipID: UUID
  var position: Int
  var fileName: String
  var contentType: String?
  var byteCount: Int64
  var sha256: Data
  var isLocallyPresent: Bool
  var sourceRelativePath: String?
  var uploadRelativePath: String?
  var metadataZoneName: String
  var metadataOwnerName: String
  var metadataRecordName: String
  var payloadZoneName: String
  var payloadOwnerName: String
  var payloadRecordName: String
  var payloadAccepted: Bool
  var payloadShadowData: Data?
  var payloadSystemFields: Data?
  var metadataAccepted: Bool
  var metadataShadowData: Data?
  var metadataSystemFields: Data?
  var priorPayloadZoneName: String?
  var priorPayloadOwnerName: String?
  var priorPayloadRecordName: String?
  var priorPayloadShadowData: Data?
  var lastFailure: String?
  var revision: UInt64

  init(
    namespaceKey: String,
    attachmentID: UUID,
    snipID: UUID,
    position: Int,
    fileName: String,
    contentType: String?,
    byteCount: Int64,
    sha256: Data,
    sourceRelativePath: String?,
    metadataIdentity: CloudTextStorageIdentity,
    payloadIdentity: CloudTextStorageIdentity
  ) {
    id = Self.key(namespaceKey: namespaceKey, attachmentID: attachmentID)
    self.namespaceKey = namespaceKey
    self.attachmentID = attachmentID
    self.snipID = snipID
    self.position = position
    self.fileName = fileName
    self.contentType = contentType
    self.byteCount = byteCount
    self.sha256 = sha256
    isLocallyPresent = true
    self.sourceRelativePath = sourceRelativePath
    uploadRelativePath = nil
    metadataZoneName = metadataIdentity.zoneName
    metadataOwnerName = metadataIdentity.ownerName
    metadataRecordName = metadataIdentity.recordName
    payloadZoneName = payloadIdentity.zoneName
    payloadOwnerName = payloadIdentity.ownerName
    payloadRecordName = payloadIdentity.recordName
    payloadAccepted = false
    payloadShadowData = nil
    payloadSystemFields = nil
    metadataAccepted = false
    metadataShadowData = nil
    metadataSystemFields = nil
    priorPayloadZoneName = nil
    priorPayloadOwnerName = nil
    priorPayloadRecordName = nil
    priorPayloadShadowData = nil
    lastFailure = nil
    revision = 1
  }

  static func key(namespaceKey: String, attachmentID: UUID) -> String {
    "\(namespaceKey)|attachment|\(attachmentID.uuidString.lowercased())"
  }
}

@Model
final class StoredCloudAttachmentCleanup {
  @Attribute(.unique) var id: String
  var namespaceKey: String
  var zoneName: String
  var ownerName: String
  var recordName: String
  var shadowData: Data?
  var blockedByAttachmentID: UUID?
  var lastFailure: String?
  var revision: UInt64

  init(
    namespaceKey: String,
    identity: CloudTextStorageIdentity,
    shadowData: Data?,
    blockedByAttachmentID: UUID? = nil
  ) {
    id = Self.key(namespaceKey: namespaceKey, identity: identity)
    self.namespaceKey = namespaceKey
    zoneName = identity.zoneName
    ownerName = identity.ownerName
    recordName = identity.recordName
    self.shadowData = shadowData
    self.blockedByAttachmentID = blockedByAttachmentID
    lastFailure = nil
    revision = 1
  }

  var identity: CloudTextStorageIdentity {
    CloudTextStorageIdentity(zoneName: zoneName, ownerName: ownerName, recordName: recordName)
  }

  static func key(namespaceKey: String, identity: CloudTextStorageIdentity) -> String {
    "\(namespaceKey)|cleanup|\(identity.key)"
  }
}

@Model
final class StoredCloudAttachmentCacheEntry {
  @Attribute(.unique) var id: String
  var namespaceKey: String
  var attachmentID: UUID
  var payloadZoneName: String
  var payloadOwnerName: String
  var payloadRecordName: String
  var relativePath: String
  var byteCount: Int64
  var lastAccessedAt: Date

  init(
    namespaceKey: String,
    attachmentID: UUID,
    payloadIdentity: CloudTextStorageIdentity,
    relativePath: String,
    byteCount: Int64,
    lastAccessedAt: Date
  ) {
    id = Self.key(namespaceKey: namespaceKey, attachmentID: attachmentID)
    self.namespaceKey = namespaceKey
    self.attachmentID = attachmentID
    payloadZoneName = payloadIdentity.zoneName
    payloadOwnerName = payloadIdentity.ownerName
    payloadRecordName = payloadIdentity.recordName
    self.relativePath = relativePath
    self.byteCount = byteCount
    self.lastAccessedAt = lastAccessedAt
  }

  var payloadIdentity: CloudTextStorageIdentity {
    CloudTextStorageIdentity(
      zoneName: payloadZoneName,
      ownerName: payloadOwnerName,
      recordName: payloadRecordName
    )
  }

  static func key(namespaceKey: String, attachmentID: UUID) -> String {
    "\(namespaceKey)|cache|\(attachmentID.uuidString.lowercased())"
  }
}

@Model
package final class StoredRequestRecord {
  @Attribute(.unique) package var id: UUID

  package init(id: UUID) {
    self.id = id
  }
}

package enum StoredLibraryMetadataKind: String, Codable {
  case snip, list
}

package enum LibraryMetadataBackfillPoint: CaseIterable {
  case beforeSave, afterSave
}

package enum CloudFullRecordBackfillPoint: CaseIterable {
  case beforeSave, afterSave
}

@Model
final class StoredLibraryMetadataRecord {
  @Attribute(.unique) var id: String
  var kind: String
  var domainID: UUID
  var orderKeyData: Data
  var desiredName: String?
  var legacyPosition: Int64?
  var legacyOrderKeyData: Data?

  init(
    kind: StoredLibraryMetadataKind,
    domainID: UUID,
    orderKey: SnipOrderKey,
    desiredName: String? = nil,
    legacyPosition: Int64? = nil,
    legacyOrderKey: SnipOrderKey? = nil
  ) {
    id = Self.identifier(kind: kind, domainID: domainID)
    self.kind = kind.rawValue
    self.domainID = domainID
    orderKeyData = orderKey.data
    self.desiredName = desiredName
    self.legacyPosition = legacyPosition
    legacyOrderKeyData = legacyOrderKey?.data
  }

  static func identifier(kind: StoredLibraryMetadataKind, domainID: UUID) -> String {
    "\(kind.rawValue)|\(domainID.uuidString.lowercased())"
  }

  func update(orderKey: SnipOrderKey, desiredName: String? = nil) {
    orderKeyData = orderKey.data
    self.desiredName = desiredName
  }
}
