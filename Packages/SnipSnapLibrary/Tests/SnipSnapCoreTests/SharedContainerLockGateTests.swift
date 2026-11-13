import Darwin
import Foundation
import Synchronization
import XCTest

@testable import SnipSnapCore

final class SharedContainerLockGateTests: XCTestCase {
  func testClosedGateKeepsDiagnosticsOutOfSharedDirectoryUntilItOpens() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = SharedContainerLockGate()
    let store = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2", backgroundActivityRunner: nil,
      lockGate: gate)

    gate.close()
    XCTAssertThrowsError(try store.appendThrowing(.succeeded(operation: "app.startup"))) {
      XCTAssertTrue($0 is AppDiagnosticAccessError)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

    gate.open()
    try store.appendThrowing(.succeeded(operation: "app.startup"))
    XCTAssertEqual(try store.readLog().returnedEvents, 1)
  }

  func testClosingDuringDiagnosticWriteReportsReleaseOnlyAfterUnlock() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = SharedContainerLockGate()
    let closeRequested = Mutex(false)
    let released = Mutex<Bool?>(nil)
    @Sendable func lockIsFree() -> Bool {
      let fd = Darwin.open(root.appendingPathComponent(".lock").path, O_RDWR)
      defer { Darwin.close(fd) }
      guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
      flock(fd, LOCK_UN)
      return true
    }
    let date = Date()
    let store = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2",
      now: {
        // Runs while the append holds the diagnostic lock.
        if !closeRequested.withLock({ $0 }) {
          closeRequested.withLock { $0 = true }
          gate.close { released.withLock { $0 = lockIsFree() } }
        }
        XCTAssertNil(released.withLock { $0 })
        return date
      },
      backgroundActivityRunner: nil, lockGate: gate)

    try store.appendThrowing(.succeeded(operation: "app.startup"), at: date)

    XCTAssertEqual(released.withLock { $0 }, true)
    XCTAssertThrowsError(try store.appendThrowing(.succeeded(operation: "app.resume"))) {
      XCTAssertTrue($0 is AppDiagnosticAccessError)
    }
  }

  func testWriterKeepsEventsWhileGateIsClosedAndWritesThemOnceAfterItOpens() throws {
    for sharedControls in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let gate = SharedContainerLockGate()
      gate.close()
      let retry = Mutex<(@Sendable () -> Void)?>(nil)
      let deferred = DispatchSemaphore(value: 0)
      let store = AppDiagnosticEventStore(
        directoryURL: root, appVersion: "1", appBuild: "2", backgroundActivityRunner: nil,
        lockGate: gate)
      let writer = AppDiagnosticWriter(
        store: store, requiresReadableControls: sharedControls,
        scheduleRetry: { _, run in
          retry.withLock { $0 = run }
          deferred.signal()
        })

      writer.submit(.failure(
        operation: "sync.run", errorCode: "sync.accessDenied", visibility: .background))
      XCTAssertEqual(deferred.wait(timeout: .now() + 2), .success)
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

      gate.open()
      try XCTUnwrap(retry.withLock { $0 })()
      let report = try writer.perform { try store.readLog() }
      XCTAssertEqual(report.returnedEvents, 1)
      XCTAssertTrue(report.text.contains("error=sync.accessDenied"))
    }
  }
}
