import Foundation
import SnipSnapPersistence

extension CloudFullSyncPersistence {
  static func hasFailedFetchRecords(_ recovery: CloudFullRecoveryInput) -> Bool {
    guard recovery.kind == .retryableFetch || recovery.kind == .terminalFetch else { return false }
    // Unreadable evidence must not become permission to send.
    return (try? failedFetchRecordIDs([recovery]).isEmpty) != true
  }

  static func failedFetchRecordIDs(
    _ recovery: [CloudFullRecoveryInput]
  ) throws -> Set<CloudRecordID> {
    try recovery.reduce(into: Set<CloudRecordID>()) { ids, event in
      guard event.kind == .retryableFetch || event.kind == .terminalFetch else { return }
      let fetched = try recoveredFetch(event)
      ids.formUnion(fetched.items.compactMap { item in
        guard case .failed(let id, _) = item else { return nil }
        return id
      })
    }
  }

  static func fetchRecoveryChanges(
    _ recovery: [CloudFullRecoveryInput],
    resolved: Set<CloudRecordID>
  ) throws -> [CloudFullRecoveryChange] {
    guard !resolved.isEmpty else { return [] }
    return try recovery.compactMap { event in
      guard event.kind == .retryableFetch || event.kind == .terminalFetch else { return nil }
      let prior = try Self.recoveredFetch(event)
      let remaining = prior.items.filter { item in
        guard case .failed(let id?, _) = item else { return true }
        return !resolved.contains(id)
      }
      guard remaining.count != prior.items.count else { return nil }
      let next = CloudFetchedBatch(id: prior.id, items: remaining,
        databaseEvents: prior.databaseEvents, zoneEvents: prior.zoneEvents, engineState: prior.engineState)
      let replacement = try CloudFullBatchPlanner.fetchRecoveryKind(next).map { kind in
        CloudFullRecoveryInput(namespaceKey: event.namespaceKey, batchID: event.batchID,
          kind: kind, outboundData: event.outboundData,
          resultData: try Self.rawBatchData(.fetched(next), outbound: nil))
      }
      return CloudFullRecoveryChange(expected: event, replacement: replacement)
    }
  }

  private static func recoveredFetch(_ recovery: CloudFullRecoveryInput) throws -> CloudFetchedBatch {
    let raw = try JSONDecoder().decode(RawStagedBatch.self, from: recovery.resultData)
    guard raw.storageVersion == 1, raw.batch.id == recovery.batchID,
      case .fetched(let fetched) = raw.batch
    else { throw CloudFullStorageError.invalidBatchReplay }
    return fetched
  }
}
