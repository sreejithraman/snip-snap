import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnapCLI

final class SnipCLIIntegrationTests: XCTestCase {
  func testDiagnosticBusyErrorHasARetryableMachineReadableCode() throws {
    let data = try SnipCLIErrorReport(error: AppDiagnosticAccessError.busy).data()
    let error = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "diagnostics_busy")
    XCTAssertEqual(error["status"] as? String, "failed")
    XCTAssertFalse((error["message"] as? String ?? "").isEmpty)
  }

  func testBundledDiagnosticFetchRequiresExplicitSelectionForAnUnrelatedStore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Example.app")
    let executable = app.appendingPathComponent("Contents/MacOS/snipsnap")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: executable)
    let embeddedStore = root.appendingPathComponent("dev/items.json").path
    try PropertyListSerialization.data(fromPropertyList: [
      "CFBundlePackageType": "APPL", "CFBundleIdentifier": "org.example.snipsnap.dev",
      "SnipSnapDevelopmentStorePath": embeddedStore,
    ], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let link = root.appendingPathComponent("snipsnap")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
    let override = ["SNIP_SNAP_STORE_PATH": root.appendingPathComponent("unrelated/items.json").path]
    let implicit = try SnipCLIApplicationLocation(executableURL: link, environment: override)
    XCTAssertThrowsError(try implicit.diagnosticIdentity())
    let explicit = try SnipCLIApplicationLocation(executableURL: link,
      environment: override.merging(["SNIP_SNAP_APP_PATH": app.path]) { _, new in new })
    XCTAssertEqual(try explicit.diagnosticIdentity().bundleIdentifier, "org.example.snipsnap.dev")
    let matching = try SnipCLIApplicationLocation(executableURL: link,
      environment: ["SNIP_SNAP_STORE_PATH": embeddedStore])
    XCTAssertEqual(try matching.diagnosticIdentity().bundleIdentifier, "org.example.snipsnap.dev")
    let isolated = try SnipCLIApplicationLocation(executableURL: link,
      environment: override.merging(["SNIP_SNAP_DIAGNOSTICS_DIRECTORY": root.appendingPathComponent("logs").path]) { _, new in new })
    XCTAssertNoThrow(try isolated.diagnosticIdentity())
  }

  func testGlobalOptionsReachEveryNamespaceAndHelpDoesNotNeedAnApp() throws {
    let id = UUID()
    for arguments in [["search", "hello"], ["clipboard", "status"], ["drafts", "list"],
                      ["settings", "show"], ["attachments", "cache", "status"]] {
      guard case .request(let options) = try SnipSnapCLIParser.parse(
        arguments + ["--json", "--request-id", id.uuidString]
      ) else { return XCTFail("Expected an app request for \(arguments)") }
      XCTAssertEqual(options.requestID, id)
      XCTAssertTrue(options.json)
    }
    XCTAssertEqual(try SnipSnapCLIParser.parse(["--help"]), .help)
    XCTAssertEqual(try SnipSnapCLIParser.parse(["clipboard", "--help"]), .help)
    XCTAssertEqual(try SnipSnapCLIParser.parse(["snips", "move", "--help"]), .help)
  }

  func testLiteralTextAndOptionValuesAreNotConsumedAsGlobalFlags() throws {
    guard case .request(let literal) = try SnipSnapCLIParser.parse(["search", "--", "--json"]),
          case .extended(.library(.query(let query))) = try literal.action() else {
      return XCTFail("Expected a literal search")
    }
    XCTAssertEqual(query.text, "--json")
    XCTAssertFalse(literal.json)
    guard case .request(let attachment) = try SnipSnapCLIParser.parse([
      "snips", "add", "--file", "/tmp/file", "--text", "--json",
    ]), case .extended(.library(.addFiles(let text, _, _))) = try attachment.action() else {
      return XCTFail("Expected file add")
    }
    XCTAssertEqual(text, "--json")
    XCTAssertFalse(attachment.json)
    XCTAssertFalse(SnipCLIExtendedParser.requestsJSON(["add", "--session-title", "--json", "Hello"]))
    XCTAssertFalse(SnipCLIExtendedParser.requestsJSON(["search", "--", "--json"]))
  }

  func testExtendedWriteDeliversResultThenCompactsWithoutReplaying() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("test")
    let request = SnipCLIRequest(action: .extended(.application(.search(query: "Private query"))),
                                 scopeToken: "test")
    let result = SnipCLIExtendedResult.application(.init(values: ["query": "Private query"]))
    _ = try await store.enqueue(request)
    await store.processPending { request in
      SnipCLIReceipt(request: request, status: .success, extendedResult: result)
    }
    guard case .completed(let delivered) = try await store.state(for: request.requestID) else {
      return XCTFail("Expected result")
    }
    XCTAssertEqual(delivered.extendedResult, result)
    try await store.releaseReceipt(request.requestID)
    guard case .completed(let retry) = try await store.enqueue(request) else {
      return XCTFail("A released mutation must stay completed")
    }
    XCTAssertNil(retry.extendedResult)
    XCTAssertEqual(retry.action, .extended(.application(.search(query: ""))))
    XCTAssertTrue(retry.matches(request))
    let privateBytes = try JSONEncoder().encode(retry)
    XCTAssertFalse(String(decoding: privateBytes, as: UTF8.self).contains("Private query"))
  }

  func testBundledCLIUsesDevelopmentStoreThroughSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Example.app")
    let executable = app.appendingPathComponent("Contents/MacOS/snipsnap")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                          withIntermediateDirectories: true)
    try Data().write(to: executable)
    let storePath = root.appendingPathComponent("Isolated/items.json").path
    let info: [String: String] = ["CFBundlePackageType": "APPL",
      "CFBundleIdentifier": "test.snipsnap.dev", "SnipSnapDevelopmentStorePath": storePath,
      "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let link = root.appendingPathComponent("snipsnap")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
    let location = try SnipCLIApplicationLocation(executableURL: link, environment: [:])
    XCTAssertEqual(location.applicationURL?.standardizedFileURL, app.standardizedFileURL)
    XCTAssertEqual(location.rootURL.path, root.appendingPathComponent("Isolated").path)
    XCTAssertTrue(location.canLaunch)
    let diagnosticTarget = try location.diagnosticIdentity()
    XCTAssertEqual(diagnosticTarget.bundleIdentifier, "test.snipsnap.dev")
    XCTAssertEqual(diagnosticTarget.appVersion, "1.2.3")
    XCTAssertEqual(diagnosticTarget.appBuild, "42")
    let standalone = try SnipCLIApplicationLocation(executableURL: root.appendingPathComponent("tool"),
      environment: ["SNIP_SNAP_STORE_PATH": storePath])
    XCTAssertFalse(standalone.canLaunch)
    XCTAssertThrowsError(try standalone.diagnosticIdentity())
    let isolated = try SnipCLIApplicationLocation(executableURL: root.appendingPathComponent("tool"),
      environment: ["SNIP_SNAP_STORE_PATH": storePath,
                    "SNIP_SNAP_DIAGNOSTICS_DIRECTORY": root.appendingPathComponent("logs").path])
    XCTAssertNoThrow(try isolated.diagnosticIdentity())
  }

  func testJSONErrorsHaveStableCodeAndRequestIdentity() throws {
    let id = UUID()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with:
      SnipCLIErrorReport(error: SnipSnapCLIError.commandInProgress(id)).data()
    ) as? [String: Any])
    XCTAssertEqual(object["status"] as? String, "failed")
    XCTAssertEqual(object["code"] as? String, "in_progress")
    XCTAssertEqual(object["requestID"] as? String, id.uuidString)
  }
}
