import AppKit
import SnipSnapCore
import XCTest
@testable import SnipSnap

@MainActor
final class ClipboardHistoryTests: XCTestCase {
    func testCapturesAndRestoresEveryPasteboardItem() throws {
        let context = try makeContext()
        let firstURL = URL(fileURLWithPath: "/tmp/first.md")
        let secondURL = URL(fileURLWithPath: "/tmp/second.md")
        writeFileURLs([firstURL, secondURL], to: context.pasteboard)

        context.history.poll()

        let entry = try XCTUnwrap(context.history.entries.first)
        XCTAssertEqual(entry.items.count, 2)
        XCTAssertEqual(entry.fileURLs, [firstURL, secondURL])

        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.setString("replacement", forType: .string))
        XCTAssertTrue(context.history.restore(entry))
        XCTAssertEqual(context.pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(
            context.pasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileURL) },
            [firstURL.absoluteString, secondURL.absoluteString]
        )
    }

    func testCaptureRestoresSourceSpecificPasteboardForms() throws {
        let context = try makeContext()
        let customType = NSPasteboard.PasteboardType.rtf
        let item = NSPasteboardItem()
        item.setString("Visible text", forType: .string)
        item.setData(Data([0x01, 0x02, 0x03]), forType: customType)
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([item]))

        context.history.poll()
        let entry = try XCTUnwrap(context.history.entries.first)
        context.pasteboard.clearContents()

        XCTAssertTrue(context.history.restore(entry))
        XCTAssertEqual(
            context.pasteboard.data(forType: customType),
            Data([0x01, 0x02, 0x03])
        )
    }

    func testCaptureSkipsUnsupportedAndOversizedRepresentations() throws {
        let context = try makeContext()
        let item = NSPasteboardItem()
        item.setString("Visible text", forType: .string)
        item.setData(
            Data(repeating: 7, count: ClipboardHistory.representationByteLimit + 1),
            forType: .png
        )
        item.setData(Data([1, 2, 3]), forType: .init("world.sree.snipsnap.tests.unsupported"))
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([item]))

        context.history.poll()

        let entry = try XCTUnwrap(context.history.entries.first)
        XCTAssertEqual(entry.items.flatMap(\.representations).map(\.type), [NSPasteboard.PasteboardType.string.rawValue])
    }

    func testLargeCaptureFinishesThroughTheBackgroundProcessingPath() async throws {
        let context = try makeContext()
        let item = NSPasteboardItem()
        item.setString("Large image", forType: .string)
        item.setData(
            Data(repeating: 7, count: ClipboardHistory.backgroundProcessingThreshold),
            forType: .png
        )
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([item]))

        context.history.poll()
        await context.history.waitForPendingCapture()

        let entry = try XCTUnwrap(context.history.entries.first)
        XCTAssertEqual(entry.text, "Large image")
        XCTAssertEqual(entry.imageRepresentations.first?.data.count, ClipboardHistory.backgroundProcessingThreshold)
    }

    func testPauseAndScopedSuppressionSkipChanges() throws {
        let context = try makeContext()
        writeText("Initial", to: context.pasteboard)
        context.history.poll()
        XCTAssertEqual(context.history.entries.map(\.text), ["Initial"])

        context.history.setPaused(true)
        writeText("While paused", to: context.pasteboard)
        context.history.poll()
        context.history.setPaused(false)
        context.history.poll()
        XCTAssertEqual(context.history.entries.map(\.text), ["Initial"])

        let token = context.history.beginSuppression()
        writeText("Temporary copy", to: context.pasteboard)
        context.history.poll()
        context.history.endSuppression(token)
        context.history.poll()
        XCTAssertEqual(context.history.entries.map(\.text), ["Initial"])

        writeText("User copy", to: context.pasteboard)
        context.history.poll()
        XCTAssertEqual(context.history.entries.map(\.text), ["User copy", "Initial"])
    }

    func testPauseSurvivesRelaunch() throws {
        let context = try makeContext()
        context.history.setPaused(true)

        let reopened = ClipboardHistory(
            pasteboard: context.pasteboard,
            defaults: context.defaults,
            storeURL: context.storeURL
        )

        XCTAssertTrue(reopened.isPaused)
        writeText("Ignored after relaunch", to: context.pasteboard)
        reopened.poll()
        XCTAssertTrue(reopened.entries.isEmpty)
    }

    func testClipboardEntryRejectsTheOldFlatPayloadShape() throws {
        let legacy = """
        {
          "id": "00000000-0000-0000-0000-000000000123",
          "capturedAt": "2026-08-22T12:00:00Z",
          "representations": [],
          "plainText": "Old"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(try decoder.decode(ClipboardEntry.self, from: Data(legacy.utf8)))
    }

    func testInternalCopyMarkerNeverCreatesHistory() throws {
        let context = try makeContext()
        writeText("Initial", to: context.pasteboard)
        context.history.poll()

        let item = NSPasteboardItem()
        item.setString("Snip Snap copy", forType: .string)
        item.setData(Data(), forType: ClipboardHistory.internalType)
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.writeObjects([item]))
        context.history.poll()

        XCTAssertEqual(context.history.entries.map(\.text), ["Initial"])
    }

    func testHistoryPersistsTheLatestClipboardSnapshot() async throws {
        let context = try makeContext()
        writeText("First", to: context.pasteboard)
        context.history.poll()
        writeText("Second", to: context.pasteboard)
        context.history.poll()

        await context.history.flushPersistence()

        let data = try Data(contentsOf: context.storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([ClipboardEntry].self, from: data)
        XCTAssertEqual(entries.map(\.text), ["Second", "First"])
    }

    func testInitialHistoryLoadKeepsNewerCapturedEntries() async throws {
        let context = try makeContext(persistedEntries: [clipboardEntry("Persisted")])
        writeText("Copied during launch", to: context.pasteboard)

        context.history.poll()
        await context.history.waitForInitialLoad()

        XCTAssertEqual(
            context.history.entries.map(\.text),
            ["Copied during launch", "Persisted"]
        )
    }

    func testFileStoreKeepsTheNewestRapidReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip SnapClipboardStoreTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("clipboard.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryFileStore(url: storeURL)

        await store.scheduleReplacement([clipboardEntry("First")])
        await store.scheduleReplacement([clipboardEntry("Newest")])
        await store.flush()

        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([ClipboardEntry].self, from: data)
        XCTAssertEqual(entries.map(\.text), ["Newest"])
    }

    func testHistoryReportsPersistenceFailure() async throws {
        let context = try makeContext()
        try Data("not a directory".utf8).write(
            to: context.storeURL.deletingLastPathComponent(),
            options: .atomic
        )
        writeText("Keep this in memory", to: context.pasteboard)

        context.history.poll()
        await context.history.flushPersistence()

        XCTAssertEqual(context.history.entries.map(\.text), ["Keep this in memory"])
        XCTAssertNotNil(context.history.persistenceError)
    }

    func testHistoryByteLimitKeepsANewestFirstPrefixAfterSkippingOversizedEntries() {
        let oversized = clipboardEntry("O", byteCount: 9)
        let newest = clipboardEntry("N", byteCount: 6)
        let next = clipboardEntry("M", byteCount: 4)
        let older = clipboardEntry("L", byteCount: 2)

        let result = ClipboardHistory.trimmed(
            [oversized, newest, next, older],
            maximumEntryBytes: 8,
            maximumHistoryBytes: 8,
            maximumCount: 4
        )

        XCTAssertEqual(result.map(\.text), ["N"])
    }

    private func makeContext(
        persistedEntries: [ClipboardEntry] = []
    ) throws -> (
        history: ClipboardHistory,
        pasteboard: NSPasteboard,
        storeURL: URL,
        defaults: UserDefaults
    ) {
        let pasteboard = NSPasteboard(
            name: .init("world.sree.snipsnap.clipboard-tests.\(UUID().uuidString)")
        )
        let suite = "Snip SnapClipboardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip SnapClipboardTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("clipboard.json")
        if !persistedEntries.isEmpty {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(persistedEntries).write(to: storeURL, options: .atomic)
        }
        addTeardownBlock {
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (
            ClipboardHistory(pasteboard: pasteboard, defaults: defaults, storeURL: storeURL),
            pasteboard,
            storeURL,
            defaults
        )
    }

    private func clipboardEntry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(
            sourceApplication: "Tests",
            items: [
                ClipboardPayloadItem(
                    representations: [
                        ClipboardRepresentation(
                            type: NSPasteboard.PasteboardType.string.rawValue,
                            data: Data(text.utf8)
                        )
                    ]
                )
            ]
        )
    }

    private func clipboardEntry(_ text: String, byteCount: Int) -> ClipboardEntry {
        let textData = Data(text.utf8)
        return ClipboardEntry(
            sourceApplication: "Tests",
            items: [
                ClipboardPayloadItem(
                    representations: [
                        ClipboardRepresentation(
                            type: NSPasteboard.PasteboardType.string.rawValue,
                            data: textData
                        ),
                        ClipboardRepresentation(
                            type: NSPasteboard.PasteboardType.png.rawValue,
                            data: Data(repeating: 0, count: max(byteCount - textData.count, 0))
                        )
                    ]
                )
            ]
        )
    }

    private func writeText(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
    }

    private func writeFileURLs(_ urls: [URL], to pasteboard: NSPasteboard) {
        let items = urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
    }
}
