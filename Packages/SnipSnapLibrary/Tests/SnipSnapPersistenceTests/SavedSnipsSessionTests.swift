import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class SavedSnipsSessionTests: XCTestCase {
  func testSwiftDataDoneAcceptsCopiedSnipsAfterSourceNormalizationAndCanBeUndone() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("snips.store"))
    let session = SavedSnipsSession(library: library)
    let sources: [(SnipOrigin, SnipSource?)] = [
      (.quickEntry, nil),
      (.selection, SnipSource(applicationName: "Example", windowTitle: "Document")),
      (.agent, SnipSource(applicationName: "", agentContext: .init(sessionTitle: "Example task"))),
      (.agent, SnipSource(applicationName: "Agent", windowTitle: "Legacy task")),
    ]
    for (origin, source) in sources {
      let requestID = UUID()
      let added = try await library.perform(
        .add(content: "Copy me", origin: origin, source: source, listID: SnipList.inboxID,
             attachmentURLs: [], requestID: requestID,
             now: Date(timeIntervalSinceReferenceDate: 816_000_000.1234567)),
        sortedBy: .manual
      )
      let snip = try XCTUnwrap(added.snapshot.snips.first { $0.requestID == requestID })
      let changed = try await session.setDone(
        ids: [snip.id], done: true,
        expectation: .init(expectedCompletionSnips: [snip]), sortedBy: .manual
      )
      XCTAssertTrue(try XCTUnwrap(changed.update.snapshot.snips.first { $0.id == snip.id }).isDone)
      let undo = try XCTUnwrap(changed.undo)
      let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
      XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first { $0.id == snip.id }).isDone)
    }
  }

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

  func testDoneAndNotDoneAllowReorderingBetweenTheReadAndGuardedWrite() async throws {
    for done in [true, false] {
      let (root, base, snips) = try await makeLibrary(contents: ["First", "Second"])
      defer { try? FileManager.default.removeItem(at: root) }
      _ = try await base.perform(.setDone(ids: [snips[0].id], done: !done), sortedBy: .manual)
      let before = try await base.checkedSnapshot(sortedBy: .manual)
      let expected = try XCTUnwrap(before.snips.first { $0.id == snips[0].id })
      let library = ControlledDoneUndoLibrary(base: base)
      let session = SavedSnipsSession(library: library)
      await library.performBeforeNextCommand(
        .place(ids: [expected.id], in: expected.listID, before: snips[1].id, basedOn: .manual)
      )

      let result = try await session.setDone(
        ids: [expected.id], done: done,
        expectation: .init(expectedCompletionSnips: [expected]), sortedBy: .manual
      )

      let changed = try XCTUnwrap(result.update.snapshot.snips.first { $0.id == expected.id })
      let other = try XCTUnwrap(result.update.snapshot.snips.first { $0.id == snips[1].id })
      XCTAssertEqual(changed.isDone, done)
      XCTAssertLessThan(changed.manualSortKey, other.manualSortKey)
      if done {
        let undo = try XCTUnwrap(result.undo)
        let restored = try await session.restoreDone(token: undo.id, sortedBy: .manual)
        XCTAssertFalse(try XCTUnwrap(restored?.snapshot.snips.first { $0.id == expected.id }).isDone)
      } else {
        XCTAssertNil(result.undo)
      }
    }
  }

  func testCompletionGuardRejectsEditsPinsDeletionAndReplacementAtTheWrite() async throws {
    for mutation in ["text", "attachments", "pin", "done", "delete", "replacement"] {
      let (root, base, snips) = try await makeLibrary(contents: ["Original"])
      defer { try? FileManager.default.removeItem(at: root) }
      let original = snips[0]
      let command: SnipLibraryCommand
      switch mutation {
      case "text":
        command = .update(id: original.id, content: "Edited", attachmentURLs: nil,
                          expectedUpdatedAt: nil, now: Date())
      case "attachments":
        let file = root.appendingPathComponent("new.txt")
        try Data("New attachment".utf8).write(to: file)
        command = .update(id: original.id, content: original.content, attachmentURLs: [file],
                          expectedUpdatedAt: nil, now: Date())
      case "pin": command = .setPinned(ids: [original.id], pinned: true)
      case "done": command = .setDone(ids: [original.id], done: true)
      case "delete": command = .delete(ids: [original.id])
      default:
        command = .replaceAll([Snip(id: original.id, content: original.content, origin: original.origin)])
      }
      let library = ControlledDoneUndoLibrary(base: base)
      let session = SavedSnipsSession(library: library)
      await library.performBeforeNextCommand(command)

      do {
        _ = try await session.setDone(
          ids: [original.id], done: true,
          expectation: .init(expectedCompletionSnips: [original]), sortedBy: .manual
        )
        XCTFail("A concurrent \(mutation) must reject completion.")
      } catch {
        XCTAssertEqual(error as? SnipLibraryError, .snipChanged, mutation)
      }
      let current = try await base.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(current.snips.first?.isDone, mutation == "delete" ? nil : mutation == "done")
      if mutation == "text" { XCTAssertEqual(current.snips.first?.content, "Edited") }
      if mutation == "attachments" { XCTAssertEqual(current.snips.first?.attachments.count, 1) }
      if mutation == "pin" { XCTAssertEqual(current.snips.first?.isPinned, true) }
    }
  }

  func testCompletionGuardRejectsChangedAttachmentOrderIdentityAndMetadata() async throws {
    let (root, base, snips) = try await makeLibrary(contents: ["Original"])
    defer { try? FileManager.default.removeItem(at: root) }
    let files = ["first.txt", "second.txt"].map { root.appendingPathComponent($0) }
    for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
    let update = try await base.perform(
      .update(id: snips[0].id, content: "Original", attachmentURLs: files,
              expectedUpdatedAt: nil, now: Date()), sortedBy: .manual
    )
    let original = try XCTUnwrap(update.snapshot.snips.first)
    let library = ControlledDoneUndoLibrary(base: base)
    let session = SavedSnipsSession(library: library)
    for mutation in ["order", "identity", "name", "path", "type", "bytes"] {
      _ = try await base.perform(.replaceAll([original]), sortedBy: .manual)
      var changed = original
      switch mutation {
      case "order": changed.attachments.reverse()
      case "identity":
        let attachment = changed.attachments[0]
        changed.attachments[0] = SnipAttachment(
          id: UUID(), fileName: attachment.fileName, relativePath: attachment.relativePath,
          contentType: attachment.contentType, byteCount: attachment.byteCount
        )
      case "name": changed.attachments[0].fileName = "renamed.txt"
      case "path": changed.attachments[0].relativePath = "other/first.txt"
      case "type": changed.attachments[0].contentType = "application/octet-stream"
      default: changed.attachments[0].byteCount += 1
      }
      await library.performBeforeNextCommand(.replaceAll([changed]))

      do {
        _ = try await session.setDone(
          ids: [original.id], done: true,
          expectation: .init(expectedCompletionSnips: [original]), sortedBy: .manual
        )
        XCTFail("Changed attachment \(mutation) must reject completion.")
      } catch {
        XCTAssertEqual(error as? SnipLibraryError, .snipChanged, mutation)
      }
      let current = try await base.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(current.snips, [changed])
    }
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

  func testImportPreviewSuspendedAcrossLibraryReplacementIsNotKept() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let backupURL = try await makeBackup(at: root.appendingPathComponent("Backup.json"), content: "From backup")
    let original = try JSONSnipLibrary(fileURL: root.appendingPathComponent("original.json"))
    let replacement = try JSONSnipLibrary(fileURL: root.appendingPathComponent("replacement.json"))
    let gate = ImportPreviewGate()
    let session = makeImportSession(library: original, gate: gate)
    let latePreview = Task { try await session.previewImport(from: backupURL) }
    await gate.waitUntilPaused()

    _ = await session.replaceLibrary(replacement, recoveryScope: nil, sortedBy: .manual)
    await gate.resume()

    let retained: SavedSnipsImportPreview?
    do {
      retained = try await latePreview.value
      XCTFail("A preview made for the replaced library must not be kept.")
    } catch {
      retained = nil
      XCTAssertTrue(error is CancellationError)
    }
    if let retained {
      let applied = try await session.applyPendingImport(id: retained.id, sortedBy: .manual)
      XCTAssertNil(applied)
    }
    let snapshot = try await replacement.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(snapshot.snips.isEmpty)
  }

  func testOlderImportPreviewFinishingLateLeavesTheNewerPreviewPending() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let olderURL = try await makeBackup(at: root.appendingPathComponent("Older.json"), content: "Older backup")
    let newerURL = try await makeBackup(at: root.appendingPathComponent("Newer.json"), content: "Newer backup")
    let target = try JSONSnipLibrary(fileURL: root.appendingPathComponent("target.json"))
    let gate = ImportPreviewGate()
    let session = makeImportSession(library: target, gate: gate)
    let olderPreview = Task { try await session.previewImport(from: olderURL) }
    await gate.waitUntilPaused()

    let newer = try await session.previewImport(from: newerURL)
    await gate.resume()

    do {
      _ = try await olderPreview.value
      XCTFail("An older preview must not replace a newer one.")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    let applied = try await session.applyPendingImport(id: newer.id, sortedBy: .manual)
    XCTAssertEqual(applied?.0.snapshot.snips.map(\.content), ["Newer backup"])
  }

  func testCancellingAnImportPreviewOnlyClearsTheMatchingPendingPreview() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let backupURL = try await makeBackup(at: root.appendingPathComponent("Backup.json"), content: "From backup")
    let target = try JSONSnipLibrary(fileURL: root.appendingPathComponent("target.json"))
    let session = makeImportSession(library: target)
    let preview = try await session.previewImport(from: backupURL)

    let cancelledStale = await session.cancelImport(id: UUID())
    XCTAssertFalse(cancelledStale)
    let keptAfterStaleCancel = await session.hasPendingImport(id: preview.id)
    XCTAssertTrue(keptAfterStaleCancel)
    let cancelled = await session.cancelImport(id: preview.id)
    XCTAssertTrue(cancelled)
    let keptAfterCancel = await session.hasPendingImport(id: preview.id)
    XCTAssertFalse(keptAfterCancel)
    let applied = try await session.applyPendingImport(id: preview.id, sortedBy: .manual)
    XCTAssertNil(applied)
    let snapshot = try await target.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(snapshot.snips.isEmpty)
  }

  func testCheckingForAPendingImportDoesNotConsumeIt() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let backupURL = try await makeBackup(at: root.appendingPathComponent("Backup.json"), content: "From backup")
    let target = try JSONSnipLibrary(fileURL: root.appendingPathComponent("target.json"))
    let session = makeImportSession(library: target)
    let preview = try await session.previewImport(from: backupURL)

    let hasUnknown = await session.hasPendingImport(id: UUID())
    XCTAssertFalse(hasUnknown)
    let hasPreview = await session.hasPendingImport(id: preview.id)
    XCTAssertTrue(hasPreview)
    let applied = try await session.applyPendingImport(id: preview.id, sortedBy: .manual)
    XCTAssertEqual(applied?.0.snapshot.snips.map(\.content), ["From backup"])
    let hasAppliedPreview = await session.hasPendingImport(id: preview.id)
    XCTAssertFalse(hasAppliedPreview)
  }

  @MainActor
  func testExclusiveAccessRunsOverlappingOperationsOneAtATimeInCallOrder() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SavedSnipsSession(library: try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json")))
    let probe = ExclusiveAccessProbe()
    let first = Task { @MainActor in
      await session.withExclusiveAccess { _ in
        probe.record("start 1")
        await probe.holdFirst()
        probe.record("end 1")
      }
    }
    while !probe.isHoldingFirst { await Task.yield() }
    let later = [2, 3].map { number in
      Task { @MainActor in
        probe.markQueued(number)
        await session.withExclusiveAccess { _ in
          probe.record("start \(number)")
          await Task.yield()
          probe.record("end \(number)")
        }
      }
    }
    while probe.queued.count < 2 { await Task.yield() }

    probe.releaseFirst()
    await first.value
    for task in later { await task.value }

    let callOrder = probe.queued.flatMap { ["start \($0)", "end \($0)"] }
    XCTAssertEqual(probe.events, ["start 1", "end 1"] + callOrder)
  }

  private func makeBackup(at url: URL, content: String) async throws -> URL {
    let backup = try JSONSnipLibrary(fileURL: url)
    _ = try await backup.add(content: content, origin: .quickEntry)
    return url
  }

  private func makeImportSession(library: any SnipLibrary, gate: ImportPreviewGate? = nil) -> SavedSnipsSession {
    SavedSnipsSession(library: library, userActionsFactory: { current in
      DirectSnipLibraryUserActions(library: current, previewBackupImport: { url, target in
        let preview = try await SnipLibraryImport.preview(backupURL: url, target: target)
        await gate?.pauseFirstPreview()
        return preview
      })
    })
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

private actor ImportPreviewGate {
  private var pausesNextPreview = true
  private var isPaused = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var pausedPreview: CheckedContinuation<Void, Never>?

  func pauseFirstPreview() async {
    guard pausesNextPreview else { return }
    pausesNextPreview = false
    isPaused = true
    pauseWaiters.forEach { $0.resume() }
    pauseWaiters.removeAll()
    await withCheckedContinuation { pausedPreview = $0 }
  }

  func waitUntilPaused() async {
    if isPaused { return }
    await withCheckedContinuation { pauseWaiters.append($0) }
  }

  func resume() {
    pausedPreview?.resume()
    pausedPreview = nil
  }
}

@MainActor
private final class ExclusiveAccessProbe {
  private(set) var events: [String] = []
  private(set) var queued: [Int] = []
  private var heldFirst: CheckedContinuation<Void, Never>?

  var isHoldingFirst: Bool { heldFirst != nil }

  func record(_ event: String) { events.append(event) }

  func markQueued(_ number: Int) { queued.append(number) }

  func holdFirst() async {
    await withCheckedContinuation { heldFirst = $0 }
  }

  func releaseFirst() {
    heldFirst?.resume()
    heldFirst = nil
  }
}

extension SavedSnipsSessionTests {
  func testCheckedReplacementBindsOnceAndReturnsActualContentAndRecovery() async throws {
    let root = checkedReplacementRoot()
    let old = try JSONSnipLibrary(fileURL: root.appendingPathComponent("old.json"))
    let oldAdded = try await old.add(content: "Old Done", origin: .quickEntry)
    let oldSnip = try XCTUnwrap(oldAdded)
    let replacement = try JSONSnipLibrary(fileURL: root.appendingPathComponent("replacement.json"))
    _ = try await replacement.add(content: "Replacement durable", origin: .quickEntry)
    let observed = CheckedReplacementLibrary(base: replacement)
    let bindings = CheckedReplacementBindings()
    let session = SavedSnipsSession(library: old, userActionsFactory: { library in
      bindings.record()
      return DirectSnipLibraryUserActions(library: library)
    })
    let changed = try await session.setDone(ids: [oldSnip.id], done: true, sortedBy: .manual)
    let token = try XCTUnwrap(changed.undo).id

    let result = try await session.replaceLibraryChecked(
      observed, recoveryScope: SnipRecoveryScope("replacement"), sortedBy: .manual
    )

    XCTAssertEqual(result.read.snapshot.snips.map(\.content), ["Replacement durable"])
    XCTAssertNil(result.read.source)
    XCTAssertEqual(result.recovery, .empty)
    XCTAssertEqual(bindings.count, 2, "One initial bind and one replacement bind")
    let calls = await observed.calls()
    XCTAssertEqual(calls.checked, 1)
    XCTAssertEqual(calls.unchecked, 0)
    XCTAssertEqual(calls.recoveryScopes, ["replacement"])
    let retained = await session.retainsUndo(token: token)
    XCTAssertFalse(retained)
    _ = try await session.performUserCommand(
      .add(content: "Written after bind", origin: .quickEntry, source: nil,
           listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: Date()),
      sortedBy: .manual
    )
    let reopened = try JSONSnipLibrary(fileURL: root.appendingPathComponent("replacement.json"))
    let durable = try await reopened.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(Set(durable.snips.map(\.content)), ["Replacement durable", "Written after bind"])
    let oldDurable = try await old.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(oldDurable.snips.map(\.content), ["Old Done"])
    XCTAssertTrue(try XCTUnwrap(oldDurable.snips.first).isDone)
  }

  func testCheckedReplacementPropagatesReadErrorWithoutFallbackOrRecovery() async throws {
    let root = checkedReplacementRoot()
    let raw = try JSONSnipLibrary(fileURL: root.appendingPathComponent("replacement.json"))
    _ = try await raw.add(content: "Durable despite read error", origin: .quickEntry)
    let failure = CheckedReplacementFailure()
    let library = CheckedReplacementLibrary(base: raw, readFailure: failure)
    let session = SavedSnipsSession(library: try JSONSnipLibrary(fileURL: root.appendingPathComponent("old.json")))
    do {
      _ = try await session.replaceLibraryChecked(
        library, recoveryScope: SnipRecoveryScope("checked"), sortedBy: .manual
      )
      XCTFail("A replacement read error must not become fallback success.")
    } catch { XCTAssertTrue((error as? CheckedReplacementFailure) === failure) }
    let calls = await library.calls()
    XCTAssertEqual(calls.checked, 1)
    XCTAssertEqual(calls.unchecked, 0)
    XCTAssertTrue(calls.recoveryScopes.isEmpty)
    let durable = try await raw.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(durable.snips.map(\.content), ["Durable despite read error"])
    _ = try await session.performUserCommand(.add(content: "Old owner after failed read", origin: .quickEntry,
      source: nil, listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: .distantPast), sortedBy: .manual)
    let old = try JSONSnipLibrary(fileURL: root.appendingPathComponent("old.json"))
    let oldDurable = try await old.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(oldDurable.snips.map(\.content), ["Old owner after failed read"])
    let stillReplacement = try await raw.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(stillReplacement.snips.map(\.content), ["Durable despite read error"])

  }

  func testCheckedReplacementPropagatesRecoveryErrorWithoutReturningEmptySuccess() async throws {
    let root = checkedReplacementRoot()
    let raw = try JSONSnipLibrary(fileURL: root.appendingPathComponent("replacement.json"))
    _ = try await raw.add(content: "Checked before recovery error", origin: .quickEntry)
    let failure = CheckedReplacementFailure()
    let library = CheckedReplacementLibrary(base: raw, recoveryFailure: failure)
    let session = SavedSnipsSession(library: try JSONSnipLibrary(fileURL: root.appendingPathComponent("old.json")))
    do {
      _ = try await session.replaceLibraryChecked(
        library, recoveryScope: SnipRecoveryScope("required recovery"), sortedBy: .manual
      )
      XCTFail("Required recovery failure must not become an empty successful replacement.")
    } catch { XCTAssertTrue((error as? CheckedReplacementFailure) === failure) }
    let calls = await library.calls()
    XCTAssertEqual(calls.checked, 1)
    XCTAssertEqual(calls.unchecked, 0)
    XCTAssertEqual(calls.recoveryScopes, ["required recovery"])
    let durable = try await raw.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(durable.snips.map(\.content), ["Checked before recovery error"])
    _ = try await session.performUserCommand(.add(content: "Old owner after failed recovery", origin: .quickEntry,
      source: nil, listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: .distantPast), sortedBy: .manual)
    let old = try JSONSnipLibrary(fileURL: root.appendingPathComponent("old.json"))
    let oldDurable = try await old.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(oldDurable.snips.map(\.content), ["Old owner after failed recovery"])
    let stillReplacement = try await raw.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(stillReplacement.snips.map(\.content), ["Checked before recovery error"])

  }
}

private func checkedReplacementRoot() -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("CheckedReplacement-\(UUID())")
  print("OFFLINE-CHECKED-APPLICATION retained unique root: \(root.path)")
  return root
}

