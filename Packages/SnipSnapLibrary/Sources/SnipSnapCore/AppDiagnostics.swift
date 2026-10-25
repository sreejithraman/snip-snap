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
    "share.import", "share.extension_startup", "share.extension_load", "share.extension_save",
    "share.catalog_publish", "share.catalog_read", "shortcut.save", "shortcut.register",
    "capture.screen", "selection.capture",
    "snip.paste_read", "snip.paste_save",
    "sync.account_refresh", "sync.account_resolve", "sync.account_status",
    "sync.cancel_setup", "sync.delete", "sync.disable", "sync.enable", "sync.run",
    "sync.setup", "sync.stop", "sync.snapshot", "sync.provider", "sync.fetch", "sync.send",
    "sync.settlement", "sync.schedule", "sync.reset",
  ]

  static let errorCodes: Set<String> = [
    "diagnostics.busy", "diagnostics.routineOverflow", "diagnostics.failureOverflow",
    "diagnostics.writeFailed", "share.sharedContainerUnavailable",
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

  /// Best effort for a finite queued batch. False means timeout, cancellation, or
  /// unavailable storage; pending work remains eligible for the writer's retry.
  /// The wait is capped at two seconds and never blocks the caller's executor.
  public func flush(timeout: TimeInterval = 0.5) async -> Bool {
    guard !Task.isCancelled else { return false }
    return await flushEvents(timeout)
  }

  public func record(_ event: AppDiagnosticEvent) {
    recordEvent(event)
  }

  public static var live: AppDiagnosticRecorder { AppDiagnosticScope.live.recorder }
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

  public static func setRecordingEnabled(_ enabled: Bool, ifRevision revision: String) throws
    -> Bool
  {
    try AppDiagnosticScope.live.setRecordingEnabled(enabled, ifRevision: revision)
  }

  public static func makeShareableFile(range: AppDiagnosticExportRange = .last24Hours) throws -> URL
  {
    try AppDiagnosticScope.live.makeShareableFile(range: range)
  }

  /// Removes an owned staging file and its directory. User-saved copies are left alone.
  public static func removeShareableFile(_ fileURL: URL) {
    AppDiagnosticScope.removeLiveShareableFile(fileURL)
    AppDiagnosticEventStore.removeOwnedShareableFile(fileURL)
  }

  public static func clear() throws {
    try AppDiagnosticScope.live.clear()
  }

  public static func snapshot() throws -> AppDiagnosticExportSnapshot {
    try AppDiagnosticScope.live.snapshot()
  }

  /// Returns false without clearing when history, health, app context, or recording state has changed.
  public static func clear(ifRevision revision: String) throws -> Bool {
    try AppDiagnosticScope.live.clear(ifRevision: revision)
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

/// One explicitly owned history, writer, recording preference, and export scope.
/// Live iOS sharing requires matching application metadata and an accessible app group.
/// Other bundles keep their private history; no global configuration order is required.
public final class AppDiagnosticScope: @unchecked Sendable {
  public static let live = resolve(bundle: .main)

  public var recorder: AppDiagnosticRecorder {
    AppDiagnosticRecorder(
      record: { [self] in record($0) }, flush: { [self] in await writer.flush(timeout: $0) })
  }

  private let logger = Logger(subsystem: "SnipSnap", category: "Operations")
  private let store: AppDiagnosticEventStore
  private let writer: AppDiagnosticWriter
  private let controlsAvailable: Bool
  public let sharesApplicationHistory: Bool

  init(
    store: AppDiagnosticEventStore, writer: AppDiagnosticWriter? = nil,
    sharesApplicationHistory: Bool = false, controlsAvailable: Bool = true
  ) {
    self.store = store
    self.sharesApplicationHistory = sharesApplicationHistory
    self.controlsAvailable = controlsAvailable
    self.writer = writer ?? AppDiagnosticWriter(
      store: store, requiresReadableControls: sharesApplicationHistory)
  }

  private static func resolve(bundle: Bundle) -> AppDiagnosticScope {
    let manager = FileManager.default
    let environment = ProcessInfo.processInfo.environment
    #if os(iOS)
      let application =
        bundle.object(forInfoDictionaryKey: "SnipSnapDiagnosticsApplicationIdentifier") as? String
      let group = bundle.object(forInfoDictionaryKey: "SnipSnapAppGroupIdentifier") as? String
      let isolated = environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"]?.hasPrefix("/") == true
      let container =
        !isolated && validIdentifier(group)
        ? manager.containerURL(forSecurityApplicationGroupIdentifier: group!) : nil
    #else
      let application: String? = nil
      let group: String? = nil
      let container: URL? = nil
    #endif
    return resolve(
      bundleIdentifier: bundle.bundleIdentifier, applicationIdentifier: application,
      appGroupIdentifier: group, sharedContainerURL: container,
      applicationSupportURL: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
        0],
      cachesURL: manager.urls(for: .cachesDirectory, in: .userDomainMask)[0],
      environment: environment,
      appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "unknown",
      appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
  }

  // The internal resolution seam substitutes only OS directory and bundle metadata in tests.
  static func resolve(
    bundleIdentifier: String?, applicationIdentifier: String?, appGroupIdentifier: String?,
    sharedContainerURL: URL?, applicationSupportURL: URL, cachesURL: URL,
    environment: [String: String], appVersion: String, appBuild: String
  ) -> AppDiagnosticScope {
    let isolated = environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"]?.hasPrefix("/") == true
    let owned =
      validIdentifier(applicationIdentifier)
      && (bundleIdentifier == applicationIdentifier
        || bundleIdentifier == applicationIdentifier.map { $0 + ".share" })
    let shared = !isolated && owned && validIdentifier(appGroupIdentifier)
      && sharedContainerURL?.isFileURL == true
    let base =
      shared
      ? sharedContainerURL!.appendingPathComponent("Library/Application Support", isDirectory: true)
      : applicationSupportURL
    let directory = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: base,
      bundleIdentifier: shared ? applicationIdentifier : bundleIdentifier, environment: environment)
    let oldSupport = AppDiagnosticEventStore.storageDirectoryURL(
      applicationSupportURL: applicationSupportURL, bundleIdentifier: bundleIdentifier,
      environment: [:])
    let oldCache = AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: cachesURL, bundleIdentifier: bundleIdentifier, environment: [:])
    return AppDiagnosticScope(
      store: AppDiagnosticEventStore(
        directoryURL: directory, appVersion: appVersion, appBuild: appBuild,
        legacyDirectoryURL: isolated ? nil : oldCache,
        priorDirectoryURLs: shared ? [oldSupport] : []), sharesApplicationHistory: shared,
      controlsAvailable: isolated || !owned || shared)
  }

  // Cleanup must not initialize the process's live writer. CLI/tests can clean an
  // independently created export before first recording in their own isolated scope.
  static func removeLiveShareableFile(_ fileURL: URL) {
    resolve(bundle: .main).store.removeShareableFile(fileURL)
  }

  private static func validIdentifier(_ value: String?) -> Bool {
    guard let value, !value.isEmpty, value.utf8.count <= 200,
      value != ".", value != ".."
    else { return false }
    return value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        .contains($0)
    }
  }

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
    if controlsAvailable { writer.submit(event, at: submittedAt) }
  }

  private func perform<T>(_ operation: () throws -> T) throws -> T {
    guard controlsAvailable else { throw CocoaError(.fileReadNoPermission) }
    return try writer.perform {
      if sharesApplicationHistory { _ = try store.readRecordingEnabled() }
      return try operation()
    }
  }

  public func readLog(
    range: AppDiagnosticExportRange = .last24Hours, limit: Int = 200, errorsOnly: Bool = false
  ) throws
    -> AppDiagnosticLogReport
  {
    try perform { try store.readLog(range: range, limit: limit, errorsOnly: errorsOnly) }
  }

  public func readRecordingEnabled() throws -> Bool {
    try perform { try store.readRecordingEnabled() }
  }

  public func setRecordingEnabled(_ enabled: Bool) throws {
    try perform { try store.setRecordingEnabled(enabled) }
  }

  public func setRecordingEnabled(_ enabled: Bool, ifRevision revision: String) throws -> Bool {
    try perform { try store.setRecordingEnabled(enabled, ifRevision: revision) }
  }

  public func makeShareableFile(range: AppDiagnosticExportRange = .last24Hours) throws -> URL {
    try perform { try store.makeShareableFile(range: range) }
  }

  public func removeShareableFile(_ fileURL: URL) {
    store.removeShareableFile(fileURL)
  }

  public func clear() throws {
    try perform { try store.clear() }
  }

  public func snapshot() throws -> AppDiagnosticExportSnapshot {
    try perform { try store.snapshot() }
  }

  public func clear(ifRevision revision: String) throws -> Bool {
    try perform { try store.clear(ifRevision: revision) }
  }
}
