import AppKit
import XCTest
import Foundation
import UniformTypeIdentifiers
@testable import SnipSnap

final class InboxModelsTests: XCTestCase {
    func testListSnapshotCanKeepTheActiveSectionHeaderWhenItIsEmpty() {
        let section = SnipSnapSection(
            id: UUID(),
            name: "Agents",
            systemImage: "star",
            position: 1
        )
        let snapshot = InboxListSnapshot(
            visibleItems: [],
            allItems: [],
            sections: [section],
            selection: [],
            keepsEmptySectionID: section.id
        )

        XCTAssertEqual(
            snapshot.groups,
            [InboxItemGroup(sectionID: section.id, section: section.name, items: [])]
        )
        XCTAssertTrue(snapshot.orderedVisibleIDs.isEmpty)
    }

    @MainActor
    func testDropGeometryIsInactiveOutsideAnActiveClipDrag() {
        let controller = InboxDragController()
        let payload = ClipDragPayload(ids: [UUID()], text: "Clip")

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
        let controller = InboxDragController()

        XCTAssertFalse(controller.needsDropGeometry)

        controller.beginClipboardDropSession()

        XCTAssertTrue(controller.needsDropGeometry)

        controller.endClipboardDropSession()

        XCTAssertFalse(controller.needsDropGeometry)
    }

    func testDropSurfaceStateRejectsStaleExitTokens() throws {
        let sectionID = UUID()
        let firstSurface = SectionDropSurface.entry(.item(UUID()))
        let secondSurface = SectionDropSurface.entry(.item(UUID()))
        var state = SectionDropSurfaceState()

        state.activate(sectionID: sectionID, surface: firstSurface)
        let firstExit = try XCTUnwrap(
            state.exitToken(sectionID: sectionID, surface: firstSurface)
        )

        state.activate(sectionID: sectionID, surface: secondSurface)

        XCTAssertFalse(state.owns(firstExit))
        XCTAssertNil(state.exitToken(sectionID: sectionID, surface: firstSurface))

        let secondExit = try XCTUnwrap(
            state.exitToken(sectionID: sectionID, surface: secondSurface)
        )
        XCTAssertTrue(state.owns(secondExit))

        state.activate(sectionID: sectionID, surface: secondSurface)
        XCTAssertFalse(state.owns(secondExit))
    }

    @MainActor
    func testMixedClipDragUsesOneClipVisualForItsFilePackage() {
        let image = URL(fileURLWithPath: "/tmp/preview.png")
        let payload = ClipDragPayload(
            ids: [UUID()],
            text: "Use this image",
            attachmentURLs: [image]
        )

        let package = ClipDragExportPackage(payload: payload)
        let items = package.draggingItems(
            at: NSPoint(x: 100, y: 100),
            scale: 2,
            colorScheme: .light
        )

        XCTAssertEqual(items.count, 3)
        XCTAssertGreaterThan(items[0].draggingFrame.width, 0)
        XCTAssertEqual(items[1].draggingFrame.size, NSSize(width: 1, height: 1))
        XCTAssertEqual(items[1].imageComponentsProvider?().count, 0)
        XCTAssertEqual(items[2].draggingFrame.size, NSSize(width: 1, height: 1))
        XCTAssertEqual(items[2].imageComponentsProvider?().count, 0)
    }

    func testMixedClipDragPublishesMarkdownThenEveryAttachment() throws {
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.md")
        let payload = ClipDragPayload(
            ids: [UUID()],
            text: "Use these files",
            attachmentURLs: [first, second]
        )

        let package = ClipDragExportPackage(payload: payload)
        let writers = package.pasteboardWriters()

        XCTAssertEqual(writers.count, 4)
        let provider = try XCTUnwrap(writers.first as? NSFilePromiseProvider)
        XCTAssertEqual(provider.fileType, UTType.data.identifier)
        XCTAssertEqual(
            writers.compactMap { ($0 as? NSURL) as URL? },
            [first, second]
        )
        let privateItem = try XCTUnwrap(writers.last as? NSPasteboardItem)
        XCTAssertNotNil(privateItem.data(forType: ClipDragExportPackage.privateType))
    }

