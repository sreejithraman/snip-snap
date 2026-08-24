import XCTest
import Foundation
@testable import SnipSnap

final class ItemRepositoryTests: StoreBackedTestCase {
    func testStoreReopensWithSavedItems() async throws {
        let url = try storeURL()
        let firstRepository = try ItemRepository(fileURL: url)
        let requestID = UUID()
        let source = CaptureSource(
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
        XCTAssertEqual(storedDocument["version"] as? Int, 4)
        XCTAssertEqual((storedDocument["sections"] as? [[String: Any]])?.count, 1)

        let reopened = try ItemRepository(fileURL: url)
        let items = await reopened.allItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].content, "A saved selection")
        XCTAssertEqual(items[0].requestID, requestID)
        XCTAssertEqual(items[0].source, source)
    }

    func testSelectionStoragePreservesContentWhileManualEntryStillTrims() async throws {
        let repository = try ItemRepository(fileURL: storeURL())

        _ = try await repository.add(content: "  selected line\n", origin: .selection)
        _ = try await repository.add(content: "  quick thought\n", origin: .quickEntry)

        let items = await repository.allItems()
        XCTAssertEqual(items.map(\.content), ["quick thought", "  selected line\n"])
    }

    func testItemsUseNewestFirstStableOrdering() async throws {
        let repository = try ItemRepository(fileURL: storeURL())
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

        let items = await repository.allItems()
        XCTAssertEqual(items.map(\.content), ["New", "Old"])
    }

    func testMergeReplacesItemsAndPersistsCombinedContext() async throws {
        let url = try storeURL()
        let repository = try ItemRepository(fileURL: url)
        let addedFirst = try await repository.add(
            content: "First thought",
            origin: .quickEntry,
            requestID: UUID(),
            now: Date(timeIntervalSince1970: 100)
        )
        let addedSecond = try await repository.add(
            content: "Second snippet",
            origin: .selection,
            source: CaptureSource(
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

        let reopened = try ItemRepository(fileURL: url)
        let items = await reopened.allItems()
        XCTAssertEqual(items.map(\.id), [merged.id])
    }

    func testRapidUniqueSavesDoNotDropOrDuplicateItems() async throws {
        let repository = try ItemRepository(fileURL: storeURL())
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

        let items = await repository.allItems()
        XCTAssertEqual(items.count, count)
        XCTAssertEqual(Set(items.map(\.content)).count, count)
        XCTAssertEqual(Set(items.map(\.requestID)).count, count)
    }

    func testDuplicateRequestIsIgnoredAcrossReopen() async throws {
        let url = try storeURL()
        let requestID = UUID()
        let repository = try ItemRepository(fileURL: url)
        let first = try await repository.add(
            content: "Keep once",
            origin: .selection,
            requestID: requestID
        )
        XCTAssertNotNil(first)

        let reopened = try ItemRepository(fileURL: url)
        let duplicate = try await reopened.add(
            content: "Do not add",
            origin: .selection,
            requestID: requestID
        )
        XCTAssertNil(duplicate)
        let items = await reopened.allItems()
        XCTAssertEqual(items.map(\.content), ["Keep once"])
    }

    func testDeletedRequestCannotBeReplayedDuringTheSameRun() async throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let requestID = UUID()
        let added = try await repository.add(
            content: "Delete once",
            origin: .selection,
            requestID: requestID
        )
        let item = try XCTUnwrap(added)

        try await repository.delete(ids: [item.id])
        let replay = try await repository.add(
            content: "Do not recreate",
            origin: .selection,
            requestID: requestID
        )

        XCTAssertNil(replay)
        let items = await repository.allItems()
        XCTAssertTrue(items.isEmpty)
    }

    func testSectionMovePersistsAcrossReopen() async throws {
        let url = try storeURL()
        let repository = try ItemRepository(fileURL: url)
        let build = try await repository.createSection(name: "Build", systemImage: "hammer")
        let addedItem = try await repository.add(content: "Move me", origin: .quickEntry)
        let item = try XCTUnwrap(addedItem)
        try await repository.moveChronologically(ids: [item.id], to: build.id)

        let reopened = try ItemRepository(fileURL: url)
        let reopenedItems = await reopened.allItems()
        let moved = try XCTUnwrap(reopenedItems.first)
        XCTAssertEqual(moved.sectionID, build.id)
        XCTAssertEqual(
            InboxFilter.apply(
                items: [moved],
                query: "build",
                completionFilter: .all,
                sectionNames: [build.id: build.name]
            ),
            [moved]
        )
    }

    func testDeletedItemsRestoreWithIdentityAndState() async throws {
        let url = try storeURL()
        let repository = try ItemRepository(fileURL: url)
        let addedItem = try await repository.add(content: "Recover me", origin: .quickEntry)
        var item = try XCTUnwrap(addedItem)
        try await repository.setDone(ids: [item.id], done: true)
        let itemsAfterDone = await repository.allItems()
        item = try XCTUnwrap(itemsAfterDone.first)

        try await repository.delete(ids: [item.id])
        let itemsAfterDelete = await repository.allItems()
        XCTAssertTrue(itemsAfterDelete.isEmpty)
        try await repository.restore(items: [item])

        let reopened = try ItemRepository(fileURL: url)
        let reopenedItems = await reopened.allItems()
        let restored = try XCTUnwrap(reopenedItems.first)
        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.requestID, item.requestID)
        XCTAssertEqual(restored.content, item.content)
        XCTAssertEqual(restored.origin, item.origin)
        XCTAssertEqual(restored.source, item.source)
        XCTAssertEqual(restored.sectionID, item.sectionID)
        XCTAssertEqual(restored.isDone, item.isDone)
    }

    func testRepositoryRejectsUndoAfterMergedItemChanges() async throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let addedFirst = try await repository.add(content: "First", origin: .quickEntry)
        let addedSecond = try await repository.add(content: "Second", origin: .quickEntry)
        let first = try XCTUnwrap(addedFirst)
        let second = try XCTUnwrap(addedSecond)
        let merged = try await repository.merge(ids: [first.id, second.id])
        try await repository.update(id: merged.id, content: "Edited merge")

        do {
            try await repository.restore(
                items: [first, second],
                replacing: merged.id,
                expectedUpdatedAt: merged.updatedAt
            )
            XCTFail("Expected the stale undo to fail")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .itemChanged)
        }

        let items = await repository.allItems()
        XCTAssertEqual(items.map(\.content), ["Edited merge"])
    }

    func testFailureStatesAreExplicit() async throws {
        let repository = try ItemRepository(fileURL: storeURL())
        do {
            _ = try await repository.add(content: "   ", origin: .quickEntry)
            XCTFail("Blank content should fail")
        } catch let error as RepositoryError {
            XCTAssertEqual(error, .emptyContent)
        }

        do {
            try await repository.update(id: UUID(), content: "Missing")
            XCTFail("A missing item should fail")
        } catch let error as RepositoryError {
            XCTAssertEqual(error, .itemNotFound)
        }

        let corruptURL = try storeURL()
        try Data("not json".utf8).write(to: corruptURL)
        XCTAssertThrowsError(try ItemRepository(fileURL: corruptURL)) { error in
            XCTAssertEqual(error as? RepositoryError, .invalidStore)
        }
    }

    func testMovesRequireAnExistingSectionAndRenameKeepsClipIdentity() async throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let section = try await repository.createSection(name: "Review", systemImage: "star")
        let added = try await repository.add(
            content: "Keep linked",
            origin: .quickEntry,
            sectionID: section.id
        )
        let item = try XCTUnwrap(added)

        try await repository.updateSection(id: section.id, name: "Agents", systemImage: "terminal")
        let renamedItems = await repository.allItems()
        XCTAssertEqual(try XCTUnwrap(renamedItems.first).sectionID, section.id)

        do {
            try await repository.moveChronologically(ids: [item.id], to: UUID())
            XCTFail("A move must not create a section")
        } catch let error as RepositoryError {
            XCTAssertEqual(error, .invalidSection)
        }
        let sections = await repository.allSections()
        XCTAssertEqual(sections.map(\.name), ["Inbox", "Agents"])
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

        let result = try ItemRepository.openRecoveringCorruptStore(fileURL: url)
        let backupURL = try XCTUnwrap(result.backupURL)
        XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let recoveryID = backupURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "items.corrupt-", with: "")
        let backupAttachment = url.deletingLastPathComponent()
            .appendingPathComponent("Attachments.corrupt-\(recoveryID)/kept/context.md")
        XCTAssertEqual(try String(contentsOf: backupAttachment, encoding: .utf8), "Keep me")

        _ = try await result.repository.add(content: "Safe after recovery", origin: .quickEntry)
        let reopened = try ItemRepository(fileURL: url)
        let reopenedContents = await reopened.allItems().map(\.content)
        XCTAssertEqual(reopenedContents, ["Safe after recovery"])
    }

    func testUnavailableStoreRejectsNewItems() async {
        let repository = ItemRepository.unavailable(fileURL: URL(fileURLWithPath: "/unavailable/items.json"))
        do {
            _ = try await repository.add(content: "Must not disappear", origin: .quickEntry)
            XCTFail("An unavailable store must reject writes")
        } catch let error as RepositoryError {
            XCTAssertEqual(error, .storeUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExactBatchPlacementAcrossSectionsPersistsVisibleOrder() async throws {
        let url = try storeURL()
        let repository = try ItemRepository(fileURL: url)
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let secondResult = try await repository.add(content: "Second", origin: .quickEntry)
        let targetResult = try await repository.add(content: "Target", origin: .quickEntry)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        let target = try XCTUnwrap(targetResult)
        let review = try await repository.createSection(name: "Review", systemImage: "star")
        try await repository.moveChronologically(ids: [target.id], to: review.id)

        try await repository.place(ids: [first.id, second.id], in: review.id, before: target.id)

        let reopened = try ItemRepository(fileURL: url)
        let manual = await reopened.allItems(sortMode: .manual).filter { $0.sectionID == review.id }
        XCTAssertEqual(manual.map(\.content), ["First", "Second", "Target"])
    }

    func testOrganizationChangesKeepContentEditTokenAndChronologicalMoveSeedsManualTop() async throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let existingResult = try await repository.add(content: "Existing", origin: .quickEntry)
        let existing = try XCTUnwrap(existingResult)
        let review = try await repository.createSection(name: "Review", systemImage: "star")
        try await repository.moveChronologically(ids: [existing.id], to: review.id)
        let movedResult = try await repository.add(content: "Moved", origin: .quickEntry)
        let moved = try XCTUnwrap(movedResult)
        let editToken = moved.updatedAt

        try await repository.moveChronologically(ids: [moved.id], to: review.id)

        let manual = await repository.allItems(sortMode: .manual).filter { $0.sectionID == review.id }
        XCTAssertEqual(manual.map(\.id), [moved.id, existing.id])
        XCTAssertEqual(manual.first?.updatedAt, editToken)
    }

    func testChronologicalBatchMoveKeepsItsVisibleOrderAtTopOfSavedManualOrder() async throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let targetResult = try await repository.add(content: "Target", origin: .quickEntry)
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let secondResult = try await repository.add(content: "Second", origin: .quickEntry)
        let target = try XCTUnwrap(targetResult)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        let review = try await repository.createSection(name: "Review", systemImage: "star")
        try await repository.moveChronologically(ids: [target.id], to: review.id)

        try await repository.moveChronologically(ids: [first.id, second.id], to: review.id)

        let manual = await repository.allItems(sortMode: .manual).filter { $0.sectionID == review.id }
        XCTAssertEqual(manual.map(\.id), [first.id, second.id, target.id])
    }

    func testManualMergeUsesHighestSelectedPlace() async throws {
        let repository = try ItemRepository(fileURL: storeURL())
        let firstResult = try await repository.add(content: "First", origin: .quickEntry)
        let middleResult = try await repository.add(content: "Middle", origin: .quickEntry)
        let lastResult = try await repository.add(content: "Last", origin: .quickEntry)
        let first = try XCTUnwrap(firstResult)
        let middle = try XCTUnwrap(middleResult)
        let last = try XCTUnwrap(lastResult)
        try await repository.place(
            ids: [first.id, middle.id, last.id],
            in: SnipSnapSection.inboxID,
            before: nil
        )

        let merged = try await repository.merge(ids: [first.id, last.id])

        let manual = await repository.allItems(sortMode: .manual)
        XCTAssertEqual(manual.map(\.id), [merged.id, middle.id])
    }

    func testChronologicalMergeKeepsHighestSelectedSavedManualPlace() async throws {
        let repository = try ItemRepository(fileURL: storeURL())
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
            in: SnipSnapSection.inboxID,
            before: nil
        )

        let merged = try await repository.merge(ids: [new.id, middle.id])

        let manual = await repository.allItems(sortMode: .manual)
        XCTAssertEqual(manual.map(\.id), [old.id, merged.id])
    }

    func testEmptySectionsPersistAndDeletingOneMovesItsClipsToInbox() async throws {
        let url = try storeURL()
        let repository = try ItemRepository(fileURL: url)
        let section = try await repository.createSection(name: "Agents", systemImage: "terminal.fill")
        _ = try await repository.add(
            content: "Prompt",
            origin: .quickEntry,
            sectionID: section.id
        )

        let reopened = try ItemRepository(fileURL: url)
        let reopenedSections = await reopened.allSections()
        XCTAssertEqual(reopenedSections.map(\.name), ["Inbox", "Agents"])

        try await reopened.deleteSection(id: section.id)
        let remainingSections = await reopened.allSections()
        let remainingItems = await reopened.allItems()
        XCTAssertEqual(remainingSections.map(\.name), ["Inbox"])
        XCTAssertEqual(remainingItems.first?.sectionID, SnipSnapSection.inboxID)
    }

    func testAttachmentOnlyClipCopiesAStableLocalSnapshot() async throws {
        let url = try storeURL()
        let source = url.deletingLastPathComponent().appendingPathComponent("note.md")
        try Data("# Context".utf8).write(to: source)
        let repository = try ItemRepository(fileURL: url)

        let added = try await repository.add(
            content: "",
            origin: .quickEntry,
            attachmentURLs: [source]
        )
        let item = try XCTUnwrap(added)
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(item.attachments.map(\.fileName), ["note.md"])
        let copied = url.deletingLastPathComponent()
            .appendingPathComponent("Attachments")
            .appendingPathComponent(item.attachments[0].relativePath)
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "# Context")
    }

    func testMergePreservesAttachmentsInSourceOrder() async throws {
        let url = try storeURL()
        let firstSource = url.deletingLastPathComponent().appendingPathComponent("first.md")
        let secondSource = url.deletingLastPathComponent().appendingPathComponent("second.md")
        try Data("First".utf8).write(to: firstSource)
        try Data("Second".utf8).write(to: secondSource)
        let repository = try ItemRepository(fileURL: url)
        let firstResult = try await repository.add(
            content: "First clip",
            origin: .quickEntry,
            attachmentURLs: [firstSource],
            now: Date(timeIntervalSince1970: 100)
        )
        let first = try XCTUnwrap(firstResult)
        let secondResult = try await repository.add(
            content: "Second clip",
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
