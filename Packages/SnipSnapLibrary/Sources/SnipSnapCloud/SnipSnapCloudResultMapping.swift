import SnipSnapCore

package enum CloudAccountIsolationError: Error, Equatable, Sendable {
  case signedOut
  case accountChanged

  var syncResult: SnipSnapCloudSyncResult {
    self == .signedOut ? .iCloudSignedOut : .iCloudAccountChanged
  }
}

func automaticSyncResult(for error: any Error) -> SnipSnapCloudSyncResult {
  if let isolation = error as? CloudAccountIsolationError { return isolation.syncResult }
  return .syncIssue(SnipSnapCloudSyncIssueMapper.issue(for: error))
}

func syncResult(for status: CloudCollectionStatus) -> SnipSnapCloudSyncResult {
  switch status {
  case .on:
    .contentUpdated
  case .requiresEnable:
    .noChange
  case .oldSyncedContentRemovalPending:
    .oldSyncedContentRemovalPending
  case .deletedSyncedContent:
    .oldSyncedContentRemovalCompleted
  case .enabled, .adoptedRemoteCollection:
    .libraryReplaced
  case .purged:
    .iCloudDataReset
  }
}

func deleteOutcome(for status: CloudCollectionStatus) -> SyncedContentDeleteOutcome {
  if case .oldSyncedContentRemovalPending = status { return .removalPending }
  return .completed
}

struct NoopCloudCollectionSyncDriver: CloudCollectionSyncDriver {
  func fetch(_ context: CloudCollectionSyncContext) async throws -> CloudCollectionFetchResult {
    .fetched
  }
  func send(_ context: CloudCollectionSyncContext) async throws -> CloudCollectionSendResult {
    .sent
  }
}
