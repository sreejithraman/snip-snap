import Foundation
import SnipSnapCore
import XCTest
@testable import SnipSnapCLI

final class SnipCLIDataParserTests: XCTestCase {
  func testCancelRequiresTheReviewedPreviewIdentity() throws {
    let id = UUID()
    XCTAssertEqual(try SnipCLIDataParser.parse(["backup", "cancel", "--if-preview", id.uuidString]),
      .extended(.data(.cancelBackup(previewID: id))))
    XCTAssertThrowsError(try SnipCLIDataParser.parse(["backup", "cancel"]))
  }
  func testImportRequiresTheReviewedPreviewAndConfirmation() throws {
    let id = UUID()
    XCTAssertThrowsError(try SnipCLIDataParser.parse(["backup", "import", "--yes"]))
    XCTAssertThrowsError(try SnipCLIDataParser.parse(["backup", "import", "--if-preview", id.uuidString]))
    XCTAssertEqual(try SnipCLIDataParser.parse([
      "backup", "import", "--if-preview", id.uuidString, "--yes"
    ]), .extended(.data(.importBackup(previewID: id))))
  }

  func testEmptyDraftSaveCannotBypassClearConfirmation() throws {
    XCTAssertThrowsError(try SnipCLIDataParser.parse([
      "drafts", "save", "Inbox", "--text", "", "--if-draft-revision", String(repeating: "a", count: 64)
    ]))
  }

  func testDraftMovesRequireBothCurrentRevisionsAndRejectUnrelatedFlags() throws {
    let revision = String(repeating: "a", count: 64)
    let move = ["drafts", "move", "Inbox", "--to", "Work", "--if-draft-revision", revision]
    XCTAssertThrowsError(try SnipCLIDataParser.parse(move))
    XCTAssertEqual(try SnipCLIDataParser.parse(move + ["--if-destination-revision", revision]),
      .extended(.data(.moveDraft(list: "Inbox", destination: "Work", expectedRevision: revision,
                                expectedDestinationRevision: revision))))
    XCTAssertThrowsError(try SnipCLIDataParser.parse(["drafts", "list", "--yes"]))
    XCTAssertThrowsError(try SnipCLIDataParser.parse(["backup", "preview", "/backup", "--text", "ignored"]))
    XCTAssertNil(try SnipCLIDataParser.parse(["show", UUID().uuidString]))
  }

  func testEditedRecoveryReadsTheCompleteSnipObject() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("edited.json")
    let snip = Snip(content: "Edited CLI text", origin: .quickEntry)
    try JSONEncoder().encode(snip).write(to: file)
    let id = UUID()
    let revision = String(repeating: "b", count: 64)
    let base = ["recovery", "resolve", id.uuidString, "--choice", "edit-snip",
                "--if-recovery-revision", revision]
    XCTAssertThrowsError(try SnipCLIDataParser.parse(base))
    XCTAssertEqual(try SnipCLIDataParser.parse(base + ["--edited-json", file.path]),
      .extended(.data(.resolveRecovery(id: id, choice: .editSnip, editedSnip: snip,
                                      editedList: nil, expectedRevision: revision))))
  }
}
