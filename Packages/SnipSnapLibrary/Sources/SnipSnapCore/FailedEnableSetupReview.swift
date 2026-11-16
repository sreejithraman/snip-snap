import Foundation

public enum FailedEnableSetupEntityID: Equatable, Sendable {
  case snip(UUID)
  case list(UUID)
}

public enum FailedEnableSetupLocalVersion: Equatable, Sendable {
  case snip(Snip)
  case list(SnipList)
}

public enum FailedEnableSetupReviewReason: String, Equatable, Sendable {
  case unverifiedHistory, unknownOutcome, rejectedValue, remoteDeletion, unavailableBytes
  case unsupportedRecord, interruptedWriter, evidenceUnavailable, earlierLocalVersion
}

public enum FailedEnableSetupReviewReadError: Error, Equatable, Sendable {
  case evidenceUnavailable
}

public struct FailedEnableSetupIssue: Equatable, Sendable {
  public let id: UUID
  public let entityID: FailedEnableSetupEntityID
  public let reason: FailedEnableSetupReviewReason
  public let localVersionAtReview: FailedEnableSetupLocalVersion?

  package init(
    id: UUID,
    entityID: FailedEnableSetupEntityID,
    reason: FailedEnableSetupReviewReason,
    localVersionAtReview: FailedEnableSetupLocalVersion?
  ) {
    self.id = id
    self.entityID = entityID
    self.reason = reason
    self.localVersionAtReview = localVersionAtReview
  }
}

public struct FailedEnableSetupReviewSnapshot: Equatable, Sendable {
  public let sourceStoreID: UUID
  public let issues: [FailedEnableSetupIssue]

  package init(sourceStoreID: UUID, issues: [FailedEnableSetupIssue]) {
    self.sourceStoreID = sourceStoreID
    self.issues = issues
  }
}
