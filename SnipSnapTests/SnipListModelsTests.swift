import AppKit
import XCTest
import Foundation
import UniformTypeIdentifiers
@testable import SnipSnap

final class SnipListModelsTests: XCTestCase {
    func testListSnapshotCanKeepTheActiveListHeaderWhenItIsEmpty() {
        let list = SnipList(
            id: UUID(),
            name: "Agents",
            systemImage: "star",
            position: 1
        )
        let snapshot = SnipListSnapshot(
            visibleSnips: [],
            allSnips: [],
            lists: [list],
            selection: [],
            keepsEmptyListID: list.id
        )

        XCTAssertEqual(
            snapshot.groups,
            [SnipListGroup(listID: list.id, list: list.name, snips: [])]
        )
        XCTAssertTrue(snapshot.orderedVisibleIDs.isEmpty)
    }

    @MainActor
    func testDropGeometryIsInactiveOutsideAnActiveSnipDrag() {
        let controller = SnipListDragController()
        let payload = SnipDragPayload(ids: [UUID()], text: "Snip")

        XCTAssertFalse(controller.needsDropGeometry)

        controller.beginNativeDrag(payload)

        XCTAssertTrue(controller.needsDropGeometry)

        controller.endNativeDrag(
            payload,
            outcome: .cancelled,
            markDoneAfterExternalCopy: { _ in }
        )

        XCTAssertFalse(controller.needsDropGeometry)
    }

    @MainActor
    func testClipboardDropSessionEnablesGeometryBeforeItHasATarget() {
        let controller = SnipListDragController()

        XCTAssertFalse(controller.needsDropGeometry)

        controller.beginClipboardDropSession()

        XCTAssertTrue(controller.needsDropGeometry)

        controller.endClipboardDropSession()

        XCTAssertFalse(controller.needsDropGeometry)
    }

    func testDropSurfaceStateRejectsStaleExitTokens() throws {
        let listID = UUID()
        let firstSurface = SnipListDropSurface.entry(.snip(UUID()))
        let secondSurface = SnipListDropSurface.entry(.snip(UUID()))
        var state = SnipListDropSurfaceState()

        state.activate(listID: listID, surface: firstSurface)
        let firstExit = try XCTUnwrap(
            state.exitToken(listID: listID, surface: firstSurface)
        )

        state.activate(listID: listID, surface: secondSurface)

        XCTAssertFalse(state.owns(firstExit))
        XCTAssertNil(state.exitToken(listID: listID, surface: firstSurface))

        let secondExit = try XCTUnwrap(
            state.exitToken(listID: listID, surface: secondSurface)
        )
        XCTAssertTrue(state.owns(secondExit))

        state.activate(listID: listID, surface: secondSurface)
        XCTAssertFalse(state.owns(secondExit))
    }

    @MainActor
    func testMixedSnipDragUsesOneSnipVisualForItsFilePackage() {
        let image = URL(fileURLWithPath: "/tmp/preview.png")
        let payload = SnipDragPayload(
            ids: [UUID()],
            text: "Use this image",
            attachmentURLs: [image]
        )

        let package = SnipDragExportPackage(payload: payload)
        let snips = package.draggingItems(
            at: NSPoint(x: 100, y: 100),
            scale: 2,
            colorScheme: .light
        )

        XCTAssertEqual(snips.count, 3)
        XCTAssertGreaterThan(snips[0].draggingFrame.width, 0)
        XCTAssertEqual(snips[1].draggingFrame.size, NSSize(width: 1, height: 1))
        XCTAssertEqual(snips[1].imageComponentsProvider?().count, 0)
        XCTAssertEqual(snips[2].draggingFrame.size, NSSize(width: 1, height: 1))
        XCTAssertEqual(snips[2].imageComponentsProvider?().count, 0)
    }

    func testMixedSnipDragPublishesMarkdownThenEveryAttachment() throws {
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.md")
        let payload = SnipDragPayload(
            ids: [UUID()],
            text: "Use these files",
            attachmentURLs: [first, second]
        )

        let package = SnipDragExportPackage(payload: payload)
        let writers = package.pasteboardWriters()

        XCTAssertEqual(writers.count, 4)
        let provider = try XCTUnwrap(writers.first as? NSFilePromiseProvider)
        XCTAssertEqual(provider.fileType, UTType.data.identifier)
        XCTAssertEqual(
            writers.compactMap { ($0 as? NSURL) as URL? },
            [first, second]
        )
        let privateItem = try XCTUnwrap(writers.last as? NSPasteboardItem)
        XCTAssertNotNil(privateItem.data(forType: SnipDragExportPackage.privateType))
    }