private final class CheckedReplacementFailure: Error, @unchecked Sendable {}

private final class CheckedReplacementBindings: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func record() { lock.withLock { value += 1 } }
}

private actor CheckedReplacementLibrary: SnipLibrary {
  let base: JSONSnipLibrary
  let readFailure: CheckedReplacementFailure?
  let recoveryFailure: CheckedReplacementFailure?
  private var checked = 0
  private var unchecked = 0
  private var scopes: [String] = []

  init(base: JSONSnipLibrary, readFailure: CheckedReplacementFailure? = nil,
       recoveryFailure: CheckedReplacementFailure? = nil) {
    self.base = base
    self.readFailure = readFailure
    self.recoveryFailure = recoveryFailure
  }

  func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot {
    checked += 1
    let value = try await base.checkedSnapshot(sortedBy: sortMode)
    if let readFailure { throw readFailure }
    return value
  }

  func snapshot(sortedBy sortMode: SnipSortMode) async -> SnipLibrarySnapshot {
    unchecked += 1
    return await base.snapshot(sortedBy: sortMode)
  }

  func recoverySnapshot(in scope: SnipRecoveryScope) async throws -> SnipRecoverySnapshot {
    scopes.append(scope.rawValue)
    let value = try await base.recoverySnapshot(in: scope)
    if let recoveryFailure { throw recoveryFailure }
    return value
  }

  func perform(_ command: SnipLibraryCommand, sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate {
    try await base.perform(command, sortedBy: sortMode)
  }

  func calls() -> (checked: Int, unchecked: Int, recoveryScopes: [String]) { (checked, unchecked, scopes) }
}


extension SavedSnipsSessionTests {
  @MainActor
  func testCancelledCheckedReplacementKeepsUndoAndSubsequentCommandsOnTheDisplayedOwner() async throws {
    let root = checkedReplacementRoot()
    let oldURL = root.appendingPathComponent("old.json")
    let replacementURL = root.appendingPathComponent("replacement.json")
    let old = try JSONSnipLibrary(fileURL: oldURL)
    let oldAdded = try await old.add(content: "Original Done", origin: .quickEntry)
    let oldSnip = try XCTUnwrap(oldAdded)
    let replacement = try JSONSnipLibrary(fileURL: replacementURL)
    _ = try await replacement.add(content: "Replacement untouched", origin: .quickEntry)
    let observed = CheckedReplacementLibrary(base: replacement)
    let session = SavedSnipsSession(library: old)
    let done = try await session.setDone(ids: [oldSnip.id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(done.undo)
    let finished = XCTestExpectation(description: "cancelled real checked replacement returned")
    let joined = XCTestExpectation(description: "cancelled checked replacement cleanup joined")
    var failure: (any Error)?
    let operation = Task { @MainActor in
      defer { finished.fulfill(); joined.fulfill() }
      do {
        _ = try await session.replaceLibraryChecked(observed, recoveryScope: SnipRecoveryScope("replacement"), sortedBy: .manual)
        XCTFail("Cancellation cannot bind the replacement or discard original undo")
      } catch { failure = error }
    }
    operation.cancel()
    let settled = await XCTWaiter.fulfillment(of: [finished], timeout: 30) == .completed
    XCTAssertTrue(settled, "Cancellation must return through the actual checked replacement owner")
    if settled {
      await operation.value
      XCTAssertTrue(failure is CancellationError)
      let retained = await session.retainsUndo(token: undo.id)
      XCTAssertTrue(retained)
      _ = try await session.performUserCommand(.add(content: "Command after cancelled preparation", origin: .quickEntry,
        source: nil, listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: .distantPast), sortedBy: .manual)
      let reopenedOld = try JSONSnipLibrary(fileURL: oldURL)
      let oldDurable = try await reopenedOld.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(Set(oldDurable.snips.map(\.content)), ["Original Done", "Command after cancelled preparation"])
      XCTAssertTrue(try XCTUnwrap(oldDurable.snips.first { $0.id == oldSnip.id }).isDone)
      let reopenedReplacement = try JSONSnipLibrary(fileURL: replacementURL)
      let newDurable = try await reopenedReplacement.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(newDurable.snips.map(\.content), ["Replacement untouched"])
    } else {
      operation.cancel()
      let cleanup = await XCTWaiter.fulfillment(of: [joined], timeout: 30) == .completed
      XCTAssertTrue(cleanup, "Failed cleanup retains the task-owned libraries and the logged root")
      if cleanup { await operation.value }
    }
  }
}


extension SavedSnipsSessionTests {
  func testRetiredPreparedReplacementCannotRedirectTheOriginalSessionsNextCommand() async throws {
    let root = checkedReplacementRoot()
    let oldURL = root.appendingPathComponent("original.json")
    let old = try JSONSnipLibrary(fileURL: oldURL)
    let created = try await old.add(content: "Displayed original", origin: .quickEntry)
    let snip = try XCTUnwrap(created)
    let session = SavedSnipsSession(library: old)
    let done = try await session.setDone(ids: [snip.id], done: true, sortedBy: .manual)
    let undo = try XCTUnwrap(done.undo)
    let modeRoot = root.appendingPathComponent("mode")
    let persistence = try SwiftDataSyncModePersistence(rootURL: modeRoot)
    let managed = try await persistence.activeLibrary()
    _ = try await managed.perform(.add(content: "Prepared target B", origin: .quickEntry, source: nil,
      listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: .distantPast), sortedBy: .manual)
    let storeB = try await persistence.snapshot().activeStore.id
    let prepared = try await session.prepareLibraryApplication(managed, recoveryScope: nil, replacing: true, sortedBy: .manual)
    XCTAssertEqual(prepared.read.snapshot.snips.map(\.content), ["Prepared target B"])
    try await persistence.activateEmptyCollection(namespace: ICloudSyncNamespaceBinding(scope: "private",
      accountLineage: "retired-preparation", generation: UUID(uuidString: "AAAAAAAA-3333-4444-5555-AAAAAAAAAAAA")!,
      zones: [.init(name: "target-c", ownerName: "owner")]))
    _ = try await managed.perform(.add(content: "Actual target C", origin: .quickEntry, source: nil,
      listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: .distantPast), sortedBy: .manual)

    do {
      let closing = try XCTUnwrap(prepared.read.publication).beginApplication()
      defer { closing.finish() }
      try prepared.install(within: closing)
      XCTFail("A retired prepared target cannot install its command owner")
    } catch { XCTAssertTrue(error is SnipLibraryReadPublicationError) }
    do {
      try prepared.install()
      XCTFail("A bound command owner cannot bypass its actual closing operation")
    } catch { XCTAssertTrue(error is SnipLibraryReadPublicationError) }
    let retained = await session.retainsUndo(token: undo.id)
    XCTAssertTrue(retained)
    _ = try await session.performUserCommand(.add(content: "Command remains on displayed original", origin: .quickEntry,
      source: nil, listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: .distantPast), sortedBy: .manual)
    let reopened = try JSONSnipLibrary(fileURL: oldURL)
    let originalDurable = try await reopened.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(Set(originalDurable.snips.map(\.content)), ["Displayed original", "Command remains on displayed original"])
    let retiredB = try await persistence.libraryForTransition(storeID: storeB)
    let bDurable = try await retiredB.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(bDurable.snips.map(\.content), ["Prepared target B"])
    let reopenedMode = try SwiftDataSyncModePersistence(rootURL: modeRoot)
    let currentDurable = try await (try await reopenedMode.activeLibrary()).checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(currentDurable.snips.map(\.content), ["Actual target C"])
  }
}
