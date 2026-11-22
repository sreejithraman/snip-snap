import SnipSnapCore
import SwiftUI
import UIKit
import XCTest
@testable import SnipSnapiOS

final class LibraryRailArrowKeyTests: XCTestCase {
    func testArrowKeysStepThroughPagesAndStopAtTheEnds() {
        let work = UUID()
        let pages: [LibraryPage] = [.clipboard, .list(SnipList.inboxID), .list(work)]
        XCTAssertEqual(pages.page(1, from: .clipboard), .list(SnipList.inboxID))
        XCTAssertEqual(pages.page(1, from: .list(SnipList.inboxID)), .list(work))
        XCTAssertEqual(pages.page(-1, from: .list(SnipList.inboxID)), .clipboard)
        XCTAssertNil(pages.page(1, from: .list(work)))
        XCTAssertNil(pages.page(-1, from: .clipboard))
        XCTAssertNil(pages.page(1, from: .list(UUID())))
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

    func testReleaseAtTheFlatMaximumKeepsAHingeChoice() {
        XCTAssertEqual(flat.outcome(predictedWidth: 320, travel: 20, current: .expanded(.hinge)), .expanded(.hinge))
        XCTAssertEqual(flat.outcome(predictedWidth: 500, travel: 60, current: .expanded(.hinge)), .expanded(.hinge))
        XCTAssertEqual(flat.outcome(predictedWidth: 280, travel: -40, current: .expanded(.hinge)), .expanded(.points(280)))
        XCTAssertEqual(flat.outcome(predictedWidth: 500, travel: 60, current: .expanded(.points(250))), .expanded(.points(320)))
    }

    func testATinyDragChangesNothing() {
        XCTAssertEqual(flat.outcome(predictedWidth: 400, travel: 4, current: .rail), .rail)
        XCTAssertEqual(flat.outcome(predictedWidth: 100, travel: -4, current: .expanded(.points(250))), .expanded(.points(250)))
        XCTAssertEqual(flat.outcome(predictedWidth: 400, travel: 4.5, current: .rail), .expanded(.points(320)))
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

    func testIPadStartsWithNamesInAWiderColumnThanThePhone() {
        XCTAssertFalse(LibrarySidebarDefaults.phone.showsNames)
        XCTAssertTrue(LibrarySidebarDefaults.pad.showsNames)
        func maximum(_ defaults: LibrarySidebarDefaults, width: CGFloat) -> CGFloat {
            LibrarySidebarSizing(containerWidth: width, hingeEdge: nil, flatMaximumWidth: defaults.flatMaximumWidth)
                .maximumExpandedWidth
        }
        // 11" iPad portrait and landscape, then 13" portrait and landscape.
        XCTAssertEqual(maximum(.pad, width: 834), 333.6, accuracy: 0.01)
        XCTAssertEqual(maximum(.pad, width: 1210), 360)
        XCTAssertEqual(maximum(.pad, width: 1032), 360)
        XCTAssertEqual(maximum(.pad, width: 1376), 360)
        // The open Duo keeps its cap.
        XCTAssertEqual(maximum(.phone, width: 951), 320)
        let padDefault = LibrarySidebarSizing(containerWidth: 1210, hingeEdge: nil, flatMaximumWidth: 360)
            .width(isExpanded: true, expandedWidth: LibrarySidebarDefaults.pad.expandedWidth)
        XCTAssertEqual(padDefault, 300)
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

    func testDragDetentTracksRailExpandedAndHingeZones() {
        XCTAssertEqual(flat.dragDetent(at: 80), .rail)
        XCTAssertEqual(flat.dragDetent(at: 139.9), .rail)
        XCTAssertEqual(flat.dragDetent(at: 140), .expanded)
        XCTAssertEqual(flat.dragDetent(at: 320), .expanded)
        XCTAssertEqual(book.dragDetent(at: 347), .expanded)
        XCTAssertEqual(book.dragDetent(at: 348), .hinge)
        XCTAssertEqual(book.dragDetent(at: 380), .hinge)
    }
}

@MainActor
final class LibrarySidebarPanObserverTests: XCTestCase {
    func testHitRectCoversEntireSidebarPlusTrailingSeam() {
        let frame = CGRect(x: 0, y: 0, width: 80, height: 669)
        let ltr = LibrarySidebarPanObserver.Coordinator.hitRect(
            for: frame, layoutDirection: .leftToRight, seamOverhang: 16
        )
        XCTAssertEqual(ltr, CGRect(x: 0, y: 0, width: 96, height: 669))

        let rtl = LibrarySidebarPanObserver.Coordinator.hitRect(
            for: CGRect(x: 720, y: 0, width: 80, height: 669),
            layoutDirection: .rightToLeft,
            seamOverhang: 16
        )
        XCTAssertEqual(rtl, CGRect(x: 704, y: 0, width: 96, height: 669))

        XCTAssertTrue(
            LibrarySidebarPanObserver.Coordinator.hitRect(
                for: .zero, layoutDirection: .leftToRight, seamOverhang: 16
            ).isNull
        )
    }

    func testOnlyStrictlyHorizontalMovementBeginsSidebarPan() {
        XCTAssertTrue(LibrarySidebarPanObserver.Coordinator.isHorizontalMovement(CGPoint(x: 12, y: 4)))
        XCTAssertTrue(LibrarySidebarPanObserver.Coordinator.isHorizontalMovement(CGPoint(x: -12, y: 11)))
        XCTAssertFalse(LibrarySidebarPanObserver.Coordinator.isHorizontalMovement(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(LibrarySidebarPanObserver.Coordinator.isHorizontalMovement(CGPoint(x: 4, y: 18)))
        XCTAssertFalse(LibrarySidebarPanObserver.Coordinator.isHorizontalMovement(.zero))
    }

    func testSidebarPanBlocksScrollAndRowTapsOnceRecognized() {
        let coordinator = LibrarySidebarPanObserver.Coordinator(
            layoutDirection: .leftToRight,
            canBegin: { true },
            onPan: { _, _, _ in }
        )
        let sidebarPan = UIPanGestureRecognizer()
        let scrollView = UIScrollView()
        let scrollPan = scrollView.panGestureRecognizer
        let tap = UITapGestureRecognizer()
        let delegate: UIGestureRecognizerDelegate = coordinator

        XCTAssertFalse(coordinator.gestureRecognizer(sidebarPan, shouldRecognizeSimultaneouslyWith: scrollPan))
        XCTAssertFalse(coordinator.gestureRecognizer(sidebarPan, shouldRecognizeSimultaneouslyWith: tap))
        XCTAssertTrue(delegate.gestureRecognizer?(sidebarPan, shouldBeRequiredToFailBy: scrollPan) == true)
        XCTAssertFalse(delegate.gestureRecognizer?(sidebarPan, shouldBeRequiredToFailBy: tap) == true)
    }

    func testTouchesOutsideRootViewHierarchyAreIgnored() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let rootView = UIView(frame: window.bounds)
        let sidebarRow = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 56))
        let contextMenuOverlay = UIView(frame: window.bounds)
        rootView.addSubview(sidebarRow)
        window.addSubview(rootView)
        window.addSubview(contextMenuOverlay)

        XCTAssertTrue(LibrarySidebarPanObserver.Coordinator.isTouchInRootHierarchy(rootView, rootView: rootView))
        XCTAssertTrue(LibrarySidebarPanObserver.Coordinator.isTouchInRootHierarchy(sidebarRow, rootView: rootView))
        XCTAssertFalse(LibrarySidebarPanObserver.Coordinator.isTouchInRootHierarchy(contextMenuOverlay, rootView: rootView))
        XCTAssertFalse(LibrarySidebarPanObserver.Coordinator.isTouchInRootHierarchy(nil, rootView: rootView))
        XCTAssertFalse(LibrarySidebarPanObserver.Coordinator.isTouchInRootHierarchy(sidebarRow, rootView: nil))
    }
}
