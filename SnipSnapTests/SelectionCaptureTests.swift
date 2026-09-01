import XCTest
import SnipSnapCore
import AppKit
@testable import SnipSnap

final class SelectionCaptureTests: XCTestCase {
    func testSelectionCaptureFallsBackToFocusedAXTextWhenCopyIsUnavailable() {
        let fixture = SelectionCaptureFixture(axTexts: ["  exact selection\n"])
        let reader = fixture.makeReader()
        let result = captureOnce(reader, processID: 41, applicationName: "Editor")

        XCTAssertEqual(
            result,
            .success(
                SelectionCapture(
                    content: "  exact selection\n",
                    source: SnipSource(
                        applicationName: "Editor",
                        windowTitle: "Work",
                        url: "https://example.com/work"
                    )
                )
            )
        )
        XCTAssertEqual(fixture.postedProcessIDs, [41])
    }

    func testSelectionCaptureWalksAXAncestorsBeforeCopyFallback() {
        let fixture = SelectionCaptureFixture(
            axTexts: [nil],
            ancestorTexts: ["Ancestor selection"]
        )
        let result = captureOnce(fixture.makeReader(), processID: 42, applicationName: "Browser")

        XCTAssertEqual(result?.success?.content, "Ancestor selection")
        XCTAssertEqual(fixture.postedProcessIDs, [42])
    }

    func testQueuedSelectionCaptureStopsWhenSourceAppChangedBeforeAXRead() {
        let fixture = SelectionCaptureFixture(
            axTexts: ["Should not be read"],
            frontmostChecks: [false]
        )
        let result = captureOnce(fixture.makeReader(), processID: 70, applicationName: "Browser")

        XCTAssertEqual(result, .failure(.sourceChanged))
        XCTAssertEqual(fixture.focusedReadCount, 0)
        XCTAssertEqual(fixture.postedProcessIDs, [])
    }

    func testSelectionCaptureStopsWhenSourceAppChangedBeforeCopy() {
        let fixture = SelectionCaptureFixture(
            axTexts: [nil],
            copyBehaviors: [.write("Wrong app")],
            frontmostChecks: [true, false]
        )
        let result = captureOnce(fixture.makeReader(), processID: 71, applicationName: "Browser")

        XCTAssertEqual(result, .failure(.sourceChanged))
        XCTAssertEqual(fixture.postedProcessIDs, [])
    }

    func testSelectionCaptureStopsIfClipboardChangesAfterSnapshotBeforeCopy() {
        let fixture = SelectionCaptureFixture(
            axTexts: [nil],
            copyBehaviors: [.write("Should not copy")],
            changeClipboardAfterSnapshot: true
        )
        let result = captureOnce(fixture.makeReader(), processID: 72, applicationName: "Browser")

        XCTAssertEqual(result, .failure(.clipboardChanged))
        XCTAssertEqual(fixture.postedProcessIDs, [])
        XCTAssertEqual(fixture.restoreAttempts, 0)
    }

    func testSelectionCaptureFallsBackToCopyForOriginalProcess() {
        let fixture = SelectionCaptureFixture(
            axTexts: [nil],
            copyBehaviors: [.write("  copied selection\n")]
        )
        let result = captureOnce(fixture.makeReader(), processID: 73, applicationName: "Safari")

        XCTAssertEqual(result?.success?.content, "  copied selection\n")
        XCTAssertEqual(fixture.postedProcessIDs, [73])
        XCTAssertEqual(fixture.restoreCount, 1)
    }

    func testSelectionCaptureKeepsCopiedImagesAsAttachments() {
        let png = Data([137, 80, 78, 71])
        let fixture = SelectionCaptureFixture(
            axTexts: ["Article text"],
            copyBehaviors: [
                .writePayload(
                    text: "Article text",
                    items: [
                        .init(values: [
                            .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("Article text".utf8)),
                            .init(type: NSPasteboard.PasteboardType.png.rawValue, data: png)
                        ])
                    ]
                )
            ]
        )

        let result = captureOnce(fixture.makeReader(), processID: 81, applicationName: "Browser")

