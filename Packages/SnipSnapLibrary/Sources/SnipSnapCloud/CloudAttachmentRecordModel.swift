import Foundation
import SnipSnapPersistence

package enum CloudAttachmentRecordCodec {
  package static let metadataRecordType = "AttachmentMetadata"
  package static let payloadRecordType = "AttachmentPayload"
  package static let assetField = "payload"
  package static let schemaVersion = 1

  package static func payloadDraft(
    _ publication: CloudAttachmentPublication
  ) throws -> CloudRecordDraft {
    guard let sourceURL = publication.sourceURL else {
      throw CloudAttachmentStorageError.missingPayload
    }
    return CloudRecordDraft(
      id: recordID(publication.metadata.payloadIdentity),
      recordType: payloadRecordType,
      schemaVersion: schemaVersion,
      routingFields: ["schemaVersion": .int64(Int64(schemaVersion))],
      encryptedFields: [:],
      assetFields: [assetField: CloudAssetUpload(fileURL: sourceURL)]
    )
  }

  package static func metadataDraft(
    _ publication: CloudAttachmentPublication
  ) throws -> CloudRecordDraft {
    var fields: [String: CloudFieldValue] = [
      "attachmentID": .string(publication.metadata.attachmentID.uuidString.lowercased()),
      "snipID": .string(publication.metadata.snipID.uuidString.lowercased()),
      "position": .int64(Int64(publication.metadata.position)),
      "fileName": .string(publication.metadata.fileName),
      "byteCount": .int64(publication.metadata.byteCount),
      "sha256": .data(publication.metadata.sha256),
      "payloadZoneName": .string(publication.metadata.payloadIdentity.zoneName),
      "payloadOwnerName": .string(publication.metadata.payloadIdentity.ownerName),
      "payloadRecordName": .string(publication.metadata.payloadIdentity.recordName),
    ]
    if let contentType = publication.metadata.contentType {
      fields["contentType"] = .string(contentType)
    }
    let base = try publication.metadataShadowData.map(CloudRecordShadow.init(data:))
    return CloudRecordDraft(
      id: recordID(publication.metadataIdentity),
      recordType: metadataRecordType,
      schemaVersion: schemaVersion,
      routingFields: ["schemaVersion": .int64(Int64(schemaVersion))],
      encryptedFields: fields,
      base: base
    )
  }

  package static func metadata(
    from snapshot: CloudRecordSnapshot,
    metadataZone: CloudZoneID? = nil,
    payloadZone: CloudZoneID? = nil
  ) throws -> CloudAttachmentMetadataValue {
    guard snapshot.completeness == .full else { throw CloudRecordError.projectedSnapshot }
    guard snapshot.recordType == metadataRecordType else { throw CloudRecordError.wrongRecordType }
    if let metadataZone, snapshot.id.zone != metadataZone {
      throw CloudAttachmentStorageError.invalidMetadata
    }
    let fields = snapshot.encryptedFields
    let metadata = CloudAttachmentMetadataValue(
      attachmentID: try uuid(fields, "attachmentID"),
      snipID: try uuid(fields, "snipID"),
      position: Int(try int64(fields, "position")),
      fileName: try string(fields, "fileName"),
      contentType: try optionalString(fields, "contentType"),
      byteCount: try int64(fields, "byteCount"),
      sha256: try data(fields, "sha256"),
      payloadIdentity: CloudTextStorageIdentity(
        zoneName: try string(fields, "payloadZoneName"),
        ownerName: try string(fields, "payloadOwnerName"),
        recordName: try string(fields, "payloadRecordName")
      )
    )
    if let payloadZone,
      metadata.payloadIdentity.zoneName != payloadZone.name
        || metadata.payloadIdentity.ownerName != payloadZone.ownerName
    {
      throw CloudAttachmentStorageError.invalidMetadata
    }
    return metadata
  }

  package static func recordID(_ identity: CloudTextStorageIdentity) -> CloudRecordID {
    CloudRecordID(
      zone: CloudZoneID(name: identity.zoneName, ownerName: identity.ownerName),
      name: identity.recordName
    )
  }

  package static func identity(_ id: CloudRecordID) -> CloudTextStorageIdentity {
    CloudTextStorageIdentity(
      zoneName: id.zone.name,
      ownerName: id.zone.ownerName,
      recordName: id.name
    )
  }

  private static func string(
    _ fields: [String: CloudFieldValue], _ key: String
  ) throws -> String {
    guard let field = fields[key] else { throw CloudRecordError.missingField(key) }
    guard case .string(let value) = field else { throw CloudRecordError.invalidField(key) }
    return value
  }

  private static func optionalString(
    _ fields: [String: CloudFieldValue], _ key: String
  ) throws -> String? {
    guard let field = fields[key] else { return nil }
    guard case .string(let value) = field else { throw CloudRecordError.invalidField(key) }
    return value
  }

  private static func uuid(
    _ fields: [String: CloudFieldValue], _ key: String
  ) throws -> UUID {
    let raw = try string(fields, key)
    guard let value = UUID(uuidString: raw) else { throw CloudRecordError.invalidField(key) }
    return value
  }

  private static func int64(
    _ fields: [String: CloudFieldValue], _ key: String
  ) throws -> Int64 {
    guard let field = fields[key] else { throw CloudRecordError.missingField(key) }
    guard case .int64(let value) = field, value >= 0 else {
      throw CloudRecordError.invalidField(key)
    }
    return value
  }

  private static func data(
    _ fields: [String: CloudFieldValue], _ key: String
  ) throws -> Data {
    guard let field = fields[key] else { throw CloudRecordError.missingField(key) }
    guard case .data(let value) = field, value.count == 32 else {
      throw CloudRecordError.invalidField(key)
    }
    return value
  }
}
