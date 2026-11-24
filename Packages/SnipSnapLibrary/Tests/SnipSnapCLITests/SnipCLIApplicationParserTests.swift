@testable import SnipSnapCLI
import Foundation
import SnipSnapCore
import XCTest

final class SnipCLIApplicationParserTests: XCTestCase {
  func testOriginFilterAcceptsThreeChoicesAndRetainsAgentOnlyAlias() throws {
    let revision = String(repeating: "a", count: 64)
    for value in ["all", "agent", "human"] {
      let action = try XCTUnwrap(SnipCLIApplicationParser.parse([
        "settings", "set", "origin-filter", value, "--if-revision", revision,
      ]))
      guard case .extended(.application(.setSetting(let key, let parsedValue, _))) = action else {
        return XCTFail("Expected an origin-filter setting.")
      }
      XCTAssertEqual(key.rawValue, "origin-filter")
      XCTAssertEqual(parsedValue, value)
    }
    for value in ["on", "off"] {
      XCTAssertNotNil(try SnipCLIApplicationParser.parse([
        "settings", "set", "agent-snips-only", value, "--if-revision", revision,
      ]))
    }
    for value in ["on", "manual", "", "Human"] {
      XCTAssertThrowsError(try SnipCLIApplicationParser.parse([
        "settings", "set", "origin-filter", value, "--if-revision", revision,
      ]))
    }
  }

  func testDiagnosticLogsFetchIsReadOnlyAndKeepsTheRequestedFilters() throws {
    let action = try XCTUnwrap(SnipCLIApplicationParser.parse([
      "diagnostics", "logs", "--range", "7d", "--errors-only", "--limit", "3",
    ]))
    XCTAssertEqual(action, .extended(.application(.diagnosticLogs(range: .last7Days, limit: 3, errorsOnly: true))))
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
    XCTAssertEqual(action, .extended(.application(.exportDiagnostics(path: "/tmp/diagnostics.txt", range: .last7Days))))
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
      XCTAssertEqual(
        action,
        .extended(.application(.setDiagnosticRecording(enabled: choice == "on", expectedRevision: revision)))
      )
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

  func testClearDiagnosticsRequiresConfirmationAndCacheClearAlsoRequiresRevision() throws {
    let revision = String(repeating: "b", count: 64)
    let diagnostics = ["diagnostics", "clear"]
    let cache = ["attachments", "cache", "clear"]
    for prefix in [diagnostics, cache] {
      XCTAssertThrowsError(try SnipCLIApplicationParser.parse(prefix))
      XCTAssertThrowsError(try SnipCLIApplicationParser.parse(prefix + ["--if-revision", revision]))
    }
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse(cache + ["--yes"]))
    XCTAssertEqual(try SnipCLIApplicationParser.parse(diagnostics + ["--yes"]),
      .extended(.application(.clearDiagnostics(expectedRevision: "", confirmed: true))))
    XCTAssertEqual(try SnipCLIApplicationParser.parse(diagnostics + ["--yes", "--if-revision", revision]),
      .extended(.application(.clearDiagnostics(expectedRevision: revision, confirmed: true))))
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
    XCTAssertThrowsError(try SnipCLIApplicationParser.parse([
      "sync", "account", "keep", "--if-revision", revision,
    ]))
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
