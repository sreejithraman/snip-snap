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

final class LibrarySidebarSizingTests: XCTestCase {
    private let flat = LibrarySidebarSizing(containerWidth: 1000, hingeEdge: nil)
    /// A book pose with the hinge's leading edge 380 pt into the container.
    private let book = LibrarySidebarSizing(containerWidth: 800, hingeEdge: 380)

    func testReleaseBelowTheThresholdSnapsToTheRail() {
        XCTAssertEqual(flat.outcome(predictedWidth: 20), .rail)
        XCTAssertEqual(flat.outcome(predictedWidth: 139.9), .rail)
        XCTAssertEqual(flat.outcome(predictedWidth: 140), .expanded(.points(200)))
    }

    func testReleaseBetweenTheThresholdAndTheMinimumSettlesAtTheMinimum() {
        XCTAssertEqual(flat.outcome(predictedWidth: 170), .expanded(.points(200)))
        XCTAssertEqual(flat.outcome(predictedWidth: 199), .expanded(.points(200)))
        XCTAssertEqual(flat.outcome(predictedWidth: 250), .expanded(.points(250)))
    }

    func testFlatMaximumIsTheSmallerOfTheCapAndAShareOfTheContainer() {
        XCTAssertEqual(flat.maximumExpandedWidth, 320)
        XCTAssertEqual(LibrarySidebarSizing(containerWidth: 600, hingeEdge: nil).maximumExpandedWidth, 240)
        XCTAssertEqual(LibrarySidebarSizing(containerWidth: 300, hingeEdge: nil).maximumExpandedWidth, 200)
        XCTAssertEqual(flat.outcome(predictedWidth: 900), .expanded(.points(320)))
    }

    func testBookPoseLetsTheSidebarReachTheHingeAndSnapsNearIt() {
        XCTAssertEqual(book.maximumExpandedWidth, 380)
        XCTAssertEqual(book.outcome(predictedWidth: 347), .expanded(.points(347)))
        XCTAssertEqual(book.outcome(predictedWidth: 348), .expanded(.hinge))
        XCTAssertEqual(book.outcome(predictedWidth: 600), .expanded(.hinge))
        XCTAssertEqual(flat.outcome(predictedWidth: 318), .expanded(.points(318)))
    }

    func testHingeWidthShowsAtTheHingeInBookPoseAndAtTheFlatMaximumWhenFlat() {
        XCTAssertEqual(book.width(isExpanded: true, expandedWidth: .hinge), 380)
        XCTAssertEqual(flat.width(isExpanded: true, expandedWidth: .hinge), 320)
        XCTAssertEqual(book.width(isExpanded: false, expandedWidth: .hinge), 80)
    }

    func testTheSameDragTravelFollowsTheCurrentMaximum() {
        // The view resolves a drag's travel against whichever sizing is current, as after a fold mid-drag.
        let proposed = LibrarySidebarSizing.railWidth + 270
        XCTAssertEqual(book.dragWidth(proposed), 350)
        let flatWidth = flat.dragWidth(proposed)
        XCTAssertGreaterThan(flatWidth, 320)
        XCTAssertLessThan(flatWidth, 320 + LibrarySidebarSizing.rubberBandReach)
    }

    func testStoredWidthShowsClampedToTheCurrentRange() {
        XCTAssertEqual(LibrarySidebarSizing(containerWidth: 600, hingeEdge: nil).width(isExpanded: true, expandedWidth: .points(300)), 240)
        XCTAssertEqual(flat.width(isExpanded: true, expandedWidth: .points(300)), 300)
        XCTAssertEqual(flat.width(isExpanded: true, expandedWidth: .points(120)), 200)
    }

    func testDragFollowsTheFingerInsideTheRangeAndResistsPastIt() {
        XCTAssertEqual(flat.dragWidth(150), 150)
        XCTAssertEqual(flat.dragWidth(320), 320)
        let pastMaximum = flat.dragWidth(420)
        XCTAssertGreaterThan(pastMaximum, 320)
        XCTAssertLessThan(pastMaximum, 320 + LibrarySidebarSizing.rubberBandReach)
        XCTAssertGreaterThan(flat.dragWidth(1000), pastMaximum)
        let pastRail = flat.dragWidth(0)
        XCTAssertLessThan(pastRail, 80)
        XCTAssertGreaterThan(pastRail, 80 - LibrarySidebarSizing.rubberBandReach)
    }

    func testNamesFadeInBetweenTheRailAndTheMinimumWidth() {
        XCTAssertEqual(LibrarySidebarSizing.nameOpacity(at: 60), 0)
        XCTAssertEqual(LibrarySidebarSizing.nameOpacity(at: 80), 0)
        XCTAssertEqual(LibrarySidebarSizing.nameOpacity(at: 140), 0.5, accuracy: 0.001)
        XCTAssertEqual(LibrarySidebarSizing.nameOpacity(at: 200), 1)
        XCTAssertEqual(LibrarySidebarSizing.nameOpacity(at: 300), 1)
    }

    func testOnlyAVerticalBandInsideTheContainerCountsAsAHinge() {
        let hinge = CGRect(x: 380, y: 0, width: 40, height: 900)
        XCTAssertEqual(LibrarySidebarSizing(containerWidth: 800, divisions: [hinge]).hingeEdge, 380)
        let tableBand = CGRect(x: 0, y: 430, width: 800, height: 40)
        XCTAssertNil(LibrarySidebarSizing(containerWidth: 800, divisions: [tableBand]).hingeEdge)
        let outside = CGRect(x: 800, y: 0, width: 40, height: 900)
        XCTAssertNil(LibrarySidebarSizing(containerWidth: 800, divisions: [outside]).hingeEdge)
        XCTAssertNil(LibrarySidebarSizing(containerWidth: 800, divisions: []).hingeEdge)
    }

    func testExpandedWidthRoundTripsAndRejectsJunk() {
        for width in [LibrarySidebarExpandedWidth.hinge, .points(256)] {
            XCTAssertEqual(LibrarySidebarExpandedWidth(rawValue: width.rawValue), width)
        }
        XCTAssertEqual(LibrarySidebarExpandedWidth.points(255.6).rawValue, "256")
        for junk in ["", "wide", "nan", "inf", "-40", "0", "Hinge"] {
            XCTAssertNil(LibrarySidebarExpandedWidth(rawValue: junk), junk)
        }
        XCTAssertEqual(LibrarySidebarExpandedWidth.default, .points(240))
    }
}
