import Foundation
import SnipSnapCore
import XCTest

final class SnipCLIClipboardActionTests: XCTestCase {
    func testQueryFiltersBeforeLimitingAndPreservesPinnedOrder() {
        let oldPin = entry("meeting older pin", at: 1, pinnedAt: 10)
        let newPin = entry("meeting newest pin", at: 2, pinnedAt: 20)
        let old = entry("meeting old", at: 3)
        let new = entry("meeting new", at: 4)
        let unrelated = entry("Other work", at: 5)
        let entries = [old, unrelated, newPin, new, oldPin]

        XCTAssertEqual(SnipCLIClipboardQuery(search: "MEETING", newestFirst: false, limit: 3)
            .apply(to: entries).map(\.text), ["meeting newest pin", "meeting older pin", "meeting old"])
        XCTAssertEqual(SnipCLIClipboardQuery(search: "meeting", onlyPinned: true, limit: 1)
            .apply(to: entries).map(\.id), [newPin.id])
    }

    func testRevisionsDetectEntryEditsAndHistoryMembershipAndPauseChanges() {
        let first = entry("Text", at: 1)
        var edited = first
        edited.pinnedAt = Date(timeIntervalSinceReferenceDate: 2)
        XCTAssertNotEqual(SnipCLIClipboardRevision.token(entry: first), SnipCLIClipboardRevision.token(entry: edited))
        let initial = SnipCLIClipboardRevision.token(entries: [first], isPaused: false)
        XCTAssertNotEqual(initial, SnipCLIClipboardRevision.token(entries: [edited], isPaused: false))
        XCTAssertNotEqual(initial, SnipCLIClipboardRevision.token(entries: [first], isPaused: true))
        XCTAssertNotEqual(initial, SnipCLIClipboardRevision.token(entries: [], isPaused: false))
        let second = entry("Second", at: 2)
        XCTAssertEqual(SnipCLIClipboardRevision.token(entries: [first, second], isPaused: false),
                       SnipCLIClipboardRevision.token(entries: [second, first], isPaused: false))
    }

    func testCompactedActionsRemoveContentAndSelectorsAndRemainDecodable() throws {
        let id = UUID()
        let revision = String(repeating: "a", count: 64)
        let actions: [SnipCLIClipboardAction] = [
            .list(.init(search: "private query")), .show(id: id),
            .save(id: id, list: "Private list", expectedRevision: revision),
            .restore(id: id, expectedRevision: revision),
            .setPinned(id: id, pinned: true, expectedRevision: revision),
            .delete(id: id, expectedRevision: revision),
            .setPaused(paused: true, expectedRevision: revision),
            .clear(expectedRevision: revision)
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action.compacted)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            for secret in ["private query", "Private list", id.uuidString, revision] {
                XCTAssertFalse(text.contains(secret))
            }
            XCTAssertEqual(try JSONDecoder().decode(SnipCLIClipboardAction.self, from: data), action.compacted)
        }
    }

    func testReadsUseTransientReceiptsAndMutationsRemoveTypedResultsWhenCompacted() throws {
        let entry = entry("Private clipboard content", at: 1)
        XCTAssertEqual(SnipCLIAction.extended(.clipboard(.show(id: entry.id))).receiptPolicy, .transientRead)
        let request = SnipCLIRequest(action: .extended(.clipboard(.save(
            id: entry.id, list: "Private list", expectedRevision: SnipCLIClipboardRevision.token(entry: entry)
        ))))
        XCTAssertNotEqual(request.action.receiptPolicy, .transientRead)
        let receipt = SnipCLIReceipt(request: request, status: .success, extendedResult: .clipboard(.init(
            entries: [.init(entry)], status: .init(entries: [entry], isPaused: false)
        )))
        let compacted = receipt.compacted()
        XCTAssertNil(compacted.extendedResult)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(compacted), encoding: .utf8))
        XCTAssertFalse(encoded.contains("Private clipboard content"))
        XCTAssertFalse(encoded.contains("Private list"))
    }

    private func entry(_ text: String, at time: TimeInterval, pinnedAt pin: TimeInterval? = nil) -> ClipboardEntry {
        ClipboardEntry(capturedAt: Date(timeIntervalSinceReferenceDate: time), items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data(text.utf8))
        ])], pinnedAt: pin.map(Date.init(timeIntervalSinceReferenceDate:)))
    }
}
