import Dispatch
import Foundation
import XCTest

@testable import SnipSnapCore

final class AppDiagnosticWriterTests: XCTestCase {
  private var directory: URL!
  private let now = Date(timeIntervalSince1970: 1_792_800_000)

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testSubmissionDoesNotWaitForExternalLockAndFlushRetriesFailure() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2",
      now: { self.now }, lockTimeout: 0.05)
    let writer = AppDiagnosticWriter(store: store)
    let held = try DiagnosticProcessLock(directory: directory)
    let start = ContinuousClock.now
    writer.submit(
      .failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user), at: now)
    XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
    XCTAssertThrowsError(try writer.perform { try store.readLog() }) { error in
      XCTAssertTrue(error is AppDiagnosticAccessError)
    }
    held.release()
    let report = try writer.perform { try store.readLog() }
    XCTAssertEqual(report.returnedEvents, 1)
    XCTAssertTrue(report.text.contains("error=sync.accessDenied"))
    XCTAssertTrue(report.text.contains(now.ISO8601Format()))
  }

  func testBoundedStormRetainsFailureAndAccountsForEveryOmittedRoutineEvent() throws {
    var policy = AppDiagnosticRetentionPolicy()
    policy.contextCount = 0
    let store = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy,
      appVersion: "1", appBuild: "2", now: { self.now }, lockTimeout: 0.02)
    let writer = AppDiagnosticWriter(store: store, capacity: 4)
    let held = try DiagnosticProcessLock(directory: directory)
    let start = ContinuousClock.now
    for index in 0..<1_000 {
      writer.submit(.succeeded(operation: "clipboard.persist", byteCount: Int64(index)), at: now)
    }
    writer.submit(
      .failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user), at: now)
    XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
    held.release()
    let report = try writer.perform { try store.readLog() }
    XCTAssertLessThanOrEqual(report.returnedEvents, 14)  // bounded batch + pending, plus fixed loss categories
    XCTAssertTrue(report.text.contains("error=sync.accessDenied"))
    XCTAssertTrue(report.text.contains("error=diagnostics.routineOverflow"))
    XCTAssertEqual(eventCount(report.text), 1_001)
  }

  func testRepeatedQueuedFailuresPreserveSubmissionTimesAndCounts() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2",
      now: { self.now }, lockTimeout: 0.02)
    let writer = AppDiagnosticWriter(store: store, capacity: 4)
    let held = try DiagnosticProcessLock(directory: directory)
    for index in 0..<2_000 {
      writer.submit(
        .failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user),
        at: now.addingTimeInterval(Double(index) / 100))
    }
    held.release()
    let report = try writer.perform { try store.readLog() }
    XCTAssertEqual(report.returnedEvents, 1)
    XCTAssertTrue(report.text.contains("count=2000"))
    XCTAssertTrue(report.text.contains("first=\(now.ISO8601Format())"))
    XCTAssertTrue(report.text.contains("last=\(now.addingTimeInterval(19.99).ISO8601Format())"))
    XCTAssertFalse(report.text.contains("Overflow"))
  }

  func testFlushOrdersRecordingRevisionClearAndExportAroundSubmittedEvents() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    let writer = AppDiagnosticWriter(store: store)
    writer.submit(.succeeded(operation: "app.startup"), at: now)
    try writer.perform { try store.setRecordingEnabled(false) }
    writer.submit(.succeeded(operation: "clipboard.persist", byteCount: 10), at: now)
    try writer.perform { try store.setRecordingEnabled(true) }
    let before = try writer.perform { try store.snapshot() }
    writer.submit(
      .failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user), at: now)
    XCTAssertFalse(
      try writer.perform { try store.setRecordingEnabled(false, ifRevision: before.revision) })
    XCTAssertFalse(try writer.perform { try store.clear(ifRevision: before.revision) })
    let file = try writer.perform { try store.makeShareableFile() }
    let text = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(text.contains("operation=app.startup"))
    XCTAssertTrue(text.contains("error=sync.accessDenied"))
    XCTAssertFalse(text.contains("bytes=10"))
    try writer.perform { try store.clear() }
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    writer.submit(.succeeded(operation: "clipboard.persist", byteCount: 99), at: now)
    let after = try writer.perform { try store.makeShareableFile() }
    let afterText = try String(contentsOf: after, encoding: .utf8)
    XCTAssertTrue(afterText.contains("bytes=99"))
    XCTAssertFalse(afterText.contains("operation=app.startup"))
    XCTAssertFalse(afterText.contains("error=sync.accessDenied"))
  }

  func testFailureOverflowIsExplicitAndCounted() throws {
    var policy = AppDiagnosticRetentionPolicy()
    policy.contextCount = 0
    let store = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy,
      appVersion: "1", appBuild: "2", now: { self.now }, lockTimeout: 0.02)
    let writer = AppDiagnosticWriter(store: store, capacity: 4)
    let held = try DiagnosticProcessLock(directory: directory)
    for index in 0..<1_000 {
      writer.submit(
        .failure(
          operation: "sync.run",
          errorCode: index.isMultiple(of: 2) ? "sync.accessDenied" : "sync.appDataIssue",
          visibility: .user), at: now)
    }
    held.release()
    let report = try writer.perform { try store.readLog() }
    XCTAssertLessThanOrEqual(report.returnedEvents, 14)
    XCTAssertTrue(report.text.contains("error=diagnostics.failureOverflow"))
    XCTAssertEqual(eventCount(report.text), 1_000)
  }

  func testDiskFailureLeavesExplicitUncertainWriteCountAfterRecovery() throws {
    try Data("occupied".utf8).write(to: directory)
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    let writer = AppDiagnosticWriter(store: store)
    writer.submit(
      .failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user), at: now)
    XCTAssertThrowsError(try writer.perform { try store.readLog() })
    try FileManager.default.removeItem(at: directory)
    let report = try writer.perform { try store.readLog() }
    XCTAssertTrue(report.text.contains("error=diagnostics.writeFailed"))
    XCTAssertEqual(eventCount(report.text), 1)
  }

  func testUnavailableStorageBacksOffAndProgressResetsRetryWithoutLosingAccounting() throws {
    try Data("occupied".utf8).write(to: directory)
    let clock = DiagnosticRetryClock()
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now })
    let writer = AppDiagnosticWriter(store: store, scheduleRetry: clock.schedule)
    writer.submit(
      .failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user), at: now)
    for expected in [0.05, 0.1, 0.2, 0.4, 0.8, 1.6, 3.2, 5, 5] {
      let retry = try clock.next()
      XCTAssertEqual(retry.delay, expected, accuracy: 0.001)
      retry.run()
    }
    let recovery = try clock.next()
    try FileManager.default.removeItem(at: directory)
    recovery.run()
    let report = try writer.perform { try store.readLog() }
    XCTAssertTrue(report.text.contains("error=diagnostics.writeFailed"))
    XCTAssertEqual(eventCount(report.text), 1)
    try FileManager.default.removeItem(at: directory)
    try Data("occupied again".utf8).write(to: directory)
    writer.submit(
      .failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user), at: now)
    let reset = try clock.next()
    XCTAssertEqual(reset.delay, 0.05, accuracy: 0.001)
    try FileManager.default.removeItem(at: directory)
    reset.run()
    let recovered = try writer.perform { try store.readLog() }
    XCTAssertEqual(eventCount(recovered.text), 1)
  }

  func testContinuousProducerAllowsExportAndRecordingControlToFinish() throws {
    var policy = AppDiagnosticRetentionPolicy()
    policy.contextCount = 0
    let store = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy,
      appVersion: "1", appBuild: "2", now: { self.now })
    let writer = AppDiagnosticWriter(store: store, capacity: 4)
    let running = WriterProducerFlag()
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      var index: Int64 = 0
      started.signal()
      while running.value {
        writer.submit(.succeeded(operation: "clipboard.persist", byteCount: index))
        index += 1
      }
      finished.signal()
    }
    defer {
      running.stop()
      _ = finished.wait(timeout: .now() + 2)
    }
    XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
    let start = ContinuousClock.now
    let export = try writer.perform { try store.makeShareableFile() }
    try writer.perform { try store.setRecordingEnabled(false) }
    XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    XCTAssertTrue(running.value)
    XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
    XCTAssertFalse(try writer.perform { try store.readRecordingEnabled() })
  }

  func testSameInstanceMemoryLockSharesTheAcquisitionDeadline() throws {
    let gate = DiagnosticClockGate(date: now)
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2",
      now: gate.read, lockTimeout: 0.05)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = try? store.readLog()
      finished.signal()
    }
    defer {
      gate.release.signal()
      _ = finished.wait(timeout: .now() + 2)
    }
    XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)
    let start = ContinuousClock.now
    XCTAssertThrowsError(try store.readLog()) { error in
      XCTAssertTrue(error is AppDiagnosticAccessError)
    }
    XCTAssertLessThan(start.duration(to: .now), .milliseconds(200))
  }

  func testRecordingStateReadPropagatesExternalBusyAndPreservesEnabledPreference() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2",
      now: { self.now }, lockTimeout: 0.05)
    try store.setRecordingEnabled(true)
    let held = try DiagnosticProcessLock(directory: directory)
    XCTAssertThrowsError(try store.readRecordingEnabled()) { error in
      XCTAssertTrue(error is AppDiagnosticAccessError)
    }
    held.release()
    XCTAssertTrue(try store.readRecordingEnabled())
  }

  @MainActor
  func testPublicLiveRecorderDoesNotBlockMainActorOnExternalLock() throws {
    let previous = ProcessInfo.processInfo.environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"]
    setenv("SNIP_SNAP_DIAGNOSTICS_DIRECTORY", directory.path, 1)
    defer {
      if let previous {
        setenv("SNIP_SNAP_DIAGNOSTICS_DIRECTORY", previous, 1)
      } else {
        unsetenv("SNIP_SNAP_DIAGNOSTICS_DIRECTORY")
      }
    }
    let held = try DiagnosticProcessLock(directory: directory, holdSeconds: 2)
    let start = ContinuousClock.now
    AppDiagnosticRecorder.live.record(
      .failure(operation: "sync.run", error: AppDiagnosticAccessError.busy, visibility: .user))
    let duration = start.duration(to: .now)
    print("diagnostic_live_record_duration=\(duration) external_lock_seconds=2")
    XCTAssertLessThan(duration, .milliseconds(100))
    held.waitForExpiry()
    let report = try AppDiagnosticsExport.readLog()
    XCTAssertTrue(report.text.contains("error=diagnostics.busy"))
    try AppDiagnosticsExport.setRecordingEnabled(true)
    let preferenceLock = try DiagnosticProcessLock(directory: directory)
    XCTAssertThrowsError(try AppDiagnosticsExport.readRecordingEnabled()) { error in
      XCTAssertTrue(error is AppDiagnosticAccessError)
    }
    preferenceLock.release()
    XCTAssertTrue(try AppDiagnosticsExport.readRecordingEnabled())
    try AppDiagnosticsExport.clear()
  }

  private func eventCount(_ report: String) -> Int {
    report.split(separator: "\n").filter { $0.contains(" diagnostic_event ") }.reduce(0) {
      sum, line in
      let field = line.split(separator: " ").first { $0.hasPrefix("count=") }
      return sum + (field.flatMap { Int($0.dropFirst(6)) } ?? 1)
    }
  }
}

