import Dispatch
import Darwin
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

  func testExternalControlsKeepOnlyFreshIdenticalFailuresOnProductionRetry() async throws {
    for clear in [true, false] {
      let history = directory.appendingPathComponent(clear ? "clear" : "off-on")
      let store = AppDiagnosticEventStore(
        directoryURL: history, appVersion: "1", appBuild: "2",
        now: { self.now }, lockTimeout: 0.01)
      let retries = DiagnosticRetryClock()
      let writer = AppDiagnosticWriter(store: store, scheduleRetry: retries.schedule)
      let share = AppDiagnosticScope(store: store, writer: writer)
      let app = AppDiagnosticScope(store: AppDiagnosticEventStore(
        directoryURL: history, appVersion: "1", appBuild: "2", now: { self.now }))
      let held = try DiagnosticProcessLock(directory: history)
      writer.submit(.succeeded(operation: "app.startup"), at: now.addingTimeInterval(-20))
      let retry = try retries.next() // The blocked batch leaves subsequent events pending.
      let failure = AppDiagnosticEvent.failure(
        operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user)
      writer.submit(failure, at: now.addingTimeInterval(-10))
      writer.submit(failure, at: now.addingTimeInterval(-9))
      held.release()
      if clear {
        try app.clear()
      } else {
        try app.setRecordingEnabled(false)
        writer.submit(failure, at: now.addingTimeInterval(-5))
        try app.setRecordingEnabled(true)
      }
      writer.submit(failure, at: now.addingTimeInterval(-2))
      writer.submit(failure, at: now.addingTimeInterval(-1))
      retry.run()
      let flushed = await share.recorder.flush(timeout: 1)
      XCTAssertTrue(flushed)
      let report = try app.readLog()
      XCTAssertEqual(report.returnedEvents, 1)
      XCTAssertEqual(eventCount(report.text), 2)
      XCTAssertTrue(report.text.contains("error=cocoa.513"))
      XCTAssertTrue(report.text.contains("first=\(now.addingTimeInterval(-2).ISO8601Format())"))
      XCTAssertTrue(report.text.contains("last=\(now.addingTimeInterval(-1).ISO8601Format())"))
      XCTAssertFalse(report.text.contains("operation=app.startup"))
      XCTAssertFalse(report.text.contains(now.addingTimeInterval(-10).ISO8601Format()))
    }
  }

  func testExternalControlsSplitMixedOverflowCountsWithoutDroppingFreshLosses() async throws {
    for clear in [true, false] {
      let history = directory.appendingPathComponent(clear ? "loss-clear" : "loss-off-on")
      var policy = AppDiagnosticRetentionPolicy()
      policy.contextCount = 0
      let store = AppDiagnosticEventStore(
        directoryURL: history, policy: policy, appVersion: "1", appBuild: "2",
        now: { self.now }, lockTimeout: 0.01)
      let retries = DiagnosticRetryClock()
      let writer = AppDiagnosticWriter(store: store, capacity: 2, scheduleRetry: retries.schedule)
      let app = AppDiagnosticScope(store: AppDiagnosticEventStore(
        directoryURL: history, policy: policy, appVersion: "1", appBuild: "2", now: { self.now }))
      let held = try DiagnosticProcessLock(directory: history)
      writer.submit(.succeeded(operation: "app.startup"), at: now.addingTimeInterval(-20))
      let retry = try retries.next()
      let firstFailure = AppDiagnosticEvent.failure(
        operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user)
      let secondFailure = AppDiagnosticEvent.failure(
        operation: "share.extension_load", errorCode: "cocoa.260", visibility: .user)
      writer.submit(firstFailure, at: now.addingTimeInterval(-10))
      writer.submit(secondFailure, at: now.addingTimeInterval(-10))
      for index in 0..<80 {
        writer.submit(.succeeded(operation: "clipboard.persist", byteCount: Int64(index)),
          at: now.addingTimeInterval(-9))
        writer.submit(.failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user),
          at: now.addingTimeInterval(-9))
      }
      held.release()
      if clear {
        try app.clear()
      } else {
        try app.setRecordingEnabled(false)
        try app.setRecordingEnabled(true)
      }
      // Both event slots are still occupied, so these become loss occurrences.
      // Alternate categories to exercise independently bounded accounting chunks.
      for index in 0..<3 {
        writer.submit(.succeeded(operation: "clipboard.persist", byteCount: Int64(index)),
          at: now.addingTimeInterval(Double(index) - 3))
        writer.submit(.failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user),
          at: now.addingTimeInterval(Double(index) - 3))
      }
      // Repeated fresh failures in occupied slots must retain their own metadata.
      writer.submit(secondFailure, at: now.addingTimeInterval(-2))
      writer.submit(secondFailure, at: now.addingTimeInterval(-1))
      retry.run()
      let flushed = await writer.flush(timeout: 1)
      XCTAssertTrue(flushed)
      let report = try app.readLog()
      XCTAssertEqual(eventCount(report.text), 8)
      for code in ["diagnostics.routineOverflow", "diagnostics.failureOverflow"] {
        let line = try XCTUnwrap(report.text.split(separator: "\n").first { $0.contains("error=\(code)") })
        XCTAssertTrue(line.contains("count=3"))
        XCTAssertTrue(line.contains("first=\(now.addingTimeInterval(-3).ISO8601Format())"))
        XCTAssertTrue(line.contains("last=\(now.addingTimeInterval(-1).ISO8601Format())"))
      }
      XCTAssertTrue(report.text.contains("operation=share.extension_load"))
      XCTAssertFalse(report.text.contains("operation=share.extension_save"))
      XCTAssertFalse(report.text.contains("operation=app.startup"))
      XCTAssertFalse(report.text.contains(now.addingTimeInterval(-9).ISO8601Format()))
    }
  }

  func testOverflowPrefixCutByClearReportsUnknownRemainderAndExactFreshTail() async throws {
    var policy = AppDiagnosticRetentionPolicy()
    policy.contextCount = 0
    let store = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy, appVersion: "1", appBuild: "2",
      now: { self.now }, lockTimeout: 0.01)
    let retries = DiagnosticRetryClock()
    let writer = AppDiagnosticWriter(store: store, capacity: 1, scheduleRetry: retries.schedule)
    let app = AppDiagnosticScope(store: AppDiagnosticEventStore(
      directoryURL: directory, policy: policy, appVersion: "1", appBuild: "2", now: { self.now }))
    let held = try DiagnosticProcessLock(directory: directory)
    writer.submit(.succeeded(operation: "app.startup"), at: now.addingTimeInterval(-20))
    let retry = try retries.next()
    writer.submit(.failure(operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user),
      at: now.addingTimeInterval(-10))
    for index in 0..<100 {
      writer.submit(.succeeded(operation: "clipboard.persist", byteCount: Int64(index)),
        at: now.addingTimeInterval(-9))
    }
    held.release()
    try app.clear()
    for index in 0..<100 {
      writer.submit(.succeeded(operation: "clipboard.persist", byteCount: Int64(index)),
        at: now.addingTimeInterval(Double(index) / 100 - 2))
    }
    retry.run()
    let flushed = await writer.flush(timeout: 1)
    XCTAssertTrue(flushed)
    let report = try app.readLog()
    let loss = try XCTUnwrap(report.text.split(separator: "\n").first {
      $0.contains("error=diagnostics.routineOverflow")
    })
    // The 64 latest known occurrences remain exact. The older mixed prefix
    // gets one missing-diagnostics marker, never its old+fresh combined count.
    XCTAssertTrue(loss.contains("count=64"))
    XCTAssertTrue(loss.contains("first=\(now.addingTimeInterval(-1.64).ISO8601Format())"))
    XCTAssertTrue(loss.contains("last=\(now.addingTimeInterval(-1.01).ISO8601Format())"))
    XCTAssertTrue(report.text.contains("operation=diagnostics.recording outcome=missing"))
    XCTAssertFalse(report.text.contains("count=200"))
    XCTAssertFalse(report.text.contains(now.addingTimeInterval(-9).ISO8601Format()))
    XCTAssertFalse(report.text.contains("operation=share.extension_save"))
  }

  func testCompoundSelectionKeepsProcessLockUntilAllRecordsArePersisted() throws {
    var policy = AppDiagnosticRetentionPolicy()
    policy.contextCount = 0
    let contender = try DiagnosticSelectionContender(directory: directory)
    defer { contender.release() }
    let gate = DiagnosticSelectionClock(date: now, directory: directory, contender: contender)
    let store = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy, appVersion: "1", appBuild: "2",
      now: gate.read, lockTimeout: 0.05)
    var prefix = AppDiagnosticOccurrence(stamp: .capture(), date: now.addingTimeInterval(-10))
    try store.clear()
    prefix.merge(.init(stamp: .capture(), date: now.addingTimeInterval(-2)))
    let occurrences = [prefix, AppDiagnosticOccurrence(stamp: .capture(), date: now.addingTimeInterval(-1))]
    let loss = AppDiagnosticEvent.failure(
      operation: "diagnostics.recording", errorCode: "diagnostics.routineOverflow", visibility: .background)
    var busy = false
    do {
      try store.appendThrowing(loss, occurrences: occurrences)
    } catch AppDiagnosticAccessError.busy {
      busy = true
    }
    try gate.check()
    let observed = try contender.observation()
    contender.release()
    // The writer retains and replays the entire submission on .busy.
    if busy { try store.appendThrowing(loss, occurrences: occurrences) }
    XCTAssertFalse(busy, "Contention after a persisted marker must not fail a compound append")
    XCTAssertTrue(observed.contains("error=diagnostics.routineOverflow"),
      "A process acquiring the history lock must see the complete compound selection")
    let report = try store.readLog()
    XCTAssertEqual(eventCount(report.text), 3) // One incomplete interval and two exact retained occurrences.
    let marker = try XCTUnwrap(report.text.split(separator: "\n").first { $0.contains("outcome=missing") })
    XCTAssertFalse(marker.contains("count="), "Retry must not duplicate the incomplete-interval marker")
    let retained = try XCTUnwrap(report.text.split(separator: "\n").first {
      $0.contains("error=diagnostics.routineOverflow")
    })
    XCTAssertTrue(retained.contains("count=2"))
  }

  func testUncertainWritesAfterClearCountOnlyFreshOccurrences() async throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2",
      now: { self.now }, lockTimeout: 0.01)
    let retries = DiagnosticRetryClock()
    let writer = AppDiagnosticWriter(store: store, scheduleRetry: retries.schedule)
    let app = AppDiagnosticScope(store: AppDiagnosticEventStore(
      directoryURL: directory, appVersion: "1", appBuild: "2", now: { self.now }))
    let held = try DiagnosticProcessLock(directory: directory)
    writer.submit(.succeeded(operation: "app.startup"), at: now.addingTimeInterval(-20))
    let retry = try retries.next()
    let failure = AppDiagnosticEvent.failure(
      operation: "share.extension_save", errorCode: "cocoa.513", visibility: .user)
    writer.submit(failure, at: now.addingTimeInterval(-10))
    held.release()
    try app.clear()
    writer.submit(failure, at: now.addingTimeInterval(-2))
    writer.submit(failure, at: now.addingTimeInterval(-1))
    let blockedLock = directory.appendingPathComponent(".lock")
    try FileManager.default.removeItem(at: blockedLock)
    try FileManager.default.createDirectory(at: blockedLock, withIntermediateDirectories: false)
    retry.run()
    let blockedBatch = try retries.next()
    blockedBatch.run() // The old batch and mixed pending submission each fail finitely.
    let recovery = try retries.next()
    try FileManager.default.removeItem(at: blockedLock)
    recovery.run()
    let flushed = await writer.flush(timeout: 1)
    XCTAssertTrue(flushed)
    let report = try app.readLog()
    let loss = try XCTUnwrap(report.text.split(separator: "\n").first {
      $0.contains("error=diagnostics.writeFailed")
    })
    XCTAssertTrue(loss.contains("count=2"))
    XCTAssertTrue(loss.contains("first=\(now.addingTimeInterval(-2).ISO8601Format())"))
    XCTAssertTrue(loss.contains("last=\(now.addingTimeInterval(-1).ISO8601Format())"))
    XCTAssertFalse(report.text.contains(now.addingTimeInterval(-10).ISO8601Format()))
    XCTAssertFalse(report.text.contains("operation=app.startup"))
  }

  func testExactOccurrenceCapacityFallsBackToExplicitCountedFailureLoss() async throws {
    var policy = AppDiagnosticRetentionPolicy()
    policy.contextCount = 0
    let store = AppDiagnosticEventStore(
      directoryURL: directory, policy: policy, appVersion: "1", appBuild: "2",
      now: { self.now }, lockTimeout: 0.01)
    let retries = DiagnosticRetryClock()
    let writer = AppDiagnosticWriter(store: store, capacity: 1, scheduleRetry: retries.schedule)
    let held = try DiagnosticProcessLock(directory: directory)
    writer.submit(.succeeded(operation: "app.startup"), at: now.addingTimeInterval(-1))
    let retry = try retries.next()
    let start = ContinuousClock.now
    for index in 0..<3_000 {
      writer.submit(.failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user),
        at: now.addingTimeInterval(Double(index) / 100))
    }
    XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    held.release()
    retry.run()
    let flushed = await writer.flush(timeout: 1)
    XCTAssertTrue(flushed)
    let report = try writer.perform { try store.readLog() }
    let failure = try XCTUnwrap(report.text.split(separator: "\n").first {
      $0.contains("error=sync.accessDenied")
    })
    let loss = try XCTUnwrap(report.text.split(separator: "\n").first {
      $0.contains("error=diagnostics.failureOverflow")
    })
    XCTAssertTrue(failure.contains("count=2048"))
    XCTAssertTrue(failure.contains("first=\(now.ISO8601Format())"))
    XCTAssertTrue(failure.contains("last=\(now.addingTimeInterval(20.47).ISO8601Format())"))
    XCTAssertTrue(loss.contains("count=952"))
    XCTAssertTrue(loss.contains("first=\(now.addingTimeInterval(20.48).ISO8601Format())"))
    XCTAssertTrue(loss.contains("last=\(now.addingTimeInterval(29.99).ISO8601Format())"))
    XCTAssertEqual(eventCount(report.text), 3_001)
    XCTAssertFalse(report.text.contains("outcome=missing"))
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

