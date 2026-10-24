import CryptoKit
import Foundation

public enum SnipCLIApplicationSetting: String, Codable, CaseIterable, Sendable {
  case appearance
  case sort
  case completionFilter = "completion-filter"
  case clipboardOnlyPinned = "clipboard-only-pinned"
  case clipboardNewestFirst = "clipboard-newest-first"
  case betaUpdates = "beta-updates"

  public func accepts(_ value: String) -> Bool {
    switch self {
    case .appearance: ["system", "light", "dark"].contains(value)
    case .sort: ["chronological", "manual"].contains(value)
    case .completionFilter: ["all", "done", "notDone"].contains(value)
    case .clipboardOnlyPinned, .clipboardNewestFirst, .betaUpdates: ["on", "off"].contains(value)
    }
  }
}

public enum SnipCLIShortcutAction: String, Codable, CaseIterable, Sendable {
  case captureSelection = "capture-selection"
  case togglePanel = "toggle-panel"
  case toggleClipboard = "toggle-clipboard"
  case toggleDone = "toggle-done"
  case merge
}

public enum SnipCLIShortcutBinding: Codable, Equatable, Sendable {
  case doubleShift(right: Bool)
  case commandDoubleShift(right: Bool)
  /// Physical macOS key code and Carbon modifier bits, matching the app's shortcut model.
  case chord(keyCode: UInt32, modifiers: UInt32, label: String)
}

public enum SnipCLIAccountChoice: String, Codable, Sendable {
  case keep
  case remove
}

public enum SnipCLIApplicationAction: Codable, Equatable, Sendable {
  case settingsShow
  case setSetting(key: SnipCLIApplicationSetting, value: String, expectedRevision: String)
  case setShortcut(action: SnipCLIShortcutAction, binding: SnipCLIShortcutBinding, expectedRevision: String)
  case resetShortcut(action: SnipCLIShortcutAction, expectedRevision: String)
  case syncStatus
  case setSync(enabled: Bool, useCurrentCache: Bool, expectedRevision: String)
  case cancelSyncSetup(expectedRevision: String)
  case retrySync
  case clipboardSyncStatus
  case setClipboardSync(enabled: Bool, expectedRevision: String)
  case retryClipboardSync
  case resolveAccount(choice: SnipCLIAccountChoice, expectedRevision: String, confirmed: Bool)
  case exportDiagnostics(path: String, range: AppDiagnosticExportRange? = nil)
  case diagnosticsStatus
  case diagnosticLogs(range: AppDiagnosticExportRange, limit: Int, errorsOnly: Bool)
  case setDiagnosticRecording(enabled: Bool, expectedRevision: String)
  case clearDiagnostics(expectedRevision: String, confirmed: Bool)
  case attachmentCacheStatus
  case clearAttachmentCache(expectedRevision: String, confirmed: Bool)
  case status
  case show
  case hide
  case showClipboard
  case closeSearch
  case selectList(selector: String)
  case search(query: String)
  case openSettings
  case captureSelection
  case captureScreen
  case checkForUpdates

  public var isReadOnly: Bool {
    switch self {
    case .settingsShow, .syncStatus, .clipboardSyncStatus, .diagnosticsStatus, .diagnosticLogs,
         .attachmentCacheStatus, .status: true
    default: false
    }
  }

  public var compacted: Self {
    switch self {
    case .setSetting(let key, _, _): .setSetting(key: key, value: "", expectedRevision: "")
    case .setShortcut(let action, _, _):
      .setShortcut(action: action, binding: .chord(keyCode: 0, modifiers: 0, label: ""), expectedRevision: "")
    case .resetShortcut(let action, _): .resetShortcut(action: action, expectedRevision: "")
    case .setSync(let enabled, let cache, _): .setSync(enabled: enabled, useCurrentCache: cache, expectedRevision: "")
    case .cancelSyncSetup: .cancelSyncSetup(expectedRevision: "")
    case .setClipboardSync(let enabled, _): .setClipboardSync(enabled: enabled, expectedRevision: "")
    case .resolveAccount(let choice, _, let confirmed): .resolveAccount(choice: choice, expectedRevision: "", confirmed: confirmed)
    case .exportDiagnostics(_, let range): .exportDiagnostics(path: "", range: range)
    case .setDiagnosticRecording(let enabled, _): .setDiagnosticRecording(enabled: enabled, expectedRevision: "")
    case .clearDiagnostics(_, let confirmed): .clearDiagnostics(expectedRevision: "", confirmed: confirmed)
    case .clearAttachmentCache(_, let confirmed): .clearAttachmentCache(expectedRevision: "", confirmed: confirmed)
    case .selectList: .selectList(selector: "")
    case .search: .search(query: "")
    default: self
    }
  }
}

/// Named values keep status useful both in JSON and in a terminal without exposing cloud identities.
public struct SnipCLIApplicationResult: Codable, Equatable, Sendable {
  public let values: [String: String]
  public let revision: String

  /// Uses an owner's revision when it guards the mutation of the reported state.
  public init(values: [String: String], revision: String) {
    self.values = values
    self.revision = revision
  }

  public init(values: [String: String]) {
    self.values = values
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(values)
    revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public init(diagnosticLog report: AppDiagnosticLogReport) {
    self.init(values: [
      "log": report.text,
      "returned-events": String(report.returnedEvents),
      "truncated": String(report.truncated),
    ])
  }
}
