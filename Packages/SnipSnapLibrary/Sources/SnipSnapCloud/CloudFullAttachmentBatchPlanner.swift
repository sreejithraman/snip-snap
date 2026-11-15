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
  private let outboundOperations: [CloudRecordID: CloudOutboundOperation]
  private let sentItemResults: [CloudRecordID: CloudSendItemResult]
  private let publicationByMetadataIdentity: [CloudTextStorageIdentity: CloudAttachmentPublication]
  private let publicationByPayloadIdentity: [CloudTextStorageIdentity: CloudAttachmentPublication]
  private let cleanupByIdentity: [CloudTextStorageIdentity: CloudAttachmentCleanup]

  init(
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID?,
    attachmentOperationIDs _: Set<CloudRecordID>,
    outboundOperations: [CloudRecordID: CloudOutboundOperation],
    sentItemResults: [CloudRecordID: CloudSendItemResult],
    storage: CloudAttachmentStorageSnapshot
  ) {
    self.dataZone = dataZone
    self.payloadZone = payloadZone
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
    let identity = CloudFullSyncPersistence.storageIdentity(snapshot.id)
    let operation = outboundOperations[snapshot.id]
    if snapshot.recordType == CloudAttachmentRecordCodec.metadataRecordType {
      guard let payloadZone else { throw CloudAttachmentStorageError.invalidMetadata }
      let metadata = try CloudAttachmentRecordCodec.metadata(
        from: snapshot,
        metadataZone: dataZone,
        payloadZone: payloadZone
      )
      let remoteAcceptance = CloudAttachmentTransition.remoteMetadataAccepted(
        metadata: metadata,
        metadataIdentity: identity,
        shadowData: snapshot.shadow.data,
        systemFields: snapshot.shadow.systemFields
      )
      guard let operation else { return .handled(remoteAcceptance) }
      guard let local = publicationByMetadataIdentity[identity] else { return .handled(nil) }
      if case .delete = operation {
        if !local.isLocallyPresent {
          return .handled(.metadataDeleteConflict(
            attachmentID: local.metadata.attachmentID,
            expectedRevision: local.revision,
            shadowData: snapshot.shadow.data,
            systemFields: snapshot.shadow.systemFields,
            payloadIdentity: metadata.payloadIdentity
          ))
        }
        if local.metadataAccepted { return .handled(remoteAcceptance) }
      } else if case .saved? = sentItemResults[snapshot.id],
        metadata == local.metadata, local.payloadAccepted
      {
        return .handled(.metadataAccepted(
          attachmentID: local.metadata.attachmentID,
          expectedRevision: local.revision,
          shadowData: snapshot.shadow.data,
          systemFields: snapshot.shadow.systemFields
        ))
      }
      return .handled(.metadataConflict(
        attachmentID: local.metadata.attachmentID,
        expectedRevision: local.revision,
        shadowData: snapshot.shadow.data,
        systemFields: snapshot.shadow.systemFields
      ))
    }

    guard snapshot.recordType == CloudAttachmentRecordCodec.payloadRecordType else {
      return .unhandled
    }
    if case .delete? = operation {
      guard case .conflict? = sentItemResults[snapshot.id],
        let cleanup = cleanupByIdentity[identity]
      else { return .handled(nil) }
      return .handled(.cleanupConflict(
        identity: cleanup.identity,
        expectedRevision: cleanup.revision,
        shadowData: snapshot.shadow.data
      ))
    }
    guard let local = publicationByPayloadIdentity[identity] else {
      return operation == nil ? .unhandled : .handled(nil)
    }
    if operation != nil, !local.isLocallyPresent || local.payloadAccepted {
      return .handled(nil)
    }
    guard let payloadZone, snapshot.id.zone == payloadZone else {
      throw CloudAttachmentStorageError.invalidMetadata
    }
    if case .conflict? = sentItemResults[snapshot.id] {
      return .handled(payloadCollision(local, payloadZone: payloadZone))
    }
    return .handled(.payloadAccepted(
      attachmentID: local.metadata.attachmentID,
      expectedRevision: local.revision,
      shadowData: snapshot.shadow.data,
      systemFields: snapshot.shadow.systemFields
    ))
  }

  private func reduceDeletion(_ id: CloudRecordID) -> Result {
    let identity = CloudFullSyncPersistence.storageIdentity(id)
    let operation = outboundOperations[id]
    if let local = publicationByMetadataIdentity[identity] {
      if operation == nil {
        return .handled(.remoteMetadataDeleted(metadataIdentity: identity))
      }
      if case .delete? = operation {
        if local.isLocallyPresent { return .handled(metadataUnknown(local)) }
        return .handled(.metadataDeleteAccepted(
          attachmentID: local.metadata.attachmentID,
          expectedRevision: local.revision
        ))
      }
      return .handled(nil)
    }
    if let cleanup = cleanupByIdentity[identity] {
      if case .save? = operation { return .handled(nil) }
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
    guard let id, let operation = outboundOperations[id] else { return .handled(nil) }
    let identity = CloudFullSyncPersistence.storageIdentity(id)
    if case .delete = operation, let cleanup = cleanupByIdentity[identity] {
      return .handled(.cleanupFailed(
        identity: cleanup.identity,
        expectedRevision: cleanup.revision,
        failure: Self.attachmentFailure(failure)
      ))
    }
    if let local = publicationByMetadataIdentity[identity] {
      switch operation {
      case .save:
        if case .unknownItem? = sentItemResults[id] {
          if !local.isLocallyPresent {
            return .handled(.metadataDeleteAccepted(
              attachmentID: local.metadata.attachmentID,
              expectedRevision: local.revision
            ))
          }
          return .handled(metadataUnknown(local))
        }
        guard local.isLocallyPresent, local.payloadAccepted, !local.metadataAccepted else {
          return .handled(nil)
        }
      case .delete:
        guard !local.isLocallyPresent else { return .handled(nil) }
      }
      return .handled(.operationFailed(
        attachmentID: local.metadata.attachmentID,
        expectedRevision: local.revision,
        failure: Self.attachmentFailure(failure)
      ))
    }
    guard case .save = operation,
      let local = publicationByPayloadIdentity[identity],
      local.isLocallyPresent, !local.payloadAccepted
    else { return .handled(nil) }
    if case .unknownItem? = sentItemResults[id], let payloadZone {
      return .handled(payloadCollision(local, payloadZone: payloadZone))
    }
    return .handled(.operationFailed(
      attachmentID: local.metadata.attachmentID,
      expectedRevision: local.revision,
      failure: Self.attachmentFailure(failure)
    ))
  }

  private func metadataUnknown(_ local: CloudAttachmentPublication) -> CloudAttachmentTransition {
    let replacementAttachmentID = UUID()
    return .metadataUnknown(
      attachmentID: local.metadata.attachmentID,
      expectedRevision: local.revision,
      replacementAttachmentID: replacementAttachmentID,
      replacementMetadataIdentity: CloudTextStorageIdentity(
        zoneName: dataZone.name,
        ownerName: dataZone.ownerName,
        recordName: "a-\(replacementAttachmentID.uuidString.lowercased())"
      )
    )
  }

  private func payloadCollision(
    _ local: CloudAttachmentPublication,
    payloadZone: CloudZoneID
  ) -> CloudAttachmentTransition {
    .payloadCollision(
      attachmentID: local.metadata.attachmentID,
      expectedRevision: local.revision,
      replacementIdentity: CloudTextStorageIdentity(
        zoneName: payloadZone.name,
        ownerName: payloadZone.ownerName,
        recordName: UUID().uuidString.lowercased()
      )
    )
  }

  private static func attachmentFailure(
    _ failure: CloudOperationFailure
  ) -> CloudAttachmentFailure {
    switch failure {
    case .networkUnavailable, .iCloudUnavailable, .rateLimited,
         .authenticationRequired, .accountTemporarilyUnavailable,
         .attachmentUnavailable, .changeTokenExpired, .retryable:
      .retryable
    case .quotaExceeded: .quotaExceeded
    case .updateRequired: .updateRequired
    case .accessDenied: .accessDenied
    case .rejected: .rejected
    case .attachmentMissing: .attachmentMissing
    case .invalidRecord: .invalidRecord
    case .zoneMissing: .zoneMissing
    }
  }
}
