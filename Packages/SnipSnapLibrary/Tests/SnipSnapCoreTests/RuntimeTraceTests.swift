import Foundation
import Synchronization
import XCTest

@testable import SnipSnapCore

final class RuntimeTraceTests: XCTestCase {
  func testTraceObserverCanDeliverExpiryBeforeReturningFromGrantedEvent() throws {
    let callback = Mutex<(@Sendable () -> Void)?>(nil)
    let delivered = DispatchSemaphore(value: 0)
    let trace = RuntimeTrace(sink: { event in
      if event.phase == .protectionGranted {
        DispatchQueue.global().async {
          callback.withLock { $0 }?()
          delivered.signal()
        }
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success,
          "Trace observers must not run under the expiry state lock")
      }
    }).span(.diagnostics)
    do {
      let activity = try FileAccessBackgroundActivity.begin(runner: { expire in
        callback.withLock { $0 = expire }
        return {}
      }, trace: trace)
      activity?.finish()
    } catch is CancellationError {}
  }

  func testSharedAppendFailureReportsUncertaintyWhenAnEventAlreadyReachedDisk() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let backup = root.appendingPathExtension("backup")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: backup)
    }
    let aggregate = root.appendingPathComponent("aggregate.json")
    let injected = Mutex(false)
    let events = Mutex<[RuntimeTrace.Event]>([])
    let scheduled = DispatchSemaphore(value: 0)
    let store = AppDiagnosticEventStore(directoryURL: root, appVersion: "1", appBuild: "2", now: {
      if !injected.withLock({ $0 }), FileManager.default.fileExists(atPath: aggregate.path) {
        do {
          try FileManager.default.moveItem(at: root, to: backup)
          try Data("obstruction".utf8).write(to: root)
          injected.withLock { $0 = true }
        } catch { XCTFail("Could not inject cleanup failure: \(error)") }
      }
      return Date()
    })
    let writer = AppDiagnosticWriter(store: store, requiresReadableControls: true,
      scheduleRetry: { _, _ in scheduled.signal() },
      runtimeTrace: RuntimeTrace(sink: { event in events.withLock { $0.append(event) } }))
    writer.submit(.failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user))
    XCTAssertEqual(scheduled.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(injected.withLock { $0 })
    try FileManager.default.removeItem(at: root)
    try FileManager.default.moveItem(at: backup, to: root)
    let report = try writer.perform { try store.readLog() }
    XCTAssertEqual(report.returnedEvents, 1, "The event row was persisted before cleanup failed")
    let summary = try XCTUnwrap(events.withLock { $0 }.first { $0.phase == .writerLoss })
    XCTAssertEqual(summary.uncertain, 1)
    XCTAssertEqual(summary.dropped, 1, "Removal from the queue does not establish disk loss")
  }

  func testOverflowSummaryCountsOccurrencesAndDoesNotFeedTraceBackIntoDiagnosticHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let events = Mutex<[RuntimeTrace.Event]>([])
    let store = AppDiagnosticEventStore(directoryURL: root, appVersion: "1", appBuild: "2")
    let writer = AppDiagnosticWriter(store: store, capacity: 1,
      runtimeTrace: RuntimeTrace(sink: { event in events.withLock { $0.append(event) } }))
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { finished.signal() }
      try? writer.perform {
        entered.signal()
        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
      }
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    let date = Date()
    for _ in 0..<5 { writer.submit(.succeeded(operation: "app.startup"), at: date) }
    writer.submit(.failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user), at: date)
    release.signal()
    let report = try writer.perform { try store.readLog() }
    XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    let loss = try XCTUnwrap(events.withLock { $0 }.first { $0.phase == .writerLoss })
    XCTAssertEqual(loss.dropped, 5)
    XCTAssertEqual(loss.uncertain, 0)
    XCTAssertEqual(report.returnedEvents, 2)
    XCTAssertFalse(report.text.contains("runtime_trace"))
  }

  func testDiagnosticLockTraceMeasuresWaitAndHoldAndConnectsExpirationToRelease() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let time = Mutex(100.0)
    let events = Mutex<[RuntimeTrace.Event]>([])
    let expire = Mutex<(@Sendable () -> Void)?>(nil)
    let trace = RuntimeTrace(sink: { event in
      events.withLock { $0.append(event) }
      if event.phase == .lockWaiting { time.withLock { $0 = 100.25 } }
      if event.phase == .cleanupStarted,
        FileManager.default.fileExists(atPath: root.appendingPathComponent("aggregate.json").path) {
        time.withLock { $0 = 102.25 }
        expire.withLock { $0 }?()
      }
    }, now: { time.withLock { $0 } })
    let store = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2", runtimeTrace: trace,
      backgroundActivityRunner: { callback in
        expire.withLock { $0 = callback }
        return {}
      })
    try store.appendThrowing(.succeeded(operation: "app.startup"), at: Date())
    let recorded = events.withLock { $0 }
    XCTAssertEqual(recorded.first { $0.phase == .lockAcquired }?.waitMilliseconds, 250)
    XCTAssertEqual(recorded.first { $0.phase == .lockReleased }?.holdMilliseconds, 2_000)
    let phases = recorded.map(\.phase)
    XCTAssertLessThan(try XCTUnwrap(phases.firstIndex(of: .protectionExpired)),
      try XCTUnwrap(phases.firstIndex(of: .lockReleased)))
    XCTAssertLessThan(try XCTUnwrap(phases.firstIndex(of: .lockReleased)),
      try XCTUnwrap(phases.firstIndex(of: .protectionEnded)))
    XCTAssertEqual(Set(recorded.compactMap(\.id)).count, 1)
    XCTAssertFalse(recorded.contains { $0.line.contains(root.lastPathComponent) })
  }

  func testWriterReportsBoundedRetryMilestonesAndRecoveryWithoutLosingTheBatch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let allowed = Mutex(false)
    let events = Mutex<[RuntimeTrace.Event]>([])
    let retry = Mutex<(@Sendable () -> Void)?>(nil)
    let scheduled = DispatchSemaphore(value: 0)
    let store = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2",
      backgroundActivityRunner: { expire in
        if !allowed.withLock({ $0 }) { expire() }
        return {}
      })
    let writer = AppDiagnosticWriter(store: store,
      scheduleRetry: { _, run in
        retry.withLock { $0 = run }
        scheduled.signal()
      }, runtimeTrace: RuntimeTrace(sink: { event in events.withLock { $0.append(event) } }))
    writer.submit(.failure(operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user))
    XCTAssertEqual(scheduled.wait(timeout: .now() + 2), .success)
    for _ in 0..<4 {
      try XCTUnwrap(retry.withLock { $0 })()
      XCTAssertEqual(scheduled.wait(timeout: .now() + 2), .success)
    }
    allowed.withLock { $0 = true }
    try XCTUnwrap(retry.withLock { $0 })()
    let report = try writer.perform { try store.readLog() }
    XCTAssertEqual(report.returnedEvents, 1)
    let recorded = events.withLock { $0 }
    XCTAssertEqual(recorded.filter { $0.phase == .writerDeferred }.compactMap(\.retries), [1, 2, 4])
    let recovery = try XCTUnwrap(recorded.first { $0.phase == .writerRecovered })
    XCTAssertEqual(recovery.retries, 5)
    XCTAssertEqual(recovery.queued, 0)
  }

  func testDeniedDiagnosticAccessReportsOwnerAndOneOperationIdentityWithoutOpeningStorage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let events = Mutex<[RuntimeTrace.Event]>([])
    let store = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2",
      runtimeTrace: RuntimeTrace(sink: { event in events.withLock { $0.append(event) } }),
      backgroundActivityRunner: { expire in expire(); return {} })

    XCTAssertThrowsError(try store.appendThrowing(.succeeded(operation: "app.startup")))
    let recorded = events.withLock { $0 }
    XCTAssertEqual(recorded.map(\.phase), [.protectionRequested, .protectionDenied,
      .protectionEnded, .accessEnded])
    XCTAssertTrue(recorded.allSatisfy { $0.component == .diagnostics && $0.operation == .append })
    XCTAssertEqual(Set(recorded.compactMap(\.id)).count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
}
