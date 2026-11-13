import XCTest
@testable import SnipSnapiOS

final class LibraryRailTests: XCTestCase {
    func testDefaultIconListsShowInitialsOfUpToTwoWords() {
        XCTAssertEqual(RailListMark(name: "Groceries", systemImage: ListIconSymbol.defaultName, policy: .letterBadgeForDefaultIcon), .letters("G"))
        XCTAssertEqual(RailListMark(name: "reading list", systemImage: ListIconSymbol.defaultName, policy: .letterBadgeForDefaultIcon), .letters("RL"))
        XCTAssertEqual(RailListMark(name: "Work  plans for May", systemImage: "circle.grid.2x2.fill", policy: .letterBadgeForDefaultIcon), .letters("WP"))
    }

    func testInitialsSkipLeadingSymbolsAndFallBackToTheIcon() {
        XCTAssertEqual(RailListMark(name: "#launch 2026", systemImage: ListIconSymbol.defaultName, policy: .letterBadgeForDefaultIcon), .letters("L2"))
        XCTAssertEqual(RailListMark(name: "🚀 ✨", systemImage: ListIconSymbol.defaultName, policy: .letterBadgeForDefaultIcon), .icon(ListIconSymbol.defaultName))
    }

    func testCustomIconsStayIcons() {
        XCTAssertEqual(RailListMark(name: "Travel", systemImage: "airplane", policy: .letterBadgeForDefaultIcon), .icon("airplane"))
        XCTAssertEqual(RailListMark(name: "Inbox", systemImage: "tray.fill", policy: .letterBadgeForDefaultIcon), .icon("tray.fill"))
    }

    func testIconOnlyPolicyNeverShowsLetters() {
        XCTAssertEqual(RailListMark(name: "Groceries", systemImage: ListIconSymbol.defaultName, policy: .iconOnly), .icon(ListIconSymbol.defaultName))
    }
}