private final class WriterProducerFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var running = true
  var value: Bool { lock.withLock { running } }
  func stop() { lock.withLock { running = false } }
}

/// Controls the timer boundary without waiting for long retry delays in tests.
private final class DiagnosticRetryClock: @unchecked Sendable {
  private let lock = NSLock()
  private let ready = DispatchSemaphore(value: 0)
  private var retries: [(delay: TimeInterval, run: @Sendable () -> Void)] = []
  func schedule(_ delay: TimeInterval, _ run: @escaping @Sendable () -> Void) {
    lock.withLock { retries.append((delay, run)) }
    ready.signal()
  }
  func next() throws -> (delay: TimeInterval, run: @Sendable () -> Void) {
    guard ready.wait(timeout: .now() + 2) == .success else { throw CocoaError(.fileReadUnknown) }
    return lock.withLock { retries.removeFirst() }
  }
}

private final class DiagnosticClockGate: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var didBlock = false
  private let date: Date
  init(date: Date) { self.date = date }
  func read() -> Date {
    let shouldBlock = lock.withLock {
      if didBlock { return false }
      didBlock = true
      return true
    }
    if shouldBlock {
      entered.signal()
      _ = release.wait(timeout: .now() + 2)
    }
    return date
  }
}

/// A separate process is necessary: flock has different ownership from NSLock.
private final class DiagnosticProcessLock {
  private let process = Process()
  private let releasePipe = Pipe()
  private var released = false

  init(directory: URL, holdSeconds: Int = 10) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-c",
      "import fcntl,sys,select; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('r',flush=True); select.select([sys.stdin],[],[],int(sys.argv[2]))",
      directory.appendingPathComponent(".lock").path, String(holdSeconds),
    ]
    let ready = Pipe()
    process.standardOutput = ready
    process.standardInput = releasePipe
    try process.run()
    guard try ready.fileHandleForReading.read(upToCount: 1) == Data("r".utf8) else {
      throw CocoaError(.fileReadUnknown)
    }
  }

  func release() {
    guard !released else { return }
    released = true
    try? releasePipe.fileHandleForWriting.write(contentsOf: Data([10]))
    process.waitUntilExit()
  }

  func waitForExpiry() {
    process.waitUntilExit()
    released = true
  }

  deinit { release() }
}
