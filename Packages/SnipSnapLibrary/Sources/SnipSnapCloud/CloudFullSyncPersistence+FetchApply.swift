import Foundation
import SnipSnapCore
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  func makeCommit(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?,
    rawBatchData: Data
  ) async throws -> CloudFullBatchCommit {
    let wire = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
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
      attachmentStorage: attachmentStorage
    ).plan(batch, outbound: outbound, rawBatchData: rawBatchData)
  }
}
