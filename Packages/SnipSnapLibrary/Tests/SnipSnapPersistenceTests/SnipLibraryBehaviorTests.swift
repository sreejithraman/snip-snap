import Foundation
import SnipSnapCore
import SwiftData
import XCTest

@testable import SnipSnapPersistence

final class SnipLibraryBehaviorTests: XCTestCase {
  private enum Adapter: String, CaseIterable {
    case json
    case swiftData

    func open(in directory: URL) throws -> any SnipLibrary {
      switch self {
      case .json:
        try JSONSnipLibrary(fileURL: directory.appendingPathComponent("snips.json"))
      case .swiftData:
        try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
      }
    }

    func unavailable(in directory: URL) -> any SnipLibrary {
      switch self {
      case .json:
        JSONSnipLibrary.unavailable(
          fileURL: directory.appendingPathComponent("unavailable.json")
        )
      case .swiftData:
        SwiftDataSnipLibrary.unavailable(
          storeURL: directory.appendingPathComponent("unavailable.store")
        )
      }
    }
  }

  func testDurableAdaptersMatchListAddOrderingAndDuplicateRules() async throws {
    try await forEachAdapter { adapter, directory, library in
      let work = try await createList(named: " Work ", in: library)
      await assertThrows(.duplicateList) {
        _ = try await library.perform(
          .createList(name: "work", systemImage: "briefcase"),
          sortedBy: .chronological
        )
      }

      let firstRequest = UUID()
      let first = try await add(
        "First",
        requestID: firstRequest,
        at: 100,
        to: work.id,
        in: library
      )
      let second = try await add(
        "Second",
        requestID: UUID(),
        at: 200,
        to: work.id,
        in: library
      )
      let duplicate = try await library.perform(
        .add(
          content: "Ignored retry",
          origin: .quickEntry,
          source: nil,
          listID: work.id,
          attachmentURLs: [],
          requestID: firstRequest,
          now: Date(timeIntervalSince1970: 300)
        ),
        sortedBy: .chronological
      )
      XCTAssertEqual(duplicate.outcome, .add(.duplicate), adapter.rawValue)
      XCTAssertEqual(duplicate.snapshot.snips.map(\.id), [second.id, first.id], adapter.rawValue)

      let reopened = try adapter.open(in: directory)
      let reopenedSnapshot = await reopened.snapshot(sortedBy: .chronological)
      XCTAssertEqual(reopenedSnapshot.lists.map(\.name), ["Inbox", "Work"], adapter.rawValue)
      XCTAssertEqual(reopenedSnapshot.snips.map(\.content), ["Second", "First"], adapter.rawValue)

      let reopenedRetry = try await reopened.perform(
        .add(
          content: "Still ignored",
          origin: .quickEntry,
          source: nil,
          listID: work.id,
          attachmentURLs: [],
          requestID: firstRequest,
          now: Date(timeIntervalSince1970: 400)
        ),
        sortedBy: .chronological
      )
      XCTAssertEqual(reopenedRetry.outcome, .add(.duplicate), adapter.rawValue)
      XCTAssertEqual(reopenedRetry.snapshot.snips.count, 2, adapter.rawValue)
    }
  }

