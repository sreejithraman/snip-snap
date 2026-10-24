import AppKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnap

final class AppModelCLIClipboardTests: StoreBackedTestCase {
    @MainActor
    func testSaveUsesSpecifiedListAndLeavesHistoryAndActiveListUnchanged() async throws {
        let entry = clipboardEntry("Keep for research")
        let context = try await makeContext(entries: [entry])
        let created = try await context.model.handleCLIRequest(.init(action: .createList(name: "Research")))
        let list = try XCTUnwrap(created.lists.first)
        let activeListID = context.model.activeListID

        let receipt = try await context.model.handleCLIRequest(request(.save(
            id: entry.id, list: list.id.uuidString,
            expectedRevision: SnipCLIClipboardRevision.token(entry: entry)
        )))

        XCTAssertEqual(receipt.snips.map(\.content), ["Keep for research"])
        XCTAssertEqual(receipt.snips.map(\.listID), [list.id])
        XCTAssertEqual(receipt.snips.map(\.origin), [.clipboard])
        XCTAssertEqual(context.model.activeListID, activeListID)
        XCTAssertEqual(context.history.entries, [entry])
    }

    @MainActor
    func testShowWaitsForInitialLoadAndReturnsRevisionAndContent() async throws {
        let entry = clipboardEntry("Already persisted")
        let context = try await makeContext(entries: [entry])
        let receipt = try await context.model.handleCLIRequest(request(.show(id: entry.id)))
        guard case .clipboard(let result) = receipt.extendedResult else {
            return XCTFail("Expected typed clipboard result")
        }
        XCTAssertEqual(result.entries.first?.text, "Already persisted")
        XCTAssertEqual(result.entries.first?.revision, SnipCLIClipboardRevision.token(entry: entry))
        XCTAssertEqual(result.status.entryCount, 1)
        XCTAssertTrue(receipt.snips.isEmpty)
    }

    @MainActor
    func testRestoreWritesEntryToClipboardAndWaitsForPersistence() async throws {
        let entry = clipboardEntry("Restore this")
        let context = try await makeContext(entries: [entry])

        _ = try await context.model.handleCLIRequest(request(.restore(
            id: entry.id, expectedRevision: SnipCLIClipboardRevision.token(entry: entry)
        )))

        XCTAssertEqual(context.pasteboard.string(forType: .string), "Restore this")
        let stored = try await context.history.sharedStore.load()
        XCTAssertEqual(stored.entries, context.history.entries)
        XCTAssertGreaterThan(try XCTUnwrap(stored.entries.first).capturedAt, entry.capturedAt)
    }

    @MainActor
    func testPauseAndResumeRequireLatestStatusRevision() async throws {
        let context = try await makeContext(entries: [])
        let initial = SnipCLIClipboardRevision.token(entries: [], isPaused: false)
        _ = try await context.model.handleCLIRequest(request(.setPaused(paused: true, expectedRevision: initial)))
        XCTAssertTrue(context.history.isPaused)

        do {
            _ = try await context.model.handleCLIRequest(request(.setPaused(paused: false, expectedRevision: initial)))
            XCTFail("A stale pause state must not overwrite the current choice")
        } catch SnipCLIClipboardError.historyChanged {}

        let paused = SnipCLIClipboardRevision.token(entries: [], isPaused: true)
        _ = try await context.model.handleCLIRequest(request(.setPaused(paused: false, expectedRevision: paused)))
        XCTAssertFalse(context.history.isPaused)
    }

    @MainActor
    func testStaleSaveAndDeleteReturnPreciseErrors() async throws {
        let entry = clipboardEntry("Changed pin")
        let context = try await makeContext(entries: [entry])
        let stale = SnipCLIClipboardRevision.token(entry: entry)
        _ = try await context.model.handleCLIRequest(request(.setPinned(id: entry.id, pinned: true, expectedRevision: stale)))
        for action: SnipCLIClipboardAction in [
            .save(id: entry.id, list: "Inbox", expectedRevision: stale),
            .delete(id: entry.id, expectedRevision: stale)
        ] {
            do {
                _ = try await context.model.handleCLIRequest(request(action))
                XCTFail("Stale clipboard changes must fail without being marked uncertain")
            } catch SnipCLIClipboardError.entryChanged {}
        }
        XCTAssertTrue(context.model.snips.isEmpty)
        XCTAssertEqual(context.history.entries.map(\.id), [entry.id])
    }

    @MainActor
    private func makeContext(entries: [ClipboardEntry]) async throws
        -> (model: AppModel, history: ClipboardHistory, pasteboard: NSPasteboard) {
        let clipboardURL = try storeURL().deletingLastPathComponent().appendingPathComponent("clipboard.json")
        try await ClipboardHistoryStore(url: clipboardURL).save(.init(entries: entries))
        let pasteboard = NSPasteboard(name: .init("SnipSnap.CLIClipboardTests.\(UUID())"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        let history = ClipboardHistory(pasteboard: pasteboard, defaults: defaults(), storeURL: clipboardURL)
        let model = AppModel(library: try JSONSnipLibrary(fileURL: storeURL()), defaults: defaults(), clipboardHistory: history)
        return (model, history, pasteboard)
    }

    private func clipboardEntry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(capturedAt: Date(timeIntervalSinceReferenceDate: 100), items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data(text.utf8))
        ])])
    }

    private func request(_ action: SnipCLIClipboardAction) -> SnipCLIRequest {
        SnipCLIRequest(action: .extended(.clipboard(action)))
    }
}
