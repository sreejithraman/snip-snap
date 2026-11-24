import Foundation
import OSLog

enum AppDiagnosticCodePolicy {
  static let unknownError = "other.UnknownError"

  static let operations: Set<String> = [
    "app.startup", "app.user_action", "app.unknown",
    "cli.readiness", "cli.scope_suspend", "cli.session_end",
    "attachment.asset_copy", "attachment.cache_install",
    "attachment.cloudkit_asset_url", "attachment.cloudkit_record", "attachment.cloudkit_request",
    "attachment.import_select", "attachment.import_stage", "attachment.prepare",
    "attachment.receipt_validation", "attachment.remote_fetch",
    "backup.export", "backup.import_select", "backup.import_preview", "backup.import_apply",
    "clipboard.account_reset", "clipboard.clear", "clipboard.copy_file", "clipboard.delete",
    "clipboard.export", "clipboard.load", "clipboard.paste",
    "clipboard.persist",
    "clipboard.paste_read", "clipboard.pin", "clipboard.share_import", "clipboard.sync",
    "clipboard.write", "composer.paste_stage",
    "cloudkit.clipboard_delete", "cloudkit.clipboard_fetch", "cloudkit.clipboard_save",
    "cloudkit.control_create_zones", "cloudkit.control_delete_zones", "cloudkit.control_fetch",
    "cloudkit.control_save", "cloudkit.record_fetch", "cloudkit.record_send", "cloudkit.request",
    "diagnostics.clear", "diagnostics.export", "diagnostics.recording", "import.file",
    "share.import", "share.extension_startup", "share.extension_load", "share.extension_save",
    "share.import_read", "share.import_apply", "share.import_cleanup", "share.import_library",
    "share.catalog_publish", "share.catalog_read", "shortcut.save", "shortcut.register",
    "capture.screen", "selection.capture",
    "snip.paste_read", "snip.paste_save", "snip.add", "snip.update", "snip.edit_attachments",
    "snip.delete", "snip.restore", "snip.merge", "snip.pin", "snip.completion", "snip.move",
    "snip.completion_after_copy", "snip.undo_done",
    "snip.replace_all", "snip.undo_delete", "list.create", "list.restore", "list.update",
    "list.delete", "list.move", "library.batch", "attachment.prune",
    "recovery.resolve", "library.write_admission", "library.relocate",
    "sync.account_refresh", "sync.account_resolve", "sync.account_status",
    "sync.cancel_setup", "sync.delete", "sync.disable", "sync.enable", "sync.run",
    "sync.setup", "sync.stop", "sync.snapshot", "sync.provider", "sync.fetch", "sync.send",
    "sync.settlement", "sync.reset",
  ]