        XCTAssertEqual(result?.success?.content, "Article text")
        XCTAssertEqual(
            result?.success?.attachments,
            [SelectionCaptureAttachment(fileName: "Selection.png", data: png)]
        )
        XCTAssertEqual(fixture.restoreCount, 1)
    }

    func testSelectionCaptureAcceptsAnImageWithoutText() {
        let png = Data([137, 80, 78, 71])
        let fixture = SelectionCaptureFixture(
            axTexts: [nil],
            copyBehaviors: [
                .writePayload(
                    text: nil,
                    items: [
                        .init(values: [
                            .init(type: NSPasteboard.PasteboardType.png.rawValue, data: png)
                        ])
                    ]
                )
            ]
        )

        let result = captureOnce(fixture.makeReader(), processID: 82, applicationName: "Canvas")

        XCTAssertEqual(result?.success?.content, "")
        XCTAssertEqual(
            result?.success?.attachments,
            [SelectionCaptureAttachment(fileName: "Selection.png", data: png)]
        )
        XCTAssertEqual(fixture.restoreCount, 1)
    }

    func testSelectionCaptureCopyFallbackTimesOut() {
        let fixture = SelectionCaptureFixture(
            axTexts: [nil],
            copyBehaviors: [.timeout]
        )
        let result = captureOnce(
            fixture.makeReader(copyTimeout: 0.03, pollInterval: 0.01),
            processID: 74,
            applicationName: "Terminal"
        )

        XCTAssertEqual(result, .failure(.copyTimedOut))
        XCTAssertEqual(fixture.postedProcessIDs, [74])
        XCTAssertEqual(fixture.restoreCount, 0)
    }

    func testSelectionCaptureRestoresClipboardWhenCopyHasNoUsableContent() {
        let originalItems = [
            PasteboardSnapshot.Item(values: [
                .init(type: "com.example.binary", data: Data([4, 3, 2, 1]))
            ])
        ]
        let fixture = SelectionCaptureFixture(
            axTexts: [nil],
            copyBehaviors: [.writeWithoutText],
            originalItems: originalItems
        )

        let result = captureOnce(
            fixture.makeReader(copyTimeout: 0.03, pollInterval: 0.01),
            processID: 79,
            applicationName: "Canvas"
        )

        XCTAssertEqual(result, .failure(.noSelection))
        XCTAssertEqual(fixture.currentPasteboardItems, originalItems)
        XCTAssertEqual(fixture.restoreCount, 1)
        XCTAssertEqual(fixture.sleepCount, 0)
    }

    func testSelectionCaptureAbortsBeforeCopyWhenFullClipboardSnapshotTimesOut() {
        let fixture = SelectionCaptureFixture(
            axTexts: [nil],
            copyBehaviors: [.write("Must not copy")],
            blockSnapshot: true
        )
        defer { fixture.releaseSnapshot() }

        let result = captureOnce(
            fixture.makeReader(snapshotTimeout: 0.02),
            processID: 80,
            applicationName: "Browser"
        )

        XCTAssertTrue(fixture.snapshotDidStart)
        XCTAssertEqual(result, .failure(.clipboardSnapshotTimedOut))
        XCTAssertEqual(fixture.postedProcessIDs, [])
        XCTAssertEqual(fixture.restoreAttempts, 0)
    }

    func testSelectionCaptureRestoresEveryPasteboardItemAndType() {
        let originalItems = [
            PasteboardSnapshot.Item(values: [
                .init(type: "public.utf8-plain-text", data: Data([0, 1, 2, 255])),
                .init(type: "com.example.custom", data: Data([9, 8, 7]))
            ]),
            PasteboardSnapshot.Item(values: [
                .init(type: "public.png", data: Data([137, 80, 78, 71]))
            ])
        ]
        let fixture = SelectionCaptureFixture(
            axTexts: [nil],
            copyBehaviors: [.write("Copied")],
            originalItems: originalItems
        )

        _ = captureOnce(fixture.makeReader(), processID: 75, applicationName: "Browser")

        XCTAssertEqual(fixture.currentPasteboardItems, originalItems)
        XCTAssertEqual(fixture.restoreCount, 1)
    }

    func testPasteboardSnapshotStoreRestoresEveryRealItemAndType() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("world.sree.snipsnap.tests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        let first = NSPasteboardItem()
        XCTAssertTrue(
            first.setData(Data([0, 1, 2, 255]), forType: .init("com.example.binary"))
        )
        XCTAssertTrue(
            first.setData(Data("plain text".utf8), forType: .string)
        )
        let second = NSPasteboardItem()
        XCTAssertTrue(
            second.setData(Data([137, 80, 78, 71]), forType: .png)
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        let original = try XCTUnwrap(PasteboardSnapshotStore.snapshot(pasteboard))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Copied selection", forType: .string))
        let copiedChangeCount = pasteboard.changeCount

        XCTAssertEqual(
            PasteboardSnapshotStore.restore(
                original,
                to: pasteboard,
                ifChangeCountIs: copiedChangeCount
            ),
            .restored
        )
        let restored = try XCTUnwrap(PasteboardSnapshotStore.snapshot(pasteboard))
        XCTAssertEqual(restored.items, original.items)
    }

    func testSelectionCaptureDoesNotOverwriteNewerClipboardChange() {
        let fixture = SelectionCaptureFixture(
            axTexts: [nil],
            copyBehaviors: [.write("Captured")],
            thirdPartyTextAfterRead: "New clipboard value"
        )
        let result = captureOnce(fixture.makeReader(), processID: 76, applicationName: "Browser")

        XCTAssertEqual(result, .failure(.clipboardChanged))
        XCTAssertEqual(fixture.currentPasteboardString, "New clipboard value")
        XCTAssertEqual(fixture.restoreCount, 0)
        XCTAssertEqual(fixture.restoreAttempts, 0)
    }

    func testSelectionCaptureReportsPasteboardRestoreWriteFailure() {
        let fixture = SelectionCaptureFixture(
            axTexts: [nil],
            copyBehaviors: [.write("Captured")],
            restoreShouldFail: true
        )
        let result = captureOnce(fixture.makeReader(), processID: 78, applicationName: "Browser")

        XCTAssertEqual(result, .failure(.clipboardRestoreFailed))
        XCTAssertEqual(fixture.restoreAttempts, 1)
        XCTAssertEqual(fixture.restoreCount, 0)
    }

    func testRapidSelectionCapturesStayFIFOAndSuppressImmediateDuplicate() {
        let fixture = SelectionCaptureFixture(axTexts: ["One", "One", "Two"])
        let reader = fixture.makeReader()
        let results = CaptureResultStore()
        let completed = expectation(description: "All captures complete")
        completed.expectedFulfillmentCount = 3

        for _ in 0..<3 {
            reader.capture(processID: 77, applicationName: "Editor") { result in
                results.append(result)
                completed.fulfill()
            }
        }
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(
            results.values,
            [
                .success(
                    SelectionCapture(
                        content: "One",
                        source: SnipSource(
                            applicationName: "Editor",
                            windowTitle: "Work",
                            url: "https://example.com/work"
                        )
                    )
                ),
                .failure(.duplicateSelection),
                .success(
                    SelectionCapture(
                        content: "Two",
                        source: SnipSource(
                            applicationName: "Editor",
                            windowTitle: "Work",
                            url: "https://example.com/work"
                        )
                    )
                )
            ]
        )
        XCTAssertEqual(fixture.postedProcessIDs, [77, 77, 77])
    }

    private func captureOnce(
        _ reader: AccessibilitySelectionReader,
        processID: pid_t,
        applicationName: String
    ) -> Result<SelectionCapture, SelectionCaptureFailure>? {
        let resultStore = CaptureResultStore()
        let completed = expectation(description: "Capture completes")
        reader.capture(processID: processID, applicationName: applicationName) { result in
            resultStore.append(result)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        return resultStore.values.first
    }
}
private extension Result where Success == SelectionCapture, Failure == SelectionCaptureFailure {
    var success: SelectionCapture? {
        guard case .success(let capture) = self else { return nil }
        return capture
    }
}
private final class CaptureResultStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Result<SelectionCapture, SelectionCaptureFailure>] = []

    var values: [Result<SelectionCapture, SelectionCaptureFailure>] {
        lock.withLock { storedValues }
    }

    func append(_ value: Result<SelectionCapture, SelectionCaptureFailure>) {
        lock.withLock { storedValues.append(value) }
    }
}
