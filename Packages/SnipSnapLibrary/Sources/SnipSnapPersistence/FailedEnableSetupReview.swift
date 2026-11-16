import Foundation
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

  public func choose(_ issueID: UUID, selection: FailedEnableSetupSelection,
    expecting expectation: FailedEnableSetupExpectation
  ) async throws -> FailedEnableSetupSelectionReceipt {
    try await persistence.chooseFailedEnableSetupReview(issueID, selection: selection,
      expecting: expectation)
  }

  public func keepLocalOnly() async throws {
    try await persistence.keepFailedEnableSetupLocalOnly()
  }
}

public extension SnipSyncModeStore {
  var failedEnableReview: FailedEnableSetupReview {
    FailedEnableSetupReview(persistence: persistence)
  }
}
