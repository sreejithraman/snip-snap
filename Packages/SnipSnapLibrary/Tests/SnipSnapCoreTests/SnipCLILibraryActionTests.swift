import Foundation
import SnipSnapCore
import XCTest

final class SnipCLILibraryActionTests: XCTestCase {
  func testQueryUsesSavedSnipOrderingAndCompletionFilter() throws {
    let older = Snip(createdAt: Date(timeIntervalSince1970: 1), content: "Alpha", origin: .agent)
    let done = Snip(content: "Alpha done", origin: .agent, isDone: true)
    let pin = Snip(content: "Alpha reusable", origin: .agent, pinnedAt: Date())
    let query = SnipCLILibraryQuery(text: "alpha", completion: .notDone, limit: 1)
    let result = try query.snips(in: SnipLibrarySnapshot(snips: [older, done, pin], lists: [.inbox]))
    XCTAssertEqual(result.map(\.id), [pin.id])
  }

  func testAttachmentPathAndListDetailsAreRemovedFromDecodableStoredActions() throws {
    let reference = SnipCLISnipReference(id: UUID(), revision: String(repeating: "a", count: 64))
    let actions: [SnipCLILibraryAction] = [
      .addFiles(content: "private text", list: "private list", paths: ["/private/file"]),
      .editAttachments(snip: reference, add: ["/private/add"], remove: [], replace: [UUID().uuidString: "/private/replacement"]),
      .exportAttachment(snipID: UUID(), attachmentID: UUID(), path: "/private/export"),
      .editList(id: UUID(), revision: "revision", name: "private name", icon: "private icon", color: "blue"),
    ]
    for action in actions {
      let data = try JSONEncoder().encode(action.compacted)
      XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
      XCTAssertEqual(try JSONDecoder().decode(SnipCLILibraryAction.self, from: data), action.compacted)
    }
  }

  func testAttachmentReplacementFingerprintSurvivesDecoding() throws {
    let replacements = Dictionary(uniqueKeysWithValues: (1...16).map {
      (String(format: "00000000-0000-0000-0000-%012d", $0), "/file\($0).txt")
    })
    let action = SnipCLILibraryAction.editAttachments(
      snip: .init(id: UUID(), revision: String(repeating: "a", count: 64)),
      add: [], remove: [], replace: replacements)
    let original = SnipCLIRequest(action: .extended(.library(action)))
    for _ in 0..<8 {
      let decoded = try JSONDecoder().decode(SnipCLIRequest.self, from: JSONEncoder().encode(original))
      XCTAssertEqual(decoded.fingerprint, original.fingerprint,
                     "Replaying the same decoded command must preserve its identity.")
    }
  }
}
