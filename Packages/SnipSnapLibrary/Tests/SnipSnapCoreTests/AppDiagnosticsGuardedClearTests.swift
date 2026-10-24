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
      directoryURL: directory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
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
      directoryURL: directory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
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
        maxBytes: 4_096, appVersion: "1", appBuild: "2"
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
      XCTAssertTrue(contents.contains("operation=clipboard.persist"),
                    "The event unseen by the original snapshot must survive either outcome.")
      XCTAssertEqual(contents.contains("operation=app.startup"), !cleared)
    }
  }

  func testSnapshotIncludesHeaderAndUsesTheRenderedExportBytes() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
    )
    let snapshot = try store.snapshot()
    XCTAssertEqual(snapshot.byteCount, 100)
    XCTAssertEqual(snapshot.revision, "b7a269856c6cf64edc3f7d37859ca6fb5c8943be68bb758826b4e57d318beccc")
    XCTAssertEqual(try Data(contentsOf: store.makeShareableFile()).count, snapshot.byteCount)
    XCTAssertEqual(try store.snapshot(), snapshot)

    let newBuild = AppDiagnosticEventStore(
      directoryURL: directory, maxBytes: 4_096, appVersion: "1", appBuild: "3"
    )
    XCTAssertNotEqual(try newBuild.snapshot().revision, snapshot.revision)
    XCTAssertFalse(try newBuild.clear(ifRevision: snapshot.revision))
  }

  func testSnapshotIncludesRetainedHealthAfterHistoryRotatesOut() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, maxBytes: 1_024, appVersion: "1", appBuild: "2"
    )
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    func fillHistory() {
      for _ in 0..<20 {
        store.append(.succeeded(operation: "app.startup"), at: date)
      }
    }
    store.append(.syncSnapshot(scope: .transport, pendingEvents: 1), at: date)
    fillHistory()
    let snapshot = try store.snapshot()
    let historyURL = directory.appendingPathComponent("diagnostic-events.txt")
    let firstHistory = try Data(contentsOf: historyURL)
    let firstExport = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertFalse(String(decoding: firstHistory, as: UTF8.self).contains("sync.snapshot"))
    XCTAssertTrue(firstExport.contains("diagnostic_sync_latest operation=sync.snapshot"))
    XCTAssertTrue(firstExport.contains("pending_events=1"))
    XCTAssertEqual(snapshot.byteCount, firstExport.utf8.count)

    store.append(.syncSnapshot(scope: .transport, pendingEvents: 2), at: date)
    fillHistory()
    XCTAssertEqual(try Data(contentsOf: historyURL), firstHistory)
    XCTAssertNotEqual(try store.snapshot().revision, snapshot.revision)
    XCTAssertFalse(try store.clear(ifRevision: snapshot.revision))
    let export = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertTrue(export.contains("pending_events=2"))
    XCTAssertFalse(export.contains("pending_events=1"))
  }

  func testSnapshotAndGuardedClearPropagateExportFailureWithoutDeletingHistory() throws {
    let store = AppDiagnosticEventStore(
      directoryURL: directory, maxBytes: 4_096, appVersion: "1", appBuild: "2"
    )
    store.append(.succeeded(operation: "app.startup"))
    let snapshot = try store.snapshot()
    let exportURL = try store.makeShareableFile()
    try FileManager.default.removeItem(at: exportURL)
    try FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: false)

    XCTAssertThrowsError(try store.snapshot())
    XCTAssertThrowsError(try store.clear(ifRevision: snapshot.revision))

    try FileManager.default.removeItem(at: exportURL)
    let contents = try String(contentsOf: store.makeShareableFile(), encoding: .utf8)
    XCTAssertTrue(contents.contains("operation=app.startup"))
  }
}
