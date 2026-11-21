import SnipSnapCore

extension SnipSnapCloudSyncResult {
  public var syncStopIssue: SyncedContentSyncIssue? {
    switch self {
    case .iCloudDataReset: .iCloudDataReset
    case .iCloudSignedOut: .signInRequired
    case .iCloudAccountChanged: .iCloudAccountChanged
    default: nil
    }
  }

  @MainActor
  @discardableResult
  public func applyEnableProgress(
    to settings: SyncedContentSettingsModel, started: SyncedContentSyncStart,
    reload: @MainActor () async throws -> Void
  ) async throws -> Bool {
    switch self {
    case .iCloudSyncSettingUp(let issue):
      guard settings.acceptsEnableCompletion(started: started) else { return false }
      settings.recordEnableSettingUp(issue)
    case .iCloudSyncEnabled:
      do {
        try await reload()
      } catch {
        guard settings.acceptsEnableCompletion(started: started) else { return false }
        throw error
      }
      guard settings.acceptsEnableCompletion(started: started) else { return false }
      settings.recordEnableCompleted()
    default:
      return false
    }
    return true
  }
}

func automaticSyncResult(for error: any Error) -> SnipSnapCloudSyncResult {
  if let account = error as? ICloudAccountGateError {
    switch account {
    case .noAccount: return .iCloudSignedOut
    case .accountChanged: return .iCloudAccountChanged
    default: break
    }
  }
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
