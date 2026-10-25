import Darwin
import Dispatch
import Foundation
import XCTest

@testable import SnipSnapCore

final class AppDiagnosticRetentionTests: XCTestCase {
  func testUnreadableLegacySourceSurvivesAndRetriesWithoutDuplicatingImportedEvents() throws {
    let cache = directory.appendingPathComponent("cache")
    let durable = directory.appendingPathComponent("durable")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let source = cache.appendingPathComponent("diagnostic-events.txt")
    let healthy = cache.appendingPathComponent("attachment-events.txt")
    let line =
      "\(now.ISO8601Format()) diagnostic_event operation=sync.run outcome=failed visibility=user error=sync.accessDenied\n"
    try line.write(to: source, atomically: true, encoding: .utf8)
    try ("corrupt private text\n" + line).write(to: healthy, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
    }
    let store = AppDiagnosticEventStore(
      directoryURL: durable, appVersion: "1", appBuild: "2",
      legacyDirectoryURL: cache, now: { self.now })
    XCTAssertEqual(try store.readLog().returnedEvents, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: healthy.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: durable.appendingPathComponent("migration-complete").path))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
    XCTAssertEqual(try store.readLog().returnedEvents, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: durable.appendingPathComponent("migration-complete").path))
    XCTAssertEqual(try store.readLog().returnedEvents, 1)
  }

  func testBudgetLimitedLegacyReadKeepsSourceUntilEOFAndDoesNotImportClippedTail() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("diagnostic-events.txt")
    let line =
      "\(now.ISO8601Format()) diagnostic_event operation=app.startup outcome=succeeded visibility=background"
    let first = Data((line + "\n").utf8)
    var data = first + Data(repeating: 10, count: 65_536 - first.count - line.utf8.count)
    data.append(Data((line + " bytes=17\n").utf8))
    try data.write(to: source)
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    XCTAssertEqual(try store.readLog().returnedEvents, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    // Exact-budget EOF is complete, including a valid non-newline-terminated tail.
    data =
      first + Data(repeating: 10, count: 65_536 - first.count - (line + " bytes=17").utf8.count)
    data.append(Data((line + " bytes=17").utf8))
    try data.write(to: source)
    XCTAssertEqual(try store.readLog().returnedEvents, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(try store.readLog().returnedEvents, 2)
  }

  func testOfflineReadReturnsBoundedBusyWhenAnotherProcessHoldsLock() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-c",
      "import fcntl,sys,select; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('r',flush=True); select.select([sys.stdin],[],[],2)",
      directory.appendingPathComponent(".lock").path,
    ]
    let ready = Pipe()
    let release = Pipe()
    process.standardOutput = ready
    process.standardInput = release
    try process.run()
    defer {
      try? release.fileHandleForWriting.write(contentsOf: Data([10]))
      process.waitUntilExit()
    }
    XCTAssertEqual(try ready.fileHandleForReading.read(upToCount: 1), Data("r".utf8))
    let store = AppDiagnosticEventStore(directoryURL: directory, appVersion: "1", appBuild: "2")
    let start = ContinuousClock.now
    XCTAssertThrowsError(try store.readLog()) { error in
      XCTAssertEqual(error.localizedDescription, "Diagnostic history is busy. Try again shortly.")
    }
    XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
  }

  func testSameTimestampExportsHaveStableContentAndBudgetSelection() throws {
    var policy = AppDiagnosticRetentionPolicy()
    policy.exportBytes = 1_200
    policy.contextCount = 0
    let store = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy,
      appVersion: "1", appBuild: "2", now: { self.now })
    for index in 0..<20 {
      store.append(.succeeded(operation: "clipboard.persist", byteCount: Int64(index)))
    }
    let first = try store.makeShareableFile()
    let expected = Data(try store.readLog(limit: 200).text.utf8)
    XCTAssertEqual(try Data(contentsOf: first), expected)
    store.removeShareableFile(first)
    for _ in 0..<10 {
      let file = try store.makeShareableFile()
      XCTAssertEqual(try Data(contentsOf: file), expected)
      store.removeShareableFile(file)
    }
  }

  func testCompletedShareCleanupUnderExternalLockReleasesBudgetWhileOwnerIsAlive() throws {
    var policy = AppDiagnosticRetentionPolicy()
    policy.exportBytes = 800
    policy.stagingBytes = 800
    let store = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy,
      appVersion: "1", appBuild: "2", now: { self.now })
    store.append(.succeeded(operation: "app.startup"))
    let file = try store.makeShareableFile()
    XCTAssertThrowsError(try store.makeShareableFile())

    do {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = [
        "-c",
        "import fcntl,sys,select; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('r',flush=True); select.select([sys.stdin],[],[],5)",
        directory.appendingPathComponent(".lock").path,
      ]
      let ready = Pipe()
      let release = Pipe()
      process.standardOutput = ready
      process.standardInput = release
      try process.run()
      defer {
        try? release.fileHandleForWriting.write(contentsOf: Data([10]))
        process.waitUntilExit()
      }
      XCTAssertEqual(try ready.fileHandleForReading.read(upToCount: 1), Data("r".utf8))
      let start = ContinuousClock.now
      store.removeShareableFile(file)
      let duration = start.duration(to: .now)
      print("diagnostic_share_cleanup_duration=\(duration) external_history_lock=held")
      XCTAssertLessThan(duration, .milliseconds(200))
      XCTAssertTrue(process.isRunning)
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    // A live owner/session must not leave the completed share occupying the budget.
    XCTAssertEqual(try store.readLog().returnedEvents, 1)
    let next = try store.makeShareableFile()
    XCTAssertTrue(try String(contentsOf: next, encoding: .utf8).contains("operation=app.startup"))
    store.removeShareableFile(next)
    store.removeShareableFile(next)
    XCTAssertFalse(FileManager.default.fileExists(atPath: next.deletingLastPathComponent().path))
  }

  func testShareCleanupDoesNotFollowRootStageOrFileSymlinks() throws {
    let root = directory.appendingPathComponent("root")
    let store = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2", now: { self.now })
    let file = try store.makeShareableFile()
    let stage = file.deletingLastPathComponent()
    let original = try Data(contentsOf: file)

    let movedRoot = directory.appendingPathComponent("moved-root")
    try FileManager.default.moveItem(at: root, to: movedRoot)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: movedRoot)
    store.removeShareableFile(file)
    XCTAssertEqual(try Data(contentsOf: file), original)
    try FileManager.default.removeItem(at: root)
    try FileManager.default.moveItem(at: movedRoot, to: root)

    let movedStage = directory.appendingPathComponent("moved-stage")
    try FileManager.default.moveItem(at: stage, to: movedStage)
    try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: movedStage)
    store.removeShareableFile(file)
    XCTAssertEqual(
      try Data(contentsOf: movedStage.appendingPathComponent(file.lastPathComponent)), original)
    try FileManager.default.removeItem(at: stage)
    try FileManager.default.moveItem(at: movedStage, to: stage)

    let unrelated = directory.appendingPathComponent("notes.txt")
    try Data("keep".utf8).write(to: unrelated)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: unrelated)
    store.removeShareableFile(file)
    XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
    XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
  }

  func testShareCleanupLeavesUnexpectedStageContentsIntact() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    let file = try store.makeShareableFile()
    let unrelated = file.deletingLastPathComponent().appendingPathComponent("notes.txt")
    try Data("keep".utf8).write(to: unrelated)
    store.removeShareableFile(file)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
  }

  func testUserFailureRecordsKeepTheirSpecificOperationAndCode() {
    let shortcut = AppDiagnosticEvent.failure(
      operation: "shortcut.register",
      errorCode: "shortcut.registrationFailed", visibility: .user)
    XCTAssertEqual(shortcut.operation, "shortcut.register")
    XCTAssertEqual(shortcut.errorCode, "shortcut.registrationFailed")
    let capture = AppDiagnosticEvent.failure(
      operation: "selection.capture",
      errorCode: "selection.sourceUnavailable", visibility: .user)
    XCTAssertEqual(capture.operation, "selection.capture")
    XCTAssertEqual(capture.errorCode, "selection.sourceUnavailable")
    let account = AppDiagnosticEvent.failure(
      operation: "sync.account_refresh",
      errorCode: "sync.checkingAccount", visibility: .background)
    XCTAssertEqual(account.operation, "sync.account_refresh")
    XCTAssertEqual(account.errorCode, "sync.checkingAccount")
  }

  func testMigrationKeepsAllSmallLegacyEventsWithinTheHistoryBudget() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let history = (0..<140).map { index in
      "\(now.addingTimeInterval(Double(index - 1_000)).ISO8601Format()) diagnostic_event operation=clipboard.persist outcome=succeeded visibility=background bytes=\(index)\n"
    }.joined()
    try history.write(
      to: directory.appendingPathComponent("diagnostic-events.txt"), atomically: true,
      encoding: .utf8)
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "2", appBuild: "9", now: { self.now })
    let report = try String(contentsOf: store.makeShareableFile(range: .last7Days), encoding: .utf8)
    XCTAssertTrue(
      report.contains("bytes=0 "),
      "A small legacy history must not lose its earliest event during migration")
    XCTAssertTrue(report.contains("bytes=139 "))
    XCTAssertEqual(report.components(separatedBy: " diagnostic_event ").count - 1, 140)
  }

  private var directory: URL!
  private let now = Date(timeIntervalSince1970: 1_792_800_000)

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testYesterdayFailureSurvivesRoutineFloodAndRelaunch() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    store.append(
      .failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .background),
      at: now.addingTimeInterval(-86_400))
    for _ in 0..<2_000 {
      store.append(.succeeded(operation: "clipboard.persist"), at: now)
    }
    let reopened = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    let export = try String(
      contentsOf: reopened.makeShareableFile(range: .last7Days), encoding: .utf8)
    XCTAssertTrue(export.contains("error=sync.accessDenied"))
    XCTAssertTrue(export.contains("count=2000"))
  }
  func testLegacyMigrationSanitizesAndConsumesOnlyOwnedCache() throws {
    let cache = directory.appendingPathComponent("bundle-cache")
    let durable = directory.appendingPathComponent("durable")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let legacy = cache.appendingPathComponent("diagnostic-events.txt")
    try
      "\(now.ISO8601Format()) diagnostic_event operation=sync.run outcome=failed visibility=background error=PrivateFilename\n"
      .write(to: legacy, atomically: true, encoding: .utf8)
    let store = AppDiagnosticEventStore(
      directoryURL: durable, appVersion: "1", appBuild: "2",
      legacyDirectoryURL: cache, now: { self.now })
    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertTrue(export.contains("error=other.UnknownError"))
    XCTAssertFalse(export.contains("PrivateFilename"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertEqual(
      try durable.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    try store.clear()
    XCTAssertFalse(
      try String(contentsOf: store.makeShareableFile(), encoding: .utf8).contains(
        "diagnostic_event"))
  }

  func testIndependentSharesAndSnapshotsDoNotOverwriteActiveExports() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    store.append(.succeeded(operation: "app.startup"))
    let first = try store.makeShareableFile()
    let firstData = try Data(contentsOf: first)
    store.append(.succeeded(operation: "clipboard.persist"))
    let second = try store.makeShareableFile(range: .last7Days)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(first.lastPathComponent, "Snip-Snap-Diagnostics.txt")
    XCTAssertEqual(second.lastPathComponent, "Snip-Snap-Diagnostics.txt")
    XCTAssertEqual(try Data(contentsOf: first), firstData)
    store.removeShareableFile(first)
    XCTAssertTrue(try String(contentsOf: second, encoding: .utf8).contains("clipboard.persist"))
    _ = try store.snapshot()
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
  }

  func testExpiryRemovesOldRecordsFromMixedAgeSegmentOnDisk() throws {
    var clock = now.addingTimeInterval(-7 * 86_400 - 3_600)
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { clock })
    store.append(.succeeded(operation: "clipboard.persist", byteCount: 111))
    clock = now.addingTimeInterval(-7 * 86_400 + 3_600)
    store.append(.succeeded(operation: "clipboard.persist", byteCount: 222))
    clock = now
    let export = try String(contentsOf: store.makeShareableFile(range: .last7Days), encoding: .utf8)
    XCTAssertFalse(export.contains("bytes=111"))
    XCTAssertTrue(export.contains("bytes=222"))
    for file in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    where file.pathExtension == "jsonl" {
      XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("bytes=111"))
    }
  }

  func testMigrationRecoversLatestSuccessAndSidecarWins() throws {
    for hasSidecar in [false, true] {
      let root = directory.appendingPathComponent(String(hasSidecar))
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let first = now.addingTimeInterval(-20).ISO8601Format()
      let last = now.addingTimeInterval(-10).ISO8601Format()
      let sidecar = now.addingTimeInterval(-5).ISO8601Format()
      let event = "diagnostic_event operation=sync.fetch outcome=succeeded visibility=background"
      try "\(first) \(event)\n\(last) \(event)\n"
        .write(
          to: root.appendingPathComponent("diagnostic-events.txt"), atomically: true,
          encoding: .utf8)
      if hasSidecar {
        try "\(sidecar) \(event)\n".write(
          to: root.appendingPathComponent("diagnostic-sync-health.txt"), atomically: true,
          encoding: .utf8)
      }
      let store = AppDiagnosticEventStore(
        directoryURL: root, appVersion: "1", appBuild: "2", now: { self.now })
      let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
      XCTAssertTrue(export.contains("\(hasSidecar ? sidecar : last) diagnostic_sync_last_success"))
    }
  }

  func testRepeatedFailuresKeepCountTimestampsAndSeverityAcrossRelaunch() throws {
    let first = now.addingTimeInterval(-30)
    let event = AppDiagnosticEvent.failure(
      operation: "sync.run", errorCode: "sync.accessDenied", visibility: .background)
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    store.append(event, at: first)
    store.append(event, at: now)
    let reopened = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    let export = try String(contentsOf: reopened.makeShareableFile(), encoding: .utf8)
    XCTAssertTrue(
      export.contains("count=2 first=\(first.ISO8601Format()) last=\(now.ISO8601Format())"))
    XCTAssertTrue(export.contains("severity=error"))
    XCTAssertEqual(export.components(separatedBy: "error=sync.accessDenied").count - 1, 1)
  }

  func testRecordingControlsPersistAndRejectStaleChangesWithoutCrossingIsolation() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    let before = try store.snapshot()
    XCTAssertTrue(try store.setRecordingEnabled(false, ifRevision: before.revision))
    XCTAssertFalse(try store.setRecordingEnabled(true, ifRevision: before.revision))
    let reopened = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    XCTAssertFalse(try reopened.readRecordingEnabled())
    reopened.append(
      .failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .background))
    let disabled = try String(contentsOf: reopened.makeShareableFile(), encoding: .utf8)
    XCTAssertFalse(disabled.contains("diagnostic_event"))
    XCTAssertTrue(disabled.contains("recording_enabled=false OSLog=separate"))
    let separate = AppDiagnosticEventStore(
      directoryURL: directory.appendingPathComponent("isolated"),
      appVersion: "1", appBuild: "2", now: { self.now })
    XCTAssertTrue(try separate.readRecordingEnabled())
    try reopened.clear()
    XCTAssertFalse(try reopened.readRecordingEnabled())
    try reopened.setRecordingEnabled(true)
    reopened.append(.succeeded(operation: "app.startup"))
    XCTAssertTrue(
      try String(contentsOf: reopened.makeShareableFile(), encoding: .utf8).contains(
        "operation=app.startup"))
  }

  func testSegmentMetadataSurvivesUpgradeAndSegmentsRollAtSizeOrDay() throws {
    var clock = now.addingTimeInterval(-2 * 86_400)
    var policy = AppDiagnosticRetentionPolicy()
    policy.segmentBytes = 1_024
    policy.contextCount = 0
    let old = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy,
      appVersion: "1", appBuild: "2", now: { clock })
    old.append(
      .failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .background))
    clock.addTimeInterval(86_400)
    old.append(.succeeded(operation: "app.startup"))
    let upgraded = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy,
      appVersion: "2", appBuild: "3", now: { clock })
    for index in 0..<12 {
      upgraded.append(.succeeded(operation: "clipboard.persist", byteCount: Int64(index)))
    }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey]
    )
    .filter { $0.pathExtension == "jsonl" }
    XCTAssertGreaterThan(files.count, 3)
    for file in files {
      XCTAssertLessThanOrEqual(
        try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize), 1_024)
    }
    let encoded = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    XCTAssertTrue(encoded.contains("\"schema\":1"))
    XCTAssertTrue(encoded.contains("\"severity\":\"error\""))
    let export = try String(
      contentsOf: upgraded.makeShareableFile(range: .last7Days), encoding: .utf8)
    XCTAssertTrue(export.contains("app_version=1 app_build=2"))
    XCTAssertTrue(export.contains("app_version=2 app_build=3"))
    XCTAssertTrue(export.contains("os=macOS-") || export.contains("os=iOS-"))
  }

  func testRoutineAndFailureFloodsRespectIndependentBudgetsIncludingContext() throws {
    var policy = AppDiagnosticRetentionPolicy()
    policy.historyBytes = 24 * 1_024
    policy.protectedBytes = 12 * 1_024
    policy.segmentBytes = 2_048
    policy.contextCount = 2
    policy.exportBytes = 16 * 1_024
    let store = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy,
      appVersion: "1", appBuild: "2", now: { self.now })
    store.append(
      .syncSnapshot(scope: .transport, pendingEvents: 7), at: now.addingTimeInterval(-86_400))
    store.append(
      .failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .background),
      at: now.addingTimeInterval(-86_400))
    for index in 0..<120 {
      store.append(.succeeded(operation: "clipboard.persist", byteCount: Int64(index)))
    }
    let before = try String(contentsOf: store.makeShareableFile(range: .last7Days), encoding: .utf8)
    XCTAssertTrue(before.contains("error=sync.accessDenied"))
    XCTAssertTrue(before.contains("diagnostic_sync_latest"))
    for index in 0..<120 {
      store.append(
        .failure(
          operation: "sync.run", errorCode: "cloudkit.23", visibility: .background,
          retryAfterSeconds: Double(index)))
    }
    let after = try String(contentsOf: store.makeShareableFile(range: .last7Days), encoding: .utf8)
    XCTAssertFalse(after.contains("error=sync.accessDenied"))
    XCTAssertTrue(after.contains("retry_after=119.0"))
    XCTAssertTrue(after.contains("bytes=119"))
    XCTAssertTrue(after.contains("context=true"))
    XCTAssertTrue(after.contains("diagnostic_sync_latest"))
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey]
    )
    .filter { $0.pathExtension != "txt" && !$0.lastPathComponent.hasPrefix("share-") }
    let bytes = try files.reduce(0) {
      try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    XCTAssertLessThanOrEqual(bytes, 24 * 1_024)
  }

  func testLogFiltersBeforeLimitAndReturnsNewestFailuresWithoutStaging() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    for index in 1...3 {
      store.append(
        .failure(
          operation: "sync.run", errorCode: "cloudkit.23",
          visibility: index.isMultiple(of: 2) ? .user : .background,
          retryAfterSeconds: Double(index)), at: now.addingTimeInterval(Double(index - 10)))
    }
    store.append(.succeeded(operation: "clipboard.persist"))
    let report = try store.readLog(range: .last24Hours, limit: 2, errorsOnly: true)
    XCTAssertEqual(report.returnedEvents, 2)
    XCTAssertTrue(report.truncated)
    XCTAssertFalse(report.text.contains("retry_after=1.0"))
    XCTAssertFalse(report.text.contains("operation=clipboard.persist"))
    let second = try XCTUnwrap(report.text.range(of: "retry_after=2.0"))
    let third = try XCTUnwrap(report.text.range(of: "retry_after=3.0"))
    XCTAssertLessThan(second.lowerBound, third.lowerBound)
    XCTAssertTrue(report.text.contains("truncated=true"))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .contains { $0.lastPathComponent.hasPrefix("share-") })
    XCTAssertThrowsError(try store.readLog(limit: 0))
    XCTAssertThrowsError(try store.readLog(limit: 2_001))
  }

  func testBundleReadFactoryUsesExplicitIsolationAndNeedsNoLiveSink() throws {
    let key = "SNIP_SNAP_DIAGNOSTICS_DIRECTORY"
    let original = ProcessInfo.processInfo.environment[key]
    setenv(key, directory.path, 1)
    defer {
      if let original { setenv(key, original, 1) } else { unsetenv(key) }
    }
    let store = AppDiagnosticEventStore(directoryURL: directory, appVersion: "1", appBuild: "2")
    store.append(.succeeded(operation: "app.startup"))
    let report = try AppDiagnosticsExport.readLog(
      bundleIdentifier: "org.example.offline.dev",
      appVersion: "2", appBuild: "3", limit: 20)
    XCTAssertTrue(report.text.contains("operation=app.startup"))
    XCTAssertTrue(report.text.contains("format=4 app_version=2 app_build=3"))
    XCTAssertEqual(report.returnedEvents, 1)
    XCTAssertFalse(report.truncated)
    let shared = try store.makeShareableFile()
    AppDiagnosticsExport.removeShareableFile(shared)
    XCTAssertFalse(FileManager.default.fileExists(atPath: shared.deletingLastPathComponent().path))
    let saved = directory.appendingPathComponent("saved", isDirectory: true)
    try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: false)
    let savedCopy = saved.appendingPathComponent("Snip-Snap-Diagnostics.txt")
    try Data("user copy".utf8).write(to: savedCopy)
    AppDiagnosticsExport.removeShareableFile(savedCopy)
    XCTAssertEqual(try String(contentsOf: savedCopy, encoding: .utf8), "user copy")
  }

  func testCorruptOversizedAndPartialRecordsDoNotHideGoodEventsOrLeakInput() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    store.append(.succeeded(operation: "app.startup"))
    let segment = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.pathExtension == "jsonl" })
    let original = try Data(contentsOf: segment)
    let firstLine = Data(try XCTUnwrap(original.split(separator: 10).first))
    var invalidDate = try XCTUnwrap(JSONSerialization.jsonObject(with: firstLine) as? [String: Any])
    invalidDate["id"] = UUID().uuidString
    invalidDate["first"] = 1e300
    invalidDate["last"] = 1e300
    let file = try FileHandle(forWritingTo: segment)
    try file.seekToEnd()
    try file.write(contentsOf: JSONSerialization.data(withJSONObject: invalidDate) + Data([10]))
    try file.write(contentsOf: Data("{broken}\n".utf8))
    try file.write(contentsOf: Data(repeating: 97, count: 100_000))
    try file.write(contentsOf: Data("\n{\"private_path\":\"/private/fixture/secret.txt".utf8))
    try file.close()
    store.append(.succeeded(operation: "clipboard.persist"))
    let report = try store.readLog()
    XCTAssertTrue(report.text.contains("operation=app.startup"))
    XCTAssertTrue(report.text.contains("operation=clipboard.persist"))
    XCTAssertEqual(report.returnedEvents, 2)
    XCTAssertFalse(report.text.contains("private"))
    XCTAssertFalse(report.text.contains("broken"))
    try store.clear()
    let reportAfterClear = try store.readLog()
    XCTAssertEqual(reportAfterClear.returnedEvents, 0)
  }

  func testClearFromAnotherStoreCannotRestoreOldInMemoryContext() throws {
    let first = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    let second = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    first.append(.succeeded(operation: "clipboard.persist"))
    try second.clear()
    first.append(.failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user))
    let report = try first.readLog()
    XCTAssertTrue(report.text.contains("error=sync.accessDenied"))
    XCTAssertFalse(report.text.contains("operation=clipboard.persist"))
  }

  func testExportRangeTruncationAndTotalStagingBudgetPreserveExistingShares() throws {
    var clock = now.addingTimeInterval(-2 * 86_400)
    var policy = AppDiagnosticRetentionPolicy()
    policy.exportBytes = 1_200
    policy.stagingBytes = 2_000
    policy.contextCount = 0
    let store = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy,
      appVersion: "1", appBuild: "2", now: { clock })
    store.append(.failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user))
    clock = now
    for index in 0..<20 {
      store.append(.succeeded(operation: "clipboard.persist", byteCount: Int64(index)))
    }
    let recent = try store.makeShareableFile()
    let recentData = try Data(contentsOf: recent)
    let recentText = String(decoding: recentData, as: UTF8.self)
    XCTAssertFalse(recentText.contains("error=sync.accessDenied"))
    XCTAssertTrue(recentText.contains("truncated=true"))
    XCTAssertTrue(
      recentText.contains("available_first=\(now.addingTimeInterval(-2 * 86_400).ISO8601Format())"))
    let week = try store.makeShareableFile(range: .last7Days)
    let weekData = try Data(contentsOf: week)
    XCTAssertTrue(String(decoding: weekData, as: UTF8.self).contains("error=sync.accessDenied"))
    XCTAssertLessThanOrEqual(recentData.count + weekData.count, 2_000)
    XCTAssertThrowsError(try store.makeShareableFile())
    XCTAssertEqual(try Data(contentsOf: recent), recentData)
    store.removeShareableFile(recent)
    _ = try store.makeShareableFile()
    try store.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: week.path))
  }

  func testGuardedMutationsRejectChangesOmittedFromDefaultReport() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    store.append(
      .succeeded(operation: "clipboard.persist", byteCount: 1),
      at: now.addingTimeInterval(-3 * 86_400))
    store.append(
      .succeeded(operation: "clipboard.persist", byteCount: 2),
      at: now.addingTimeInterval(-2 * 86_400))
    store.append(.succeeded(operation: "app.startup"))
    let before = try store.snapshot()
    store.append(
      .succeeded(operation: "clipboard.persist", byteCount: 3),
      at: now.addingTimeInterval(-2.5 * 86_400))
    let after = try store.snapshot()
    XCTAssertEqual(after.byteCount, before.byteCount)
    XCTAssertNotEqual(after.revision, before.revision)
    XCTAssertFalse(try store.clear(ifRevision: before.revision))
    XCTAssertFalse(try store.setRecordingEnabled(false, ifRevision: before.revision))
    XCTAssertTrue(try store.readRecordingEnabled())
  }

  func testFailedDiskAndSettingWritesAreSafeAndCanBeRetried() throws {
    try Data("occupied".utf8).write(to: directory)
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    store.append(.succeeded(operation: "app.startup"))
    XCTAssertThrowsError(try store.readLog())
    XCTAssertEqual(try String(contentsOf: directory, encoding: .utf8), "occupied")
    try FileManager.default.removeItem(at: directory)
    try store.setRecordingEnabled(true)
    store.append(.succeeded(operation: "app.startup"))
    let preference = directory.appendingPathComponent("recording.json")
    try FileManager.default.removeItem(at: preference)
    try FileManager.default.createDirectory(at: preference, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.setRecordingEnabled(false))
    XCTAssertThrowsError(try store.readRecordingEnabled())
    try FileManager.default.removeItem(at: preference)
    try store.setRecordingEnabled(true)
    XCTAssertTrue(try store.readRecordingEnabled())
    XCTAssertTrue(try store.readLog().text.contains("operation=app.startup"))
  }

  func testConcurrentStoreInstancesSerializeAppendsWithoutLostEvents() throws {
    let first = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    let second = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let descriptor = Darwin.open(
      directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }

    // Force both production pumps past the bounded lock deadline. Observe their
    // retry timers while preserving the production scheduling and backoff.
    let retries = [
      expectation(description: "first writer retry"),
      expectation(description: "second writer retry"),
    ]
    retries.forEach { $0.assertForOverFulfill = false }
    let writers = [first, second].enumerated().map { index, store in
      AppDiagnosticWriter(store: store) { delay, run in
        retries[index].fulfill()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: run)
      }
    }
    let timestamp = now
    DispatchQueue.concurrentPerform(iterations: 60) { index in
      writers[index % 2].submit(
        .succeeded(operation: "clipboard.persist", byteCount: Int64(index)),
        at: timestamp.addingTimeInterval(Double(index - 60)))
    }
    guard XCTWaiter.wait(for: retries, timeout: 5) == .completed else {
      XCTFail("Both writers must encounter contention and schedule a retry")
      return
    }
    guard flock(descriptor, LOCK_UN) == 0 else { throw CocoaError(.fileWriteUnknown) }

    // Do not explicitly flush: automatic retries must retain and persist every
    // accepted submission, including its original timestamp, after contention.
    var report: AppDiagnosticLogReport?
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    repeat {
      do {
        report = try first.readLog(limit: 200)
      } catch AppDiagnosticAccessError.busy {
        // A writer may hold the same file lock while draining its retained batch.
      }
      if report?.returnedEvents == 60 { break }
      Thread.sleep(forTimeInterval: 0.02)
    } while ContinuousClock.now < deadline
    let recovered = try XCTUnwrap(report, "History must become readable before the deadline")
    XCTAssertEqual(recovered.returnedEvents, 60)
    XCTAssertFalse(recovered.truncated)
    let lines = recovered.text.split(separator: "\n")
    for index in 0..<60 {
      let line = lines.first { $0.contains("bytes=\(index) schema=1") }
      XCTAssertNotNil(line, "Missing event \(index)")
      XCTAssertTrue(
        line?.hasPrefix("\(timestamp.addingTimeInterval(Double(index - 60)).ISO8601Format()) ")
          == true,
        "Missing original timestamp for event \(index)")
    }
  }

  func testShareCleanupRejectsUnownedPathsAndRemovesAbandonedDirectories() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let abandoned = directory.appendingPathComponent(
      "share-1999999999-\(UUID().uuidString)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
    try Data("old".utf8).write(to: abandoned.appendingPathComponent("Snip-Snap-Diagnostics.txt"))
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    _ = try store.snapshot()
    XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    let file = try store.makeShareableFile()
    store.removeShareableFile(file)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    let unowned = directory.appendingPathComponent("notes.txt")
    try Data("keep".utf8).write(to: unowned)
    store.removeShareableFile(unowned)
    XCTAssertEqual(try String(contentsOf: unowned, encoding: .utf8), "keep")
  }

}
