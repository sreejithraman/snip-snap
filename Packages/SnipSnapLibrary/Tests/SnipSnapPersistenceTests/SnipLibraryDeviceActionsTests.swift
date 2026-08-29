import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class SnipLibraryDeviceActionsTests: XCTestCase {
  func testStorePatchStartsFromTheStateInsideTheLockedWrite() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("snips.store")
    let first = try SwiftDataSnipLibrary(storeURL: storeURL)
    let second = try SwiftDataSnipLibrary(storeURL: storeURL)
    let list = try await createList(named: "Work", in: first)
    let snip = try await add("Original", in: first)
    let remoteView = await second.snapshot(sortedBy: .manual)
    let remoteSnip = try XCTUnwrap(remoteView.snips.first { $0.id == snip.id })
    _ = try await second.perform(
      .update(
        id: snip.id,
        content: "Remote text",
        attachmentURLs: nil,
        expectedUpdatedAt: remoteSnip.updatedAt,
        now: Date(timeIntervalSince1970: 500)
      ),
      sortedBy: .manual
    )

    let update = try await first.perform(
      .moveChronologically(ids: [snip.id], to: list.id),
      sortedBy: .manual
    )

    let change = try XCTUnwrap(update.devicePatch?.snips.first)
    XCTAssertEqual(change.before?.content, "Remote text")
    XCTAssertEqual(change.after?.content, "Remote text")
    XCTAssertEqual(change.before?.listID, SnipList.inboxID)
    XCTAssertEqual(change.after?.listID, list.id)
  }

  func testUndoChangesOnlyFieldsOwnedByTheDeviceAction() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let list = try await createList(named: "Work", in: library)
    let snip = try await add("Local text", in: library)
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )

    _ = try await actions.perform(
      name: "Move",
      command: .moveChronologically(ids: [snip.id], to: list.id),
      sortedBy: .manual
    )
    let movedSnapshot = await library.snapshot(sortedBy: .manual)
    let moved = try XCTUnwrap(movedSnapshot.snips.first { $0.id == snip.id })
    _ = try await library.perform(
      .update(
        id: snip.id,
        content: "Remote text",
        attachmentURLs: nil,
        expectedUpdatedAt: moved.updatedAt,
        now: Date(timeIntervalSince1970: 500)
      ),
      sortedBy: .manual
    )

    let undoResult = try await actions.undo(sortedBy: .manual)
    let undone = try XCTUnwrap(undoResult)

    let current = try XCTUnwrap(undone.snapshot.snips.first { $0.id == snip.id })
    XCTAssertEqual(current.content, "Remote text")
    XCTAssertEqual(current.listID, SnipList.inboxID)
    let state = try await actions.state(sortedBy: .manual)
    XCTAssertFalse(state.canUndo)
    XCTAssertTrue(state.canRedo)
    XCTAssertEqual(state.redoTitle, "Redo Move")
  }

  func testRemoteChangeToAnOwnedFieldRemovesUnsafeUndoEntry() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let work = try await createList(named: "Work", in: library)
    let later = try await createList(named: "Later", in: library)
    let snip = try await add("Text", in: library)
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )
    _ = try await actions.perform(
      name: "Move",
      command: .moveChronologically(ids: [snip.id], to: work.id),
      sortedBy: .manual
    )

    _ = try await library.perform(
      .moveChronologically(ids: [snip.id], to: later.id),
      sortedBy: .manual
    )

    let state = try await actions.state(sortedBy: .manual)
    XCTAssertFalse(state.canUndo)
    let undoResult = try await actions.undo(sortedBy: .manual)
    XCTAssertNil(undoResult)
    let current = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(current.snips.first { $0.id == snip.id }?.listID, later.id)
  }

  func testUndoAndRedoHistorySurvivesReopen() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("snips.store")
    let journalURL = directory.appendingPathComponent("device-actions.json")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let list = try await createList(named: "Work", in: library)
    let snip = try await add("Text", in: library)
    var actions: SnipLibraryDeviceActions? = SnipLibraryDeviceActions(
      library: library,
      journalURL: journalURL
    )
    _ = try await actions?.perform(
      name: "Move",
      command: .moveChronologically(ids: [snip.id], to: list.id),
      sortedBy: .manual
    )

    actions = nil
    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
    actions = SnipLibraryDeviceActions(library: reopenedLibrary, journalURL: journalURL)
    let undoResult = try await actions?.undo(sortedBy: .manual)
    XCTAssertEqual(
      undoResult?.snapshot.snips.first { $0.id == snip.id }?.listID,
      SnipList.inboxID
    )

    actions = nil
    let reopenedAgain = try SwiftDataSnipLibrary(storeURL: storeURL)
    let finalActions = SnipLibraryDeviceActions(library: reopenedAgain, journalURL: journalURL)
    let redoResult = try await finalActions.redo(sortedBy: .manual)
    XCTAssertEqual(redoResult?.snapshot.snips.first { $0.id == snip.id }?.listID, list.id)
  }

  func testFailedActionDoesNotReplaceExistingUndoHistory() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let list = try await createList(named: "Work", in: library)
    let snip = try await add("Text", in: library)
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )
    _ = try await actions.perform(
      name: "Move",
      command: .moveChronologically(ids: [snip.id], to: list.id),
      sortedBy: .manual
    )

    do {
      _ = try await actions.perform(
        name: "Delete List",
        command: .deleteList(id: UUID()),
        sortedBy: .manual
      )
      XCTFail("Expected the invalid action to fail")
    } catch SnipLibraryError.invalidList {
    }

    let state = try await actions.state(sortedBy: .manual)
    XCTAssertEqual(state.undoTitle, "Undo Move")
  }

  func testJournalWriteFailureDropsUnsafeHistory() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let list = try await createList(named: "Work", in: library)
    let snip = try await add("Text", in: library)
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory
    )

    _ = try await actions.perform(
      name: "Move",
      command: .moveChronologically(ids: [snip.id], to: list.id),
      sortedBy: .manual
    )

    let state = try await actions.state(sortedBy: .manual)
    XCTAssertFalse(state.canUndo)
    let current = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(current.snips.first { $0.id == snip.id }?.listID, list.id)
  }

  private func add(
    _ content: String,
    in library: any SnipLibrary
  ) async throws -> Snip {
    let update = try await library.perform(
      .add(
        content: content,
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 100)
      ),
      sortedBy: .manual
    )
    return try XCTUnwrap(update.snapshot.snips.first { $0.content == content })
  }

  private func createList(
    named name: String,
    in library: any SnipLibrary
  ) async throws -> SnipList {
    let update = try await library.perform(
      .createList(name: name, systemImage: "folder"),
      sortedBy: .manual
    )
    guard case .listCreated(let list) = update.outcome else {
      throw SnipLibraryError.invalidStore
    }
    return list
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnipLibraryDeviceActionsTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
