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
    func testOriginFilterComposesWithoutDiscardingGatheredSelection() async {
        let manual = Snip(content: "Review manual", origin: .quickEntry)
        let agent = Snip(content: "Review agent", origin: .agent, pinnedAt: Date(timeIntervalSince1970: 1))
        let done = Snip(content: "Review done", origin: .agent, isDone: true)
        let other = SnipList(id: UUID(), name: "Other", systemImage: "folder", position: 1)
        let elsewhere = Snip(content: "Review elsewhere", origin: .agent, listID: other.id)
        let model = makeModel(library: ModelTestLibrary(snips: [manual, agent, done, elsewhere], lists: [.inbox, other]))
        await model.load()
        XCTAssertEqual(model.originFilter, .all)
        let originalOrder = model.visibleSnips.map(\.id)
        model.selectSnips([manual.id])
        model.originFilter = .agent
        XCTAssertEqual(Set(model.visibleSnips.map(\.id)), [agent.id, done.id])
        XCTAssertEqual(model.selectedSnipIDs, [manual.id])
        model.completionFilter = .done
        XCTAssertEqual(model.visibleSnips.map(\.id), [done.id])
        model.searchText = "Review agent"
        XCTAssertTrue(model.visibleSnips.isEmpty)
        model.completionFilter = .notDone
        XCTAssertEqual(model.visibleSnips.map(\.id), [agent.id])
        model.searchText = ""
        model.completionFilter = .all
        XCTAssertEqual(model.visibleSnips(in: other.id).map(\.id), [elsewhere.id])
        model.originFilter = .human
        XCTAssertEqual(model.visibleSnips.map(\.id), [manual.id])
        XCTAssertEqual(model.selectedSnipIDs, [manual.id])
        XCTAssertTrue(model.visibleSnips(in: other.id).isEmpty)
        model.completionFilter = .done
        XCTAssertTrue(model.visibleSnips.isEmpty)
        model.completionFilter = .notDone
        model.searchText = "Review manual"
        XCTAssertEqual(model.visibleSnips.map(\.id), [manual.id])
        model.searchText = ""
        model.completionFilter = .all
        model.originFilter = .all
        XCTAssertEqual(model.visibleSnips.map(\.id), originalOrder)
    }

    func testOriginFilterCannotHideInlineEditorOrReorderFilteredSubset() async {
        let manual = Snip(content: "Manual", origin: .quickEntry)
        let agent = Snip(content: "Agent", origin: .agent)
        let library = ModelTestLibrary(snips: [manual, agent])
        let model = makeModel(library: library)
        await model.load()
        XCTAssertTrue(model.beginInlineSnipEdit(manual))
        model.originFilter = .agent
        model.originFilter = .human
        XCTAssertEqual(model.originFilter, .all)
        XCTAssertTrue(model.visibleSnips.contains { $0.id == manual.id })
        model.cancelInlineSnipEdit()
        let before = await library.snapshot(sortedBy: .manual)
        for filter in [SnipOriginFilter.agent, .human] {
            model.originFilter = filter
            XCTAssertFalse(model.canReorderVisibleSnips)
            let moved = await model.placeVisibleSnips([agent.id])
            XCTAssertFalse(moved)
            let after = await library.snapshot(sortedBy: .manual)
            XCTAssertEqual(after.snips, before.snips)
            XCTAssertEqual(model.sortMode, .chronological)
        }
    }

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
        model.selectSnips(Set(model.snips.map(\.id)))
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

        model.selectSnips([first.id])
        let firstSession = model.gatheringSessionID
        model.selectSnips([first.id, second.id])
        model.selectSnips([second.id])
        XCTAssertEqual(model.gatheringSessionID, firstSession)
        await model.load()
        XCTAssertEqual(model.gatheringSessionID, firstSession)
        model.selectList(SnipList.inboxID)
        XCTAssertEqual(model.gatheringSessionID, firstSession)
        XCTAssertEqual(model.selectedSnipIDs, [second.id])
        XCTAssertTrue(model.isSelectingSnips)

        model.endSelectingSnips()
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        XCTAssertFalse(model.isSelectingSnips)
        model.selectSnips([first.id])
        let afterCancellation = model.gatheringSessionID
        XCTAssertNotEqual(afterCancellation, firstSession)
        model.selectSnips([first.id, second.id])
        XCTAssertEqual(model.gatheringSessionID, afterCancellation)

        model.selectPage(.clipboard)
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        XCTAssertFalse(model.isSelectingSnips)
        model.selectList(SnipList.inboxID)
        model.selectSnips([second.id])
        let afterReturning = model.gatheringSessionID
        XCTAssertNotEqual(afterReturning, afterCancellation)
        XCTAssertNotEqual(afterReturning, firstSession)
        model.selectList(SnipList.inboxID)
        XCTAssertEqual(model.gatheringSessionID, afterReturning)
        XCTAssertEqual(model.selectedSnipIDs, [second.id])
        await model.load()
        XCTAssertEqual(model.snips, originalSnips)
        let reopened = makeModel(library: library)
        await reopened.load()
        reopened.selectSnips([second.id])
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
        model.setSelectionExpanded(true)
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
        model.dismissNewListMove()
        XCTAssertEqual(model.lists, originalLists)
        XCTAssertEqual(model.selectedSnipIDs, [snip.id])
        model.requestNewListMove(snips: model.selectedSnips, fromSelection: true)
        let request = try XCTUnwrap(model.newListMoveRequest)
        model.dismissNewListMove()
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
        model.dismissNewListMove()
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

    func testGatheredActionsRunOneAtATimeAndEndTheSessionOnceTheSelectionEmpties() async throws {
        let gathered = Snip(content: "Delete when access frees", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [gathered])
        let model = makeModel(library: library)
        await model.load()
        model.selectSnips([gathered.id])
        await library.suspendNextCommand()
        let holding = Task { await model.createSnip(content: "Holding access", in: SnipList.inboxID, selectCreatedSnip: false) }
        await library.waitUntilFirstCommandStarts()

        let deletion = Task.immediate {
            await model.performGatheredAction(requiresEmptySelection: true) { await model.deleteSelection() }
        }
        XCTAssertTrue(model.isPerformingGatheredAction)
        var ranSecondAction = false
        let second = await model.performGatheredAction {
            ranSecondAction = true
            return true
        }
        XCTAssertFalse(second)
        XCTAssertFalse(ranSecondAction)
        XCTAssertTrue(model.isPerformingGatheredAction)

        await library.resumeFirstCommand()
        let saved = await holding.value
        let endsSession = await deletion.value
        XCTAssertTrue(saved)
        XCTAssertTrue(endsSession)
        XCTAssertFalse(model.isPerformingGatheredAction)
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        XCTAssertFalse(model.snips.contains { $0.id == gathered.id })
    }

    func testGatheredActionFromAnEndedSessionKeepsTheNewGathering() async throws {
        let first = Snip(content: "First gathering", origin: .quickEntry)
        let second = Snip(content: "Second gathering", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [first, second])
        let model = makeModel(library: library)
        await model.load()
        model.selectSnips([first.id])
        await library.suspendNextCommand()
        let holding = Task { await model.createSnip(content: "Holding access", in: SnipList.inboxID, selectCreatedSnip: false) }
        await library.waitUntilFirstCommandStarts()

        let action = Task.immediate {
            await model.performGatheredAction { await model.setSelectionDone(true) }
        }
        model.endSelectingSnips()
        model.selectSnips([second.id])
        let newSession = model.gatheringSessionID
        await library.resumeFirstCommand()
        let saved = await holding.value
        let endsSession = await action.value

        XCTAssertTrue(saved)
        XCTAssertFalse(endsSession)
        XCTAssertFalse(model.isPerformingGatheredAction)
        XCTAssertTrue(model.isSelectingSnips)
        XCTAssertEqual(model.gatheringSessionID, newSession)
        XCTAssertEqual(model.selectedSnipIDs, [second.id])
    }

    func testGatheredActionsThatMustEmptyTheSelectionKeepItOtherwise() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(library: try JSONSnipLibrary(fileURL: root.appendingPathComponent("library.json")))
        await model.load()
        let created = await model.createSnip(content: "Gathered", in: SnipList.inboxID)
        XCTAssertTrue(created)
        let gathered = try XCTUnwrap(model.snips.first)
        model.selectSnips([gathered.id])
        let session = model.gatheringSessionID

        let failedMove = await model.performGatheredAction(requiresEmptySelection: true) {
            await model.moveSelection(to: UUID())
        }
        XCTAssertFalse(failedMove)
        XCTAssertNotNil(model.errorMessage)
        let markedDone = await model.performGatheredAction(requiresEmptySelection: true) {
            await model.setSelectionDone(true)
        }
        XCTAssertFalse(markedDone)
        XCTAssertEqual(model.selectedSnipIDs, [gathered.id])
        XCTAssertEqual(model.gatheringSessionID, session)
        XCTAssertFalse(model.isPerformingGatheredAction)

        let reopened = await model.performGatheredAction { await model.setSelectionDone(false) }
        XCTAssertTrue(reopened)
    }

    func testAddListMoveEndsOnlyTheSessionItCameFrom() async throws {
        let gathered = Snip(content: "Gathered", origin: .quickEntry)
        let single = Snip(content: "Moved alone", origin: .quickEntry)
        let model = makeModel(library: ModelTestLibrary(snips: [gathered, single]))
        await model.load()
        model.selectSnips([gathered.id])
        model.requestNewListMove(snips: model.selectedSnips, fromSelection: true)
        let selectionRequest = try XCTUnwrap(model.newListMoveRequest)
        let movedSelection = await model.createListAndMove(selectionRequest, name: "Gathered list")
        XCTAssertTrue(movedSelection)
        XCTAssertNil(model.newListMoveRequest)
        XCTAssertFalse(model.isSelectingSnips)
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)

        model.beginSelectingSnips()
        let session = model.gatheringSessionID
        model.requestNewListMove(snips: [single])
        let singleRequest = try XCTUnwrap(model.newListMoveRequest)
        XCTAssertNil(singleRequest.selectionSessionID)
        let movedSingle = await model.createListAndMove(singleRequest, name: "Single list")
        XCTAssertTrue(movedSingle)
        XCTAssertNil(model.newListMoveRequest)
        XCTAssertTrue(model.isSelectingSnips)
        XCTAssertEqual(model.gatheringSessionID, session)
        let singleList = try XCTUnwrap(model.lists.first { $0.name == "Single list" })
        XCTAssertEqual(model.snips.first { $0.id == single.id }?.listID, singleList.id)
    }

    func testSelectStartsOneEmptyGatheringSessionAndGatheringStartsOneWhenIdle() async throws {
        let snip = Snip(content: "Gather me", origin: .quickEntry)
        let model = makeModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()
        XCTAssertFalse(model.isSelectingSnips)
        XCTAssertNil(model.gatheringSessionID)

        model.beginSelectingSnips()
        let session = try XCTUnwrap(model.gatheringSessionID)
        XCTAssertTrue(model.isSelectingSnips)
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        model.beginSelectingSnips()
        XCTAssertEqual(model.gatheringSessionID, session)
        model.selectSnips([snip.id])
        XCTAssertEqual(model.gatheringSessionID, session)

        model.endSelectingSnips()
        XCTAssertNil(model.gatheringSessionID)
        model.setSelectionExpanded(true)
        XCTAssertFalse(model.isSelectionExpanded)
        model.requestNewListMove(snips: model.snips, fromSelection: true)
        XCTAssertNil(model.newListMoveRequest)
        model.selectSnips([snip.id])
        XCTAssertTrue(model.isSelectingSnips)
        XCTAssertEqual(model.selectedSnipIDs, [snip.id])
        let gatheringSession = try XCTUnwrap(model.gatheringSessionID)
        XCTAssertNotEqual(gatheringSession, session)
    }

    func testRegatheringAfterPutBackIgnoresTheStaleDeparture() {
        let snip = Snip(content: "Gathered twice", origin: .quickEntry)
        var transfers = GatheringTransfers()
        let first = makeFlight(snip)
        transfers.begin(first)
        transfers.keep(only: [])
        XCTAssertFalse(transfers.isDeparting(snip.id))
        XCTAssertTrue(transfers.flights.isEmpty)

        let second = makeFlight(snip)
        transfers.begin(second)
        XCTAssertEqual(transfers.departure(of: snip.id), second.id)
        XCTAssertEqual(transfers.flights.map(\.id), [second.id])
        XCTAssertEqual(transfers.arrivingSnipIDs, [snip.id])

        transfers.finishDeparture(of: snip.id, departure: first.id)
        XCTAssertEqual(transfers.departure(of: snip.id), second.id)
        transfers.finishDeparture(of: snip.id, departure: second.id)
        XCTAssertNil(transfers.departure(of: snip.id))
        XCTAssertFalse(transfers.isDeparting(snip.id))
        XCTAssertEqual(transfers.flights.map(\.id), [second.id])
    }

    func testKeepingOnlySelectedSnipsDropsDeselectedFlightsAndDepartures() {
        let kept = Snip(content: "Still gathered", origin: .quickEntry)
        let putBack = Snip(content: "Put back", origin: .quickEntry)
        var transfers = GatheringTransfers()
        let keptFlight = makeFlight(kept)
        transfers.begin(keptFlight)
        transfers.begin(makeFlight(putBack))

        transfers.keep(only: [kept.id])

        XCTAssertEqual(transfers.flights.map(\.id), [keptFlight.id])
        XCTAssertEqual(transfers.arrivingSnipIDs, [kept.id])
        XCTAssertEqual(transfers.departure(of: kept.id), keptFlight.id)
        XCTAssertFalse(transfers.isDeparting(putBack.id))
    }

    func testLandingFlightsKeepsRowDeparturesUntilTheirFadesFinish() {
        let first = Snip(content: "First", origin: .quickEntry)
        let second = Snip(content: "Second", origin: .quickEntry)
        var transfers = GatheringTransfers()
        let firstFlight = makeFlight(first)
        let secondFlight = makeFlight(second)
        transfers.begin(firstFlight)
        transfers.begin(secondFlight)

        transfers.land(firstFlight.id)
        XCTAssertEqual(transfers.flights.map(\.id), [secondFlight.id])
        XCTAssertEqual(transfers.arrivingSnipIDs, [second.id])
        XCTAssertEqual(transfers.departure(of: first.id), firstFlight.id)

        transfers.landAll()
        XCTAssertTrue(transfers.flights.isEmpty)
        XCTAssertTrue(transfers.arrivingSnipIDs.isEmpty)
        XCTAssertEqual(transfers.departure(of: first.id), firstFlight.id)
        XCTAssertEqual(transfers.departure(of: second.id), secondFlight.id)
    }

    func testAimingFlightsChangesOnlyFlightsWithANewDestination() throws {
        let aimedSnip = Snip(content: "Has a card frame", origin: .quickEntry)
        let waitingSnip = Snip(content: "Not measured yet", origin: .quickEntry)
        var transfers = GatheringTransfers()
        transfers.begin(makeFlight(aimedSnip))
        transfers.begin(makeFlight(waitingSnip))
        let card = CGRect(x: 20, y: 600, width: 300, height: 72)

        XCTAssertNil(transfers.aimed(at: [:]))
        XCTAssertNil(transfers.aimed(at: [UUID(): card]))
        let aimed = try XCTUnwrap(transfers.aimed(at: [aimedSnip.id: card]))
        XCTAssertEqual(aimed.flights.map(\.id), transfers.flights.map(\.id))
        XCTAssertEqual(aimed.flights.first { $0.snip.id == aimedSnip.id }?.destination, card)
        XCTAssertNil(aimed.flights.first { $0.snip.id == waitingSnip.id }?.destination)
        XCTAssertNil(transfers.flights.first { $0.snip.id == aimedSnip.id }?.destination)
        XCTAssertEqual(aimed.departure(of: aimedSnip.id), transfers.departure(of: aimedSnip.id))
        XCTAssertNil(aimed.aimed(at: [aimedSnip.id: card]))
        let retargeted = try XCTUnwrap(aimed.aimed(at: [aimedSnip.id: card.offsetBy(dx: 0, dy: -40)]))
        XCTAssertEqual(
            retargeted.flights.first { $0.snip.id == aimedSnip.id }?.destination,
            card.offsetBy(dx: 0, dy: -40)
        )
    }

    func testCancellingTransfersClearsFlightsAndDepartures() {
        let snip = Snip(content: "Mid flight", origin: .quickEntry)
        var transfers = GatheringTransfers()
        transfers.begin(makeFlight(snip))

        transfers.cancelAll()

        XCTAssertTrue(transfers.flights.isEmpty)
        XCTAssertTrue(transfers.arrivingSnipIDs.isEmpty)
        XCTAssertFalse(transfers.isDeparting(snip.id))
    }

    private func makeFlight(_ snip: Snip) -> GatheringFlight {
        GatheringFlight(
            snip: snip, source: CGRect(x: 0, y: 200, width: 320, height: 64),
            sourceIsSelecting: true, destination: nil
        )
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
        await fulfillment(of: [requested], timeout: TestReadiness.timeout)
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
            await fulfillment(of: [requested], timeout: TestReadiness.timeout)
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
            await fulfillment(of: [requested], timeout: TestReadiness.timeout)
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
        await fulfillment(of: [moveStarted], timeout: TestReadiness.timeout)
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
        await fulfillment(of: [moveStarted], timeout: TestReadiness.timeout)
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
            await fulfillment(of: [requested], timeout: TestReadiness.timeout)
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
        model.selectSnips([newer.id])
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
