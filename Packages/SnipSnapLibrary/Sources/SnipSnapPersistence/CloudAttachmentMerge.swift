import Foundation

/// SM33-F2: merges attachment edits against the values iCloud last acknowledged.
///
/// A field this device left at its acknowledged value takes the remote value. A field it changed
/// keeps the local value, because this device sends next and reaches iCloud last.
enum CloudAttachmentMerge {
  static func field<Value: Equatable>(base: Value, local: Value, remote: Value) -> Value {
    local == base ? remote : local
  }

  /// Merges a row's fields. Without a readable base, the local record stays whole.
  static func metadata(
    base: CloudAttachmentMetadataValue?,
    local: CloudAttachmentMetadataValue,
    remote: CloudAttachmentMetadataValue
  ) -> CloudAttachmentMetadataValue {
    guard let base else { return local }
    return CloudAttachmentMetadataValue(
      attachmentID: remote.attachmentID,
      snipID: field(base: base.snipID, local: local.snipID, remote: remote.snipID),
      position: field(base: base.position, local: local.position, remote: remote.position),
      fileName: field(base: base.fileName, local: local.fileName, remote: remote.fileName),
      contentType: field(base: base.contentType, local: local.contentType, remote: remote.contentType),
      byteCount: remote.byteCount,
      sha256: remote.sha256,
      payloadIdentity: remote.payloadIdentity
    )
  }
}

/// A fetched record applied to a locally present publication in one commit.
struct CloudAttachmentAdoption {
  /// What iCloud acknowledged before the commit, or nil when this device can't read it.
  let base: CloudAttachmentMetadataValue?
  let record: CloudAttachmentMetadataValue
}

extension StoredCloudAttachmentPublication {
  /// The values iCloud last acknowledged, or nil for metadata it never accepted. A published row
  /// equals its shadow, so its own values stand in when the shadow can't be read.
  func acknowledgedMetadata(
    _ acknowledgedValues: CloudAttachmentAcknowledgedValues
  ) -> CloudAttachmentMetadataValue? {
    let lifecycle = self.lifecycle
    if let shadowData = lifecycle.metadataShadowData,
      let acknowledged = try? acknowledgedValues.metadata(fromShadow: shadowData)
    {
      return acknowledged
    }
    return lifecycle.isMetadataAccepted ? metadata : nil
  }
}
