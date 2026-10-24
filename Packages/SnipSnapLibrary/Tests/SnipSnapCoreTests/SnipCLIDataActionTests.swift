import Foundation
import SnipSnapCore
import XCTest

final class SnipCLIDataActionTests: XCTestCase {
  func testMutationCompactionRemovesContentPathsAndSelectorsAndStillDecodes() throws {
    let actions: [SnipCLIDataAction] = [
      .exportBackup(path: "/private/secret"),
      .saveDraft(list: "Secret list", text: "Secret text", attachmentPaths: ["/private/file"],
                 expectedRevision: "revision"),
      .resolveRecovery(id: UUID(), choice: .editSnip,
        editedSnip: Snip(content: "Secret recovered text", origin: .quickEntry),
        editedList: nil, expectedRevision: "revision"),
      .resolveRecovery(id: UUID(), choice: .editList, editedSnip: nil,
        editedList: SnipList(id: UUID(), name: "Secret list", systemImage: "folder", position: 1),
        expectedRevision: "revision"),
      .moveDraft(list: "Secret source", destination: "Secret destination", expectedRevision: "revision",
                 expectedDestinationRevision: "revision"),
      .clearDraft(list: "Secret list", expectedRevision: "revision"),
      .saveDraftAsSnip(list: "Secret source", destination: "Secret destination", expectedRevision: "revision")
    ]
    for action in actions {
      let encoded = try JSONEncoder().encode(action.compacted)
      let text = String(decoding: encoded, as: UTF8.self)
      XCTAssertFalse(text.contains("Secret"))
      XCTAssertFalse(text.contains("private"))
      XCTAssertEqual(try JSONDecoder().decode(SnipCLIDataAction.self, from: encoded), action.compacted)
      XCTAssertFalse(action.isReadOnly)
    }
    XCTAssertTrue(SnipCLIDataAction.previewBackup(path: "/backup").isReadOnly)
    XCTAssertTrue(SnipCLIDataAction.listRecoveredDrafts.isReadOnly)
  }

  func testDraftRevisionIncludesScopeTextAndAttachmentPaths() {
    let id = UUID()
    let original = SnipCLIDraft(listID: id, text: "First", attachmentPaths: ["/a"], scope: "local")
    for changed in [
      SnipCLIDraft(listID: id, text: "Second", attachmentPaths: ["/a"], scope: "local"),
      SnipCLIDraft(listID: id, text: "First", attachmentPaths: ["/b"], scope: "local"),
      SnipCLIDraft(listID: id, text: "First", attachmentPaths: ["/a"], scope: "other")
    ] { XCTAssertNotEqual(original.revision, changed.revision) }
  }
}
