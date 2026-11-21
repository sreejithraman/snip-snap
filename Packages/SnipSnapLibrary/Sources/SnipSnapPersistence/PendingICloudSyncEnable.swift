import Foundation
import SnipSnapCore

/// The pending iCloud enable marker. No marker means no enable is pending: it finished,
/// was cancelled, or never started.
package enum PendingICloudSyncEnable {
  private enum Phase: Equatable {
    case pending
    case retrying(SyncedContentSyncIssue)
    case needsAttention(SyncedContentSyncIssue)
  }

  private static let fileName = "icloud-sync-enable-pending"
  private static let pendingValue = "pending"
  private static let legacyFailedValue = Data("needs-attention".utf8)
  private static let legacyRetryPrefix = "retry:"
  private static let retryPrefix = "retry-v2:"
  private static let failurePrefix = "failure-v2:"

  package static func exists(at rootURL: URL) -> Bool {
    switch phase(at: rootURL) {
    case .pending, .retrying: true
    case .needsAttention, nil: false
    }
  }

  package static func needsAttention(at rootURL: URL) -> Bool {
    failureIssue(at: rootURL) != nil
  }

  package static func failureIssue(at rootURL: URL) -> SyncedContentSyncIssue? {
    guard case .needsAttention(let issue) = phase(at: rootURL) else { return nil }
    return issue
  }

  package static func retryIssue(at rootURL: URL) -> SyncedContentSyncIssue? {
    guard case .retrying(let issue) = phase(at: rootURL) else { return nil }
    return issue
  }

  package static func mark(at rootURL: URL) throws {
    try write(.pending, at: rootURL)
  }

  package static func markNeedsAttention(_ issue: SyncedContentSyncIssue, at rootURL: URL) {
    try? write(.needsAttention(issue), at: rootURL)
  }

  package static func markRetrying(_ issue: SyncedContentSyncIssue, at rootURL: URL) {
    try? write(.retrying(issue), at: rootURL)
  }

  package static func clear(at rootURL: URL) throws {
    do {
      try FileManager.default.removeItem(at: url(at: rootURL))
    } catch CocoaError.fileNoSuchFile {}
  }

  private static func url(at rootURL: URL) -> URL {
    rootURL.appendingPathComponent(fileName, isDirectory: false)
  }

  private static func phase(at rootURL: URL) -> Phase? {
    guard let data = try? Data(contentsOf: url(at: rootURL)) else { return nil }
    if data == legacyFailedValue { return .needsAttention(.appDataIssue) }
    guard let value = String(data: data, encoding: .utf8) else { return .pending }
    if value.hasPrefix(failurePrefix) {
      return .needsAttention(issue(in: value, after: failurePrefix) ?? .appDataIssue)
    }
    if let issue = issue(in: value, after: retryPrefix) ?? legacyRetryIssue(in: value) {
      return .retrying(issue)
    }
    return .pending
  }

  private static func write(_ phase: Phase, at rootURL: URL) throws {
    let value: String
    switch phase {
    case .pending: value = pendingValue
    case .retrying(let issue): value = try retryPrefix + payload(for: issue)
    case .needsAttention(let issue): value = try failurePrefix + payload(for: issue)
    }
    try DurableFile.write(Data(value.utf8), to: url(at: rootURL))
  }

  private static func payload(for issue: SyncedContentSyncIssue) throws -> String {
    try JSONEncoder().encode(issue).base64EncodedString()
  }

  private static func issue(in value: String, after prefix: String) -> SyncedContentSyncIssue? {
    guard value.hasPrefix(prefix),
      let payload = Data(base64Encoded: String(value.dropFirst(prefix.count)))
    else { return nil }
    return try? JSONDecoder().decode(SyncedContentSyncIssue.self, from: payload)
  }

  private static func legacyRetryIssue(in value: String) -> SyncedContentSyncIssue? {
    guard value.hasPrefix(legacyRetryPrefix) else { return nil }
    return switch String(value.dropFirst(legacyRetryPrefix.count)) {
    case "waiting-for-connection": .waitingForConnection
    case "icloud-unavailable": .iCloudUnavailable
    case "retrying-soon": .retryingSoon
    case "checking-account": .checkingAccount
    case "account-temporarily-unavailable": .accountTemporarilyUnavailable
    case "some-changes-pending": .someChangesPending
    case "attachment-unavailable": .attachmentUnavailable
    default: nil
    }
  }
}