    func testTextOnlyClipDragOffersPlainTextBeforeItsPrivatePayload() throws {
        let payload = ClipDragPayload(
            ids: [UUID()],
            text: "Start at the first character"
        )

        let writers = ClipDragExportPackage(payload: payload).pasteboardWriters()
        let item = try XCTUnwrap(writers.first as? NSPasteboardItem)

        XCTAssertEqual(item.types.first, .string)
        XCTAssertEqual(item.string(forType: .string), payload.text)
    }

    func testMixedClipDragWritesOnlyFilesToTheDragPasteboard() throws {
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.md")
        let payload = ClipDragPayload(
            ids: [UUID()],
            text: "Use these files",
            attachmentURLs: [first, second]
        )
        let writers = ClipDragExportPackage(payload: payload).pasteboardWriters()

        XCTAssertTrue(writers.first is NSFilePromiseProvider)
        XCTAssertEqual(
            writers.compactMap { ($0 as? NSURL) as URL? },
            [first, second]
        )
        XCTAssertEqual(
            (writers.last as? NSPasteboardItem)?.types,
            [ClipDragExportPackage.privateType]
        )
    }

    func testImageOnlyClipDragStillPublishesItsFile() throws {
        let image = URL(fileURLWithPath: "/tmp/image.png")
        let payload = ClipDragPayload(
            ids: [UUID()],
            text: "",
            attachmentURLs: [image]
        )

        let writers = ClipDragExportPackage(payload: payload).pasteboardWriters()

        XCTAssertEqual(writers.count, 2)
        XCTAssertEqual((writers.first as? NSURL) as URL?, image)
        XCTAssertEqual(
            (writers.last as? NSPasteboardItem)?.types,
            [ClipDragExportPackage.privateType]
        )
    }

    @MainActor
    func testMixedClipDragWritesMarkdownOnAFilePromiseQueue() throws {
        let payload = ClipDragPayload(
            ids: [UUID()],
            text: "Keep this text",
            attachmentURLs: [URL(fileURLWithPath: "/tmp/image.png")]
        )
        let package = ClipDragExportPackage(payload: payload)
        let provider = try XCTUnwrap(
            package.pasteboardWriters().first as? NSFilePromiseProvider
        )
        let delegate = try XCTUnwrap(provider.delegate)
        let queue = try XCTUnwrap(delegate.operationQueue?(for: provider))

        XCTAssertFalse(queue === OperationQueue.main)
    }

