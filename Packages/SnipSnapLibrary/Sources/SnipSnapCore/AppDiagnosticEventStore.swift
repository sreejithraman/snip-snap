import CryptoKit
import Darwin
import Foundation

/// Owns one resolved local history. Scope resolution alone selects bundle or app-group storage.
/// flock serializes separate instances/processes; NSLock also protects instance state.
final class AppDiagnosticEventStore: @unchecked Sendable {
  private typealias Record = AppDiagnosticRecord
  private typealias ControlFence = AppDiagnosticControlFence
  private static let unbundledNamespace = "unbundled-\(UUID().uuidString)"
  private static let session = UUID().uuidString
  private static let recordLimit = 4_096
  private let directoryURL: URL
  private let legacyDirectoryURL: URL?
  private let priorDirectoryURLs: [URL]
  private let legacyMigrationMarker: String
  private let policy: AppDiagnosticRetentionPolicy
  private let now: () -> Date
  private let appVersion: String
  private let appBuild: String
  private let os: String
  private let lock = NSLock()
  private let lockTimeout: TimeInterval
  private var context: [Record] = []
  private var contextClearToken: Data?

  init(
    directoryURL: URL, policy: AppDiagnosticRetentionPolicy = .init(),
    appVersion: String, appBuild: String, legacyDirectoryURL: URL? = nil,
    priorDirectoryURLs: [URL] = [],
    now: @escaping () -> Date = Date.init, lockTimeout: TimeInterval = 0.25
  ) {
    self.lockTimeout = lockTimeout.isFinite ? max(0, min(lockTimeout, 0.5)) : 0.25
    self.directoryURL = directoryURL
    self.legacyDirectoryURL = legacyDirectoryURL
    self.priorDirectoryURLs = priorDirectoryURLs
    if priorDirectoryURLs.isEmpty {
      legacyMigrationMarker = "migration-complete"
    } else {
      let namespace = priorDirectoryURLs[0].deletingLastPathComponent().lastPathComponent
      let key = SHA256.hash(data: Data(namespace.utf8)).prefix(8).map { String(format: "%02x", $0) }
        .joined()
      legacyMigrationMarker = "migration-cache-\(key).complete"
    }
    self.policy = policy
    self.now = now
    self.appVersion = Record.safeVersion(appVersion)
    self.appBuild = Record.safeVersion(appBuild)
    let version = ProcessInfo.processInfo.operatingSystemVersion
    #if os(iOS)
      let platform = "iOS"
    #else
      let platform = "macOS"
    #endif
    os = "\(platform)-\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  /// Kept for source compatibility. New callers should inject independent history/export budgets.
  convenience init(
    directoryURL: URL, maxBytes: Int, appVersion: String, appBuild: String,
    now: @escaping () -> Date = Date.init
  ) {
    var policy = AppDiagnosticRetentionPolicy()
    policy.exportBytes = max(0, maxBytes)
    self.init(
      directoryURL: directoryURL, policy: policy, appVersion: appVersion, appBuild: appBuild,
      now: now)
  }

  static func forBundle(bundleIdentifier: String?, appVersion: String, appBuild: String)
    -> AppDiagnosticEventStore
  {
    let environment = ProcessInfo.processInfo.environment
    let manager = FileManager.default
    let directory = storageDirectoryURL(
      applicationSupportURL: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
        0],
      bundleIdentifier: bundleIdentifier, environment: environment
    )
    // Isolation overrides never inspect or migrate a real installation's cache.
    let legacy =
      environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"]?.hasPrefix("/") == true
      ? nil
      : storageDirectoryURL(
        cachesURL: manager.urls(for: .cachesDirectory, in: .userDomainMask)[0],
        bundleIdentifier: bundleIdentifier, environment: [:])
    return AppDiagnosticEventStore(
      directoryURL: directory, appVersion: appVersion, appBuild: appBuild,
      legacyDirectoryURL: legacy)
  }

  static func storageDirectoryURL(
    applicationSupportURL: URL, bundleIdentifier: String?, environment: [String: String]
  ) -> URL {
    storageDirectoryURL(
      cachesURL: applicationSupportURL, bundleIdentifier: bundleIdentifier, environment: environment
    )
  }

