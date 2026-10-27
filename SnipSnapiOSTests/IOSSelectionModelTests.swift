import Observation
import ImageIO
import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnapiOS

@MainActor
final class IOSSelectionModelTests: IOSModelTestCase {
    func testMergeSelectionPreservesAttachmentsAndShowsTheSavedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.txt")
        try Data("Attachment content".utf8).write(to: file)
        let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("library.json"))
        let model = IOSAppModel(library: library)
        await model.load()
        let firstCreated = await model.createSnip(content: "First merge note", in: SnipList.inboxID, attachmentURLs: [file])
        let secondCreated = await model.createSnip(content: "Second merge note", in: SnipList.inboxID)
        XCTAssertTrue(firstCreated)
        XCTAssertTrue(secondCreated)
        let attachments = model.snips.flatMap(\.attachments).map(\.id)
        model.selectedSnipIDs = Set(model.snips.map(\.id))
        let markedDone = await model.setSelectionDone(true)
        XCTAssertTrue(markedDone)
        model.completionFilter = .done

        let merged = await model.mergeSelection()

        XCTAssertTrue(merged)
        XCTAssertEqual(model.snips.count, 1)
        let result = try XCTUnwrap(model.snips.first)
        XCTAssertTrue(result.content.contains("First merge note"))
        XCTAssertTrue(result.content.contains("Second merge note"))
        XCTAssertEqual(result.attachments.map(\.id), attachments)
        XCTAssertEqual(model.completionFilter, .all)
        XCTAssertEqual(model.selectedSnipID, result.id)
        XCTAssertEqual(model.selectedSnipIDs, [result.id])
        let saved = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(saved.snips.map(\.id), [result.id])
        let singleMerge = await model.mergeSelection()
        XCTAssertFalse(singleMerge)
        XCTAssertEqual(model.snips.map(\.id), [result.id])
    }

    func testSelectionSessionPersistsAcrossListsAndEndsOnCancellationOrClipboard() async {
        let first = Snip(content: "First", origin: .quickEntry)
        let second = Snip(content: "Second", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [first, second])
        let model = makeModel(library: library)
        await model.load()
        let originalSnips = model.snips
        let initialSession = model.gatheringSessionID

        model.selectSnips([first.id])
        model.selectSnips([first.id, second.id])
        model.selectSnips([second.id])
        XCTAssertEqual(model.gatheringSessionID, initialSession)
        await model.load()
        XCTAssertEqual(model.gatheringSessionID, initialSession)

        model.endSelectingSnips()
        let afterCancellation = model.gatheringSessionID
        XCTAssertNotEqual(afterCancellation, initialSession)
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        model.selectSnips([first.id])
        XCTAssertEqual(model.gatheringSessionID, afterCancellation)

        model.selectPage(.clipboard)
        let afterLeaving = model.gatheringSessionID
        XCTAssertNotEqual(afterLeaving, afterCancellation)
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        model.selectList(SnipList.inboxID)
        let afterReturning = model.gatheringSessionID
        XCTAssertEqual(afterReturning, afterLeaving)
        model.selectSnips([second.id])
        XCTAssertEqual(model.gatheringSessionID, afterReturning)
        model.selectList(SnipList.inboxID)
        XCTAssertEqual(model.gatheringSessionID, afterReturning)
        XCTAssertEqual(model.selectedSnipIDs, [second.id])
        await model.load()
        XCTAssertEqual(model.snips, originalSnips)
        let reopened = makeModel(library: library)
        await reopened.load()
        XCTAssertNotEqual(reopened.gatheringSessionID, model.gatheringSessionID)
        XCTAssertEqual(reopened.snips, originalSnips)
    }

    func testMultiListSelectionKeepsLatestOnTopAndMovesAllItems() async throws {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        _ = await model.createSnip(content: "Inbox item", in: SnipList.inboxID)
        let inbox = try XCTUnwrap(model.snips.first)
        _ = await model.createList(name: "Work")
        let workID = model.lastSelectedListID
        _ = await model.createSnip(content: "Work item", in: workID)
        let work = try XCTUnwrap(model.snips.first { $0.content == "Work item" })
        _ = await model.createList(name: "Destination")
        let destinationID = model.lastSelectedListID
        model.selectList(SnipList.inboxID)
        model.selectSnips([inbox.id])
        let sessionID = model.gatheringSessionID
        model.isSelectionExpanded = true
        model.selectList(workID)
        model.selectSnips([inbox.id, work.id])
        XCTAssertEqual(model.selectedSnips.map(\.id), [work.id, inbox.id])
        XCTAssertEqual(model.gatheringSessionID, sessionID)
        XCTAssertTrue(model.isSelectionExpanded)
        XCTAssertTrue(model.isSelectingSnips)
        XCTAssertTrue(model.moveDestinations(for: model.selectedSnips).contains { $0.id == workID })
        model.completionFilter = .done
        XCTAssertEqual(model.selectedSnips.map(\.id), [work.id, inbox.id])
        model.completionFilter = .all
        let moved = await model.moveSelection(to: destinationID)
        XCTAssertTrue(moved)
        XCTAssertEqual(Set(model.visibleSnips(in: destinationID).map(\.id)), [inbox.id, work.id])
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        XCTAssertTrue(model.visibleSnips(in: SnipList.inboxID).isEmpty)
        XCTAssertTrue(model.visibleSnips(in: workID).isEmpty)
    }

    func testAddListMoveCapturesSelectionAndCancelDoesNotCreateAnything() async throws {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        _ = await model.createSnip(content: "Selected", in: SnipList.inboxID)
        let snip = try XCTUnwrap(model.snips.first)
        model.selectSnips([snip.id])
        let originalLists = model.lists
        model.requestNewListMove(snips: model.selectedSnips, fromSelection: true)
        model.newListMoveRequest = nil
        XCTAssertEqual(model.lists, originalLists)
        XCTAssertEqual(model.selectedSnipIDs, [snip.id])
        model.requestNewListMove(snips: model.selectedSnips, fromSelection: true)
        let request = try XCTUnwrap(model.newListMoveRequest)
        model.newListMoveRequest = nil
        let moved = await model.createListAndMove(request, name: "New destination")
        XCTAssertTrue(moved)
        let list = try XCTUnwrap(model.lists.first { $0.name == "New destination" })
        XCTAssertEqual(model.snips.first?.listID, list.id)
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        XCTAssertFalse(model.isPerformingGatheredAction)
    }

    func testFailedAddListMovePreservesTheSelection() async throws {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        _ = await model.createList(name: "Work")
        _ = await model.createSnip(content: "Selected", in: SnipList.inboxID)
        model.selectSnips(Set(model.snips.map(\.id)))
        let selectedIDs = model.selectedSnipIDs
        model.requestNewListMove(snips: model.selectedSnips, fromSelection: true)
        let request = try XCTUnwrap(model.newListMoveRequest)
        model.newListMoveRequest = nil
        let moved = await model.createListAndMove(request, name: "Work")
        XCTAssertFalse(moved)
        XCTAssertEqual(model.selectedSnipIDs, selectedIDs)
        XCTAssertEqual(model.snips.first?.listID, SnipList.inboxID)
        XCTAssertEqual(model.lists.count, 2)
        XCTAssertFalse(model.isPerformingGatheredAction)
        XCTAssertTrue(model.isSelectingSnips)
        XCTAssertNotNil(model.errorMessage)
    }

    func testMultiListCompletionAndDeleteUseTheWholeSelection() async throws {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        _ = await model.createSnip(content: "Inbox item", in: SnipList.inboxID)
        let first = try XCTUnwrap(model.snips.first)
        _ = await model.createList(name: "Work")
        _ = await model.createSnip(content: "Work item", in: model.lastSelectedListID)
        let second = try XCTUnwrap(model.snips.first { $0.content == "Work item" })
        model.selectSnips([first.id, second.id])
        let marked = await model.setSelectionDone(true)
        XCTAssertTrue(marked)
        XCTAssertTrue(model.snips.allSatisfy(\.isDone))
        let deleted = await model.deleteSelection()
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.snips.isEmpty)
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        let toast = try XCTUnwrap(model.toast)
        await model.performToastActionNow(toast)
        XCTAssertEqual(Set(model.snips.map(\.id)), [first.id, second.id])
        XCTAssertEqual(model.snips.first { $0.id == first.id }?.listID, SnipList.inboxID)
        XCTAssertEqual(model.snips.first { $0.id == second.id }?.listID, second.listID)
    }

    func testCancelledSelectionInvalidatesPendingAddListMove() async throws {
        let model = makeModel(library: ModelTestLibrary())
        await model.load()
        _ = await model.createSnip(content: "Selected", in: SnipList.inboxID)
        model.selectSnips(Set(model.snips.map(\.id)))
        model.requestNewListMove(snips: model.selectedSnips, fromSelection: true)
        let request = try XCTUnwrap(model.newListMoveRequest)
        model.endSelectingSnips()
        let moved = await model.createListAndMove(request, name: "Stale destination")
        XCTAssertFalse(moved)
        XCTAssertEqual(model.lists, [.inbox])
        XCTAssertEqual(model.snips.first?.listID, SnipList.inboxID)
    }

    func testReturningAndCancellingSelectedSnipsKeepsTheirSourceOrderAndStorage() async {
        let first = Snip(content: "First", origin: .quickEntry, manualPosition: 0)
        let second = Snip(content: "Second", origin: .quickEntry, manualPosition: 1)
        let third = Snip(content: "Third", origin: .quickEntry, manualPosition: 2)
        let model = makeModel(library: ModelTestLibrary(snips: [third, first, second]))
        await model.load()
        model.sortMode = .manual
        await model.load()
        let originalSnips = model.snips

        model.selectSnips([third.id])
        model.selectSnips([third.id, first.id])

        XCTAssertEqual(model.selectedSnips.map(\.id), [first.id, third.id])
        XCTAssertEqual(model.visibleSnips.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(model.snips, originalSnips)
        await model.load()
        XCTAssertEqual(model.snips, originalSnips)
        XCTAssertEqual(model.selectedSnips.map(\.id), [first.id, third.id])

        model.selectSnips([third.id])

        XCTAssertEqual(model.selectedSnips.map(\.id), [third.id])
        XCTAssertEqual(model.visibleSnips.map(\.id), [first.id, second.id, third.id])
        await model.load()
        XCTAssertEqual(model.snips, originalSnips)

        model.endSelectingSnips()

        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        XCTAssertTrue(model.selectedSnips.isEmpty)
        XCTAssertEqual(model.visibleSnips.map(\.id), [first.id, second.id, third.id])
        await model.load()
        XCTAssertEqual(model.snips, originalSnips)
        XCTAssertEqual(model.lastSelectedListID, SnipList.inboxID)
    }

    func testMovingSelectedSnipsCommitsTheirSourceOrderAheadOfTheDestinationSnips() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("library.json")
        let model = makeModel(library: try JSONSnipLibrary(fileURL: storeURL))
        await model.load()
        for content in ["First", "Second", "Third"] {
            let created = await model.createSnip(content: content, in: SnipList.inboxID)
            XCTAssertTrue(created)
        }
        let first = try XCTUnwrap(model.snips.first { $0.content == "First" })
        let second = try XCTUnwrap(model.snips.first { $0.content == "Second" })
        let third = try XCTUnwrap(model.snips.first { $0.content == "Third" })
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = model.lastSelectedListID
        for content in ["Destination first", "Destination second"] {
            let created = await model.createSnip(content: content, in: workID)
            XCTAssertTrue(created)
        }
        let destinationFirst = try XCTUnwrap(model.snips.first { $0.content == "Destination first" })
        let destinationSecond = try XCTUnwrap(model.snips.first { $0.content == "Destination second" })
        let orderedDestination = await model.placeVisibleSnips([destinationFirst.id, destinationSecond.id])
        XCTAssertTrue(orderedDestination)
        model.selectList(SnipList.inboxID)
        let orderedSource = await model.placeVisibleSnips([second.id, third.id, first.id])
        XCTAssertTrue(orderedSource)
        let originalSnips = model.snips
        model.selectSnips([first.id])
        model.selectSnips([first.id, second.id])
        XCTAssertEqual(model.selectedSnips.map(\.id), [second.id, first.id])
        XCTAssertEqual(model.snips, originalSnips)

        let moved = await model.moveSelection(to: workID)

        XCTAssertTrue(moved)
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        XCTAssertTrue(model.selectedSnips.isEmpty)
        XCTAssertNil(model.selectedSnipID)
        XCTAssertEqual(model.lastSelectedListID, SnipList.inboxID)
        XCTAssertEqual(model.visibleSnips.map(\.id), [third.id])
        XCTAssertEqual(
            model.visibleSnips(in: workID).map(\.id),
            [second.id, first.id, destinationFirst.id, destinationSecond.id]
        )

        let reopened = makeModel(library: try JSONSnipLibrary(fileURL: storeURL))
        await reopened.load()
        reopened.sortMode = .manual
        XCTAssertEqual(reopened.visibleSnips.map(\.id), [third.id])
        XCTAssertEqual(
            reopened.visibleSnips(in: workID).map(\.id),
            [second.id, first.id, destinationFirst.id, destinationSecond.id]
        )
    }

    func testQueuedDeleteKeepsRequestedIDsAndPreservesNewGathering() async throws {
        let first = Snip(content: "Delete this gathering", origin: .quickEntry)
        let second = Snip(content: "Keep the later gathering", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [first, second])
        let model = makeModel(library: library)
        await model.load()
        model.selectSnips([first.id])
        await library.suspendNextCommand()
        let holding = Task { await model.createSnip(content: "Holding access", in: SnipList.inboxID, selectCreatedSnip: false) }
        await library.waitUntilFirstCommandStarts()
        let requested = expectation(description: "Delete requested while access is held")
        let deletion = Task {
            requested.fulfill()
            return await model.deleteSelection()
        }
        await fulfillment(of: [requested], timeout: 2)
        model.endSelectingSnips()
        model.selectSnips([second.id])
        await library.resumeFirstCommand()
        let saved = await holding.value
        let deleted = await deletion.value
        XCTAssertTrue(saved)
        XCTAssertTrue(deleted)
        XCTAssertFalse(model.snips.contains { $0.id == first.id })
        XCTAssertTrue(model.snips.contains { $0.id == second.id })
        XCTAssertEqual(model.selectedSnipIDs, [second.id])
    }

    func testQueuedMoreActionsKeepRequestedIDsAndPreserveNewGathering() async throws {
        for merges in [false, true] {
            var first = Snip(content: "First requested", origin: .quickEntry)
            first.isDone = true
            let second = Snip(content: "Second requested", origin: .quickEntry)
            var later = Snip(content: "Later gathering", origin: .quickEntry)
            later.isDone = true
            let otherLater = Snip(content: "Other later gathering", origin: .quickEntry)
            let library = ModelTestLibrary(snips: [first, second, later, otherLater])
            let model = makeModel(library: library)
            await model.load()
            model.selectSnips(merges ? [first.id, second.id] : [first.id])
            await library.suspendNextCommand()
            let holding = Task { await model.createSnip(content: "Holding access", in: SnipList.inboxID, selectCreatedSnip: false) }
            await library.waitUntilFirstCommandStarts()
            let requested = expectation(description: "More action requested while access is held")
            let action = Task {
                requested.fulfill()
                return merges ? await model.mergeSelection() : await model.setSelectionDone(false)
            }
            await fulfillment(of: [requested], timeout: 2)
            model.endSelectingSnips()
            model.selectSnips([later.id, otherLater.id])
            await library.resumeFirstCommand()
            let saved = await holding.value
            let succeeded = await action.value
            XCTAssertTrue(saved)
            XCTAssertTrue(succeeded)
            if merges {
                let mergedIDs = await library.mergedIDs()
                XCTAssertEqual(mergedIDs, [first.id, second.id])
            } else {
                XCTAssertEqual(model.snips.first { $0.id == first.id }?.isDone, false)
                XCTAssertEqual(model.snips.first { $0.id == later.id }?.isDone, true)
            }
            XCTAssertEqual(model.selectedSnipIDs, [later.id, otherLater.id])
        }
    }

    func testQueuedMergeResultPreservesLaterPageSessionEditorAndFilter() async throws {
        for changesPage in [false, true] {
            let first = Snip(content: "First requested", origin: .quickEntry)
            let second = Snip(content: "Second requested", origin: .quickEntry)
            let library = ModelTestLibrary(snips: [first, second])
            let model = makeModel(library: library)
            await model.load()
            if changesPage {
                let created = await model.createList(name: "Later page")
                XCTAssertTrue(created)
            }
            let laterListID = model.lastSelectedListID
            let created = await model.createSnip(content: "Later editor", in: laterListID, selectCreatedSnip: false)
            XCTAssertTrue(created)
            let later = try XCTUnwrap(model.snips.first { $0.content == "Later editor" })
            model.selectList(SnipList.inboxID)
            model.selectSnips([first.id, second.id])
            await library.suspendNextCommand()
            let holding = Task { await model.createSnip(content: "Holding access", in: SnipList.inboxID, selectCreatedSnip: false) }
            await library.waitUntilFirstCommandStarts()
            let requested = expectation(description: "Merge requested before navigation")
            let merge = Task {
                requested.fulfill()
                return await model.mergeSelection()
            }
            await fulfillment(of: [requested], timeout: 2)
            model.endSelectingSnips()
            model.selectList(laterListID)
            model.selectSnips([later.id])
            model.selectedSnipID = later.id
            model.completionFilter = .done
            await library.resumeFirstCommand()
            let saved = await holding.value
            let merged = await merge.value
            XCTAssertTrue(saved)
            XCTAssertTrue(merged)
            XCTAssertTrue(model.snips.contains { $0.content == "Controlled merge result" })
            XCTAssertFalse(model.snips.contains { $0.id == first.id || $0.id == second.id })
            XCTAssertEqual(model.lastSelectedListID, laterListID)
            XCTAssertEqual(model.selectedSnipIDs, [later.id])
            XCTAssertEqual(model.selectedSnipID, later.id)
            XCTAssertEqual(model.completionFilter, .done)
        }
    }

    func testQueuedSelectionMoveKeepsItsOriginalOrderAndPreservesNewerPageSelection() async throws {
        let first = Snip(
            createdAt: Date(timeIntervalSince1970: 1),
            content: "First gathered", origin: .quickEntry, manualPosition: 0
        )
        let second = Snip(
            createdAt: Date(timeIntervalSince1970: 2),
            content: "Second gathered", origin: .quickEntry, manualPosition: 1
        )
        let remaining = Snip(content: "Left behind", origin: .quickEntry, manualPosition: 2)
        let library = ModelTestLibrary(snips: [first, second, remaining])
        let model = makeModel(library: library)
        await model.load()
        let destinationCreated = await model.createList(name: "Destination")
        XCTAssertTrue(destinationCreated)
        let destinationID = model.lastSelectedListID
        let laterCreated = await model.createList(name: "Later")
        XCTAssertTrue(laterCreated)
        let laterID = model.lastSelectedListID
        let snipCreated = await model.createSnip(content: "New selection", in: laterID)
        XCTAssertTrue(snipCreated)
        let laterSnip = try XCTUnwrap(model.snips.first { $0.content == "New selection" })
        model.selectList(SnipList.inboxID)
        model.sortMode = .manual
        model.selectSnips([second.id, first.id])
        XCTAssertEqual(model.selectedSnips.map(\.id), [first.id, second.id])

        await library.suspendNextCommand()
        let pendingCreation = Task {
            await model.createSnip(
                content: "Arrived while move queued", in: destinationID, selectCreatedSnip: false
            )
        }
        await library.waitUntilFirstCommandStarts()
        let moveStarted = expectation(description: "Move is requested while the library is locked")
        let queuedMove = Task {
            moveStarted.fulfill()
            return await model.moveSelection(to: destinationID)
        }
        await fulfillment(of: [moveStarted], timeout: 2)
        model.selectList(laterID)
        model.sortMode = .chronological
        model.selectSnips([laterSnip.id])
        model.beginEditingSnip(laterSnip.id)
        await library.resumeFirstCommand()
        let created = await pendingCreation.value
        let moved = await queuedMove.value

        XCTAssertTrue(created)
        XCTAssertTrue(moved)
        XCTAssertEqual(model.lastSelectedListID, laterID)
        XCTAssertEqual(model.selectedSnipIDs, [laterSnip.id])
        XCTAssertEqual(model.selectedSnipID, laterSnip.id)
        XCTAssertEqual(model.selectedSnips.map(\.id), [laterSnip.id])
        XCTAssertEqual(model.visibleSnips.map(\.id), [laterSnip.id])
        let arrived = try XCTUnwrap(model.snips.first { $0.content == "Arrived while move queued" })
        model.sortMode = .manual
        XCTAssertEqual(model.visibleSnips(in: SnipList.inboxID).map(\.id), [remaining.id])
        XCTAssertEqual(
            model.visibleSnips(in: destinationID).map(\.id),
            [first.id, second.id, arrived.id]
        )
        await model.load()
        XCTAssertEqual(model.selectedSnipIDs, [laterSnip.id])
        XCTAssertEqual(model.selectedSnipID, laterSnip.id)
        XCTAssertEqual(
            model.visibleSnips(in: destinationID).map(\.id),
            [first.id, second.id, arrived.id]
        )
    }

    func testQueuedMovePreservesNewGatheringAfterLeavingAndReturningToItsSource() async throws {
        let original = Snip(content: "Original gather", origin: .quickEntry, manualPosition: 0)
        let newlyGathered = Snip(content: "New gather", origin: .quickEntry, manualPosition: 1)
        let remaining = Snip(content: "Ungathered", origin: .quickEntry, manualPosition: 2)
        let library = ModelTestLibrary(snips: [original, newlyGathered, remaining])
        let model = makeModel(library: library)
        await model.load()
        let destinationCreated = await model.createList(name: "Destination")
        XCTAssertTrue(destinationCreated)
        let destinationID = model.lastSelectedListID
        model.selectList(SnipList.inboxID)
        model.sortMode = .manual
        model.selectSnips([original.id])
        let initiatingSession = model.gatheringSessionID

        await library.suspendNextCommand()
        let pendingCreation = Task {
            await model.createSnip(
                content: "Saved while waiting", in: destinationID, selectCreatedSnip: false
            )
        }
        await library.waitUntilFirstCommandStarts()
        let moveStarted = expectation(description: "Original move is queued")
        let queuedMove = Task {
            moveStarted.fulfill()
            return await model.moveSelection(to: destinationID)
        }
        await fulfillment(of: [moveStarted], timeout: 2)
        model.selectPage(.clipboard)
        model.selectList(SnipList.inboxID)
        model.selectSnips([newlyGathered.id])
        let newSession = model.gatheringSessionID
        XCTAssertNotEqual(newSession, initiatingSession)
        await library.resumeFirstCommand()
        let created = await pendingCreation.value
        let moved = await queuedMove.value

        XCTAssertTrue(created)
        XCTAssertTrue(moved)
        XCTAssertEqual(model.selectedPage, .list(SnipList.inboxID))
        XCTAssertNotEqual(model.gatheringSessionID, initiatingSession)
        XCTAssertEqual(model.gatheringSessionID, newSession)
        XCTAssertEqual(model.selectedSnipIDs, [newlyGathered.id])
        XCTAssertEqual(model.selectedSnips.map(\.id), [newlyGathered.id])
        XCTAssertEqual(model.visibleSnips.map(\.id), [newlyGathered.id, remaining.id])
        XCTAssertEqual(model.visibleSnips(in: destinationID).map(\.content), ["Original gather", "Saved while waiting"])
        await model.load()
        XCTAssertEqual(model.gatheringSessionID, newSession)
        XCTAssertEqual(model.selectedSnipIDs, [newlyGathered.id])
        XCTAssertEqual(model.visibleSnips.map(\.id), [newlyGathered.id, remaining.id])
        XCTAssertEqual(model.visibleSnips(in: destinationID).map(\.content), ["Original gather", "Saved while waiting"])
    }

    func testQueuedMovesPreserveOverlappingNewSelection() async throws {
        for movesSelection in [false, true] {
            let original = Snip(content: "Selected again", origin: .quickEntry)
            let library = ModelTestLibrary(snips: [original])
            let model = makeModel(library: library)
            await model.load()
            _ = await model.createList(name: "Destination")
            let destinationID = model.lastSelectedListID
            model.selectList(SnipList.inboxID)
            if movesSelection { model.selectSnips([original.id]) }
            await library.suspendNextCommand()
            let holding = Task {
                await model.createSnip(content: "Holding access", in: destinationID, selectCreatedSnip: false)
            }
            await library.waitUntilFirstCommandStarts()
            let requested = expectation(description: "Move captured before a new selection session")
            let move = Task {
                requested.fulfill()
                return movesSelection
                    ? await model.moveSelection(to: destinationID)
                    : await model.moveSnip(id: original.id, to: destinationID)
            }
            await fulfillment(of: [requested], timeout: 2)
            model.endSelectingSnips()
            model.selectSnips([original.id])
            let newSessionID = model.gatheringSessionID
            await library.resumeFirstCommand()
            let held = await holding.value
            let moved = await move.value
            XCTAssertTrue(held)
            XCTAssertTrue(moved)
            XCTAssertEqual(model.snips.first { $0.id == original.id }?.listID, destinationID)
            XCTAssertEqual(model.selectedSnipIDs, [original.id])
            XCTAssertEqual(model.selectedSnips.map(\.id), [original.id])
            XCTAssertEqual(model.gatheringSessionID, newSessionID)
            XCTAssertTrue(model.isSelectingSnips)
        }
    }

    func testFailedSelectionMoveKeepsTheGatheredSnipsAndSourceStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("library.json")
        let model = makeModel(library: try JSONSnipLibrary(fileURL: storeURL))
        await model.load()
        let firstCreated = await model.createSnip(content: "First", in: SnipList.inboxID)
        let secondCreated = await model.createSnip(content: "Second", in: SnipList.inboxID)
        XCTAssertTrue(firstCreated && secondCreated)
        let first = try XCTUnwrap(model.snips.first { $0.content == "First" })
        let second = try XCTUnwrap(model.snips.first { $0.content == "Second" })
        let reordered = await model.placeVisibleSnips([first.id, second.id])
        XCTAssertTrue(reordered)
        let originalSnips = model.snips
        let persisted = makeModel(library: try JSONSnipLibrary(fileURL: storeURL))
        await persisted.load()
        let originalStoredSnips = persisted.snips
        model.selectSnips([second.id, first.id])

        let moved = await model.moveSelection(to: UUID())

        XCTAssertFalse(moved)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.selectedSnips.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.selectedSnipIDs, [first.id, second.id])
        XCTAssertEqual(model.snips, originalSnips)
        XCTAssertEqual(model.visibleSnips.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.lastSelectedListID, SnipList.inboxID)
        let reopened = makeModel(library: try JSONSnipLibrary(fileURL: storeURL))
        await reopened.load()
        reopened.sortMode = .manual
        XCTAssertEqual(reopened.snips, originalStoredSnips)
        XCTAssertEqual(reopened.visibleSnips.map(\.id), [first.id, second.id])
    }

    func testDroppingSnipsUsesManualOrderAndKeepsSelection() async {
        let older = Snip(createdAt: Date(timeIntervalSince1970: 1), content: "Older", origin: .quickEntry)
        let newer = Snip(createdAt: Date(timeIntervalSince1970: 2), content: "Newer", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [older, newer])
        let model = IOSAppModel(library: library)
        await model.load()
        model.selectedSnipIDs = [newer.id]
        XCTAssertEqual(model.visibleSnips.map(\.id), [newer.id, older.id])
        XCTAssertTrue(model.canReorderVisibleSnips)

        let moved = await model.placeVisibleSnips([older.id, newer.id])

        XCTAssertTrue(moved)
        XCTAssertEqual(model.sortMode, .manual)
        XCTAssertEqual(model.visibleSnips.map(\.id), [older.id, newer.id])
        XCTAssertEqual(model.selectedSnipIDs, [newer.id])
        await model.load()
        XCTAssertEqual(model.visibleSnips.map(\.id), [older.id, newer.id])
        let saved = await library.snapshot(sortedBy: .manual)
        XCTAssertEqual(saved.snips.map(\.id), [older.id, newer.id])
    }

    func testDropRejectsFilteredOrStaleRowsWithoutChangingSort() async {
        let first = Snip(content: "First", origin: .quickEntry)
        let second = Snip(content: "Second", origin: .quickEntry)
        let model = IOSAppModel(library: ModelTestLibrary(snips: [first, second]))
        await model.load()
        let order = model.visibleSnips.map(\.id)

        model.searchText = "First"
        XCTAssertFalse(model.canReorderVisibleSnips)
        let searched = await model.placeVisibleSnips([first.id])
        XCTAssertFalse(searched)
        model.searchText = ""
        model.completionFilter = .notDone
        let filtered = await model.placeVisibleSnips(Array(order.reversed()))
        XCTAssertFalse(filtered)
        model.completionFilter = .all
        let missing = await model.placeVisibleSnips([first.id])
        let duplicate = await model.placeVisibleSnips([first.id, first.id])
        let foreign = await model.placeVisibleSnips([first.id, UUID()])
        XCTAssertFalse(missing)
        XCTAssertFalse(duplicate)
        XCTAssertFalse(foreign)
        XCTAssertEqual(model.sortMode, .chronological)
        XCTAssertEqual(model.visibleSnips.map(\.id), order)
    }

    func testDroppingAtTheSamePositionKeepsNewestFirst() async {
        let snip = Snip(content: "Unmoved", origin: .quickEntry)
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()

        let accepted = await model.placeVisibleSnips([snip.id])

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.sortMode, .chronological)
    }
}
