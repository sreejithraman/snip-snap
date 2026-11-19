import SnipSnapCore
import SnipSnapPersistence

extension SnipSnapCloudSyncResult {
  @MainActor
  public func applyDeferredEnableCompletion(
    to settings: SyncedContentSettingsModel,
    reload: @MainActor () async throws -> Void,
    acknowledge: @MainActor (ICloudSyncNamespaceBinding) async throws -> Void
  ) async throws -> Bool {
    guard case .deferredICloudSyncEnabled(let binding, let issue) = self else { return false }
    try await reload()
    settings.recordEnableCompleted()
    if let issue { settings.recordSyncFailure(issue) }
    try await acknowledge(binding)
    return issue != nil
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
