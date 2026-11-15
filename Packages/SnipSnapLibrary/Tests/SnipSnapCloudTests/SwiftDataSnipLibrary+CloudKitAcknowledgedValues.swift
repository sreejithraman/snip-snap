import Foundation

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

/// Commits read acknowledged attachment values from shadows, as the coordinator does.
extension SwiftDataSnipLibrary {
  func commitCloudFullBatch(
    _ batch: CloudFullBatchCommit,
    afterSave: @Sendable () -> Void = {}
  ) throws -> CloudFullBatchCommitResult {
    try commitCloudFullBatch(batch, acknowledgedValues: .cloudKit, afterSave: afterSave)
  }

  func commitCloudAttachmentTransitions(
    namespaceKey: CloudSyncNamespaceKey,
    transitions: [CloudAttachmentTransition],
    afterSave: @Sendable () -> Void = {}
  ) throws {
    try commitCloudAttachmentTransitions(
      namespaceKey: namespaceKey,
      transitions: transitions,
      acknowledgedValues: .cloudKit,
      afterSave: afterSave
    )
  }
}
