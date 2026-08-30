import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class SnipLibraryDeviceActionsTests: XCTestCase {
  func testFactoryRebindsDurableJournalAcrossReplacementAndReopen() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journalURL = directory.appendingPathComponent("device-actions.json")
    let firstLibrary = try SwiftDataSnipLibrary(
      storeURL: directory.appendingPathComponent("first.store")
    )
    let secondLibrary = try SwiftDataSnipLibrary(
      storeURL: directory.appendingPathComponent("second.store")
    )
    let identity = DeviceActionIdentitySource("account-a-generation-a")
    let factory = SnipLibraryUserActionsFactory.durable(
      journalURL: journalURL,
      collectionIdentity: { await identity.current() }
    )
    var actions: (any SnipLibraryUserActions)? = factory.actions(for: firstLibrary)
    _ = try await actions?.perform(
      name: "Add",
      command: .add(
        content: "First account",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 100)
      ),
      sortedBy: .manual
    )
    var state = try await actions?.state(sortedBy: .manual)
    XCTAssertEqual(state?.undoCount, 1)

    actions = factory.actions(for: firstLibrary)
    state = try await actions?.state(sortedBy: .manual)
    XCTAssertEqual(state?.undoCount, 1)

    await identity.set("account-b-generation-b")
    actions = factory.actions(for: secondLibrary)
    state = try await actions?.state(sortedBy: .manual)
    XCTAssertEqual(state?.undoCount, 0)
    _ = try await actions?.perform(
      name: "Add",
      command: .add(
        content: "Second account",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 200)
      ),
      sortedBy: .manual
    )
    actions = nil

    let reopened = factory.actions(for: secondLibrary)
    let reopenedState = try await reopened.state(sortedBy: .manual)
    XCTAssertEqual(reopenedState.undoCount, 1)
    XCTAssertEqual(reopenedState.undoTitle, "Undo Add")
  }

  func testFactoryKeepsAddUndoAfterJSONLibraryReplacement() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("snips.json")
    let factory = SnipLibraryUserActionsFactory.durable(
      journalURL: directory.appendingPathComponent("device-actions.json"),
      collectionIdentity: {
        SnipLibraryCollectionIdentity(digest: Data("same-collection".utf8))
      }
    )
    let firstLibrary = try JSONSnipLibrary(fileURL: storeURL)
    let firstActions = factory.actions(for: firstLibrary)
    _ = try await firstActions.perform(
      name: "Add Snip",
      command: .add(
        content: "Keep me",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date()
      ),
      sortedBy: .chronological
    )
    let beforeReplacement = try await firstActions.state(sortedBy: .chronological)
    XCTAssertEqual(beforeReplacement.undoTitle, "Undo Add Snip")
    let originalSnapshot = try await firstLibrary.checkedSnapshot(sortedBy: .chronological)

    let replacement = try JSONSnipLibrary(fileURL: storeURL)
    let reopenedSnapshot = try await replacement.checkedSnapshot(sortedBy: .chronological)
    let original = try XCTUnwrap(originalSnapshot.snips.first)
    let reopened = try XCTUnwrap(reopenedSnapshot.snips.first)
    XCTAssertTrue(original.deviceFieldsEqual(reopened))
    let rebound = factory.actions(for: replacement)
    let afterReplacement = try await rebound.state(sortedBy: .chronological)

    XCTAssertEqual(afterReplacement.undoTitle, "Undo Add Snip")
  }

  func testNewActionPrunesAttachmentBytesHeldOnlyByClearedRedo() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.txt")
    try Data("redo attachment".utf8).write(to: sourceURL)
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )
    let added = try await actions.perform(
      name: "Add",
      command: .add(
        content: "With file",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [sourceURL],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 100)
      ),
      sortedBy: .manual
    )
    let attachmentURL = try XCTUnwrap(added.snapshot.attachmentURLs.values.first)
    _ = try await actions.undo(sortedBy: .manual)
    XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))

    _ = try await actions.perform(
      name: "Create List",
      command: .createList(name: "Work", systemImage: "folder"),
      sortedBy: .manual
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))
  }

  func testHistoryDepthTrimPrunesAttachmentBytesHeldOnlyByOldestEntry() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.txt")
    try Data("trim attachment".utf8).write(to: sourceURL)
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let added = try await library.perform(
      .add(
        content: "With file",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [sourceURL],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 100)
      ),
      sortedBy: .manual
    )
    let attachmentSnip = try XCTUnwrap(added.snapshot.snips.first)
    let attachmentURL = try XCTUnwrap(added.snapshot.attachmentURLs.values.first)
    let plain = try await add("Plain", in: library)
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )
    _ = try await actions.perform(
      name: "Delete file snip",
      command: .delete(ids: [attachmentSnip.id]),
      sortedBy: .manual
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))

    for index in 0..<100 {
      _ = try await actions.perform(
        name: "Toggle \(index)",
        command: .toggleDone(id: plain.id),
        sortedBy: .manual
      )
    }

    let state = try await actions.state(sortedBy: .manual)
    XCTAssertEqual(state.undoCount, 100)
    XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))
  }

  func testImportUndoKeepsAWriteThatArrivesBetweenTheImportSnapshots() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let imported = Snip(content: "From backup", origin: .quickEntry)
    let remote = Snip(content: "Arrived during import", origin: .quickEntry)
    let library = InterleavingImportLibrary(remoteSnip: remote)
    let preview = try await library.previewImport(
      SnipLibraryTransferSnapshot(
        revision: 0,
        snips: [imported],
        lists: [.inbox],
        attachmentData: [:]
      ),
      transitionID: UUID()
    )
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )

    let result = try await actions.applyImport(preview, sortedBy: .chronological)
    XCTAssertEqual(Set(result.snapshot.snips.map(\.id)), [imported.id, remote.id])

    let undone = try await actions.undo(sortedBy: .chronological)

    XCTAssertEqual(undone?.snapshot.snips.map(\.id), [remote.id])
  }

  func testCollectionChangeRotatesHistoryBeforeStateOrAction() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let list = try await createList(named: "Work", in: library)
    let snip = try await add("Text", in: library)
    let identity = DeviceActionIdentitySource("local-store")
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory.appendingPathComponent("device-actions.json"),
      collectionIdentity: { await identity.current() }
    )
    _ = try await actions.perform(
      name: "Move",
      command: .moveChronologically(ids: [snip.id], to: list.id),
      sortedBy: .manual
    )
    let localState = try await actions.state(sortedBy: .manual)
    XCTAssertEqual(localState.undoCount, 1)

    await identity.set("cloud-account-a-generation-a")

    let rotatedState = try await actions.state(sortedBy: .manual)
    XCTAssertEqual(rotatedState.undoCount, 0)
    _ = try await actions.perform(
      name: "Mark Done",
      command: .setDone(ids: [snip.id], done: true),
      sortedBy: .manual
    )
    let newState = try await actions.state(sortedBy: .manual)
    XCTAssertEqual(newState.undoCount, 1)
    XCTAssertEqual(newState.undoTitle, "Undo Mark Done")
  }

  func testStoreAccountAndGenerationIdentitiesEachRotateHistory() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let snip = try await add("Text", in: library)
    let storeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let firstGeneration = UUID()
    let local = SnipLibraryCollectionIdentityFactory.identity(
      storeID: storeID,
      kind: "localOnly",
      namespace: nil
    )
    let cloudA = SnipLibraryCollectionIdentityFactory.identity(
      storeID: storeID,
      kind: "iCloudSync",
      namespace: namespace(account: "account-a", generation: firstGeneration)
    )
    let cloudB = SnipLibraryCollectionIdentityFactory.identity(
      storeID: storeID,
      kind: "iCloudSync",
      namespace: namespace(account: "account-b", generation: firstGeneration)
    )
    let nextGeneration = SnipLibraryCollectionIdentityFactory.identity(
      storeID: storeID,
      kind: "iCloudSync",
      namespace: namespace(account: "account-b", generation: UUID())
    )
    let identities = [local, cloudA, cloudB, nextGeneration]
    XCTAssertEqual(Set(identities).count, identities.count)
    XCTAssertTrue(identities.allSatisfy { $0.digest.count == 32 })
    let encoded = try JSONEncoder().encode(identities)
    XCTAssertNil(String(decoding: encoded, as: UTF8.self).range(of: "account-a"))
    XCTAssertNil(String(decoding: encoded, as: UTF8.self).range(of: storeID.uuidString))
    let identity = DeviceActionIdentitySource(local)
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory.appendingPathComponent("device-actions.json"),
      collectionIdentity: { await identity.current() }
    )

    for (index, value) in identities.enumerated() {
      await identity.set(value)
      let rotated = try await actions.state(sortedBy: .manual)
      XCTAssertEqual(rotated.undoCount, 0)
      _ = try await actions.perform(
        name: "Set Done \(index)",
        command: .setDone(ids: [snip.id], done: index.isMultiple(of: 2)),
        sortedBy: .manual
      )
      let recorded = try await actions.state(sortedBy: .manual)
      XCTAssertEqual(recorded.undoCount, 1)
    }
  }

  func testCollectionChangeAfterCrashRotatesOnReopenAndStaysRotated() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("snips.store")
    let journalURL = directory.appendingPathComponent("device-actions.json")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let list = try await createList(named: "Work", in: library)
    let snip = try await add("Text", in: library)
    let identity = DeviceActionIdentitySource("local-store")
    var actions: SnipLibraryDeviceActions? = SnipLibraryDeviceActions(
      library: library,
      journalURL: journalURL,
      collectionIdentity: { await identity.current() }
    )
    _ = try await actions?.perform(
      name: "Move",
      command: .moveChronologically(ids: [snip.id], to: list.id),
      sortedBy: .manual
    )

    await identity.set("cloud-account-a-generation-a")
    actions = nil

    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
    actions = SnipLibraryDeviceActions(
      library: reopenedLibrary,
      journalURL: journalURL,
      collectionIdentity: { await identity.current() }
    )
    let rotated = try await actions?.state(sortedBy: .manual)
    XCTAssertEqual(rotated?.undoCount, 0)
    actions = nil

    let reopenedAgain = try SwiftDataSnipLibrary(storeURL: storeURL)
    actions = SnipLibraryDeviceActions(
      library: reopenedAgain,
      journalURL: journalURL,
      collectionIdentity: { await identity.current() }
    )
    let durable = try await actions?.state(sortedBy: .manual)
    XCTAssertEqual(durable?.undoCount, 0)
    _ = try await actions?.perform(
      name: "Mark Done",
      command: .setDone(ids: [snip.id], done: true),
      sortedBy: .manual
    )
    actions = nil

    let finalLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
    let finalActions = SnipLibraryDeviceActions(
      library: finalLibrary,
      journalURL: journalURL,
      collectionIdentity: { await identity.current() }
    )
    let final = try await finalActions.state(sortedBy: .manual)
    XCTAssertEqual(final.undoCount, 1)
    XCTAssertEqual(final.undoTitle, "Undo Mark Done")
  }

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

  func testReconcileRemovesInvalidUndoBelowASafeNewerAction() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let work = try await createList(named: "Work", in: library)
    let later = try await createList(named: "Later", in: library)
    let first = try await add("First", in: library)
    let second = try await add("Second", in: library)
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )
    _ = try await actions.perform(
      name: "Move",
      command: .moveChronologically(ids: [first.id], to: work.id),
      sortedBy: .manual
    )
    _ = try await actions.perform(
      name: "Mark Done",
      command: .setDone(ids: [second.id], done: true),
      sortedBy: .manual
    )
    _ = try await library.perform(
      .moveChronologically(ids: [first.id], to: later.id),
      sortedBy: .manual
    )

    let state = try await actions.state(sortedBy: .manual)

    XCTAssertEqual(state.undoCount, 1)
    XCTAssertEqual(state.undoTitle, "Undo Mark Done")
    let undone = try await actions.undo(sortedBy: .manual)
    XCTAssertEqual(undone?.snapshot.snips.first { $0.id == second.id }?.isDone, false)
    XCTAssertEqual(undone?.snapshot.snips.first { $0.id == first.id }?.listID, later.id)
  }

  func testReconcilePreservesStackedSafeActionsInTheirOrder() async throws {
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
      name: "Move to Work",
      command: .moveChronologically(ids: [snip.id], to: work.id),
      sortedBy: .manual
    )
    _ = try await actions.perform(
      name: "Move to Later",
      command: .moveChronologically(ids: [snip.id], to: later.id),
      sortedBy: .manual
    )

    let state = try await actions.state(sortedBy: .manual)

    XCTAssertEqual(state.undoCount, 2)
    XCTAssertEqual(state.undoTitle, "Undo Move to Later")
    _ = try await actions.undo(sortedBy: .manual)
    let firstUndo = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(firstUndo.snips.first { $0.id == snip.id }?.listID, work.id)
    _ = try await actions.undo(sortedBy: .manual)
    let secondUndo = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(secondUndo.snips.first { $0.id == snip.id }?.listID, SnipList.inboxID)
  }

  func testReconcileRemovesInvalidRedoBelowASafeNewerRedo() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let work = try await createList(named: "Work", in: library)
    let first = try await add("First", in: library)
    let second = try await add("Second", in: library)
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )
    _ = try await actions.perform(
      name: "Move",
      command: .moveChronologically(ids: [first.id], to: work.id),
      sortedBy: .manual
    )
    _ = try await actions.perform(
      name: "Mark Done",
      command: .setDone(ids: [second.id], done: true),
      sortedBy: .manual
    )
    _ = try await actions.undo(sortedBy: .manual)
    _ = try await actions.undo(sortedBy: .manual)
    _ = try await library.perform(
      .setDone(ids: [second.id], done: true),
      sortedBy: .manual
    )

    let state = try await actions.state(sortedBy: .manual)

    XCTAssertEqual(state.redoCount, 1)
    XCTAssertEqual(state.redoTitle, "Redo Move")
    let redone = try await actions.redo(sortedBy: .manual)
    XCTAssertEqual(redone?.snapshot.snips.first { $0.id == first.id }?.listID, work.id)
    XCTAssertEqual(redone?.snapshot.snips.first { $0.id == second.id }?.isDone, true)
  }

  func testRemoteConflictPrunesAttachmentKeptOnlyByRemovedHistory() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let sourceURL = directory.appendingPathComponent("source.txt")
    try Data("attachment".utf8).write(to: sourceURL)
    let added = try await library.perform(
      .add(
        content: "With file",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [sourceURL],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 100)
      ),
      sortedBy: .manual
    )
    let snip = try XCTUnwrap(added.snapshot.snips.first)
    let attachmentURL = try XCTUnwrap(added.snapshot.attachmentURLs.values.first)
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory.appendingPathComponent("device-actions.json")
    )
    _ = try await actions.perform(
      name: "Delete",
      command: .delete(ids: [snip.id]),
      sortedBy: .manual
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))
    var remote = snip
    remote.content = "Remote replacement"
    remote.attachments = []
    _ = try await library.perform(.restore(snips: [remote]), sortedBy: .manual)

    let state = try await actions.state(sortedBy: .manual)

    XCTAssertFalse(state.canUndo)
    XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentURL.path))
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

  func testJSONDeleteReopenUnrelatedActionThenUndoKeepsAttachmentBytes() async throws {
    try await assertDeleteReopenUndoKeepsAttachmentBytes(using: .json)
  }

  func testSwiftDataDeleteReopenUnrelatedActionThenUndoKeepsAttachmentBytes() async throws {
    try await assertDeleteReopenUndoKeepsAttachmentBytes(using: .swiftData)
  }

  func testJSONDirectActionsPruneDeletedAttachmentBytes() async throws {
    try await assertDirectActionsPruneDeletedAttachmentBytes(using: .json)
  }

  func testSwiftDataDirectActionsPruneDeletedAttachmentBytes() async throws {
    try await assertDirectActionsPruneDeletedAttachmentBytes(using: .swiftData)
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

  func testInitialIdentityWriteFailureBlocksTheAction() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
    let list = try await createList(named: "Work", in: library)
    let snip = try await add("Text", in: library)
    let actions = SnipLibraryDeviceActions(
      library: library,
      journalURL: directory
    )

    do {
      _ = try await actions.perform(
        name: "Move",
        command: .moveChronologically(ids: [snip.id], to: list.id),
        sortedBy: .manual
      )
      XCTFail("Expected collection binding to fail before the action")
    } catch {
    }

    let current = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(current.snips.first { $0.id == snip.id }?.listID, SnipList.inboxID)
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

  private func assertDeleteReopenUndoKeepsAttachmentBytes(
    using adapter: DurableTestAdapter
  ) async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = adapter.storeURL(in: directory)
    let journalURL = directory.appendingPathComponent("device-actions.json")
    let sourceURL = directory.appendingPathComponent("source.txt")
    let expectedBytes = Data("durable Undo attachment".utf8)
    try expectedBytes.write(to: sourceURL)

    var library: (any SnipLibrary)? = try adapter.open(storeURL: storeURL)
    var actions: SnipLibraryDeviceActions? = SnipLibraryDeviceActions(
      library: try XCTUnwrap(library),
      journalURL: journalURL
    )
    let added = try await actions?.perform(
      name: "Add",
      command: .add(
        content: "With file",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [sourceURL],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 100)
      ),
      sortedBy: .manual
    )
    let snip = try XCTUnwrap(added?.snapshot.snips.first)
    let attachmentID = try XCTUnwrap(snip.attachments.first?.id)
    let storedURL = try XCTUnwrap(added?.snapshot.attachmentURLs.values.first)
    _ = try await actions?.perform(
      name: "Delete",
      command: .delete(ids: [snip.id]),
      sortedBy: .manual
    )
    XCTAssertEqual(try Data(contentsOf: storedURL), expectedBytes)

    actions = nil
    library = nil
    let reopenedLibrary = try adapter.open(storeURL: storeURL)
    let reopenedActions = SnipLibraryDeviceActions(
      library: reopenedLibrary,
      journalURL: journalURL
    )
    _ = try await reopenedActions.perform(
      name: "Create List",
      command: .createList(name: "After reopen", systemImage: "folder"),
      sortedBy: .manual
    )
    XCTAssertEqual(try Data(contentsOf: storedURL), expectedBytes)
    _ = try await reopenedActions.undo(sortedBy: .manual)
    XCTAssertEqual(try Data(contentsOf: storedURL), expectedBytes)
    let undoResult = try await reopenedActions.undo(sortedBy: .manual)
    let restored = try XCTUnwrap(undoResult)
    let restoredURL = try XCTUnwrap(restored.snapshot.attachmentURLs[attachmentID])

    XCTAssertEqual(restored.snapshot.snips.map(\.id), [snip.id])
    XCTAssertTrue(FileManager.default.fileExists(atPath: restoredURL.path))
    XCTAssertEqual(try Data(contentsOf: restoredURL), expectedBytes)
  }

  private func assertDirectActionsPruneDeletedAttachmentBytes(
    using adapter: DurableTestAdapter
  ) async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.txt")
    try Data("direct attachment".utf8).write(to: sourceURL)
    let library = try adapter.open(storeURL: adapter.storeURL(in: directory))
    let actions = DirectSnipLibraryUserActions(library: library)
    let added = try await actions.perform(
      name: "Add",
      command: .add(
        content: "With file",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [sourceURL],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 100)
      ),
      sortedBy: .manual
    )
    let snip = try XCTUnwrap(added.snapshot.snips.first)
    let storedURL = try XCTUnwrap(added.snapshot.attachmentURLs.values.first)

    _ = try await actions.perform(
      name: "Delete",
      command: .delete(ids: [snip.id]),
      sortedBy: .manual
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
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

  private func namespace(
    account: String,
    generation: UUID
  ) -> ICloudSyncNamespaceBinding {
    ICloudSyncNamespaceBinding(
      scope: "private",
      accountLineage: account,
      generation: generation,
      zones: [ICloudSyncZoneBinding(name: "SnipSnapData", ownerName: "owner")]
    )
  }
}

