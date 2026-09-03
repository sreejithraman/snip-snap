import CloudKit
import Foundation
import SnipSnapCore

public enum SnipSnapCloudSyncIssueMapper {
  public static func issue(for error: any Error) -> SyncedContentSyncIssue {
    if let issueError = error as? CloudSyncIssueError {
      return issueError.issue
    }
    if let cloudKitError = error as? CKError {
      return issue(for: cloudKitError)
    }
    if let accountError = error as? ICloudAccountGateError {
      return switch accountError {
      case .couldNotDetermine: .checkingAccount
      case .noAccount: .signInRequired
      case .restricted: .accountRestricted
      case .temporarilyUnavailable: .accountTemporarilyUnavailable
      case .accountChanged: .iCloudAccountChanged
      }
    }
    if let recordError = error as? CloudRecordError {
      return switch recordError {
      case .invalidAssetDestination: .attachmentStorageUnavailable
      case .missingAsset: .attachmentUnavailable
      case .invalidShadow, .mismatchedShadow, .unsupportedValue, .missingField,
           .invalidField, .projectedSnapshot, .wrongRecordType:
        .appDataIssue
      }
    }
    if error is CloudAttachmentSetupError {
      return .setupBlocked(error.localizedDescription)
    }
    if let collectionError = error as? CloudCollectionError {
      return switch collectionError {
      case .operationInProgress: .retryingSoon
      case .noActiveCollection, .invalidDescriptor, .syncNeedsAttention:
        .appDataIssue
      }
    }
    if error is CloudSyncRetryableError {
      return .someChangesPending
    }
    if let transportError = error as? CloudTransportError {
      return switch transportError {
      case .fetchFailed, .sendFailed: .someChangesPending
      case .syncAlreadyRunning: .retryingSoon
      case .stateNamespaceMismatch, .invalidEngineState, .invalidRecord,
           .wrongBatchConfirmation, .notStarted:
        .appDataIssue
      }
    }
    return .appDataIssue
  }

  private static func issue(for error: CKError) -> SyncedContentSyncIssue {
    if error.code == .partialFailure {
      let itemErrors = (error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error])?
        .values
        .map(issue(for:)) ?? []
      return CloudSyncIssueError.preferredIssue(from: itemErrors) ?? .someChangesPending
    }
    return switch error.code {
    case .networkUnavailable:
      .waitingForConnection
    case .networkFailure, .serviceUnavailable, .serverResponseLost:
      .iCloudUnavailable
    case .requestRateLimited, .zoneBusy:
      .retryingSoon
    case .notAuthenticated:
      .checkingAccount
    case .accountTemporarilyUnavailable:
      .accountTemporarilyUnavailable
    case .quotaExceeded:
      .iCloudStorageFull
    case .incompatibleVersion:
      .updateRequired
    case .permissionFailure, .managedAccountRestricted:
      .accessDenied
    case .assetFileModified, .assetFileNotFound:
      .attachmentMissing
    case .assetNotAvailable:
      .attachmentUnavailable
    case .batchRequestFailed, .changeTokenExpired, .operationCancelled:
      .someChangesPending
    case .partialFailure:
      .someChangesPending
    default:
      .appDataIssue
    }
  }

}

