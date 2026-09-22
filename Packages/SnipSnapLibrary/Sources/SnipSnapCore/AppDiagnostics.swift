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
    "sync.setup", "sync.stop",
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

  private init(
    operation: StaticString,
    outcome: AppDiagnosticOutcome,
    visibility: AppDiagnosticVisibility,
    errorCode: String? = nil,
    byteCount: Int64? = nil,
    retryAfterSeconds: Double? = nil,
    nextAttemptSeconds: Double? = nil
  ) {
    self.operation = AppDiagnosticCodePolicy.operation(String(describing: operation))
    self.outcome = outcome
    self.visibility = visibility
    self.errorCode = errorCode.map(AppDiagnosticCodePolicy.errorCode)
    self.byteCount = byteCount
    self.retryAfterSeconds = retryAfterSeconds
    self.nextAttemptSeconds = nextAttemptSeconds
  }

  public static func started(
    operation: StaticString,
    visibility: AppDiagnosticVisibility = .background
  ) -> Self {
    Self(operation: operation, outcome: .started, visibility: visibility)
  }

  public static func succeeded(
    operation: StaticString,
    visibility: AppDiagnosticVisibility = .background,
    byteCount: Int64? = nil
  ) -> Self {
    Self(
      operation: operation,
      outcome: .succeeded,
      visibility: visibility,
      byteCount: byteCount
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
    directoryURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SnipSnapDiagnostics", isDirectory: true),
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
  private let directoryURL: URL
  private let eventsURL: URL
  private let legacyEventsURL: URL
  private let shareURL: URL
  private let maxBytes: Int
  private let header: String
  private let lock = NSLock()

  init(directoryURL: URL, maxBytes: Int, appVersion: String, appBuild: String) {
    self.directoryURL = directoryURL
    eventsURL = directoryURL.appendingPathComponent("diagnostic-events.txt")
    legacyEventsURL = directoryURL.appendingPathComponent("attachment-events.txt")
    shareURL = directoryURL.appendingPathComponent("Snip-Snap-Diagnostics.txt")
    self.maxBytes = maxBytes
    header = """
      Snip Snap diagnostics
      format=2 app_version=\(appVersion) app_build=\(appBuild)
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
        let line = "\(date.ISO8601Format(.iso8601(timeZone: .gmt))) \(event.line)"
        let contents = bounded(header + combinedEventLines(appending: line))
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
      let contents = bounded(header + combinedEventLines())
      try contents.write(to: eventsURL, atomically: true, encoding: .utf8)
      consumeLegacyEvents()
      try contents.write(to: shareURL, atomically: true, encoding: .utf8)
      return shareURL
    }
  }

  func clear() throws {
    try lock.withLock {
      for url in [eventsURL, legacyEventsURL, shareURL]
      where FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  private func combinedEventLines(appending line: String? = nil) -> String {
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
    var lines = legacyOnly + current
    if let line { lines.append(line) }
    guard !lines.isEmpty else { return "" }
    return lines.joined(separator: "\n") + "\n"
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
      optionalKeys = ["error", "bytes", "retry_after", "next_attempt"]
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
    }
    if let error = values["error"] {
      values["error"] = AppDiagnosticCodePolicy.errorCode(error)
    }
    let orderedFields = (requiredKeys + optionalKeys).compactMap { key in
      values[key].map { "\(key)=\($0)" }
    }
    return ([fields[0], fields[1]] + orderedFields).joined(separator: " ")
  }

  private func bounded(_ contents: String) -> String {
    guard contents.utf8.count > maxBytes else { return contents }
    var lines = eventLines(from: contents)
    while !lines.isEmpty {
      let candidate = header + lines.joined(separator: "\n") + "\n"
      if candidate.utf8.count <= maxBytes { return candidate }
      lines.removeFirst()
    }
    return header
  }
}
