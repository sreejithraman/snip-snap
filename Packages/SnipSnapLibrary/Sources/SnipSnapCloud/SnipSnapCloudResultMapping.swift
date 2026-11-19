import SnipSnapCore

extension SnipSnapCloudSyncResult {
  @MainActor
  public func applyDeferredEnableCompletion(
    to settings: SyncedContentSettingsModel,
    started: SyncedContentSyncStart,
    reload: @MainActor () async throws -> Void,
    acknowledge: @MainActor (SnipSnapDeferredEnableCompletion) async throws -> Bool
  ) async throws -> Bool {
    guard case .deferredICloudSyncEnabled(let completion) = self else { return false }
    guard settings.acceptsEnableCompletion(started: started) else { return true }
    try await reload()
    guard settings.acceptsEnableCompletion(started: started),
      try await acknowledge(completion), settings.acceptsEnableCompletion(started: started)
    else { return true }
    settings.recordEnableCompleted()
    if let issue = completion.issue { settings.recordSyncFailure(issue) }
    return completion.issue != nil
  }
}

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
  case .scheduled:
    .syncScheduled
  case .on:
    .contentUpdated
  case .settled:
    .syncCompleted
  case .requiresEnable:
    .noChange
  case .oldSyncedContentRemovalPending:
    .oldSyncedContentRemovalPending
  case .deletedSyncedContent:
    .oldSyncedContentRemovalCompleted
  case .enabled, .adoptedRemoteCollection:
    .libraryReplaced
  case .adoptedRemoteCollectionWithIssue(_, let issue):
    .libraryReplacedWithSyncIssue(issue)
  case .adoptedRemoteCollectionSettled:
    .libraryReplacedAndSyncCompleted
  case .adoptedRemoteCollectionScheduled:
    .libraryReplacedAndSyncScheduled
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
    .fetched(nil)
  }
  func send(_ context: CloudCollectionSyncContext) async throws -> CloudCollectionSendResult {
    .sent
  }
}