package struct CloudSyncIssueError: Error, Equatable, Sendable {
  package let issue: SyncedContentSyncIssue

  package init(_ issue: SyncedContentSyncIssue) {
    self.issue = issue
  }

  package static func issue(in batch: CloudSyncBatch) -> SyncedContentSyncIssue? {
    preferredIssue(from: issues(in: batch))
  }

  package static func issues(in batch: CloudSyncBatch) -> [SyncedContentSyncIssue] {
    let failures: [CloudOperationFailure] = switch batch {
    case .fetched(let fetched):
      fetched.items.compactMap(\.failure)
        + fetched.databaseEvents.compactMap(\.failure)
        + fetched.zoneEvents.compactMap(\.failure)
    case .sent(let sent):
      sent.items.compactMap(\.failure)
        + sent.databaseEvents.compactMap(\.failure)
        + sent.zoneEvents.compactMap(\.failure)
    }
    return failures.compactMap(\.syncIssue)
  }

  package static func blocksOutbound(in batch: CloudSyncBatch) -> Bool {
    switch batch {
    case .fetched(let fetched):
      fetched.databaseEvents.contains(where: \.isDestructiveReset)
        || fetched.databaseEvents.contains(where: \.isBlockingFailure)
        || fetched.zoneEvents.contains(where: \.isBlockingFailure)
    case .sent(let sent):
      sent.databaseEvents.contains(where: \.isDestructiveReset)
        || sent.databaseEvents.contains(where: \.isBlockingFailure)
        || sent.zoneEvents.contains(where: \.isBlockingFailure)
    }
  }

  package static func requiresEngineReset(_ batch: CloudSyncBatch) -> Bool {
    let failures: [CloudOperationFailure] = switch batch {
    case .fetched(let fetched):
      fetched.items.compactMap(\.failure)
        + fetched.databaseEvents.compactMap(\.failure)
        + fetched.zoneEvents.compactMap(\.failure)
    case .sent(let sent):
      sent.items.compactMap(\.failure)
        + sent.databaseEvents.compactMap(\.failure)
        + sent.zoneEvents.compactMap(\.failure)
    }
    return failures.contains(.changeTokenExpired)
  }

  package static func preferredIssue(
    from issues: [SyncedContentSyncIssue]
  ) -> SyncedContentSyncIssue? {
    let order: [SyncedContentSyncIssue] = [
      .iCloudStorageFull,
      .updateRequired,
      .signInRequired,
      .accountRestricted,
      .accessDenied,
      .attachmentMissing,
      .attachmentUnavailable,
      .waitingForConnection,
      .iCloudUnavailable,
      .retryingSoon,
      .checkingAccount,
      .accountTemporarilyUnavailable,
      .appDataIssue,
      .someChangesPending,
    ]
    return order.first(where: issues.contains)
  }
}

private extension CloudDatabaseEvent {
  var isDestructiveReset: Bool {
    guard case .zoneDeleted(_, let reason) = self else { return false }
    return reason == .purged || reason == .encryptedDataReset
  }
}

private extension CloudOperationFailure {
  var syncIssue: SyncedContentSyncIssue? {
    switch self {
    case .networkUnavailable: .waitingForConnection
    case .iCloudUnavailable: .iCloudUnavailable
    case .rateLimited: .retryingSoon
    case .authenticationRequired: .checkingAccount
    case .accountTemporarilyUnavailable: .accountTemporarilyUnavailable
    case .quotaExceeded: .iCloudStorageFull
    case .updateRequired: .updateRequired
    case .accessDenied: .accessDenied
    case .attachmentMissing: .attachmentMissing
    case .attachmentUnavailable: .attachmentUnavailable
    case .changeTokenExpired, .retryable: .someChangesPending
    case .rejected, .invalidRecord, .zoneMissing: .appDataIssue
    }
  }
}

private extension CloudFetchItemResult {
  var failure: CloudOperationFailure? {
    guard case .failed(_, let failure) = self else { return nil }
    return failure
  }
}

private extension CloudSendItemResult {
  var failure: CloudOperationFailure? {
    guard case .failed(_, let failure) = self else { return nil }
    return failure
  }
}

private extension CloudDatabaseEvent {
  var failure: CloudOperationFailure? {
    guard case .failed(_, let failure) = self else { return nil }
    return failure
  }

  var isBlockingFailure: Bool {
    guard case .failed = self else { return false }
    return true
  }
}

private extension CloudZoneEvent {
  var failure: CloudOperationFailure? {
    guard case .failed(_, let failure) = self else { return nil }
    return failure
  }

  var isBlockingFailure: Bool {
    guard case .failed = self else { return false }
    return true
  }
}
