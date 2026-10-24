import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

final class ClipboardCLIStoreTests: XCTestCase {
    func testGuardedClearPreservesPinnedEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(url: directory.appendingPathComponent("clipboard.json"))
        let pinned = entry("Keep", pinned: true)
        let temporary = entry("Clear")
        try await store.save(ClipboardHistoryState(entries: [pinned, temporary]))
        let revision = SnipCLIClipboardRevision.token(entries: [pinned, temporary], isPaused: false)

        let cleared = try await store.performCLI(.clear(expectedRevision: revision), isPaused: false)

        XCTAssertEqual(cleared.entries.map(\.id), [pinned.id])
        let stored = try await store.load()
        XCTAssertEqual(stored.entries.map(\.id), [pinned.id])
    }

    func testDeleteRejectsChangedAndMissingEntriesWithoutDeletingCurrentHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(url: directory.appendingPathComponent("clipboard.json"))
        let original = entry("Keep this")
        try await store.save(ClipboardHistoryState(entries: [original]))
        let revision = SnipCLIClipboardRevision.token(entry: original)
        _ = try await store.setPinned(true, id: original.id)

        do {
            _ = try await store.performCLI(.delete(id: original.id, expectedRevision: revision), isPaused: false)
            XCTFail("A stale delete must leave the changed entry intact")
        } catch SnipCLIClipboardError.entryChanged {}
        do {
            _ = try await store.performCLI(.delete(id: UUID(), expectedRevision: revision), isPaused: false)
            XCTFail("A missing ID must not be treated as a successful deletion")
        } catch SnipCLIClipboardError.entryNotFound {}

        let stored = try await store.load()
        XCTAssertEqual(stored.entries.map(\.id), [original.id])
        XCTAssertTrue(try XCTUnwrap(stored.entries.first).isPinned)
        XCTAssertTrue(stored.tombstones.isEmpty)
    }

    func testClearRejectsEntriesCapturedAfterStatusWasRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(url: directory.appendingPathComponent("clipboard.json"))
        let first = entry("First")
        try await store.save(ClipboardHistoryState(entries: [first]))
        let revision = SnipCLIClipboardRevision.token(entries: [first], isPaused: false)
        let second = entry("New capture")
        _ = try await store.insert(second)

        do {
            _ = try await store.performCLI(.clear(expectedRevision: revision), isPaused: false)
            XCTFail("Clear must not remove entries the caller has not inspected")
        } catch SnipCLIClipboardError.historyChanged {}

        let stored = try await store.load()
        XCTAssertEqual(Set(stored.entries.map(\.id)), [first.id, second.id])
    }

    func testPinUsesExplicitStateAndRejectsStaleWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(url: directory.appendingPathComponent("clipboard.json"))
        let original = entry("Reusable")
        try await store.save(.init(entries: [original]))
        let revision = SnipCLIClipboardRevision.token(entry: original)
        let pinned = try await store.performCLI(.setPinned(id: original.id, pinned: true, expectedRevision: revision), isPaused: false)
        let current = try XCTUnwrap(pinned.entries.first)
        XCTAssertTrue(current.isPinned)
        do {
            _ = try await store.performCLI(.setPinned(id: original.id, pinned: false, expectedRevision: revision), isPaused: false)
            XCTFail("A stale pin command must not overwrite the current state")
        } catch SnipCLIClipboardError.entryChanged {}
        let unchanged = try await store.performCLI(.setPinned(
            id: original.id, pinned: true, expectedRevision: SnipCLIClipboardRevision.token(entry: current)
        ), isPaused: false)
        XCTAssertEqual(unchanged.entries, [current])
        let unpinned = try await store.performCLI(.setPinned(
            id: original.id, pinned: false, expectedRevision: SnipCLIClipboardRevision.token(entry: current)
        ), isPaused: false)
        XCTAssertFalse(try XCTUnwrap(unpinned.entries.first).isPinned)
    }

    private func entry(_ text: String, pinned: Bool = false) -> ClipboardEntry {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        return ClipboardEntry(capturedAt: date, items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data(text.utf8))
        ])], pinnedAt: pinned ? date : nil)
    }
}
