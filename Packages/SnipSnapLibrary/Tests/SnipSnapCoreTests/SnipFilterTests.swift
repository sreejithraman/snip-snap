import XCTest
@testable import SnipSnapCore

final class SnipFilterTests: XCTestCase {
    func testOldestFirstKeepsPinsNewestFirstAndUsesDeterministicTies() throws {
        let older = Snip(id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                         createdAt: Date(timeIntervalSince1970: 10), content: "Older", origin: .quickEntry)
        let tie = Snip(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                       createdAt: older.createdAt, content: "Tie", origin: .quickEntry)
        let newer = Snip(createdAt: Date(timeIntervalSince1970: 20), content: "Newer", origin: .quickEntry)
        let olderDone = Snip(createdAt: older.createdAt, content: "Older Done", origin: .quickEntry, isDone: true)
        let newerDone = Snip(createdAt: newer.createdAt, content: "Newer Done", origin: .quickEntry, isDone: true)
        let olderPin = Snip(createdAt: older.createdAt, content: "Older pin", origin: .quickEntry,
                            pinnedAt: Date(timeIntervalSince1970: 100))
        let newerPin = Snip(createdAt: newer.createdAt, content: "Newer pin", origin: .quickEntry,
                            pinnedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(Snip.sorted([newerDone, newer, tie, olderPin, olderDone, older, newerPin], by: .oldestFirst),
                       [newerPin, olderPin, older, tie, newer, olderDone, newerDone])
        for mode in SnipSortMode.allCases {
            let sorted = Snip.sorted([newerDone, newer, tie, olderPin, olderDone, older, newerPin], by: mode)
            XCTAssertEqual(Array(sorted.prefix(2)), [newerPin, olderPin])
            XCTAssertEqual(Set(sorted[2..<5].map(\.id)), [older.id, tie.id, newer.id])
            XCTAssertEqual(Set(sorted[5...].map(\.id)), [olderDone.id, newerDone.id])
        }
        XCTAssertEqual(SnipSortMode.chronological.rawValue, "chronological")
        let encoded = try JSONEncoder().encode(SnipSortMode.oldestFirst)
        XCTAssertEqual(try JSONDecoder().decode(SnipSortMode.self, from: encoded), .oldestFirst)
    }

    func testDoneLimitKeepsNotDoneAndPinnedSnipsInTheirSortedPositions() {
        let pinned = Snip(content: "Pinned", origin: .quickEntry, pinnedAt: Date(timeIntervalSince1970: 1))
        let pending = Snip(content: "Not Done", origin: .quickEntry)
        let done = (1...12).map { Snip(content: "Done \($0)", origin: .agent, isDone: true) }
        let ordered = [pinned, done[0], pending] + Array(done.dropFirst())
        XCTAssertEqual(SnipDoneLimit.ten.apply(to: ordered), [pinned, done[0], pending] + Array(done[1..<10]))
    }

    func testDoneLimitCanBeUnlimitedAndSearchFindsEveryMatchingSnip() {
        let done = (1...12).map { Snip(content: "Matching \($0)", origin: .agent, isDone: true) }
        XCTAssertEqual(SnipDoneLimit.unlimited.apply(to: done), done)
        XCTAssertEqual(SnipDoneLimit.ten.apply(to: done, query: " Matching "), done)
        XCTAssertEqual(SnipDoneLimit.ten.apply(to: done, query: " \n "), Array(done.prefix(10)))
    }

    func testDoneLimitOnlyAppliesToAllStatus() {
        let done = (1...12).map { Snip(content: "Done \($0)", origin: .agent, isDone: true) }
        XCTAssertEqual(SnipDoneLimit.ten.apply(to: done, completionFilter: .all), Array(done.prefix(10)))
        XCTAssertEqual(SnipDoneLimit.ten.apply(to: done, completionFilter: .done), done)
        XCTAssertEqual(SnipDoneLimit.ten.apply(to: done, completionFilter: .notDone), done)
    }

    func testDoneLimitDefaultsToTenAndPersistsIncludingUnlimited() throws {
        let suite = "SnipDoneLimitTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SnipDoneLimit.load(from: defaults), .ten)
        for choice in SnipDoneLimit.allCases {
            choice.save(to: defaults)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(SnipDoneLimit.load(from: reopened), choice)
        }
    }

    func testHumanFilterIncludesEveryNonAgentOriginRegardlessOfContext() {
        let selection = Snip(content: "Selection", origin: .selection)
        let quickEntry = Snip(content: "Typed", origin: .quickEntry)
        let clipboard = Snip(content: "Clipboard", origin: .clipboard, pinnedAt: Date(timeIntervalSince1970: 1))
        let share = Snip(content: "Shared", origin: .share, source: SnipSource(
            applicationName: "Example", agentContext: SnipAgentContext(sessionTitle: "Retained context")
        ))
        let agent = Snip(content: "Agent without context", origin: .agent)
        let snips = [selection, agent, quickEntry, clipboard, share]
        XCTAssertEqual(
            SnipFilter.apply(snips: snips, query: "", completionFilter: .all, originFilter: .human),
            [selection, quickEntry, clipboard, share]
        )
    }

    func testAgentSnipsOnlyUsesOriginAndPreservesInputOrder() {
        let agentWithoutContext = Snip(content: "Agent without context", origin: .agent, pinnedAt: Date(timeIntervalSince1970: 1))
        let manualWithContext = Snip(
            content: "Manual with context", origin: .quickEntry,
            source: SnipSource(applicationName: "Example", agentContext: SnipAgentContext(sessionTitle: "Retained context"))
        )
        let agentWithContext = Snip(
            content: "Agent with context", origin: .agent,
            source: SnipSource(applicationName: "Example", agentContext: SnipAgentContext(sessionTitle: "Current work"))
        )
        let snips = [agentWithoutContext, manualWithContext, agentWithContext]

        XCTAssertEqual(
            SnipFilter.apply(snips: snips, query: "", completionFilter: .all),
            snips
        )
        XCTAssertEqual(
            SnipFilter.apply(snips: snips, query: "", completionFilter: .all, originFilter: .agent),
            [agentWithoutContext, agentWithContext]
        )
    }
    func testAgentSnipsOnlyCombinesWithCompletionAndQuery() {
        let agent = Snip(content: "Release review", origin: .agent)
        let done = Snip(content: "Release shipped", origin: .agent, isDone: true)
        let manual = Snip(content: "Release manual", origin: .quickEntry)
        let snips = [agent, manual, done]
        XCTAssertEqual(
            SnipFilter.apply(snips: snips, query: " Release ", completionFilter: .done, originFilter: .agent),
            [done]
        )
        XCTAssertEqual(
            SnipFilter.apply(snips: snips, query: "review", completionFilter: .notDone, originFilter: .agent),
            [agent]
        )
        XCTAssertTrue(SnipFilter.apply(snips: snips, query: "manual", completionFilter: .all, originFilter: .agent).isEmpty)
    }

    func testHumanFilterComposesWithCompletionQueryAndGlobalSearch() {
        let work = SnipList(id: UUID(), name: "Work", systemImage: "folder", position: 1)
        let manual = Snip(content: "Review typed", origin: .quickEntry)
        let done = Snip(content: "Review shared", origin: .share, listID: work.id, isDone: true)
        let agent = Snip(content: "Review agent", origin: .agent)
        let entry = ClipboardEntry(items: [], plainText: "Review clipboard")
        XCTAssertEqual(SnipFilter.apply(snips: [manual, agent, done], query: "Review", completionFilter: .done,
                                       originFilter: .human), [done])
        XCTAssertEqual(SnipFilter.apply(snips: [manual, agent, done], query: "typed", completionFilter: .notDone,
                                       originFilter: .human), [manual])
        let results = LibrarySearchResults(query: "Review", snips: [manual, agent, done], lists: [.inbox, work],
                                           clipboard: [entry], sortMode: .chronological, originFilter: .human,
                                           sourceLabel: { $0.origin.rawValue })
        XCTAssertEqual(results.lists.map(\.list.id), [SnipList.inboxID, work.id])
        XCTAssertEqual(results.lists.flatMap(\.snips), [manual, done])
        XCTAssertEqual(results.clipboard.map(\.id), [entry.id])
    }

    func testLibrarySearchKeepsAgentFilterAcrossListsWithoutFilteringClipboard() {
        let work = SnipList(id: UUID(), name: "Work", systemImage: "folder", position: 1)
        let manual = Snip(content: "Review manual", origin: .quickEntry)
        let agent = Snip(content: "Review agent", origin: .agent)
        let done = Snip(content: "Review done", origin: .agent, listID: work.id, isDone: true)
        let entry = ClipboardEntry(items: [], plainText: "Review clipboard")
        let results = LibrarySearchResults(
            query: "Review", snips: [manual, agent, done], lists: [.inbox, work],
            clipboard: [entry], sortMode: .chronological, originFilter: .agent,
            sourceLabel: { $0.origin.rawValue }
        )
        XCTAssertEqual(results.lists.map(\.list.id), [SnipList.inboxID, work.id])
        XCTAssertEqual(results.lists.flatMap(\.snips), [agent, done])
        XCTAssertEqual(results.clipboard.map(\.id), [entry.id])
    }

    func testDoneSnipsSortAfterActiveSnipsInBothModes() {
        let review = UUID()
        func card(_ id: Int, createdAt: TimeInterval, manualPosition: Int64, isDone: Bool = false) -> Snip {
            Snip(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
                requestID: UUID(),
                createdAt: Date(timeIntervalSince1970: createdAt),
                content: "Card \(id)",
                origin: .quickEntry,
                listID: review,
                isDone: isDone,
                manualPosition: manualPosition
            )
        }
        let olderActive = card(1, createdAt: 100, manualPosition: 1)
        let newerDone = card(2, createdAt: 200, manualPosition: 0, isDone: true)
        let newestActive = card(3, createdAt: 300, manualPosition: -1)

        XCTAssertEqual(
            Snip.sorted([olderActive, newerDone, newestActive], by: .chronological).map(\.id),
            [newestActive.id, olderActive.id, newerDone.id]
        )
        XCTAssertEqual(
            Snip.sorted([olderActive, newerDone, newestActive], by: .manual).map(\.id),
            [newestActive.id, olderActive.id, newerDone.id]
        )
    }

    func testFilteringSearchesContentAndSourceAndHonorsCompletionFilter() {
        let done = Snip(content: "Follow up tomorrow", origin: .quickEntry, isDone: true)
        let safari = Snip(
            content: "An unrelated excerpt",
            origin: .selection,
            source: SnipSource(applicationName: "Safari", windowTitle: "Swift guide", url: nil)
        )

        XCTAssertEqual(SnipFilter.apply(snips: [done, safari], query: "swift", completionFilter: .all), [safari])
        XCTAssertEqual(SnipFilter.apply(snips: [done, safari], query: "", completionFilter: .done), [done])
        XCTAssertEqual(SnipFilter.apply(snips: [done, safari], query: "", completionFilter: .notDone), [safari])
        XCTAssertTrue(SnipFilter.apply(snips: [done, safari], query: "swift", completionFilter: .done).isEmpty)
    }

    func testLargeSnipFilteringKeepsExactMatches() {
        let later = UUID()
        let snips = (0..<2_500).map { index in
            Snip(
                content: index.isMultiple(of: 250) ? "Needle \(index)" : "Item \(index)",
                origin: .quickEntry,
                listID: index.isMultiple(of: 2) ? SnipList.inboxID : later
            )
        }
        let matches = SnipFilter.apply(snips: snips, query: "needle", completionFilter: .all)
        XCTAssertEqual(matches.map(\.content), stride(from: 0, to: 2_500, by: 250).map { "Needle \($0)" })
    }
}
