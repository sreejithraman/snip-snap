import XCTest
@testable import SnipSnapCore

final class SnipFilterTests: XCTestCase {
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

}