  static let errorCodes: Set<String> = [
    "share.sharedContainerUnavailable",
    "cli.unavailable",
    "clipboard.empty", "clipboard.tooLarge", "clipboard.unreadable", "clipboard.unsupported",
    "import.partialFailure", "import.readFailed", "pasteboard.writeFailed",
    "presentation.message", "presentation.startup", "attachment.unavailableAfterPrepare",
    "undo.unavailable",
    "selection.sourceUnavailable", "selection.selectionUnavailable",
    "selection.clipboardUnavailable",
    "selection.clipboardSnapshotTimedOut", "selection.clipboardChanged",
    "selection.clipboardRestoreFailed",
    "selection.sourceChanged", "selection.attachmentStagingFailed",
    "shortcut.eventHandlerFailed", "shortcut.registrationFailed", "snip.emptyClipboard",
    "snip.clipboardUnreadable",
    "library.emptyContent", "library.snipNotFound", "library.invalidStore",
    "library.storeUnavailable", "library.requiresMultipleSnips", "library.snipChanged",
    "library.duplicateList", "library.invalidList", "library.invalidCommand",
    "library.attachmentCopyFailed", "library.modeTransitionInProgress",
    "library.readOnlyRecovery", "library.transferUnsupported", "library.transferConflict",
    "library.recoveryNotFound", "library.recoveryChanged", "library.invalidRecoveryChoice",
    "library.importChanged",
    "library.relocationConflict",
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

public enum AppDiagnosticVisibility: String, Codable, Sendable {
  case user
  case background
}

public enum AppDiagnosticOutcome: String, Codable, Sendable {
  case started
  case succeeded
  case failed
  case cancelled
  case missing
}

public enum AppDiagnosticSyncScope: String, Codable, Sendable {
  case transport
  case records
}

public enum AppDiagnosticSyncEnvironment: String, Codable, Sendable {
  case development
  case production
  case unknown
}

public enum AppDiagnosticSyncPhase: String, Codable, Sendable {
  case uninitialized
  case remoteChecked = "remote_checked"
  case remoteCheckedMissingZone = "remote_checked_missing_zone"
  case seeding
  case active
  case blocked
}

public enum AppDiagnosticSyncReason: String, Codable, Sendable {
  case initialFetch = "initial_fetch"
  case uncommittedEvents = "uncommitted_events"
  case namespaceBlocked = "namespace_blocked"
  case recoveryBlocked = "recovery_blocked"
  case recordBlocked = "record_blocked"
  case pendingWork = "pending_work"
  case settled
  case stopped
}

public enum AppDiagnosticWriteReason: String, Codable, Sendable {
  case syncBusy = "sync_busy"
  case writeBusy = "write_busy"
  case modeChange = "mode_change"
  case dataReset = "data_reset"
  case reservedWrite = "reserved_write"
}

/// One structured operational event. Fields are deliberately limited to values that cannot
/// contain user content, filenames, filesystem paths, record identifiers, or hashes.
public struct AppDiagnosticEvent: Codable, Equatable, Sendable {
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
  public let writeReason: AppDiagnosticWriteReason?

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
    blockedRecords: Int? = nil,
    writeReason: AppDiagnosticWriteReason? = nil
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
    self.writeReason = writeReason
  }

  public static func writeAdmission(
    _ outcome: AppDiagnosticOutcome, reason: AppDiagnosticWriteReason
  ) -> Self {
    Self(operation: "library.write_admission", outcome: outcome, visibility: .background,
      errorCode: outcome == .failed ? "library.modeTransitionInProgress" : nil,
      writeReason: reason)
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
      "operation=\(AppDiagnosticCodePolicy.operation(operation))",
      "outcome=\(outcome.rawValue)",
      "visibility=\(visibility.rawValue)",
    ]
    if let errorCode { fields.append("error=\(AppDiagnosticCodePolicy.errorCode(errorCode))") }
    if let writeReason { fields.append("write_reason=\(writeReason.rawValue)") }
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
  private let flushEvents: @Sendable (TimeInterval) async -> Bool

  public init(record: @escaping @Sendable (AppDiagnosticEvent) -> Void) {
    recordEvent = record
    flushEvents = { _ in true }
  }

  init(
    record: @escaping @Sendable (AppDiagnosticEvent) -> Void,
    flush: @escaping @Sendable (TimeInterval) async -> Bool
  ) {
    recordEvent = record
    flushEvents = flush
  }

  /// Waits for queued recording attempts, up to the supplied timeout (at most two seconds).
  public func flush(timeout: TimeInterval = 0.5) async -> Bool {
    guard !Task.isCancelled else { return false }
    return await flushEvents(timeout)
  }

  public func record(_ event: AppDiagnosticEvent) {
    recordEvent(event)
  }

  public static var live: AppDiagnosticRecorder { AppDiagnosticScope.live.recorder }
}

public struct AppDiagnosticLogReport: Sendable {
  public let text: String
  public let returnedEvents: Int
  public let truncated: Bool
  public let recordingEnabled: Bool

  public var recordingRevision: String { Self.recordingRevision(enabled: recordingEnabled) }

  static func recordingRevision(enabled: Bool) -> String {
    SnipCLIApplicationResult(values: ["recording-enabled": String(enabled)]).revision
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
    try AppDiagnosticScope.live.readLog(range: range, limit: limit, errorsOnly: errorsOnly)
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
    try AppDiagnosticScope.live.readRecordingEnabled()
  }

