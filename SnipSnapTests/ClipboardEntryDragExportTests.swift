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

    func testExportIsCopyOnly() {
        let entry = ClipboardEntry(
            sourceApplication: "Tests",
            items: [payload(.string, Data("Copy me".utf8))]
        )

        XCTAssertEqual(
            ClipboardEntryDragExportPackage(entry: entry).sourceOperationMask,
            .copy
        )
    }

    func testEmptyEntryProducesNoDraggingItems() {
        let entry = ClipboardEntry(sourceApplication: "Tests", items: [])
        let package = ClipboardEntryDragExportPackage(entry: entry)

        XCTAssertTrue(package.pasteboardWriters().isEmpty)
        XCTAssertTrue(
            package.draggingItems(
                preview: NSImage(size: NSSize(width: 20, height: 20)),
                sourceFrame: NSRect(x: 0, y: 0, width: 20, height: 20)
            ).isEmpty
        )
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
