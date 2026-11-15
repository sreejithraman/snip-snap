import Darwin
import Foundation
import Synchronization
import XCTest

@testable import SnipSnapCore

final class AppDiagnosticBackgroundActivityTests: XCTestCase {
  func testBackgroundTimeEndsOnlyAfterDiagnosticFileIsUnlocked() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ends = Mutex(0)
    let store = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2",
      backgroundActivityRunner: { _ in
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        return {
          let fd = Darwin.open(root.appendingPathComponent(".lock").path, O_RDWR)
          XCTAssertGreaterThanOrEqual(fd, 0)
          defer { Darwin.close(fd) }
          XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
          flock(fd, LOCK_UN)
          ends.withLock { $0 += 1 }
        }
      })

    try store.appendThrowing(.succeeded(operation: "app.startup"))
    XCTAssertEqual(ends.withLock { $0 }, 1)
  }

  func testDeniedExecutionDoesNotCreateDiagnosticStorage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let ended = Mutex(false)
    let store = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2",
      backgroundActivityRunner: { expire in
        expire()
        return { ended.withLock { $0 = true } }
      })

    XCTAssertThrowsError(try store.appendThrowing(.succeeded(operation: "app.startup"))) {
      XCTAssertTrue($0 is AppDiagnosticAccessError)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    XCTAssertTrue(ended.withLock { $0 })
  }

  func testExpirationDuringAppendKeepsProtectionThroughUnlockAndDoesNotRepeatEvent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let expire = Mutex<(@Sendable () -> Void)?>(nil)
    let expiredDuringAppend = Mutex(false)
    let ended = Mutex(false)
    let date = Date()
    let store = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2",
      now: {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("aggregate.json").path) {
          expiredDuringAppend.withLock { $0 = true }
          expire.withLock { $0 }?()
        }
        XCTAssertFalse(ended.withLock { $0 })
        let fd = Darwin.open(root.appendingPathComponent(".lock").path, O_RDWR)
        defer { Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), -1)
        return date
      },
      backgroundActivityRunner: { callback in
        expire.withLock { $0 = callback }
        return { ended.withLock { $0 = true } }
      })

    try store.appendThrowing(.failure(
      operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user), at: date)
    XCTAssertTrue(expiredDuringAppend.withLock { $0 })
    XCTAssertTrue(ended.withLock { $0 })
    let reopened = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2", backgroundActivityRunner: nil)
    let report = try reopened.readLog()
    XCTAssertEqual(report.returnedEvents, 1)
    XCTAssertTrue(report.text.contains("error=sync.accessDenied"))
  }

  func testWriterRetainsDeniedBatchAndRetriesExactlyOnce() throws {
    for sharedControls in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let allowed = Mutex(false)
      let retry = Mutex<(@Sendable () -> Void)?>(nil)
      let deferred = DispatchSemaphore(value: 0)
      let store = AppDiagnosticEventStore(
        directoryURL: root, appVersion: "1", appBuild: "2",
        backgroundActivityRunner: { expire in
          if !allowed.withLock({ $0 }) { expire() }
          return {}
        })
      let writer = AppDiagnosticWriter(
        store: store, requiresReadableControls: sharedControls,
        scheduleRetry: { _, run in
          retry.withLock { $0 = run }
          deferred.signal()
        })

      writer.submit(.failure(
        operation: "sync.run", errorCode: "sync.accessDenied", visibility: .user))
      XCTAssertEqual(deferred.wait(timeout: .now() + 2), .success)
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
      allowed.withLock { $0 = true }
      let run = try XCTUnwrap(retry.withLock { $0 })
      run()
      let report = try writer.perform { try store.readLog() }
      XCTAssertEqual(report.returnedEvents, 1)
      XCTAssertTrue(report.text.contains("error=sync.accessDenied"))
      XCTAssertFalse(report.text.contains("diagnostics.writeFailed"))
    }
  }

  func testExpiryAfterFinishIsIgnoredAndProtectionEndsOnce() throws {
    let probe = ProtectionProbe()
    let activity = try XCTUnwrap(try probe.begin())
    activity.finish()
    probe.expire()
    activity.finish()

    XCTAssertNoThrow(try activity.check())
    XCTAssertEqual(probe.ends, 1)
    XCTAssertEqual(probe.phases, [.protectionRequested, .protectionGranted, .protectionEnded])
  }

  func testRepeatedExpiryIsReportedOnceAndStillStopsWorkAfterFinish() throws {
    let probe = ProtectionProbe()
    let activity = try XCTUnwrap(try probe.begin())
    probe.expire()
    probe.expire()
    XCTAssertThrowsError(try activity.check()) { XCTAssertTrue($0 is CancellationError) }
    activity.finish()

    XCTAssertThrowsError(try activity.check()) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(probe.ends, 1)
    XCTAssertEqual(probe.phases, [
      .protectionRequested, .protectionGranted, .protectionExpired, .protectionEnded,
    ])
  }
}

/// Grants protection, then delivers expiry only when the test asks.
private final class ProtectionProbe: Sendable {
  private let expiry = Mutex<(@Sendable () -> Void)?>(nil)
  private let recordedPhases = Mutex<[RuntimeTrace.Phase]>([])
  private let recordedEnds = Mutex(0)
  var phases: [RuntimeTrace.Phase] { recordedPhases.withLock { $0 } }
  var ends: Int { recordedEnds.withLock { $0 } }

  func begin() throws -> FileAccessBackgroundActivity? {
    let trace = RuntimeTrace(sink: { [self] event in
      recordedPhases.withLock { $0.append(event.phase) }
    }).span(.diagnostics)
    return try FileAccessBackgroundActivity.begin(runner: { [self] expire in
      expiry.withLock { $0 = expire }
      return { [self] in recordedEnds.withLock { $0 += 1 } }
    }, trace: trace)
  }

  func expire() { expiry.withLock { $0 }?() }
}
