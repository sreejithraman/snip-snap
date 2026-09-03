import Foundation
import Observation

public enum SyncedContentMode: Equatable, Sendable {
  case localOnly
  case iCloudSync
}

public enum SyncedContentSyncIssue: Codable, Equatable, Sendable {
  case waitingForConnection
  case iCloudUnavailable
  case retryingSoon
  case checkingAccount
  case signInRequired
  case accountRestricted
  case accountTemporarilyUnavailable
  case iCloudStorageFull
  case updateRequired
  case accessDenied
  case someChangesPending
  case attachmentMissing
  case attachmentUnavailable
  case attachmentStorageUnavailable
  case setupBlocked(String)
  case iCloudDataReset
  case iCloudAccountChanged
  case appDataIssue

  fileprivate var statusTitle: String {
    switch self {
    case .waitingForConnection:
      String(localized: "Waiting for a Connection", bundle: .main)
    case .iCloudUnavailable:
      String(localized: "iCloud Is Unavailable", bundle: .main)
    case .retryingSoon:
      String(localized: "iCloud Sync Paused", bundle: .main)
    case .checkingAccount:
      String(localized: "Checking iCloud…", bundle: .main)
    case .signInRequired:
      String(localized: "Sign In to iCloud", bundle: .main)
    case .accountRestricted:
      String(localized: "iCloud Access Is Restricted", bundle: .main)
    case .accountTemporarilyUnavailable:
      String(localized: "iCloud Sync Paused", bundle: .main)
    case .iCloudStorageFull:
      String(localized: "iCloud Storage Is Full", bundle: .main)
    case .updateRequired:
      String(localized: "Update Snip Snap to Sync", bundle: .main)
    case .accessDenied:
      String(localized: "iCloud Access Was Denied", bundle: .main)
    case .someChangesPending:
      String(localized: "Some Changes Haven’t Synced", bundle: .main)
    case .attachmentMissing:
      String(localized: "An Attachment Couldn’t Sync", bundle: .main)
    case .attachmentUnavailable:
      String(localized: "An Attachment Isn’t Available", bundle: .main)
    case .attachmentStorageUnavailable:
      String(localized: "An Attachment Couldn’t Be Saved", bundle: .main)
    case .setupBlocked:
      String(localized: "iCloud Sync Setup Stopped", bundle: .main)
    case .iCloudDataReset:
      String(localized: "iCloud Sync Was Turned Off", bundle: .main)
    case .iCloudAccountChanged:
      String(localized: "iCloud Account Changed", bundle: .main)
    case .appDataIssue:
      String(localized: "Snip Snap Couldn’t Sync", bundle: .main)
    }
  }

