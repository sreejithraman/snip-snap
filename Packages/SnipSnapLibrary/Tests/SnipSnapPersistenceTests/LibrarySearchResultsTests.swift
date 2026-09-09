import Foundation
import XCTest
import SnipSnapCore

final class LibrarySearchResultsTests: XCTestCase {
    private let reading = SnipList(id: UUID(), name: "Reading", systemImage: "book", position: 1)

    func testSearchIncludesEveryListDoneSnipsAndClipboard() {
        let inboxSnip = Snip(content: "Alpha inbox", origin: .quickEntry)
        var doneSnip = Snip(content: "Alpha reading", origin: .quickEntry, listID: reading.id)
        doneSnip.isDone = true
        let entry = ClipboardEntry(items: [], plainText: "Alpha clipboard")
        let results = search("  ALPHA \n", snips: [doneSnip, inboxSnip], clipboard: [entry])
        XCTAssertEqual(results.lists.map(\.id), [SnipList.inboxID, reading.id])
        XCTAssertEqual(results.lists.flatMap(\.snips).map(\.id), [inboxSnip.id, doneSnip.id])
        XCTAssertEqual(results.clipboard.map(\.id), [entry.id])
        XCTAssertEqual(results.count, 3)
    }

    func testListNameSearchAndEmptySections() {
        let snip = Snip(content: "Saved article", origin: .quickEntry, listID: reading.id)
        let other = Snip(content: "Unrelated", origin: .quickEntry)
        let results = search("reading", snips: [other, snip])
        XCTAssertEqual(results.lists.map(\.id), [reading.id])
        XCTAssertEqual(results.lists[0].snips.map(\.id), [snip.id])
        XCTAssertTrue(results.clipboard.isEmpty)
    }

    func testBlankAndNoMatchesHaveNoSections() {
        let snip = Snip(content: "Alpha", origin: .quickEntry)
        let entry = ClipboardEntry(items: [], plainText: "Alpha")
        XCTAssertTrue(search(" \n", snips: [snip], clipboard: [entry]).isEmpty)
        XCTAssertTrue(search("missing", snips: [snip], clipboard: [entry]).isEmpty)
    }

    private func search(_ query: String, snips: [Snip], clipboard: [ClipboardEntry] = []) -> LibrarySearchResults {
        LibrarySearchResults(query: query, snips: snips, lists: [.inbox, reading], clipboard: clipboard,
                             sortMode: .chronological, sourceLabel: { $0.origin.rawValue })
    }
}
