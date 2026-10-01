import Foundation
import OSLog

/// Persist only codes owned by this app. Unknown values keep the event but lose the value.
private enum AppDiagnosticCodePolicy {
  static let unknownError = "other.UnknownError"

  static let operations: Set<String> = [
    "app.startup", "app.user_action", "app.unknown",
    "attachment.asset_copy", "attachment.cache_clear", "attachment.cache_install",
    "attachment.cloudkit_asset_url", "attachment.cloudkit_record", "attachment.cloudkit_request",
    "attachment.import_select", "attachment.import_stage", "attachment.prepare",
    "attachment.receipt_validation", "attachment.remote_fetch",
    "backup.export", "backup.import_select",
    "clipboard.account_reset", "clipboard.clear", "clipboard.copy_file", "clipboard.delete",
    "clipboard.delete_synced", "clipboard.export", "clipboard.load", "clipboard.paste",
    "clipboard.persist",
    "clipboard.paste_read", "clipboard.pin", "clipboard.share_import", "clipboard.sync",
    "clipboard.write", "composer.paste_stage",
    "cloudkit.clipboard_delete", "cloudkit.clipboard_fetch", "cloudkit.clipboard_save",
    "cloudkit.control_create_zones", "cloudkit.control_delete_zones", "cloudkit.control_fetch",
    "cloudkit.control_save", "cloudkit.record_fetch", "cloudkit.record_send", "cloudkit.request",
    "diagnostics.clear", "diagnostics.export", "import.file", "share.import", "shortcut.save",
    "sync.cancel_setup", "sync.delete", "sync.disable", "sync.enable", "sync.run",
    "sync.setup", "sync.stop", "sync.snapshot", "sync.provider", "sync.fetch", "sync.send",
    "sync.settlement", "sync.schedule", "sync.reset",
  ]

