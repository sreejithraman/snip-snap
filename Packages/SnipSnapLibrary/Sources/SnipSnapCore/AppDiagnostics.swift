import Foundation
import OSLog

enum AppDiagnosticCodePolicy {
  static let unknownError = "other.UnknownError"

  static let operations: Set<String> = [
    "app.startup", "app.user_action", "app.unknown",
    "attachment.asset_copy", "attachment.cache_clear", "attachment.cache_install",
    "attachment.cloudkit_asset_url", "attachment.cloudkit_record", "attachment.cloudkit_request",
    "attachment.import_select", "attachment.import_stage", "attachment.prepare",
    "attachment.receipt_validation", "attachment.remote_fetch",
    "backup.export", "backup.import_select", "backup.import_preview", "backup.import_apply",
    "clipboard.account_reset", "clipboard.clear", "clipboard.copy_file", "clipboard.delete",
    "clipboard.delete_synced", "clipboard.export", "clipboard.load", "clipboard.paste",
    "clipboard.persist",
    "clipboard.paste_read", "clipboard.pin", "clipboard.share_import", "clipboard.sync",
    "clipboard.write", "composer.paste_stage",
    "cloudkit.clipboard_delete", "cloudkit.clipboard_fetch", "cloudkit.clipboard_save",
    "cloudkit.control_create_zones", "cloudkit.control_delete_zones", "cloudkit.control_fetch",
    "cloudkit.control_save", "cloudkit.record_fetch", "cloudkit.record_send", "cloudkit.request",
    "diagnostics.clear", "diagnostics.export", "diagnostics.recording", "import.file",
    "share.import", "shortcut.save", "shortcut.register", "capture.screen", "selection.capture",
    "snip.paste_read", "snip.paste_save",
    "sync.account_refresh", "sync.account_resolve", "sync.account_status",
    "sync.cancel_setup", "sync.delete", "sync.disable", "sync.enable", "sync.run",
    "sync.setup", "sync.stop", "sync.snapshot", "sync.provider", "sync.fetch", "sync.send",
    "sync.settlement", "sync.schedule", "sync.reset",
  ]

  static let errorCodes: Set<String> = [
    "diagnostics.busy", "diagnostics.routineOverflow", "diagnostics.failureOverflow",
    "diagnostics.writeFailed",
    "clipboard.empty", "clipboard.tooLarge", "clipboard.unreadable", "clipboard.unsupported",
    "import.partialFailure", "import.readFailed", "pasteboard.writeFailed",
    "presentation.message", "presentation.startup", "attachment.unavailableAfterPrepare",
    "selection.sourceUnavailable", "selection.selectionUnavailable",
    "selection.clipboardUnavailable",
    "selection.clipboardSnapshotTimedOut", "selection.clipboardChanged",
    "selection.clipboardRestoreFailed",
    "selection.sourceChanged", "selection.attachmentStagingFailed",
    "shortcut.eventHandlerFailed", "shortcut.registrationFailed", "snip.emptyClipboard",
    "library.emptyContent", "library.snipNotFound", "library.invalidStore",
    "library.storeUnavailable", "library.requiresMultipleSnips", "library.snipChanged",
    "library.duplicateList", "library.invalidList", "library.invalidCommand",
    "library.attachmentCopyFailed", "library.modeTransitionInProgress",
    "library.readOnlyRecovery", "library.transferUnsupported", "library.transferConflict",
    "library.recoveryNotFound", "library.recoveryChanged", "library.invalidRecoveryChoice",
    "library.importChanged", "library.deviceActionChanged",
    "storage.invalidPath", "storage.invalidRelativePath", "storage.pathOutsideRoot",
    "storage.symbolicLinkRoot", "storage.symbolicLinkDescendant", "storage.invalidMetadata",
    "storage.staleTransition", "storage.missingPublication", "storage.hashMismatch",
    "storage.sizeMismatch", "storage.missingPayload",
    "record.invalidShadow", "record.mismatchedShadow", "record.unsupportedValue",
    "record.missingField", "record.invalidField", "record.projectedSnapshot",
    "record.wrongRecordType", "record.invalidAssetDestination", "record.missingAsset",
    "transport.stateNamespaceMismatch", "transport.invalidEngineState", "transport.invalidRecord",
    "transport.fetchFailed", "transport.sendFailed", "transport.wrongBatchConfirmation",
    "transport.notStarted", "transport.syncAlreadyRunning",
    "sync.waitingForConnection", "sync.iCloudUnavailable", "sync.retryingSoon",
    "sync.checkingAccount", "sync.signInRequired", "sync.accountRestricted",
    "sync.accountTemporarilyUnavailable", "sync.iCloudStorageFull", "sync.updateRequired",
    "sync.accessDenied", "sync.someChangesPending", "sync.attachmentMissing",
    "sync.attachmentUnavailable", "sync.attachmentStorageUnavailable", "sync.setupBlocked",
    "sync.iCloudDataReset", "sync.iCloudAccountChanged", "sync.appDataIssue",
  ]