/// The existing clock seam runs cleanup after the first selected record is on disk.
private final class DiagnosticSelectionClock {
  private let date: Date
  private let directory: URL
  private let contender: DiagnosticSelectionContender
  private var started = false
  private var failure: Error?

  init(date: Date, directory: URL, contender: DiagnosticSelectionContender) {
    self.date = date
    self.directory = directory
    self.contender = contender
  }

  func read() -> Date {
    if !started,
      let data = try? Data(contentsOf: directory.appendingPathComponent("aggregate.json")),
      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      (record["line"] as? String)?.contains("outcome=missing") == true
    {
      started = true
      do { try contender.start() } catch { failure = error }
    }
    return date
  }

  func check() throws {
    XCTAssertTrue(started, "The contender must start after marker persistence")
    if let failure { throw failure }
  }
}

/// A real process contends for flock, then inspects persistence under that lock.
private final class DiagnosticSelectionContender {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let observed: URL
  private var released = false

  init(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    observed = directory.appendingPathComponent("contender-observation.txt")
    process.environment = ["PATH": "/usr/bin:/bin"]
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", """
      import fcntl, pathlib, select, signal, sys, time
      signal.alarm(5)
      root = pathlib.Path(sys.argv[1])
      lock = (root / '.lock').open('a')
      print('r', end='', flush=True)
      sys.stdin.buffer.read(1)
      try:
          fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
          print('u', end='', flush=True)
      except BlockingIOError:
          print('b', end='', flush=True)
          deadline = time.monotonic() + 2
          while True:
              try:
                  fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                  break
              except BlockingIOError:
                  if time.monotonic() >= deadline:
                      raise TimeoutError('history lock remained busy')
      records = list(root.glob('*.jsonl')) + [root / 'aggregate.json']
      (root / 'contender-observation.txt').write_text('\\n'.join(p.read_text() for p in records if p.exists()))
      print('a', end='', flush=True)
      select.select([sys.stdin], [], [], 2)
      """, directory.path]
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    do { try expect("r") } catch { release(); throw error }
  }

  func start() throws {
    try input.fileHandleForWriting.write(contentsOf: Data([10]))
    try expect("b") // The first marker is persisted while the store still owns flock.
    // Let the contender begin its bounded acquisition loop before cleanup returns.
    Thread.sleep(forTimeInterval: 0.02)
  }

  func observation() throws -> String {
    try expect("a")
    return try String(contentsOf: observed, encoding: .utf8)
  }

  private func expect(_ byte: String) throws {
    var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
    guard Darwin.poll(&descriptor, 1, 2_000) > 0,
      try output.fileHandleForReading.read(upToCount: 1) == Data(byte.utf8)
    else { throw CocoaError(.fileReadUnknown) }
  }

  func release() {
    guard !released else { return }
    released = true
    try? input.fileHandleForWriting.write(contentsOf: Data([10]))
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
  }

  deinit { release() }
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
