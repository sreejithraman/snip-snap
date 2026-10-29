import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class DirectSnipLibraryUserActionsTests: XCTestCase {
  func testDeleteCanBeRestoredOnceWithItsToken() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let added = try await library.add(content: "Keep me", origin: .quickEntry)
    let snip = try XCTUnwrap(added)
    let actions = DirectSnipLibraryUserActions(library: library)
    let token = UUID()

    let deleted = try await actions.delete(ids: [snip.id], token: token, sortedBy: .manual)
    XCTAssertTrue(deleted.snapshot.snips.isEmpty)
    let wrongTokenResult = try await actions.restoreDeletion(token: UUID(), sortedBy: .manual)
    XCTAssertNil(wrongTokenResult)

    let restored = try await actions.restoreDeletion(token: token, sortedBy: .manual)
    XCTAssertEqual(restored?.snapshot.snips.map(\.id), [snip.id])
    let secondRestore = try await actions.restoreDeletion(token: token, sortedBy: .manual)
    XCTAssertNil(secondRestore)
  }

  func testNewDeleteReplacesThePriorPendingDelete() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let firstAdded = try await library.add(content: "First", origin: .quickEntry)
    let secondAdded = try await library.add(content: "Second", origin: .quickEntry)
    let first = try XCTUnwrap(firstAdded)
    let second = try XCTUnwrap(secondAdded)
    let actions = DirectSnipLibraryUserActions(library: library)
    let firstToken = UUID()
    let secondToken = UUID()

    _ = try await actions.delete(ids: [first.id], token: firstToken, sortedBy: .manual)
    _ = try await actions.delete(ids: [second.id], token: secondToken, sortedBy: .manual)

    let oldRestore = try await actions.restoreDeletion(token: firstToken, sortedBy: .manual)
    XCTAssertNil(oldRestore)
    let restored = try await actions.restoreDeletion(token: secondToken, sortedBy: .manual)
    XCTAssertEqual(restored?.snapshot.snips.map(\.id), [second.id])
  }

  func testFailedCommandKeepsThePendingDelete() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let added = try await library.add(content: "Keep me", origin: .quickEntry)
    let snip = try XCTUnwrap(added)
    let actions = DirectSnipLibraryUserActions(library: library)
    let token = UUID()

    _ = try await actions.delete(ids: [snip.id], token: token, sortedBy: .manual)
    do {
      _ = try await actions.perform(
        command: .update(
          id: UUID(),
          content: "Missing",
          attachmentURLs: nil,
          expectedUpdatedAt: nil,
          now: Date()
        ),
        sortedBy: .manual
      )
      XCTFail("Updating a missing snip must fail.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .snipNotFound)
    }

    let restored = try await actions.restoreDeletion(token: token, sortedBy: .manual)
    XCTAssertEqual(restored?.snapshot.snips.map(\.id), [snip.id])
  }

  func testDeletedAttachmentIsKeptUntilTheToastIsDiscarded() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let input = root.appendingPathComponent("note.txt")
    try Data("Note".utf8).write(to: input)
    let added = try await library.add(
      content: "Attached",
      origin: .quickEntry,
      attachmentURLs: [input]
    )
    let snip = try XCTUnwrap(added)
    let storedURL = library.attachmentURL(for: try XCTUnwrap(snip.attachments.first))
    let actions = DirectSnipLibraryUserActions(library: library)
    let token = UUID()

    _ = try await actions.delete(ids: [snip.id], token: token, sortedBy: .manual)
    XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))

    await actions.discardDeletion(token: token, sortedBy: .manual)
    XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
  }

  func testBackendNoOpsKeepDeletedAttachmentsAndUndoUntilARealMutation() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let input = root.appendingPathComponent("note.txt")
    try Data("Retained note".utf8).write(to: input)
    let added = try await library.add(content: "Deleted", origin: .quickEntry, attachmentURLs: [input])
    let deleted = try XCTUnwrap(added)
    let remainingResult = try await library.add(content: "Remaining", origin: .quickEntry)
    let remaining = try XCTUnwrap(remainingResult)
    let storedURL = library.attachmentURL(for: try XCTUnwrap(deleted.attachments.first))
    let actions = DirectSnipLibraryUserActions(library: library)
    let token = UUID()
    _ = try await actions.delete(ids: [deleted.id], token: token, sortedBy: .manual)
    let before = try await library.checkedSnapshot(sortedBy: .manual)
    let noOps: [SnipLibraryCommand] = [
      .moveChronologically(ids: [remaining.id], to: remaining.listID),
      .add(content: remaining.content, origin: .quickEntry, source: nil,
           listID: remaining.listID, attachmentURLs: [], requestID: remaining.requestID, now: Date()),
      .batch([]),
    ]

    for command in noOps {
      let result = try await actions.performWithResult(command: command, sortedBy: .manual)
      XCTAssertFalse(result.didChange)
      XCTAssertEqual(result.update.snapshot, before)
      XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
    }

    for ids: Set<UUID> in [[], [UUID()]] {
      let result = try await actions.deleteWithResult(ids: ids, token: UUID(), sortedBy: .manual)
      XCTAssertFalse(result.didChange)
      XCTAssertEqual(result.update.snapshot, before)
      XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
    }

    let restored = try await actions.restoreDeletion(token: token, sortedBy: .manual)
    XCTAssertTrue(try XCTUnwrap(restored).snapshot.snips.contains { $0.id == deleted.id })
    XCTAssertEqual(try Data(contentsOf: storedURL), Data("Retained note".utf8))

    let nextToken = UUID()
    let nextDeletion = try await actions.deleteWithResult(ids: [deleted.id], token: nextToken, sortedBy: .manual)
    XCTAssertTrue(nextDeletion.didChange)
    let mutation = try await actions.performWithResult(command: .togglePinned(id: remaining.id), sortedBy: .manual)
    XCTAssertTrue(mutation.didChange)
    XCTAssertEqual(mutation.update.outcome, .none)
    XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    let stale = try await actions.restoreDeletion(token: nextToken, sortedBy: .manual)
    XCTAssertNil(stale)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("DirectSnipLibraryUserActionsTests-\(UUID().uuidString)")
  }
}
