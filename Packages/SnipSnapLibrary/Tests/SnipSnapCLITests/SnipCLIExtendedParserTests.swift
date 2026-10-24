@testable import SnipSnapCLI
import Foundation
import SnipSnapCore
import XCTest

final class SnipCLIExtendedParserTests: XCTestCase {
  func testApplicationSearchTreatsJSONAfterTerminatorAsLiteralQuery() throws {
    let arguments = ["app", "search", "--", "--json"]
    guard case .request(let options) = try SnipSnapCLIParser.parse(arguments) else {
      return XCTFail("Expected an application request.")
    }
    XCTAssertEqual(options.input, .action(.extended(.application(.search(query: "--json")))))
    XCTAssertFalse(options.json)
    XCTAssertFalse(SnipCLIExtendedParser.requestsJSON(arguments))
  }

  func testClipboardSearchPreservesLiteralGlobalFlagValues() throws {
    for literal in ["--json", "--request-id", "--help", "-h", "--"] {
      let arguments = ["clipboard", "list", "--search", literal, "--pinned"]
      guard case .request(let options) = try SnipSnapCLIParser.parse(arguments) else {
        return XCTFail("Expected a clipboard request for \(literal).")
      }
      XCTAssertEqual(options.input, .action(.extended(.clipboard(.list(.init(
        search: literal, onlyPinned: true, newestFirst: true, limit: nil))))))
      XCTAssertFalse(options.json)
      XCTAssertNil(options.requestID)
      XCTAssertFalse(SnipCLIExtendedParser.requestsJSON(arguments))
    }
  }

  func testLeadingGlobalsDoNotChangeClipboardPinnedArity() throws {
    let requestID = UUID()
    let arguments = ["--json", "clipboard", "--request-id", requestID.uuidString, "list", "--pinned", "--json"]
    guard case .request(let options) = try SnipSnapCLIParser.parse(arguments) else {
      return XCTFail("Expected a clipboard request.")
    }
    XCTAssertEqual(options.input, .action(.extended(.clipboard(.list(.init(
      search: nil, onlyPinned: true, newestFirst: true, limit: nil))))))
    XCTAssertTrue(options.json)
    XCTAssertEqual(options.requestID, requestID)
    XCTAssertTrue(SnipCLIExtendedParser.requestsJSON(arguments))
  }

  func testDiagnosticsExportAcceptsLiteralFlagPathAfterTerminator() throws {
    guard case .request(let options) = try SnipSnapCLIParser.parse([
      "diagnostics", "export", "--", "--json",
    ]) else { return XCTFail("Expected a diagnostics request.") }
    XCTAssertEqual(options.input, .action(.extended(.application(.exportDiagnostics(
      path: URL(fileURLWithPath: "--json").standardizedFileURL.path)))))
    XCTAssertFalse(options.json)
  }

  func testLeadingGlobalsReachLegacyCommands() throws {
    let requestID = UUID()
    for arguments in [["add", "literal text"], ["list", "--list", "Research"]] {
      guard case .request(let expected) = try SnipSnapCLIParser.parse(arguments),
        case .request(let actual) = try SnipSnapCLIParser.parse(
          ["--request-id", requestID.uuidString, "--json"] + arguments)
      else { return XCTFail("Expected a legacy request.") }
      XCTAssertEqual(actual.input, expected.input)
      XCTAssertTrue(actual.json)
      XCTAssertEqual(actual.requestID, requestID)
    }
    let statusID = UUID()
    XCTAssertEqual(try SnipSnapCLIParser.parse(["--json", "status", statusID.uuidString]),
                   .status(id: statusID, json: true))
    XCTAssertThrowsError(try SnipSnapCLIParser.parse([
      "--json", "status", statusID.uuidString, "--request-id", requestID.uuidString,
    ]))
  }

  func testRevisionOptionsAfterTerminatorRemainPositional() throws {
    let revision = String(repeating: "a", count: 64)
    guard case .request(let options) = try SnipSnapCLIParser.parse([
      "app", "search", "--", "--if-revision",
    ]) else { return XCTFail("Expected a literal search request.") }
    XCTAssertEqual(options.input, .action(.extended(.application(.search(query: "--if-revision")))))
    for prefix in [["sync", "enable"], ["settings", "set", "appearance", "dark"],
                   ["clipboard", "pause"]] {
      XCTAssertThrowsError(try SnipSnapCLIParser.parse(prefix + ["--", "--if-revision", revision]))
    }
  }

  func testShortcutLabelsAfterTerminatorPreserveLiteralFlags() throws {
    let revision = String(repeating: "b", count: 64)
    for label in ["--json", "--request-id", "--if-revision", "--yes", "--help", "-h", "--"] {
      let arguments = ["settings", "shortcuts", "set", "merge", "chord", "46", "768",
                       "--if-revision", revision, "--", label]
      guard case .request(let options) = try SnipSnapCLIParser.parse(arguments) else {
        return XCTFail("Expected a shortcut request for \(label).")
      }
      XCTAssertEqual(options.input, .action(.extended(.application(.setShortcut(action: .merge,
        binding: .chord(keyCode: 46, modifiers: 768, label: label), expectedRevision: revision)))))
      XCTAssertFalse(options.json)
      XCTAssertNil(options.requestID)
      XCTAssertFalse(SnipCLIExtendedParser.requestsJSON(arguments))
    }
    XCTAssertEqual(try SnipSnapCLIParser.parse(["app", "search", "--help"]), .help)
    XCTAssertEqual(try SnipSnapCLIParser.parse(["app", "search", "-h"]), .help)
  }

