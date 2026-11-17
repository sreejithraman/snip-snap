import SnipSnapCore

package enum CloudAccountIsolationError: Error, Equatable, Sendable {
  case signedOut
  case accountChanged

  var syncResult: SnipSnapCloudSyncResult {
    self == .signedOut ? .iCloudSignedOut : .iCloudAccountChanged
  }
}

func automaticSyncResult(for error: any Error) -> SnipSnapCloudSyncResult {
  if let isolation = error as? CloudAccountIsolationDeliveryError { return isolation.original.syncResult }
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

public extension SnipSnapCloudSyncResult {
  var originalActionValue: SyncedContentOriginalActionValue {
    switch self {
    case .noChange: .noChange
    case .contentUpdated: .contentUpdated
    case .libraryReplaced: .libraryReplaced
    case .libraryReplacedAndSyncCompleted: .libraryReplacedAndSyncCompleted
    case .libraryReplacedAndSyncScheduled: .libraryReplacedAndSyncScheduled
    case .iCloudDataReset: .iCloudDataReset
    case .iCloudSignedOut: .iCloudSignedOut
    case .iCloudAccountChanged: .iCloudAccountChanged
    case .syncCompleted: .syncCompleted
    case .syncScheduled: .syncScheduled
    case .iCloudSyncEnabled: .iCloudSyncEnabled
    case .oldSyncedContentRemovalPending: .oldSyncedContentRemovalPending
    case .oldSyncedContentRemovalCompleted: .oldSyncedContentRemovalCompleted
    case .libraryReplacedWithSyncIssue(let issue): .libraryReplacedWithSyncIssue(issue)
    case .syncIssue(let issue): .syncIssue(issue)
    case .iCloudSyncSettingUp(let issue): .iCloudSyncSettingUp(issue)
    }
  }

  var requiresApplication: Bool {
    switch self {
    case .noChange, .syncScheduled, .syncIssue, .iCloudSyncSettingUp: false
    default: true
    }
  }

  var offersCurrentConfirmation: Bool {
    switch self {
    case .noChange, .syncScheduled, .iCloudSyncSettingUp: false
    default: true
    }
  }

  var removalCompleted: Bool? {
    switch self { case .oldSyncedContentRemovalPending: false; case .oldSyncedContentRemovalCompleted: true; default: nil }
  }

  var skipsMacClipboardTail: Bool {
    switch self { case .syncIssue, .libraryReplacedWithSyncIssue: true; default: false }
  }
}
