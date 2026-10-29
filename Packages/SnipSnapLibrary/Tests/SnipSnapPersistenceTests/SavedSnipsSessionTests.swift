import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class SavedSnipsSessionTests: XCTestCase {
  func testDoneUndoOnlyReopensNewlyDoneUnpinnedSnips() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    let unfinishedResult = try await library.add(content: "Unfinished", origin: .quickEntry)
    let unfinished = try XCTUnwrap(unfinishedResult)
    let doneResult = try await library.add(content: "Already Done", origin: .quickEntry)
    let done = try XCTUnwrap(doneResult)
    let pinnedResult = try await library.add(content: "Pinned", origin: .quickEntry)
    let pinned = try XCTUnwrap(pinnedResult)
    _ = try await library.perform(.setDone(ids: [done.id], done: true), sortedBy: .manual)
    _ = try await library.perform(.setPinned(ids: [pinned.id], pinned: true), sortedBy: .manual)
    let session = SavedSnipsSession(library: library)

    let changed = try await session.setDone(ids: [unfinished.id, done.id, pinned.id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(changed.undo)
    XCTAssertEqual(undo.count, 1)
    XCTAssertTrue(try XCTUnwrap(changed.update.snapshot.snips.first { $0.id == unfinished.id }).isDone)

    let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    let snips = try XCTUnwrap(restored).snapshot.snips
    XCTAssertFalse(try XCTUnwrap(snips.first { $0.id == unfinished.id }).isDone)
    XCTAssertTrue(try XCTUnwrap(snips.first { $0.id == done.id }).isDone)
    XCTAssertTrue(try XCTUnwrap(snips.first { $0.id == pinned.id }).isPinned)
    XCTAssertFalse(try XCTUnwrap(snips.first { $0.id == pinned.id }).isDone)
  }

  func testOnlyLatestDoneActionCanBeUndoneAndItsTokenIsConsumedOnce() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["First", "Second"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: library)
    let first = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let firstUndo = try XCTUnwrap(first.undo)
    let second = try await session.setDone(ids: [snips[1].id], done: true, sortedBy: .manual)
    let secondUndo = try XCTUnwrap(second.undo)

    let stale = try await session.restoreDone(token: firstUndo.id, sortedBy: .manual)
    XCTAssertNil(stale)
    let restored = try await session.restoreDone(token: secondUndo.id, sortedBy: .manual)
    XCTAssertTrue(try XCTUnwrap(restored?.snapshot.snips.first { $0.id == snips[0].id }).isDone)
    XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first { $0.id == snips[1].id }).isDone)
    let repeated = try await session.restoreDone(token: secondUndo.id, sortedBy: .manual)
    XCTAssertNil(repeated)
  }

  func testUnchangedDoneRequestKeepsThePreviousUndo() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["Snip"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: library)
    let changed = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(changed.undo)

    let unchanged = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    XCTAssertNil(unchanged.undo)
    XCTAssertEqual(unchanged.update.snapshot, changed.update.snapshot)
    let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first).isDone)
  }

  func testSameListMoveKeepsThePreviousDoneUndo() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["Snip"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: library)
    let changed = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(changed.undo)

    let unchanged = try await session.performUserCommand(
      .moveChronologically(ids: [snips[0].id], to: snips[0].listID), sortedBy: .manual
    )
    XCTAssertEqual(unchanged.snapshot, changed.update.snapshot)

    let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first).isDone)
  }

  func testBackendNoOpsPreserveDoneUndoAndReportNoChange() async throws {
    for useUserActions in [true, false] {
      let (root, library, snips) = try await makeLibrary(contents: ["Snip"])
      defer { try? FileManager.default.removeItem(at: root) }
      let session = SavedSnipsSession(library: library)
      let changed = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
      let undo = try XCTUnwrap(changed.undo)

      for command in backendNoOps(for: snips[0]) {
        let result = try await perform(command, on: session, useUserActions: useUserActions)
        XCTAssertFalse(result.didChange)
        XCTAssertEqual(result.update.snapshot, changed.update.snapshot)
      }

      let retainsUndo = await session.retainsUndo(token: undo.id)
      XCTAssertTrue(retainsUndo)
      let retainsUnknownUndo = await session.retainsUndo(token: UUID())
      XCTAssertFalse(retainsUnknownUndo)
      let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
      XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first).isDone)
      let retainsConsumedUndo = await session.retainsUndo(token: undo.id)
      XCTAssertFalse(retainsConsumedUndo)
    }
  }

  func testBackendNoOpsPreserveDeletionUndoAcrossBothCommandBoundaries() async throws {
    for useUserActions in [true, false] {
      let (root, library, snips) = try await makeLibrary(contents: ["Remaining", "Deleted"])
      defer { try? FileManager.default.removeItem(at: root) }
      let session = SavedSnipsSession(library: library)
      let token = UUID()
      let deleted = try await session.delete(ids: [snips[1].id], token: token, sortedBy: .manual)

      for command in backendNoOps(for: snips[0]) {
        let result = try await perform(command, on: session, useUserActions: useUserActions)
        XCTAssertFalse(result.didChange)
        XCTAssertEqual(result.update.snapshot, deleted.snapshot)
      }

      let retainsUndo = await session.retainsUndo(token: token)
      XCTAssertTrue(retainsUndo)
      let restored = try await session.restoreDeletion(token: token, sortedBy: .manual)
      XCTAssertTrue(try XCTUnwrap(restored).snapshot.snips.contains { $0.id == snips[1].id })
      let retainsConsumedUndo = await session.retainsUndo(token: token)
      XCTAssertFalse(retainsConsumedUndo)
    }
  }

  func testDeletingNoSnipsPreservesThePreviousDoneUndo() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["Snip"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: library)
    let changed = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(changed.undo)

    for ids: Set<UUID> in [[], [UUID()]] {
      let update = try await session.delete(ids: ids, token: UUID(), sortedBy: .manual)
      XCTAssertEqual(update.snapshot, changed.update.snapshot)
    }

    let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first).isDone)
  }

  func testDeletingNoSnipsKeepsDeletionUndoAndStillValidatesTheCallerExpectation() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["Remaining", "Deleted"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: library)
    _ = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let token = UUID()
    let deleted = try await session.delete(ids: [snips[1].id], token: token, sortedBy: .manual)

    for ids: Set<UUID> in [[], [UUID()]] {
      let replacementToken = UUID()
      let result = try await session.deleteWithResult(ids: ids, token: replacementToken, sortedBy: .manual)
      XCTAssertFalse(result.didChange)
      XCTAssertEqual(result.update.snapshot, deleted.snapshot)
      let retainsUndo = await session.retainsUndo(token: token)
      XCTAssertTrue(retainsUndo)
      let retainsReplacement = await session.retainsUndo(token: replacementToken)
      XCTAssertFalse(retainsReplacement)
    }

    do {
      _ = try await session.deleteWithResult(
        ids: [], token: UUID(),
        expectation: SnipLibraryExpectation(expectedSnips: [snips[0]]), sortedBy: .manual
      )
      XCTFail("A no-op delete must validate its stale caller expectation.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .snipChanged)
    }

    let restored = try await session.restoreDeletion(token: token, sortedBy: .manual)
    XCTAssertTrue(try XCTUnwrap(restored).snapshot.snips.contains { $0.id == snips[1].id })
  }

  func testRealMutationWithNoneOutcomeInvalidatesDoneUndo() async throws {
    for useUserActions in [true, false] {
      let (root, library, snips) = try await makeLibrary(contents: ["Done", "Pinned"])
      defer { try? FileManager.default.removeItem(at: root) }
      let session = SavedSnipsSession(library: library)
      let changed = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
      let undo = try XCTUnwrap(changed.undo)

      let result = try await perform(
        .togglePinned(id: snips[1].id), on: session, useUserActions: useUserActions
      )
      XCTAssertTrue(result.didChange)
      XCTAssertEqual(result.update.outcome, .none)
      XCTAssertTrue(try XCTUnwrap(result.update.snapshot.snips.first { $0.id == snips[1].id }).isPinned)
      let retainsUndo = await session.retainsUndo(token: undo.id)
      XCTAssertFalse(retainsUndo)
      let stale = try await session.restoreDone(token: undo.id, sortedBy: .manual)
      XCTAssertNil(stale)
    }
  }

  func testRealMutationWithNoneOutcomeInvalidatesDeletionUndo() async throws {
    for useUserActions in [true, false] {
      let (root, library, snips) = try await makeLibrary(contents: ["Remaining", "Deleted"])
      defer { try? FileManager.default.removeItem(at: root) }
      let session = SavedSnipsSession(library: library)
      let token = UUID()
      _ = try await session.delete(ids: [snips[1].id], token: token, sortedBy: .manual)

      let result = try await perform(
        .togglePinned(id: snips[0].id), on: session, useUserActions: useUserActions
      )
      XCTAssertTrue(result.didChange)
      XCTAssertEqual(result.update.outcome, .none)
      let retainsUndo = await session.retainsUndo(token: token)
      XCTAssertFalse(retainsUndo)
      let stale = try await session.restoreDeletion(token: token, sortedBy: .manual)
      XCTAssertNil(stale)
    }
  }

  func testGuardedBackendNoOpValidatesStaleReferencesAndPreservesDoneUndo() async throws {
    for useUserActions in [true, false] {
      let (root, library, snips) = try await makeLibrary(contents: ["Snip"])
      defer { try? FileManager.default.removeItem(at: root) }
      let session = SavedSnipsSession(library: library)
      let changed = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
      let undo = try XCTUnwrap(changed.undo)

      do {
        _ = try await perform(
          .guarded(
            expectation: SnipLibraryExpectation(expectedSnips: snips),
            command: .moveChronologically(ids: [snips[0].id], to: snips[0].listID)
          ),
          on: session, useUserActions: useUserActions
        )
        XCTFail("A guarded no-op must validate its stale references at the backend.")
      } catch {
        XCTAssertEqual(error as? SnipLibraryError, .snipChanged)
      }

      let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
      XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first).isDone)
    }
  }

  func testSuccessfulMutationEndsDoneUndoButFailedMutationKeepsIt() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["First", "Second"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: library)
    let changed = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(changed.undo)
    do {
      _ = try await session.performUserCommand(
        .update(id: UUID(), content: "Missing", attachmentURLs: nil, expectedUpdatedAt: nil, now: Date()),
        sortedBy: .manual
      )
      XCTFail("An update to a missing snip must fail.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .snipNotFound)
    }
    let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first { $0.id == snips[0].id }).isDone)

    let next = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let nextUndo = try XCTUnwrap(next.undo)
    _ = try await session.performLibraryCommand(.togglePinned(id: snips[1].id), sortedBy: .manual)
    let stale = try await session.restoreDone(token: nextUndo.id, sortedBy: .manual)
    XCTAssertNil(stale)
    let snapshot = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(try XCTUnwrap(snapshot.snips.first { $0.id == snips[0].id }).isDone)
  }

  func testDeleteReplacesDoneUndoAndDoneReplacesDeleteUndo() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["First", "Second"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: library)
    let changed = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(changed.undo)
    let deletionToken = UUID()
    _ = try await session.delete(ids: [snips[1].id], token: deletionToken, sortedBy: .manual)
    let staleDone = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    XCTAssertNil(staleDone)

    _ = try await session.setDone(ids: [snips[0].id], done: false, sortedBy: .manual)
    let staleDelete = try await session.restoreDeletion(token: deletionToken, sortedBy: .manual)
    XCTAssertNil(staleDelete)
  }

  func testNoOpDoneKeepsDeleteUndoAvailable() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["First", "Second"])
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await library.perform(.setDone(ids: [snips[0].id], done: true), sortedBy: .manual)
    let session = SavedSnipsSession(library: library)
    let token = UUID()
    _ = try await session.delete(ids: [snips[1].id], token: token, sortedBy: .manual)

    let noOp = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    XCTAssertNil(noOp.undo)
    let restored = try await session.restoreDeletion(token: token, sortedBy: .manual)
    XCTAssertTrue(try XCTUnwrap(restored).snapshot.snips.contains { $0.id == snips[1].id })
  }

  func testDiscardOnlyConsumesTheMatchingDoneUndo() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["Snip"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: library)
    let first = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let firstUndo = try XCTUnwrap(first.undo)
    await session.discardDone(token: UUID())
    let restored = try await session.restoreDone(token: firstUndo.id, sortedBy: .manual)
    XCTAssertNotNil(restored)

    let second = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let secondUndo = try XCTUnwrap(second.undo)
    await session.discardDone(token: secondUndo.id)
    let stale = try await session.restoreDone(token: secondUndo.id, sortedBy: .manual)
    XCTAssertNil(stale)
  }

  func testReplacingTheLibraryInvalidatesDoneUndoEvenWithMatchingSnips() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["Snip"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: library)
    let changed = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(changed.undo)
    let replacement = try JSONSnipLibrary(fileURL: root.appendingPathComponent("replacement.json"))
    _ = try await replacement.perform(.replaceAll(changed.update.snapshot.snips), sortedBy: .manual)

    _ = await session.replaceLibrary(replacement, recoveryScope: nil, sortedBy: .manual)
    let stale = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    XCTAssertNil(stale)
    let snapshot = try await replacement.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(try XCTUnwrap(snapshot.snips.first).isDone)
  }

  func testDoneUndoSkipsRemoteEditsAndMissingSnipsWhileRestoringUnchangedOnes() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["Edited", "Deleted", "Unchanged"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: library)
    let changed = try await session.setDone(ids: Set(snips.map(\.id)), done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(changed.undo)
    XCTAssertEqual(undo.count, 3)
    _ = try await library.perform(
      .update(id: snips[0].id, content: "Remote edit", attachmentURLs: nil, expectedUpdatedAt: nil, now: Date()),
      sortedBy: .manual
    )
    _ = try await library.perform(.delete(ids: [snips[1].id]), sortedBy: .manual)

    let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    let snapshot = try XCTUnwrap(restored).snapshot
    let edited = try XCTUnwrap(snapshot.snips.first { $0.id == snips[0].id })
    XCTAssertEqual(edited.content, "Remote edit")
    XCTAssertTrue(edited.isDone)
    XCTAssertFalse(snapshot.snips.contains { $0.id == snips[1].id })
    XCTAssertFalse(try XCTUnwrap(snapshot.snips.first { $0.id == snips[2].id }).isDone)
  }

  func testCallerExpectationRejectsStaleReferencesEvenForNoOpDone() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["First", "Second"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: library)
    let first = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(first.undo)
    do {
      _ = try await session.setDone(
        ids: [snips[1].id], done: true,
        expectation: SnipLibraryExpectation(expectedSnips: [snips[0]]), sortedBy: .manual
      )
      XCTFail("A caller expectation must reject a stale reference before changing another snip.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .snipChanged)
    }
    do {
      _ = try await session.setDone(
        ids: [snips[0].id], done: true,
        expectation: SnipLibraryExpectation(expectedSnips: [snips[0]]), sortedBy: .manual
      )
      XCTFail("No-op requests must still validate stale caller references.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .snipChanged)
    }
    let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first { $0.id == snips[0].id }).isDone)
    XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first { $0.id == snips[1].id }).isDone)
  }

  func testFailedInverseWriteRetainsDoneUndoForRetry() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["Snip"])
    defer { try? FileManager.default.removeItem(at: root) }
    let controlled = ControlledDoneUndoLibrary(base: library)
    let session = SavedSnipsSession(library: controlled)
    let changed = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(changed.undo)
    await controlled.failNextCommand()

    do {
      _ = try await session.restoreDone(token: undo.id, sortedBy: .manual)
      XCTFail("The inverse write must report persistence failure.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .storeUnavailable)
    }
    let afterFailure = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(try XCTUnwrap(afterFailure.snips.first).isDone)

    for command in backendNoOps(for: snips[0]) {
      let noOp = try await session.performUserCommandWithResult(command, sortedBy: .manual)
      XCTAssertFalse(noOp.didChange)
      XCTAssertEqual(noOp.update.snapshot, afterFailure)
    }

    let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first).isDone)
  }

  func testEditBetweenUndoReadAndWriteRejectsTheGuardAndAllowsSafeRetry() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["Edited", "Unchanged"])
    defer { try? FileManager.default.removeItem(at: root) }
    let controlled = ControlledDoneUndoLibrary(base: library)
    let session = SavedSnipsSession(library: controlled)
    let changed = try await session.setDone(ids: Set(snips.map(\.id)), done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(changed.undo)
    await controlled.performBeforeNextCommand(
      .update(id: snips[0].id, content: "Newer edit", attachmentURLs: nil, expectedUpdatedAt: nil, now: Date())
    )

    do {
      _ = try await session.restoreDone(token: undo.id, sortedBy: .manual)
      XCTFail("The guarded inverse must not overwrite an edit that arrives after its read.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .snipChanged)
    }
    let afterFailure = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(afterFailure.snips.allSatisfy(\.isDone))

    let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    let snapshot = try XCTUnwrap(restored).snapshot
    let edited = try XCTUnwrap(snapshot.snips.first { $0.id == snips[0].id })
    XCTAssertEqual(edited.content, "Newer edit")
    XCTAssertTrue(edited.isDone)
    XCTAssertFalse(try XCTUnwrap(snapshot.snips.first { $0.id == snips[1].id }).isDone)
  }

  func testFailedDoneWritePreservesThePreviousDoneUndo() async throws {
    let (root, library, snips) = try await makeLibrary(contents: ["First", "Second"])
    defer { try? FileManager.default.removeItem(at: root) }
    let controlled = ControlledDoneUndoLibrary(base: library)
    let session = SavedSnipsSession(library: controlled)
    let changed = try await session.setDone(ids: [snips[0].id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(changed.undo)
    await controlled.failNextCommand()

    do {
      _ = try await session.setDone(ids: [snips[1].id], done: true, sortedBy: .manual)
      XCTFail("The failed Done write must be reported.")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .storeUnavailable)
    }
    let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
    XCTAssertTrue(try XCTUnwrap(restored).snapshot.snips.allSatisfy { !$0.isDone })
  }

  private func backendNoOps(for snip: Snip) -> [SnipLibraryCommand] {
    [
      .moveChronologically(ids: [snip.id], to: snip.listID),
      .add(content: snip.content, origin: .quickEntry, source: nil,
           listID: snip.listID, attachmentURLs: [], requestID: snip.requestID, now: Date()),
      .batch([]),
    ]
  }

  private func perform(
    _ command: SnipLibraryCommand,
    on session: SavedSnipsSession,
    useUserActions: Bool
  ) async throws -> SnipLibraryCommandResult {
    if useUserActions {
      try await session.performUserCommandWithResult(command, sortedBy: .manual)
    } else {
      try await session.performLibraryCommandWithResult(command, sortedBy: .manual)
    }
  }

  private func makeLibrary(contents: [String]) async throws -> (URL, JSONSnipLibrary, [Snip]) {
    let root = temporaryDirectory()
    let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
    var snips: [Snip] = []
    for content in contents {
      let added = try await library.add(content: content, origin: .quickEntry)
      snips.append(try XCTUnwrap(added))
    }
    return (root, library, snips)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("SavedSnipsSessionTests-\(UUID())")
  }
}

private actor ControlledDoneUndoLibrary: SnipLibrary {
  private let base: any SnipLibrary
  private var nextCommandFails = false
  private var precedingCommand: SnipLibraryCommand?

  init(base: any SnipLibrary) { self.base = base }

  func failNextCommand() { nextCommandFails = true }

  func performBeforeNextCommand(_ command: SnipLibraryCommand) {
    precedingCommand = command
  }

  func snapshot(sortedBy sortMode: SnipSortMode) async -> SnipLibrarySnapshot {
    await base.snapshot(sortedBy: sortMode)
  }

  func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot {
    try await base.checkedSnapshot(sortedBy: sortMode)
  }

  func perform(_ command: SnipLibraryCommand, sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate {
    if nextCommandFails {
      nextCommandFails = false
      throw SnipLibraryError.storeUnavailable
    }
    if let precedingCommand {
      self.precedingCommand = nil
      _ = try await base.perform(precedingCommand, sortedBy: sortMode)
    }
    return try await base.perform(command, sortedBy: sortMode)
  }
}