  static let errorCodes: Set<String> = [
    "clipboard.empty", "clipboard.tooLarge", "clipboard.unreadable", "clipboard.unsupported",
    "import.partialFailure", "import.readFailed", "pasteboard.writeFailed",
    "presentation.message", "presentation.startup", "attachment.unavailableAfterPrepare",
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

public protocol AppDiagnosticRecording: Sendable {
  func record(_ event: AppDiagnosticEvent)
}

public struct AppDiagnosticRecorder: AppDiagnosticRecording, Sendable {
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

public enum AppDiagnostics {
  public static let shared = AppDiagnosticRecorder.live
}

/// Creates and clears the bounded, privacy-safe diagnostic file shared from app settings.
public enum AppDiagnosticsExport {
  public static func makeShareableFile() throws -> URL {
    try AppDiagnosticLiveSink.shared.makeShareableFile()
  }

  public static func clear() throws {
    try AppDiagnosticLiveSink.shared.clear()
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
  private let store = AppDiagnosticEventStore(
    directoryURL: AppDiagnosticEventStore.storageDirectoryURL(
      cachesURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
      bundleIdentifier: Bundle.main.bundleIdentifier,
      environment: ProcessInfo.processInfo.environment
    ),
    maxBytes: 64 * 1_024,
    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown",
    appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      ?? "unknown"
  )

  func record(_ event: AppDiagnosticEvent) {
    switch event.outcome {
    case .failed:
      logger.error("\(event.line, privacy: .public)")
    case .cancelled, .missing:
      logger.notice("\(event.line, privacy: .public)")
    case .started, .succeeded:
      logger.info("\(event.line, privacy: .public)")
    }
    store.append(event)
  }

  func makeShareableFile() throws -> URL {
    try store.makeShareableFile()
  }

  func clear() throws {
    try store.clear()
  }
}

final class AppDiagnosticEventStore: @unchecked Sendable {
  private static let unbundledCacheNamespace = "unbundled-\(UUID().uuidString)"

  static func storageDirectoryURL(
    cachesURL: URL,
    bundleIdentifier: String?,
    environment: [String: String]
  ) -> URL {
    storageDirectoryURL(
      cachesURL: cachesURL,
      bundleIdentifier: bundleIdentifier,
      isolatedDirectoryPath: environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"]
    )
  }

  /// A diagnostics-only override isolates hosts while normal launches keep the bundle cache.
  static func storageDirectoryURL(
    cachesURL: URL,
    bundleIdentifier: String?,
    isolatedDirectoryPath: String?
  ) -> URL {
    if let isolatedDirectoryPath, isolatedDirectoryPath.hasPrefix("/") {
      return URL(fileURLWithPath: isolatedDirectoryPath, isDirectory: true)
    }
    let namespace: String
    if let bundleIdentifier, !bundleIdentifier.isEmpty,
      !bundleIdentifier.contains("/"), bundleIdentifier != ".", bundleIdentifier != ".."
    {
      namespace = bundleIdentifier
    } else {
      namespace = unbundledCacheNamespace
    }
    return cachesURL.appendingPathComponent(namespace, isDirectory: true)
      .appendingPathComponent("SnipSnapDiagnostics", isDirectory: true)
  }

  private enum SyncHealthKey: CaseIterable {
    case transport
    case records
    case fetch
    case send

    var marker: String {
      switch self {
      case .transport, .records: "diagnostic_sync_latest"
      case .fetch, .send: "diagnostic_sync_last_success"
      }
    }
  }

  private let directoryURL: URL
  private let eventsURL: URL
  private let legacyEventsURL: URL
  private let syncHealthURL: URL
  private let shareURL: URL
  private let maxBytes: Int
  private let header: String
  private let lock = NSLock()

  init(directoryURL: URL, maxBytes: Int, appVersion: String, appBuild: String) {
    self.directoryURL = directoryURL
    eventsURL = directoryURL.appendingPathComponent("diagnostic-events.txt")
    legacyEventsURL = directoryURL.appendingPathComponent("attachment-events.txt")
    syncHealthURL = directoryURL.appendingPathComponent("diagnostic-sync-health.txt")
    shareURL = directoryURL.appendingPathComponent("Snip-Snap-Diagnostics.txt")
    self.maxBytes = max(0, maxBytes)
    header = """
      Snip Snap diagnostics
      format=3 app_version=\(appVersion) app_build=\(appBuild)
      privacy=structured-operational-events-only

      """
  }

  func append(_ event: AppDiagnosticEvent, at date: Date = Date()) {
    lock.withLock {
      do {
        try FileManager.default.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: true
        )
        guard let line = sanitizedStoredEventLine(
          "\(date.ISO8601Format(.iso8601(timeZone: .gmt).timeZone(separator: .colon))) \(event.line)"
        ) else { return }
        var lines = combinedEventLines()
        var health = retainedSyncHealth(from: lines)
        if let key = syncHealthKey(for: line) { health[key] = line }
        // Save health before history can rotate. A crash between these atomic writes must
        // not erase the newest observation or the last successful transfer.
        try persistSyncHealth(health)
        lines.append(line)
        let contents = bounded(lines, prefix: header)
        try contents.write(to: eventsURL, atomically: true, encoding: .utf8)
        consumeLegacyEvents()
      } catch {
        // Diagnostics must never alter app behavior.
      }
    }
  }

  func makeShareableFile() throws -> URL {
    try lock.withLock {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      let lines = combinedEventLines()
      let health = retainedSyncHealth(from: lines)
      try persistSyncHealth(health)
      try bounded(lines, prefix: header).write(to: eventsURL, atomically: true, encoding: .utf8)
      consumeLegacyEvents()
      var prefix = header
      for key in SyncHealthKey.allCases {
        guard let line = health[key] else { continue }
        let observation = line.replacingOccurrences(
          of: " diagnostic_event ",
          with: " \(key.marker) "
        ) + "\n"
        if prefix.utf8.count + observation.utf8.count <= maxBytes {
          prefix += observation
        }
      }
      let contents = bounded(lines, prefix: prefix)
      try contents.write(to: shareURL, atomically: true, encoding: .utf8)
      return shareURL
    }
  }

  func clear() throws {
    try lock.withLock {
      for url in [syncHealthURL, eventsURL, legacyEventsURL, shareURL]
      where FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  private func combinedEventLines() -> [String] {
    let current = storedEventLines(at: eventsURL)
    var currentCounts = current.reduce(into: [String: Int]()) { counts, event in
      counts[event, default: 0] += 1
    }
    // Earlier exports copied legacy events into the current file. Remove only that overlap;
    // identical failures in one second are separate events and must remain separate.
    let legacyOnly = storedEventLines(at: legacyEventsURL).filter { event in
      guard let count = currentCounts[event], count > 0 else { return true }
      currentCounts[event] = count - 1
      return false
    }
    return legacyOnly + current
  }

  private func retainedSyncHealth(from history: [String]) -> [SyncHealthKey: String] {
    var health: [SyncHealthKey: String] = [:]
    for line in history {
      if let key = syncHealthKey(for: line) { health[key] = line }
    }
    // The sidecar wins over history because it is written first. History also provides
    // safe migration when an older build wrote a sync event without retained health.
    if let size = try? syncHealthURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 4_096
    {
      for line in storedEventLines(at: syncHealthURL) {
        if let key = syncHealthKey(for: line) { health[key] = line }
      }
    }
    return health
  }

  private func syncHealthKey(for line: String) -> SyncHealthKey? {
    let fields = line.split(separator: " ").map(String.init)
    guard fields.count >= 5, fields[1] == "diagnostic_event",
      fields.contains("outcome=succeeded")
    else { return nil }
    if fields.contains("operation=sync.snapshot") {
      if fields.contains("scope=transport") { return .transport }
      if fields.contains("scope=records") { return .records }
    }
    if fields.contains("operation=sync.fetch") { return .fetch }
    if fields.contains("operation=sync.send") { return .send }
    return nil
  }

  private func persistSyncHealth(_ health: [SyncHealthKey: String]) throws {
    let lines = SyncHealthKey.allCases.compactMap { health[$0] }
    guard !lines.isEmpty else { return }
    try (lines.joined(separator: "\n") + "\n")
      .write(to: syncHealthURL, atomically: true, encoding: .utf8)
  }

  private func consumeLegacyEvents() {
    guard FileManager.default.fileExists(atPath: legacyEventsURL.path) else { return }
    try? FileManager.default.removeItem(at: legacyEventsURL)
  }

  private func storedEventLines(at url: URL) -> [String] {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return eventLines(from: contents)
  }

  private func eventLines(from contents: String) -> [String] {
    contents.split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap { sanitizedStoredEventLine(String($0)) }
  }

  private func sanitizedStoredEventLine(_ line: String) -> String? {
    guard line.utf8.count <= 512 else { return nil }
    let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 4,
      fields[0].count >= 19, fields[0].count <= 35,
      fields[0].allSatisfy({ "0123456789-T:.+Z".contains($0) })
    else { return nil }

    let requiredKeys: [String]
    let optionalKeys: [String]
    switch fields[1] {
    case "diagnostic_event":
      requiredKeys = ["operation", "outcome", "visibility"]
      optionalKeys = [
        "error", "bytes", "retry_after", "next_attempt", "scope", "environment", "phase",
        "reason", "pending_uploads", "pending_downloads", "pending_events", "blocked_records",
      ]
    case "attachment_download":
      requiredKeys = ["stage", "outcome"]
      optionalKeys = ["error", "bytes"]
    default:
      return nil
    }
    guard fields.count <= 2 + requiredKeys.count + optionalKeys.count else { return nil }

    var values: [String: String] = [:]
    for field in fields.dropFirst(2) {
      let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2, !pair[1].isEmpty,
        values.updateValue(String(pair[1]), forKey: String(pair[0])) == nil
      else { return nil }
    }
    guard requiredKeys.allSatisfy({ values[$0] != nil }),
      values.keys.allSatisfy({ requiredKeys.contains($0) || optionalKeys.contains($0) }),
      values.filter({ !["bytes", "retry_after", "next_attempt"].contains($0.key) })
        .allSatisfy({ entry in
        entry.value.unicodeScalars.allSatisfy {
          CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
            .contains($0)
        }
      })
    else { return nil }

    if let bytes = values["bytes"], Int64(bytes) == nil { return nil }
    for key in ["retry_after", "next_attempt"] {
      if let value = values[key], Double(value)?.isFinite != true { return nil }
    }
    for key in ["pending_uploads", "pending_downloads", "pending_events", "blocked_records"] {
      if let raw = values[key] {
        guard let count = Int(raw), count >= 0, String(count) == raw else { return nil }
      }
    }
    if let scope = values["scope"], AppDiagnosticSyncScope(rawValue: scope) == nil { return nil }
    if let environment = values["environment"],
      AppDiagnosticSyncEnvironment(rawValue: environment) == nil
    { return nil }
    if let phase = values["phase"], AppDiagnosticSyncPhase(rawValue: phase) == nil { return nil }
    if let reason = values["reason"], AppDiagnosticSyncReason(rawValue: reason) == nil { return nil }
    guard let outcome = values["outcome"] else { return nil }
    if fields[1] == "attachment_download" {
      guard let stage = values["stage"],
        ["cloudkit_request", "cloudkit_record", "cloudkit_asset_url", "asset_copy",
        "remote_fetch", "receipt_validation", "cache_install"].contains(stage)
        && ["started", "succeeded", "failed", "missing"].contains(outcome)
      else { return nil }
    } else {
      guard let visibility = values["visibility"],
        ["started", "succeeded", "failed", "cancelled", "missing"].contains(outcome),
        ["user", "background"].contains(visibility)
      else { return nil }
      values["operation"] = AppDiagnosticCodePolicy.operation(values["operation"] ?? "")
      if values["operation"] == "sync.snapshot" {
        guard values["scope"] != nil, outcome == "succeeded", visibility == "background"
        else { return nil }
      } else if [
        "scope", "environment", "phase", "pending_uploads", "pending_downloads", "pending_events",
        "blocked_records",
      ].contains(where: { values[$0] != nil }) {
        return nil
      }
    }
    if let error = values["error"] {
      values["error"] = AppDiagnosticCodePolicy.errorCode(error)
    }
    let orderedFields = (requiredKeys + optionalKeys).compactMap { key in
      values[key].map { "\(key)=\($0)" }
    }
    return ([fields[0], fields[1]] + orderedFields).joined(separator: " ")
  }

  private func bounded(_ lines: [String], prefix: String) -> String {
    guard prefix.utf8.count <= maxBytes else {
      return String(decoding: prefix.utf8.prefix(maxBytes), as: UTF8.self)
    }
    var bytes = prefix.utf8.count
    var retained: [String] = []
    for line in lines.reversed() {
      let count = line.utf8.count + 1
      guard bytes + count <= maxBytes else { break }
      bytes += count
      retained.append(line)
    }
    guard !retained.isEmpty else { return prefix }
    return prefix + retained.reversed().joined(separator: "\n") + "\n"
  }
}