    @MainActor
    func testMixedClipPromiseKeepsItsDelegateAfterThePackageEnds() throws {
        let payload = ClipDragPayload(
            ids: [UUID()],
            text: "Keep this text",
            attachmentURLs: [URL(fileURLWithPath: "/tmp/image.png")]
        )
        let provider = try makeMixedClipPromiseProvider(payload: payload)
        let delegate = try XCTUnwrap(provider.delegate)
        XCTAssertTrue((provider.userInfo as AnyObject) === (delegate as AnyObject))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Snip Snap Clip.md")
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
            ClipDragExportPackage.markdown(for: payload)
        )
    }

    @MainActor
    private func makeMixedClipPromiseProvider(
        payload: ClipDragPayload
    ) throws -> NSFilePromiseProvider {
        let package = ClipDragExportPackage(payload: payload)
        return try XCTUnwrap(
            package.pasteboardWriters().first as? NSFilePromiseProvider
        )
    }

    func testOnlySuccessfulExternalCopyMarksDraggedClipsDone() {
        XCTAssertTrue(ExternalClipDragCompletion.shouldMarkDone(after: .copy))
        XCTAssertFalse(ExternalClipDragCompletion.shouldMarkDone(after: .move))
        XCTAssertFalse(ExternalClipDragCompletion.shouldMarkDone(after: .cancel))
        XCTAssertFalse(ExternalClipDragCompletion.shouldMarkDone(after: .forbidden))
    }

    func testPinnedHeaderGlassRequiresRealScrollMovement() {
        XCTAssertFalse(
            InboxPinnedHeaderGlass.isVisible(
                isPinned: true,
                hasScrolled: InboxPinnedHeaderGlass.hasScrolled(visibleOriginY: 0)
            )
        )
        XCTAssertTrue(
            InboxPinnedHeaderGlass.isVisible(
                isPinned: true,
                hasScrolled: InboxPinnedHeaderGlass.hasScrolled(visibleOriginY: 1)
            )
        )
        XCTAssertFalse(
            InboxPinnedHeaderGlass.isVisible(
                isPinned: false,
                hasScrolled: InboxPinnedHeaderGlass.hasScrolled(visibleOriginY: 1)
            )
        )
    }

    func testPinnedHeaderStateIgnoresDuplicateGeometryReports() {
        let sectionID = UUID()

        XCTAssertEqual(
            InboxPinnedHeaderGlass.updatedSections(
                [],
                sectionID: sectionID,
                isPinned: true
            ),
            [sectionID]
        )
        XCTAssertNil(
            InboxPinnedHeaderGlass.updatedSections(
                [sectionID],
                sectionID: sectionID,
                isPinned: true
            )
        )
        XCTAssertEqual(
            InboxPinnedHeaderGlass.updatedSections(
                [sectionID],
                sectionID: sectionID,
                isPinned: false
            ),
            []
        )
        XCTAssertNil(
            InboxPinnedHeaderGlass.updatedSections(
                [],
                sectionID: sectionID,
                isPinned: false
            )
        )
    }

    func testNewClipRevealWaitsForTheAddedRowWhenTheListWasAtTheTop() {
        let existingID = UUID()
        let addedID = UUID()
        var state = InboxAddedClipRevealState()

        XCTAssertNil(
            state.record(
                clipID: addedID,
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

    func testNewClipRevealPreservesTheScrollPositionWhenAwayFromTheTop() {
        let addedID = UUID()
        var state = InboxAddedClipRevealState()

        XCTAssertNil(
            state.record(
                clipID: addedID,
                wasAtTop: false,
                isVisibleInModel: true,
                visibleIDs: [addedID]
            )
        )
        XCTAssertNil(state.nextDestination(visibleIDs: [addedID]))
    }

    func testNewClipRevealDoesNotWaitForAClipHiddenByTheCurrentFilter() {
        let addedID = UUID()
        var state = InboxAddedClipRevealState()

        XCTAssertNil(
            state.record(
                clipID: addedID,
                wasAtTop: true,
                isVisibleInModel: false,
                visibleIDs: []
            )
        )
        XCTAssertNil(state.nextDestination(visibleIDs: [addedID]))
    }

    func testDisplaySourceLabelUsesStoredSourceOrCaptureOrigin() {
        let captured = CaptureItem(
            content: "Captured",
            origin: .selection,
            source: CaptureSource(
                applicationName: "TextEdit",
                windowTitle: "Draft"
            )
        )
        let quickEntry = CaptureItem(content: "Typed", origin: .quickEntry)

        XCTAssertEqual(captured.displaySourceLabel, "TextEdit — Draft")
        XCTAssertEqual(quickEntry.displaySourceLabel, "Snip Snap — Quick Entry")
    }

    func testDoneClipsSortAfterActiveClipsInBothModes() {
        let olderActive = dropItem(
            id: 1,
            createdAt: 100,
            section: "Review",
            manualPosition: 1
        )
        let newerDone = dropItem(
            id: 2,
            createdAt: 200,
            section: "Review",
            manualPosition: 0,
            isDone: true
        )
        let newestActive = dropItem(
            id: 3,
            createdAt: 300,
            section: "Review",
            manualPosition: -1
        )

        XCTAssertEqual(
            CaptureItem.sorted([olderActive, newerDone, newestActive], by: .chronological)
                .map(\.id),
            [newestActive.id, olderActive.id, newerDone.id]
        )
        XCTAssertEqual(
            CaptureItem.sorted([olderActive, newerDone, newestActive], by: .manual)
                .map(\.id),
            [newestActive.id, olderActive.id, newerDone.id]
        )
    }

    func testCopyFormattingUsesChronologicalOrderAndSourceContext() {
        let old = CaptureItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            requestID: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            content: "First thought",
            origin: .quickEntry
        )
        let new = CaptureItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            requestID: UUID(),
            createdAt: Date(timeIntervalSince1970: 200),
            content: "Second snippet",
            origin: .selection,
            source: CaptureSource(
                applicationName: "Safari",
                windowTitle: "Docs",
                url: "https://example.com/docs"
            )
        )

        XCTAssertEqual(
            CopyFormatter.format(items: [new, old]),
            "First thought\n\n---\n\nSecond snippet\nSource: Safari — Docs\nURL: https://example.com/docs"
        )
        XCTAssertEqual(CopyFormatter.formatForClipboard(items: [old]), "First thought")
        XCTAssertEqual(
            CopyFormatter.formatForClipboard(items: [new, old]),
            "- First thought\n- Second snippet\n  Source: Safari — Docs\n  URL: https://example.com/docs"
        )
    }

    func testClipDragPayloadUsesVisibleOrderAndPlainTextForOneClip() {
        let first = CaptureItem(
            content: "Shown first",
            origin: .selection,
            source: CaptureSource(
                applicationName: "Safari",
                windowTitle: "Reference",
                url: "https://example.com"
            )
        )
        let second = CaptureItem(content: "Shown second", origin: .quickEntry)

        XCTAssertEqual(
            ClipDragPayload.make(items: [first]),
            ClipDragPayload(
                ids: [first.id],
                text: "Shown first",
                previewSourceLabel: "Safari — Reference"
            )
        )
        XCTAssertEqual(
            ClipDragPayload.make(items: [second, first]),
            ClipDragPayload(
                ids: [second.id, first.id],
                text: "Shown second\n\n---\n\nShown first\nSource: Safari — Reference\nURL: https://example.com",
                previewSourceLabel: "2 clips"
            )
        )
    }

    func testClipDragListSlotsKeepOriginsUntilAnExactDestinationExists() {
        let first = UUID()
        let moving = UUID()
        let last = UUID()
        let itemIDs = [first, moving, last]

        XCTAssertEqual(
            ClipDragListLayout.slots(
                itemIDs: itemIDs,
                draggingIDs: [moving],
                destinationBeforeID: nil,
                showsDestinationGap: false,
                preservesOriginGaps: true
            ),
            [.item(first), .originGap(moving), .item(last)]
        )

        XCTAssertEqual(
            ClipDragListLayout.slots(
                itemIDs: itemIDs,
                draggingIDs: [moving],
                destinationBeforeID: last,
                showsDestinationGap: true,
                preservesOriginGaps: false
            ),
            [.item(first), .destinationGap, .item(last)]
        )

        XCTAssertEqual(
            ClipDragListLayout.slots(
                itemIDs: itemIDs,
                draggingIDs: [moving],
                destinationBeforeID: nil,
                showsDestinationGap: false,
                preservesOriginGaps: false
            ),
            [.item(first), .item(last)]
        )
    }

    func testClipDragListSlotsKeepEachNoncontiguousOrigin() {
        let ids = (0..<4).map { _ in UUID() }

        XCTAssertEqual(
            ClipDragListLayout.slots(
                itemIDs: ids,
                draggingIDs: [ids[0], ids[2]],
                destinationBeforeID: nil,
                showsDestinationGap: false,
                preservesOriginGaps: true
            ),
            [
                .originGap(ids[0]),
                .item(ids[1]),
                .originGap(ids[2]),
                .item(ids[3])
            ]
        )
    }

    func testDropPlannerAllowsPreciseSameSectionPlacementWithoutFilters() {
        let first = dropItem(id: 1, createdAt: 300, section: "Review", manualPosition: 0)
        let moving = dropItem(id: 2, createdAt: 200, section: "Review", manualPosition: 1)
        let last = dropItem(id: 3, createdAt: 100, section: "Review", manualPosition: 2)

        XCTAssertEqual(
            ClipDropPlanner.plan(
                payloadIDs: [moving.id],
                items: [first, moving, last],
                targetSectionID: sectionID("Review"),
                pointerBeforeID: last.id,
                isOverHeading: false,
                sortMode: .manual,
                filtersActive: false
            ),
            ClipDropPlan(
                sectionID: sectionID("Review"),
                beforeID: last.id,
                behavior: .exact,
                showsInsertion: true
            )
        )
    }

    func testDropPlannerBlocksFilteredSameSectionPlacement() {
        let moving = dropItem(id: 1, createdAt: 200, section: "Review", manualPosition: 0)
        let other = dropItem(id: 2, createdAt: 100, section: "Review", manualPosition: 1)

        XCTAssertNil(
            ClipDropPlanner.plan(
                payloadIDs: [moving.id],
                items: [moving, other],
                targetSectionID: sectionID("Review"),
                pointerBeforeID: other.id,
                isOverHeading: false,
                sortMode: .manual,
                filtersActive: true
            )
        )
    }

    func testDropPlannerSendsFilteredManualSectionMoveToTop() {
        let moving = dropItem(id: 1, createdAt: 100, section: "Inbox", manualPosition: 0)
        let first = dropItem(id: 2, createdAt: 200, section: "Review", manualPosition: 0)
        let last = dropItem(id: 3, createdAt: 300, section: "Review", manualPosition: 1)

        XCTAssertEqual(
            ClipDropPlanner.plan(
                payloadIDs: [moving.id],
                items: [moving, last, first],
                targetSectionID: sectionID("Review"),
                pointerBeforeID: last.id,
                isOverHeading: false,
                sortMode: .manual,
                filtersActive: true
            ),
            ClipDropPlan(
                sectionID: sectionID("Review"),
                beforeID: first.id,
                behavior: .sectionTop,
                showsInsertion: false
            )
        )
    }

    func testDropPlannerShowsTheChronologicalDestinationForOneClip() {
        let newest = dropItem(id: 1, createdAt: 300, section: "Review", manualPosition: 0)
        let moving = dropItem(id: 2, createdAt: 200, section: "Inbox", manualPosition: 0)
        let oldest = dropItem(id: 3, createdAt: 100, section: "Review", manualPosition: 1)

        XCTAssertEqual(
            ClipDropPlanner.plan(
                payloadIDs: [moving.id],
                items: [oldest, moving, newest],
                targetSectionID: sectionID("Review"),
                pointerBeforeID: nil,
                isOverHeading: false,
                sortMode: .chronological,
                filtersActive: false
            ),
            ClipDropPlan(
                sectionID: sectionID("Review"),
                beforeID: oldest.id,
                behavior: .chronological,
                showsInsertion: true
            )
        )
    }

    func testDropPlannerOmitsPreciseInsertionForChronologicalBatchSectionMove() {
        let firstMoving = dropItem(id: 1, createdAt: 250, section: "Inbox", manualPosition: 0)
        let secondMoving = dropItem(id: 2, createdAt: 150, section: "Inbox", manualPosition: 1)
        let target = dropItem(id: 3, createdAt: 200, section: "Review", manualPosition: 0)

        XCTAssertEqual(
            ClipDropPlanner.plan(
                payloadIDs: [firstMoving.id, secondMoving.id],
                items: [firstMoving, target, secondMoving],
                targetSectionID: sectionID("Review"),
                pointerBeforeID: target.id,
                isOverHeading: false,
                sortMode: .chronological,
                filtersActive: false
            ),
            ClipDropPlan(
                sectionID: sectionID("Review"),
                beforeID: nil,
                behavior: .chronological,
                showsInsertion: false
            )
        )
    }

    func testFilteringSearchesContentAndSourceAndHonorsCompletionFilter() {
        let done = CaptureItem(
            content: "Follow up tomorrow",
            origin: .quickEntry,
            isDone: true
        )
        let safari = CaptureItem(
            content: "An unrelated excerpt",
            origin: .selection,
            source: CaptureSource(
                applicationName: "Safari",
                windowTitle: "Swift guide",
                url: nil
            )
        )

        XCTAssertEqual(
            InboxFilter.apply(
                items: [done, safari],
                query: "swift",
                completionFilter: .all
            ),
            [safari]
        )
        XCTAssertEqual(
            InboxFilter.apply(
                items: [done, safari],
                query: "",
                completionFilter: .done
            ),
            [done]
        )
        XCTAssertEqual(
            InboxFilter.apply(
                items: [done, safari],
                query: "",
                completionFilter: .notDone
            ),
            [safari]
        )
        XCTAssertTrue(
            InboxFilter.apply(
                items: [done, safari],
                query: "swift",
                completionFilter: .done
            ).isEmpty
        )
    }

    func testLargeInboxFilteringKeepsExactMatches() {
        let items = (0..<2_500).map { index in
            CaptureItem(
                content: index.isMultiple(of: 250) ? "Needle \(index)" : "Item \(index)",
                origin: .quickEntry,
                sectionID: index.isMultiple(of: 2) ? SnipSnapSection.inboxID : sectionID("Later")
            )
        }
        let matches = InboxFilter.apply(
            items: items,
            query: "needle",
            completionFilter: .all
        )
        XCTAssertEqual(matches.count, 10)
    }

    func testInboxSelectionPlainClickDoesNotStartAndClearsBatchSelection() {
        let first = UUID()
        let second = UUID()
        let orderedIDs = [first, second]

        let untouched = InboxSelection.click(
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

        let cleared = InboxSelection.click(
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

    func testInboxSelectionCommandClickStartsThenTogglesBatchSelection() {
        let first = UUID()
        let second = UUID()
        let orderedIDs = [first, second]

        let started = InboxSelection.click(
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

        let added = InboxSelection.click(
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

        let removed = InboxSelection.click(
            first,
            orderedIDs: orderedIDs,
            selection: added.selection,
            anchor: added.anchor,
            focus: added.focus,
            modifiers: .command
        )
        XCTAssertEqual(removed.selection, [second])
    }

    func testInboxSelectionShiftClickUsesVisibleCommandClickAnchor() {
        let ids = (0..<4).map { _ in UUID() }
        let shiftWithoutSelection = InboxSelection.click(
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

        let start = InboxSelection.click(
            ids[1],
            orderedIDs: ids,
            selection: [],
            anchor: nil,
            focus: nil,
            modifiers: .command
        )

        let clickedRange = InboxSelection.click(
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

        let staleAnchor = InboxSelection.click(
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

        let contracted = InboxSelection.move(
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

    func testInboxSelectionArrowStartsAtTheNearestListEdge() {
        let ids = (0..<3).map { _ in UUID() }

        let down = InboxSelection.move(
            by: 1,
            orderedIDs: ids,
            selection: [],
            anchor: nil,
            focus: nil,
            extending: false
        )
        XCTAssertEqual(down.selection, [ids[0]])

        let up = InboxSelection.move(
            by: -1,
            orderedIDs: ids,
            selection: [],
            anchor: nil,
            focus: nil,
            extending: false
        )
        XCTAssertEqual(up.selection, [ids[2]])
    }

    func testInboxSelectionArrowContinuesFromAnExternalSelection() {
        let ids = (0..<3).map { _ in UUID() }

        let moved = InboxSelection.move(
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

        let staleFocus = InboxSelection.move(
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
        let inbox = dropItem(
            id: 1,
            createdAt: 100,
            section: "Inbox",
            manualPosition: 0
        )
        let firstReview = dropItem(id: 2, createdAt: 200, section: "Review", manualPosition: 0)
        let secondReview = dropItem(id: 3, createdAt: 300, section: "Review", manualPosition: 1)
        let snapshot = InboxListSnapshot(
            visibleItems: [secondReview, inbox, firstReview],
            allItems: [secondReview, inbox, firstReview],
            sections: [
                .inbox,
                SnipSnapSection(id: sectionID("Review"), name: "Review", systemImage: "star", position: 1)
            ],
            selection: [secondReview.id, inbox.id]
        )

        XCTAssertEqual(snapshot.groups.map(\.section), ["Inbox", "Review"])
        XCTAssertEqual(snapshot.orderedVisibleIDs, [inbox.id, secondReview.id, firstReview.id])
        XCTAssertEqual(snapshot.dragPayload(for: secondReview).ids, [inbox.id, secondReview.id])
        XCTAssertEqual(snapshot.dragPayload(for: firstReview).ids, [firstReview.id])
    }

    @MainActor
    func testListGeometrySupportsDropPlacementWithoutWindowInputRules() {
        let first = dropItem(id: 1, createdAt: 100, section: "Review", manualPosition: 0)
        let second = dropItem(id: 2, createdAt: 200, section: "Review", manualPosition: 1)
        let geometry = InboxListGeometry()
        geometry.record(CGRect(x: 10, y: 120, width: 200, height: 40), for: .row(first.id))
        geometry.record(CGRect(x: 10, y: 180, width: 200, height: 60), for: .row(second.id))
        geometry.record(
            CGRect(x: 10, y: 80, width: 200, height: 30),
            for: .heading(sectionID("Review"))
        )
        geometry.record(
            CGRect(x: 10, y: 110, width: 200, height: 40),
            for: .dropSurface(.item(first.id))
        )
        geometry.record(
            CGRect(x: 10, y: 120, width: 200, height: 40),
            for: .entry(.item(first.id))
        )
        geometry.record(
            CGRect(x: 10, y: 180, width: 200, height: 60),
            for: .entry(.item(second.id))
        )
        geometry.record(
            CGRect(x: 10, y: 250, width: 200, height: 16),
            for: .sectionFooter(sectionID("Review"))
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
                in: .heading(sectionID("Review"))
            ),
            CGPoint(x: 15, y: 86)
        )
        XCTAssertEqual(
            geometry.contentPoint(
                fromLocalPoint: CGPoint(x: 5, y: 6),
                in: .dropSurface(.item(first.id))
            ),
            CGPoint(x: 15, y: 116)
        )
        XCTAssertEqual(
            geometry.sectionBodyFrame(
                sectionID: sectionID("Review"),
                rowIDs: [first.id, second.id],
                entryIDs: [.item(first.id), .item(second.id)]
            ),
            CGRect(x: 10, y: 120, width: 200, height: 120)
        )
        XCTAssertTrue(
            geometry.hasPlacementFrames(
                in: sectionID("Review"),
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
            for: .dropSurface(.item(second.id))
        )
        geometry.record(
            CGRect(x: 10, y: 180, width: 200, height: 60),
            for: .entry(.originGap(second.id))
        )

        geometry.retainItems([first.id])

        XCTAssertNil(geometry.frame(for: .row(second.id)))
        XCTAssertNil(geometry.frame(for: .entry(.item(second.id))))
        XCTAssertNil(geometry.frame(for: .entry(.originGap(second.id))))
        XCTAssertNil(geometry.frame(for: .dropSurface(.item(second.id))))
    }

    @MainActor
    func testListGeometryUsesHeaderForAnEmptySectionDropSurface() {
        let geometry = InboxListGeometry()
        let sectionID = sectionID("Empty")
        geometry.record(
            CGRect(x: 10, y: 80, width: 200, height: 30),
            for: .heading(sectionID)
        )

        XCTAssertTrue(geometry.hasPlacementFrames(in: sectionID, among: []))
        XCTAssertNil(
            geometry.sectionBodyFrame(
                sectionID: sectionID,
                rowIDs: [],
                entryIDs: []
            )
        )
    }

    @MainActor
    func testListGeometryIncludesSyntheticEntriesInSectionHighlight() {
        let geometry = InboxListGeometry()
        let sectionID = sectionID("Review")
        let gapID = ClipListEntryID.destinationGap(sectionID)
        geometry.record(
            CGRect(x: 10, y: 80, width: 200, height: 72),
            for: .entry(gapID)
        )

        XCTAssertEqual(
            geometry.sectionBodyFrame(
                sectionID: sectionID,
                rowIDs: [],
                entryIDs: [gapID]
            ),
            CGRect(x: 10, y: 80, width: 200, height: 72)
        )
    }

    private func dropItem(
        id: Int,
        createdAt: TimeInterval,
        section: String,
        manualPosition: Int64,
        isDone: Bool = false
    ) -> CaptureItem {
        CaptureItem(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            requestID: UUID(),
            createdAt: Date(timeIntervalSince1970: createdAt),
            content: "Card \(id)",
            origin: .quickEntry,
            sectionID: sectionID(section),
            isDone: isDone,
            manualPosition: manualPosition
        )
    }

    private func sectionID(_ name: String) -> UUID {
        if name == "Inbox" { return SnipSnapSection.inboxID }
        let suffix: String
        switch name {
        case "Review": suffix = "000000000101"
        case "Later": suffix = "000000000102"
        default: suffix = "000000000103"
        }
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}
