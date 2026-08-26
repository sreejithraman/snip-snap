import AppKit
import XCTest
import Foundation
import UniformTypeIdentifiers
@testable import SnipSnap

final class InboxModelsTests: XCTestCase {
    func testReorderTargetUsesEachRowsRealHeight() {
        let ids = (0..<3).map { _ in UUID() }
        let frames = [
            ids[0]: CGRect(x: 0, y: 220, width: 200, height: 40),
            ids[1]: CGRect(x: 0, y: 100, width: 200, height: 110),
            ids[2]: CGRect(x: 0, y: 50, width: 200, height: 40)
        ]

        XCTAssertEqual(
            InboxReorderPlan.target(
                atWindowY: 165,
                orderedIDs: ids,
                movingIDs: [ids[2]],
                rowFrames: frames
            ),
            .before(ids[1])
        )
        XCTAssertEqual(
            InboxReorderPlan.target(
                atWindowY: 95,
                orderedIDs: ids,
                movingIDs: [ids[2]],
                rowFrames: frames
            ),
            .end
        )
    }

    func testReorderTargetOffsetsFrozenFramesAfterScrolling() {
        let ids = (0..<2).map { _ in UUID() }
        let frames = [
            ids[0]: CGRect(x: 0, y: 180, width: 200, height: 40),
            ids[1]: CGRect(x: 0, y: 120, width: 200, height: 40)
        ]

        XCTAssertEqual(
            InboxReorderPlan.target(
                atWindowY: 265,
                orderedIDs: ids,
                movingIDs: [ids[1]],
                rowFrames: frames,
                rowFrameOffsetY: 60
            ),
            .before(ids[0])
        )
    }

    func testReorderPlanMovesToAMiddleSlot() {
        let ids = (0..<4).map { _ in UUID() }

        XCTAssertEqual(
            InboxReorderPlan.orderedIDs(
                from: ids,
                movingIDs: [ids[0]],
                target: .before(ids[2])
            ),
            [ids[1], ids[0], ids[2], ids[3]]
        )
    }

    func testReorderPlanDetectsAnUnchangedDrop() {
        let ids = (0..<3).map { _ in UUID() }

        XCTAssertEqual(
            InboxReorderPlan.orderedIDs(
                from: ids,
                movingIDs: [ids[1]],
                target: .before(ids[2])
            ),
            ids
        )
    }

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

    @MainActor
    func testMultilineDragPreviewUsesTheExactSourceFrame() {
        let payload = ClipDragPayload(
            ids: [UUID()],
            text: "First line\nSecond line"
        )
        let sourceFrame = NSRect(x: 18, y: 42, width: 316, height: 94)

        let items = ClipDragExportPackage(payload: payload).draggingItems(
            at: sourceFrame.origin,
            scale: 2,
            colorScheme: .light,
            sourceFrame: sourceFrame
        )

        XCTAssertEqual(items.first?.draggingFrame, sourceFrame)
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