    func testTextOnlySnipDragOffersPlainTextBeforeItsPrivatePayload() throws {
        let payload = SnipDragPayload(
            ids: [UUID()],
            text: "Start at the first character"
        )

        let writers = SnipDragExportPackage(payload: payload).pasteboardWriters()
        let snip = try XCTUnwrap(writers.first as? NSPasteboardItem)

        XCTAssertEqual(snip.types.first, .string)
        XCTAssertEqual(snip.string(forType: .string), payload.text)
    }

    func testMixedSnipDragWritesOnlyFilesToTheDragPasteboard() throws {
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.md")
        let payload = SnipDragPayload(
            ids: [UUID()],
            text: "Use these files",
            attachmentURLs: [first, second]
        )
        let writers = SnipDragExportPackage(payload: payload).pasteboardWriters()

        XCTAssertTrue(writers.first is NSFilePromiseProvider)
        XCTAssertEqual(
            writers.compactMap { ($0 as? NSURL) as URL? },
            [first, second]
        )
        XCTAssertEqual(
            (writers.last as? NSPasteboardItem)?.types,
            [SnipDragExportPackage.privateType]
        )
    }

    func testImageOnlySnipDragStillPublishesItsFile() throws {
        let image = URL(fileURLWithPath: "/tmp/image.png")
        let payload = SnipDragPayload(
            ids: [UUID()],
            text: "",
            attachmentURLs: [image]
        )

        let writers = SnipDragExportPackage(payload: payload).pasteboardWriters()

        XCTAssertEqual(writers.count, 2)
        XCTAssertEqual((writers.first as? NSURL) as URL?, image)
        XCTAssertEqual(
            (writers.last as? NSPasteboardItem)?.types,
            [SnipDragExportPackage.privateType]
        )
    }

    @MainActor
    func testMixedSnipDragWritesMarkdownOnAFilePromiseQueue() throws {
        let payload = SnipDragPayload(
            ids: [UUID()],
            text: "Keep this text",
            attachmentURLs: [URL(fileURLWithPath: "/tmp/image.png")]
        )
        let package = SnipDragExportPackage(payload: payload)
        let provider = try XCTUnwrap(
            package.pasteboardWriters().first as? NSFilePromiseProvider
        )
        let delegate = try XCTUnwrap(provider.delegate)
        let queue = try XCTUnwrap(delegate.operationQueue?(for: provider))

        XCTAssertFalse(queue === OperationQueue.main)
    }