  func testDurableAdaptersMatchEditMergeListDeletionAndManualOrdering() async throws {
    try await forEachAdapter { adapter, directory, library in
      let work = try await createList(named: "Work", in: library)
      let first = try await add("First", requestID: UUID(), at: 100, to: work.id, in: library)
      let second = try await add("Second", requestID: UUID(), at: 200, to: work.id, in: library)
      let staleDate = first.updatedAt.addingTimeInterval(-1)
      await assertThrows(.snipChanged) {
        _ = try await library.perform(
          .update(
            id: first.id,
            content: "Stale",
            attachmentURLs: nil,
            expectedUpdatedAt: staleDate,
            now: Date(timeIntervalSince1970: 300)
          ),
          sortedBy: .manual
        )
      }

      _ = try await library.perform(
        .place(ids: [first.id], in: work.id, before: second.id, basedOn: .manual),
        sortedBy: .manual
      )
      let merged = try await library.perform(
        .merge(ids: [first.id, second.id], now: Date(timeIntervalSince1970: 400)),
        sortedBy: .manual
      )
      guard case .merged(let mergedSnip) = merged.outcome else {
        return XCTFail("Expected merged snip for \(adapter.rawValue)")
      }
      XCTAssertTrue(mergedSnip.content.contains("First"), adapter.rawValue)
      XCTAssertTrue(mergedSnip.content.contains("Second"), adapter.rawValue)

      _ = try await library.perform(.deleteList(id: work.id), sortedBy: .manual)
      let reopened = try adapter.open(in: directory)
      let snapshot = await reopened.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.lists, [.inbox], adapter.rawValue)
      XCTAssertEqual(snapshot.snips.map(\.listID), [SnipList.inboxID], adapter.rawValue)
      XCTAssertEqual(snapshot.snips.map(\.id), [mergedSnip.id], adapter.rawValue)
    }
  }

  func testDurableAdaptersKeepDoneStateManualOrderAndListMovesAfterReopen() async throws {
    try await forEachAdapter { adapter, directory, library in
      let work = try await createList(named: "Work", in: library)
      let first = try await add("First", requestID: UUID(), at: 100, to: SnipList.inboxID, in: library)
      let second = try await add("Second", requestID: UUID(), at: 200, to: SnipList.inboxID, in: library)
      let third = try await add("Third", requestID: UUID(), at: 300, to: SnipList.inboxID, in: library)

      _ = try await library.perform(
        .setDone(ids: [second.id], done: true),
        sortedBy: .manual
      )
      _ = try await library.perform(
        .place(ids: [third.id, first.id], in: work.id, before: nil, basedOn: .manual),
        sortedBy: .manual
      )

      let reopened = try adapter.open(in: directory)
      let snapshot = await reopened.snapshot(sortedBy: .manual)
      XCTAssertEqual(
        snapshot.snips.filter { $0.listID == work.id }.map(\.id),
        [third.id, first.id],
        adapter.rawValue
      )
      XCTAssertEqual(snapshot.snips.first(where: { $0.id == second.id })?.isDone, true)
      XCTAssertEqual(snapshot.snips.first(where: { $0.id == second.id })?.listID, SnipList.inboxID)
    }
  }

  func testGuardedInverseRejectsChangedRecordsAndKeepsUnrelatedWrites() async throws {
    try await forEachAdapter { adapter, _, library in
      let first = try await add("First", requestID: UUID(), at: 100, to: SnipList.inboxID, in: library)
      let unrelated = try await add("Unrelated", requestID: UUID(), at: 200, to: SnipList.inboxID, in: library)
      let doneUpdate = try await library.perform(
        .setDone(ids: [first.id], done: true),
        sortedBy: .manual
      )
      let expectedDone = try XCTUnwrap(doneUpdate.snapshot.snips.first(where: { $0.id == first.id }))

      _ = try await library.perform(
        .update(
          id: first.id,
          content: "Changed later",
          attachmentURLs: nil,
          expectedUpdatedAt: expectedDone.updatedAt,
          now: Date(timeIntervalSince1970: 300)
        ),
        sortedBy: .manual
      )

      await assertThrows(.snipChanged) {
        _ = try await library.perform(
          .guarded(
            expectation: SnipLibraryExpectation(expectedSnips: [expectedDone]),
            command: .setDone(ids: [first.id], done: first.isDone)
          ),
          sortedBy: .manual
        )
      }

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.snips.first(where: { $0.id == first.id })?.content, "Changed later")
      XCTAssertEqual(snapshot.snips.first(where: { $0.id == unrelated.id })?.content, "Unrelated")
      XCTAssertEqual(snapshot.snips.count, 2, adapter.rawValue)
    }
  }

  func testGuardedListDeletionRejectsNewListMembers() async throws {
    try await forEachAdapter { adapter, _, library in
      let work = try await createList(named: "Work", in: library)
      let added = try await add(
        "Added elsewhere",
        requestID: UUID(),
        at: 100,
        to: work.id,
        in: library
      )

      await assertThrows(.snipChanged) {
        _ = try await library.perform(
          .guarded(
            expectation: SnipLibraryExpectation(
              expectedListMemberships: [work.id: []]
            ),
            command: .deleteList(id: work.id)
          ),
          sortedBy: .manual
        )
      }

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertTrue(snapshot.lists.contains(where: { $0.id == work.id }), adapter.rawValue)
      XCTAssertEqual(snapshot.snips.first(where: { $0.id == added.id })?.listID, work.id)
    }
  }

  func testGuardedRestoreRejectsADeletedDestinationList() async throws {
    try await forEachAdapter { adapter, _, library in
      let work = try await createList(named: "Work", in: library)
      let removed = try await add("Removed", requestID: UUID(), at: 100, to: work.id, in: library)
      _ = try await library.perform(.delete(ids: [removed.id]), sortedBy: .manual)
      _ = try await library.perform(.deleteList(id: work.id), sortedBy: .manual)

      await assertThrows(.snipChanged) {
        _ = try await library.perform(
          .guarded(
            expectation: SnipLibraryExpectation(requiredListIDs: [work.id]),
            command: .restore(snips: [removed])
          ),
          sortedBy: .manual
        )
      }

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertFalse(snapshot.snips.contains(where: { $0.id == removed.id }), adapter.rawValue)
    }
  }

  func testRestoreRejectsSnipsWhoseListDoesNotExist() async throws {
    try await forEachAdapter { adapter, _, library in
      let orphan = Snip(
        content: "Orphan",
        origin: .quickEntry,
        listID: UUID()
      )

      await assertThrows(.invalidList) {
        _ = try await library.perform(.restore(snips: [orphan]), sortedBy: .manual)
      }

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertTrue(snapshot.snips.isEmpty, adapter.rawValue)
    }
  }

  func testRestoreRetriesIgnoreListIDsOnRecordsThatAlreadyExist() async throws {
    try await forEachAdapter { adapter, _, library in
      let existing = try await add(
        "Existing",
        requestID: UUID(),
        at: 100,
        to: SnipList.inboxID,
        in: library
      )
      let ignoredRetry = Snip(
        id: existing.id,
        requestID: existing.requestID,
        createdAt: existing.createdAt,
        content: "Ignored retry",
        origin: existing.origin,
        listID: UUID()
      )

      _ = try await library.perform(.restore(snips: [ignoredRetry]), sortedBy: .manual)

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.snips, [existing], adapter.rawValue)
    }
  }

  func testRestoreReplacingIgnoresListIDsOnFilteredExistingRecords() async throws {
    try await forEachAdapter { adapter, _, library in
      let replaced = try await add(
        "Replace me",
        requestID: UUID(),
        at: 100,
        to: SnipList.inboxID,
        in: library
      )
      let existing = try await add(
        "Keep me",
        requestID: UUID(),
        at: 200,
        to: SnipList.inboxID,
        in: library
      )
      let ignored = Snip(
        id: existing.id,
        requestID: UUID(),
        createdAt: existing.createdAt,
        content: "Filtered",
        origin: .quickEntry,
        listID: UUID()
      )
      let replacement = Snip(
        content: "Replacement",
        origin: .quickEntry,
        listID: SnipList.inboxID
      )

      _ = try await library.perform(
        .restoreReplacing(
          snips: [ignored, replacement],
          id: replaced.id,
          expectedUpdatedAt: replaced.updatedAt
        ),
        sortedBy: .manual
      )

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertTrue(snapshot.snips.contains(where: { $0 == existing }), adapter.rawValue)
      XCTAssertTrue(snapshot.snips.contains(where: { $0 == replacement }), adapter.rawValue)
      XCTAssertFalse(snapshot.snips.contains(where: { $0.id == replaced.id }), adapter.rawValue)
    }
  }

  func testBatchRejectsAttachmentPruningBeforeAnySideEffect() async throws {
    try await forEachAdapter { adapter, directory, library in
      let sourceURL = directory.appendingPathComponent("keep-me.txt")
      try Data("Keep".utf8).write(to: sourceURL)
      let added = try await library.perform(
        .add(
          content: "Has file",
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
      let attachment = try XCTUnwrap(snip.attachments.first)
      let storedURL = try XCTUnwrap(added.snapshot.attachmentURLs[attachment.id])

      await assertThrows(.invalidCommand) {
        _ = try await library.perform(
          .batch([
            .delete(ids: [snip.id]),
            .pruneAttachments(retaining: []),
          ]),
          sortedBy: .manual
        )
      }

      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertTrue(snapshot.snips.contains(where: { $0.id == snip.id }), adapter.rawValue)
      XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path), adapter.rawValue)
    }
  }

  func testDurableAdaptersMatchAttachmentRecordsAndReopen() async throws {
    try await forEachAdapter { adapter, directory, library in
      let sourceURL = directory.appendingPathComponent("note.txt")
      try Data("Attachment body".utf8).write(to: sourceURL)
      let added = try await library.perform(
        .add(
          content: "With file",
          origin: .quickEntry,
          source: SnipSource(applicationName: "Tests", windowTitle: "Contract"),
          listID: SnipList.inboxID,
          attachmentURLs: [sourceURL],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
      let attachment = try XCTUnwrap(added.snapshot.snips.first?.attachments.first)
      XCTAssertEqual(attachment.fileName, "note.txt", adapter.rawValue)
      XCTAssertEqual(attachment.byteCount, 15, adapter.rawValue)
      let storedURL = try XCTUnwrap(added.snapshot.attachmentURLs[attachment.id])
      XCTAssertEqual(
        try Data(contentsOf: storedURL), Data("Attachment body".utf8), adapter.rawValue)

      _ = try await library.perform(
        .add(
          content: "Shares file",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [storedURL],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 200)
        ),
        sortedBy: .chronological
      )

      let reopened = try adapter.open(in: directory)
      let snapshot = await reopened.snapshot(sortedBy: .chronological)
      XCTAssertEqual(snapshot.snips.last?.source?.windowTitle, "Contract", adapter.rawValue)
      XCTAssertEqual(
        snapshot.snips.flatMap(\.attachments).map(\.id), [attachment.id, attachment.id],
        adapter.rawValue)
      let reopenedURL = try XCTUnwrap(snapshot.attachmentURLs[attachment.id])
      XCTAssertEqual(
        try Data(contentsOf: reopenedURL), Data("Attachment body".utf8), adapter.rawValue)
    }
  }

  func testDurableAdaptersRollBackFailedWrites() async throws {
    for adapter in Adapter.allCases {
      let directory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let library = adapter.unavailable(in: directory)
      await assertThrows(.storeUnavailable) {
        _ = try await library.perform(
          .add(
            content: "Must not appear",
            origin: .quickEntry,
            source: nil,
            listID: SnipList.inboxID,
            attachmentURLs: [],
            requestID: UUID(),
            now: Date(timeIntervalSince1970: 100)
          ),
          sortedBy: .chronological
        )
      }
      let snapshot = await library.snapshot(sortedBy: .chronological)
      XCTAssertTrue(snapshot.snips.isEmpty, adapter.rawValue)
    }
  }

  func testDurableAdaptersMatchRemainingCommandRules() async throws {
    try await forEachAdapter { adapter, directory, library in
      let work = try await createList(named: "Work", in: library)
      let later = try await createList(named: "Later", in: library)
      let first = try await add("First", requestID: UUID(), at: 100, to: work.id, in: library)
      let second = try await add("Second", requestID: UUID(), at: 200, to: work.id, in: library)

      _ = try await library.perform(
        .updateList(id: work.id, name: "Focus", systemImage: "scope"),
        sortedBy: .manual
      )
      let editedAt = Date(timeIntervalSince1970: 300)
      _ = try await library.perform(
        .update(
          id: first.id,
          content: "Edited",
          attachmentURLs: nil,
          expectedUpdatedAt: first.updatedAt,
          now: editedAt
        ),
        sortedBy: .manual
      )
      _ = try await library.perform(.toggleDone(id: first.id), sortedBy: .manual)
      _ = try await library.perform(
        .toggleDoneMany(ids: [first.id, second.id]),
        sortedBy: .manual
      )
      _ = try await library.perform(.setDone(ids: [second.id], done: false), sortedBy: .manual)
      _ = try await library.perform(
        .moveChronologically(ids: [first.id, second.id], to: later.id),
        sortedBy: .manual
      )
      let beforeReplacement = await library.snapshot(sortedBy: .manual)
      let replacementToken = try XCTUnwrap(
        beforeReplacement.snips.first(where: { $0.id == first.id })?.updatedAt
      )
      _ = try await library.perform(
        .delete(ids: [second.id]),
        sortedBy: .manual
      )
      _ = try await library.perform(.restore(snips: [second]), sortedBy: .manual)

      let replacement = Snip(
        id: UUID(),
        requestID: UUID(),
        createdAt: Date(timeIntervalSince1970: 400),
        content: "Replacement",
        origin: .quickEntry,
        listID: later.id
      )
      _ = try await library.perform(
        .restoreReplacing(snips: [replacement], id: first.id, expectedUpdatedAt: replacementToken),
        sortedBy: .manual
      )
      _ = try await library.perform(.replaceAll([replacement]), sortedBy: .manual)

      let reopened = try adapter.open(in: directory)
      let snapshot = await reopened.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.lists.map(\.name), ["Inbox", "Focus", "Later"], adapter.rawValue)
      XCTAssertEqual(snapshot.snips, [replacement], adapter.rawValue)
    }
  }

  func testDurableAdaptersMatchAttachmentPruning() async throws {
    try await forEachAdapter { adapter, _, library in
      let sourceDirectory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: sourceDirectory) }
      let sourceURL = sourceDirectory.appendingPathComponent("remove-me.txt")
      try Data("Temporary".utf8).write(to: sourceURL)
      let added = try await library.perform(
        .add(
          content: "File",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [sourceURL],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
      let snip = try XCTUnwrap(added.snapshot.snips.first)
      let attachment = try XCTUnwrap(snip.attachments.first)
      let storedURL = try XCTUnwrap(added.snapshot.attachmentURLs[attachment.id])

      _ = try await library.perform(.delete(ids: [snip.id]), sortedBy: .chronological)
      XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path), adapter.rawValue)
      _ = try await library.perform(
        .pruneAttachments(retaining: []),
        sortedBy: .chronological
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path), adapter.rawValue)
    }
  }

  func testDurableAdaptersTreatEmptyMovesAsNoOpsBeforeListValidation() async throws {
    try await forEachAdapter { adapter, _, library in
      let missingList = UUID()
      _ = try await library.perform(
        .moveChronologically(ids: [], to: missingList),
        sortedBy: .manual
      )
      _ = try await library.perform(
        .place(ids: [], in: missingList, before: nil, basedOn: .manual),
        sortedBy: .manual
      )
      let snapshot = await library.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.lists, [.inbox], adapter.rawValue)
      XCTAssertTrue(snapshot.snips.isEmpty, adapter.rawValue)
    }
  }

  func testDurableAdaptersRememberEveryRestoreReplacingRequestID() async throws {
    try await forEachAdapter { adapter, _, library in
      let replaced = try await add(
        "Replace me",
        requestID: UUID(),
        at: 100,
        to: SnipList.inboxID,
        in: library
      )
      let existing = try await add(
        "Existing",
        requestID: UUID(),
        at: 200,
        to: SnipList.inboxID,
        in: library
      )
      let blockedRequestID = UUID()
      let filteredRestore = Snip(
        id: existing.id,
        requestID: blockedRequestID,
        createdAt: Date(timeIntervalSince1970: 300),
        content: "Filtered by stable ID",
        origin: .quickEntry
      )
      _ = try await library.perform(
        .restoreReplacing(
          snips: [filteredRestore],
          id: replaced.id,
          expectedUpdatedAt: replaced.updatedAt
        ),
        sortedBy: .chronological
      )
      let retry = try await library.perform(
        .add(
          content: "Must stay blocked",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [],
          requestID: blockedRequestID,
          now: Date(timeIntervalSince1970: 400)
        ),
        sortedBy: .chronological
      )
      XCTAssertEqual(retry.outcome, .add(.duplicate), adapter.rawValue)
      XCTAssertEqual(retry.snapshot.snips.map(\.id), [existing.id], adapter.rawValue)
    }
  }

  func testDurableAdaptersRejectMalformedImportedSnipsWithoutTrapping() async throws {
    try await forEachAdapter { adapter, _, library in
      let original = try await add(
        "Original",
        requestID: UUID(),
        at: 100,
        to: SnipList.inboxID,
        in: library
      )
      let duplicateID = UUID()
      let duplicateSnips = [
        Snip(
          id: duplicateID,
          requestID: UUID(),
          createdAt: Date(timeIntervalSince1970: 200),
          content: "First duplicate",
          origin: .quickEntry
        ),
        Snip(
          id: duplicateID,
          requestID: UUID(),
          createdAt: Date(timeIntervalSince1970: 300),
          content: "Second duplicate",
          origin: .quickEntry
        ),
      ]
      await assertThrows(.invalidStore) {
        _ = try await library.perform(.restore(snips: duplicateSnips), sortedBy: .chronological)
      }
      await assertThrows(.invalidStore) {
        _ = try await library.perform(
          .restoreReplacing(
            snips: duplicateSnips,
            id: original.id,
            expectedUpdatedAt: original.updatedAt
          ),
          sortedBy: .chronological
        )
      }

      let sharedAttachment = SnipAttachment(
        id: UUID(),
        fileName: "shared.txt",
        relativePath: "shared/shared.txt",
        contentType: "text/plain",
        byteCount: 6
      )
      let repeatedAttachment = Snip(
        requestID: UUID(),
        createdAt: Date(timeIntervalSince1970: 400),
        content: "Repeated attachment",
        origin: .quickEntry,
        attachments: [sharedAttachment, sharedAttachment]
      )
      await assertThrows(.invalidStore) {
        _ = try await library.perform(
          .replaceAll([repeatedAttachment]),
          sortedBy: .chronological
        )
      }

      let sharedSnips = [
        Snip(
          requestID: UUID(),
          createdAt: Date(timeIntervalSince1970: 500),
          content: "Shares attachment one",
          origin: .quickEntry,
          attachments: [sharedAttachment]
        ),
        Snip(
          requestID: UUID(),
          createdAt: Date(timeIntervalSince1970: 600),
          content: "Shares attachment two",
          origin: .quickEntry,
          attachments: [sharedAttachment]
        ),
      ]
      let restored = try await library.perform(
        .restore(snips: sharedSnips),
        sortedBy: .chronological
      )
      XCTAssertEqual(restored.snapshot.snips.count, 3, adapter.rawValue)
      XCTAssertEqual(
        restored.snapshot.snips.filter { $0.id != original.id }
          .flatMap(\.attachments).map(\.id),
        [sharedAttachment.id, sharedAttachment.id],
        adapter.rawValue
      )
    }
  }

  func testDurableAdaptersRememberDeletedRequestIDsAcrossReopen() async throws {
    try await forEachAdapter { adapter, directory, library in
      let requestID = UUID()
      let added = try await add(
        "One durable request",
        requestID: requestID,
        at: 100,
        to: SnipList.inboxID,
        in: library
      )
      _ = try await library.perform(.delete(ids: [added.id]), sortedBy: .chronological)

      let reopened = try adapter.open(in: directory)
      let retry = try await reopened.perform(
        .add(
          content: "Relaunch retry",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [],
          requestID: requestID,
          now: Date(timeIntervalSince1970: 200)
        ),
        sortedBy: .chronological
      )
      XCTAssertEqual(retry.outcome, .add(.duplicate), adapter.rawValue)
      XCTAssertTrue(retry.snapshot.snips.isEmpty, adapter.rawValue)
    }
  }

  func testSwiftDataAdaptersDoNotOverwriteEachOthersUnrelatedWrites() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("snips.store")
    let firstEnteredSaveHook = expectation(description: "First client entered save hook")
    let releaseFirstSave = DispatchSemaphore(value: 0)
    let first = try SwiftDataSnipLibrary(
      storeURL: storeURL,
      afterMutationBeforeSave: {
        firstEnteredSaveHook.fulfill()
        releaseFirstSave.wait()
      }
    )
    let second = try SwiftDataSnipLibrary(storeURL: storeURL)

    let firstWrite = Task.detached {
      try await first.perform(
        .add(
          content: "First client",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
    }
    await fulfillment(of: [firstEnteredSaveHook], timeout: 1)

    let secondStarted = expectation(description: "Second client started")
    let secondFinished = expectation(description: "Second client finished")
    secondFinished.isInverted = true
    let secondWrite = Task.detached {
      secondStarted.fulfill()
      defer { secondFinished.fulfill() }
      return try await second.perform(
        .add(
          content: "Second client",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 200)
        ),
        sortedBy: .chronological
      )
    }
    await fulfillment(of: [secondStarted], timeout: 1)
    await fulfillment(of: [secondFinished], timeout: 0.2)
    releaseFirstSave.signal()
    _ = try await firstWrite.value
    _ = try await secondWrite.value

    let snapshot = await first.snapshot(sortedBy: .chronological)
    XCTAssertEqual(snapshot.snips.map(\.content), ["Second client", "First client"])
  }

  func testSwiftDataSaveFailureRollsBackRecordsAndNewAttachmentFiles() async throws {
    enum InjectedFailure: Error { case save }
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("snips.store")
    let sourceURL = directory.appendingPathComponent("source.txt")
    let requestID = UUID()
    try Data("Must roll back".utf8).write(to: sourceURL)
    let library = try SwiftDataSnipLibrary(
      storeURL: storeURL,
      afterMutationBeforeSave: { throw InjectedFailure.save }
    )

    do {
      _ = try await library.perform(
        .add(
          content: "Failed write",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inboxID,
          attachmentURLs: [sourceURL],
          requestID: requestID,
          now: Date(timeIntervalSince1970: 100)
        ),
        sortedBy: .chronological
      )
      XCTFail("Expected the injected save failure.")
    } catch is InjectedFailure {
      // Expected.
    }

    let failedSnapshot = await library.snapshot(sortedBy: .chronological)
    XCTAssertTrue(failedSnapshot.snips.isEmpty)
    let attachmentRoot = directory.appendingPathComponent("Attachments", isDirectory: true)
    let remaining = try? FileManager.default.contentsOfDirectory(atPath: attachmentRoot.path)
    XCTAssertTrue(remaining?.isEmpty ?? true)
    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
    let reopenedSnapshot = await reopened.snapshot(sortedBy: .chronological)
    XCTAssertTrue(reopenedSnapshot.snips.isEmpty)
    let retry = try await reopened.perform(
      .add(
        content: "Retry after rollback",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inboxID,
        attachmentURLs: [],
        requestID: requestID,
        now: Date(timeIntervalSince1970: 200)
      ),
      sortedBy: .chronological
    )
    guard case .add(.added) = retry.outcome else {
      return XCTFail("Expected the rolled-back request ID to remain available.")
    }
  }

  func testSwiftDataStorePathKeepsJSONBackupSeparateAndFollowsDevSlotOverride() {
    let url = SwiftDataSnipLibrary.defaultStoreURL(
      fileManager: .default,
      environment: ["SNIP_SNAP_STORE_PATH": "/tmp/snip-snap-dev-slot/snips.json"]
    )
    XCTAssertEqual(url.path, "/tmp/snip-snap-dev-slot/Local/snips.store")
    XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Local")
    XCTAssertEqual(
      SwiftDataSnipLibrary.attachmentRootURL(forStoreURL: url).path,
      "/tmp/snip-snap-dev-slot/Local/Attachments"
    )
    XCTAssertEqual(SnipSnapStoreSchemaContract.currentVersion, 1)
  }

  func testSwiftDataRejectsAStoreWithRecordsButNoLists() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("snips.store")
    try makeRequestOnlySwiftDataStore(at: storeURL)

    XCTAssertThrowsError(try SwiftDataSnipLibrary(storeURL: storeURL)) { error in
      XCTAssertEqual(error as? SnipLibraryError, .invalidStore)
    }
  }

  private func forEachAdapter(
    _ body: (Adapter, URL, any SnipLibrary) async throws -> Void
  ) async throws {
    for adapter in Adapter.allCases {
      let directory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      try await body(adapter, directory, adapter.open(in: directory))
    }
  }

  private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnipLibraryBehaviorTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeRequestOnlySwiftDataStore(at storeURL: URL) throws {
    let schema = Schema(versionedSchema: SnipSnapSchemaV1.self)
    let configuration = ModelConfiguration(
      "SnipSnapLocal",
      schema: schema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(
      for: schema,
      migrationPlan: SnipSnapSchemaMigrationPlan.self,
      configurations: [configuration]
    )
    let context = ModelContext(container)
    context.autosaveEnabled = false
    context.insert(StoredRequestRecord(id: UUID()))
    try context.save()
  }

  private func createList(named name: String, in library: any SnipLibrary) async throws -> SnipList
  {
    let update = try await library.perform(
      .createList(name: name, systemImage: "briefcase"),
      sortedBy: .chronological
    )
    guard case .listCreated(let list) = update.outcome else {
      throw TestFailure.unexpectedOutcome
    }
    return list
  }

  private func add(
    _ content: String,
    requestID: UUID,
    at timestamp: TimeInterval,
    to listID: UUID,
    in library: any SnipLibrary
  ) async throws -> Snip {
    let update = try await library.perform(
      .add(
        content: content,
        origin: .quickEntry,
        source: nil,
        listID: listID,
        attachmentURLs: [],
        requestID: requestID,
        now: Date(timeIntervalSince1970: timestamp)
      ),
      sortedBy: .chronological
    )
    guard case .add(.added(let id)) = update.outcome,
      let snip = update.snapshot.snips.first(where: { $0.id == id })
    else {
      throw TestFailure.unexpectedOutcome
    }
    return snip
  }

  private func assertThrows(
    _ expected: SnipLibraryError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, expected)
    }
  }

  private enum TestFailure: Error {
    case unexpectedOutcome
  }
}