  func testTextAndFileValuesCannotBecomeGlobalFlags() throws {
    let requestID = UUID()
    for literal in ["--json", "--request-id", "--help", "-h", "--"] {
      let arguments = ["snips", "add", "--file", literal, "--text", literal,
                       "--request-id", requestID.uuidString]
      guard case .request(let options) = try SnipSnapCLIParser.parse(arguments) else {
        return XCTFail("Expected a file-add request for \(literal).")
      }
      XCTAssertEqual(options.input, .action(.extended(.library(.addFiles(content: literal, list: nil,
        paths: [URL(fileURLWithPath: literal).standardizedFileURL.path])))))
      XCTAssertFalse(options.json)
      XCTAssertEqual(options.requestID, requestID)
      XCTAssertFalse(SnipCLIExtendedParser.requestsJSON(arguments))
    }
  }

  func testDraftTextPreservesLiteralGlobalsWhileRealGlobalsAreExtracted() throws {
    let revision = String(repeating: "c", count: 64)
    let requestID = UUID()
    for literal in ["--json", "--request-id", "--help", "-h", "--"] {
      let arguments = ["--request-id", requestID.uuidString, "drafts", "--json", "save", "Inbox",
                       "--text", literal, "--if-draft-revision", revision]
      guard case .request(let options) = try SnipSnapCLIParser.parse(arguments) else {
        return XCTFail("Expected a draft request for \(literal).")
      }
      XCTAssertEqual(options.input, .action(.extended(.data(.saveDraft(list: "Inbox", text: literal,
        attachmentPaths: [], expectedRevision: revision)))))
      XCTAssertTrue(options.json)
      XCTAssertEqual(options.requestID, requestID)
      XCTAssertTrue(SnipCLIExtendedParser.requestsJSON(arguments))
    }
  }

  func testLibraryPinnedConsumesAnOnOffValueBeforeGlobals() throws {
    let requestID = UUID()
    for (value, pinned) in [("on", true), ("off", false)] {
      let arguments = ["--json", "snips", "--request-id", requestID.uuidString, "list", "--pinned", value]
      guard case .request(let options) = try SnipSnapCLIParser.parse(arguments) else {
        return XCTFail("Expected a snip query.")
      }
      XCTAssertEqual(options.input, .action(.extended(.library(.query(.init(text: "", pinned: pinned))))))
      XCTAssertTrue(options.json)
      XCTAssertEqual(options.requestID, requestID)
    }
    XCTAssertFalse(SnipCLIExtendedParser.requestsJSON(["search", "--pinned", "--json"]))
    XCTAssertThrowsError(try SnipSnapCLIParser.parse(["search", "--pinned", "--json"]))
  }

  func testLegacyAddUpdateAndListKeepTheirSyntaxAndLiteralValues() throws {
    let id = UUID()
    guard case .request(let add) = try SnipSnapCLIParser.parse([
      "add", "--list", "--json", "--session-title", "--help", "--branch", "topic",
      "--json", "--", "--json", "-h",
    ]), case .request(let update) = try SnipSnapCLIParser.parse([
      "update", id.uuidString, "--if-updated-at", "42", "--json", "--", "--json", "-h",
    ]), case .request(let list) = try SnipSnapCLIParser.parse(["list", "--list", "--json"])
    else { return XCTFail("Expected legacy requests.") }
    XCTAssertEqual(add.input, .add(textArguments: ["--json", "-h"], list: "--json",
                                  sessionTitle: "--help", branchName: "topic"))
    XCTAssertTrue(add.json)
    XCTAssertEqual(update.input, .updateSnip(id: id, expectedUpdatedAt: Date(timeIntervalSinceReferenceDate: 42),
                                           textArguments: ["--json", "-h"]))
    XCTAssertTrue(update.json)
    XCTAssertEqual(list.input, .action(.listSnips(list: "--json")))
    XCTAssertFalse(list.json)
    XCTAssertFalse(SnipCLIExtendedParser.requestsJSON(["list", "--list", "--json"]))
  }

  func testGlobalsAfterTerminatorRemainLiteralAcrossSearchCommands() throws {
    let requestID = UUID()
    let arguments = ["search", "--", "--json", "--request-id", requestID.uuidString, "--help"]
    guard case .request(let options) = try SnipSnapCLIParser.parse(arguments) else {
      return XCTFail("Expected a literal library search.")
    }
    XCTAssertEqual(options.input, .action(.extended(.library(.query(.init(
      text: "--json --request-id \(requestID.uuidString) --help"))))))
    XCTAssertFalse(options.json)
    XCTAssertNil(options.requestID)
    XCTAssertFalse(SnipCLIExtendedParser.requestsJSON(arguments))
  }
}
