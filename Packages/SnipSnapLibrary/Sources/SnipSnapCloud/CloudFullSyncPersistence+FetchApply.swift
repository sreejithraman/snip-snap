import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  func makeCommit(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?,
    rawBatchData: Data
  ) async throws -> CloudFullBatchCommit {
    if case .fetched(let fetched) = batch, let payloadZone {
      let deleted = Set(fetched.items.compactMap { item -> CloudTextStorageIdentity? in
        guard case .deleted(let id) = item else { return nil }
        return Self.storageIdentity(id)
      })
      if !deleted.isEmpty {
        let attachments = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
        let affectedSnipIDs = Set(attachments.publications.filter {
          deleted.contains($0.metadataIdentity)
        }.map { $0.metadata.snipID })
        if !affectedSnipIDs.isEmpty {
          // Identity selects the affected rows. Reconciliation also follows a row moved out of
          // its prior parent; neither restart nor current hold membership grants deletion.
          try await library.reconcileCloudAttachments(
            namespaceKey: namespaceKey,
            metadataZoneName: dataZone.name,
            metadataOwnerName: dataZone.ownerName,
            payloadZoneName: payloadZone.name,
            payloadOwnerName: payloadZone.ownerName,
            snipIDs: affectedSnipIDs
          )
        }
      }
    }
    if case .sent(let sent) = batch, let outbound, let payloadZone {
      let operations = try Self.uniqueOperations(outbound.operations)
      let reportedIDs = Set(sent.items.map(\.id))
      guard reportedIDs.count == sent.items.count, reportedIDs == Set(operations.keys) else {
        throw CloudTransportError.invalidRecord
      }
      let missingIDs = Set(sent.items.compactMap { item -> CloudRecordID? in
        guard case .unknownItem(let id) = item else { return nil }
        return id
      })
      let missingMetadataSaves = outbound.operations.filter { operation in
        guard missingIDs.contains(operation.id), case .save(let draft) = operation else { return false }
        return draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
      }
      if !missingMetadataSaves.isEmpty {
        let attachments = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
        let ownedIDs = Self.submittedAttachmentOperationIDs(
          attachments, submittedOperations: missingMetadataSaves,
          dataZone: dataZone, payloadZone: payloadZone
        )
        let affectedAttachmentIDs = Set(attachments.publications.compactMap { publication -> UUID? in
          guard ownedIDs.contains(CloudAttachmentRecordCodec.recordID(publication.metadataIdentity)) else { return nil }
          return publication.metadata.attachmentID
        })
        if !affectedAttachmentIDs.isEmpty {
          // The source guard also protects sent remaps. Refresh only their actual submitted
          // identities on both initial planning and raw replay, leaving unrelated intent alone.
          try await library.reconcileCloudAttachments(
            namespaceKey: namespaceKey,
            metadataZoneName: dataZone.name,
            metadataOwnerName: dataZone.ownerName,
            payloadZoneName: payloadZone.name,
            payloadOwnerName: payloadZone.ownerName,
            attachmentIDs: affectedAttachmentIDs
          )
        }
      }
    }
    let wire = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let recovery = corruptShadowRecovery(in: stored)
    let attachmentStorage = try await library.cloudAttachmentStorageSnapshot(
      namespaceKey: namespaceKey
    )
    return try CloudFullBatchPlanner(
      namespaceKey: namespaceKey,
      dataZone: dataZone,
      payloadZone: payloadZone,
      expectedEngine: wire.engineState,
      local: local,
      stored: stored,
      attachmentStorage: attachmentStorage,
      recoveryEvents: try await library.cloudFullRecoveryEvents(namespaceKey: namespaceKey)
    ).plan(
      recoveryFetchBatch(batch, stored: stored, recovery: recovery), inventorySource: batch,
      blockedReplayIDs: recovery.unpreparedRecordIDs,
      outbound: outbound, rawBatchData: rawBatchData
    )
  }
}
