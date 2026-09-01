import SnipSnapCore

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
  case .enabled, .adoptedRemoteCollection, .purged:
    .libraryReplaced
  case .encryptedDataResetRequiresChoice:
    .encryptedDataResetRequiresChoice
  case .syncKeptOff:
    .syncKeptOff
  }
}

func resolutionOutcome(
  for result: SnipSnapCloudSyncResult
) -> EncryptedDataResetResolutionOutcome {
  result == .encryptedDataResetRequiresChoice ? .requiresChoice : .resolved
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
