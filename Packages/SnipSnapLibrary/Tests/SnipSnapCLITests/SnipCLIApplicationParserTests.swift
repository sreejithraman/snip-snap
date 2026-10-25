@testable import SnipSnapCLI
import Foundation
import SnipSnapCore
import XCTest

final class SnipCLIApplicationParserTests: XCTestCase {
  func testDiagnosticLogsFetchIsReadOnlyAndKeepsTheRequestedFilters() throws {
    let action = try XCTUnwrap(SnipCLIApplicationParser.parse([
      "diagnostics", "logs", "--range", "7d", "--errors-only", "--limit", "3",
    ]))
    let encoded = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
    XCTAssertTrue(encoded.contains("last7Days"))
    XCTAssertTrue(encoded.contains(#""limit":3"#))
    XCTAssertTrue(encoded.contains(#""errorsOnly":true"#))
    if case .extended(let query) = action { XCTAssertTrue(query.isReadOnly) }
    else { XCTFail("Expected a read-only extended action") }
    XCTAssertEqual(try SnipCLIApplicationParser.parse(["diagnostics", "logs"]),
      .extended(.application(.diagnosticLogs(range: .last24Hours, limit: 200, errorsOnly: false))))
    for arguments in [
      ["--limit", "0"], ["--limit", "2001"], ["--limit", "--json"],
      ["--range", "30d"], ["--errors-only", "--errors-only"],
      ["--limit", "2", "--limit", "3"], ["--range", "7d", "--range", "24h"],
      ["--", "--errors-only"],
    ] {
      XCTAssertThrowsError(try SnipCLIApplicationParser.parse(["diagnostics", "logs"] + arguments))
    }
  }

  func testDiagnosticsExportAcceptsAnExplicitHistoryRange() throws {
    let action = try XCTUnwrap(SnipCLIApplicationParser.parse([
      "diagnostics", "export", "/tmp/diagnostics.txt", "--range", "7d",
    ]))
    let encoded = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
    XCTAssertTrue(encoded.contains("last7Days"))
    for invalid in ["30d", "", "yesterday"] {
      XCTAssertThrowsError(try SnipCLIApplicationParser.parse([
        "diagnostics", "export", "/tmp/diagnostics.txt", "--range", invalid,
      ]))
    }
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse([
      "diagnostics", "status", "--range", "7d",
    ]))
  }

  func testDiagnosticRecordingRequiresARevisionAndAnExplicitOnOffChoice() throws {
    let revision = String(repeating: "a", count: 64)
    for choice in ["on", "off"] {
      let action = try XCTUnwrap(SnipCLIApplicationParser.parse([
        "diagnostics", "recording", choice, "--if-revision", revision,
      ]))
      let encoded = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
      XCTAssertTrue(encoded.contains("setDiagnosticRecording"))
    }
    for args in [
      ["diagnostics", "recording", "off"],
      ["diagnostics", "recording", "maybe", "--if-revision", revision],
      ["diagnostics", "recording", "on", "--if-revision", "stale"],
    ] {
      XCTAssertThrowsError(try SnipCLIApplicationParser.parse(args))
    }
  }

  func testExplicitNavigationActionsParseAndSurviveCompaction() throws {
    let commands: [(String, SnipCLIApplicationAction)] = [
      ("clipboard", .showClipboard), ("close-search", .closeSearch),
    ]
    for (command, action) in commands {
      XCTAssertEqual(try SnipCLIApplicationParser.parse(["app", command]), .extended(.application(action)))
      guard case .request(let options) = try SnipSnapCLIParser.parse(["app", command, "--json"]) else {
        return XCTFail("Expected a navigation request for \(command).")
      }
      XCTAssertEqual(options.input, .action(.extended(.application(action))))
      XCTAssertTrue(options.json)
      XCTAssertFalse(action.isReadOnly)
      XCTAssertEqual(action.compacted, action)
      XCTAssertEqual(try JSONDecoder().decode(SnipCLIApplicationAction.self,
        from: JSONEncoder().encode(action.compacted)), action)
      for suffix in [["extra"], ["--toggle"], ["--if-revision", String(repeating: "a", count: 64)]] {
        XCTAssertThrowsError(try SnipCLIApplicationParser.parse(["app", command] + suffix))
      }
    }
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse(["app", "toggle-clipboard"]))
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse(["app", "toggle-search"]))
  }

  func testSettingsWriteRequiresCurrentRevisionAndKnownValue() throws {
    let revision = String(repeating: "a", count: 64)
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse(["settings", "set", "appearance", "dark"]))
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse([
      "settings", "set", "appearance", "purple", "--if-revision", revision,
    ]))
    XCTAssertEqual(try SnipCLIApplicationParser.parse([
      "settings", "set", "appearance", "dark", "--if-revision", revision,
    ]), .extended(.application(.setSetting(key: .appearance, value: "dark", expectedRevision: revision))))
  }

  func testUnrelatedAndLegacyCommandsRemainAvailableToOtherParsers() throws {
    for arguments in [["show", UUID().uuidString], ["clipboard", "sync"], ["attachments", "list", UUID().uuidString]] {
      XCTAssertNil(try SnipCLIApplicationParser.parse(arguments))
    }
  }

  func testClearRequiresBothLatestRevisionAndExplicitConfirmation() throws {
    let revision = String(repeating: "b", count: 64)
    for prefix in [["diagnostics", "clear"], ["attachments", "cache", "clear"]] {
      XCTAssertThrowsError(try SnipCLIApplicationParser.parse(prefix))
      XCTAssertThrowsError(try SnipCLIApplicationParser.parse(prefix + ["--yes"]))
      XCTAssertThrowsError(try SnipCLIApplicationParser.parse(prefix + ["--if-revision", revision]))
    }
    XCTAssertEqual(try SnipCLIApplicationParser.parse([
      "attachments", "cache", "clear", "--yes", "--if-revision", revision,
    ]), .extended(.application(.clearAttachmentCache(expectedRevision: revision, confirmed: true))))
  }

  func testSyncCommandsPreserveExplicitChoicesAndDoNotOfferCloudReset() throws {
    let revision = String(repeating: "c", count: 64)
    XCTAssertEqual(try SnipCLIApplicationParser.parse([
      "sync", "disable", "--use-current-cache", "--if-revision", revision,
    ]), .extended(.application(.setSync(enabled: false, useCurrentCache: true, expectedRevision: revision))))
    XCTAssertEqual(try SnipCLIApplicationParser.parse(["sync", "retry"]), .extended(.application(.retrySync)))
    XCTAssertEqual(try SnipCLIApplicationParser.parse(["sync", "clipboard", "retry"]),
                   .extended(.application(.retryClipboardSync)))
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse(["sync", "reset", "--yes"]))
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse(["sync", "toggle"]))
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse([
      "sync", "account", "remove", "--if-revision", revision,
    ]))
    XCTAssertEqual(try SnipCLIApplicationParser.parse([
      "sync", "account", "remove", "--if-revision", revision, "--yes",
    ]), .extended(.application(.resolveAccount(choice: .remove, expectedRevision: revision, confirmed: true))))
  }

  func testMalformedOptionsFailWithUsageInsteadOfSilentlyChangingState() throws {
    for args in [
      ["settings", "set", "appearance", "dark", "--if-revision", "stale"],
      ["app", "show", "--toggle"], ["sync", "status", "--yes"],
      ["settings", "show", "extra"],
      ["sync", "enable", "--if-revision", String(repeating: "d", count: 64), "--if-revision", String(repeating: "e", count: 64)],
    ] {
      XCTAssertThrowsError(try SnipCLIApplicationParser.parse(args)) { error in
        guard case SnipSnapCLIError.usage = error else { return XCTFail("Expected usage, got \(error)") }
      }
    }
  }

  func testAllKeyboardActionsCanResetAndOnlyGlobalActionsAcceptShiftTriggers() throws {
    let revision = String(repeating: "f", count: 64)
    for action in SnipCLIShortcutAction.allCases {
      XCTAssertEqual(try SnipCLIApplicationParser.parse([
        "settings", "shortcuts", "reset", action.rawValue, "--if-revision", revision,
      ]), .extended(.application(.resetShortcut(action: action, expectedRevision: revision))))
    }
    XCTAssertEqual(try SnipCLIApplicationParser.parse([
      "settings", "shortcuts", "set", "merge", "chord", "46", "768", "M", "--if-revision", revision,
    ]), .extended(.application(.setShortcut(action: .merge,
      binding: .chord(keyCode: 46, modifiers: 768, label: "M"), expectedRevision: revision))))
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse([
      "settings", "shortcuts", "set", "merge", "double-shift", "left", "--if-revision", revision,
    ]))
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse([
      "settings", "shortcuts", "set", "capture-selection", "chord", "400", "768", "M", "--if-revision", revision,
    ]))
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse([
      "settings", "shortcuts", "set", "capture-selection", "chord", "46", "1024", "M", "--if-revision", revision,
    ]))
  }

  func testCaptureIsInteractiveAndSearchPreservesOneExactArgument() throws {
    XCTAssertEqual(try SnipCLIApplicationParser.parse(["app", "capture-screen"]), .extended(.application(.captureScreen)))
    XCTAssertEqual(try SnipCLIApplicationParser.parse(["app", "capture-selection"]), .extended(.application(.captureSelection)))
    XCTAssertEqual(try SnipCLIApplicationParser.parse(["app", "search", "two words"]), .extended(.application(.search(query: "two words"))))
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse(["app", "search", "two", "words"]))
  }
}