  fileprivate func detail(mode: SyncedContentMode) -> String {
    let safeCopy = mode == .localOnly
      ? String(localized: "Your local library remains available.", bundle: .main)
      : String(localized: "Your changes are safe on this device.", bundle: .main)
    return switch self {
    case .waitingForConnection:
      mode == .localOnly
        ? String(localized: "You appear to be offline. Your local library remains available, and Snip Snap will finish setup when you’re back online.", bundle: .main)
        : String(localized: "You appear to be offline. Your changes are safe on this device and will sync when you’re back online.", bundle: .main)
    case .iCloudUnavailable:
      mode == .localOnly
        ? String(localized: "Snip Snap can’t reach iCloud right now. Your local library remains available, and setup will try again.", bundle: .main)
        : String(localized: "Snip Snap can’t reach iCloud right now. Your changes are safe on this device, and sync will try again.", bundle: .main)
    case .retryingSoon:
      String(localized: "iCloud asked Snip Snap to wait. \(safeCopy) Sync will try again soon.", bundle: .main)
    case .checkingAccount:
      String(localized: "Snip Snap can’t check your iCloud account right now. \(safeCopy) Sync will try again.", bundle: .main)
    case .signInRequired:
      String(localized: "Sign in to iCloud in Settings to sync your snips. Your changes will stay on this device until then.", bundle: .main)
    case .accountRestricted:
      String(localized: "A device setting or management rule is blocking iCloud. Your changes will stay on this device.", bundle: .main)
    case .accountTemporarilyUnavailable:
      String(localized: "Your iCloud account is not ready for sync right now. \(safeCopy) Sync will resume when iCloud is available.", bundle: .main)
    case .iCloudStorageFull:
      String(localized: "Free up some iCloud storage, then try sync again. \(safeCopy)", bundle: .main)
    case .updateRequired:
      String(localized: "This version can no longer sync with iCloud. Update Snip Snap to keep syncing. \(safeCopy)", bundle: .main)
    case .accessDenied:
      String(localized: "Snip Snap can’t access this iCloud data. Check your iCloud and device restrictions. \(safeCopy)", bundle: .main)
    case .someChangesPending:
      String(localized: "Some changes did not reach iCloud. Your other changes are safe, and Snip Snap will retry.", bundle: .main)
    case .attachmentMissing:
      String(localized: "Snip Snap can’t find or read one attachment on this device. Your other changes are safe.", bundle: .main)
    case .attachmentUnavailable:
      String(localized: "One attachment can’t be read from iCloud right now. Your other changes are safe, and Snip Snap will try again.", bundle: .main)
    case .attachmentStorageUnavailable:
      String(localized: "Snip Snap couldn’t prepare a safe place for one iCloud attachment on this device. Your other changes are safe, and sync will try again.", bundle: .main)
    case .setupBlocked(let message):
      String(localized: "Snip Snap could not finish setting up iCloud Sync. \(safeCopy) \(message)", bundle: .main)
    case .iCloudDataReset:
      String(localized: "The synced Snip Snap data was removed from iCloud. Snip Snap cleared its old sync copy and will not upload it again. You can turn sync on when you’re ready.", bundle: .main)
    case .iCloudAccountChanged:
      String(localized: "Snip Snap stopped sync for the prior iCloud account and opened a separate local library. Sign in to the account you want to use, then turn sync on.", bundle: .main)
    case .appDataIssue:
      String(localized: "\(safeCopy) Try sync again. If this keeps happening, update Snip Snap if an update is available or contact support.", bundle: .main)
    }
  }

  package var canRetry: Bool {
    switch self {
    case .signInRequired, .accountRestricted, .updateRequired, .accessDenied,
         .iCloudDataReset, .iCloudAccountChanged:
      false
    default:
      true
    }
  }

  package var retriesAutomatically: Bool {
    switch self {
    case .waitingForConnection, .iCloudUnavailable, .retryingSoon, .checkingAccount,
         .accountTemporarilyUnavailable, .someChangesPending, .attachmentUnavailable:
      true
    default:
      false
    }
  }
}

public enum SyncedContentSettingsState: Equatable, Sendable {
  case ready
  case enabling(SyncedContentSyncIssue? = nil)
  case syncing
  case disabling
  case deleting
  case removalPending
  case deleted
  case failed(SyncedContentSyncIssue)
}

public enum SyncedContentEnableOutcome: Equatable, Sendable {
  case enabled
  case settingUp(SyncedContentSyncIssue? = nil)
}

public enum SyncedContentDisableChoice: Equatable, Sendable {
  case refreshThenCopy
  case useCurrentCache
}

public enum SyncedContentDeleteOutcome: Equatable, Sendable {
  case completed
  case removalPending
}

@MainActor
@Observable
public final class SyncedContentSettingsModel {
  public typealias IssueMapper = @Sendable (any Error) -> SyncedContentSyncIssue
  public typealias EnableAction = @Sendable () async throws -> SyncedContentEnableOutcome
  public typealias CancelEnableAction = @Sendable () async throws -> Void
  public typealias DisableAction = @Sendable (SyncedContentDisableChoice) async throws -> Void
  public typealias DeleteAction = @Sendable () async throws -> SyncedContentDeleteOutcome
  public typealias DeleteCompletionAction = @MainActor @Sendable () async throws -> Void