    @MainActor
    func testMixedSnipPromiseKeepsItsDelegateAfterThePackageEnds() throws {
        let payload = SnipDragPayload(
            ids: [UUID()],
            text: "Keep this text",
            attachmentURLs: [URL(fileURLWithPath: "/tmp/image.png")]
        )
        let provider = try makeMixedSnipPromiseProvider(payload: payload)
        let delegate = try XCTUnwrap(provider.delegate)
        XCTAssertTrue((provider.userInfo as AnyObject) === (delegate as AnyObject))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Snip Snap Snip.md")
        var writeError: Error?

        delegate.filePromiseProvider(
            provider,
            writePromiseTo: destination
        ) { error in
            writeError = error
        }

        XCTAssertNil(writeError)
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            SnipDragExportPackage.markdown(for: payload)
        )
    }

    @MainActor
    private func makeMixedSnipPromiseProvider(
        payload: SnipDragPayload
    ) throws -> NSFilePromiseProvider {
        let package = SnipDragExportPackage(payload: payload)
        return try XCTUnwrap(
            package.pasteboardWriters().first as? NSFilePromiseProvider
        )
    }

    func testOnlySuccessfulExternalCopyMarksDraggedSnipsDone() {
        XCTAssertTrue(ExternalSnipDragCompletion.shouldMarkDone(after: .copy))
        XCTAssertFalse(ExternalSnipDragCompletion.shouldMarkDone(after: .move))
        XCTAssertFalse(ExternalSnipDragCompletion.shouldMarkDone(after: .cancel))
        XCTAssertFalse(ExternalSnipDragCompletion.shouldMarkDone(after: .forbidden))
    }

    func testPinnedHeaderGlassRequiresRealScrollMovement() {
        XCTAssertFalse(
            PinnedListHeaderGlass.isVisible(
                isPinned: true,
                hasScrolled: PinnedListHeaderGlass.hasScrolled(visibleOriginY: 0)
            )
        )
        XCTAssertTrue(
            PinnedListHeaderGlass.isVisible(
                isPinned: true,
                hasScrolled: PinnedListHeaderGlass.hasScrolled(visibleOriginY: 1)
            )
        )
        XCTAssertFalse(
            PinnedListHeaderGlass.isVisible(
                isPinned: false,
                hasScrolled: PinnedListHeaderGlass.hasScrolled(visibleOriginY: 1)
            )
        )
    }

    func testPinnedHeaderStateIgnoresDuplicateGeometryReports() {
        let listID = UUID()

        XCTAssertEqual(
            PinnedListHeaderGlass.updatedLists(
                [],
                listID: listID,
                isPinned: true
            ),
            [listID]
        )
        XCTAssertNil(
            PinnedListHeaderGlass.updatedLists(
                [listID],
                listID: listID,
                isPinned: true
            )
        )
        XCTAssertEqual(
            PinnedListHeaderGlass.updatedLists(
                [listID],
                listID: listID,
                isPinned: false
            ),
            []
        )
        XCTAssertNil(
            PinnedListHeaderGlass.updatedLists(
                [],
                listID: listID,
                isPinned: false
            )
        )
    }

    func testNewSnipRevealWaitsForTheAddedRowWhenTheListWasAtTheTop() {
        let existingID = UUID()
        let addedID = UUID()
        var state = AddedSnipRevealState()

        XCTAssertNil(
            state.record(
                snipID: addedID,
                wasAtTop: true,
                isVisibleInModel: true,
                visibleIDs: [existingID]
            )
        )
        XCTAssertEqual(
            state.nextDestination(visibleIDs: [addedID, existingID]),
            .scrollViewTop
        )
    }

    func testNewSnipRevealPreservesTheScrollPositionWhenAwayFromTheTop() {
        let addedID = UUID()
        var state = AddedSnipRevealState()

        XCTAssertNil(
            state.record(
                snipID: addedID,
                wasAtTop: false,
                isVisibleInModel: true,
                visibleIDs: [addedID]
            )
        )
        XCTAssertNil(state.nextDestination(visibleIDs: [addedID]))
    }

    func testNewSnipRevealDoesNotWaitForASnipHiddenByTheCurrentFilter() {
        let addedID = UUID()
        var state = AddedSnipRevealState()

        XCTAssertNil(
            state.record(
                snipID: addedID,
                wasAtTop: true,
                isVisibleInModel: false,
                visibleIDs: []
            )
        )
        XCTAssertNil(state.nextDestination(visibleIDs: [addedID]))
    }

    func testDisplaySourceLabelUsesStoredSourceOrCaptureOrigin() {
        let captured = Snip(
            content: "Captured",
            origin: .selection,
            source: SnipSource(
                applicationName: "TextEdit",
                windowTitle: "Draft"
            )
        )
        let quickEntry = Snip(content: "Typed", origin: .quickEntry)

        XCTAssertEqual(captured.displaySourceLabel, "TextEdit — Draft")
        XCTAssertEqual(quickEntry.displaySourceLabel, "Snip Snap — Quick Entry")
    }

    func testDoneSnipsSortAfterActiveSnipsInBothModes() {
        let olderActive = makeSnip(
            id: 1,
            createdAt: 100,
            list: "Review",
            manualPosition: 1
        )
        let newerDone = makeSnip(
            id: 2,
            createdAt: 200,
            list: "Review",
            manualPosition: 0,
            isDone: true
        )
        let newestActive = makeSnip(
            id: 3,
            createdAt: 300,
            list: "Review",
            manualPosition: -1
        )

        XCTAssertEqual(
            Snip.sorted([olderActive, newerDone, newestActive], by: .chronological)
                .map(\.id),
            [newestActive.id, olderActive.id, newerDone.id]
        )
        XCTAssertEqual(
            Snip.sorted([olderActive, newerDone, newestActive], by: .manual)
                .map(\.id),
            [newestActive.id, olderActive.id, newerDone.id]
        )
    }

    func testCopyFormattingUsesChronologicalOrderAndSourceContext() {
        let old = Snip(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            requestID: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            content: "First thought",
            origin: .quickEntry
        )
        let new = Snip(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            requestID: UUID(),
            createdAt: Date(timeIntervalSince1970: 200),
            content: "Second snippet",
            origin: .selection,
            source: SnipSource(
                applicationName: "Safari",
                windowTitle: "Docs",
                url: "https://example.com/docs"
            )
        )

        XCTAssertEqual(
            SnipFormatter.format(snips: [new, old]),
            "First thought\n\n---\n\nSecond snippet\nSource: Safari — Docs\nURL: https://example.com/docs"
        )
        XCTAssertEqual(SnipFormatter.formatForClipboard(snips: [old]), "First thought")
        XCTAssertEqual(
            SnipFormatter.formatForClipboard(snips: [new, old]),
            "- First thought\n- Second snippet\n  Source: Safari — Docs\n  URL: https://example.com/docs"
        )
    }

    func testSnipDragPayloadUsesVisibleOrderAndPlainTextForOneSnip() {
        let first = Snip(
            content: "Shown first",
            origin: .selection,
            source: SnipSource(
                applicationName: "Safari",
                windowTitle: "Reference",
                url: "https://example.com"
            )
        )
        let second = Snip(content: "Shown second", origin: .quickEntry)

        XCTAssertEqual(
            SnipDragPayload.make(snips: [first]),
            SnipDragPayload(
                ids: [first.id],
                text: "Shown first",
                previewSourceLabel: "Safari — Reference"
            )
        )
        XCTAssertEqual(
            SnipDragPayload.make(snips: [second, first]),
            SnipDragPayload(
                ids: [second.id, first.id],
                text: "Shown second\n\n---\n\nShown first\nSource: Safari — Reference\nURL: https://example.com",
                previewSourceLabel: "2 snips"
            )
        )
    }

    func testSnipDragListSlotsKeepOriginsUntilAnExactDestinationExists() {
        let first = UUID()
        let moving = UUID()
        let last = UUID()
        let snipIDs = [first, moving, last]

        XCTAssertEqual(
            SnipDragListLayout.slots(
                snipIDs: snipIDs,
                draggingIDs: [moving],
                destinationBeforeID: nil,
                showsDestinationGap: false,
                preservesOriginGaps: true
            ),
            [.snip(first), .originGap(moving), .snip(last)]
        )

        XCTAssertEqual(
            SnipDragListLayout.slots(
                snipIDs: snipIDs,
                draggingIDs: [moving],
                destinationBeforeID: last,
                showsDestinationGap: true,
                preservesOriginGaps: false
            ),
            [.snip(first), .destinationGap, .snip(last)]
        )

        XCTAssertEqual(
            SnipDragListLayout.slots(
                snipIDs: snipIDs,
                draggingIDs: [moving],
                destinationBeforeID: nil,
                showsDestinationGap: false,
                preservesOriginGaps: false
            ),
            [.snip(first), .snip(last)]
        )
    }

    func testSnipDragListSlotsKeepEachNoncontiguousOrigin() {
        let ids = (0..<4).map { _ in UUID() }

        XCTAssertEqual(
            SnipDragListLayout.slots(
                snipIDs: ids,
                draggingIDs: [ids[0], ids[2]],
                destinationBeforeID: nil,
                showsDestinationGap: false,
                preservesOriginGaps: true
            ),
            [
                .originGap(ids[0]),
                .snip(ids[1]),
                .originGap(ids[2]),
                .snip(ids[3])
            ]
        )
    }

    func testDropPlannerAllowsPreciseSameListPlacementWithoutFilters() {
        let first = makeSnip(id: 1, createdAt: 300, list: "Review", manualPosition: 0)
        let moving = makeSnip(id: 2, createdAt: 200, list: "Review", manualPosition: 1)
        let last = makeSnip(id: 3, createdAt: 100, list: "Review", manualPosition: 2)

        XCTAssertEqual(
            SnipDropPlanner.plan(
                payloadIDs: [moving.id],
                snips: [first, moving, last],
                targetListID: listID("Review"),
                pointerBeforeID: last.id,
                isOverHeading: false,
                sortMode: .manual,
                filtersActive: false
            ),
            SnipDropPlan(
                listID: listID("Review"),
                beforeID: last.id,
                behavior: .exact,
                showsInsertion: true
            )
        )
    }

    func testDropPlannerBlocksFilteredSameListPlacement() {
        let moving = makeSnip(id: 1, createdAt: 200, list: "Review", manualPosition: 0)
        let other = makeSnip(id: 2, createdAt: 100, list: "Review", manualPosition: 1)

        XCTAssertNil(
            SnipDropPlanner.plan(
                payloadIDs: [moving.id],
                snips: [moving, other],
                targetListID: listID("Review"),
                pointerBeforeID: other.id,
                isOverHeading: false,
                sortMode: .manual,
                filtersActive: true
            )
        )
    }

    func testDropPlannerSendsFilteredManualListMoveToTop() {
        let moving = makeSnip(id: 1, createdAt: 100, list: "Inbox", manualPosition: 0)
        let first = makeSnip(id: 2, createdAt: 200, list: "Review", manualPosition: 0)
        let last = makeSnip(id: 3, createdAt: 300, list: "Review", manualPosition: 1)

        XCTAssertEqual(
            SnipDropPlanner.plan(
                payloadIDs: [moving.id],
                snips: [moving, last, first],
                targetListID: listID("Review"),
                pointerBeforeID: last.id,
                isOverHeading: false,
                sortMode: .manual,
                filtersActive: true
            ),
            SnipDropPlan(
                listID: listID("Review"),
                beforeID: first.id,
                behavior: .listTop,
                showsInsertion: false
            )
        )
    }

    func testDropPlannerShowsTheChronologicalDestinationForOneSnip() {
        let newest = makeSnip(id: 1, createdAt: 300, list: "Review", manualPosition: 0)
        let moving = makeSnip(id: 2, createdAt: 200, list: "Inbox", manualPosition: 0)
        let oldest = makeSnip(id: 3, createdAt: 100, list: "Review", manualPosition: 1)

        XCTAssertEqual(
            SnipDropPlanner.plan(
                payloadIDs: [moving.id],
                snips: [oldest, moving, newest],
                targetListID: listID("Review"),
                pointerBeforeID: nil,
                isOverHeading: false,
                sortMode: .chronological,
                filtersActive: false
            ),
            SnipDropPlan(
                listID: listID("Review"),
                beforeID: oldest.id,
                behavior: .chronological,
                showsInsertion: true
            )
        )
    }

    func testDropPlannerOmitsPreciseInsertionForChronologicalBatchListMove() {
        let firstMoving = makeSnip(id: 1, createdAt: 250, list: "Inbox", manualPosition: 0)
        let secondMoving = makeSnip(id: 2, createdAt: 150, list: "Inbox", manualPosition: 1)
        let target = makeSnip(id: 3, createdAt: 200, list: "Review", manualPosition: 0)

        XCTAssertEqual(
            SnipDropPlanner.plan(
                payloadIDs: [firstMoving.id, secondMoving.id],
                snips: [firstMoving, target, secondMoving],
                targetListID: listID("Review"),
                pointerBeforeID: target.id,
                isOverHeading: false,
                sortMode: .chronological,
                filtersActive: false
            ),
            SnipDropPlan(
                listID: listID("Review"),
                beforeID: nil,
                behavior: .chronological,
                showsInsertion: false
            )
        )
    }

    func testFilteringSearchesContentAndSourceAndHonorsCompletionFilter() {
        let done = Snip(
            content: "Follow up tomorrow",
            origin: .quickEntry,
            isDone: true
        )
        let safari = Snip(
            content: "An unrelated excerpt",
            origin: .selection,
            source: SnipSource(
                applicationName: "Safari",
                windowTitle: "Swift guide",
                url: nil
            )
        )

        XCTAssertEqual(
            SnipFilter.apply(
                snips: [done, safari],
                query: "swift",
                completionFilter: .all
            ),
            [safari]
        )
        XCTAssertEqual(
            SnipFilter.apply(
                snips: [done, safari],
                query: "",
                completionFilter: .done
            ),
            [done]
        )
        XCTAssertEqual(
            SnipFilter.apply(
                snips: [done, safari],
                query: "",
                completionFilter: .notDone
            ),
            [safari]
        )
        XCTAssertTrue(
            SnipFilter.apply(
                snips: [done, safari],
                query: "swift",
                completionFilter: .done
            ).isEmpty
        )
    }

    func testLargeSnipFilteringKeepsExactMatches() {
        let snips = (0..<2_500).map { index in
            Snip(
                content: index.isMultiple(of: 250) ? "Needle \(index)" : "Snip \(index)",
                origin: .quickEntry,
                listID: index.isMultiple(of: 2) ? SnipList.inboxID : listID("Later")
            )
        }
        let matches = SnipFilter.apply(
            snips: snips,
            query: "needle",
            completionFilter: .all
        )
        XCTAssertEqual(matches.count, 10)
    }

    func testSnipSelectionPlainClickDoesNotStartAndClearsBatchSelection() {
        let first = UUID()
        let second = UUID()
        let orderedIDs = [first, second]

        let untouched = SnipSelection.click(
            first,
            orderedIDs: orderedIDs,
            selection: [],
            anchor: nil,
            focus: nil,
            modifiers: []
        )
        XCTAssertTrue(untouched.selection.isEmpty)
        XCTAssertNil(untouched.anchor)
        XCTAssertNil(untouched.focus)

        let cleared = SnipSelection.click(
            second,
            orderedIDs: orderedIDs,
            selection: [first],
            anchor: first,
            focus: first,
            modifiers: []
        )
        XCTAssertTrue(cleared.selection.isEmpty)
        XCTAssertNil(cleared.anchor)
        XCTAssertNil(cleared.focus)
    }

    func testSnipSelectionCommandClickStartsThenTogglesBatchSelection() {
        let first = UUID()
        let second = UUID()
        let orderedIDs = [first, second]

        let started = SnipSelection.click(
            first,
            orderedIDs: orderedIDs,
            selection: [],
            anchor: nil,
            focus: nil,
            modifiers: .command
        )
        XCTAssertEqual(started.selection, [first])
        XCTAssertEqual(started.anchor, first)
        XCTAssertEqual(started.focus, first)

        let added = SnipSelection.click(
            second,
            orderedIDs: orderedIDs,
            selection: started.selection,
            anchor: started.anchor,
            focus: started.focus,
            modifiers: .command
        )
        XCTAssertEqual(added.selection, [first, second])
        XCTAssertEqual(added.anchor, second)
        XCTAssertEqual(added.focus, second)

        let removed = SnipSelection.click(
            first,
            orderedIDs: orderedIDs,
            selection: added.selection,
            anchor: added.anchor,
            focus: added.focus,
            modifiers: .command
        )
        XCTAssertEqual(removed.selection, [second])
    }

    func testSnipSelectionShiftClickUsesVisibleCommandClickAnchor() {
        let ids = (0..<4).map { _ in UUID() }
        let shiftWithoutSelection = SnipSelection.click(
            ids[3],
            orderedIDs: ids,
            selection: [],
            anchor: nil,
            focus: nil,
            modifiers: .shift
        )
        XCTAssertTrue(shiftWithoutSelection.selection.isEmpty)
        XCTAssertNil(shiftWithoutSelection.anchor)
        XCTAssertNil(shiftWithoutSelection.focus)

        let start = SnipSelection.click(
            ids[1],
            orderedIDs: ids,
            selection: [],
            anchor: nil,
            focus: nil,
            modifiers: .command
        )

        let clickedRange = SnipSelection.click(
            ids[3],
            orderedIDs: ids,
            selection: start.selection,
            anchor: start.anchor,
            focus: start.focus,
            modifiers: .shift
        )
        XCTAssertEqual(clickedRange.selection, Set(ids[1...3]))
        XCTAssertEqual(clickedRange.anchor, ids[1])
        XCTAssertEqual(clickedRange.focus, ids[3])

        let staleAnchor = SnipSelection.click(
            ids[3],
            orderedIDs: ids,
            selection: [ids[2]],
            anchor: ids[1],
            focus: ids[1],
            modifiers: .shift
        )
        XCTAssertEqual(staleAnchor.selection, [ids[2]])
        XCTAssertEqual(staleAnchor.anchor, ids[1])
        XCTAssertEqual(staleAnchor.focus, ids[1])

        let contracted = SnipSelection.move(
            by: -1,
            orderedIDs: ids,
            selection: clickedRange.selection,
            anchor: clickedRange.anchor,
            focus: clickedRange.focus,
            extending: true
        )
        XCTAssertEqual(contracted.selection, Set(ids[1...2]))
        XCTAssertEqual(contracted.anchor, ids[1])
        XCTAssertEqual(contracted.focus, ids[2])
    }

    func testSnipSelectionArrowStartsAtTheNearestListEdge() {
        let ids = (0..<3).map { _ in UUID() }

        let down = SnipSelection.move(
            by: 1,
            orderedIDs: ids,
            selection: [],
            anchor: nil,
            focus: nil,
            extending: false
        )
        XCTAssertEqual(down.selection, [ids[0]])

        let up = SnipSelection.move(
            by: -1,
            orderedIDs: ids,
            selection: [],
            anchor: nil,
            focus: nil,
            extending: false
        )
        XCTAssertEqual(up.selection, [ids[2]])
    }

    func testSnipSelectionArrowContinuesFromAnExternalSelection() {
        let ids = (0..<3).map { _ in UUID() }

        let moved = SnipSelection.move(
            by: 1,
            orderedIDs: ids,
            selection: [ids[1]],
            anchor: nil,
            focus: nil,
            extending: false
        )

        XCTAssertEqual(moved.selection, [ids[2]])
        XCTAssertEqual(moved.anchor, ids[2])
        XCTAssertEqual(moved.focus, ids[2])

        let staleFocus = SnipSelection.move(
            by: 1,
            orderedIDs: ids,
            selection: [ids[0]],
            anchor: ids[2],
            focus: ids[2],
            extending: false
        )
        XCTAssertEqual(staleFocus.selection, [ids[1]])
        XCTAssertEqual(staleFocus.anchor, ids[1])
        XCTAssertEqual(staleFocus.focus, ids[1])
    }

    func testListSnapshotBuildsGroupsAndSelectedPayloadOnceInListOrder() {
        let inboxSnip = makeSnip(
            id: 1,
            createdAt: 100,
            list: "Inbox",
            manualPosition: 0
        )
        let firstReview = makeSnip(id: 2, createdAt: 200, list: "Review", manualPosition: 0)
        let secondReview = makeSnip(id: 3, createdAt: 300, list: "Review", manualPosition: 1)
        let snapshot = SnipListSnapshot(
            visibleSnips: [secondReview, inboxSnip, firstReview],
            allSnips: [secondReview, inboxSnip, firstReview],
            lists: [
                .inbox,
                SnipList(id: listID("Review"), name: "Review", systemImage: "star", position: 1)
            ],
            selection: [secondReview.id, inboxSnip.id]
        )

        XCTAssertEqual(snapshot.groups.map(\.list), ["Inbox", "Review"])
        XCTAssertEqual(snapshot.orderedVisibleIDs, [inboxSnip.id, secondReview.id, firstReview.id])
        XCTAssertEqual(snapshot.dragPayload(for: secondReview).ids, [inboxSnip.id, secondReview.id])
        XCTAssertEqual(snapshot.dragPayload(for: firstReview).ids, [firstReview.id])
    }

    @MainActor
    func testListGeometrySupportsDropPlacementWithoutWindowInputRules() {
        let first = makeSnip(id: 1, createdAt: 100, list: "Review", manualPosition: 0)
        let second = makeSnip(id: 2, createdAt: 200, list: "Review", manualPosition: 1)
        let geometry = SnipListGeometry()
        geometry.record(CGRect(x: 10, y: 120, width: 200, height: 40), for: .row(first.id))
        geometry.record(CGRect(x: 10, y: 180, width: 200, height: 60), for: .row(second.id))
        geometry.record(
            CGRect(x: 10, y: 80, width: 200, height: 30),
            for: .heading(listID("Review"))
        )
        geometry.record(
            CGRect(x: 10, y: 110, width: 200, height: 40),
            for: .dropSurface(.snip(first.id))
        )
        geometry.record(
            CGRect(x: 10, y: 120, width: 200, height: 40),
            for: .entry(.snip(first.id))
        )
        geometry.record(
            CGRect(x: 10, y: 180, width: 200, height: 60),
            for: .entry(.snip(second.id))
        )
        geometry.record(
            CGRect(x: 10, y: 250, width: 200, height: 16),
            for: .listFooter(listID("Review"))
        )
        geometry.updateScroll(
            .init(visibleOrigin: CGPoint(x: 0, y: 100), contentHeight: 500, viewportHeight: 200)
        )

        XCTAssertEqual(
            geometry.contentPoint(fromViewportPoint: CGPoint(x: 20, y: 30)),
            CGPoint(x: 20, y: 130)
        )
        XCTAssertEqual(
            geometry.viewportPoint(fromContentPoint: CGPoint(x: 20, y: 130)),
            CGPoint(x: 20, y: 30)
        )
        XCTAssertEqual(
            geometry.insertionID(atContentPoint: CGPoint(x: 20, y: 170), among: [first, second]),
            second.id
        )
        XCTAssertEqual(geometry.dragGapHeight(for: [first.id, second.id]), 108)
        XCTAssertEqual(
            geometry.contentPoint(
                fromLocalPoint: CGPoint(x: 5, y: 6),
                in: .heading(listID("Review"))
            ),
            CGPoint(x: 15, y: 86)
        )
        XCTAssertEqual(
            geometry.contentPoint(
                fromLocalPoint: CGPoint(x: 5, y: 6),
                in: .dropSurface(.snip(first.id))
            ),
            CGPoint(x: 15, y: 116)
        )
        XCTAssertEqual(
            geometry.listBodyFrame(
                listID: listID("Review"),
                rowIDs: [first.id, second.id],
                entryIDs: [.snip(first.id), .snip(second.id)]
            ),
            CGRect(x: 10, y: 120, width: 200, height: 120)
        )
        XCTAssertTrue(
            geometry.hasPlacementFrames(
                in: listID("Review"),
                among: [first, second]
            )
        )

        geometry.updateScroll(
            .init(visibleOrigin: CGPoint(x: 0, y: 140), contentHeight: 500, viewportHeight: 200)
        )
        XCTAssertEqual(
            geometry.contentPoint(fromViewportPoint: CGPoint(x: 20, y: 10)),
            CGPoint(x: 20, y: 150)
        )

        geometry.remove(.row(first.id))
        XCTAssertNil(geometry.frame(for: .row(first.id)))

        geometry.record(
            CGRect(x: 10, y: 180, width: 200, height: 60),
            for: .dropSurface(.snip(second.id))
        )
        geometry.record(
            CGRect(x: 10, y: 180, width: 200, height: 60),
            for: .entry(.originGap(second.id))
        )

        geometry.retainSnips([first.id])

        XCTAssertNil(geometry.frame(for: .row(second.id)))
        XCTAssertNil(geometry.frame(for: .entry(.snip(second.id))))
        XCTAssertNil(geometry.frame(for: .entry(.originGap(second.id))))
        XCTAssertNil(geometry.frame(for: .dropSurface(.snip(second.id))))
    }

    @MainActor
    func testListGeometryUsesHeaderForAnEmptySnipListDropSurface() {
        let geometry = SnipListGeometry()
        let listID = listID("Empty")
        geometry.record(
            CGRect(x: 10, y: 80, width: 200, height: 30),
            for: .heading(listID)
        )

        XCTAssertTrue(geometry.hasPlacementFrames(in: listID, among: []))
        XCTAssertNil(
            geometry.listBodyFrame(
                listID: listID,
                rowIDs: [],
                entryIDs: []
            )
        )
    }

    @MainActor
    func testListGeometryIncludesSyntheticEntriesInListHighlight() {
        let geometry = SnipListGeometry()
        let listID = listID("Review")
        let gapID = SnipListEntryID.destinationGap(listID)
        geometry.record(
            CGRect(x: 10, y: 80, width: 200, height: 72),
            for: .entry(gapID)
        )

        XCTAssertEqual(
            geometry.listBodyFrame(
                listID: listID,
                rowIDs: [],
                entryIDs: [gapID]
            ),
            CGRect(x: 10, y: 80, width: 200, height: 72)
        )
    }

    private func makeSnip(
        id: Int,
        createdAt: TimeInterval,
        list: String,
        manualPosition: Int64,
        isDone: Bool = false
    ) -> Snip {
        Snip(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            requestID: UUID(),
            createdAt: Date(timeIntervalSince1970: createdAt),
            content: "Card \(id)",
            origin: .quickEntry,
            listID: listID(list),
            isDone: isDone,
            manualPosition: manualPosition
        )
    }

    private func listID(_ name: String) -> UUID {
        if name == "Inbox" { return SnipList.inboxID }
        let suffix: String
        switch name {
        case "Review": suffix = "000000000101"
        case "Later": suffix = "000000000102"
        default: suffix = "000000000103"
        }
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}
