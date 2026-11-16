import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  func makeCommit(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?,
    rawBatchData: Data
  ) async throws -> CloudFullBatchCommit {
    if case .fetched = batch, !orderWritesAwaitingFetch.isEmpty, let payloadZone {
      // Edits can arrive while every metadata save is held, without another outbound plan.
      try await library.reconcileCloudAttachments(
        namespaceKey: namespaceKey,
        metadataZoneName: dataZone.name,
        metadataOwnerName: dataZone.ownerName,
        payloadZoneName: payloadZone.name,
        payloadOwnerName: payloadZone.ownerName,
        snipIDs: orderWritesAwaitingFetch
      )
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
      recoveryEvents: try await library.cloudFullRecoveryEvents(namespaceKey: namespaceKey),
      heldAttachmentSnipIDs: orderWritesAwaitingFetch
    ).plan(
      recoveryFetchBatch(batch, stored: stored, recovery: recovery), inventorySource: batch,
      blockedReplayIDs: recovery.unpreparedRecordIDs,
      outbound: outbound, rawBatchData: rawBatchData
    )
  }
}