  static func operation(_ raw: String) -> String {
    operations.contains(raw) ? raw : "app.unknown"
  }

  static func errorCode(_ raw: String) -> String {
    if errorCodes.contains(raw) { return raw }
    let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 2, ["cloudkit", "cocoa", "url", "posix"].contains(parts[0]),
      let number = Int(parts[1]), String(number) == String(parts[1])
    {
      return raw
    }
    return unknownError
  }
}

/// Supplies a stable, privacy-safe code without exposing an error description.
public protocol AppDiagnosticErrorCodeProviding: Error {
  var appDiagnosticCode: String { get }
}

public enum AppDiagnosticVisibility: String, Sendable {
  case user
  case background
}

public enum AppDiagnosticOutcome: String, Sendable {
  case started
  case succeeded
  case failed
  case cancelled
  case missing
}

public enum AppDiagnosticSyncScope: String, Sendable {
  case transport
  case records
}

public enum AppDiagnosticSyncEnvironment: String, Sendable {
  case development
  case production
  case unknown
}

public enum AppDiagnosticSyncPhase: String, Sendable {
  case uninitialized
  case remoteChecked = "remote_checked"
  case remoteCheckedMissingZone = "remote_checked_missing_zone"
  case seeding
  case active
  case blocked
}

public enum AppDiagnosticSyncReason: String, Sendable {
  case initialFetch = "initial_fetch"
  case uncommittedEvents = "uncommitted_events"
  case namespaceBlocked = "namespace_blocked"
  case recoveryBlocked = "recovery_blocked"
  case recordBlocked = "record_blocked"
  case pendingWork = "pending_work"
  case settled
  case stopped
  case ownerReplaced = "owner_replaced"
}

/// One structured operational event. Fields are deliberately limited to values that cannot
/// contain user content, filenames, filesystem paths, record identifiers, or hashes.
public struct AppDiagnosticEvent: Equatable, Sendable {
  public let operation: String
  public let outcome: AppDiagnosticOutcome
  public let visibility: AppDiagnosticVisibility
  public let errorCode: String?
  public let byteCount: Int64?
  public let retryAfterSeconds: Double?
  public let nextAttemptSeconds: Double?
  public let syncScope: AppDiagnosticSyncScope?
  public let syncEnvironment: AppDiagnosticSyncEnvironment?
  public let syncPhase: AppDiagnosticSyncPhase?
  public let syncReason: AppDiagnosticSyncReason?
  public let pendingUploads: Int?
  public let pendingDownloads: Int?
  public let pendingEvents: Int?
  public let blockedRecords: Int?

