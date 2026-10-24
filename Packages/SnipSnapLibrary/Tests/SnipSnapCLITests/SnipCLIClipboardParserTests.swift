import Foundation
import SnipSnapCore
import XCTest
@testable import SnipSnapCLI

final class SnipCLIClipboardParserTests: XCTestCase {
    func testListAcceptsSearchPinnedSortAndLimit() throws {
        XCTAssertEqual(try SnipCLIClipboardParser.parse([
            "clipboard", "list", "--search", "meeting", "--pinned",
            "--sort", "oldest", "--limit", "3"
        ]), .extended(.clipboard(.list(.init(
            search: "meeting", onlyPinned: true, newestFirst: false, limit: 3
        )))))
    }

    func testTargetedCommandsRequireEntryRevisionAndDeleteConfirmation() throws {
        let id = UUID()
        let revision = String(repeating: "a", count: 64)
        for command in ["copy", "restore", "pin", "unpin", "delete", "save"] {
            XCTAssertThrowsError(try SnipCLIClipboardParser.parse(["clipboard", command, id.uuidString]))
        }
        XCTAssertThrowsError(try SnipCLIClipboardParser.parse([
            "clipboard", "delete", id.uuidString, "--if-revision", revision
        ]))
        XCTAssertEqual(try SnipCLIClipboardParser.parse([
            "clipboard", "delete", id.uuidString, "--if-revision", revision, "--yes"
        ]), .extended(.clipboard(.delete(id: id, expectedRevision: revision))))
        XCTAssertEqual(try SnipCLIClipboardParser.parse([
            "clipboard", "copy", id.uuidString, "--if-revision", revision
        ]), .extended(.clipboard(.restore(id: id, expectedRevision: revision))))
    }

    func testSaveRequiresExplicitListAndClearRequiresHistoryRevisionAndConfirmation() throws {
        let id = UUID()
        let revision = String(repeating: "1", count: 64)
        XCTAssertThrowsError(try SnipCLIClipboardParser.parse([
            "clipboard", "save", id.uuidString, "--if-revision", revision
        ]))
        XCTAssertEqual(try SnipCLIClipboardParser.parse([
            "clipboard", "save", id.uuidString, "--list", "Research", "--if-revision", revision
        ]), .extended(.clipboard(.save(id: id, list: "Research", expectedRevision: revision))))
        XCTAssertThrowsError(try SnipCLIClipboardParser.parse(["clipboard", "clear", "--yes"]))
        XCTAssertThrowsError(try SnipCLIClipboardParser.parse(["clipboard", "clear", "--if-revision", revision]))
        XCTAssertEqual(try SnipCLIClipboardParser.parse([
            "clipboard", "clear", "--if-revision", revision, "--yes"
        ]), .extended(.clipboard(.clear(expectedRevision: revision))))
    }

    func testRejectsInvalidAndCommandInappropriateInput() {
        let id = UUID().uuidString
        let revision = String(repeating: "a", count: 64)
        for arguments in [
            ["clipboard"], ["clipboard", "unknown"],
            ["clipboard", "show", "not-an-id"],
            ["clipboard", "show", id, "extra"],
            ["clipboard", "status", "--yes"],
            ["clipboard", "list", "--limit", "0"],
            ["clipboard", "list", "--limit", "-1"],
            ["clipboard", "list", "--limit", "NaN"],
            ["clipboard", "list", "--sort", "alphabetical"],
            ["clipboard", "list", "--search"],
            ["clipboard", "list", "--pinned", "--pinned"],
            ["clipboard", "pin", id, "--if-revision", "stale"],
            ["clipboard", "save", id, "--list", " ", "--if-revision", revision],
            ["clipboard", "pause", "--if-revision", revision, "--if-revision", revision]
        ] {
            XCTAssertThrowsError(try SnipCLIClipboardParser.parse(arguments), arguments.joined(separator: " ")) { error in
                guard case SnipSnapCLIError.usage = error else { return XCTFail("Expected usage error, got \(error)") }
            }
        }
    }

    func testUnrelatedCommandsRemainAvailableToOtherParsers() throws {
        for arguments in [[], ["list"], ["add", "saved text"], ["sync", "clipboard", "status"], ["clipboard", "sync", "status"]] {
            XCTAssertNil(try SnipCLIClipboardParser.parse(arguments))
        }
    }
}