  public private(set) var mode: SyncedContentMode
  public private(set) var state: SyncedContentSettingsState
  private let enableAction: EnableAction?
  private let issueMapper: IssueMapper
  private let cancelEnableAction: CancelEnableAction?
  private let disableAction: DisableAction?
  private let deleteAction: DeleteAction?
  private var enableCompletionAction: DeleteCompletionAction?
  private var disableCompletionAction: DeleteCompletionAction?
  private var deleteCompletionAction: DeleteCompletionAction?

  public init(
    mode: SyncedContentMode,
    initialState: SyncedContentSettingsState = .ready,
    issueMapper: @escaping IssueMapper = { _ in .appDataIssue },
    enableAction: EnableAction? = nil,
    cancelEnableAction: CancelEnableAction? = nil,
    disableAction: DisableAction? = nil,
    deleteAction: DeleteAction? = nil
  ) {
    self.mode = mode
    self.issueMapper = issueMapper
    self.enableAction = enableAction
    self.cancelEnableAction = cancelEnableAction
    self.disableAction = disableAction
    self.deleteAction = deleteAction
    state = initialState
  }

  public func setEnableCompletionAction(_ action: @escaping DeleteCompletionAction) {
    enableCompletionAction = action
  }

  public func setDisableCompletionAction(_ action: @escaping DeleteCompletionAction) {
    disableCompletionAction = action
  }

  public func setDeleteCompletionAction(_ action: @escaping DeleteCompletionAction) {
    deleteCompletionAction = action
  }

  public var canDelete: Bool {
    guard mode == .iCloudSync, deleteAction != nil else { return false }
    return switch state {
    case .ready, .failed: true
    case .enabling, .syncing, .disabling, .deleting, .removalPending, .deleted: false
    }
  }

  public var canEnable: Bool {
    guard mode == .localOnly, enableAction != nil else { return false }
    return switch state {
    case .ready, .failed: true
    case .enabling, .syncing, .disabling, .deleting, .removalPending, .deleted: false
    }
  }

  public var canCancelEnable: Bool {
    guard mode == .localOnly, cancelEnableAction != nil else { return false }
    if case .enabling = state { return true }
    return false
  }

  public var canDisable: Bool {
    guard mode == .iCloudSync, disableAction != nil else { return false }
    return switch state {
    case .ready, .failed, .deleted: true
    case .enabling, .syncing, .disabling, .deleting, .removalPending: false
    }
  }

  public var statusTitle: String {
    switch (mode, state) {
    case (_, .failed(let issue)): issue.statusTitle
    case (_, .enabling(let issue?)): issue.statusTitle
    case (.localOnly, .enabling): String(localized: "Setting Up iCloud Sync…", bundle: .main)
    case (.localOnly, _): String(localized: "Local Only", bundle: .main)
    case (_, .ready): String(localized: "iCloud Sync On", bundle: .main)
    case (_, .enabling): String(localized: "Setting Up iCloud Sync…", bundle: .main)
    case (_, .syncing): String(localized: "Syncing with iCloud…", bundle: .main)
    case (_, .disabling): String(localized: "Turning Off iCloud Sync…", bundle: .main)
    case (_, .deleting): String(localized: "Deleting Synced Content…", bundle: .main)
    case (_, .removalPending): String(localized: "Old Synced Content Removal Pending", bundle: .main)
    case (_, .deleted): String(localized: "Synced Content Deleted", bundle: .main)
    }
  }

