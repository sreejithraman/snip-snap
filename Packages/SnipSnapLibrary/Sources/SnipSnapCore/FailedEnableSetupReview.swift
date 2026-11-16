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
  case evidenceUnavailable, staleComparison, choiceUnavailable, accountUnavailable
}

public enum FailedEnableSetupSelection: String, Equatable, Sendable {
  case useDevice, recoverAsNew
}

public enum FailedEnableSetupServerState: Equatable, Sendable {
  case value, absent, unavailable
}

public struct FailedEnableSetupExpectation: Equatable, Sendable {
  public let sourceStoreID: UUID
  public let issueID: UUID
  package let issueDigest: String
  package let sequence: String

  package init(sourceStoreID: UUID, issueID: UUID, issueDigest: String, sequence: String) {
    self.sourceStoreID = sourceStoreID
    self.issueID = issueID
    self.issueDigest = issueDigest
    self.sequence = sequence
  }
}

public struct FailedEnableSetupAttachmentIDs: Equatable, Sendable {
  public let originalID: UUID
  public let outputID: UUID
  package init(originalID: UUID, outputID: UUID) {
    self.originalID = originalID
    self.outputID = outputID
  }
}

public struct FailedEnableSetupOutputIDs: Equatable, Sendable {
  public let original: FailedEnableSetupEntityID
  public let output: FailedEnableSetupEntityID
  public let requestID: UUID?
  public let attachments: [FailedEnableSetupAttachmentIDs]
  package init(original: FailedEnableSetupEntityID, output: FailedEnableSetupEntityID,
    requestID: UUID?, attachments: [FailedEnableSetupAttachmentIDs]) {
    self.original = original
    self.output = output
    self.requestID = requestID
    self.attachments = attachments
  }
}

public struct FailedEnableSetupSelectionReceipt: Equatable, Sendable {
  public let issueID: UUID
  public let selection: FailedEnableSetupSelection
  public let outputs: [FailedEnableSetupOutputIDs]
  package init(issueID: UUID, selection: FailedEnableSetupSelection,
    outputs: [FailedEnableSetupOutputIDs]) {
    self.issueID = issueID
    self.selection = selection
    self.outputs = outputs
  }
}

public struct FailedEnableSetupIssue: Equatable, Sendable {
  public let id: UUID
  public let entityID: FailedEnableSetupEntityID
  public let reason: FailedEnableSetupReviewReason
  public let localVersionAtReview: FailedEnableSetupLocalVersion?
  public let earlierLocalVersions: [FailedEnableSetupLocalVersion]
  public let serverState: FailedEnableSetupServerState
  /// Cloud record fields at the checked comparison. Attachment ownership is separate.
  public let serverFieldsAtReview: FailedEnableSetupLocalVersion?
  public let allowedChoices: [FailedEnableSetupSelection]
  public let expectation: FailedEnableSetupExpectation
  public let selection: FailedEnableSetupSelectionReceipt?

  package init(
    id: UUID,
    entityID: FailedEnableSetupEntityID,
    reason: FailedEnableSetupReviewReason,
    localVersionAtReview: FailedEnableSetupLocalVersion?,
    earlierLocalVersions: [FailedEnableSetupLocalVersion],
    serverState: FailedEnableSetupServerState,
    serverFieldsAtReview: FailedEnableSetupLocalVersion?,
    allowedChoices: [FailedEnableSetupSelection],
    expectation: FailedEnableSetupExpectation,
    selection: FailedEnableSetupSelectionReceipt?
  ) {
    self.id = id
    self.entityID = entityID
    self.reason = reason
    self.localVersionAtReview = localVersionAtReview
    self.earlierLocalVersions = earlierLocalVersions
    self.serverState = serverState
    self.serverFieldsAtReview = serverFieldsAtReview
    self.allowedChoices = allowedChoices
    self.expectation = expectation
    self.selection = selection
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
