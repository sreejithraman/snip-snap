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

  public var diagnosticCode: String {
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

/// Original operation values, without checked-source or current-sync authority.
public enum SyncedContentOriginalActionValue: Equatable, Sendable {
  case noChange
  case contentUpdated
  case syncCompleted
  case syncScheduled
  case libraryReplaced
  case libraryReplacedWithSyncIssue(SyncedContentSyncIssue)
  case libraryReplacedAndSyncCompleted
  case libraryReplacedAndSyncScheduled
  case iCloudDataReset
  case iCloudSignedOut
  case iCloudAccountChanged
  case syncIssue(SyncedContentSyncIssue)
  case iCloudSyncSettingUp(SyncedContentSyncIssue? = nil)
  case iCloudSyncEnabled
  case oldSyncedContentRemovalPending
  case oldSyncedContentRemovalCompleted
}

public enum SyncedContentActionNotRunReason: Equatable, Sendable {
  case overlappingExplicitAction
  case unavailableSession
  case unsupportedLegacyHandler
  case unavailableAction
}

public enum SyncedContentActionInterruption: Equatable, Sendable {
  case cancelled
  case statusSessionChanged
  case sourceUnavailable
  case applicationUnavailable
}

/// Operation handling data, never a managed application or confirmation certificate.
public enum SyncedContentRequiredApplicationDisposition: Sendable {
  case notRequired
  /// The required operation hook returned; this attests no checked model application.
  case applied
  case failed(any Error)
  case interrupted(SyncedContentActionInterruption)
  case unavailable(SyncedContentActionInterruption)
}

public struct SyncedContentOriginalActionResult: Sendable {
  public let value: Result<SyncedContentOriginalActionValue, any Error>
  public let requiredApplication: SyncedContentRequiredApplicationDisposition

  public init(
    value: Result<SyncedContentOriginalActionValue, any Error>,
    requiredApplication: SyncedContentRequiredApplicationDisposition
  ) {
    self.value = value
    self.requiredApplication = requiredApplication
  }
}

public enum SyncedContentOriginalActionReturn: Sendable {
  case finished(SyncedContentOriginalActionValue, SyncedContentRequiredApplicationDisposition)
  case interrupted(SyncedContentActionInterruption, originalIfKnown: SyncedContentOriginalActionResult?)
}

public struct SyncedContentOperationReceiptProjection: Sendable {
  public enum Status: Equatable, Sendable { case succeeded, failed }
  public let status: Status
  public let message: String

  fileprivate init(status: Status, message: String) {
    self.status = status
    self.message = message
  }
}

/// One original operation projection, without current-state publication authority.
public struct OriginalSyncActionReport: Sendable {
  public let origin: Result<SyncedContentOriginalActionValue, any Error>
  public let requiredApplication: SyncedContentRequiredApplicationDisposition
  public let operation: SyncedContentOperationReceiptProjection

  fileprivate init(
    origin: Result<SyncedContentOriginalActionValue, any Error>,
    requiredApplication: SyncedContentRequiredApplicationDisposition,
    operation: SyncedContentOperationReceiptProjection
  ) {
    self.origin = origin
    self.requiredApplication = requiredApplication
    self.operation = operation
  }
}

public enum SyncedContentActionOutcome: Sendable {
  case completed(OriginalSyncActionReport)
  case notRun(SyncedContentActionNotRunReason)
  case interrupted(SyncedContentActionInterruption, originalIfKnown: SyncedContentOriginalActionResult?)
}

fileprivate struct SyncedContentStatus: Equatable, Sendable {
  var mode: SyncedContentMode
  var state: SyncedContentSettingsState

  enum RemovalEffect {
    case none
    case begin
    case failed(SyncedContentSyncIssue)
  }

  enum Change {
    case state(SyncedContentSettingsState)
    case replace(SyncedContentStatus)

    func apply(to status: inout SyncedContentStatus) {
      switch self {
      case .state(let state): status.state = state
      case .replace(let replacement): status = replacement
      }
    }
  }

  struct Transition {
    var change: Change? = nil
    var diagnostic: (issue: SyncedContentSyncIssue, operation: StaticString)? = nil
    var removal: RemovalEffect = .none
  }

  func startingSync() -> Transition {
    guard mode == .iCloudSync, state == .ready else { return Transition() }
    return Transition(change: .state(.syncing))
  }

  func completingSync(removalMatches: Bool) -> Transition {
    guard mode == .iCloudSync else { return Transition() }
    switch state {
    case .syncing: return Transition(change: .state(.ready))
    case .removalPending where removalMatches:
      return Transition(change: .state(.deleted))
    default: return Transition()
    }
  }

  func recoveringSync() -> Transition {
    guard mode == .iCloudSync else { return Transition() }
    switch state {
    case .syncing, .failed: return Transition(change: .state(.ready))
    default: return Transition()
    }
  }

  func failingSync(
    _ issue: SyncedContentSyncIssue, explicit: Bool, previousRemovalFailure: SyncedContentSyncIssue?
  ) -> Transition {
    switch (mode, state) {
    case (.iCloudSync, .failed(let existing)) where existing == issue:
      return Transition()
    case (.iCloudSync, .ready), (.iCloudSync, .syncing), (.iCloudSync, .failed):
      return Transition(change: .state(.failed(issue)), diagnostic: (issue, "sync.run"))
    case (.iCloudSync, .removalPending) where explicit && previousRemovalFailure != issue:
      return Transition(diagnostic: (issue, "sync.run"), removal: .failed(issue))
    case (.localOnly, .enabling(let existing)) where existing == issue:
      return Transition()
    case (.localOnly, .enabling) where issue.retriesAutomatically:
      return Transition(change: .state(.enabling(issue)), diagnostic: (issue, "sync.setup"))
    case (.localOnly, .enabling):
      return Transition(change: .state(.failed(issue)), diagnostic: (issue, "sync.setup"))
    default:
      return Transition()
    }
  }

  func stoppingSync(_ issue: SyncedContentSyncIssue) -> Transition {
    guard mode != .localOnly || state != .failed(issue) else { return Transition() }
    return Transition(change: .replace(SyncedContentStatus(mode: .localOnly, state: .failed(issue))),
                      diagnostic: (issue, "sync.stop"))
  }

  func startingEnable() -> Transition { Transition(change: .state(.enabling())) }
  func completingEnable() -> Transition {
    Transition(change: .replace(SyncedContentStatus(mode: .iCloudSync, state: .ready)))
  }
  func failingEnable(_ issue: SyncedContentSyncIssue) -> Transition {
    Transition(change: .state(.failed(issue)))
  }

  func settingUp(_ issue: SyncedContentSyncIssue?, deduplicating: Bool) -> Transition {
    if deduplicating, mode == .localOnly, state == .enabling(issue) { return Transition() }
    let diagnostic: (issue: SyncedContentSyncIssue, operation: StaticString)? = issue.map { ($0, "sync.setup") }
    return Transition(change: .replace(SyncedContentStatus(mode: .localOnly, state: .enabling(issue))),
                      diagnostic: diagnostic)
  }

  func beginningRemoval() -> Transition {
    Transition(change: .state(.removalPending), diagnostic: (.someChangesPending, "sync.delete"),
               removal: .begin)
  }

  func reportingPendingRemoval(explicit: Bool, previousFailure: SyncedContentSyncIssue?) -> Transition {
    guard mode == .iCloudSync else { return Transition() }
    switch state {
    case .deleting:
      return Transition()
    case .removalPending where explicit && previousFailure != .someChangesPending:
      return Transition(diagnostic: (.someChangesPending, "sync.delete"), removal: .failed(.someChangesPending))
    case .removalPending:
      return Transition()
    default:
      return beginningRemoval()
    }
  }

  func completingRemoval(matches: Bool) -> Transition {
    guard mode == .iCloudSync else { return Transition() }
    switch state {
    case .deleting:
      return Transition()
    case .removalPending where !matches:
      return Transition()
    default:
      return Transition(change: .state(.deleted))
    }
  }

  var detail: String {
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
      String(localized: "Some synced content is still in iCloud. This device keeps a recovery copy.", bundle: .main)
    case (_, .deleted):
      String(localized: "This device keeps a recovery copy.", bundle: .main)
    }
  }
}

