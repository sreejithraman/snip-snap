import Dispatch
import Foundation
import XCTest

@testable import SnipSnapCore

final class AppDiagnosticsGuardedClearTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = URL(fileURLWithPath: "/tmp/snipsnap-cli-diagnostics-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  func testCurrentSnapshotClearsHistoryAndRetainedHealth() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, maxBytes: 4_096, appVersion: "1", appBuild: "2",
      now: { Date(timeIntervalSince1970: 1_790_056_800) }
    )
    store.append(.syncSnapshot(scope: .transport, pendingEvents: 3))
    store.append(.succeeded(operation: "sync.send"))
    let snapshot = try store.snapshot()

    XCTAssertTrue(try store.clear(ifRevision: snapshot.revision))

    let contents = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertTrue(contents.contains("Snip Snap diagnostics"))
    XCTAssertFalse(contents.contains("diagnostic_event"))
    XCTAssertFalse(contents.contains("diagnostic_sync_"))
    XCTAssertNotEqual(try store.snapshot().revision, snapshot.revision)
  }

  func testStaleSnapshotRejectsClearAndPreservesBothEvents() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, maxBytes: 4_096, appVersion: "1", appBuild: "2",
      now: { Date(timeIntervalSince1970: 1_790_056_800) }
    )
    store.append(.succeeded(operation: "app.startup", byteCount: 1))
    let snapshot = try store.snapshot()
    store.append(.succeeded(operation: "clipboard.persist", byteCount: 2))

    XCTAssertFalse(try store.clear(ifRevision: snapshot.revision))

    let contents = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertTrue(contents.contains("operation=app.startup"))
    XCTAssertTrue(contents.contains("operation=clipboard.persist"))
    XCTAssertNotEqual(try store.snapshot().revision, snapshot.revision)
  }

  func testConcurrentAppendEitherConflictsOrSurvivesSuccessfulClear() throws {
    for iteration in 0..<64 {
      let store = AppDiagnosticEventStore(
        directoryURL: directory.appendingPathComponent(String(iteration), isDirectory: true),
        maxBytes: 4_096, appVersion: "1", appBuild: "2",
        now: { Date(timeIntervalSince1970: 1_790_056_800) }
      )
      store.append(.succeeded(operation: "app.startup"))
      let snapshot = try store.snapshot()
      let ready = DispatchSemaphore(value: 0)
      let start = DispatchSemaphore(value: 0)
      let finished = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        ready.signal()
        start.wait()
        store.append(.succeeded(operation: "clipboard.persist"))
        finished.signal()
      }
      ready.wait()
      start.signal()
      let result = Result { try store.clear(ifRevision: snapshot.revision) }
      finished.wait()
      let cleared = try result.get()

      let contents = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
      XCTAssertTrue(
        contents.contains("operation=clipboard.persist"),
        "The event unseen by the original snapshot must survive either outcome.")
      XCTAssertEqual(contents.contains("operation=app.startup"), !cleared)
    }
  }

  func testSnapshotIncludesHeaderAndUsesTheRenderedExportBytes() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, maxBytes: 4_096, appVersion: "1", appBuild: "2",
      now: { Date(timeIntervalSince1970: 1_790_056_800) }
    )
    let snapshot = try store.snapshot()
    XCTAssertGreaterThan(snapshot.byteCount, 100)
    XCTAssertEqual(snapshot.revision.count, 64)
    XCTAssertEqual(try Data(contentsOf: store.makeShareableFile()).count, snapshot.byteCount)
    XCTAssertEqual(try store.snapshot(), snapshot)

    let newBuild = AppDiagnosticEventStore(
      directoryURL: directory, maxBytes: 4_096, appVersion: "1", appBuild: "3",
      now: { Date(timeIntervalSince1970: 1_790_056_800) }
    )
    XCTAssertNotEqual(try newBuild.snapshot().revision, snapshot.revision)
    XCTAssertFalse(try newBuild.clear(ifRevision: snapshot.revision))
  }

  func testSnapshotIncludesRetainedHealthAfterHistoryExpires() throws {
    var clock = Date(timeIntervalSince1970: 1_790_053_200)
    let store = AppDiagnosticEventStore(
      directoryURL: directory, maxBytes: 4_096,
      appVersion: "1", appBuild: "2", now: { clock })
    store.append(.syncSnapshot(scope: .transport, pendingEvents: 1))
    clock.addTimeInterval(8 * 86_400)
    let snapshot = try store.snapshot()
    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertFalse(export.contains("diagnostic_event"))
    XCTAssertTrue(export.contains("diagnostic_sync_latest operation=sync.snapshot"))
    XCTAssertTrue(export.contains("pending_events=1"))
    store.append(.syncSnapshot(scope: .transport, pendingEvents: 2))
    clock.addTimeInterval(8 * 86_400)
    XCTAssertNotEqual(try store.snapshot().revision, snapshot.revision)
    XCTAssertFalse(try store.clear(ifRevision: snapshot.revision))
    let updated = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertTrue(updated.contains("pending_events=2"))
    XCTAssertFalse(updated.contains("pending_events=1"))
  }

  func testSnapshotAndGuardedClearPropagateStorageFailureWithoutDeletingHistory() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, maxBytes: 4_096,
      appVersion: "1", appBuild: "2")
    store.append(.succeeded(operation: "app.startup"))
    let snapshot = try store.snapshot()
    let lockURL = directory.appendingPathComponent(".lock")
    try FileManager.default.removeItem(at: lockURL)
    try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.snapshot())
    XCTAssertThrowsError(try store.clear(ifRevision: snapshot.revision))
    try FileManager.default.removeItem(at: lockURL)
    let contents = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertTrue(contents.contains("operation=app.startup"))
  }
}
