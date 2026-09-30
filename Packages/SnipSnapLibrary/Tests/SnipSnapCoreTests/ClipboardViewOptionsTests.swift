import Foundation
import XCTest
import SnipSnapCore

final class ClipboardViewOptionsTests: XCTestCase {
    func testPinnedFilterHidesUnpinnedEntriesWithoutChangingPinOrder() {
        let unpinned = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 40), items: [])
        let firstPin = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 30), items: [], pinnedAt: Date(timeIntervalSince1970: 20))
        let lastPin = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 20), items: [], pinnedAt: Date(timeIntervalSince1970: 30))

        XCTAssertEqual(
            ClipboardViewOptions(onlyPinned: true).apply(to: [firstPin, unpinned, lastPin]).map(\.id),
            [lastPin.id, firstPin.id]
        )
    }

    func testSortDirectionKeepsPinsAtTheTopInPinOrder() {
        let oldest = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 10), items: [])
        let newest = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 40), items: [])
        let firstPin = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 30), items: [], pinnedAt: Date(timeIntervalSince1970: 20))
        let lastPin = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 20), items: [], pinnedAt: Date(timeIntervalSince1970: 30))
        let entries = [newest, firstPin, oldest, lastPin]

        XCTAssertEqual(
            ClipboardViewOptions(newestFirst: true).apply(to: entries).map(\.id),
            [lastPin.id, firstPin.id, newest.id, oldest.id]
        )
        XCTAssertEqual(
            ClipboardViewOptions(newestFirst: false).apply(to: entries).map(\.id),
            [lastPin.id, firstPin.id, oldest.id, newest.id]
        )
    }
}
