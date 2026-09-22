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
      String(localized: "Waiting for connection", bundle: .main)
    case .iCloudUnavailable:
      String(localized: "iCloud unavailable", bundle: .main)
    case .retryingSoon:
      String(localized: "Sync paused", bundle: .main)
    case .checkingAccount:
      String(localized: "Checking iCloud…", bundle: .main)
    case .signInRequired:
      String(localized: "Sign in to iCloud", bundle: .main)
    case .accountRestricted:
      String(localized: "iCloud restricted", bundle: .main)
    case .accountTemporarilyUnavailable:
      String(localized: "Sync paused", bundle: .main)
    case .iCloudStorageFull:
      String(localized: "iCloud storage full", bundle: .main)
    case .updateRequired:
      String(localized: "Update Snip Snap", bundle: .main)
    case .accessDenied:
      String(localized: "Can’t access iCloud", bundle: .main)
    case .someChangesPending:
      String(localized: "Some changes haven’t synced", bundle: .main)
    case .attachmentMissing:
      String(localized: "Couldn’t sync an attachment", bundle: .main)
    case .attachmentUnavailable:
      String(localized: "Attachment unavailable", bundle: .main)
    case .attachmentStorageUnavailable:
      String(localized: "Couldn’t save an attachment", bundle: .main)
    case .setupBlocked:
      String(localized: "Couldn’t set up sync", bundle: .main)
    case .iCloudDataReset:
      String(localized: "Sync turned off", bundle: .main)
    case .iCloudAccountChanged:
      String(localized: "iCloud account changed", bundle: .main)
    case .appDataIssue:
      String(localized: "Couldn’t sync", bundle: .main)
    }
  }

  fileprivate func detail(mode: SyncedContentMode) -> String {
    return switch self {
    case .waitingForConnection:
      mode == .localOnly
        ? String(localized: "Connect to the internet to finish setup.", bundle: .main)
        : String(localized: "Your changes will sync when you’re back online.", bundle: .main)
    case .iCloudUnavailable:
      mode == .localOnly
        ? String(localized: "iCloud isn’t available right now. Setup will try again.", bundle: .main)
        : String(localized: "iCloud isn’t available right now. Sync will try again.", bundle: .main)
    case .retryingSoon:
      String(localized: "Sync will resume when iCloud is ready.", bundle: .main)
    case .checkingAccount:
      String(localized: "Can’t check your iCloud account right now. Sync will try again.", bundle: .main)
    case .signInRequired:
      String(localized: "Sign in to iCloud in your device settings to sync your snips.", bundle: .main)
    case .accountRestricted:
      String(localized: "Check your device’s iCloud restrictions or ask your administrator.", bundle: .main)
    case .accountTemporarilyUnavailable:
      String(localized: "Sync will resume when your iCloud account is available.", bundle: .main)
    case .iCloudStorageFull:
      String(localized: "Free up iCloud storage, then retry sync.", bundle: .main)
    case .updateRequired:
      String(localized: "Update Snip Snap to keep syncing.", bundle: .main)
    case .accessDenied:
      String(localized: "Check your device’s iCloud permissions for Snip Snap.", bundle: .main)
    case .someChangesPending:
      String(localized: "Sync will retry the remaining changes.", bundle: .main)
    case .attachmentMissing:
      String(localized: "Can’t read an attachment. Retry sync. If it still fails, contact support.", bundle: .main)
    case .attachmentUnavailable:
      String(localized: "iCloud can’t provide this attachment yet. Sync will try again.", bundle: .main)
    case .attachmentStorageUnavailable:
      String(localized: "Retry sync. If it still fails, contact support.", bundle: .main)
    case .setupBlocked(let message):
      String(localized: "\(message) Remove or replace these attachments, then retry sync.", bundle: .main)
    case .iCloudDataReset:
      String(localized: "iCloud deleted Snip Snap’s synced content. Sync is off so old data won’t upload again.", bundle: .main)
    case .iCloudAccountChanged:
      String(localized: "Your previous account’s snips stay separate. Choose whether to keep them before syncing again.", bundle: .main)
    case .appDataIssue:
      String(localized: "Retry sync. If it still fails, update Snip Snap or contact support.", bundle: .main)
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

  fileprivate var diagnosticCode: String {
    switch self {
    case .waitingForConnection: "sync.waitingForConnection"
    case .iCloudUnavailable: "sync.iCloudUnavailable"
    case .retryingSoon: "sync.retryingSoon"
    case .checkingAccount: "sync.checkingAccount"
    case .signInRequired: "sync.signInRequired"
    case .accountRestricted: "sync.accountRestricted"
    case .accountTemporarilyUnavailable: "sync.accountTemporarilyUnavailable"
    case .iCloudStorageFull: "sync.iCloudStorageFull"
    case .updateRequired: "sync.updateRequired"
    case .accessDenied: "sync.accessDenied"
    case .someChangesPending: "sync.someChangesPending"
    case .attachmentMissing: "sync.attachmentMissing"
    case .attachmentUnavailable: "sync.attachmentUnavailable"
    case .attachmentStorageUnavailable: "sync.attachmentStorageUnavailable"
    case .setupBlocked: "sync.setupBlocked"
    case .iCloudDataReset: "sync.iCloudDataReset"
    case .iCloudAccountChanged: "sync.iCloudAccountChanged"
    case .appDataIssue: "sync.appDataIssue"
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
  private let diagnostics: any AppDiagnosticRecording
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
    deleteAction: DeleteAction? = nil,
    diagnostics: any AppDiagnosticRecording = AppDiagnostics.shared
  ) {
    self.mode = mode
    self.issueMapper = issueMapper
    self.enableAction = enableAction
    self.cancelEnableAction = cancelEnableAction
    self.disableAction = disableAction
    self.deleteAction = deleteAction
    self.diagnostics = diagnostics
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
    case (.localOnly, .enabling): String(localized: "Setting up sync…", bundle: .main)
    case (.localOnly, _): String(localized: "Sync off", bundle: .main)
    case (_, .ready): String(localized: "Sync on", bundle: .main)
    case (_, .enabling): String(localized: "Setting up sync…", bundle: .main)
    case (_, .syncing): String(localized: "Syncing with iCloud…", bundle: .main)
    case (_, .disabling): String(localized: "Turning off sync…", bundle: .main)
    case (_, .deleting): String(localized: "Deleting synced content…", bundle: .main)
    case (_, .removalPending): String(localized: "Deletion incomplete", bundle: .main)
    case (_, .deleted): String(localized: "Synced content deleted", bundle: .main)
    }
  }

  public var detail: String {
    switch (mode, state) {
    case (_, .failed(let issue)), (_, .enabling(let issue?)):
      issue.detail(mode: mode)
    case (.localOnly, .enabling):
      String(localized: "Getting your snips from iCloud…", bundle: .main)
    case (.iCloudSync, .enabling):
      String(localized: "Finishing sync setup…", bundle: .main)
    case (.iCloudSync, .syncing):
      String(localized: "Checking for changes…", bundle: .main)
    case (.iCloudSync, .disabling):
      String(localized: "Saving a copy on this device. Your iCloud data stays.", bundle: .main)
    case (.localOnly, _):
      String(localized: "Your snips aren’t syncing with iCloud.", bundle: .main)
    case (_, .ready):
      String(localized: "Your snips and attachments sync through iCloud.", bundle: .main)
    case (_, .deleting):
      String(localized: "Removing synced content from iCloud…", bundle: .main)
    case (_, .removalPending):
      String(localized: "Sync will retry the deletion. This device keeps a recovery copy.", bundle: .main)
    case (_, .deleted):
      String(localized: "This device keeps a recovery copy.", bundle: .main)
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
        if let issue { record(issue, operation: "sync.setup") }
        mode = .localOnly
        state = .enabling(issue)
      }
    } catch {
      diagnostics.record(.failure(
        operation: "sync.enable",
        error: error,
        visibility: .user
      ))
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
      diagnostics.record(.failure(
        operation: "sync.disable",
        error: error,
        visibility: .user
      ))
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
      diagnostics.record(.failure(
        operation: "sync.cancel_setup",
        error: error,
        visibility: .user
      ))
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
    case .ready:
      state = .syncing
    case .enabling, .syncing, .disabling, .deleting, .removalPending, .deleted, .failed:
      break
    }
  }

  /// Records that a normal sync request finished.
  public func recordSyncCompleted() {
    guard mode == .iCloudSync else { return }
    switch state {
    case .syncing:
      state = .ready
    default:
      break
    }
  }

  /// Records that the sync engine reports no work or failures remain.
  public func recordOutstandingSyncRecovered() {
    guard mode == .iCloudSync else { return }
    switch state {
    case .syncing, .failed:
      state = .ready
    default:
      break
    }
  }

  public func recordSyncFailure(_ issue: SyncedContentSyncIssue) {
    switch (mode, state) {
    case (.iCloudSync, .failed(let existing)) where existing == issue:
      break
    case (.iCloudSync, .ready), (.iCloudSync, .syncing), (.iCloudSync, .failed):
      record(issue, operation: "sync.run")
      state = .failed(issue)
    case (.localOnly, .enabling(let existing)) where existing == issue:
      break
    case (.localOnly, .enabling) where issue.retriesAutomatically:
      record(issue, operation: "sync.setup")
      state = .enabling(issue)
    case (.localOnly, .enabling):
      record(issue, operation: "sync.setup")
      state = .failed(issue)
    default:
      break
    }
  }

  public func recordSyncStopped(_ issue: SyncedContentSyncIssue) {
    if mode == .localOnly, state == .failed(issue) { return }
    record(issue, operation: "sync.stop")
    mode = .localOnly
    state = .failed(issue)
  }

  public func recordEnableSettingUp(_ issue: SyncedContentSyncIssue? = nil) {
    if mode == .localOnly, state == .enabling(issue) { return }
    if let issue { record(issue, operation: "sync.setup") }
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
      diagnostics.record(.failure(
        operation: "sync.delete",
        error: error,
        visibility: .user
      ))
      state = .failed(issueMapper(error))
    }
  }

  private func record(_ issue: SyncedContentSyncIssue, operation: StaticString) {
    diagnostics.record(.failure(
      operation: operation,
      errorCode: issue.diagnosticCode,
      visibility: .user
    ))
  }
}