  private init(
    operation: StaticString,
    outcome: AppDiagnosticOutcome,
    visibility: AppDiagnosticVisibility,
    errorCode: String? = nil,
    byteCount: Int64? = nil,
    retryAfterSeconds: Double? = nil,
    nextAttemptSeconds: Double? = nil,
    syncScope: AppDiagnosticSyncScope? = nil,
    syncEnvironment: AppDiagnosticSyncEnvironment? = nil,
    syncPhase: AppDiagnosticSyncPhase? = nil,
    syncReason: AppDiagnosticSyncReason? = nil,
    pendingUploads: Int? = nil,
    pendingDownloads: Int? = nil,
    pendingEvents: Int? = nil,
    blockedRecords: Int? = nil
  ) {
    self.operation = AppDiagnosticCodePolicy.operation(String(describing: operation))
    self.outcome = outcome
    self.visibility = visibility
    self.errorCode = errorCode.map(AppDiagnosticCodePolicy.errorCode)
    self.byteCount = byteCount
    self.retryAfterSeconds = retryAfterSeconds
    self.nextAttemptSeconds = nextAttemptSeconds
    self.syncScope = syncScope
    self.syncEnvironment = syncEnvironment
    self.syncPhase = syncPhase
    self.syncReason = syncReason
    self.pendingUploads = pendingUploads.flatMap { $0 >= 0 ? $0 : nil }
    self.pendingDownloads = pendingDownloads.flatMap { $0 >= 0 ? $0 : nil }
    self.pendingEvents = pendingEvents.flatMap { $0 >= 0 ? $0 : nil }
    self.blockedRecords = blockedRecords.flatMap { $0 >= 0 ? $0 : nil }
  }

  public static func started(
    operation: StaticString,
    visibility: AppDiagnosticVisibility = .background,
    reason: AppDiagnosticSyncReason? = nil
  ) -> Self {
    Self(operation: operation, outcome: .started, visibility: visibility, syncReason: reason)
  }

  public static func succeeded(
    operation: StaticString,
    visibility: AppDiagnosticVisibility = .background,
    byteCount: Int64? = nil,
    reason: AppDiagnosticSyncReason? = nil
  ) -> Self {
    Self(
      operation: operation,
      outcome: .succeeded,
      visibility: visibility,
      byteCount: byteCount,
      syncReason: reason
    )
  }

  /// Captures one owner's observed work. Missing or negative counts remain unknown;
  /// transport and record observations describe separate scopes and must not be added.
  public static func syncSnapshot(
    scope: AppDiagnosticSyncScope,
    environment: AppDiagnosticSyncEnvironment? = nil,
    phase: AppDiagnosticSyncPhase? = nil,
    reason: AppDiagnosticSyncReason? = nil,
    pendingUploads: Int? = nil,
    pendingDownloads: Int? = nil,
    pendingEvents: Int? = nil,
    blockedRecords: Int? = nil
  ) -> Self {
    Self(
      operation: "sync.snapshot",
      outcome: .succeeded,
      visibility: .background,
      syncScope: scope,
      syncEnvironment: environment,
      syncPhase: phase,
      syncReason: reason,
      pendingUploads: pendingUploads,
      pendingDownloads: pendingDownloads,
      pendingEvents: pendingEvents,
      blockedRecords: blockedRecords
    )
  }

  public static func missing(
    operation: StaticString,
    visibility: AppDiagnosticVisibility = .background
  ) -> Self {
    Self(operation: operation, outcome: .missing, visibility: visibility)
  }

  public static func failure(
    operation: StaticString,
    error: any Error,
    visibility: AppDiagnosticVisibility
  ) -> Self {
    Self(
      operation: operation,
      outcome: .failed,
      visibility: visibility,
      errorCode: diagnosticErrorCode(error)
    )
  }

  public static func failure(
    operation: StaticString,
    errorCode: String,
    visibility: AppDiagnosticVisibility,
    retryAfterSeconds: Double? = nil,
    nextAttemptSeconds: Double? = nil
  ) -> Self {
    Self(
      operation: operation,
      outcome: .failed,
      visibility: visibility,
      errorCode: errorCode,
      retryAfterSeconds: retryAfterSeconds,
      nextAttemptSeconds: nextAttemptSeconds
    )
  }

  public var line: String {
    var fields = [
      "diagnostic_event",
      "operation=\(operation)",
      "outcome=\(outcome.rawValue)",
      "visibility=\(visibility.rawValue)",
    ]
    if let errorCode { fields.append("error=\(errorCode)") }
    if let byteCount { fields.append("bytes=\(byteCount)") }
    if let retryAfterSeconds { fields.append("retry_after=\(retryAfterSeconds)") }
    if let nextAttemptSeconds { fields.append("next_attempt=\(nextAttemptSeconds)") }
    if let syncScope { fields.append("scope=\(syncScope.rawValue)") }
    if let syncEnvironment { fields.append("environment=\(syncEnvironment.rawValue)") }
    if let syncPhase { fields.append("phase=\(syncPhase.rawValue)") }
    if let syncReason { fields.append("reason=\(syncReason.rawValue)") }
    if let pendingUploads { fields.append("pending_uploads=\(pendingUploads)") }
    if let pendingDownloads { fields.append("pending_downloads=\(pendingDownloads)") }
    if let pendingEvents { fields.append("pending_events=\(pendingEvents)") }
    if let blockedRecords { fields.append("blocked_records=\(blockedRecords)") }
    return fields.joined(separator: " ")
  }

}

