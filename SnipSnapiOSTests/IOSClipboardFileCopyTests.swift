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
final class IOSClipboardFileCopyTests: XCTestCase {
    func testFileCopyReadsOffMainThreadAndPreservesMixedRepresentations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("original.bin")
        let original = Data([0, 1, 2, 250, 255])
        try original.write(to: url)
        let read = ClipboardCopyReadGate()
        let preferencesName = UUID().uuidString
        let preferences = UserDefaults(suiteName: preferencesName)!
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let clipboard = IOSClipboardModel(rootURL: root,
            settings: SyncedContentSettingsModel(mode: .localOnly), preferences: preferences,
            readCopyFile: { try read.read($0) })
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        UIPasteboard.general.string = "Previous pasteboard"
        let html = Data("<b>Original text</b>".utf8)
        let entry = ClipboardEntry(items: [
            .init(representations: [
                .init(type: UTType.utf8PlainText.identifier, data: Data("Original text".utf8)),
                .init(type: UTType.html.identifier, data: html),
            ]),
            .init(representations: [.init(type: UTType.fileURL.identifier, data: Data(url.absoluteString.utf8))]),
        ])
        let coordinator = IOSCopyShareCoordinator()
        let text = ClipboardEntry(items: [.init(representations: [
            .init(type: UTType.utf8PlainText.identifier, data: Data("Earlier copy".utf8)),
        ])])
        let earlierSucceeded = await coordinator.copyClipboardEntry(text, clipboard: clipboard).value
        XCTAssertTrue(earlierSucceeded)
        XCTAssertTrue(clipboard.copied)
        UIPasteboard.general.string = "Previous pasteboard"
        let copying = coordinator.copyClipboardEntry(entry, clipboard: clipboard)
        await fulfillment(of: [read.entered], timeout: 2)
        XCTAssertEqual(UIPasteboard.general.string, "Previous pasteboard")
        XCTAssertFalse(clipboard.copied)
        XCTAssertFalse(read.wasMainThread)
        read.resume.signal()
        let succeeded = await copying.value
        XCTAssertTrue(succeeded)
        XCTAssertTrue(clipboard.copied)
        XCTAssertEqual(UIPasteboard.general.string, "Original text")
        XCTAssertEqual(UIPasteboard.general.data(forPasteboardType: UTType.html.identifier), html)
        let type = UTType(filenameExtension: "bin")?.identifier ?? UTType.data.identifier
        XCTAssertEqual(
            UIPasteboard.general.data(forPasteboardType: type, inItemSet: IndexSet(integer: 1)),
            [original]
        )
    }

    func testNewerSnipCopyPreventsLateClipboardPublication() async throws {
        for fails in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("older.bin")
            try Data([42]).write(to: url)
            let read = ClipboardCopyReadGate(fails: fails)
            let preferencesName = UUID().uuidString
            let preferences = UserDefaults(suiteName: preferencesName)!
            defer { preferences.removePersistentDomain(forName: preferencesName) }
            let clipboard = IOSClipboardModel(rootURL: root,
                settings: SyncedContentSettingsModel(mode: .localOnly), preferences: preferences,
                readCopyFile: { try read.read($0) })
            let entry = ClipboardEntry(items: [.init(representations: [
                .init(type: UTType.fileURL.identifier, data: Data(url.absoluteString.utf8)),
            ])])
            let previous = UIPasteboard.general.items
            defer { UIPasteboard.general.items = previous }
            UIPasteboard.general.string = "Previous pasteboard"
            let pasteboard = RecordingPasteboard()
            let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
            let older = coordinator.copyClipboardEntry(entry, clipboard: clipboard)
            await fulfillment(of: [read.entered], timeout: 2)
            let snip = Snip(content: "Newer copy", origin: .quickEntry)
            let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]))
            await model.load()
            let newer = await coordinator.copyText(snips: [snip], model: model)
            read.resume.signal()
            let olderSucceeded = await older.value
            XCTAssertTrue(newer)
            XCTAssertFalse(olderSucceeded)
            XCTAssertEqual(pasteboard.writes, [[.text("Newer copy")]])
            XCTAssertEqual(UIPasteboard.general.string, "Previous pasteboard")
            XCTAssertFalse(clipboard.copied)
            XCTAssertNil(clipboard.errorMessage)
        }
    }

    func testUnreadableFilePreservesPasteboardAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("retry.bin")
        let preferencesName = UUID().uuidString
        let preferences = UserDefaults(suiteName: preferencesName)!
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let clipboard = IOSClipboardModel(rootURL: root,
            settings: SyncedContentSettingsModel(mode: .localOnly), preferences: preferences)
        let entry = ClipboardEntry(items: [.init(representations: [
            .init(type: UTType.fileURL.identifier, data: Data(url.absoluteString.utf8)),
        ])])
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        UIPasteboard.general.string = "Keep on failure"
        let coordinator = IOSCopyShareCoordinator()
        let failed = await coordinator.copyClipboardEntry(entry, clipboard: clipboard).value
        XCTAssertFalse(failed)
        XCTAssertEqual(UIPasteboard.general.string, "Keep on failure")
        XCTAssertNotNil(clipboard.errorMessage)
        XCTAssertFalse(clipboard.copied)
        let bytes = Data([7, 8, 9])
        try bytes.write(to: url)
        let retried = await coordinator.copyClipboardEntry(entry, clipboard: clipboard).value
        XCTAssertTrue(retried)
        XCTAssertNil(clipboard.errorMessage, "A successful retry must clear the earlier copy error")
        let type = UTType(filenameExtension: "bin")?.identifier ?? UTType.data.identifier
        XCTAssertEqual(UIPasteboard.general.data(forPasteboardType: type), bytes)
        XCTAssertTrue(clipboard.copied)
    }

}

private final class ClipboardCopyReadGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Clipboard file read started")
    let resume = DispatchSemaphore(value: 0)
    private let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    private let lock = NSLock()
    private var storedWasMainThread = true
    var wasMainThread: Bool { lock.withLock { storedWasMainThread } }
    func read(_ url: URL) throws -> Data {
        lock.withLock { storedWasMainThread = Thread.isMainThread }
        entered.fulfill()
        guard resume.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
        if fails { throw CocoaError(.fileReadUnknown) }
        return try Data(contentsOf: url)
    }
}
