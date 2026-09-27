import SnipSnapCore
import SwiftUI
import UIKit
import XCTest
@testable import SnipSnapiOS

@MainActor
final class ListPageGestureTests: XCTestCase {
    func testBackCueClearsThePageEdgeWhileStretching() {
        for progress: CGFloat in [0.45, 1] {
            let halfWidth = (ListAddCueLayout.diameter
                + ListEdgeCueLayout.stretch(progress: progress))
                * (progress == 1 ? ListAddCueLayout.armedScale : 1) / 2
            let leftToRightX = ListEdgeCueLayout.centerX(
                for: .cancel, in: 400, progress: progress,
                layoutDirection: .leftToRight
            )
            let rightToLeftX = ListEdgeCueLayout.centerX(
                for: .cancel, in: 400, progress: progress,
                layoutDirection: .rightToLeft
            )
            XCTAssertLessThanOrEqual(leftToRightX + halfWidth, -8)
            XCTAssertGreaterThanOrEqual(rightToLeftX - halfWidth, 408)
        }
    }

    func testPagePanOwnsScrollingAfterHorizontalRecognition() {
        let coordinator = ListPagePanObserver.Coordinator(canBegin: { _ in true }, onPan: { _, _, _, _ in })
        let pagePan = UIPanGestureRecognizer()
        let list = UIScrollView()
        let listPan = list.panGestureRecognizer
        let delegate: UIGestureRecognizerDelegate = coordinator

        XCTAssertFalse(coordinator.gestureRecognizer(pagePan, shouldRecognizeSimultaneouslyWith: listPan))
        XCTAssertTrue(delegate.gestureRecognizer?(pagePan, shouldBeRequiredToFailBy: listPan) == true)
        XCTAssertTrue(coordinator.gestureRecognizer(pagePan, shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()))
    }