  public var detail: String {
    switch (mode, state) {
    case (_, .failed(let issue)), (_, .enabling(let issue?)):
      issue.detail(mode: mode)
    case (.localOnly, .enabling):
      String(localized: "Snip Snap is fetching iCloud data and preparing a safe merged copy.", bundle: .main)
    case (.iCloudSync, .enabling):
      String(localized: "Snip Snap is finishing iCloud Sync setup.", bundle: .main)
    case (.iCloudSync, .syncing):
      String(localized: "Snip Snap is checking iCloud for changes.", bundle: .main)
    case (.iCloudSync, .disabling):
      String(localized: "Snip Snap is making a local copy of your synced library. Your iCloud copy will stay in place.", bundle: .main)
    case (.localOnly, _):
      String(localized: "Snip Snap does not send local-only data to CloudKit.", bundle: .main)
    case (_, .ready):
      String(localized: "Saved snips and attachments sync through your private iCloud database. Snip Snap’s maintainers cannot inspect private records in CloudKit Console. Apple encrypts synced data in transit and at rest; user fields use encrypted values and files use CKAsset data. Those user fields and attachments are end-to-end encrypted only when Advanced Data Protection is on.", bundle: .main)
    case (_, .deleting):
      String(localized: "Snip Snap is starting a fresh empty synced collection and removing the old data zones.", bundle: .main)
    case (_, .removalPending):
      String(localized: "Snip Snap started a fresh empty synced collection, but it could not remove all old iCloud data yet. It will retry the next time it syncs. Your local recovery copy remains.", bundle: .main)
    case (_, .deleted):
      String(localized: "Synced content was removed. This device kept a local recovery copy. A small control record remains in iCloud so an old device cannot restore the deleted collection.", bundle: .main)
    }
  }

  public var canRetryFailedSync: Bool {
    guard case .failed(let issue) = state else { return false }
    return issue.canRetry
  }

  public func enableICloudSync() async {
    guard canEnable, let enableAction else { return }
    state = .enabling()
    do {
      switch try await enableAction() {
      case .enabled:
        try await enableCompletionAction?()
        mode = .iCloudSync
        state = .ready
      case .settingUp(let issue):
        mode = .localOnly
        state = .enabling(issue)
      }
    } catch {
      state = .failed(issueMapper(error))
    }
  }

  public func disableICloudSync(_ choice: SyncedContentDisableChoice) async {
    guard canDisable, let disableAction else { return }
    state = .disabling
    do {
      try await disableAction(choice)
      try await disableCompletionAction?()
      mode = .localOnly
      state = .ready
    } catch {
      state = .failed(issueMapper(error))
    }
  }

  public func cancelICloudSyncSetup() async {
    guard canCancelEnable, let cancelEnableAction else { return }
    do {
      try await cancelEnableAction()
      mode = .localOnly
      state = .ready
    } catch {
      state = .failed(issueMapper(error))
    }
  }

  public func recordRemovalPending(_ pending: Bool) {
    guard mode == .iCloudSync else { return }
    state = pending ? .removalPending : .deleted
  }

  public func recordSyncStarted() {
    guard mode == .iCloudSync else { return }
    switch state {
    case .ready, .failed:
      state = .syncing
    case .enabling, .syncing, .disabling, .deleting, .removalPending, .deleted:
      break
    }
  }

  public func recordSyncCompleted() {
    guard mode == .iCloudSync else { return }
    switch state {
    case .syncing:
      state = .ready
    default:
      break
    }
  }

  public func recordOutstandingSyncRecovered() {
    guard mode == .iCloudSync else { return }
    if case .failed = state { state = .ready }
  }

  public func recordSyncFailure(_ issue: SyncedContentSyncIssue) {
    switch (mode, state) {
    case (.iCloudSync, .ready), (.iCloudSync, .syncing), (.iCloudSync, .failed):
      state = .failed(issue)
    case (.localOnly, .enabling) where issue.retriesAutomatically:
      state = .enabling(issue)
    case (.localOnly, .enabling):
      state = .failed(issue)
    default:
      break
    }
  }

  public func recordSyncStopped(_ issue: SyncedContentSyncIssue) {
    mode = .localOnly
    state = .failed(issue)
  }

  public func recordEnableSettingUp(_ issue: SyncedContentSyncIssue? = nil) {
    mode = .localOnly
    state = .enabling(issue)
  }

  public func recordEnableCompleted() {
    mode = .iCloudSync
    state = .ready
  }

  public func deleteSyncedContent() async {
    guard canDelete, let deleteAction else { return }
    state = .deleting
    do {
      let outcome = try await deleteAction()
      try await deleteCompletionAction?()
      state = outcome == .completed ? .deleted : .removalPending
    } catch {
      state = .failed(issueMapper(error))
    }
  }
}
