import Foundation
import XCTest

@testable import SnipSnapCore

final class AppDiagnosticsTests: XCTestCase {
  func testRecorderWritesSafeEventsForReadingAndExport() async throws {
    let (root, scope) = makeScope()
    defer { try? FileManager.default.removeItem(at: root) }
    scope.recorder.record(.succeeded(operation: "app.startup"))
    scope.recorder.record(.failure(
      operation: "clipboard.persist",
      error: NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSFilePathErrorKey: "/private/snip"]),
      visibility: .user
    ))
    let flushed = await scope.recorder.flush()
    XCTAssertTrue(flushed)
    XCTAssertEqual(try scope.readLog().returnedEvents, 2)
    let errors = try scope.readLog(errorsOnly: true)
    XCTAssertEqual(errors.returnedEvents, 1)
    XCTAssertTrue(errors.text.contains("error=cocoa.513"))
    XCTAssertFalse(errors.text.contains("/private/snip"))

    let export = try scope.makeShareableFile()
    XCTAssertEqual(try String(contentsOf: export, encoding: .utf8), try scope.readLog().text)
    scope.removeShareableFile(export)
    XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
  }

  func testCapRetainsNewestCompleteEntriesForAnIndependentReader() throws {
    let (root, scope) = makeScope(byteLimit: 640)
    defer { try? FileManager.default.removeItem(at: root) }
    for bytes in 100...119 {
      scope.recorder.record(.succeeded(operation: "app.startup", byteCount: Int64(bytes)))
    }
    let report = try scope.readLog()
    let data = try Data(contentsOf: root.appendingPathComponent("events.jsonl"))
    XCTAssertLessThanOrEqual(data.count, 640)
    XCTAssertEqual(report.returnedEvents, data.split(separator: 10).count)
    XCTAssertGreaterThan(report.returnedEvents, 1)
    XCTAssertLessThan(report.returnedEvents, 20)
    XCTAssertTrue(report.text.contains("bytes=119"))
    XCTAssertFalse(report.text.contains("bytes=100"))
    let reader = AppDiagnosticEventStore(directoryURL: root, appVersion: "1", appBuild: "2", preferenceDirectory: root)
    XCTAssertEqual(try reader.readLog(range: .last24Hours, limit: 200, errorsOnly: false).text, report.text)
  }

  func testClearPreservesRecordingPreferenceAndAllowsNewEvents() throws {
    let (root, scope) = makeScope()
    defer { try? FileManager.default.removeItem(at: root) }
    try scope.clear()
    scope.recorder.record(.succeeded(operation: "app.startup"))
    try scope.setRecordingEnabled(false)
    try scope.clear()
    scope.recorder.record(.succeeded(operation: "app.startup"))
    XCTAssertFalse(try scope.readRecordingEnabled())
    XCTAssertEqual(try scope.readLog().returnedEvents, 0)

    try scope.setRecordingEnabled(true)
    scope.recorder.record(.succeeded(operation: "app.startup"))
    XCTAssertEqual(try scope.readLog().returnedEvents, 1)
  }

  func testRecordingChangeRejectsAnOutdatedPreferenceRevision() throws {
    let (root, scope) = makeScope()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try scope.readLog()
    try scope.setRecordingEnabled(false)
    XCTAssertFalse(try scope.setRecordingEnabled(true, ifRevision: initial.recordingRevision))
    let current = try scope.readLog()
    XCTAssertFalse(current.recordingEnabled)
    XCTAssertTrue(try scope.setRecordingEnabled(true, ifRevision: current.recordingRevision))
  }

  func testUnavailableSharedPreferenceDoesNotEnablePrivateRecording() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2", preferenceDirectory: nil
    )
    XCTAssertThrowsError(try store.append(.succeeded(operation: "app.startup"), at: Date()))
    XCTAssertThrowsError(try store.readRecordingEnabled())
    XCTAssertThrowsError(try store.setRecordingEnabled(true))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  private func makeScope(byteLimit: Int = 256 * 1024) -> (URL, AppDiagnosticScope) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = AppDiagnosticEventStore(
      directoryURL: root, appVersion: "1", appBuild: "2", preferenceDirectory: root, byteLimit: byteLimit
    )
    return (root, AppDiagnosticScope(store: store))
  }
}
