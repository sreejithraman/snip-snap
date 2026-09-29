import Foundation
import SnipSnapPersistence

extension CloudFullFetchInventory {
  static func after(
    _ batch: CloudSyncBatch,
    current: CloudFullFetchInventory?,
    startsWithoutToken: Bool,
    dataZone: CloudZoneID
  ) -> CloudFullFetchInventory? {
    guard case .fetched(let fetched) = batch else { return current }
    guard fetched.isInitialFetch else { return nil }
    let prior = current ?? CloudFullFetchInventory(canProveAbsence: startsWithoutToken)
    var observed = prior.observed
    for item in fetched.items {
      switch item {
      case .record(let snapshot) where snapshot.id.zone == dataZone:
        observed.insert(CloudFullSyncPersistence.storageIdentity(snapshot.id))
      case .deleted(let id) where id.zone == dataZone:
        observed.remove(CloudFullSyncPersistence.storageIdentity(id))
      default: break
      }
    }
    return CloudFullFetchInventory(
      observed: observed,
      canProveAbsence: prior.canProveAbsence
        && CloudSyncIssueError.issue(in: batch) == nil
        && !CloudSyncIssueError.blocksOutbound(in: batch)
    )
  }
}
