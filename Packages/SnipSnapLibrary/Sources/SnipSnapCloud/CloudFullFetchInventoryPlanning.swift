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
    let observations = fetched.items.compactMap { item -> CloudFullFetchObservation? in
      switch item {
      case .record(let snapshot) where snapshot.id.zone == dataZone:
        return .present(CloudFullSyncPersistence.storageIdentity(snapshot.id))
      case .deleted(let id) where id.zone == dataZone:
        return .absent(CloudFullSyncPersistence.storageIdentity(id))
      default:
        return nil
      }
    }
    let attempt = current ?? CloudFullFetchInventory.started(tokenless: startsWithoutToken)
    return attempt.observing(
      observations,
      isClean: CloudSyncIssueError.issue(in: batch) == nil
        && !CloudSyncIssueError.blocksOutbound(in: batch)
    )
  }
}
