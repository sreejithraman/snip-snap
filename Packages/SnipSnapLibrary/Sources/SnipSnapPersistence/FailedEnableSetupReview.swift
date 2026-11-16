import SnipSnapCore

public struct FailedEnableSetupReview: Sendable {
  private let persistence: SwiftDataSyncModePersistence

  init(persistence: SwiftDataSyncModePersistence) {
    self.persistence = persistence
  }

  /// Reads stored local comparisons for the current source, without refreshing iCloud.
  public func snapshot() async throws -> FailedEnableSetupReviewSnapshot {
    try await persistence.failedEnableSetupReviewSnapshot()
  }
}

public extension SnipSyncModeStore {
  var failedEnableReview: FailedEnableSetupReview {
    FailedEnableSetupReview(persistence: persistence)
  }
}
