import Darwin
import Foundation

/// All byte budgets count encoded bytes, including duplicated failure context.
struct AppDiagnosticRetentionPolicy: Sendable {
  var historyBytes = 10 * 1_024 * 1_024
  var protectedBytes = 2 * 1_024 * 1_024
  var segmentBytes = 1_024 * 1_024
  var segmentAge: TimeInterval = 86_400
  var retentionAge: TimeInterval = 7 * 86_400
  var exportBytes = 5 * 1_024 * 1_024
  var stagingBytes = 5 * 1_024 * 1_024
  var aggregationWindow: TimeInterval = 60
  var contextCount = 8
}

/// Boot session plus monotonic submission time permits cross-process invalidation
/// without disk access on record(). Known boot identities tolerate wall-clock changes.
struct AppDiagnosticSubmissionStamp: Codable, Sendable {
  private static let boot: String = {
    var buffer = [UInt8](repeating: 0, count: 64)
    var size = buffer.count
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0, size > 1,
      size <= buffer.count
    else { return "unknown" }
    // This changes each boot, never identifies a device, and stays in the local
    // control sidecar. It is never included in diagnostic events or exports.
    return String(decoding: buffer.prefix(size - 1), as: UTF8.self)
  }()
  let boot: String
  let uptime: TimeInterval
  let capturedAt: Date?

  static func capture() -> Self {
    Self(boot: boot, uptime: ProcessInfo.processInfo.systemUptime, capturedAt: Date())
  }

  func precedes(_ cutoff: Self) -> Bool {
    if boot != "unknown", cutoff.boot != "unknown" {
      return boot == cutoff.boot && uptime <= cutoff.uptime
    }
    // Restricted environments may not expose a boot identity. Use submission
    // dates there so an earlier boot's uptime cannot suppress a new session.
    guard let capturedAt, let cutoffDate = cutoff.capturedAt else { return false }
    return capturedAt <= cutoffDate
  }
}

/// Exact occurrence times stay in memory only. The writer caps their total,
/// and the store aggregates only after rejecting occurrences behind its fence.
struct AppDiagnosticOccurrence: Sendable {
  var stamp: AppDiagnosticSubmissionStamp
  var latestStamp: AppDiagnosticSubmissionStamp
  var first: Date
  var last: Date
  var latestDate: Date
  var count: Int

  init(stamp: AppDiagnosticSubmissionStamp, date: Date) {
    self.stamp = stamp
    latestStamp = stamp
    first = date
    last = date
    latestDate = date
    count = 1
  }

  mutating func merge(_ next: Self) {
    if next.stamp.precedes(stamp) { stamp = next.stamp }
    if latestStamp.precedes(next.latestStamp) {
      latestStamp = next.latestStamp
      latestDate = next.latestDate
    }
    first = min(first, next.first)
    last = max(last, next.last)
    count = count > Int.max - next.count ? Int.max : count + next.count
  }

  struct Selection {
    var event: AppDiagnosticEvent
    var occurrence: AppDiagnosticOccurrence
  }

  /// A compacted prefix cannot be split exactly at an arbitrary later cutoff.
  /// Keep its latest known occurrence, plus the exact tail, and emit a missing
  /// diagnostics marker for the unquantifiable remainder. Marker counts describe
  /// incomplete intervals, not lost occurrences. Never reuse a mixed prefix's count.
  static func retained(
    _ occurrences: [Self], event: AppDiagnosticEvent, after cutoff: AppDiagnosticSubmissionStamp?
  ) -> [Selection] {
    var result: Self?
    var incomplete: Self?
    for var occurrence in occurrences {
      if let cutoff {
        if occurrence.latestStamp.precedes(cutoff) { continue }
        if occurrence.stamp.precedes(cutoff) {
          occurrence = Self(stamp: occurrence.latestStamp, date: occurrence.latestDate)
          if incomplete == nil { incomplete = occurrence } else { incomplete?.merge(occurrence) }
        }
      }
      if result == nil { result = occurrence } else { result?.merge(occurrence) }
    }
    var selections: [Selection] = []
    if let incomplete {
      selections.append(.init(event: .missing(operation: "diagnostics.recording"), occurrence: incomplete))
    }
    if let result { selections.append(.init(event: event, occurrence: result)) }
    return selections
  }

}

struct AppDiagnosticControlFence: Codable {
  var submission: AppDiagnosticSubmissionStamp
  var clearedAt: Date?
}

struct AppDiagnosticRecord: Codable {
  var id: UUID
  var first: Date
  var last: Date
  var count: Int
  var line: String
  var version: String
  var build: String
  var os: String
  var context: Bool = false
  var schema: Int = 1
  var severity: String = "info"

  static func safeVersion(_ value: String) -> String {
    guard !value.isEmpty, value.utf8.count <= 32, value.allSatisfy({ "0123456789.".contains($0) })
    else { return "unknown" }
    return value
  }

  static func make(
    event: AppDiagnosticEvent, first: Date, last: Date, count: Int,
    version: String, build: String, os: String
  ) -> Self? {
    guard count > 0, first <= last,
      first.timeIntervalSince1970.isFinite, abs(first.timeIntervalSince1970) < 253_402_300_800,
      last.timeIntervalSince1970.isFinite, abs(last.timeIntervalSince1970) < 253_402_300_800,
      let line = AppDiagnosticLine.sanitize("\(last.ISO8601Format()) \(event.line)")
    else { return nil }
    var record = Self(
      id: UUID(), first: first, last: last, count: count, line: line,
      version: version, build: build, os: os)
    record.severity = severity(for: line)
    return record
  }

  func aggregates(_ next: Self, window: TimeInterval) -> Bool {
    line.split(separator: " ", maxSplits: 1).last
      == next.line.split(separator: " ", maxSplits: 1).last
      && version == next.version && build == next.build
      && next.last >= last && next.last.timeIntervalSince(first) < window
      && count <= Int.max - next.count
  }

  static func severity(for line: String) -> String {
    if line.contains("outcome=failed") { return "error" }
    if line.contains("outcome=missing") || line.contains("outcome=cancelled") { return "notice" }
    return "info"
  }

  var protected: Bool {
    context || line.contains("outcome=failed") || line.contains("outcome=missing")
      || line.contains("outcome=cancelled")
  }

  var exportPriority: Int {
    if line.contains("outcome=failed") { return 3 }
    if protected && !context { return 2 }
    return context ? 1 : 0
  }

  var rendered: String {
    let event = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
    var result = "\(last.ISO8601Format()) \(event)"
    if count > 1 {
      result += " count=\(count) first=\(first.ISO8601Format()) last=\(last.ISO8601Format())"
    }
    result += " schema=1 severity=\(severity)"
    result += " app_version=\(version) app_build=\(build) os=\(os)"
    if context { result += " context=true" }
    return result
  }
}