public struct AppDiagnosticRecorder: Sendable {
  private let recordEvent: @Sendable (AppDiagnosticEvent) -> Void

  public init(record: @escaping @Sendable (AppDiagnosticEvent) -> Void) {
    recordEvent = record
  }

  public func record(_ event: AppDiagnosticEvent) {
    recordEvent(event)
  }

  public static let live = AppDiagnosticRecorder { event in
    AppDiagnosticLiveSink.shared.record(event)
  }
}

/// Describes the default rendered report. Its revision covers all history, health, and recording state.
public struct AppDiagnosticExportSnapshot: Equatable, Sendable {
  public let byteCount: Int
  public let revision: String
}

/// Creates and clears the bounded, privacy-safe diagnostic file shared from app settings.
public struct AppDiagnosticLogReport: Sendable {
  public let text: String
  public let returnedEvents: Int
  public let truncated: Bool
}

/// A bounded local diagnostic operation could not acquire its storage lock.
public enum AppDiagnosticAccessError: Error, LocalizedError, Sendable,
  AppDiagnosticErrorCodeProviding
{
  case busy

  public var appDiagnosticCode: String { "diagnostics.busy" }

  public var errorDescription: String? {
    String(localized: "Diagnostic history is busy. Try again shortly.")
  }
}

public enum AppDiagnosticExportRange: String, CaseIterable, Codable, Sendable {
  case last24Hours
  case last7Days
}

public enum AppDiagnosticsExport {
  public static func readLog(
    range: AppDiagnosticExportRange = .last24Hours, limit: Int = 200, errorsOnly: Bool = false
  ) throws -> AppDiagnosticLogReport {
    try AppDiagnosticLiveSink.shared.readLog(range: range, limit: limit, errorsOnly: errorsOnly)
  }

  /// Reads a target bundle's local history without starting the app or using its live sink.
  public static func readLog(
    bundleIdentifier: String, appVersion: String, appBuild: String,
    range: AppDiagnosticExportRange = .last24Hours, limit: Int = 200, errorsOnly: Bool = false
  ) throws -> AppDiagnosticLogReport {
    try AppDiagnosticEventStore.forBundle(
      bundleIdentifier: bundleIdentifier, appVersion: appVersion, appBuild: appBuild
    ).readLog(range: range, limit: limit, errorsOnly: errorsOnly)
  }

  /// Reads the preference without treating unavailable storage as recording off.
  public static func readRecordingEnabled() throws -> Bool {
    try AppDiagnosticLiveSink.shared.readRecordingEnabled()
  }

  public static func setRecordingEnabled(_ enabled: Bool) throws {
    try AppDiagnosticLiveSink.shared.setRecordingEnabled(enabled)
  }

  public static func setRecordingEnabled(_ enabled: Bool, ifRevision revision: String) throws
    -> Bool
  {
    try AppDiagnosticLiveSink.shared.setRecordingEnabled(enabled, ifRevision: revision)
  }

  public static func makeShareableFile(range: AppDiagnosticExportRange = .last24Hours) throws -> URL
  {
    try AppDiagnosticLiveSink.shared.makeShareableFile(range: range)
  }

  /// Removes an owned staging file and its directory. User-saved copies are left alone.
  public static func removeShareableFile(_ fileURL: URL) {
    AppDiagnosticEventStore.removeOwnedShareableFile(fileURL)
  }

  public static func clear() throws {
    try AppDiagnosticLiveSink.shared.clear()
  }

  public static func snapshot() throws -> AppDiagnosticExportSnapshot {
    try AppDiagnosticLiveSink.shared.snapshot()
  }

  /// Returns false without clearing when history, health, app context, or recording state has changed.
  public static func clear(ifRevision revision: String) throws -> Bool {
    try AppDiagnosticLiveSink.shared.clear(ifRevision: revision)
  }
}