  public static func setRecordingEnabled(_ enabled: Bool) throws {
    try AppDiagnosticScope.live.setRecordingEnabled(enabled)
  }

  public static func setRecordingEnabled(_ enabled: Bool, ifRevision revision: String) throws -> Bool {
    try AppDiagnosticScope.live.setRecordingEnabled(enabled, ifRevision: revision)
  }

  public static func makeShareableFile(range: AppDiagnosticExportRange = .last24Hours) throws -> URL
  {
    try AppDiagnosticScope.live.makeShareableFile(range: range)
  }

  /// Removes an owned staging file and its directory. User-saved copies are left alone.
  public static func removeShareableFile(_ fileURL: URL) {
    AppDiagnosticScope.live.removeShareableFile(fileURL)
  }

  public static func clear() throws {
    try AppDiagnosticScope.live.clear()
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
    }
  }
}

/// Owns the diagnostics queue for this process. Each app or extension uses its own container.
public final class AppDiagnosticScope: Sendable {
  public static let live = AppDiagnosticScope(store: .forBundle(
    bundleIdentifier: Bundle.main.bundleIdentifier,
    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
    appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
    bundle: .main
  ))

  private let logger = Logger(subsystem: "SnipSnap", category: "Operations")
  private let store: AppDiagnosticEventStore
  private let queue = DispatchQueue(label: "SnipSnap.diagnostics", qos: .utility)

  init(store: AppDiagnosticEventStore) {
    self.store = store
  }

  public var recorder: AppDiagnosticRecorder {
    AppDiagnosticRecorder(record: { [self] in record($0) }, flush: { [self] timeout in
      guard timeout > 0 else { return false }
      let (results, completion) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
      queue.async {
        completion.yield(true)
        completion.finish()
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + min(timeout, 2)) {
        completion.yield(false)
        completion.finish()
      }
      var iterator = results.makeAsyncIterator()
      let drained = await iterator.next()
      return drained == true && !Task.isCancelled
    })
  }

  func record(_ event: AppDiagnosticEvent, at date: Date = Date()) {
    switch event.outcome {
    case .failed:
      logger.error("\(event.line, privacy: .public)")
    case .cancelled, .missing:
      logger.notice("\(event.line, privacy: .public)")
    case .started, .succeeded:
      logger.info("\(event.line, privacy: .public)")
    }
    queue.async { [self] in
      do {
        try store.append(event, at: date)
      } catch {
        logger.error("Diagnostic file write failed: \(diagnosticErrorCode(error), privacy: .private)")
      }
    }
  }

  public func readLog(
    range: AppDiagnosticExportRange = .last24Hours, limit: Int = 200, errorsOnly: Bool = false
  ) throws -> AppDiagnosticLogReport {
    try queue.sync { try store.readLog(range: range, limit: limit, errorsOnly: errorsOnly) }
  }

  public func readRecordingEnabled() throws -> Bool {
    try queue.sync { try store.readRecordingEnabled() }
  }

  public func setRecordingEnabled(_ enabled: Bool) throws {
    try queue.sync { try store.setRecordingEnabled(enabled) }
  }

  func setRecordingEnabled(_ enabled: Bool, ifRevision revision: String) throws -> Bool {
    try queue.sync {
      let current = try store.readRecordingEnabled()
      guard AppDiagnosticLogReport.recordingRevision(enabled: current) == revision else { return false }
      try store.setRecordingEnabled(enabled)
      return true
    }
  }

  public func makeShareableFile(range: AppDiagnosticExportRange = .last24Hours) throws -> URL {
    try queue.sync { try store.makeShareableFile(range: range) }
  }

  public func removeShareableFile(_ fileURL: URL) {
    queue.sync { store.removeShareableFile(fileURL) }
  }

  public func clear() throws {
    try queue.sync { try store.clear() }
  }
}
