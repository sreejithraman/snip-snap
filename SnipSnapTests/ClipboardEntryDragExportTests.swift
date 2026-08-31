import AppKit
import XCTest
@testable import SnipSnap

@MainActor
final class ClipboardEntryDragExportTests: XCTestCase {
    func testWritersPreserveItemOrderAndStoredForms() throws {
        let firstURL = URL(fileURLWithPath: "/tmp/first.txt")
        let imageData = Data([0x89, 0x50, 0x4e, 0x47])
        let entry = ClipboardEntry(
            sourceApplication: "Tests",
            items: [
                payload(.fileURL, Data(firstURL.absoluteString.utf8)),
                payload(.png, imageData),
                payload(.string, Data("Last".utf8))
            ]
        )

        let writers = ClipboardEntryDragExportPackage(entry: entry).pasteboardWriters()
        let items = try writers.map { try XCTUnwrap($0 as? NSPasteboardItem) }

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].string(forType: .fileURL), firstURL.absoluteString)
        XCTAssertEqual(items[1].data(forType: .png), imageData)
        XCTAssertEqual(items[2].string(forType: .string), "Last")
    }

    func testWritersKeepSeveralFormsOnTheSameItem() throws {
        let richText = Data([0x01, 0x02, 0x03])
        let entry = ClipboardEntry(
            sourceApplication: "Tests",
            items: [
                ClipboardPayloadItem(
                    representations: [
                        representation(.string, Data("Plain".utf8)),
                        representation(.rtf, richText)
                    ]
                )
            ]
        )

        let writer = try XCTUnwrap(
            ClipboardEntryDragExportPackage(entry: entry)
                .pasteboardWriters()
                .first as? NSPasteboardItem
        )

        XCTAssertEqual(writer.string(forType: .string), "Plain")
        XCTAssertEqual(writer.data(forType: .rtf), richText)
    }

    func testWriterAddsPlainTextFallbackWhenEntryHasNoStringForm() throws {
        let firstURL = URL(fileURLWithPath: "/tmp/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/second.txt")
        let entry = ClipboardEntry(
            sourceApplication: "Tests",
            items: [
                payload(.fileURL, Data(firstURL.absoluteString.utf8)),
                payload(.fileURL, Data(secondURL.absoluteString.utf8))
            ]
        )

        let writers = ClipboardEntryDragExportPackage(entry: entry).pasteboardWriters()
        let items = try writers.map { try XCTUnwrap($0 as? NSPasteboardItem) }

        XCTAssertEqual(items.map { $0.string(forType: .fileURL) }, [
            firstURL.absoluteString,
            secondURL.absoluteString
        ])
        XCTAssertEqual(items[0].string(forType: .string), "first.txt, second.txt")
        XCTAssertNil(items[1].string(forType: .string))
    }

    func testClipboardDragPolicyIsCopyOnly() {
        XCTAssertEqual(
            ClipboardEntryDragExportPackage.sourceOperationMask(for: .withinApplication),
            .copy
        )
        XCTAssertEqual(
            ClipboardEntryDragExportPackage.sourceOperationMask(for: .outsideApplication),
            .copy
        )
    }

    func testEmptyEntryProducesNoDraggingItems() {
        let entry = ClipboardEntry(sourceApplication: "Tests", items: [])
        let package = ClipboardEntryDragExportPackage(entry: entry)

        XCTAssertTrue(package.pasteboardWriters().isEmpty)
        let sourceFrame = NSRect(x: 0, y: 0, width: 20, height: 20)
        XCTAssertTrue(
            PanelDragSessionContent(
                retaining: package,
                context: PanelDragSourceContext(
                scale: 2,
                colorScheme: .light,
                sourceFrame: sourceFrame
                ),
                previewImage: NSImage(size: sourceFrame.size)
            ).draggingItems.isEmpty
        )
    }

    func testClipboardDragUsesSharedSourceFrameAndHidesSecondaryItems() {
        let entry = ClipboardEntry(
            sourceApplication: "Tests",
            items: [
                payload(.string, Data("First".utf8)),
                payload(.string, Data("Second".utf8))
            ]
        )
        let sourceFrame = NSRect(x: 18, y: 42, width: 316, height: 94)
        let package = ClipboardEntryDragExportPackage(entry: entry)

        let context = PanelDragSourceContext(
            scale: 2,
            colorScheme: .light,
            sourceFrame: sourceFrame
        )
        let items = PanelDragSessionContent(
            retaining: package,
            context: context,
            previewImage: NSImage(size: sourceFrame.size)
        ).draggingItems

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].draggingFrame, sourceFrame)
        XCTAssertEqual(items[1].draggingFrame.size, NSSize(width: 1, height: 1))
        XCTAssertEqual(items[1].imageComponentsProvider?().count, 0)
    }

    private func payload(
        _ type: NSPasteboard.PasteboardType,
        _ data: Data
    ) -> ClipboardPayloadItem {
        ClipboardPayloadItem(representations: [representation(type, data)])
    }

    private func representation(
        _ type: NSPasteboard.PasteboardType,
        _ data: Data
    ) -> ClipboardRepresentation {
        ClipboardRepresentation(type: type.rawValue, data: data)
    }
}