private enum DurableTestAdapter {
  case json
  case swiftData

  func storeURL(in directory: URL) -> URL {
    switch self {
    case .json:
      directory.appendingPathComponent("snips.json")
    case .swiftData:
      directory.appendingPathComponent("snips.store")
    }
  }

  func open(storeURL: URL) throws -> any SnipLibrary {
    switch self {
    case .json:
      try JSONSnipLibrary(fileURL: storeURL)
    case .swiftData:
      try SwiftDataSnipLibrary(storeURL: storeURL)
    }
  }
}

private actor DeviceActionIdentitySource {
  private var value: SnipLibraryCollectionIdentity

  init(_ value: String) {
    self.value = SnipLibraryCollectionIdentity(digest: Data(value.utf8))
  }

  init(_ value: SnipLibraryCollectionIdentity) {
    self.value = value
  }

  func current() -> SnipLibraryCollectionIdentity {
    value
  }

  func set(_ value: String) {
    self.value = SnipLibraryCollectionIdentity(digest: Data(value.utf8))
  }

  func set(_ value: SnipLibraryCollectionIdentity) {
    self.value = value
  }
}

private actor InterleavingImportLibrary: SnipLibrary {
  private var snips: [Snip] = []
  private let remoteSnip: Snip

  init(remoteSnip: Snip) {
    self.remoteSnip = remoteSnip
  }

  func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
    makeSnapshot(sortedBy: sortMode)
  }

  func checkedSnapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
    makeSnapshot(sortedBy: sortMode)
  }

  func perform(
    _ command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) throws -> SnipLibraryUpdate {
    let before = makeSnapshot(sortedBy: sortMode)
    var state = SnipLibraryState(snips: snips, lists: [.inbox], seenRequestIDs: [])
    let outcome = try state.perform(
      command,
      prepareAttachments: { _, _ in [] },
      pruneAttachments: { _, _ in }
    )
    snips = state.snips
    let after = makeSnapshot(sortedBy: sortMode)
    return SnipLibraryUpdate(
      snapshot: after,
      outcome: outcome,
      devicePatch: .between(before, after)
    )
  }

  func transferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot {
    SnipLibraryTransferSnapshot(
      revision: revision,
      snips: snips,
      lists: [.inbox],
      attachmentData: [:]
    )
  }

  func previewImport(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) async throws -> SnipImportPreview {
    let target = try await transferSnapshot(revision: 0)
    let plan = try SnipLibraryTransferPlanner.plan(
      source: source,
      target: target,
      transitionID: transitionID
    )
    return SnipImportPreview(
      totalSnipCount: source.snips.count,
      addedSnipCount: source.snips.count,
      recoveredSnipCount: 0,
      addedListCount: 0,
      addedAttachmentCount: 0,
      transitionID: transitionID,
      source: source,
      targetDigest: plan.targetDigest,
      devicePatch: .between(
        SnipLibrarySnapshot(snips: target.snips, lists: target.lists),
        SnipLibrarySnapshot(snips: plan.snips, lists: plan.lists)
      )
    )
  }

  func applyImport(_ preview: SnipImportPreview) async throws -> SnipImportResult {
    snips = preview.source.snips + [remoteSnip]
    return SnipImportResult(
      snapshot: makeSnapshot(sortedBy: .chronological),
      addedSnipCount: preview.addedSnipCount,
      recoveredSnipCount: preview.recoveredSnipCount
    )
  }

  private func makeSnapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
    SnipLibrarySnapshot(snips: Snip.sorted(snips, by: sortMode), lists: [.inbox])
  }
}
