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
