import Foundation
import SnipSnapPersistence

extension CloudFullInitialFetchStep {
  /// `startsWithoutToken` decides whether an attempt this batch opens can prove absence.
  init(_ batch: CloudSyncBatch, startsWithoutToken: Bool, dataZone: CloudZoneID) {
    guard case .fetched(let fetched) = batch else {
      self = .unchanged
      return
    }
    guard fetched.isInitialFetch else {
      self = .ended
      return
    }
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
    self = .observed(
      observations,
      isClean: CloudSyncIssueError.issue(in: batch) == nil
        && !CloudSyncIssueError.blocksOutbound(in: batch),
      tokenless: startsWithoutToken
    )
  }
}
