import AppKit
import SnipSnapCore
import XCTest
import Foundation
import UniformTypeIdentifiers
@testable import SnipSnap

final class SnipListModelsTests: XCTestCase {
    func testAttachmentPreviewPreservesSnipMetadata() throws {
        let id = UUID()
        let attachment = try JSONDecoder().decode(
            SnipAttachment.self,
            from: Data(
                """
                {
                  "id": "\(id.uuidString)",
                  "fileName": "Original name.txt",
                  "relativePath": "stored-name.txt",
                  "contentType": "public.plain-text",
                  "byteCount": 12
                }
                """.utf8
            )
        )

        let item = AttachmentPreviewItem(
            attachment: attachment,
            url: URL(fileURLWithPath: "/tmp/stored-name.txt")
        )

        XCTAssertEqual(item.id, id.uuidString)
        XCTAssertEqual(item.fileName, "Original name.txt")
    }

    func testAttachmentPreviewReloadsWhenRemoteFileBecomesAvailable() throws {
        let id = UUID()
        let attachment = try JSONDecoder().decode(
            SnipAttachment.self,
            from: Data(
                """
                {
                  "id": "\(id.uuidString)",
                  "fileName": "Remote.txt",
                  "relativePath": "remote.txt",
                  "contentType": "public.plain-text",
                  "byteCount": 12
                }
                """.utf8
            )
        )
        let remote = AttachmentPreviewItem(attachment: attachment, url: nil)
        let local = AttachmentPreviewItem(
            attachment: attachment,
            url: URL(fileURLWithPath: "/tmp/remote.txt")
        )

        XCTAssertNotEqual(
            remote.thumbnailRequestID(displayScale: 2),
            local.thumbnailRequestID(displayScale: 2)
        )
    }

    func testReorderTargetUsesEachRowsRealHeight() {
        let ids = (0..<3).map { _ in UUID() }
        let frames = [
            ids[0]: CGRect(x: 0, y: 220, width: 200, height: 40),
            ids[1]: CGRect(x: 0, y: 100, width: 200, height: 110),
            ids[2]: CGRect(x: 0, y: 50, width: 200, height: 40)
        ]

        XCTAssertEqual(
            SnipListReorderPlan.target(
                atWindowY: 165,
                orderedIDs: ids,
                movingIDs: [ids[2]],
                rowFrames: frames
            ),
            .before(ids[1])
        )
        XCTAssertEqual(
            SnipListReorderPlan.target(
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
            SnipListReorderPlan.target(
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
            SnipListReorderPlan.orderedIDs(
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
            SnipListReorderPlan.orderedIDs(
                from: ids,
                movingIDs: [ids[1]],
                target: .before(ids[2])
            ),
            ids
        )
    }

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
            [SnipListGroup(listID: list.id, listName: list.name, snips: [])]
        )
        XCTAssertTrue(snapshot.orderedVisibleIDs.isEmpty)
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
        let sourceFrame = NSRect(x: 100, y: 100, width: 280, height: 100)
        let context = PanelDragSourceContext(
            scale: 2,
            colorScheme: .light,
            sourceFrame: sourceFrame
        )
        let snips = PanelDragSessionContent(
            retaining: package,
            context: context,
            previewImage: NSImage(size: sourceFrame.size)
        ).draggingItems

        XCTAssertEqual(snips.count, 3)
        XCTAssertGreaterThan(snips[0].draggingFrame.width, 0)
        XCTAssertEqual(snips[1].draggingFrame.size, NSSize(width: 1, height: 1))
        XCTAssertEqual(snips[1].imageComponentsProvider?().count, 0)
        XCTAssertEqual(snips[2].draggingFrame.size, NSSize(width: 1, height: 1))
        XCTAssertEqual(snips[2].imageComponentsProvider?().count, 0)
    }

    func testSnipDragMovesInsideTheAppAndCopiesOutsideIt() {
        XCTAssertEqual(
            SnipDragExportPackage.sourceOperationMask(for: .withinApplication),
            .move
        )
        XCTAssertEqual(
            SnipDragExportPackage.sourceOperationMask(for: .outsideApplication),
            .copy
        )
    }

    @MainActor
    func testMultilineDragPreviewUsesTheExactSourceFrame() {
        let payload = SnipDragPayload(
            ids: [UUID()],
            text: "First line\nSecond line"
        )
        let sourceFrame = NSRect(x: 18, y: 42, width: 316, height: 94)

        let package = SnipDragExportPackage(payload: payload)
        let context = PanelDragSourceContext(
            scale: 2,
            colorScheme: .light,
            sourceFrame: sourceFrame
        )
        let snips = PanelDragSessionContent(
            retaining: package,
            context: context,
            previewImage: NSImage(size: sourceFrame.size)
        ).draggingItems

        XCTAssertEqual(snips.first?.draggingFrame, sourceFrame)
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

    func testRemoteOnlyDragPayloadWaitsForPreparationWithoutInventingAFileURL() {
        let attachmentID = UUID()
        let payload = SnipDragPayload(
            ids: [UUID()],
            text: "Remote attachment",
            attachmentIDs: [attachmentID]
        )

        XCTAssertTrue(payload.hasRemoteOnlyAttachments)
        XCTAssertTrue(payload.attachmentURLs.isEmpty)
        XCTAssertFalse(
            SnipDragExportPackage(payload: payload).pasteboardWriters().contains { writer in
                (writer as? NSURL)?.isFileURL == true
            }
        )
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
                windowTitle: "Draft",
                url: nil
            )
        )
        let quickEntry = Snip(content: "Typed", origin: .quickEntry)

        XCTAssertEqual(captured.displaySourceLabel, "TextEdit — Draft")
        XCTAssertEqual(quickEntry.displaySourceLabel, "Snip Snap — Quick Entry")
    }

    func testDoneSnipsSortAfterActiveSnipsInBothModes() {
        let olderActive = dropSnip(
            id: 1,
            createdAt: 100,
            list: "Review",
            manualPosition: 1
        )
        let newerDone = dropSnip(
            id: 2,
            createdAt: 200,
            list: "Review",
            manualPosition: 0,
            isDone: true
        )
        let newestActive = dropSnip(
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
                content: index.isMultiple(of: 250) ? "Needle \(index)" : "Item \(index)",
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
        let inbox = dropSnip(
            id: 1,
            createdAt: 100,
            list: "Inbox",
            manualPosition: 0
        )
        let firstReview = dropSnip(id: 2, createdAt: 200, list: "Review", manualPosition: 0)
        let secondReview = dropSnip(id: 3, createdAt: 300, list: "Review", manualPosition: 1)
        let snapshot = SnipListSnapshot(
            visibleSnips: [secondReview, inbox, firstReview],
            allSnips: [secondReview, inbox, firstReview],
            lists: [
                .inbox,
                SnipList(id: listID("Review"), name: "Review", systemImage: "star", position: 1)
            ],
            selection: [secondReview.id, inbox.id]
        )

        XCTAssertEqual(snapshot.groups.map(\.listName), ["Inbox", "Review"])
        XCTAssertEqual(snapshot.orderedVisibleIDs, [inbox.id, secondReview.id, firstReview.id])
        XCTAssertEqual(snapshot.dragPayload(for: secondReview).ids, [inbox.id, secondReview.id])
        XCTAssertEqual(snapshot.dragPayload(for: firstReview).ids, [firstReview.id])
    }

    private func dropSnip(
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
