@testable import SnipSnapCLI
import SnipSnapCore
import Foundation
import XCTest

final class SnipCLILibraryParserTests: XCTestCase {
  func testBulkDoneBindsEverySnipToItsRevision() throws {
    let first = UUID(), second = UUID()
    let revision = String(repeating: "a", count: 64)
    XCTAssertThrowsError(try SnipCLILibraryParser.parse(["snips", "done", first.uuidString]))
    let parsed = try SnipCLILibraryParser.parse([
      "snips", "done", first.uuidString, second.uuidString,
      "--if-snip-revision", "\(first):\(revision)",
      "--if-snip-revision", "\(second):\(revision)",
    ])
    XCTAssertEqual(parsed, .extended(.library(.setDone(snips: [
      .init(id: first, revision: revision), .init(id: second, revision: revision),
    ], done: true))))
  }

  func testLegacyCommandsAndAttachmentCacheAreLeftForTheirOwners() throws {
    for command in [["add", "ordinary text"], ["lists", "show", "Inbox"], ["attachments", "cache", "clear"]] {
      XCTAssertNil(try SnipCLILibraryParser.parse(command))
    }
  }

  func testDestructiveCommandsRequireConfirmationAndCompleteGuards() throws {
    let id = UUID().uuidString
    let revision = String(repeating: "b", count: 64)
    for command in [
      ["snips", "delete", id, "--if-snip-revision", revision],
      ["snips", "delete", id, "--yes"],
      ["attachments", "remove", id, UUID().uuidString, "--if-snip-revision", revision],
      ["snips", "pin", id, "--if-snip-revision", revision, "--if-snip-revision", revision],
    ] { XCTAssertThrowsError(try SnipCLILibraryParser.parse(command)) }
    XCTAssertNotNil(try SnipCLILibraryParser.parse(["snips", "delete", id, "--if-snip-revision", revision, "--yes"]))
  }

  func testSearchAndExplicitCopyState() throws {
    XCTAssertEqual(try SnipCLILibraryParser.parse([
      "search", "release notes", "--completion", "not-done", "--pinned", "off", "--sort", "manual", "--limit", "4"
    ]), .extended(.library(.query(.init(text: "release notes", completion: .notDone, pinned: false, sort: .manual, limit: 4)))))
    let id = UUID(), revision = String(repeating: "c", count: 64)
    XCTAssertEqual(try SnipCLILibraryParser.parse([
      "snips", "copy", id.uuidString, "--if-snip-revision", revision, "--mark-done", "off"
    ]), .extended(.library(.copy(snips: [.init(id: id, revision: revision)], markDone: false))))
    XCTAssertThrowsError(try SnipCLILibraryParser.parse(["search", "--limit", "0"]))
    XCTAssertThrowsError(try SnipCLILibraryParser.parse(["search", "--pinned", "toggle"]))
  }
}
