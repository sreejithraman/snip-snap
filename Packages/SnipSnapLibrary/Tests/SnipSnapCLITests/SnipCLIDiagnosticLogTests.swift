import Foundation
import XCTest

final class SnipCLIDiagnosticLogTests: XCTestCase {
  func testFetchReadsOfflineHistoryAsTextOrJSONWithoutLaunchingOrQueueing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Offline.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: [
      "CFBundlePackageType": "APPL", "CFBundleIdentifier": "org.example.snipsnap.offline",
      "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42",
    ], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let logs = root.appendingPathComponent("diagnostics")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let now = Date()
    let history = """
      \(now.addingTimeInterval(-90_000).ISO8601Format()) diagnostic_event operation=sync.run outcome=failed visibility=user error=sync.accessDenied
      \(now.addingTimeInterval(-30).ISO8601Format()) diagnostic_event operation=app.startup outcome=succeeded visibility=background
      \(now.addingTimeInterval(-20).ISO8601Format()) diagnostic_event operation=clipboard.persist outcome=failed visibility=user error=storage.pathOutsideRoot
      \(now.addingTimeInterval(-10).ISO8601Format()) diagnostic_event operation=sync.snapshot outcome=succeeded visibility=background scope=transport pending_events=0

      """
    try history.write(to: logs.appendingPathComponent("diagnostic-events.txt"), atomically: true, encoding: .utf8)
    var environment = ProcessInfo.processInfo.environment
    environment["SNIP_SNAP_APP_PATH"] = app.path
    environment["SNIP_SNAP_STORE_PATH"] = root.appendingPathComponent("store/items.json").path
    environment["SNIP_SNAP_DIAGNOSTICS_DIRECTORY"] = logs.path
    environment["SNIP_SNAP_CLI_NO_LAUNCH"] = "1"

    let json = try await fetch(["--range", "7d", "--errors-only", "--limit", "1", "--json"], environment: environment)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let result = try XCTUnwrap(object["result"] as? [String: Any])
    let application = try XCTUnwrap(result["application"] as? [String: Any])
    let values = try XCTUnwrap(application["values"] as? [String: String])
    XCTAssertEqual(values["returned-events"], "1")
    XCTAssertEqual(values["truncated"], "true")
    let filtered = try XCTUnwrap(values["log"])
    XCTAssertTrue(filtered.contains("error=storage.pathOutsideRoot"))
    XCTAssertFalse(filtered.contains("error=sync.accessDenied"))

    let text = try await fetch(["--range", "7d", "--errors-only"], environment: environment)
    XCTAssertTrue(text.hasPrefix("Snip Snap diagnostics\n"))
    XCTAssertTrue(text.contains("error=sync.accessDenied"))
    XCTAssertTrue(text.contains("error=storage.pathOutsideRoot"))
    XCTAssertFalse(text.contains("operation=app.startup"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store/Agent").path))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: logs.path).contains { $0.hasPrefix("share-") })
  }

  private func fetch(_ options: [String], environment: [String: String]) async throws -> String {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("snipsnap")
    process.arguments = ["diagnostics", "logs"] + options
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while process.isRunning, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard !process.isRunning else {
      XCTFail("Offline log fetching must not wait for the app")
      throw CocoaError(.executableRuntimeMismatch)
    }
    let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0, errorText)
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }
}