public func diagnosticErrorCode(_ error: any Error) -> String {
  if let error = error as? any AppDiagnosticErrorCodeProviding {
    return error.appDiagnosticCode
  }
  if let error = error as? CocoaError {
    return "cocoa.\(error.errorCode)"
  }
  if let error = error as? URLError {
    return "url.\(error.errorCode)"
  }
  let nsError = error as NSError
  if nsError.domain == NSPOSIXErrorDomain {
    return "posix.\(nsError.code)"
  }
  let reflected = String(reflecting: type(of: error))
  let typeName = reflected.split(separator: ".").last.map(String.init) ?? "UnknownError"
  let safeType = typeName.filter { $0.isLetter || $0.isNumber || $0 == "_" }
  return "other.\(safeType.isEmpty ? "UnknownError" : safeType)"
}

extension SnipLibraryError: AppDiagnosticErrorCodeProviding {
  public var appDiagnosticCode: String {
    switch self {
    case .emptyContent: "library.emptyContent"
    case .snipNotFound: "library.snipNotFound"
    case .invalidStore: "library.invalidStore"
    case .storeUnavailable: "library.storeUnavailable"
    case .requiresMultipleSnips: "library.requiresMultipleSnips"
    case .snipChanged: "library.snipChanged"
    case .duplicateList: "library.duplicateList"
    case .invalidList: "library.invalidList"
    case .invalidCommand: "library.invalidCommand"
    case .attachmentCopyFailed: "library.attachmentCopyFailed"
    case .modeTransitionInProgress: "library.modeTransitionInProgress"
    case .readOnlyRecovery: "library.readOnlyRecovery"
    case .transferUnsupported: "library.transferUnsupported"
    case .transferConflict: "library.transferConflict"
    case .recoveryNotFound: "library.recoveryNotFound"
    case .recoveryChanged: "library.recoveryChanged"
    case .invalidRecoveryChoice: "library.invalidRecoveryChoice"
    case .importChanged: "library.importChanged"
    case .deviceActionChanged: "library.deviceActionChanged"
    }
  }
}

private final class AppDiagnosticLiveSink: @unchecked Sendable {
  static let shared = AppDiagnosticLiveSink()

  private let logger = Logger(subsystem: "SnipSnap", category: "Operations")
  private let store = AppDiagnosticEventStore.forBundle(
    bundleIdentifier: Bundle.main.bundleIdentifier,
    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown",
    appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
  )

  private let writer: AppDiagnosticWriter

  private init() { writer = AppDiagnosticWriter(store: store) }

  func record(_ event: AppDiagnosticEvent) {
    let submittedAt = Date()
    switch event.outcome {
    case .failed:
      logger.error("\(event.line, privacy: .public)")
    case .cancelled, .missing:
      logger.notice("\(event.line, privacy: .public)")
    case .started, .succeeded:
      logger.info("\(event.line, privacy: .public)")
    }
    writer.submit(event, at: submittedAt)
  }

  func readLog(range: AppDiagnosticExportRange, limit: Int, errorsOnly: Bool) throws
    -> AppDiagnosticLogReport
  {
    try writer.perform { try store.readLog(range: range, limit: limit, errorsOnly: errorsOnly) }
  }

  func readRecordingEnabled() throws -> Bool {
    try writer.perform { try store.readRecordingEnabled() }
  }

  func setRecordingEnabled(_ enabled: Bool) throws {
    try writer.perform { try store.setRecordingEnabled(enabled) }
  }

  func setRecordingEnabled(_ enabled: Bool, ifRevision revision: String) throws -> Bool {
    try writer.perform { try store.setRecordingEnabled(enabled, ifRevision: revision) }
  }

  func makeShareableFile(range: AppDiagnosticExportRange) throws -> URL {
    try writer.perform { try store.makeShareableFile(range: range) }
  }

  func clear() throws {
    try writer.perform { try store.clear() }
  }

  func snapshot() throws -> AppDiagnosticExportSnapshot {
    try writer.perform { try store.snapshot() }
  }

  func clear(ifRevision revision: String) throws -> Bool {
    try writer.perform { try store.clear(ifRevision: revision) }
  }
}
