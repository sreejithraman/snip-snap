import SnipSnapCore
import SwiftUI
import UIKit
import XCTest
@testable import SnipSnapiOS

@MainActor
final class ListPageTransitionTests: XCTestCase {
    func testReopenedPendingListReturnsFromAddToItsTab() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [90, 110])
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let translation = CGSize(width: -140, height: 0)
        motion.updateDrag(
            translation: translation, selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertEqual(motion.release(
            translation: translation, geometry: geometry,
            reduceMotion: false, at: now
        ), .createList)
        motion.returnFromAdd(to: pages[1], pages: pages, reduceMotion: false, at: now)
        XCTAssertFalse(motion.isCreatingFromEdge)
        let returned = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        XCTAssertEqual(returned.edgeAddProgress, 1)
        XCTAssertFalse(returned.isMoving)
        let returning = motion.frame(pages: pages, selectedPage: pages[1], at: now.addingTimeInterval(0.12))
        XCTAssertGreaterThan(returning.edgeAddProgress, 0)
        XCTAssertLessThan(returning.edgeAddProgress, 1)
    }

    func testPagePullReopeningPendingListReturnsFromAddToItsTab() throws {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updatePageDrag(
            translation: CGSize(width: -220, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: -220, height: 0),
            predictedEndTranslation: CGSize(width: -220, height: 0),
            reduceMotion: false, at: now.addingTimeInterval(0.12)
        ), .createList)
        motion.returnFromAdd(to: pages[1], pages: pages, reduceMotion: false, at: now)
        let returned = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        XCTAssertEqual(returned.edgeAddProgress, 1)
        XCTAssertGreaterThan(returned.position, 1)
        XCTAssertTrue(returned.isMoving)
        let returning = motion.frame(pages: pages, selectedPage: pages[1], at: now.addingTimeInterval(0.22))
        XCTAssertGreaterThan(returning.edgeAddProgress, 0)
        XCTAssertLessThan(returning.edgeAddProgress, 1)
        XCTAssertLessThan(returning.position, returned.position)
        XCTAssertEqual(motion.transition?.settlement?.curve, .edgeSpring)
    }

    func testPageRubberBandUsesFadeWithReduceMotion() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updatePageDrag(
            translation: CGSize(width: -80, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        let frame = motion.frame(pages: pages, selectedPage: pages[1], at: now)
        XCTAssertEqual(frame.offset(for: pages[1], width: 400, layoutDirection: .leftToRight, reduceMotion: true), 0)
        XCTAssertLessThan(frame.opacity(for: pages[1], reduceMotion: true), 1)
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: -80, height: 0),
            predictedEndTranslation: CGSize(width: -80, height: 0),
            reduceMotion: true, at: now
        ), .select(1))
        XCTAssertEqual(motion.transition?.settlement?.duration, 0.12)
    }

    func testTrailingPagePullCreatesOnlyAfterDeliberateDistance() throws {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()

        motion.updatePageDrag(
            translation: CGSize(width: -142.5, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.pageCreationProgress, 0.75)
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: -142.5, height: 0),
            predictedEndTranslation: CGSize(width: -500, height: 0),
            reduceMotion: false, at: now
        ), .select(1))
        XCTAssertEqual(motion.pageCreationProgress, 0)

        motion.interrupt()
        motion.updatePageDrag(
            translation: CGSize(width: -220, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.pageCreationProgress, 1)
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: -220, height: 0),
            predictedEndTranslation: CGSize(width: -300, height: 0),
            reduceMotion: false, at: now.addingTimeInterval(0.02)
        ), .createList)

        motion.interrupt()
        motion.updatePageDrag(
            translation: CGSize(width: -220, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: -220, height: 0),
            predictedEndTranslation: CGSize(width: -220, height: 0),
            reduceMotion: false, at: now.addingTimeInterval(0.12)
        ), .createList)
        XCTAssertGreaterThan(motion.transition?.settlement?.destination ?? 0, 1)
        XCTAssertEqual(motion.transition?.settlement?.createsList, true)
        let heldPosition = try XCTUnwrap(motion.transition?.settlement?.destination)
        let settlingFrame = motion.frame(pages: pages, selectedPage: pages[1], at: now.addingTimeInterval(0.3))
        XCTAssertEqual(settlingFrame.position, heldPosition, accuracy: 0.001)
        XCTAssertEqual(settlingFrame.creationProgress(dragProgress: 0, holdsAtAdd: true), 1)
        motion.returnFromCommittedCreation(reduceMotion: false, at: now.addingTimeInterval(0.3))
        XCTAssertFalse(motion.isCreatingFromEdge)
        XCTAssertEqual(motion.transition?.settlement?.curve, .edgeSpring)
        let restingFrame = motion.frame(pages: pages, selectedPage: pages[1], at: now.addingTimeInterval(1))
        XCTAssertEqual(restingFrame.position, 1, accuracy: 0.001)
        XCTAssertEqual(restingFrame.edgeAddProgress, 0, accuracy: 0.001)

        motion.interrupt()
        XCTAssertFalse(motion.isCreatingFromEdge)
        XCTAssertNil(motion.transition)
        motion.updatePageDrag(
            translation: CGSize(width: 180, height: 0), selectedPage: pages[0], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.pageCreationProgress, 0)
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: 180, height: 0),
            predictedEndTranslation: CGSize(width: 180, height: 0),
            reduceMotion: false, at: now
        ), .select(0))
    }

    func testCommittedPagePullContinuesIntoNewListEntranceWithoutReturning() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let newPage = LibraryPage.list(UUID())
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
        let held = motion.frame(pages: pages, selectedPage: pages[1],
                                at: now.addingTimeInterval(0.7))
        XCTAssertGreaterThan(held.position, 1)
        let heldOffset = held.offset(for: pages[1], width: 400,
                                     layoutDirection: .leftToRight, reduceMotion: false)

        let insertedPages = pages + [newPage]
        motion.beginNewListEntrance(
            pages: insertedPages, cancellationOrigin: pages[1],
            reduceMotion: false, at: now.addingTimeInterval(0.7)
        )
        let entrance = motion.frame(pages: insertedPages, selectedPage: newPage,
                                    at: now.addingTimeInterval(0.7))
        XCTAssertEqual(entrance.offset(for: pages[1], width: 400,
                                       layoutDirection: .leftToRight, reduceMotion: false),
                       heldOffset, accuracy: 0.001)
        XCTAssertEqual(entrance.edgeAddProgress, 1, accuracy: 0.001)
    }

    func testLongPageDragNeverPreviewsPastAdjacentList() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID()), .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updatePageDrag(
            translation: CGSize(width: -1_200, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: now).position, 2)
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: -1_200, height: 0),
            predictedEndTranslation: CGSize(width: -1_200, height: 0),
            reduceMotion: false, at: now
        ), .select(2))
    }

    func testPageDragWaitsForExistingSettlement() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID()), .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.select(4, selectedPage: pages[1], pages: pages, reduceMotion: false, at: now)
        let settlement = motion.transition?.settlement

        motion.updatePageDrag(
            translation: CGSize(width: 80, height: 0), selectedPage: pages[4], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true,
            at: now.addingTimeInterval(0.05)
        )

        XCTAssertFalse(motion.isDragging)
        XCTAssertEqual(motion.transition?.settlement, settlement)
    }

    func testPageDragReversedPastOriginDoesNotSelectNeighbor() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updatePageDrag(
            translation: CGSize(width: -80, height: 0), selectedPage: pages[2], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )

        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: 100, height: 0),
            predictedEndTranslation: CGSize(width: 100, height: 0),
            reduceMotion: false, at: now
        ), .select(2))
        XCTAssertEqual(motion.transition?.settlement?.destination, 2)
    }

    func testPageSwipeReversalCannotChooseOppositePage() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updatePageDrag(
            translation: CGSize(width: -80, height: 0), selectedPage: pages[2], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        XCTAssertEqual(motion.releasePageDrag(
            translation: CGSize(width: -80, height: 0),
            predictedEndTranslation: CGSize(width: 200, height: 0),
            reduceMotion: false, at: now
        ), .select(3))
    }

    func testPageSwipeStopsWhenPageOrderChanges() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updatePageDrag(
            translation: CGSize(width: -80, height: 0), selectedPage: pages[1], pages: pages,
            pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: now
        )
        motion.updatePageDrag(
            translation: CGSize(width: -90, height: 0), selectedPage: pages[1],
            pages: [pages[0], pages[2], pages[1]], pageWidth: 400,
            layoutDirection: .leftToRight, isStart: false, at: now
        )
        XCTAssertNil(motion.transition)
        XCTAssertFalse(motion.isDragging)
        motion.updatePageDrag(
            translation: CGSize(width: -110, height: 0), selectedPage: pages[1],
            pages: [pages[0], pages[2], pages[1]], pageWidth: 400,
            layoutDirection: .leftToRight, isStart: false, at: now
        )
        XCTAssertNil(motion.transition)
    }

    func testListPagingFollowsEveryVariableWidthSegmentAndReversal() throws {
        let geometry = ListSelectorGeometry(widths: [80, 160, 100, 200])
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        let positions: [CGFloat] = [0.25, 0.75, 1, 1.5, 2, 2.75, 1.5, 0.25]
        var peakDistance: CGFloat = 0
        for position in positions {
            let cursor = geometry.cursor(at: position)
            motion.updateDrag(
                translation: CGSize(width: geometry.centers[0] - cursor, height: 0),
                selectedPage: pages[0], pages: pages, geometry: geometry,
                layoutDirection: .leftToRight, at: now
            )
            peakDistance = max(peakDistance, abs(cursor - geometry.centers[0]))
            XCTAssertEqual(motion.dragDistance, peakDistance)
            let frame = motion.frame(pages: pages, selectedPage: pages[0], at: now)
            XCTAssertEqual(frame.position, position, accuracy: 0.0001)
            XCTAssertEqual(geometry.pagePosition(at: cursor), position, accuracy: 0.0001)
            XCTAssertTrue(frame.retainedPages.contains(pages[0]))
            XCTAssertTrue(frame.retainedPages.contains(pages[Int(floor(position))]))
            XCTAssertTrue(frame.retainedPages.contains(pages[Int(ceil(position))]))
            XCTAssertLessThanOrEqual(frame.retainedPages.count, 3)
        }
        XCTAssertTrue(motion.isDragging)
    }

    func testListPagingMirrorsDragAndOffsetsInRTL() {
        let geometry = ListSelectorGeometry(widths: [80, 160, 100])
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            var motion = ListPageMotion()
            let sign: CGFloat = direction == .leftToRight ? -1 : 1
            motion.updateDrag(
                translation: CGSize(width: sign * 197, height: 0),
                selectedPage: pages[0], pages: pages, geometry: geometry,
                layoutDirection: direction, at: now
            )
            let frame = motion.frame(pages: pages, selectedPage: pages[0], at: now)
            XCTAssertEqual(frame.position, 1.5, accuracy: 0.0001)
            XCTAssertEqual(frame.offset(for: pages[1], width: 400, layoutDirection: direction, reduceMotion: false), sign * 200)
            XCTAssertEqual(frame.offset(for: pages[2], width: 400, layoutDirection: direction, reduceMotion: false), -sign * 200)
        }
    }

    func testCancelledListDragReturnsToSourceAndClearsSettlement() throws {
        let geometry = ListSelectorGeometry(widths: [80, 160, 100])
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updateDrag(
            translation: CGSize(width: -197, height: 0), selectedPage: pages[0],
            pages: pages, geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        motion.cancelDrag(reduceMotion: false, at: now)
        XCTAssertEqual(motion.dragDistance, 0)
        XCTAssertFalse(motion.isDragging)
        let settlement = try XCTUnwrap(motion.transition?.settlement)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[0], at: now).position, 1.5)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[0], at: now.addingTimeInterval(1)).position, 0)
        motion.finishSettlement(settlement.id)
        XCTAssertNil(motion.transition)
        XCTAssertFalse(motion.frame(pages: pages, selectedPage: pages[0], at: now).isMoving)
    }

    func testDiagonalReleaseStillCompletesAnAcceptedHorizontalDrag() throws {
        let geometry = ListSelectorGeometry(widths: [80, 160, 100])
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updateDrag(
            translation: CGSize(width: -100, height: 0), selectedPage: pages[0],
            pages: pages, geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        XCTAssertEqual(motion.release(translation: CGSize(width: -128, height: 200), geometry: geometry, reduceMotion: false, at: now), .select(1))
        XCTAssertFalse(motion.isDragging)
        XCTAssertEqual(motion.dragDistance, 0)
        let settlement = try XCTUnwrap(motion.transition?.settlement)
        motion.cancelDrag(reduceMotion: false, at: now)
        XCTAssertEqual(motion.transition?.settlement?.id, settlement.id, "A later GestureState reset must not cancel a released drag")
        motion.finishSettlement(settlement.id)
        XCTAssertNil(motion.transition)
    }

    func testNewDragStartsFromVisibleSettlingPositionAndIgnoresOldCompletion() throws {
        let geometry = ListSelectorGeometry(widths: [80, 160, 100])
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.select(2, selectedPage: pages[0], pages: pages, reduceMotion: false, at: now)
        let previous = try XCTUnwrap(motion.transition?.settlement)
        let interruptedAt = now.addingTimeInterval(previous.duration / 2)
        let visible = motion.frame(pages: pages, selectedPage: pages[2], at: interruptedAt).position
        XCTAssertGreaterThan(visible, 0)
        XCTAssertLessThan(visible, 2)
        motion.updateDrag(
            translation: CGSize(width: 10, height: 0), selectedPage: pages[2],
            pages: pages, geometry: geometry, layoutDirection: .leftToRight, at: interruptedAt
        )
        XCTAssertEqual(
            motion.frame(pages: pages, selectedPage: pages[2], at: interruptedAt).position,
            geometry.pagePosition(at: geometry.cursor(at: visible) - 10), accuracy: 0.0001
        )
        motion.finishSettlement(previous.id)
        XCTAssertTrue(motion.isDragging)
        XCTAssertNotNil(motion.transition)
        motion.cancelDrag(reduceMotion: false, at: interruptedAt)
        XCTAssertEqual(motion.transition?.settlement?.destination, 2)
    }

    func testRepeatedTabSelectionRetargetsFromVisiblePosition() throws {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.select(3, selectedPage: pages[0], pages: pages, reduceMotion: false, at: now)
        let previous = try XCTUnwrap(motion.transition?.settlement)
        let interruptedAt = now.addingTimeInterval(previous.duration / 2)
        let before = motion.frame(pages: pages, selectedPage: pages[3], at: interruptedAt)
        motion.select(1, selectedPage: pages[3], pages: pages, reduceMotion: false, at: interruptedAt)
        let after = motion.frame(pages: pages, selectedPage: pages[1], at: interruptedAt)
        XCTAssertEqual(after.position, before.position)
        XCTAssertLessThanOrEqual(after.retainedPages.count, 4)
        motion.finishSettlement(previous.id)
        XCTAssertNotNil(motion.transition)
        XCTAssertEqual(motion.frame(pages: pages, selectedPage: pages[1], at: interruptedAt.addingTimeInterval(1)).position, 1)
    }

    func testInterruptedListMotionClearsGestureAndSettlingState() throws {
        let geometry = ListSelectorGeometry(widths: [80, 160])
        let pages: [LibraryPage] = [.clipboard, .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updateDrag(
            translation: CGSize(width: -50, height: 0), selectedPage: pages[0],
            pages: pages, geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        motion.interrupt()
        XCTAssertFalse(motion.isDragging)
        XCTAssertNil(motion.transition)
        XCTAssertNil(motion.release(translation: CGSize(width: -50, height: 0), geometry: geometry, reduceMotion: false, at: now))
        motion.select(1, selectedPage: pages[0], pages: pages, reduceMotion: false, at: now)
        let settlement = try XCTUnwrap(motion.transition?.settlement)
        motion.interrupt()
        motion.finishSettlement(settlement.id)
        XCTAssertNil(motion.transition)
    }

    func testReducedMotionFadesTheSamePagesWithoutSidewaysMovement() {
        let geometry = ListSelectorGeometry(widths: [80, 160, 100])
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.updateDrag(
            translation: CGSize(width: -64, height: 0), selectedPage: pages[0],
            pages: pages, geometry: geometry, layoutDirection: .leftToRight, at: now
        )
        let frame = motion.frame(pages: pages, selectedPage: pages[0], at: now)
        for page in frame.retainedPages {
            XCTAssertEqual(frame.offset(for: page, width: 400, layoutDirection: .leftToRight, reduceMotion: true), 0)
            XCTAssertEqual(frame.offset(for: page, width: 400, layoutDirection: .rightToLeft, reduceMotion: true), 0)
            XCTAssertEqual(frame.opacity(for: page, reduceMotion: true), 0.5)
        }
        motion.cancelDrag(reduceMotion: true, at: now)
        XCTAssertEqual(motion.transition?.settlement?.duration, 0.12)
        let finished = motion.frame(pages: pages, selectedPage: pages[0], at: now.addingTimeInterval(1))
        XCTAssertEqual(finished.opacity(for: pages[0], reduceMotion: true), 1)
        XCTAssertEqual(finished.opacity(for: pages[1], reduceMotion: true), 0)
    }

    func testNewListEntranceUsesOnlyOriginAndNewPageAcrossSeveralLists() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.select(
            3, selectedPage: pages[0], pages: pages, reduceMotion: false,
            directEntrance: true, at: now
        )
        let frame = motion.frame(
            pages: pages, selectedPage: pages[3], at: now.addingTimeInterval(0.12)
        )

        XCTAssertEqual(frame.retainedPages, [pages[0], pages[3]])
        XCTAssertGreaterThan(frame.offset(for: pages[3], width: 400, layoutDirection: .leftToRight, reduceMotion: false), 0)
        XCTAssertLessThan(frame.offset(for: pages[3], width: 400, layoutDirection: .leftToRight, reduceMotion: false), 400)
        XCTAssertEqual(frame.weight(for: pages[1]), 0)
        XCTAssertEqual(frame.weight(for: pages[2]), 0)
        XCTAssertEqual(frame.weight(for: pages[0]) + frame.weight(for: pages[3]), 1, accuracy: 0.001)
        let geometry = ListSelectorGeometry(widths: [100, 100, 100, 100])
        let selectorPresentation = frame.selectorPresentation(in: geometry)
        XCTAssertNotNil(selectorPresentation)
        XCTAssertEqual(selectorPresentation?.cursor ?? 0,
                       geometry.centers[0] + (geometry.centers[3] - geometry.centers[0])
                       * (frame.directEntrance?.progress ?? 0), accuracy: 0.001)
        XCTAssertEqual(selectorPresentation?.addProgress, 0)
        let beginning = motion.frame(pages: pages, selectedPage: pages[3], at: now)
            .selectorPresentation(in: geometry)
        XCTAssertEqual(beginning?.cursor, geometry.centers[0])
        XCTAssertEqual(beginning?.addProgress, 0)
    }

    func testAdjacentNewListEntranceStartsAtAddBubble() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID())]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var motion = ListPageMotion()
        motion.select(2, selectedPage: pages[1], pages: pages, reduceMotion: false,
                      directEntrance: true, fromAddPull: true, at: now)
        let geometry = ListSelectorGeometry(widths: [100, 120, 130])

        let beginning = motion.frame(pages: pages, selectedPage: pages[2], at: now)
            .selectorPresentation(in: geometry)
        XCTAssertEqual(beginning?.cursor, geometry.centers[1] + 120 / 2 + 32)
        XCTAssertEqual(beginning?.addProgress, 1)

        let finished = motion.frame(pages: pages, selectedPage: pages[2], at: now.addingTimeInterval(1))
            .selectorPresentation(in: geometry)
        XCTAssertEqual(finished?.cursor, geometry.centers[2])
        XCTAssertEqual(finished?.addProgress, 0)
    }

    func testReducedMotionNewListEntranceFadesAtDestinationWithoutLensTravel() {
        let pages: [LibraryPage] = [.clipboard, .list(UUID()), .list(UUID()), .list(UUID())]
        let geometry = ListSelectorGeometry(widths: [100, 110, 120, 130])
        let now = Date(timeIntervalSinceReferenceDate: 100)

        for fromAddPull in [false, true] {
            var motion = ListPageMotion()
            let source = fromAddPull ? pages[2] : pages[0]
            motion.select(3, selectedPage: source, pages: pages, reduceMotion: true,
                          directEntrance: true, fromAddPull: fromAddPull, at: now)
            for elapsed in [0.0, 0.06, 0.12] {
                let frame = motion.frame(pages: pages, selectedPage: pages[3],
                                         at: now.addingTimeInterval(elapsed))
                let selector = frame.selectorPresentation(in: geometry, reduceMotion: true)
                XCTAssertEqual(selector?.cursor, geometry.centers[3])
                XCTAssertEqual(selector?.addProgress, 0)
                XCTAssertEqual(frame.offset(for: pages[3], width: 400,
                                            layoutDirection: .leftToRight, reduceMotion: true), 0)
            }
        }
    }

}
