import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

final class SnipCLILibraryWorkflowTests: XCTestCase {
  func testPinnedSnipRemainsNotDoneWhenCopiedAndUnpinned() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let snip = try await add("Reusable", to: library)
    var snapshot = try await library.checkedSnapshot(sortedBy: .manual)
    for action in [SnipCLILibraryAction.setDone(snips: [reference(snip)], done: true)] {
      snapshot = try await library.perform(action.command(in: snapshot), sortedBy: .manual).snapshot
    }
    let done = try XCTUnwrap(snapshot.snips.first)
    XCTAssertTrue(done.isDone)
    snapshot = try await library.perform(SnipCLILibraryAction.setPinned(snips: [reference(done)], pinned: true).command(in: snapshot), sortedBy: .manual).snapshot
    let pinned = try XCTUnwrap(snapshot.snips.first)
    XCTAssertTrue(pinned.isPinned)
    XCTAssertFalse(pinned.isDone)
    snapshot = try await library.perform(SnipCLILibraryAction.copy(snips: [reference(pinned)], markDone: true).command(in: snapshot), sortedBy: .manual).snapshot
    let copied = try XCTUnwrap(snapshot.snips.first)
    XCTAssertEqual(copied.pinnedAt, pinned.pinnedAt)
    XCTAssertFalse(copied.isDone)
    snapshot = try await library.perform(SnipCLILibraryAction.setPinned(snips: [reference(copied)], pinned: false).command(in: snapshot), sortedBy: .manual).snapshot
    XCTAssertFalse(try XCTUnwrap(snapshot.snips.first).isDone)
  }

  func testBulkGuardRejectsConcurrentEditWithoutChangingAnySnip() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    _ = try await add("First", to: library)
    _ = try await add("Second", to: library)
    let snapshot = try await library.checkedSnapshot(sortedBy: .manual)
    let action = SnipCLILibraryAction.setDone(snips: snapshot.snips.map(reference), done: true)
    let planned = try action.command(in: snapshot)
    let changed = try XCTUnwrap(snapshot.snips.first)
    _ = try await library.perform(.update(id: changed.id, content: "Concurrent edit", attachmentURLs: nil, expectedUpdatedAt: changed.updatedAt, now: Date()), sortedBy: .manual)
    do {
      _ = try await library.perform(planned, sortedBy: .manual)
      XCTFail("The batch must reject stale state before setting any snip Done.")
    } catch SnipLibraryError.snipChanged {}
    let current = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(current.snips.allSatisfy { !$0.isDone })
    XCTAssertThrowsError(try action.command(in: current)) { XCTAssertEqual($0 as? SnipLibraryError, .snipChanged) }
  }

  func testCopyChangesOnlySnipsThatNeedMarkingDone() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let reusable = try await add("Already Done", to: library)
    _ = try await library.perform(.setDone(ids: [reusable.id], done: true), sortedBy: .manual)
    let ordinary = try await add("Not Done", to: library)
    let before = try await library.checkedSnapshot(sortedBy: .manual)
    let done = try XCTUnwrap(before.snips.first { $0.id == reusable.id })
    let action = SnipCLILibraryAction.copy(snips: [reference(done), reference(ordinary)], markDone: true)
    let update = try await library.perform(action.command(in: before), sortedBy: .manual)
    XCTAssertEqual(update.snapshot.snips.first { $0.id == done.id }, done)
    XCTAssertTrue(try XCTUnwrap(update.snapshot.snips.first { $0.id == ordinary.id }).isDone)
  }

  func testAttachmentReplacementPreservesOtherFilesAndRejectsStaleRemoval() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt"), replacement = root.appendingPathComponent("replacement.txt")
    try Data("original".utf8).write(to: first)
    try Data("keep".utf8).write(to: second)
    try Data("new bytes".utf8).write(to: replacement)
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let added = try await library.perform(.add(content: "Files", origin: .agent, source: nil, listID: SnipList.inboxID, attachmentURLs: [first, second], requestID: UUID(), now: Date()), sortedBy: .manual)
    let snip = try XCTUnwrap(added.snapshot.snips.first)
    let originalAttachment = try XCTUnwrap(snip.attachments.first)
    let stale = SnipCLILibraryAction.editAttachments(snip: reference(snip), add: [], remove: [originalAttachment.id], replace: [:])
    let action = SnipCLILibraryAction.editAttachments(snip: reference(snip), add: [], remove: [], replace: [originalAttachment.id.uuidString: replacement.path])
    let updated = try await library.perform(action.command(in: added.snapshot), sortedBy: .manual)
    let result = try XCTUnwrap(updated.snapshot.snips.first)
    XCTAssertEqual(result.attachments.map(\.fileName), ["replacement.txt", "second.txt"])
    let url = try XCTUnwrap(updated.snapshot.attachmentURLs[result.attachments[0].id])
    XCTAssertEqual(try Data(contentsOf: url), Data("new bytes".utf8))
    XCTAssertThrowsError(try stale.command(in: updated.snapshot))
  }

  func testGuardedDeleteUndoKeepsAttachmentsAndRestoresOnlyOnce() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("proof.txt")
    try Data("retained bytes".utf8).write(to: source)
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let added = try await library.perform(.add(content: "", origin: .agent, source: nil, listID: SnipList.inboxID, attachmentURLs: [source], requestID: UUID(), now: Date()), sortedBy: .manual)
    let snip = try XCTUnwrap(added.snapshot.snips.first)
    let session = SavedSnipsSession(library: library)
    let token = UUID()
    let deleted = try await session.delete(ids: [snip.id], token: token, expectation: .init(expectedSnips: [snip]), sortedBy: .manual)
    XCTAssertTrue(deleted.snapshot.snips.isEmpty)
    let restored = try await session.restoreDeletion(token: token, sortedBy: .manual)
    XCTAssertEqual(restored?.snapshot.snips.map(\.id), [snip.id])
    let attachment = try XCTUnwrap(snip.attachments.first)
    let url = try XCTUnwrap(restored?.snapshot.attachmentURLs[attachment.id])
    XCTAssertEqual(try Data(contentsOf: url), Data("retained bytes".utf8))
    let repeated = try await session.restoreDeletion(token: token, sortedBy: .manual)
    XCTAssertNil(repeated)
  }

  @MainActor
  func testCommonRequestStoreReplaysDeleteTokenThenCompactsPrivateResult() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let scope = "library-scope"
    try await store.publishActiveScopeToken(scope)
    let request = SnipCLIRequest(action: .extended(.library(.delete(snips: [
      .init(id: UUID(), revision: String(repeating: "a", count: 64))
    ]))), scopeToken: scope)
    _ = try await store.enqueue(request)
    await store.processPending { request in
      SnipCLIReceipt(request: request, status: .success,
        extendedResult: .library(.init(undoToken: request.requestID, paths: ["/private/file"])))
    }
    guard case .completed(let first) = try await store.enqueue(request) else { return XCTFail("Expected replay.") }
    XCTAssertEqual(first.extendedResult, .library(.init(undoToken: request.requestID, paths: ["/private/file"])))
    await store.processPending { request in
      XCTFail("Replay must not execute the deletion again.")
      return SnipCLIReceipt(request: request, status: .failed)
    }
    try await store.releaseReceipt(request.requestID)
    guard case .completed(let replay) = try await store.enqueue(request) else { return XCTFail("Expected compact replay.") }
    XCTAssertNil(replay.extendedResult)
    XCTAssertEqual(replay.status, .success)
  }

  func testMoveUsesReviewedDestinationAndManualOrderThenMergeUsesLibrarySemantics() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let first = try await add("First", to: library)
    let second = try await add("Second", to: library)
    let listUpdate = try await library.perform(.createList(name: "Work", systemImage: "briefcase"), sortedBy: .manual)
    guard case .listCreated(let list) = listUpdate.outcome else { return XCTFail("Expected list.") }
    var snapshot = listUpdate.snapshot
    var action = SnipCLILibraryAction.move(snips: [reference(first), reference(second)], listID: list.id,
      before: nil, listRevision: SnipCLIListRevision.token(list: list, memberIDs: []))
    snapshot = try await library.perform(action.command(in: snapshot), sortedBy: .manual).snapshot
    XCTAssertEqual(Snip.sorted(snapshot.snips.filter { $0.listID == list.id }, by: .manual).map(\.id), [first.id, second.id])
    let moving = try XCTUnwrap(snapshot.snips.first { $0.id == second.id })
    action = .move(snips: [reference(moving)], listID: list.id, before: first.id,
      listRevision: SnipCLIListRevision.token(list: list, memberIDs: [first.id, second.id]))
    snapshot = try await library.perform(action.command(in: snapshot), sortedBy: .manual).snapshot
    XCTAssertEqual(Snip.sorted(snapshot.snips, by: .manual).map(\.id), [second.id, first.id])
    let merge = SnipCLILibraryAction.merge(snips: snapshot.snips.map(reference))
    let merged = try await library.perform(merge.command(in: snapshot), sortedBy: .manual)
    guard case .merged(let result) = merged.outcome else { return XCTFail("Expected merged snip.") }
    XCTAssertEqual(merged.snapshot.snips.count, 1)
    XCTAssertEqual(result.listID, list.id)
    XCTAssertTrue(result.content.contains("First"))
    XCTAssertTrue(result.content.contains("Second"))
  }

  func testListEditPreservesUnspecifiedDetailsAndMoveGuardsAnchor() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let created = try await library.perform(.createList(name: "Work", systemImage: "briefcase", color: .blue), sortedBy: .manual)
    guard case .listCreated(let list) = created.outcome else { return XCTFail("Expected list.") }
    let action = SnipCLILibraryAction.editList(id: list.id,
      revision: SnipCLIListRevision.token(list: list, memberIDs: []), name: nil, icon: "star", color: "none")
    let updated = try await library.perform(action.command(in: created.snapshot), sortedBy: .manual)
    let edited = try XCTUnwrap(updated.snapshot.lists.first { $0.id == list.id })
    XCTAssertEqual(edited.name, "Work")
    XCTAssertEqual(edited.systemImage, "star")
    XCTAssertNil(edited.color)
    let anchorUpdate = try await library.perform(.createList(name: "Home", systemImage: "house"), sortedBy: .manual)
    guard case .listCreated(let anchor) = anchorUpdate.outcome else { return XCTFail("Expected anchor list.") }
    let revisions = Dictionary(uniqueKeysWithValues: [edited, anchor].map {
      ($0.id.uuidString, SnipCLIListRevision.token(list: $0, memberIDs: []))
    })
    let move = SnipCLILibraryAction.moveList(id: list.id, before: anchor.id, revisions: revisions)
    let command = try move.command(in: anchorUpdate.snapshot)
    _ = try await library.perform(.updateList(id: anchor.id, name: "Household", systemImage: "house"), sortedBy: .manual)
    do {
      _ = try await library.perform(command, sortedBy: .manual)
      XCTFail("A changed anchor must reject the planned move.")
    } catch SnipLibraryError.snipChanged {}
  }

  private func add(_ content: String, to library: any SnipLibrary) async throws -> Snip {
    let update = try await library.perform(.add(content: content, origin: .agent, source: nil,
      listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: Date()), sortedBy: .manual)
    guard case .add(.added(let id)) = update.outcome else { throw SnipLibraryError.invalidCommand }
    return try XCTUnwrap(update.snapshot.snips.first { $0.id == id })
  }
  private func reference(_ snip: Snip) -> SnipCLISnipReference {
    .init(id: snip.id, revision: SnipCLIItemRevision.token(snip: snip))
  }
  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("SnipCLILibrary-\(UUID())")
  }
}
