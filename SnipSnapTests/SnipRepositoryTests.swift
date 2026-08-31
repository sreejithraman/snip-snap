import XCTest
import SnipSnapCore
import Foundation
@testable import SnipSnap
@testable import SnipSnapPersistence

final class SnipRepositoryTests: StoreBackedTestCase {
    func testLegacyItemStoreMovesToSnipsAndKeepsItsData() async throws {
        let snipsURL = try storeURL()
        let legacyURL = snipsURL.deletingLastPathComponent()
            .appendingPathComponent("items.json")
        let id = UUID()
        let requestID = UUID()
        let legacyDocument: [String: Any] = [
            "version": 4,
            "items": [[
                "id": id.uuidString,
                "requestID": requestID.uuidString,
                "createdAt": "2026-08-26T12:00:00Z",
                "updatedAt": "2026-08-26T12:00:00Z",
                "content": "Saved before the rename",
                "origin": "quickEntry",
                "sectionID": SnipList.inboxID.uuidString,
                "isDone": false,
                "manualPosition": 0,
                "attachments": [],
            ]],
            "sections": [[
                "id": SnipList.inboxID.uuidString,
                "name": "Inbox",
                "systemImage": "tray.fill",
                "position": 0,
            ]],
        ]
        try JSONSerialization.data(
            withJSONObject: legacyDocument,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: legacyURL)

        let repository = try JSONSnipLibrary(fileURL: snipsURL)
        let snips = await repository.allSnips()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snipsURL.path))
        XCTAssertEqual(snips.map(\.id), [id])
        XCTAssertEqual(snips.map(\.requestID), [requestID])
        XCTAssertEqual(snips.map(\.content), ["Saved before the rename"])

        let migratedDocument = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: snipsURL)) as? [String: Any]
        )
        XCTAssertEqual(migratedDocument["version"] as? Int, JSONSnipLibrary.currentVersion)
        XCTAssertNotNil(migratedDocument["snips"])
        XCTAssertNotNil(migratedDocument["lists"])
        XCTAssertEqual(
            Set((migratedDocument["seenRequestIDs"] as? [String]) ?? []),
            [requestID.uuidString]
        )
        XCTAssertNil(migratedDocument["items"])
        XCTAssertNil(migratedDocument["sections"])
    }

    func testStoreReopensWithSavedSnips() async throws {
        let url = try storeURL()
        let firstRepository = try JSONSnipLibrary(fileURL: url)
        let requestID = UUID()
        let source = SnipSource(
            applicationName: "Safari",
            windowTitle: "Reference",
            url: "https://example.com"
        )

        _ = try await firstRepository.add(
            content: "A saved selection",
            origin: .selection,
            source: source,
            requestID: requestID
        )

        let storedDocument = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(storedDocument["version"] as? Int, 6)
        let storedSnips = storedDocument["snips"] as? [[String: Any]]
        XCTAssertEqual(storedSnips?.count, 1)
        XCTAssertNotNil(storedSnips?.first?["listID"])
        XCTAssertNil(storedSnips?.first?["sectionID"])
        XCTAssertNil(storedDocument["items"])
        XCTAssertEqual((storedDocument["lists"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(
            Set((storedDocument["seenRequestIDs"] as? [String]) ?? []),
            [requestID.uuidString]
        )

        let reopened = try JSONSnipLibrary(fileURL: url)
        let snips = await reopened.allSnips()
        XCTAssertEqual(snips.count, 1)
        XCTAssertEqual(snips[0].content, "A saved selection")
        XCTAssertEqual(snips[0].requestID, requestID)
        XCTAssertEqual(snips[0].source, source)
    }

    func testVersionSixWithoutRequestLedgerSeedsItFromSavedSnips() async throws {
        let url = try storeURL()
        let requestID = UUID()
        let firstRepository = try JSONSnipLibrary(fileURL: url)
        let saved = try await firstRepository.add(
            content: "Saved by an older version-six build",
            origin: .selection,
            requestID: requestID
        )
        let savedSnip = try XCTUnwrap(saved)

        var legacyVersionSix = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        legacyVersionSix.removeValue(forKey: "seenRequestIDs")
        try JSONSerialization.data(
            withJSONObject: legacyVersionSix,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: url, options: .atomic)

        let reopened = try JSONSnipLibrary(fileURL: url)
        try await reopened.delete(ids: [savedSnip.id])
        let replay = try await reopened.add(
            content: "Do not recreate",
            origin: .selection,
            requestID: requestID
        )

        XCTAssertNil(replay)
        let rewrittenDocument = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(rewrittenDocument["version"] as? Int, 6)
        XCTAssertEqual(
            Set((rewrittenDocument["seenRequestIDs"] as? [String]) ?? []),
            [requestID.uuidString]
        )
    }

    func testSelectionStoragePreservesContentWhileManualEntryStillTrims() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())

        _ = try await repository.add(content: "  selected line\n", origin: .selection)
        _ = try await repository.add(content: "  quick thought\n", origin: .quickEntry)

        let snips = await repository.allSnips()
        XCTAssertEqual(snips.map(\.content), ["quick thought", "  selected line\n"])
    }

    func testSnipsUseNewestFirstStableOrdering() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)

        _ = try await repository.add(
            content: "Old",
            origin: .quickEntry,
            requestID: UUID(),
            now: oldDate
        )
        _ = try await repository.add(
            content: "New",
            origin: .quickEntry,
            requestID: UUID(),
            now: newDate
        )

        let snips = await repository.allSnips()
        XCTAssertEqual(snips.map(\.content), ["New", "Old"])
    }

    func testMergeReplacesSnipsAndPersistsCombinedContext() async throws {
        let url = try storeURL()
        let repository = try JSONSnipLibrary(fileURL: url)
        let addedFirst = try await repository.add(
            content: "First thought",
            origin: .quickEntry,
            requestID: UUID(),
            now: Date(timeIntervalSince1970: 100)
        )
        let addedSecond = try await repository.add(
            content: "Second snippet",
            origin: .selection,
            source: SnipSource(
                applicationName: "Safari",
                windowTitle: "Docs",
                url: "https://example.com/docs"
            ),
            requestID: UUID(),
            now: Date(timeIntervalSince1970: 200)
        )
        let first = try XCTUnwrap(addedFirst)
        let second = try XCTUnwrap(addedSecond)

        let merged = try await repository.merge(
            ids: [first.id, second.id],
            now: Date(timeIntervalSince1970: 300)
        )
        XCTAssertEqual(
            merged.content,
            "First thought\n\n---\n\nSecond snippet\nSource: Safari — Docs\nURL: https://example.com/docs"
        )

        let reopened = try JSONSnipLibrary(fileURL: url)
        let snips = await reopened.allSnips()
        XCTAssertEqual(snips.map(\.id), [merged.id])
    }

    func testRapidUniqueSavesDoNotDropOrDuplicateSnips() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let count = 120

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    _ = try await repository.add(
                        content: "Capture \(index)",
                        origin: .selection,
                        requestID: UUID()
                    )
                }
            }
            try await group.waitForAll()
        }

        let snips = await repository.allSnips()
        XCTAssertEqual(snips.count, count)
        XCTAssertEqual(Set(snips.map(\.content)).count, count)
        XCTAssertEqual(Set(snips.map(\.requestID)).count, count)
    }

    func testDuplicateRequestIsIgnoredAcrossReopen() async throws {
        let url = try storeURL()
        let requestID = UUID()
        let repository = try JSONSnipLibrary(fileURL: url)
        let first = try await repository.add(
            content: "Keep once",
            origin: .selection,
            requestID: requestID
        )
        XCTAssertNotNil(first)

        let reopened = try JSONSnipLibrary(fileURL: url)
        let duplicate = try await reopened.add(
            content: "Do not add",
            origin: .selection,
            requestID: requestID
        )
        XCTAssertNil(duplicate)
        let snips = await reopened.allSnips()
        XCTAssertEqual(snips.map(\.content), ["Keep once"])
    }

    func testDeletedRequestCannotBeReplayedDuringTheSameRun() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let requestID = UUID()
        let added = try await repository.add(
            content: "Delete once",
            origin: .selection,
            requestID: requestID
        )
        let snip = try XCTUnwrap(added)

        try await repository.delete(ids: [snip.id])
        let replay = try await repository.add(
            content: "Do not recreate",
            origin: .selection,
            requestID: requestID
        )

        XCTAssertNil(replay)
        let snips = await repository.allSnips()
        XCTAssertTrue(snips.isEmpty)
    }

    func testListMovePersistsAcrossReopen() async throws {
        let url = try storeURL()
        let repository = try JSONSnipLibrary(fileURL: url)
        let build = try await repository.createList(name: "Build", systemImage: "hammer")
        let addedSnip = try await repository.add(content: "Move me", origin: .quickEntry)
        let snip = try XCTUnwrap(addedSnip)
        try await repository.moveChronologically(ids: [snip.id], to: build.id)

        let reopened = try JSONSnipLibrary(fileURL: url)
        let reopenedSnips = await reopened.allSnips()
        let moved = try XCTUnwrap(reopenedSnips.first)
        XCTAssertEqual(moved.listID, build.id)
        XCTAssertEqual(
            SnipFilter.apply(
                snips: [moved],
                query: "build",
                completionFilter: .all,
                listNames: [build.id: build.name]
            ),
            [moved]
        )
    }

    func testDeletedSnipsRestoreWithIdentityAndState() async throws {
        let url = try storeURL()
        let repository = try JSONSnipLibrary(fileURL: url)
        let addedSnip = try await repository.add(content: "Recover me", origin: .quickEntry)
        var snip = try XCTUnwrap(addedSnip)
        try await repository.setDone(ids: [snip.id], done: true)
        let snipsAfterDone = await repository.allSnips()
        snip = try XCTUnwrap(snipsAfterDone.first)

        try await repository.delete(ids: [snip.id])
        let snipsAfterDelete = await repository.allSnips()
        XCTAssertTrue(snipsAfterDelete.isEmpty)
        try await repository.restore(snips: [snip])

        let reopened = try JSONSnipLibrary(fileURL: url)
        let reopenedSnips = await reopened.allSnips()
        let restored = try XCTUnwrap(reopenedSnips.first)
        XCTAssertEqual(restored.id, snip.id)
        XCTAssertEqual(restored.requestID, snip.requestID)
        XCTAssertEqual(restored.content, snip.content)
        XCTAssertEqual(restored.origin, snip.origin)
        XCTAssertEqual(restored.source, snip.source)
        XCTAssertEqual(restored.listID, snip.listID)
        XCTAssertEqual(restored.isDone, snip.isDone)
    }

    func testRepositoryRejectsUndoAfterMergedItemChanges() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let addedFirst = try await repository.add(content: "First", origin: .quickEntry)
        let addedSecond = try await repository.add(content: "Second", origin: .quickEntry)
        let first = try XCTUnwrap(addedFirst)
        let second = try XCTUnwrap(addedSecond)
        let merged = try await repository.merge(ids: [first.id, second.id])
        try await repository.update(id: merged.id, content: "Edited merge")

        do {
            try await repository.restore(
                snips: [first, second],
                replacing: merged.id,
                expectedUpdatedAt: merged.updatedAt
            )
            XCTFail("Expected the stale undo to fail")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .snipChanged)
        }

        let snips = await repository.allSnips()
        XCTAssertEqual(snips.map(\.content), ["Edited merge"])
    }

    func testFailureStatesAreExplicit() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        do {
            _ = try await repository.add(content: "   ", origin: .quickEntry)
            XCTFail("Blank content should fail")
        } catch let error as SnipLibraryError {
            XCTAssertEqual(error, .emptyContent)
        }

        do {
            try await repository.update(id: UUID(), content: "Missing")
            XCTFail("A missing snip should fail")
        } catch let error as SnipLibraryError {
            XCTAssertEqual(error, .snipNotFound)
        }

        let corruptURL = try storeURL()
        try Data("not json".utf8).write(to: corruptURL)
        XCTAssertThrowsError(try JSONSnipLibrary(fileURL: corruptURL)) { error in
            XCTAssertEqual(error as? SnipLibraryError, .invalidStore)
        }
    }

    func testMovesRequireAnExistingListAndRenameKeepsSnipIdentity() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let list = try await repository.createList(name: "Review", systemImage: "star")
        let added = try await repository.add(
            content: "Keep linked",
            origin: .quickEntry,
            listID: list.id
        )
        let snip = try XCTUnwrap(added)

        try await repository.updateList(id: list.id, name: "Agents", systemImage: "terminal")
        let renamedSnips = await repository.allSnips()
        XCTAssertEqual(try XCTUnwrap(renamedSnips.first).listID, list.id)

        do {
            try await repository.moveChronologically(ids: [snip.id], to: UUID())
            XCTFail("A move must not create a list")
        } catch let error as SnipLibraryError {
            XCTAssertEqual(error, .invalidList)
        }
        let lists = await repository.allLists()
        XCTAssertEqual(lists.map(\.name), ["Inbox", "Agents"])
    }

    func testCorruptStoreIsBackedUpAndNewSavesPersistAtTheDefaultPath() async throws {
        let url = try storeURL()
        let corruptData = Data("not json".utf8)
        try corruptData.write(to: url)
        let attachmentDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("Attachments/kept", isDirectory: true)
        try FileManager.default.createDirectory(
            at: attachmentDirectory,
            withIntermediateDirectories: true
        )
        let attachment = attachmentDirectory.appendingPathComponent("context.md")
        try Data("Keep me".utf8).write(to: attachment)

        let result = try JSONSnipLibrary.openRecoveringCorruptStore(fileURL: url)
        let backupURL = try XCTUnwrap(result.backupURL)
        XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let recoveryID = backupURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "snips.corrupt-", with: "")
        let backupAttachment = url.deletingLastPathComponent()
            .appendingPathComponent("Attachments.corrupt-\(recoveryID)/kept/context.md")
        XCTAssertEqual(try String(contentsOf: backupAttachment, encoding: .utf8), "Keep me")

        _ = try await result.repository.add(content: "Safe after recovery", origin: .quickEntry)
        let reopened = try JSONSnipLibrary(fileURL: url)
        let reopenedContents = await reopened.allSnips().map(\.content)
        XCTAssertEqual(reopenedContents, ["Safe after recovery"])
    }

    func testUnavailableStoreRejectsNewSnips() async {
        let repository = JSONSnipLibrary.unavailable(fileURL: URL(fileURLWithPath: "/unavailable/snips.json"))
        do {
            _ = try await repository.add(content: "Must not disappear", origin: .quickEntry)
            XCTFail("An unavailable store must reject writes")
        } catch let error as SnipLibraryError {
            XCTAssertEqual(error, .storeUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExactBatchPlacementAcrossListsPersistsVisibleOrder() async throws {
        let url = try storeURL()
        let repository = try JSONSnipLibrary(fileURL: url)
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let secondResult = try await repository.add(content: "Second", origin: .quickEntry)
        let targetResult = try await repository.add(content: "Target", origin: .quickEntry)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        let target = try XCTUnwrap(targetResult)
        let review = try await repository.createList(name: "Review", systemImage: "star")
        try await repository.moveChronologically(ids: [target.id], to: review.id)

        try await repository.place(ids: [first.id, second.id], in: review.id, before: target.id)

        let reopened = try JSONSnipLibrary(fileURL: url)
        let manual = await reopened.allSnips(sortMode: .manual).filter { $0.listID == review.id }
        XCTAssertEqual(manual.map(\.content), ["First", "Second", "Target"])
    }

    func testOrganizationChangesKeepContentEditTokenAndChronologicalMoveSeedsManualTop() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let existingResult = try await repository.add(content: "Existing", origin: .quickEntry)
        let existing = try XCTUnwrap(existingResult)
        let review = try await repository.createList(name: "Review", systemImage: "star")
        try await repository.moveChronologically(ids: [existing.id], to: review.id)
        let movedResult = try await repository.add(content: "Moved", origin: .quickEntry)
        let moved = try XCTUnwrap(movedResult)
        let editToken = moved.updatedAt

        try await repository.moveChronologically(ids: [moved.id], to: review.id)

        let manual = await repository.allSnips(sortMode: .manual).filter { $0.listID == review.id }
        XCTAssertEqual(manual.map(\.id), [moved.id, existing.id])
        XCTAssertEqual(manual.first?.updatedAt, editToken)
    }

    func testChronologicalBatchMoveKeepsItsVisibleOrderAtTopOfSavedManualOrder() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let targetResult = try await repository.add(content: "Target", origin: .quickEntry)
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let secondResult = try await repository.add(content: "Second", origin: .quickEntry)
        let target = try XCTUnwrap(targetResult)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        let review = try await repository.createList(name: "Review", systemImage: "star")
        try await repository.moveChronologically(ids: [target.id], to: review.id)

        try await repository.moveChronologically(ids: [first.id, second.id], to: review.id)

        let manual = await repository.allSnips(sortMode: .manual).filter { $0.listID == review.id }
        XCTAssertEqual(manual.map(\.id), [first.id, second.id, target.id])
    }

    func testManualMergeUsesHighestSelectedPlace() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let middleResult = try await repository.add(content: "Middle", origin: .quickEntry)
        let lastResult = try await repository.add(content: "Last", origin: .quickEntry)
        let first = try XCTUnwrap(firstResult)
        let middle = try XCTUnwrap(middleResult)
        let last = try XCTUnwrap(lastResult)
        try await repository.place(
            ids: [first.id, middle.id, last.id],
            in: SnipList.inboxID,
            before: nil
        )

        let merged = try await repository.merge(ids: [first.id, last.id])

        let manual = await repository.allSnips(sortMode: .manual)
        XCTAssertEqual(manual.map(\.id), [merged.id, middle.id])
    }

    func testChronologicalMergeKeepsHighestSelectedSavedManualPlace() async throws {
        let repository = try JSONSnipLibrary(fileURL: storeURL())
        let oldResult = try await repository.add(
            content: "Old", origin: .quickEntry, now: Date(timeIntervalSince1970: 100)
        )
        let middleResult = try await repository.add(
            content: "Middle", origin: .quickEntry, now: Date(timeIntervalSince1970: 200)
        )
        let newResult = try await repository.add(
            content: "New", origin: .quickEntry, now: Date(timeIntervalSince1970: 300)
        )
        let old = try XCTUnwrap(oldResult)
        let middle = try XCTUnwrap(middleResult)
        let new = try XCTUnwrap(newResult)
        try await repository.place(
            ids: [old.id, new.id, middle.id],
            in: SnipList.inboxID,
            before: nil
        )

        let merged = try await repository.merge(ids: [new.id, middle.id])

        let manual = await repository.allSnips(sortMode: .manual)
        XCTAssertEqual(manual.map(\.id), [old.id, merged.id])
    }

    func testEmptyListsPersistAndDeletingOneMovesItsSnipsToInbox() async throws {
        let url = try storeURL()
        let repository = try JSONSnipLibrary(fileURL: url)
        let list = try await repository.createList(name: "Agents", systemImage: "terminal.fill")
        _ = try await repository.add(
            content: "Prompt",
            origin: .quickEntry,
            listID: list.id
        )

        let reopened = try JSONSnipLibrary(fileURL: url)
        let reopenedLists = await reopened.allLists()
        XCTAssertEqual(reopenedLists.map(\.name), ["Inbox", "Agents"])

        try await reopened.deleteList(id: list.id)
        let remainingLists = await reopened.allLists()
        let remainingSnips = await reopened.allSnips()
        XCTAssertEqual(remainingLists.map(\.name), ["Inbox"])
        XCTAssertEqual(remainingSnips.first?.listID, SnipList.inboxID)
    }

    func testAttachmentOnlySnipCopiesAStableLocalSnapshot() async throws {
        let url = try storeURL()
        let source = url.deletingLastPathComponent().appendingPathComponent("note.md")
        try Data("# Context".utf8).write(to: source)
        let repository = try JSONSnipLibrary(fileURL: url)

        let added = try await repository.add(
            content: "",
            origin: .quickEntry,
            attachmentURLs: [source]
        )
        let snip = try XCTUnwrap(added)
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(snip.attachments.map(\.fileName), ["note.md"])
        let copied = repository.attachmentURL(for: snip.attachments[0])
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "# Context")
    }

    func testMergePreservesAttachmentsInSourceOrder() async throws {
        let url = try storeURL()
        let firstSource = url.deletingLastPathComponent().appendingPathComponent("first.md")
        let secondSource = url.deletingLastPathComponent().appendingPathComponent("second.md")
        try Data("First".utf8).write(to: firstSource)
        try Data("Second".utf8).write(to: secondSource)
        let repository = try JSONSnipLibrary(fileURL: url)
        let firstResult = try await repository.add(
            content: "First snip",
            origin: .quickEntry,
            attachmentURLs: [firstSource],
            now: Date(timeIntervalSince1970: 100)
        )
        let first = try XCTUnwrap(firstResult)
        let secondResult = try await repository.add(
            content: "Second snip",
            origin: .quickEntry,
            attachmentURLs: [secondSource],
            now: Date(timeIntervalSince1970: 200)
        )
        let second = try XCTUnwrap(secondResult)

        let merged = try await repository.merge(ids: [first.id, second.id])

        XCTAssertEqual(merged.attachments.map(\.fileName), ["second.md", "first.md"])
        XCTAssertTrue(merged.attachments.allSatisfy {
            FileManager.default.fileExists(atPath: repository.attachmentURL(for: $0).path)
        })
    }
}