/// Original operation context; only Core captures it, before starting its operation.
public struct SyncedContentSyncStart: Sendable {
  fileprivate enum Kind: Equatable, Sendable { case synchronization, retry, enable }
  fileprivate let status: SyncedContentStatus
  fileprivate let pendingRemoval: Int?
  fileprivate let removalID: Int
  fileprivate let statusSession: UUID
  fileprivate let kind: Kind
  fileprivate let explicitRemovalFailure: SyncedContentSyncIssue?

  fileprivate init(
    status: SyncedContentStatus, removalID: Int, statusSession: UUID, kind: Kind,
    explicitRemovalFailure: SyncedContentSyncIssue?
  ) {
    self.status = status
    pendingRemoval = status.state == .removalPending ? removalID : nil
    self.removalID = removalID
    self.statusSession = statusSession
    self.kind = kind
    self.explicitRemovalFailure = explicitRemovalFailure
  }
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

  private typealias Status = SyncedContentStatus

  private var status: Status
  public var mode: SyncedContentMode { status.mode }
  public var state: SyncedContentSettingsState { status.state }
  /// A sync stop starts a new session. A user operation started in an earlier session
  /// still finishes its work, but its late result can't replace the stop.
  @ObservationIgnored private var statusSession = UUID()
  /// Changes each time Settings enters `.removalPending`.
  @ObservationIgnored private var removalID = 0
  private var isPerformingExplicitSync = false
  private var explicitRemovalFailure: SyncedContentSyncIssue?
  private let enableAction: EnableAction?
  private let issueMapper: IssueMapper
  private let cancelEnableAction: CancelEnableAction?
  private let disableAction: DisableAction?
  private let deleteAction: DeleteAction?
  private let diagnostics: AppDiagnosticRecorder
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
    diagnostics: AppDiagnosticRecorder = AppDiagnosticRecorder.live
  ) {
    status = Status(mode: mode, state: initialState)
    self.issueMapper = issueMapper
    self.enableAction = enableAction
    self.cancelEnableAction = cancelEnableAction
    self.disableAction = disableAction
    self.deleteAction = deleteAction
    self.diagnostics = diagnostics
    switch initialState {
    case .failed(let issue): record(issue, operation: "sync.run")
    case .enabling(let issue?): record(issue, operation: "sync.setup")
    case .removalPending: enterRemovalPending()
    default: break
    }
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

  public var canEnableClipboardSync: Bool {
    guard mode == .iCloudSync else { return false }
    return switch state {
    case .ready, .syncing, .failed: true
    case .enabling, .disabling, .deleting, .removalPending, .deleted: false
    }
  }

  public var canSyncNow: Bool {
    guard mode == .iCloudSync, !isPerformingExplicitSync else { return false }
    return switch state {
    case .ready, .failed: true
    case .enabling, .syncing, .disabling, .deleting, .removalPending, .deleted: false
    }
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

  public var detail: String { status.detail }

  public var canRetryFailedSync: Bool {
    guard case .failed(let issue) = state else { return false }
    return issue.canRetry
  }

  /// Whether Settings offers Try Again for Delete Synced Content's incomplete removal.
  public var canFinishDeleting: Bool { mode == .iCloudSync && state == .removalPending }
  /// What kept the latest explicit sync from finishing Delete Synced Content's incomplete removal.
  public var finishDeletingIssue: SyncedContentSyncIssue? {
    canFinishDeleting ? explicitRemovalFailure : nil
  }

  public func enableICloudSync() async {
    _ = await performEnable()
  }

  public func enableICloudSyncWithOutcome() async -> SyncedContentActionOutcome {
    await performEnable()
  }

  private func performEnable() async -> SyncedContentActionOutcome {
    guard canEnable, let enableAction else { return .notRun(.unavailableAction) }
    let start = captureStart(kind: .enable)
    apply(status.startingEnable())
    let session = statusSession
    var originalValue: SyncedContentOriginalActionValue?
    var application: SyncedContentRequiredApplicationDisposition = .notRequired
    do {
      switch try await enableAction() {
      case .enabled:
        originalValue = .iCloudSyncEnabled
        if let completion = enableCompletionAction {
          do {
            try await completion()
            application = .applied
          } catch {
            application = .failed(error)
            throw error
          }
        }
        let original = SyncedContentOriginalActionResult(value: .success(.iCloudSyncEnabled),
                                                        requiredApplication: application)
        guard session == statusSession else {
          return .interrupted(.statusSessionChanged, originalIfKnown: original)
        }
        apply(status.completingEnable())
        return finishOriginal(start: start, original: original)
      case .settingUp(let issue):
        originalValue = .iCloudSyncSettingUp(issue)
        let original = SyncedContentOriginalActionResult(value: .success(.iCloudSyncSettingUp(issue)),
                                                        requiredApplication: .notRequired)
        guard session == statusSession else {
          return .interrupted(.statusSessionChanged, originalIfKnown: original)
        }
        apply(status.settingUp(issue, deduplicating: false))
        return finishOriginal(start: start, original: original)
      }
    } catch {
      diagnostics.record(.failure(
        operation: "sync.enable",
        error: error,
        visibility: .user
      ))
      let origin: Result<SyncedContentOriginalActionValue, any Error>
      if let originalValue { origin = .success(originalValue) } else { origin = .failure(error) }
      let original = SyncedContentOriginalActionResult(value: origin, requiredApplication: application)
      guard session == statusSession else {
        return .interrupted(.statusSessionChanged, originalIfKnown: original)
      }
      let issue = issueMapper(error)
      apply(status.failingEnable(issue))
      return finishOriginal(start: start, original: original, mappedIssue: issue)
    }
  }

  public func disableICloudSync(_ choice: SyncedContentDisableChoice) async {
    guard canDisable, let disableAction else { return }
    status.state = .disabling
    let session = statusSession
    do {
      try await disableAction(choice)
      try await disableCompletionAction?()
      guard session == statusSession else { return }
      status = Status(mode: .localOnly, state: .ready)
    } catch {
      diagnostics.record(.failure(
        operation: "sync.disable",
        error: error,
        visibility: .user
      ))
      guard session == statusSession else { return }
      status.state = .failed(issueMapper(error))
    }
  }

  public func cancelICloudSyncSetup() async {
    guard canCancelEnable, let cancelEnableAction else { return }
    let session = statusSession
    do {
      try await cancelEnableAction()
      guard session == statusSession else { return }
      status = Status(mode: .localOnly, state: .ready)
    } catch {
      diagnostics.record(.failure(
        operation: "sync.cancel_setup",
        error: error,
        visibility: .user
      ))
      guard session == statusSession else { return }
      status.state = .failed(issueMapper(error))
    }
  }

  /// Records that a sync request reported Delete Synced Content's removal incomplete. A
  /// running delete reports its own outcome. Only an explicit sync records a removal that
  /// stays incomplete, so automatic syncs can't flood diagnostics.
  public func recordRemovalPending() {
    apply(status.reportingPendingRemoval(explicit: isPerformingExplicitSync,
                                         previousFailure: explicitRemovalFailure))
  }

  /// Records that a sync request reported Delete Synced Content's removal finished. It
  /// finishes the removal `start` saw, or one Settings didn't know about. A running delete
  /// reports its own outcome.
  public func recordRemovalCompleted(_ start: SyncedContentSyncStart) {
    apply(status.completingRemoval(matches: start.pendingRemoval == removalID))
  }

  /// Shares admission across user retry controls without clearing an outstanding issue.
  public func performExplicitSync(_ action: @MainActor () async -> Void) async {
    _ = await withExplicitSync { _ in await action() }
  }

  public func performExplicitSyncWithOutcome(
    _ action: @MainActor (SyncedContentSyncStart) async throws -> SyncedContentOriginalActionReturn
  ) async throws -> SyncedContentActionOutcome {
    try Task.checkCancellation()
    let outcome: SyncedContentActionOutcome? = try await withExplicitSync { start in
      apply(status.startingSync())
      let returned = try await action(start)
      try Task.checkCancellation()
      switch returned {
      case .finished(let value, let application):
        return finishOriginal(start: start, original: SyncedContentOriginalActionResult(
          value: .success(value), requiredApplication: application))
      case .interrupted(let reason, let original):
        return .interrupted(reason, originalIfKnown: original)
      }
    }
    return outcome ?? .notRun(.overlappingExplicitAction)
  }

  private func withExplicitSync<Value>(
    _ action: @MainActor (SyncedContentSyncStart) async throws -> Value
  ) async rethrows -> Value? {
    guard !isPerformingExplicitSync else { return nil }
    let start = captureStart(kind: .retry)
    isPerformingExplicitSync = true
    defer { isPerformingExplicitSync = false }
    explicitRemovalFailure = nil
    return try await action(start)
  }

  private func captureStart(kind: SyncedContentSyncStart.Kind) -> SyncedContentSyncStart {
    SyncedContentSyncStart(status: status, removalID: removalID, statusSession: statusSession,
                          kind: kind, explicitRemovalFailure: explicitRemovalFailure)
  }

  public func recordSyncStarted() -> SyncedContentSyncStart {
    let start = captureStart(kind: .synchronization)
    apply(status.startingSync())
    return start
  }

  /// Records that a normal sync request finished and didn't report a pending removal.
  /// Request results report an incomplete Delete Synced Content as pending, so this also
  /// finishes the removal `start` saw, even if its report was lost. Automatic sync engine
  /// results don't carry removal progress.
  public func recordSyncCompleted(_ start: SyncedContentSyncStart) {
    apply(status.completingSync(removalMatches: start.pendingRemoval == removalID))
  }

  /// Records that the sync engine reports no work or failures remain.
  public func recordOutstandingSyncRecovered() {
    apply(status.recoveringSync())
  }

  public func recordSyncFailure(_ issue: SyncedContentSyncIssue) {
    apply(status.failingSync(issue, explicit: isPerformingExplicitSync,
                             previousRemovalFailure: explicitRemovalFailure))
  }

  public func recordSyncStopped(_ issue: SyncedContentSyncIssue) {
    statusSession = UUID()
    apply(status.stoppingSync(issue))
  }

  public func recordEnableSettingUp(_ issue: SyncedContentSyncIssue? = nil) {
    apply(status.settingUp(issue, deduplicating: true))
  }

  public func recordEnableCompleted() {
    apply(status.completingEnable())
  }

  public func deleteSyncedContent() async {
    guard canDelete, let deleteAction else { return }
    status.state = .deleting
    let session = statusSession
    do {
      let outcome = try await deleteAction()
      try await deleteCompletionAction?()
      guard session == statusSession else { return }
      if outcome == .completed {
        status.state = .deleted
      } else {
        enterRemovalPending()
      }
    } catch {
      diagnostics.record(.failure(
        operation: "sync.delete",
        error: error,
        visibility: .user
      ))
      guard session == statusSession else { return }
      status.state = .failed(issueMapper(error))
    }
  }

  private func enterRemovalPending() {
    apply(status.beginningRemoval())
  }

  private func apply(_ transition: Status.Transition) {
    if case .begin = transition.removal {
      removalID += 1
      explicitRemovalFailure = nil
    }
    if let diagnostic = transition.diagnostic {
      record(diagnostic.issue, operation: diagnostic.operation)
    }
    if case .failed(let issue) = transition.removal { explicitRemovalFailure = issue }
    transition.change?.apply(to: &status)
  }

  private func finishOriginal(
    start: SyncedContentSyncStart, original: SyncedContentOriginalActionResult,
    mappedIssue: SyncedContentSyncIssue? = nil
  ) -> SyncedContentActionOutcome {
    if Task.isCancelled {
      return .interrupted(.cancelled, originalIfKnown: original)
    }
    guard start.statusSession == statusSession else {
      return .interrupted(.statusSessionChanged, originalIfKnown: original)
    }
    let failure: (any Error)?
    switch original.requiredApplication {
    case .interrupted(let reason), .unavailable(let reason):
      return .interrupted(reason, originalIfKnown: original)
    case .failed(let error): failure = error
    case .notRequired, .applied:
      if case .failure(let error) = original.value { failure = error } else { failure = nil }
    }
    if let failure, failure is CancellationError {
      return .interrupted(.cancelled, originalIfKnown: original)
    }
    let issue = mappedIssue ?? failure.map(issueMapper)
    return .completed(Self.originalReport(start: start, original: original, mappedIssue: issue))
  }

  private static func originalReport(
    start: SyncedContentSyncStart, original: SyncedContentOriginalActionResult,
    mappedIssue: SyncedContentSyncIssue?
  ) -> OriginalSyncActionReport {
    var projected = start.status
    var projectedRemovalID = start.removalID
    var removalFailure = start.explicitRemovalFailure
    func advance(_ transition: Status.Transition) {
      if case .begin = transition.removal {
        projectedRemovalID += 1
        removalFailure = nil
      }
      if case .failed(let issue) = transition.removal { removalFailure = issue }
      transition.change?.apply(to: &projected)
    }
    switch start.kind {
    case .retry:
      removalFailure = nil
      advance(projected.startingSync())
    case .synchronization:
      advance(projected.startingSync())
    case .enable:
      advance(projected.startingEnable())
    }

    var failed = false
    if let mappedIssue {
      failed = true
      if start.kind == .enable {
        advance(projected.failingEnable(mappedIssue))
      } else {
        advance(projected.failingSync(mappedIssue, explicit: true, previousRemovalFailure: removalFailure))
      }
      // A reset's stop remains authoritative when its required replacement fails.
      if case .success(let value) = original.value, let stopIssue = value.stopIssue {
        advance(projected.stoppingSync(stopIssue))
      }
    } else if case .success(let value) = original.value {
      switch value {
      case .noChange, .contentUpdated, .syncScheduled, .libraryReplaced, .libraryReplacedAndSyncScheduled:
        break
      case .syncCompleted, .libraryReplacedAndSyncCompleted:
        advance(projected.recoveringSync())
      case .libraryReplacedWithSyncIssue(let issue), .syncIssue(let issue):
        advance(projected.failingSync(issue, explicit: true, previousRemovalFailure: removalFailure))
      case .iCloudDataReset, .iCloudSignedOut, .iCloudAccountChanged:
        if let issue = value.stopIssue { advance(projected.stoppingSync(issue)) }
      case .iCloudSyncSettingUp(let issue):
        advance(projected.settingUp(issue, deduplicating: true))
      case .iCloudSyncEnabled:
        advance(projected.completingEnable())
      case .oldSyncedContentRemovalPending:
        advance(projected.reportingPendingRemoval(explicit: true, previousFailure: removalFailure))
        failed = true
      case .oldSyncedContentRemovalCompleted:
        advance(projected.completingRemoval(matches: start.pendingRemoval == projectedRemovalID))
      }
      switch value {
      case .libraryReplacedWithSyncIssue, .syncIssue, .oldSyncedContentRemovalPending:
        break
      default:
        if start.kind != .enable {
          advance(projected.completingSync(removalMatches: start.pendingRemoval == projectedRemovalID))
        }
      }
    }
    if case .failed = projected.state { failed = true }
    if projected.mode == .iCloudSync, projected.state == .removalPending, removalFailure != nil {
      failed = true
    }
    return OriginalSyncActionReport(origin: original.value, requiredApplication: original.requiredApplication,
      operation: SyncedContentOperationReceiptProjection(status: failed ? .failed : .succeeded,
                                                        message: projected.detail))
  }

  private func record(_ issue: SyncedContentSyncIssue, operation: StaticString) {
    diagnostics.record(.failure(
      operation: operation,
      errorCode: issue.diagnosticCode,
      visibility: .user
    ))
  }
}

private extension SyncedContentOriginalActionValue {
  var stopIssue: SyncedContentSyncIssue? {
    switch self {
    case .iCloudDataReset: .iCloudDataReset
    case .iCloudSignedOut: .signInRequired
    case .iCloudAccountChanged: .iCloudAccountChanged
    default: nil
    }
  }
}