    func testPageSwipeTracksOnePageAndSelectsAdjacentList() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updatePageDrag(
            translation: CGSize(width: -80, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: now).position, 1.2, accuracy: 0.001)
        XCTAssertEqual(
            motion.releasePageDrag(
                translation: CGSize(width: -80, height: 0),
                predictedEndTranslation: CGSize(width: -100, height: 0),
                reduceMotion: false, at: now
            ), .select(2)
        )
        XCTAssertFalse(motion.isDragging)
        XCTAssertEqual(motion.transition?.settlement?.destination, 2)
        motion.cancelPageDrag(reduceMotion: false, at: now)
        XCTAssertEqual(motion.transition?.settlement?.destination, 2)
    }

    func testPageSwipeCancelsAndClampsAtPageBoundary() throws {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updatePageDrag(
            translation: CGSize(width: -600, height: 0), selectedPage: pages[0], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[0], at: now).position, 1)
        motion.cancelPageDrag(reduceMotion: false, at: now)
        XCTAssertEqual(motion.transition?.settlement?.destination, 0)
        XCTAssertEqual(motion.transition?.settlement?.curve, .easeOut)
        let settlement = try XCTUnwrap(motion.transition?.settlement)
        motion.finishSettlement(settlement.id)
        motion.updatePageDrag(
            translation: CGSize(width: -80, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .rightToLeft, isStart: true, at: now
        )
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: now).position, 0.8, accuracy: 0.001)
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: -80, height: 0),
            predictedEndTranslation: CGSize(width: -100, height: 0),
            reduceMotion: false, at: now
        ), .select(0))
    }

    func testPageSwipeRubberBandsAtBothEndsWithoutChangingPage() throws {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()

        motion.updatePageDrag(
            translation: CGSize(width: 180, height: 0), selectedPage: pages[0], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        let leadingPosition = motion.frame(pages: pages, selectedPage: pages[0], at: now).position
        XCTAssertLessThan(leadingPosition, 0)
        XCTAssertLessThan(leadingPosition, -0.12)
        XCTAssertGreaterThan(leadingPosition, -0.24)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[0], at: now).boundedPosition, 0)
        motion.updatePageDrag(
            translation: CGSize(width: 1_200, height: 0), selectedPage: pages[0], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: false, at: now
        )
        XCTAssertGreaterThan(motion.frame(pages: pages, selectedPage: pages[0], at: now).position, -0.28)
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: 1_200, height: 0),
            predictedEndTranslation: CGSize(width: 1_200, height: 0),
            reduceMotion: false, at: now
        ), .select(0))
        XCTAssertEqual(motion.transition?.settlement?.destination, 0)
        XCTAssertEqual(motion.transition?.settlement?.curve, .edgeSpring)

        motion.interrupt()
        motion.updatePageDrag(
            translation: CGSize(width: -80, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        let trailingPosition = motion.frame(pages: pages, selectedPage: pages[1], at: now).position
        XCTAssertGreaterThan(trailingPosition, 1)
        XCTAssertLessThan(trailingPosition, 1.24)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: now).boundedPosition, 1)
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: -80, height: 0),
            predictedEndTranslation: CGSize(width: -80, height: 0),
            reduceMotion: false, at: now
        ), .select(1))
        XCTAssertEqual(motion.transition?.settlement?.destination, 1)
        XCTAssertEqual(motion.transition?.settlement?.duration, 0.44)
        let halfway = motion.frame(pages: pages, selectedPage: pages[1], at: now.addingTimeInterval(0.22)).position
        XCTAssertGreaterThan(halfway, 1)
        XCTAssertLessThan(halfway, trailingPosition)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: now.addingTimeInterval(0.44)).position,
                       1, accuracy: 0.000001)
    }

    func testPageSwipeRubberBandsInRightToLeftLayout() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()

        motion.updatePageDrag(
            translation: CGSize(width: -180, height: 0), selectedPage: pages[0], pages: pages,
            pageWidth: 400, layoutDirection: .rightToLeft, isStart: true, at: now
        )
        let leading = motion.frame(pages: pages, selectedPage: pages[0], at: now)
        XCTAssertLessThan(leading.position, 0)
        XCTAssertLessThan(leading.offset(for: pages[0], width: 400, layoutDirection: .rightToLeft, reduceMotion: false), 0)

        motion.interrupt()
        motion.updatePageDrag(
            translation: CGSize(width: 180, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .rightToLeft, isStart: true, at: now
        )
        let trailing = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        XCTAssertGreaterThan(trailing.position, 1)
        XCTAssertGreaterThan(trailing.offset(for: pages[1], width: 400, layoutDirection: .rightToLeft, reduceMotion: false), 0)
    }

    func testCanceledAddPullKeepsOneProgressThroughReleaseAndReturn() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let translation = CGSize(width: -75, height: 0)

        motion.updateDrag(
            translation: translation, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        let dragging = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        XCTAssertEqual(dragging.edgeAddProgress, 0.5, accuracy: 0.001)
        XCTAssertEqual(motion.release(
            translation: translation, geometry: geometry,
            reduceMotion: false, at: now
        ), .select(1))
        XCTAssertEqual(motion.transition?.settlement?.curve, .edgeSpring)
        let released = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        XCTAssertEqual(released.edgeAddProgress, dragging.edgeAddProgress, accuracy: 0.001)
        let returning = motion.frame(pages: pages, selectedPage: pages[1], at: now.addingTimeInterval(0.22))
        XCTAssertGreaterThan(returning.edgeAddProgress, 0)
        XCTAssertLessThan(returning.edgeAddProgress, released.edgeAddProgress)
        XCTAssertEqual(
            motion.frame(pages: pages, selectedPage: pages[1], at: now.addingTimeInterval(0.44)).edgeAddProgress,
            0, accuracy: 0.0001
        )
    }

    func testSelectorAddPullRevealsCueSpaceAndContinuesIntoNewPage() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let newPage = LibraryPage.list(UUID())
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let pull = CGSize(width: -150, height: 0)

        motion.updateDrag(
            translation: pull, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        let held = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        let sourceOffset = held.offset(
            for: pages[1], width: 320, layoutDirection: .leftToRight, reduceMotion: false
        )
        XCTAssertGreaterThanOrEqual(-sourceOffset, ListAddCueLayout.clearance - 0.001,
                                    "The scaled add cue needs room beyond a narrow page")
        XCTAssertEqual(motion.release(
            translation: pull, geometry: geometry, reduceMotion: false, at: now
        ), .createList)

        motion.beginNewListEntrance(
            pages: pages + [newPage], cancellationOrigin: pages[1],
            reduceMotion: false, at: now
        )
        let entering = motion.frame(pages: pages + [newPage], selectedPage: newPage, at: now)
        XCTAssertEqual(
            entering.offset(for: pages[1], width: 320,
                            layoutDirection: .leftToRight, reduceMotion: false),
            sourceOffset, accuracy: 0.001
        )
    }

    func testSelectorAddPullRequiresMoreDistance() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()

        let shortPull = CGSize(width: -130, height: 0)
        motion.updateDrag(
            translation: shortPull, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertLessThan(motion.frame(pages: pages, selectedPage: pages[1], at: now).edgeAddProgress, 1)
        XCTAssertEqual(motion.release(
            translation: shortPull, geometry: geometry, reduceMotion: false, at: now
        ), .select(1))

        motion.interrupt()
        let fullPull = CGSize(width: -160, height: 0)
        motion.updateDrag(
            translation: fullPull, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertEqual(motion.release(
            translation: fullPull, geometry: geometry, reduceMotion: false, at: now
        ), .createList)
    }

    func testReversingSelectorAddPullResistsAndCancelsBeforeLift() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updateDrag(
            translation: CGSize(width: -170, height: 0), selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: now).edgeAddProgress, 1)
        let reversed = CGSize(width: -60, height: 0)
        motion.updateDrag(
            translation: reversed, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        let resisted = motion.frame(pages: pages, selectedPage: pages[1], at: now).edgeAddProgress
        XCTAssertGreaterThan(resisted, 0.5)
        XCTAssertLessThan(resisted, 1)
        XCTAssertEqual(motion.release(
            translation: reversed, geometry: geometry, reduceMotion: false, at: now
        ), .select(1))
        XCTAssertFalse(motion.isCreatingFromEdge)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: now).edgeAddProgress,
                       resisted, accuracy: 0.001)
    }

    func testReversingPageAddPullResistsAndCancelsBeforeLift() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updatePageDrag(
            translation: CGSize(width: -220, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.pageCreationProgress, 1)
        let reversed = CGSize(width: -95, height: 0)
        motion.updatePageDrag(
            translation: reversed, selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: false, at: now.addingTimeInterval(0.12)
        )
        let resisted = motion.pageCreationProgress
        XCTAssertGreaterThan(resisted, 0.5)
        XCTAssertLessThan(resisted, 1)
        XCTAssertEqual(motion.releasePageDrag(
            translation: reversed, predictedEndTranslation: reversed,
            reduceMotion: false, at: now.addingTimeInterval(0.12)
        ), .select(1))
        XCTAssertFalse(motion.isCreatingFromEdge)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: now.addingTimeInterval(0.12))
            .edgeAddProgress, resisted, accuracy: 0.001)
    }

    func testNewListEditorBackPullResistsAndCancelsOnlyBeyondThreshold() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID()), .list(UUID())]
        let source = pages[3]
        let origin = pages[0]
        let geometry = ListSelectorGeometry(widths: [100, 110, 120, 130])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()

        motion.updatePageDrag(
            translation: CGSize(width: 220, height: 0), selectedPage: source, pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true,
            cancelTo: origin, at: now
        )
        let full = motion.frame(pages: pages, selectedPage: source, at: now)
        XCTAssertEqual(full.retainedPages, [source, origin])
        XCTAssertGreaterThan(full.offset(for: source, width: 400,
                                         layoutDirection: .leftToRight, reduceMotion: false), 0)
        XCTAssertLessThan(full.offset(for: source, width: 400,
                                      layoutDirection: .leftToRight, reduceMotion: false), 220)
        XCTAssertEqual(motion.newListCancelProgress, 1)
        XCTAssertEqual(full.edgeCancelProgress, 1)

        motion.updatePageDrag(
            translation: CGSize(width: 80, height: 0), selectedPage: source, pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: false,
            cancelTo: origin, at: now.addingTimeInterval(0.1)
        )
        XCTAssertGreaterThan(motion.newListCancelProgress, 80.0 / 175.0)
        XCTAssertLessThan(motion.newListCancelProgress, 1)
        let reversedCue = motion.frame(pages: pages, selectedPage: source,
                                       at: now.addingTimeInterval(0.1)).edgeCancelProgress
        XCTAssertEqual(reversedCue, motion.newListCancelProgress)
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: 80, height: 0),
            predictedEndTranslation: CGSize(width: 80, height: 0),
            reduceMotion: false, at: now.addingTimeInterval(0.1)
        ), .select(3))
        XCTAssertFalse(motion.transition?.settlement?.cancelsNewList ?? true)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: source,
                                    at: now.addingTimeInterval(0.1)).edgeCancelProgress,
                       reversedCue, accuracy: 0.001)
        XCTAssertLessThan(motion.frame(pages: pages, selectedPage: source,
                                       at: now.addingTimeInterval(0.3)).edgeCancelProgress,
                          reversedCue)

        var committed = ListPageMotion()
        committed.updatePageDrag(
            translation: CGSize(width: 220, height: 0), selectedPage: source, pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true,
            cancelTo: origin, at: now
        )
        XCTAssertEqual(committed.releasePageDrag(
            translation: CGSize(width: 220, height: 0),
            predictedEndTranslation: CGSize(width: 220, height: 0),
            reduceMotion: false, at: now
        ), .cancelNewList)
        XCTAssertEqual(committed.transition?.settlement?.destination, 0)
        XCTAssertTrue(committed.transition?.settlement?.cancelsNewList == true)
        XCTAssertEqual(committed.frame(pages: pages, selectedPage: source, at: now).edgeCancelProgress, 1)
        XCTAssertNotNil(committed.frame(pages: pages, selectedPage: source, at: now)
            .selectorPresentation(in: geometry))
    }

    func testCancelButtonReturnsToOriginThroughThePageTransition() throws {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID())]
        let source = pages[2]
        let origin = pages[0]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()

        XCTAssertTrue(motion.beginNewListCancellation(
            from: source, to: origin, pages: pages, reduceMotion: false, at: now
        ))
        let settlement = try XCTUnwrap(motion.transition?.settlement)
        XCTAssertTrue(settlement.cancelsNewList)
        XCTAssertEqual(settlement.completion, .cancelNewListFromButton)
        XCTAssertEqual(settlement.destination, 0)
        XCTAssertTrue(motion.isEnteringNewList)
        let start = motion.frame(pages: pages, selectedPage: source, at: now)
        let halfway = motion.frame(pages: pages, selectedPage: source,
                                   at: now.addingTimeInterval(settlement.duration / 2))
        XCTAssertEqual(start.directEntrance?.source, source)
        XCTAssertEqual(start.directEntrance?.destination, origin)
        XCTAssertEqual(start.offset(for: source, width: 400,
                                    layoutDirection: .leftToRight, reduceMotion: false), 0)
        XCTAssertGreaterThan(halfway.offset(for: source, width: 400,
                                            layoutDirection: .leftToRight, reduceMotion: false), 0)
        XCTAssertLessThan(halfway.offset(for: source, width: 400,
                                         layoutDirection: .leftToRight, reduceMotion: false), 400)
        XCTAssertFalse(motion.beginNewListCancellation(
            from: source, to: origin, pages: pages, reduceMotion: false, at: now
        ), "A repeated Cancel must not restart the transition")
    }

    func testCancelButtonReversesAnUnfinishedNewListEntranceWithoutJumping() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID())]
        let source = pages[2]
        let origin = pages[0]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let reversal = now.addingTimeInterval(0.08)
        var motion = ListPageMotion()
        motion.beginNewListEntrance(pages: pages, cancellationOrigin: origin,
                                    reduceMotion: false, at: now)
        let before = motion.frame(pages: pages, selectedPage: source, at: reversal)
            .offset(for: source, width: 400, layoutDirection: .leftToRight, reduceMotion: false)

        XCTAssertTrue(motion.beginNewListCancellation(
            from: source, to: origin, pages: pages, reduceMotion: false, at: reversal
        ))
        let after = motion.frame(pages: pages, selectedPage: source, at: reversal)
            .offset(for: source, width: 400, layoutDirection: .leftToRight, reduceMotion: false)
        XCTAssertEqual(after, before, accuracy: 0.001)
    }

    func testPageAddPullCanRearmAfterReversingBelowThreshold() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let fullPull = CGSize(width: -220, height: 0)
        let reversed = CGSize(width: -95, height: 0)
        for extendsAgain in [false, true] {
            var motion = ListPageMotion()
            motion.updatePageDrag(
                translation: fullPull, selectedPage: pages[1], pages: pages,
                pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
            )
            motion.updatePageDrag(
                translation: reversed, selectedPage: pages[1], pages: pages,
                pageWidth: 400, layoutDirection: .leftToRight, isStart: false,
                at: now.addingTimeInterval(0.1)
            )
            if extendsAgain {
                motion.updatePageDrag(
                    translation: fullPull, selectedPage: pages[1], pages: pages,
                    pageWidth: 400, layoutDirection: .leftToRight, isStart: false,
                    at: now.addingTimeInterval(0.12)
                )
            }
            let release = extendsAgain ? fullPull : reversed
            XCTAssertEqual(motion.releasePageDrag(
                translation: release, predictedEndTranslation: release,
                reduceMotion: false, at: now.addingTimeInterval(0.16)
            ), extendsAgain ? .createList : .select(1))
        }
    }

    func testSelectorRegrabDuringAddReturnStartsAtVisibleBubble() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let firstPull = CGSize(width: -72, height: 0)
        motion.updateDrag(
            translation: firstPull, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertEqual(motion.release(
            translation: firstPull, geometry: geometry,
            reduceMotion: false, at: now
        ), .select(1))
        let regrabAt = now.addingTimeInterval(0.22)
        let visibleProgress = motion.frame(pages: pages, selectedPage: pages[1], at: regrabAt).edgeAddProgress
        let visibleCursor = geometry.centers[1] + visibleProgress * ListSelectorGeometry.pullThreshold

        motion.updateDrag(
            translation: CGSize(width: -8, height: 0), selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: regrabAt
        )
        XCTAssertEqual(motion.dragCursor ?? 0, visibleCursor + 8, accuracy: 0.001)
        XCTAssertGreaterThan(motion.frame(pages: pages, selectedPage: pages[1], at: regrabAt).edgeAddProgress, visibleProgress)
    }

    func testRegrabbingReversedSelectorAddPullKeepsPagePosition() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let fullPull = CGSize(width: -170, height: 0)
        let reversed = CGSize(width: -60, height: 0)

        motion.updateDrag(
            translation: fullPull, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        motion.updateDrag(
            translation: reversed, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertEqual(motion.release(
            translation: reversed, geometry: geometry, reduceMotion: false, at: now
        ), .select(1))

        let regrabAt = now.addingTimeInterval(0.1)
        let before = motion.frame(pages: pages, selectedPage: pages[1], at: regrabAt).position
        motion.updateDrag(
            translation: CGSize(width: -1, height: 0), selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: regrabAt
        )
        let after = motion.frame(pages: pages, selectedPage: pages[1], at: regrabAt).position
        XCTAssertEqual(after, before, accuracy: 0.003)
    }

    func testTabSelectionDuringAddReturnContinuesFromVisibleBubble() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let pull = CGSize(width: -72, height: 0)
        motion.updateDrag(
            translation: pull, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertEqual(motion.release(
            translation: pull, geometry: geometry, reduceMotion: false, at: now
        ), .select(1))
        let tapAt = now.addingTimeInterval(0.22)
        let before = motion.frame(pages: pages, selectedPage: pages[1], at: tapAt)
        let visible = before.edgeAddProgress
        let visibleCursor = before.selectorPullCursor(in: geometry, progress: visible, holdsAtAdd: false)

        motion.select(0, selectedPage: pages[1], pages: pages, reduceMotion: false, at: tapAt)
        let retargeted = motion.frame(pages: pages, selectedPage: pages[0], at: tapAt)
        XCTAssertEqual(retargeted.edgeAddProgress, visible, accuracy: 0.001)
        XCTAssertEqual(retargeted.selectorPullCursor(in: geometry, progress: retargeted.edgeAddProgress,
                                                    holdsAtAdd: false), visibleCursor, accuracy: 0.001)
        let halfway = motion.frame(pages: pages, selectedPage: pages[0], at: tapAt.addingTimeInterval(0.12))
        XCTAssertLessThan(halfway.edgeAddProgress, visible)
        XCTAssertLessThan(halfway.selectorPullCursor(in: geometry, progress: halfway.edgeAddProgress,
                                                    holdsAtAdd: false), visibleCursor)
        let finished = motion.frame(pages: pages, selectedPage: pages[0], at: tapAt.addingTimeInterval(1))
        XCTAssertEqual(finished.selectorPullCursor(in: geometry, progress: finished.edgeAddProgress,
                                                   holdsAtAdd: false), geometry.centers[0], accuracy: 0.001)
    }

    func testRegrabAfterTabSelectionDuringAddReturnStartsAtVisibleBubble() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let pull = CGSize(width: -72, height: 0)
        motion.updateDrag(
            translation: pull, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertEqual(motion.release(
            translation: pull, geometry: geometry, reduceMotion: false, at: now
        ), .select(1))

        let tapAt = now.addingTimeInterval(0.1)
        XCTAssertTrue(motion.select(0, selectedPage: pages[1], pages: pages,
                                    reduceMotion: false, at: tapAt))
        let regrabAt = tapAt.addingTimeInterval(0.08)
        let before = motion.frame(pages: pages, selectedPage: pages[0], at: regrabAt)
        let visibleCursor = before.selectorPullCursor(
            in: geometry, progress: before.edgeAddProgress, holdsAtAdd: false
        )

        motion.updateDrag(
            translation: CGSize(width: -1, height: 0), selectedPage: pages[0], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: regrabAt
        )
        XCTAssertEqual(motion.dragCursor ?? 0, visibleCursor + 1, accuracy: 0.001)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[0], at: regrabAt).position,
                       before.position, accuracy: 0.015)
    }

    func testRegrabAfterNearlyArmedPullAndTabSelectionKeepsPageAndCue() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let nearAdd = CGSize(width: -140, height: 0)
        motion.updateDrag(
            translation: nearAdd, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertEqual(motion.release(
            translation: nearAdd, geometry: geometry, reduceMotion: false, at: now
        ), .select(1))

        let tapAt = now.addingTimeInterval(0.1)
        XCTAssertTrue(motion.select(0, selectedPage: pages[1], pages: pages,
                                    reduceMotion: false, at: tapAt))
        let regrabAt = tapAt.addingTimeInterval(0.08)
        let before = motion.frame(pages: pages, selectedPage: pages[0], at: regrabAt)
        let visibleProgress = before.edgeAddProgress
        let visibleCursor = before.selectorPullCursor(
            in: geometry, progress: visibleProgress, holdsAtAdd: false
        )
        XCTAssertGreaterThan(visibleProgress - geometry.pullProgress(at: visibleCursor), 0.1)

        motion.updateDrag(
            translation: CGSize(width: -1, height: 0), selectedPage: pages[0], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: regrabAt
        )
        let after = motion.frame(pages: pages, selectedPage: pages[0], at: regrabAt)
        XCTAssertEqual(motion.dragCursor ?? 0, visibleCursor + 1, accuracy: 0.001)
        XCTAssertEqual(after.position, before.position, accuracy: 0.015)
        XCTAssertEqual(after.edgeAddProgress, visibleProgress, accuracy: 0.02)

        let thresholdCursor = geometry.centers[1] + ListSelectorGeometry.pullThreshold
        let completedPull = CGSize(width: -(thresholdCursor - visibleCursor + 1), height: 0)
        motion.updateDrag(
            translation: completedPull, selectedPage: pages[0], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: regrabAt
        )
        let armed = motion.frame(pages: pages, selectedPage: pages[0], at: regrabAt)
        XCTAssertEqual(armed.edgeAddProgress, 1)
        XCTAssertGreaterThanOrEqual(-armed.offset(for: pages[1], width: 320,
                                                     layoutDirection: .leftToRight, reduceMotion: false),
                                    ListAddCueLayout.clearance - 0.001)
        XCTAssertEqual(motion.release(
            translation: completedPull, geometry: geometry, reduceMotion: false, at: regrabAt
        ), .createList)
    }

    func testWideCompactPullRevealsOnlyCueClearanceAndKeepsStretching() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updateDrag(
            translation: CGSize(width: -160, height: 0), selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        let selectorFrame = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        XCTAssertEqual(-selectorFrame.offset(for: pages[1], width: 852,
                                             layoutDirection: .leftToRight, reduceMotion: false),
                       ListAddCueLayout.clearance, accuracy: 0.001)

        motion.interrupt()
        motion.updatePageDrag(
            translation: CGSize(width: -220, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 852, layoutDirection: .leftToRight, isStart: true, at: now
        )
        let armedFrame = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        XCTAssertEqual(-armedFrame.offset(for: pages[1], width: 852,
                                          layoutDirection: .leftToRight, reduceMotion: false),
                       ListAddCueLayout.clearance, accuracy: 0.001)
        motion.updatePageDrag(
            translation: CGSize(width: -300, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 852, layoutDirection: .leftToRight, isStart: false, at: now
        )
        let stretchedFrame = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        let stretchedOffset = -stretchedFrame.offset(for: pages[1], width: 852,
                                                     layoutDirection: .leftToRight, reduceMotion: false)
        XCTAssertGreaterThan(stretchedOffset, ListAddCueLayout.clearance)
        XCTAssertLessThan(stretchedOffset, ListAddCueLayout.clearance + 30)
    }

    func testNarrowCompactPullStillRevealsFullCue() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [64, 64])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updateDrag(
            translation: CGSize(width: -160, height: 0), selectedPage: pages[1], pages: pages,
            geometry: geometry, pageWidth: 280, layoutDirection: .leftToRight, at: now
        )
        let selectorFrame = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        XCTAssertEqual(-selectorFrame.offset(for: pages[1], width: 280,
                                             layoutDirection: .leftToRight, reduceMotion: false),
                       ListAddCueLayout.clearance, accuracy: 0.001)

        motion.interrupt()
        motion.updatePageDrag(
            translation: CGSize(width: -154, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 280, layoutDirection: .leftToRight, isStart: true, at: now
        )
        let pageFrame = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        XCTAssertEqual(-pageFrame.offset(for: pages[1], width: 280,
                                         layoutDirection: .leftToRight, reduceMotion: false),
                       ListAddCueLayout.clearance, accuracy: 0.001)
    }

    func testTabSelectionWaitsForDirectNewListEntrance() throws {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        XCTAssertTrue(motion.select(3, selectedPage: pages[0], pages: pages,
                                    reduceMotion: false, directEntrance: true, at: now))
        let entrance = try XCTUnwrap(motion.transition?.settlement)
        let tapAt = now.addingTimeInterval(0.12)
        let before = motion.frame(pages: pages, selectedPage: pages[3], at: tapAt)
        XCTAssertTrue(motion.isEnteringNewList)

        XCTAssertFalse(motion.select(1, selectedPage: pages[3], pages: pages,
                                     reduceMotion: false, at: tapAt))
        let after = motion.frame(pages: pages, selectedPage: pages[3], at: tapAt)
        XCTAssertEqual(motion.transition?.settlement?.id, entrance.id)
        XCTAssertEqual(after.position, before.position)
        XCTAssertEqual(after.retainedPages, [pages[0], pages[3]])

        motion.finishSettlement(entrance.id)
        XCTAssertFalse(motion.isEnteringNewList)
        XCTAssertTrue(motion.select(1, selectedPage: pages[3], pages: pages,
                                    reduceMotion: false, at: now.addingTimeInterval(0.3)))
    }

    func testSelectorDragWaitsForDirectNewListEntrance() throws {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.select(2, selectedPage: pages[1], pages: pages,
                      reduceMotion: false, directEntrance: true, at: now)
        let settlement = try XCTUnwrap(motion.transition?.settlement)
        let duringEntrance = now.addingTimeInterval(0.12)
        let position = motion.frame(pages: pages, selectedPage: pages[2], at: duringEntrance).position

        motion.updateDrag(
            translation: CGSize(width: -40, height: 0), selectedPage: pages[2], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: duringEntrance
        )
        XCTAssertFalse(motion.isDragging)
        XCTAssertEqual(motion.transition?.settlement?.id, settlement.id)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[2], at: duringEntrance).position, position)
        motion.finishSettlement(settlement.id)
        motion.updateDrag(
            translation: CGSize(width: -80, height: 0), selectedPage: pages[2], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now.addingTimeInterval(0.3)
        )
        XCTAssertFalse(motion.isDragging, "The same finger must stay rejected after the entrance finishes")
        XCTAssertNil(motion.release(
            translation: CGSize(width: -40, height: 0), geometry: geometry,
            reduceMotion: false, at: duringEntrance
        ))
        motion.updateDrag(
            translation: CGSize(width: -40, height: 0), selectedPage: pages[2], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now.addingTimeInterval(0.3)
        )
        XCTAssertTrue(motion.isSelectorDragging)
    }

    func testSelectorDragWaitsForPageEdgeReturn() throws {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updatePageDrag(
            translation: CGSize(width: -80, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: -80, height: 0),
            predictedEndTranslation: CGSize(width: -80, height: 0),
            reduceMotion: false, at: now
        ), .select(1))
        let settlement = try XCTUnwrap(motion.transition?.settlement)
        let returningAt = now.addingTimeInterval(0.1)
        let position = motion.frame(pages: pages, selectedPage: pages[1], at: returningAt).position
        XCTAssertGreaterThan(position, 1)

        motion.updateDrag(
            translation: CGSize(width: -20, height: 0), selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: returningAt
        )
        XCTAssertFalse(motion.isDragging)
        XCTAssertEqual(motion.transition?.settlement?.id, settlement.id)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: returningAt).position, position)
        motion.finishSettlement(settlement.id)
        motion.updateDrag(
            translation: CGSize(width: -40, height: 0), selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now.addingTimeInterval(0.5)
        )
        XCTAssertFalse(motion.isDragging, "The same finger must stay rejected after the edge return finishes")
        motion.cancelDrag(reduceMotion: false, at: returningAt)
        motion.updateDrag(
            translation: CGSize(width: -20, height: 0), selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now.addingTimeInterval(0.5)
        )
        XCTAssertTrue(motion.isSelectorDragging)
    }

    func testCompletedSelectorPullHoldsSharedAddPresentationFromEarlierPage() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let translation = CGSize(width: geometry.centers[0] - geometry.centers[1] - 160, height: 0)

        motion.updateDrag(
            translation: translation, selectedPage: pages[0], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertEqual(motion.release(
            translation: translation, geometry: geometry,
            reduceMotion: false, at: now
        ), .createList)
        XCTAssertTrue(motion.isCreatingFromEdge)
        let frame = motion.frame(pages: pages, selectedPage: pages[0], at: now)
        XCTAssertEqual(frame.creationProgress(dragProgress: 0, holdsAtAdd: motion.isCreatingFromEdge), 1)
        XCTAssertEqual(frame.weight(for: pages[1]), 1)
        XCTAssertFalse(motion.isDragging)

        let newPage = LibraryPage.list(UUID())
        let insertedPages = pages + [newPage]
        motion.beginNewListEntrance(
            pages: insertedPages, cancellationOrigin: pages[0],
            reduceMotion: false, at: now
        )
        let entranceStart = motion.frame(pages: insertedPages, selectedPage: newPage, at: now)
        XCTAssertEqual(entranceStart.directEntrance?.source, pages[1])
        XCTAssertEqual(entranceStart.retainedPages, [pages[1], newPage])
        XCTAssertEqual(entranceStart.edgeAddProgress, 1)
        XCTAssertTrue(entranceStart.directEntrance?.showsAddCue == true)
        let entranceMiddle = motion.frame(
            pages: insertedPages, selectedPage: newPage, at: now.addingTimeInterval(0.12)
        )
        XCTAssertGreaterThan(entranceMiddle.edgeAddProgress, 0)
        XCTAssertLessThan(entranceMiddle.edgeAddProgress, 1)
        motion.interrupt()
        XCTAssertFalse(motion.isCreatingFromEdge)
    }

    func testPagePanCannotTakeOverCommittedSelectorCreation() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let pull = CGSize(width: -170, height: 0)
        motion.updateDrag(
            translation: pull, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertEqual(motion.release(
            translation: pull, geometry: geometry, reduceMotion: false, at: now
        ), .createList)
        let heldFrame = motion.frame(pages: pages, selectedPage: pages[1], at: now)

        motion.updatePageDrag(
            translation: CGSize(width: 80, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertTrue(motion.isCreatingFromEdge)
        XCTAssertFalse(motion.isDragging)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: now).position,
                       heldFrame.position)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: now)
            .creationProgress(dragProgress: 0, holdsAtAdd: motion.isCreatingFromEdge), 1)
    }

    func testSelectorCannotTakeOverCommittedPageCreation() throws {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let pull = CGSize(width: -220, height: 0)
        motion.updatePageDrag(
            translation: pull, selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.releasePageDrag(
            translation: pull, predictedEndTranslation: pull,
            reduceMotion: false, at: now.addingTimeInterval(0.12)
        ), .createList)
        let settlement = try XCTUnwrap(motion.transition?.settlement)
        XCTAssertTrue(motion.isCreatingFromEdge)
        XCTAssertFalse(motion.select(0, selectedPage: pages[1], pages: pages,
                                     reduceMotion: false, at: now.addingTimeInterval(0.2)))
        XCTAssertEqual(motion.transition?.settlement?.id, settlement.id)

        motion.updateDrag(
            translation: CGSize(width: -100, height: 0), selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now.addingTimeInterval(0.5)
        )
        XCTAssertFalse(motion.isDragging)
        XCTAssertTrue(motion.isCreatingFromEdge)
        XCTAssertFalse(motion.select(0, selectedPage: pages[1], pages: pages,
                                     reduceMotion: false, at: now.addingTimeInterval(0.5)))
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: now.addingTimeInterval(0.5))
            .creationProgress(dragProgress: 0, holdsAtAdd: motion.isCreatingFromEdge), 1)
    }

}
