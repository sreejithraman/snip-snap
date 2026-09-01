import Foundation
import SnipSnapCore
import SnipSnapPersistence

struct CloudFullAttachmentBatchPlanner {
  enum Result {
    case unhandled
    case handled(CloudAttachmentTransition?)
  }

  private let dataZone: CloudZoneID
  private let payloadZone: CloudZoneID?
  private let attachmentOperationIDs: Set<CloudRecordID>
  private let outboundOperations: [CloudRecordID: CloudOutboundOperation]
  private let sentItemResults: [CloudRecordID: CloudSendItemResult]
  private let publicationByMetadataIdentity: [CloudTextStorageIdentity: CloudAttachmentPublication]
  private let publicationByPayloadIdentity: [CloudTextStorageIdentity: CloudAttachmentPublication]
  private let cleanupByIdentity: [CloudTextStorageIdentity: CloudAttachmentCleanup]

  init(
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID?,
    attachmentOperationIDs: Set<CloudRecordID>,
    outboundOperations: [CloudRecordID: CloudOutboundOperation],
    sentItemResults: [CloudRecordID: CloudSendItemResult],
    storage: CloudAttachmentStorageSnapshot
  ) {
    self.dataZone = dataZone
    self.payloadZone = payloadZone
    self.attachmentOperationIDs = attachmentOperationIDs
    self.outboundOperations = outboundOperations
    self.sentItemResults = sentItemResults
    publicationByMetadataIdentity = Dictionary(
      storage.publications.map { ($0.metadataIdentity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    publicationByPayloadIdentity = Dictionary(
      storage.publications.map { ($0.metadata.payloadIdentity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    cleanupByIdentity = Dictionary(
      storage.cleanups.map { ($0.identity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  func reduce(_ result: CloudFetchItemResult) throws -> Result {
    switch result {
    case .record(let snapshot):
      return try reduceRecord(snapshot)
    case .deleted(let id):
      return reduceDeletion(id)
    case .failed(let id, let failure):
      return reduceFailure(id: id, failure: failure)
    }
  }

  private func reduceRecord(_ snapshot: CloudRecordSnapshot) throws -> Result {
    if snapshot.recordType == CloudAttachmentRecordCodec.metadataRecordType,
      outboundOperations[snapshot.id] == nil || attachmentOperationIDs.contains(snapshot.id)
    {
      guard let payloadZone else { throw CloudAttachmentStorageError.invalidMetadata }
      let metadata = try CloudAttachmentRecordCodec.metadata(
        from: snapshot,
        metadataZone: dataZone,
        payloadZone: payloadZone
      )
      let identity = CloudFullSyncPersistence.storageIdentity(snapshot.id)
      guard outboundOperations[snapshot.id] != nil,
        let local = publicationByMetadataIdentity[identity]
      else {
        return .handled(.remoteMetadataAccepted(
          metadata: metadata,
          metadataIdentity: identity,
          shadowData: snapshot.shadow.data,
          systemFields: snapshot.shadow.systemFields
        ))
      }
      if case .conflict? = sentItemResults[snapshot.id] {
        if case .delete? = outboundOperations[snapshot.id] {
          return .handled(.metadataDeleteConflict(
            attachmentID: local.metadata.attachmentID,
            expectedRevision: local.revision,
            shadowData: snapshot.shadow.data,
            systemFields: snapshot.shadow.systemFields,
            payloadIdentity: metadata.payloadIdentity
          ))
        }
        return .handled(.metadataConflict(
          attachmentID: local.metadata.attachmentID,
          expectedRevision: local.revision,
          shadowData: snapshot.shadow.data,
          systemFields: snapshot.shadow.systemFields
        ))
      }
      return .handled(.metadataAccepted(
        attachmentID: local.metadata.attachmentID,
        expectedRevision: local.revision,
        shadowData: snapshot.shadow.data,
        systemFields: snapshot.shadow.systemFields
      ))
    }

    let identity = CloudFullSyncPersistence.storageIdentity(snapshot.id)
    if snapshot.recordType == CloudAttachmentRecordCodec.payloadRecordType,
      (outboundOperations[snapshot.id] == nil || attachmentOperationIDs.contains(snapshot.id)),
      let local = publicationByPayloadIdentity[identity]
    {
      guard let payloadZone, snapshot.id.zone == payloadZone else {
        throw CloudAttachmentStorageError.invalidMetadata
      }
      if case .conflict? = sentItemResults[snapshot.id] {
        return .handled(.payloadCollision(
          attachmentID: local.metadata.attachmentID,
          expectedRevision: local.revision,
          replacementIdentity: CloudTextStorageIdentity(
            zoneName: payloadZone.name,
            ownerName: payloadZone.ownerName,
            recordName: UUID().uuidString.lowercased()
          )
        ))
      }
      return .handled(.payloadAccepted(
        attachmentID: local.metadata.attachmentID,
        expectedRevision: local.revision,
        shadowData: snapshot.shadow.data,
        systemFields: snapshot.shadow.systemFields
      ))
    }
    if snapshot.recordType == CloudAttachmentRecordCodec.payloadRecordType,
      attachmentOperationIDs.contains(snapshot.id),
      case .conflict? = sentItemResults[snapshot.id],
      let cleanup = cleanupByIdentity[identity]
    {
      return .handled(.cleanupConflict(
        identity: cleanup.identity,
        expectedRevision: cleanup.revision,
        shadowData: snapshot.shadow.data
      ))
    }
    return .unhandled
  }

  private func reduceDeletion(_ id: CloudRecordID) -> Result {
    let identity = CloudFullSyncPersistence.storageIdentity(id)
    if let local = publicationByMetadataIdentity[identity] {
      if attachmentOperationIDs.contains(id) {
        return .handled(.metadataDeleteAccepted(
          attachmentID: local.metadata.attachmentID,
          expectedRevision: local.revision
        ))
      }
      if outboundOperations[id] == nil {
        return .handled(.remoteMetadataDeleted(metadataIdentity: identity))
      }
    }
    if let cleanup = cleanupByIdentity[identity],
      attachmentOperationIDs.contains(id) || outboundOperations[id] == nil
    {
      return .handled(.cleanupAccepted(
        identity: identity,
        expectedRevision: cleanup.revision
      ))
    }
    return .unhandled
  }

  private func reduceFailure(
    id: CloudRecordID?,
    failure: CloudOperationFailure
  ) -> Result {
    guard let id, attachmentOperationIDs.contains(id) else { return .handled(nil) }
    let identity = CloudFullSyncPersistence.storageIdentity(id)
    if let cleanup = cleanupByIdentity[identity] {
      return .handled(.cleanupFailed(
        identity: cleanup.identity,
        expectedRevision: cleanup.revision,
        failure: Self.attachmentFailure(failure)
      ))
    }
    guard let local = publicationByMetadataIdentity[identity]
      ?? publicationByPayloadIdentity[identity]
    else { return .handled(nil) }
    if case .unknownItem? = sentItemResults[id], local.metadataIdentity == identity {
      let replacementAttachmentID = UUID()
      return .handled(.metadataUnknown(
        attachmentID: local.metadata.attachmentID,
        expectedRevision: local.revision,
        replacementAttachmentID: replacementAttachmentID,
        replacementMetadataIdentity: CloudTextStorageIdentity(
          zoneName: dataZone.name,
          ownerName: dataZone.ownerName,
          recordName: "a-\(replacementAttachmentID.uuidString.lowercased())"
        )
      ))
    }
    if case .unknownItem? = sentItemResults[id],
      local.metadata.payloadIdentity == identity,
      let payloadZone
    {
      return .handled(.payloadCollision(
        attachmentID: local.metadata.attachmentID,
        expectedRevision: local.revision,
        replacementIdentity: CloudTextStorageIdentity(
          zoneName: payloadZone.name,
          ownerName: payloadZone.ownerName,
          recordName: UUID().uuidString.lowercased()
        )
      ))
    }
    return .handled(.operationFailed(
      attachmentID: local.metadata.attachmentID,
      expectedRevision: local.revision,
      failure: Self.attachmentFailure(failure)
    ))
  }

  private static func attachmentFailure(
    _ failure: CloudOperationFailure
  ) -> CloudAttachmentFailure {
    switch failure {
    case .retryable: .retryable
    case .quotaExceeded: .quotaExceeded
    case .rejected: .rejected
    case .invalidRecord: .invalidRecord
    case .zoneMissing: .zoneMissing
    }
  }
}