  static func storageDirectoryURL(
    cachesURL: URL, bundleIdentifier: String?, environment: [String: String]
  ) -> URL {
    storageDirectoryURL(
      cachesURL: cachesURL, bundleIdentifier: bundleIdentifier,
      isolatedDirectoryPath: environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"])
  }

  static func storageDirectoryURL(
    cachesURL: URL, bundleIdentifier: String?, isolatedDirectoryPath: String?
  ) -> URL {
    if let path = isolatedDirectoryPath, path.hasPrefix("/") {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    let namespace: String
    if let bundleIdentifier, !bundleIdentifier.isEmpty, !bundleIdentifier.contains("/"),
      bundleIdentifier != ".", bundleIdentifier != ".."
    {
      namespace = bundleIdentifier
    } else {
      namespace = unbundledNamespace
    }
    return cachesURL.appendingPathComponent(namespace).appendingPathComponent(
      "SnipSnapDiagnostics", isDirectory: true)
  }

  func append(_ event: AppDiagnosticEvent, at date: Date? = nil) {
    try? appendThrowing(event, at: date)
  }

  /// Selection and every resulting append share one bounded lock acquisition.
  func appendThrowing(_ event: AppDiagnosticEvent, occurrences: [AppDiagnosticOccurrence]) throws {
    try synchronized {
      for selection in AppDiagnosticOccurrence.retained(
        occurrences, event: event, after: try controlFence()?.submission)
      {
        let retained = selection.occurrence
        try appendLocked(
          selection.event, at: retained.last, count: retained.count,
          first: retained.first, submitted: retained.stamp)
      }
    }
  }

  func appendThrowing(
    _ event: AppDiagnosticEvent, at date: Date? = nil, count: Int = 1, first: Date? = nil,
    submitted: AppDiagnosticSubmissionStamp? = nil
  ) throws {
    try synchronized { try appendLocked(event, at: date, count: count, first: first, submitted: submitted) }
  }

  private func appendLocked(
    _ event: AppDiagnosticEvent, at date: Date?, count: Int, first: Date?,
    submitted: AppDiagnosticSubmissionStamp?
  ) throws {
    guard recordingEnabledLocked else { return }
    if let submitted, let fence = try controlFence(), submitted.precedes(fence.submission) { return }
    let clearToken = read(url("clear-token"), limit: 64) ?? Data()
    if contextClearToken != clearToken {
      context.removeAll()
      contextClearToken = clearToken
    }
    let date = date ?? now()
    let first = first ?? date
    guard let record = Record.make(
      event: event, first: first, last: date, count: count,
      version: appVersion, build: appBuild, os: os)
    else { return }
    try updateHealth(record)
    if var previous = pending(), previous.aggregates(record, window: policy.aggregationWindow) {
      previous.last = date
      previous.count += count
      try write(previous, to: url("aggregate.json"))
    } else {
      try flushPending()
      if record.protected {
        for var breadcrumb in context.suffix(max(0, min(policy.contextCount, 8))) {
          breadcrumb.id = UUID()
          breadcrumb.context = true
          try appendRecord(breadcrumb)
        }
      }
      try appendRecord(record)
      try write(record, to: url("aggregate.json"))
    }
    if !record.protected {
      context.append(record)
      context = Array(context.suffix(max(0, min(policy.contextCount, 8))))
    }
    try cleanup()
  }

  func makeShareableFile(range: AppDiagnosticExportRange = .last24Hours) throws -> URL {
    try synchronized { try exportLocked(range: range) }
  }

  private enum QueryError: Error { case invalidLimit }

  func readLog(
    range: AppDiagnosticExportRange = .last24Hours, limit: Int = 200,
    errorsOnly: Bool = false
  ) throws -> AppDiagnosticLogReport {
    guard (1...2_000).contains(limit) else { throw QueryError.invalidLimit }
    return try synchronized {
      let result = try renderLocked(
        range: range, budget: policy.exportBytes,
        eventLimit: limit, errorsOnly: errorsOnly)
      return AppDiagnosticLogReport(
        text: String(decoding: result.data, as: UTF8.self),
        returnedEvents: result.returned, truncated: result.truncated)
    }
  }

  func snapshot() throws -> AppDiagnosticExportSnapshot {
    try synchronized { try snapshotLocked() }
  }

  func clear() throws { try synchronized { try clearLocked() } }

  func clear(ifRevision revision: String) throws -> Bool {
    try synchronized {
      guard try snapshotLocked().revision == revision else { return false }
      try clearLocked()
      return true
    }
  }

  func readRecordingEnabled() throws -> Bool {
    try synchronized { try recordingPreference() }
  }

  func setRecordingEnabled(_ enabled: Bool) throws {
    try synchronized { try setRecordingLocked(enabled) }
  }

  func setRecordingEnabled(_ enabled: Bool, ifRevision revision: String) throws -> Bool {
    try synchronized {
      guard try snapshotLocked().revision == revision else { return false }
      try setRecordingLocked(enabled)
      return true
    }
  }

  private func url(_ name: String) -> URL { directoryURL.appendingPathComponent(name) }

  private func synchronized<T>(prepareHistory: Bool = true, _ operation: () throws -> T) throws -> T
  {
    let deadline = ProcessInfo.processInfo.systemUptime + lockTimeout
    while !lock.try() {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw AppDiagnosticAccessError.busy
      }
      Thread.sleep(forTimeInterval: 0.002)
    }
    defer { lock.unlock() }
    return try { () throws -> T in
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      guard try directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
      else {
        throw CocoaError(.fileWriteNoPermission)
      }
      var directory = directoryURL
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
      let descriptor = Darwin.open(
        url(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
      defer { Darwin.close(descriptor) }
      while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
          throw CocoaError(.fileWriteUnknown)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
          throw AppDiagnosticAccessError.busy
        }
        Thread.sleep(forTimeInterval: 0.002)
      }
      defer { flock(descriptor, LOCK_UN) }
      if prepareHistory {
        try discardAbandonedShares()
        try migrateOwnedHistory()
        try migrateLegacy()
      }
      return try operation()
    }()
  }

  /// Scope-owned history is consumed repeatedly; completion gates preference adoption.
  /// Clear discards pending imports, including later writes in rediscovered sandboxes.
  /// Unreadable files retry; readable sources are consumed after ID/count deduplication.
  private func migrateOwnedHistory() throws {
    for sourceURL in priorDirectoryURLs
    where sourceURL.standardizedFileURL != directoryURL.standardizedFileURL {
      let namespace = sourceURL.deletingLastPathComponent().lastPathComponent
      let key = SHA256.hash(data: Data(namespace.utf8)).prefix(8).map { String(format: "%02x", $0) }
        .joined()
      let marker = url("migration-owned-\(key).complete")
      guard exists(sourceURL),
        (try? sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
      else { continue }
      let source = AppDiagnosticEventStore(
        directoryURL: sourceURL, policy: policy,
        appVersion: appVersion, appBuild: appBuild, now: now, lockTimeout: lockTimeout)
      let optOutPending = url("migration-off-\(key).pending")
      if exists(marker), !exists(optOutPending), !source.exists(source.url("aggregate.json")),
        !source.exists(source.url("diagnostic-sync-health.txt")),
        (try? source.segments().isEmpty) == true
      { continue }
      if exists(optOutPending)
        || (!exists(marker) && !exists(url("recording.json"))
          && source.exists(source.url("recording.json")) && !source.recordingEnabledLocked)
      {
        // Adopt an old opt-out only once, before taking the source history lock.
        // This keeps early extension evidence private even while the source is busy.
        // A pending marker retries any interrupted purge before the next export.
        try Data("1\n".utf8).write(to: optOutPending, options: .atomic)
        try setRecordingLocked(false)
        for file in (try segments()) + [
          url("aggregate.json"), url("diagnostic-sync-health.txt"),
        ] { try remove(file) }
        try remove(optOutPending)
      }
      do {
        try source.synchronized(prepareHistory: false) {
          if source.exists(source.url("aggregate.json")),
            source.read(source.url("aggregate.json"), limit: Self.recordLimit) == nil
          {
            throw CocoaError(.fileReadUnknown)
          }
          let incomingHealth = try source.healthLines()
          let incoming = try source.recordsLocked()
          let existing = Dictionary(
            try recordsLocked().map { ($0.id, $0.count) }, uniquingKeysWith: max)
          let discardPending = try controlFence()?.clearedAt != nil
          for record in incoming.sorted(by: { $0.last < $1.last })
          where !discardPending && existing[record.id, default: 0] < record.count
          {
            try appendRecord(record)
          }
          if !discardPending, !incomingHealth.isEmpty { try mergeHealth(incomingHealth) }
          try cleanup()
          // Delete only after every source was readable and every destination write
          // succeeded. Partial deletion is safe: the next pass deduplicates by ID.
          for file in try source.segments() { try source.remove(file) }
          try source.remove(source.url("aggregate.json"))
          try source.remove(source.url("diagnostic-sync-health.txt"))
          try Data("1\n".utf8).write(to: marker, options: .atomic)
        }
      } catch {
        // Leave busy/unreadable sources for retry while shared recording/export continues.
        continue
      }
    }
  }

  /// Imports at most 64 KiB per owned legacy file; a persisted clear discards pending
  /// sources regardless of record dates. Stable IDs deduplicate interrupted imports.
  private func migrateLegacy() throws {
    guard !exists(url(legacyMigrationMarker)), recordingEnabledLocked else { return }
    var roots = [directoryURL] + priorDirectoryURLs.filter {
      (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
    }
    if let legacyDirectoryURL,
      legacyDirectoryURL.standardizedFileURL != directoryURL.standardizedFileURL,
      (try? legacyDirectoryURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    {
      roots.append(legacyDirectoryURL)
    }
    let discardPending = try controlFence()?.clearedAt != nil
    var consumed: [URL] = []
    var needsRetry = false
    var recoveredHealth: [String: Record] = [:]
    var sidecarHealth: [String: Record] = [:]
    for root in roots {
      for name in ["attachment-events.txt", "diagnostic-events.txt", "diagnostic-sync-health.txt"]
      where name != "diagnostic-sync-health.txt" || root == directoryURL || !priorDirectoryURLs.contains(root)
      {
        let source = root.appendingPathComponent(name)
        var occurrences: [String: Int] = [:]
        var imported: [Record] = []
        let completed: Bool
        do {
          completed = try forEachLine(source, byteLimit: 64 * 1_024, allowTrailing: true) { data in
            guard
              let line = String(data: data, encoding: .utf8).flatMap(AppDiagnosticLine.sanitize),
              let timestamp = line.split(separator: " ").first,
              let date = try? Date(String(timestamp), strategy: .iso8601)
            else { return }
            let occurrence = occurrences[line, default: 0]
            occurrences[line] = occurrence + 1
            let digest = SHA256.hash(data: Data("legacy:\(line):\(occurrence)".utf8))
            let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
            let indices = [0, 8, 12, 16, 20, 32].map { hex.index(hex.startIndex, offsetBy: $0) }
            let id = (0..<5).map { String(hex[indices[$0]..<indices[$0 + 1]]) }.joined(
              separator: "-")
            guard let uuid = UUID(uuidString: id) else { return }
            var record = Record(
              id: uuid, first: date, last: date, count: 1, line: line,
              version: "unknown", build: "unknown", os: os)
            record.severity = Record.severity(for: line)
            imported.append(record)
          }
        } catch {
          needsRetry = true
          continue
        }
        if !completed { needsRetry = true }
        for record in imported where !discardPending {
          if name != "diagnostic-sync-health.txt",
            record.last >= now().addingTimeInterval(-policy.retentionAge)
          {
            try appendRecord(record)
          }
          if let key = healthKey(record.line) {
            if name == "diagnostic-sync-health.txt" {
              if sidecarHealth[key].map({ $0.last >= record.last }) != true { sidecarHealth[key] = record }
            } else if recoveredHealth[key].map({ $0.last >= record.last }) != true {
              recoveredHealth[key] = record
            }
          }
        }
        if completed, name != "diagnostic-sync-health.txt" || root != directoryURL,
          (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        {
          consumed.append(source)
        }
      }
    }
    let importedHealth = recoveredHealth.values.map(\.line) + sidecarHealth.values.map(\.line)
    if !importedHealth.isEmpty { try mergeHealth(importedHealth) }
    if !needsRetry {
      try Data("1\n".utf8).write(to: url(legacyMigrationMarker), options: .atomic)
    }
    for source in consumed { try? remove(source) }
    try cleanup()
  }

  private var recordingEnabledLocked: Bool { (try? recordingPreference()) ?? false }

  private func recordingPreference() throws -> Bool {
    guard let data = read(url("recording.json"), limit: 64) else {
      guard !exists(url("recording.json")) else { throw CocoaError(.fileReadUnknown) }
      return true
    }
    if data == Data("enabled\n".utf8) { return true }
    if data == Data("disabled\n".utf8) { return false }
    throw CocoaError(.fileReadCorruptFile)
  }

  private func controlFence() throws -> ControlFence? {
    guard exists(url("submission-fence.json")) else { return nil }
    guard let data = read(url("submission-fence.json"), limit: 512) else {
      throw CocoaError(.fileReadUnknown)
    }
    let result = try JSONDecoder().decode(ControlFence.self, from: data)
    guard result.submission.uptime.isFinite, result.submission.uptime >= 0 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return result
  }

  private func advanceFence(clearing: Bool = false) throws {
    let fence = ControlFence(
      submission: .capture(), clearedAt: clearing ? now() : try controlFence()?.clearedAt)
    try JSONEncoder().encode(fence).write(to: url("submission-fence.json"), options: .atomic)
    let token = Data(UUID().uuidString.utf8)
    try token.write(to: url("clear-token"), options: .atomic)
    contextClearToken = token
    context.removeAll()
  }

  private func setRecordingLocked(_ enabled: Bool) throws {
    try advanceFence()
    try Data((enabled ? "enabled\n" : "disabled\n").utf8).write(
      to: url("recording.json"), options: .atomic)
  }

  private func pending() -> Record? {
    guard let data = read(url("aggregate.json"), limit: Self.recordLimit),
      let record = try? JSONDecoder().decode(Record.self, from: data)
    else { return nil }
    return validated(record)
  }

  private func flushPending() throws {
    if let record = pending(), record.count > 1 { try appendRecord(record) }
    try remove(url("aggregate.json"))
  }

  private func appendRecord(_ record: Record) throws {
    let data = try JSONEncoder().encode(record) + Data([10])
    guard data.count <= Self.recordLimit, data.count <= policy.segmentBytes else { return }
    let stream = record.protected ? "protected" : "routine"
    let files = try segments().filter { $0.lastPathComponent.hasPrefix(stream) }
    var destination = files.last
    if let current = destination {
      let first = segmentDate(current)
      if size(current) + data.count > policy.segmentBytes || record.last < first
        || record.last.timeIntervalSince(first) >= policy.segmentAge || !endsInNewline(current)
        || !segmentMatchesBuild(current, record: record)
      {
        destination = nil
      }
    }
    if destination == nil {
      destination = url(
        "\(stream)-\(Int64(record.last.timeIntervalSince1970 * 1000))-\(UUID().uuidString).jsonl")
      FileManager.default.createFile(atPath: destination!.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: destination!)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  private func segmentMatchesBuild(_ url: URL, record incoming: Record) -> Bool {
    var matches = false
    _ = try? forEachLine(url, byteLimit: Self.recordLimit, allowTrailing: false) { data in
      guard !matches, let record = try? JSONDecoder().decode(Record.self, from: data) else {
        return
      }
      matches = record.version == incoming.version && record.build == incoming.build
    }
    return matches
  }

  private func write(_ record: Record, to url: URL) throws {
    let data = try JSONEncoder().encode(record)
    guard data.count <= Self.recordLimit else { return }
    try data.write(to: url, options: .atomic)
  }

  private func segments() throws -> [URL] {
    let entries = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    return entries.filter {
      let name = $0.lastPathComponent
      return (name.hasPrefix("routine-") || name.hasPrefix("protected-"))
        && name.hasSuffix(".jsonl")
        && name.count <= 100
        && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }.sorted {
      segmentDate($0) == segmentDate($1)
        ? $0.lastPathComponent < $1.lastPathComponent : segmentDate($0) < segmentDate($1)
    }
  }

  private func segmentDate(_ url: URL) -> Date {
    let fields = url.lastPathComponent.split(separator: "-")
    return Date(
      timeIntervalSince1970: (fields.count > 1 ? Double(fields[1]) : nil).map { $0 / 1000 } ?? 0)
  }

  private func cleanup() throws {
    let cutoff = now().addingTimeInterval(-policy.retentionAge)
    for stream in ["routine", "protected"] {
      var files = try segments().filter { $0.lastPathComponent.hasPrefix(stream) }
      for file in files {
        if size(file) > policy.segmentBytes {
          try remove(file)
          continue
        }
        guard segmentDate(file) < cutoff else { continue }
        // Expiry is uncommon and rewrites at most one bounded segment, never the history.
        var retained = Data()
        var firstDate: Date?
        _ = try forEachLine(file, byteLimit: policy.segmentBytes, allowTrailing: false) { data in
          guard let decoded = try? JSONDecoder().decode(Record.self, from: data),
            let record = validated(decoded), record.first >= cutoff
          else { return }
          firstDate = min(firstDate ?? record.first, record.first)
          retained.append(data)
          retained.append(10)
        }
        if retained.isEmpty {
          try remove(file)
        } else if let firstDate {
          let replacement = url(
            "\(stream)-\(Int64(firstDate.timeIntervalSince1970 * 1000))-\(UUID().uuidString).jsonl")
          try retained.write(to: replacement, options: .atomic)
          try remove(file)
        }
      }
      files = try segments().filter { $0.lastPathComponent.hasPrefix(stream) }
      // Sidecars and duplicated aggregate/context bytes belong to the history budget too.
      let overhead =
        [
          "aggregate.json", "diagnostic-sync-health.txt", "recording.json", "migration-complete",
          "clear-token", "submission-fence.json",
        ].reduce(0) { $0 + size(url($1)) }
        + ((try? FileManager.default.contentsOfDirectory(
          at: directoryURL, includingPropertiesForKeys: nil)) ?? [])
        .filter {
          $0.lastPathComponent.hasPrefix("migration-")
            && ["complete", "pending"].contains($0.pathExtension)
        }
        .reduce(0) { $0 + size($1) }
      let budget =
        stream == "protected"
        ? max(0, policy.protectedBytes - overhead)
        : max(0, policy.historyBytes - policy.protectedBytes)
      var bytes = files.reduce(0) { $0 + size($1) }
      while bytes > budget || files.count > 128 {
        guard let first = files.first else { break }
        bytes -= size(first)
        try remove(first)
        files.removeFirst()
      }
    }
    if let record = pending(), record.first < cutoff { try remove(url("aggregate.json")) }
    context.removeAll { $0.first < cutoff }
  }

  /// Recognizes only names generated here, including the earlier flat-file layout.
  private static func stageOwner(_ name: String) -> Int32? {
    let stem = name.hasSuffix(".txt") ? String(name.dropLast(4)) : name
    guard stem.hasPrefix("share-") else { return nil }
    let parts = stem.dropFirst(6).split(separator: "-", maxSplits: 1)
    guard parts.count == 2, let process = Int32(parts[0]), process > 0,
      parts[1].count == 73
    else { return nil }
    let ids = String(parts[1])
    guard UUID(uuidString: String(ids.prefix(36))) != nil,
      ids[ids.index(ids.startIndex, offsetBy: 36)] == "-",
      UUID(uuidString: String(ids.suffix(36))) != nil
    else { return nil }
    return process
  }

  private func stagedFiles() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
      .filter { Self.stageOwner($0.lastPathComponent) != nil }
  }

  private func stagedByteCount(_ stage: URL) -> Int {
    stage.pathExtension == "txt"
      ? size(stage) : size(stage.appendingPathComponent("Snip-Snap-Diagnostics.txt"))
  }

  private func discardAbandonedShares() throws {
    for file in try stagedFiles() {
      guard let process = Self.stageOwner(file.lastPathComponent) else { continue }
      if (process == getpid() && !file.lastPathComponent.contains(Self.session))
        || (Darwin.kill(process, 0) != 0 && errno == ESRCH)
      {
        try remove(file)
      }
    }
  }

  private func exportLocked(range: AppDiagnosticExportRange) throws -> URL {
    let staged = try stagedFiles()
    guard staged.count < 32 else { throw CocoaError(.fileWriteOutOfSpace) }
    let used = staged.reduce(0) { $0 + stagedByteCount($1) }
    let budget = min(policy.exportBytes, max(0, policy.stagingBytes - used))
    let data = try renderLocked(range: range, budget: budget).data
    let stage = url("share-\(getpid())-\(Self.session)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
    let destination = stage.appendingPathComponent("Snip-Snap-Diagnostics.txt")
    do { try data.write(to: destination, options: .atomic) } catch {
      try? remove(stage)
      throw error
    }
    return destination
  }

  func removeShareableFile(_ fileURL: URL) {
    guard fileURL.isFileURL else { return }
    let file = fileURL.standardizedFileURL
    let root = directoryURL.standardizedFileURL
    let parent = file.deletingLastPathComponent()
    // Completed exports are immutable and uniquely named, so deleting one needs no
    // history lock. Concurrent exports may overcount removed bytes, never undercount
    // retained shares. Anchor deletion to directory descriptors without following
    // root/stage symlinks, and never recursively remove unexpected contents.
    let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { return }
    defer { Darwin.close(rootDescriptor) }
    if file.lastPathComponent == "Snip-Snap-Diagnostics.txt",
      Self.stageOwner(parent.lastPathComponent) != nil,
      parent.deletingLastPathComponent() == root
    {
      let stageDescriptor = Darwin.openat(
        rootDescriptor, parent.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      guard stageDescriptor >= 0 else { return }
      defer { Darwin.close(stageDescriptor) }
      Darwin.unlinkat(stageDescriptor, file.lastPathComponent, 0)
      Darwin.unlinkat(rootDescriptor, parent.lastPathComponent, AT_REMOVEDIR)
    } else if parent == root,
      Self.stageOwner(file.lastPathComponent) != nil
        || file.lastPathComponent == "Snip-Snap-Diagnostics.txt"
    {
      Darwin.unlinkat(rootDescriptor, file.lastPathComponent, 0)
    }
  }

  /// CLI cleanup can target a different app bundle. Restrict it to Foundation-resolved
  /// diagnostic namespaces or the explicitly isolated directory, never arbitrary paths.
  static func removeOwnedShareableFile(_ fileURL: URL) {
    guard fileURL.isFileURL else { return }
    let file = fileURL.standardizedFileURL
    let parent = file.deletingLastPathComponent()
    let root: URL
    if file.lastPathComponent == "Snip-Snap-Diagnostics.txt",
      stageOwner(parent.lastPathComponent) != nil
    {
      root = parent.deletingLastPathComponent()
    } else if stageOwner(file.lastPathComponent) != nil
      || file.lastPathComponent == "Snip-Snap-Diagnostics.txt"
    {
      root = parent
    } else {
      return
    }
    let environment = ProcessInfo.processInfo.environment
    if let isolated = environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"], isolated.hasPrefix("/") {
      guard root == URL(fileURLWithPath: isolated, isDirectory: true).standardizedFileURL else {
        return
      }
    } else {
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      guard root.lastPathComponent == "SnipSnapDiagnostics",
        support.contains(where: {
          $0.standardizedFileURL == root.deletingLastPathComponent().deletingLastPathComponent()
        })
      else { return }
    }
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    AppDiagnosticEventStore(directoryURL: root, appVersion: "unknown", appBuild: "unknown")
      .removeShareableFile(file)
  }

  private func renderLocked(
    range: AppDiagnosticExportRange, budget: Int,
    eventLimit: Int? = nil, errorsOnly: Bool = false
  ) throws
    -> (data: Data, returned: Int, truncated: Bool)
  {
    try cleanup()
    let records = try recordsLocked()
    let cutoff = now().addingTimeInterval(range == .last24Hours ? -86_400 : -7 * 86_400)
    let matching = records.filter {
      $0.last >= cutoff && (!errorsOnly || $0.line.contains("outcome=failed"))
    }
    let selected: [Record]
    if let eventLimit {
      selected = Array(
        matching.sorted {
          $0.last == $1.last ? $0.id.uuidString < $1.id.uuidString : $0.last > $1.last
        }.prefix(eventLimit))
    } else {
      selected = matching
    }
    let available = records.map(\.first).min().map { $0.ISO8601Format() } ?? "none"
    let latest = records.map(\.last).max().map { $0.ISO8601Format() } ?? "none"
    var contents =
      "Snip Snap diagnostics\nformat=4 app_version=\(appVersion) app_build=\(appBuild) os=\(os)\n"
      + "privacy=structured-operational-events-only\nrecording_enabled=\(recordingEnabledLocked) OSLog=separate\n"
      + "selected_range=\(range.rawValue) available_first=\(available) available_last=\(latest)\n"
      + "coverage=best-effort; gaps possible from expiry, caps, disabled recording, writer overflow, or disk failure\n"
    for line in (try? healthLines()) ?? [] {
      let marker =
        line.contains("operation=sync.snapshot")
        ? "diagnostic_sync_latest" : "diagnostic_sync_last_success"
      contents += line.replacingOccurrences(of: " diagnostic_event ", with: " \(marker) ") + "\n"
    }
    let notice = "truncated=true; some selected events omitted by event limit or byte budget\n"
    let limit = max(0, budget)
    guard contents.utf8.count + notice.utf8.count <= limit else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
    var retained: [Record] = []
    var bytes = contents.utf8.count + notice.utf8.count
    // Failures and their bounded context get first use of the export budget.
    let ordered =
      eventLimit == nil
      ? selected.sorted(by: {
        if $0.exportPriority != $1.exportPriority { return $0.exportPriority > $1.exportPriority }
        return $0.last == $1.last ? $0.id.uuidString < $1.id.uuidString : $0.last > $1.last
      }) : selected
    for record in ordered {
      let count = record.rendered.utf8.count + 1
      if bytes + count <= limit {
        retained.append(record)
        bytes += count
      }
    }
    let truncated = retained.count < matching.count
    if truncated { contents += notice }
    for record in retained.sorted(by: {
      $0.last == $1.last ? $0.id.uuidString < $1.id.uuidString : $0.last < $1.last
    }) { contents += record.rendered + "\n" }
    return (Data(contents.utf8), retained.count, truncated)
  }

  private func recordsLocked() throws -> [Record] {
    var records: [UUID: Record] = [:]
    let cutoff = now().addingTimeInterval(-policy.retentionAge)
    for file in try segments() {
      _ = try forEachLine(file, byteLimit: policy.segmentBytes, allowTrailing: false) { data in
        guard let decoded = try? JSONDecoder().decode(Record.self, from: data),
          let record = validated(decoded), record.last >= cutoff
        else { return }
        if records[record.id].map({ $0.count >= record.count }) != true {
          records[record.id] = record
        }
      }
    }
    if let record = pending(), record.last >= cutoff { records[record.id] = record }
    return Array(records.values)
  }

  private func validated(_ input: Record) -> Record? {
    guard input.schema == 1, input.severity == Record.severity(for: input.line),
      input.count > 0, input.first <= input.last,
      input.first.timeIntervalSince1970.isFinite, input.last.timeIntervalSince1970.isFinite,
      abs(input.first.timeIntervalSince1970) < 253_402_300_800,
      abs(input.last.timeIntervalSince1970) < 253_402_300_800,
      let line = AppDiagnosticLine.sanitize(input.line),
      Record.safeVersion(input.version) == input.version,
      Record.safeVersion(input.build) == input.build,
      input.os == os
        || input.os.range(
          of: "^(macOS|iOS)-[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$", options: .regularExpression)
          != nil
    else { return nil }
    var record = input
    record.line = line
    return record
  }

  private func healthLines() throws -> [String] {
    let file = url("diagnostic-sync-health.txt")
    guard let data = read(file, limit: 4_096) else {
      guard !exists(file) else { throw CocoaError(.fileReadUnknown) }
      return []
    }
    return Array(data.split(separator: 10).compactMap {
      String(data: $0, encoding: .utf8).flatMap(AppDiagnosticLine.sanitize)
    }.filter { healthKey($0) != nil }.suffix(4))
  }

  private func healthKey(_ line: String) -> String? {
    let fields = line.split(separator: " ")
    guard fields.contains("outcome=succeeded") else { return nil }
    if fields.contains("operation=sync.snapshot") {
      if fields.contains("scope=transport") { return "transport" }
      if fields.contains("scope=records") { return "records" }
    }
    if fields.contains("operation=sync.fetch") { return "fetch" }
    if fields.contains("operation=sync.send") { return "send" }
    return nil
  }

  private func updateHealth(_ record: Record) throws {
    guard healthKey(record.line) != nil else { return }
    try writeHealth(((try? healthLines()) ?? []) + [record.line])
  }

  private func mergeHealth(_ incoming: [String]) throws {
    // Stable sorting leaves destination observations last when timestamps tie.
    let observations = (incoming + (try healthLines())).compactMap { line -> (date: Date, line: String)? in
      guard let timestamp = line.split(separator: " ").first,
        let date = try? Date(String(timestamp), strategy: .iso8601) else { return nil }
      return (date, line)
    }
    try writeHealth(observations.sorted { $0.date < $1.date }.map(\.line))
  }

  private func writeHealth(_ lines: [String]) throws {
    var health: [String: String] = [:]
    for line in lines { if let key = healthKey(line) { health[key] = line } }
    let orderedHealth = ["transport", "records", "fetch", "send"].compactMap { health[$0] }
    try Data((orderedHealth.joined(separator: "\n") + "\n").utf8)
      .write(to: url("diagnostic-sync-health.txt"), options: .atomic)
  }

  private func snapshotLocked() throws -> AppDiagnosticExportSnapshot {
    let data = try renderLocked(range: .last24Hours, budget: policy.exportBytes).data
    var hash = SHA256()
    hash.update(data: Data("\(appVersion):\(appBuild):\(os):\(recordingEnabledLocked)".utf8))
    for file in (try segments()) + [
      url("aggregate.json"), url("diagnostic-sync-health.txt"), url("recording.json"),
      url("clear-token"), url("submission-fence.json"),
    ] {
      guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
      defer { try? handle.close() }
      var remaining = max(policy.segmentBytes, Self.recordLimit)
      while remaining > 0, let chunk = try handle.read(upToCount: min(remaining, 16_384)),
        !chunk.isEmpty
      {
        hash.update(data: chunk)
        remaining -= chunk.count
      }
    }
    return AppDiagnosticExportSnapshot(
      byteCount: data.count, revision: hash.finalize().map { String(format: "%02x", $0) }.joined())
  }

  private func clearLocked() throws {
    // Invalidate queued submissions and context held by other processes first.
    try advanceFence(clearing: true)
    for file in (try segments()) + [
      url("aggregate.json"), url("diagnostic-sync-health.txt"), url("diagnostic-events.txt"),
      url("attachment-events.txt"), url("Snip-Snap-Diagnostics.txt"),
    ] { try remove(file) }
    for file in try stagedFiles() { try remove(file) }
    if let legacyDirectoryURL,
      legacyDirectoryURL.standardizedFileURL != directoryURL.standardizedFileURL,
      (try? legacyDirectoryURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    {
      for name in [
        "diagnostic-events.txt", "attachment-events.txt", "diagnostic-sync-health.txt",
        "Snip-Snap-Diagnostics.txt",
      ] {
        let file = legacyDirectoryURL.appendingPathComponent(name)
        if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
          try remove(file)
        }
      }
    }
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
  private func size(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }
  private func remove(_ url: URL) throws {
    if exists(url) { try FileManager.default.removeItem(at: url) }
  }
  private func read(_ url: URL, limit: Int) -> Data? {
    guard
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ]),
      values.isRegularFile == true, values.isSymbolicLink != true,
      (values.fileSize ?? Int.max) <= limit
    else { return nil }
    return try? Data(contentsOf: url)
  }

  private func endsInNewline(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let count = try? handle.seekToEnd(), count > 0,
      (try? handle.seek(toOffset: count - 1)) != nil,
      let data = try? handle.read(upToCount: 1)
    else { return false }
    return data == Data([10])
  }

  /// Returns false when the byte budget stops the read before EOF. A clipped final
  /// line is never delivered. Missing/unsupported sources have nothing to import;
  /// actual metadata, open, and read failures throw so migration can retry safely.
  @discardableResult
  private func forEachLine(
    _ url: URL, byteLimit: Int, allowTrailing: Bool, body: (Data) -> Void
  ) throws -> Bool {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return true
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true else { return true }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var remaining = max(0, byteLimit)
    var line = Data()
    var oversized = false
    var completed = false
    while remaining > 0 {
      let data = try handle.read(upToCount: min(16_384, remaining)) ?? Data()
      if data.isEmpty {
        completed = true
        break
      }
      remaining -= data.count
      for byte in data {
        if byte == 10 {
          if !oversized { body(line) }
          line.removeAll(keepingCapacity: true)
          oversized = false
        } else if line.count < Self.recordLimit {
          line.append(byte)
        } else {
          oversized = true
        }
      }
    }
    // One bounded lookahead distinguishes exact-budget EOF from truncation.
    if !completed { completed = (try handle.read(upToCount: 1) ?? Data()).isEmpty }
    if completed && allowTrailing && !oversized && !line.isEmpty { body(line) }
    return completed
  }
}
