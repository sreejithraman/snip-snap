import SnipSnapCore
import SwiftUI

enum ListAddCueLayout {
    // Add overscroll uses a fixed point scale even when the page is wider or narrower.
    static let pullCoordinateWidth: CGFloat = 320
    static let diameter: CGFloat = 56
    static let edgeInset: CGFloat = 42
    static let armedScale: CGFloat = 1.06
    static let clearance: CGFloat = edgeInset + diameter * armedScale / 2 + 8
    static let revealFraction: CGFloat = clearance / pullCoordinateWidth
}

/// One page coordinate drives the strip, content, and composer. A settling
/// transition keeps its starting value so a new drag can pick up mid-animation.
struct ListPageMotion: Equatable {
    struct Settlement: Equatable {
        enum Curve: Equatable { case easeOut, edgeSpring }
        enum Completion: Equatable {
            case navigate
            case createList
            case cancelNewList
            case cancelNewListFromButton
        }

        let id = UUID()
        let startedAt: Date
        let duration: TimeInterval
        let destination: CGFloat
        let curve: Curve
        let completion: Completion

        var createsList: Bool {
            if case .createList = completion { return true }
            return false
        }

        var cancelsNewList: Bool {
            switch completion {
            case .cancelNewList, .cancelNewListFromButton: true
            default: false
            }
        }
    }

    struct Transition: Equatable {
        let pages: [LibraryPage]
        let source: LibraryPage
        var position: CGFloat
        var pageWidth: CGFloat = ListAddCueLayout.pullCoordinateWidth
        var settlement: Settlement?
        var directEntrance = false
        var directDestination: Int?
        var directEntranceInitialProgress: CGFloat = 0
        var showsAddCueDuringEntrance = false
        var beganInSelector = false
        var creationProgressAtRelease: CGFloat = 0
        var cancelProgressAtRelease: CGFloat = 0

        func remainingFraction(at date: Date) -> CGFloat {
            guard let settlement else { return 1 }
            let elapsed = date.timeIntervalSince(settlement.startedAt)
            if elapsed >= settlement.duration { return 0 }
            if elapsed <= 0 { return 1 }
            let progress = elapsed / settlement.duration
            switch settlement.curve {
            case .easeOut:
                return CGFloat(pow(1 - progress, 3))
            case .edgeSpring:
                let response = 5.0
                let elapsed = response * progress
                let remaining = (1 + elapsed) * exp(-elapsed)
                let endpoint = (1 + response) * exp(-response)
                return CGFloat((remaining - endpoint) / (1 - endpoint))
            }
        }

        func position(at date: Date) -> CGFloat {
            guard let settlement else { return position }
            return settlement.destination + (position - settlement.destination) * remainingFraction(at: date)
        }
    }

    private struct Drag: Equatable {
        let originCursor: CGFloat
        let sourceIndex: Int
        let direction: CGFloat
        let pagePositionCorrection: CGFloat
        let addProgressCorrection: CGFloat
        var cursor: CGFloat
        var reachedAdd = false

        private func remainingCorrection(in geometry: ListSelectorGeometry) -> CGFloat {
            let thresholdCursor = (geometry.centers.last ?? 0) + ListSelectorGeometry.pullThreshold
            let outwardDistance = max(1, thresholdCursor - originCursor)
            let fadeDistance = cursor >= originCursor
                ? min(ListSelectorGeometry.pullThreshold, outwardDistance)
                : ListSelectorGeometry.pullThreshold
            return max(0, 1 - abs(cursor - originCursor) / fadeDistance)
        }

        func presentedAddProgress(in geometry: ListSelectorGeometry) -> CGFloat {
            let rawProgress = geometry.pullProgress(at: cursor)
            if rawProgress >= 1 { return 1 }
            let progress = ListPageMotion.presentedAddProgress(rawProgress, reachedThreshold: reachedAdd)
            return min(1, max(0, progress + addProgressCorrection * remainingCorrection(in: geometry)))
        }

        func pagePosition(in geometry: ListSelectorGeometry, presentedAddProgress: CGFloat) -> CGFloat {
            return geometry.pagePosition(at: cursor, presentedAddProgress: presentedAddProgress)
                + pagePositionCorrection * remainingCorrection(in: geometry)
        }
    }

    private struct PageDrag: Equatable {
        let sourceIndex: Int
        let neighborIndex: Int
        let originPosition: CGFloat
        let pageWidth: CGFloat
        let direction: CGFloat
        let isTrailingEdge: Bool
        let isNewListCancel: Bool
        var reachedCreationThreshold = false
        var reachedCancelThreshold = false

        var creationThreshold: CGFloat { min(220, pageWidth * 0.55) }
        var cancelThreshold: CGFloat { min(175, pageWidth * 0.45) }

        func cancelProgress(for translation: CGSize) -> CGFloat {
            guard isNewListCancel else { return 0 }
            return min(1, max(0, translation.width * direction) / cancelThreshold)
        }

        func presentedCancelProgress(for translation: CGSize) -> CGFloat {
            ListPageMotion.presentedAddProgress(
                cancelProgress(for: translation), reachedThreshold: reachedCancelThreshold
            )
        }

        func creationProgress(for translation: CGSize) -> CGFloat {
            guard isTrailingEdge else { return 0 }
            let outwardDistance = max(0, -translation.width * direction)
            return min(1, outwardDistance / creationThreshold)
        }

        func presentedCreationProgress(for translation: CGSize) -> CGFloat {
            let progress = creationProgress(for: translation)
            return ListPageMotion.presentedAddProgress(progress, reachedThreshold: reachedCreationThreshold)
        }

        func clampedPosition(for translation: CGSize) -> CGFloat {
            if isNewListCancel {
                let distance = max(0, translation.width * direction)
                let presentedDistance = max(distance, presentedCancelProgress(for: translation) * cancelThreshold)
                let resisted = presentedDistance / (1 + presentedDistance / (pageWidth * 0.7))
                let fraction = min(0.8, resisted / pageWidth)
                return originPosition + CGFloat(neighborIndex - sourceIndex) * fraction
            }
            let position = originPosition - translation.width * direction / pageWidth
            if neighborIndex == sourceIndex {
                let edge = CGFloat(sourceIndex)
                let outward = sourceIndex == 0 ? min(0, position - edge) : max(0, position - edge)
                // Follow the finger readily at first, then increase resistance
                // while keeping even a long pull within part of the page.
                let limit = min(112, pageWidth * 0.28)
                let pull = abs(outward) * pageWidth
                let scaledPull = pull * 0.8
                let resisted = limit * scaledPull / (limit + scaledPull)
                var extraReveal: CGFloat = 0
                if isTrailingEdge {
                    let thresholdPull = creationThreshold * 0.8
                    let thresholdResisted = limit * thresholdPull / (limit + thresholdPull)
                    let clearance = max(0, ListAddCueLayout.clearance - thresholdResisted)
                    let progress = presentedCreationProgress(for: translation)
                    let eased = progress * progress * (3 - 2 * progress)
                    extraReveal = clearance * eased
                }
                let visiblePull = resisted + extraReveal
                let coordinateWidth = isTrailingEdge
                    ? ListAddCueLayout.pullCoordinateWidth : pageWidth
                return edge + (outward < 0 ? -visiblePull : visiblePull) / coordinateWidth
            }
            let lowerBound = min(CGFloat(min(sourceIndex, neighborIndex)), originPosition)
            let upperBound = max(CGFloat(max(sourceIndex, neighborIndex)), originPosition)
            return min(
                upperBound,
                max(lowerBound, position)
            )
        }
    }

    static let edgeReturnDuration: TimeInterval = 0.44

    private static func presentedAddProgress(_ rawProgress: CGFloat, reachedThreshold: Bool) -> CGFloat {
        reachedThreshold && rawProgress < 1 ? sqrt(rawProgress) : rawProgress
    }

    private(set) var transition: Transition?
    private var drag: Drag?
    private var pageDrag: PageDrag?
    private var rejectsSelectorDrag = false
    private var expansion = ListSelectorExpansion()
    private(set) var pageCreationProgress: CGFloat = 0
    private(set) var newListCancelProgress: CGFloat = 0
    private var selectorCreationProgress: CGFloat = 0
    private(set) var isCreatingFromEdge = false

    var isDragging: Bool { drag != nil || pageDrag != nil }
    var isSelectorDragging: Bool { drag != nil }
    var isEnteringNewList: Bool { transition?.directEntrance == true }
    var dragCursor: CGFloat? { drag?.cursor }
    var dragDistance: CGFloat { expansion.distance }

    mutating func updateDrag(
        translation: CGSize,
        selectedPage: LibraryPage,
        pages: [LibraryPage],
        geometry: ListSelectorGeometry,
        pageWidth: CGFloat = ListAddCueLayout.pullCoordinateWidth,
        layoutDirection: LayoutDirection,
        at date: Date
    ) {
        guard !rejectsSelectorDrag else { return }
        if isCreatingFromEdge {
            rejectsSelectorDrag = true
            return
        }
        if drag == nil {
            guard abs(translation.width) > abs(translation.height),
                  let selected = pages.firstIndex(of: selectedPage) else { return }
            if let transition {
                let position = transition.position(at: date)
                let lastPage = CGFloat(max(0, transition.pages.count - 1))
                if transition.directEntrance || position < 0
                    || (position > lastPage && (!transition.beganInSelector || transition.settlement == nil)) {
                    rejectsSelectorDrag = true
                    return
                }
            }
            let visibleFrame = frame(pages: pages, selectedPage: selectedPage, at: date)
            let visibleAddProgress = visibleFrame.creationProgress(
                dragProgress: pageCreationProgress, holdsAtAdd: isCreatingFromEdge
            )
            isCreatingFromEdge = false
            let position = transition?.position(at: date) ?? CGFloat(selected)
            pageDrag = nil
            let origin = visibleFrame.selectorPresentation(in: geometry)?.cursor
                ?? (visibleAddProgress > 0
                    ? visibleFrame.selectorPullCursor(
                        in: geometry, progress: visibleAddProgress, holdsAtAdd: false
                    )
                    : geometry.cursor(at: position))
            drag = Drag(
                originCursor: origin,
                sourceIndex: selected,
                direction: layoutDirection == .rightToLeft ? -1 : 1,
                pagePositionCorrection: visibleFrame.position - geometry.pagePosition(
                    at: origin, presentedAddProgress: visibleAddProgress
                ),
                addProgressCorrection: visibleAddProgress - geometry.pullProgress(at: origin),
                cursor: origin
            )
            transition = Transition(
                pages: pages, source: selectedPage, position: geometry.pagePosition(at: origin),
                pageWidth: pageWidth,
                beganInSelector: true
            )
        }
        guard var drag else { return }
        drag.cursor = drag.originCursor - translation.width * drag.direction
        let rawProgress = geometry.pullProgress(at: drag.cursor)
        if rawProgress >= 1 { drag.reachedAdd = true }
        self.drag = drag
        selectorCreationProgress = drag.presentedAddProgress(in: geometry)
        expansion.update(distance: abs(drag.cursor - drag.originCursor))
        transition?.position = drag.pagePosition(in: geometry, presentedAddProgress: selectorCreationProgress)
    }

    mutating func updatePageDrag(
        translation: CGSize,
        selectedPage: LibraryPage,
        pages: [LibraryPage],
        pageWidth: CGFloat,
        layoutDirection: LayoutDirection,
        isStart: Bool,
        cancelTo: LibraryPage? = nil,
        at date: Date
    ) {
        guard pageWidth > 0, pages.count > 1, !isCreatingFromEdge else { return }
        if pageDrag == nil {
            guard isStart, transition?.settlement == nil, drag == nil,
                  abs(translation.width) > abs(translation.height),
                  let source = pages.firstIndex(of: selectedPage) else { return }
            isCreatingFromEdge = false
            let position = transition?.position(at: date) ?? CGFloat(source)
            let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
            let step = -translation.width * direction >= 0 ? 1 : -1
            let cancelTarget = cancelTo.flatMap { pages.firstIndex(of: $0) }
            pageDrag = PageDrag(
                sourceIndex: source,
                neighborIndex: cancelTarget ?? min(pages.count - 1, max(0, source + step)),
                originPosition: position,
                pageWidth: pageWidth,
                direction: direction,
                isTrailingEdge: cancelTarget == nil && source == pages.count - 1 && step > 0,
                isNewListCancel: cancelTarget != nil
            )
            transition = Transition(pages: pages, source: selectedPage, position: position,
                                    pageWidth: pageWidth)
            transition?.directEntrance = cancelTarget != nil
            transition?.directDestination = cancelTarget
        }
        guard var pageDrag else { return }
        guard transition?.pages == pages else {
            interrupt()
            return
        }
        let rawProgress = pageDrag.creationProgress(for: translation)
        if rawProgress >= 1 { pageDrag.reachedCreationThreshold = true }
        pageCreationProgress = pageDrag.presentedCreationProgress(for: translation)
        if pageDrag.cancelProgress(for: translation) >= 1 {
            pageDrag.reachedCancelThreshold = true
        }
        newListCancelProgress = pageDrag.presentedCancelProgress(for: translation)
        transition?.position = pageDrag.clampedPosition(for: translation)
        self.pageDrag = pageDrag
    }

    mutating func releasePageDrag(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        reduceMotion: Bool,
        at date: Date
    ) -> Release? {
        guard let pageDrag, transition != nil else { return nil }
        self.pageDrag = nil
        if pageDrag.isNewListCancel {
            let cancels = pageDrag.cancelProgress(for: translation) >= 1
            newListCancelProgress = pageDrag.presentedCancelProgress(for: translation)
            transition?.position = pageDrag.clampedPosition(for: translation)
            let destination = cancels ? pageDrag.neighborIndex : pageDrag.sourceIndex
            let completion: Settlement.Completion = cancels ? .cancelNewList : .navigate
            settle(to: destination, reduceMotion: reduceMotion, springBack: !cancels,
                   completion: completion, at: date)
            return cancels ? .cancelNewList : .select(destination)
        }
        let distance = -translation.width * pageDrag.direction
        let projectedDistance = -predictedEndTranslation.width * pageDrag.direction
        let createsList = pageDrag.creationProgress(for: translation) >= 1
        pageCreationProgress = pageDrag.presentedCreationProgress(for: translation)
        transition?.position = pageDrag.clampedPosition(for: translation)
        if createsList {
            holdCommittedPagePull(at: date)
            return .createList
        }
        let threshold = min(72, pageDrag.pageWidth * 0.22)
        let projectedThreshold = min(100, pageDrag.pageWidth * 0.3)
        let direction: CGFloat = pageDrag.neighborIndex > pageDrag.sourceIndex ? 1 : -1
        let advances = distance * direction >= threshold
            || projectedDistance * direction >= projectedThreshold
        let destination = advances ? pageDrag.neighborIndex : pageDrag.sourceIndex
        settle(to: destination, reduceMotion: reduceMotion,
               springBack: pageDrag.neighborIndex == pageDrag.sourceIndex,
               at: date)
        return .select(destination)
    }

    mutating func cancelPageDrag(reduceMotion: Bool, at date: Date) {
        guard let pageDrag else { return }
        self.pageDrag = nil
        settle(to: pageDrag.sourceIndex, reduceMotion: reduceMotion,
               springBack: pageDrag.neighborIndex == pageDrag.sourceIndex, at: date)
    }

    enum Release: Equatable {
        case select(Int)
        case createList
        case cancelNewList
    }

    mutating func release(
        translation: CGSize,
        geometry: ListSelectorGeometry,
        reduceMotion: Bool,
        at date: Date
    ) -> Release? {
        defer { rejectsSelectorDrag = false }
        guard var drag else { return nil }
        // Once the drag has claimed the horizontal axis, a diagonal release
        // still ends it. Gesture-state reset handles cancellation separately.
        drag.cursor = drag.originCursor - translation.width * drag.direction
        let rawProgress = geometry.pullProgress(at: drag.cursor)
        selectorCreationProgress = drag.presentedAddProgress(in: geometry)
        transition?.position = drag.pagePosition(in: geometry, presentedAddProgress: selectorCreationProgress)
        self.drag = nil
        if rawProgress >= 1 {
            expansion.update(distance: nil)
            isCreatingFromEdge = true
            return .createList
        }
        let destination = geometry.nearestIndex(to: drag.cursor)
        settle(to: destination, reduceMotion: reduceMotion,
               springBack: selectorCreationProgress > 0, at: date)
        return .select(destination)
    }

    mutating func cancelDrag(reduceMotion: Bool, at date: Date) {
        defer { rejectsSelectorDrag = false }
        guard let drag else { return }
        self.drag = nil
        settle(to: drag.sourceIndex, reduceMotion: reduceMotion,
               springBack: selectorCreationProgress > 0, at: date)
    }

    @discardableResult
    mutating func select(
        _ destination: Int,
        selectedPage: LibraryPage,
        pages: [LibraryPage],
        reduceMotion: Bool,
        directEntrance: Bool = false,
        fromAddPull: Bool = false,
        at date: Date
    ) -> Bool {
        guard pages.indices.contains(destination), let source = pages.firstIndex(of: selectedPage),
              directEntrance || (!isEnteringNewList && !isCreatingFromEdge) else { return false }
        isCreatingFromEdge = false
        drag = nil
        pageDrag = nil
        if transition == nil || directEntrance {
            transition = Transition(pages: pages, source: selectedPage, position: CGFloat(source))
        }
        transition?.directEntrance = directEntrance
        transition?.directDestination = directEntrance ? destination : nil
        transition?.showsAddCueDuringEntrance = directEntrance && fromAddPull
        settle(to: destination, reduceMotion: reduceMotion, at: date)
        return true
    }

    mutating func beginNewListEntrance(
        pages: [LibraryPage], cancellationOrigin: LibraryPage,
        reduceMotion: Bool, at date: Date
    ) {
        guard pages.count >= 2 else { return }
        let destination = pages.count - 1
        let fromAddPull = isCreatingFromEdge
        let visualSource = fromAddPull ? pages[pages.count - 2] : cancellationOrigin
        if fromAddPull,
           let oldSourceIndex = transition?.pages.firstIndex(of: visualSource),
           let heldPosition = transition?.position,
           heldPosition > CGFloat(oldSourceIndex) {
            let pageWidth = transition?.pageWidth ?? ListAddCueLayout.pullCoordinateWidth
            let pulledDistance = (heldPosition - CGFloat(oldSourceIndex))
                * ListAddCueLayout.pullCoordinateWidth
            let initialProgress = min(0.5, max(0, pulledDistance / pageWidth))
            transition = Transition(
                pages: pages, source: visualSource,
                position: CGFloat(destination - 1) + initialProgress,
                pageWidth: pageWidth
            )
            transition?.directEntrance = true
            transition?.directDestination = destination
            transition?.directEntranceInitialProgress = initialProgress
            transition?.showsAddCueDuringEntrance = true
            isCreatingFromEdge = false
            settle(to: destination, reduceMotion: reduceMotion, at: date)
            return
        }
        select(destination, selectedPage: visualSource, pages: pages,
               reduceMotion: reduceMotion, directEntrance: true,
               fromAddPull: fromAddPull, at: date)
    }

    @discardableResult
    mutating func beginNewListCancellation(
        from source: LibraryPage, to origin: LibraryPage, pages: [LibraryPage],
        reduceMotion: Bool, at date: Date
    ) -> Bool {
        guard let sourceIndex = pages.firstIndex(of: source),
              let originIndex = pages.firstIndex(of: origin),
              originIndex < sourceIndex,
              transition?.settlement?.cancelsNewList != true else { return false }

        var initialProgress: CGFloat = 0
        if let current = transition, current.pages == pages, current.directEntrance {
            if current.source == origin, current.directDestination == sourceIndex {
                let forwardProgress = (current.position(at: date) - CGFloat(originIndex))
                    / CGFloat(sourceIndex - originIndex)
                initialProgress = 1 - min(1, max(0, forwardProgress))
            } else if current.source == source, current.directDestination == originIndex {
                let reverseProgress = (current.position(at: date) - CGFloat(sourceIndex))
                    / CGFloat(originIndex - sourceIndex)
                initialProgress = min(1, max(0, reverseProgress))
            }
        }

        interrupt()
        transition = Transition(
            pages: pages, source: source,
            position: CGFloat(sourceIndex)
                + CGFloat(originIndex - sourceIndex) * initialProgress
        )
        transition?.directEntrance = true
        transition?.directDestination = originIndex
        settle(to: originIndex, reduceMotion: reduceMotion,
               completion: .cancelNewListFromButton, at: date)
        return true
    }

    mutating func returnFromCommittedCreation(reduceMotion: Bool, at date: Date) {
        guard isCreatingFromEdge, let source = transition?.source,
              let sourceIndex = transition?.pages.firstIndex(of: source) else { return }
        isCreatingFromEdge = false
        transition?.settlement = nil
        settle(to: sourceIndex, reduceMotion: reduceMotion, springBack: true, at: date)
    }

    mutating func returnFromAdd(
        to page: LibraryPage, pages: [LibraryPage], reduceMotion: Bool, at date: Date
    ) {
        guard let destination = pages.firstIndex(of: page),
              let visualSource = pages.last else {
            interrupt()
            return
        }
        let heldPagePosition: CGFloat?
        if isCreatingFromEdge, let position = transition?.position,
           position > CGFloat(pages.count - 1) {
            heldPagePosition = position
        } else {
            heldPagePosition = nil
        }
        let beganInSelector = transition?.beganInSelector == true
        let pageWidth = transition?.pageWidth ?? ListAddCueLayout.pullCoordinateWidth
        transition = Transition(
            pages: pages, source: visualSource,
            position: heldPagePosition ?? CGFloat(destination),
            pageWidth: pageWidth,
            beganInSelector: beganInSelector
        )
        transition?.creationProgressAtRelease = 1
        isCreatingFromEdge = false
        drag = nil
        pageDrag = nil
        settle(to: destination, reduceMotion: reduceMotion, springBack: true, at: date)
    }

    private mutating func settle(
        to destination: Int, reduceMotion: Bool, springBack: Bool = false,
        completion: Settlement.Completion = .navigate, at date: Date
    ) {
        expansion.update(distance: nil)
        guard var transition else { return }
        let presentedCreationProgress: CGFloat
        if let previousSettlement = transition.settlement {
            presentedCreationProgress = previousSettlement.createsList ? 1
                : transition.creationProgressAtRelease * transition.remainingFraction(at: date)
        } else {
            presentedCreationProgress = transition.creationProgressAtRelease
        }
        transition.position = transition.position(at: date)
        transition.creationProgressAtRelease = max(
            presentedCreationProgress,
            max(pageCreationProgress, selectorCreationProgress)
        )
        transition.cancelProgressAtRelease = max(
            transition.cancelProgressAtRelease, newListCancelProgress
        )
        pageCreationProgress = 0
        newListCancelProgress = 0
        selectorCreationProgress = 0
        let useSpring = springBack && !reduceMotion
        transition.settlement = Settlement(
            startedAt: date,
            duration: useSpring ? Self.edgeReturnDuration : Self.duration(reduceMotion: reduceMotion),
            destination: CGFloat(destination),
            curve: useSpring ? .edgeSpring : .easeOut,
            completion: completion
        )
        self.transition = transition
    }

    private mutating func holdCommittedPagePull(at date: Date) {
        guard var transition else { return }
        transition.creationProgressAtRelease = 1
        transition.settlement = Settlement(
            startedAt: date,
            duration: 0.01,
            destination: transition.position,
            curve: .easeOut,
            completion: .createList
        )
        pageCreationProgress = 0
        isCreatingFromEdge = true
        self.transition = transition
    }

    mutating func finishSettlement(_ id: UUID) {
        guard transition?.settlement?.id == id else { return }
        let rejectedGestureIsStillActive = rejectsSelectorDrag
        interrupt()
        rejectsSelectorDrag = rejectedGestureIsStillActive
    }

    mutating func interrupt() {
        expansion.update(distance: nil)
        pageCreationProgress = 0
        newListCancelProgress = 0
        selectorCreationProgress = 0
        rejectsSelectorDrag = false
        isCreatingFromEdge = false
        drag = nil
        pageDrag = nil
        transition = nil
    }

    static func duration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0.12 : 0.24 }

    func frame(pages: [LibraryPage], selectedPage: LibraryPage, at date: Date) -> ListPageFrame {
        guard let transition else {
            return ListPageFrame(
                pages: pages,
                position: CGFloat(pages.firstIndex(of: selectedPage) ?? 0),
                retainedPages: [selectedPage],
                isMoving: false
            )
        }
        let position = transition.position(at: date)
        let contentTarget = transition.settlement?.destination
            ?? CGFloat(transition.pages.firstIndex(of: selectedPage) ?? 0)
        let blocksInteraction = abs(position - contentTarget) > 0.001
            || isCreatingFromEdge || transition.settlement?.createsList == true
        let settlingCreationProgress: CGFloat
        if let settlement = transition.settlement {
            if settlement.createsList {
                settlingCreationProgress = 1
            } else {
                settlingCreationProgress = transition.creationProgressAtRelease
                    * transition.remainingFraction(at: date)
            }
        } else {
            settlingCreationProgress = selectorCreationProgress
        }
        let settlingCancelProgress: CGFloat
        if transition.settlement != nil {
            settlingCancelProgress = transition.cancelProgressAtRelease
                * transition.remainingFraction(at: date)
        } else {
            settlingCancelProgress = newListCancelProgress
        }
        if transition.directEntrance,
           let sourceIndex = transition.pages.firstIndex(of: transition.source),
           let destinationIndex = transition.directDestination,
           transition.pages.indices.contains(destinationIndex),
           destinationIndex != sourceIndex {
            let progress = min(1, max(0,
                (position - CGFloat(sourceIndex)) / CGFloat(destinationIndex - sourceIndex)
            ))
            let initialProgress = transition.directEntranceInitialProgress
            let selectorProgress = min(1, max(0,
                (progress - initialProgress) / max(0.001, 1 - initialProgress)
            ))
            let destination = transition.pages[destinationIndex]
            return ListPageFrame(
                pages: transition.pages,
                position: position,
                retainedPages: [transition.source, destination],
                isMoving: blocksInteraction,
                edgeAddProgress: transition.showsAddCueDuringEntrance
                    ? 1 - selectorProgress : settlingCreationProgress,
                edgeCancelProgress: settlingCancelProgress,
                directEntrance: .init(
                    source: transition.source, destination: destination,
                    progress: progress, selectorProgress: selectorProgress,
                    showsAddCue: transition.showsAddCueDuringEntrance
                )
            )
        }
        var indices = Set([Int(floor(position)), Int(ceil(position))])
        if let source = transition.pages.firstIndex(of: transition.source) { indices.insert(source) }
        if let target = transition.settlement?.destination { indices.insert(Int(target)) }
        return ListPageFrame(
            pages: transition.pages,
            position: position,
            retainedPages: indices.sorted().compactMap { transition.pages.indices.contains($0) ? transition.pages[$0] : nil },
            isMoving: blocksInteraction,
            edgeAddProgress: settlingCreationProgress,
            edgeCancelProgress: settlingCancelProgress
        )
    }
}

struct ListPageFrame {
    struct DirectEntrance {
        let source: LibraryPage
        let destination: LibraryPage
        let progress: CGFloat
        let selectorProgress: CGFloat
        let showsAddCue: Bool
    }

    let pages: [LibraryPage]
    let position: CGFloat
    let retainedPages: [LibraryPage]
    let isMoving: Bool
    var edgeAddProgress: CGFloat = 0
    var edgeCancelProgress: CGFloat = 0
    var directEntrance: DirectEntrance? = nil

    var boundedPosition: CGFloat {
        min(CGFloat(max(0, pages.count - 1)), max(0, position))
    }

    func creationProgress(dragProgress: CGFloat, holdsAtAdd: Bool) -> CGFloat {
        if holdsAtAdd { return 1 }
        return min(1, max(dragProgress, edgeAddProgress))
    }

    func selectorPullCursor(in geometry: ListSelectorGeometry, progress: CGFloat, holdsAtAdd: Bool) -> CGFloat {
        let base = holdsAtAdd ? (geometry.centers.last ?? 0) : geometry.cursor(at: position)
        return base + progress * ListSelectorGeometry.pullThreshold
    }

    func offset(for page: LibraryPage, width: CGFloat, layoutDirection: LayoutDirection, reduceMotion: Bool) -> CGFloat {
        if let directEntrance {
            guard !reduceMotion else { return 0 }
            let direction: CGFloat = (pages.firstIndex(of: directEntrance.destination) ?? 0)
                >= (pages.firstIndex(of: directEntrance.source) ?? 0) ? 1 : -1
            let travel = page == directEntrance.source ? -directEntrance.progress
                : page == directEntrance.destination ? 1 - directEntrance.progress : 0
            return travel * direction * width * (layoutDirection == .rightToLeft ? -1 : 1)
        }
        guard !reduceMotion, let index = pages.firstIndex(of: page) else { return 0 }
        let coordinateWidth = index == pages.count - 1 && position > CGFloat(index)
            ? ListAddCueLayout.pullCoordinateWidth : width
        return (CGFloat(index) - position) * coordinateWidth * (layoutDirection == .rightToLeft ? -1 : 1)
    }

    func opacity(for page: LibraryPage, reduceMotion: Bool) -> Double {
        if let directEntrance, reduceMotion {
            return Double(page == directEntrance.source ? 1 - directEntrance.progress
                : page == directEntrance.destination ? directEntrance.progress : 0)
        }
        guard reduceMotion, let index = pages.firstIndex(of: page) else { return 1 }
        return Double(max(0, 1 - abs(CGFloat(index) - position)))
    }

    func weight(for page: LibraryPage) -> CGFloat {
        if let directEntrance {
            return page == directEntrance.source ? 1 - directEntrance.progress
                : page == directEntrance.destination ? directEntrance.progress : 0
        }
        guard let index = pages.firstIndex(of: page) else { return 0 }
        return max(0, 1 - abs(CGFloat(index) - boundedPosition))
    }

    func selectorPresentation(
        in geometry: ListSelectorGeometry, reduceMotion: Bool = false
    ) -> (cursor: CGFloat, addProgress: CGFloat)? {
        guard let directEntrance,
              let source = pages.firstIndex(of: directEntrance.source),
              let destination = pages.firstIndex(of: directEntrance.destination),
              destination != source,
              geometry.centers.indices.contains(source),
              geometry.centers.indices.contains(destination) else { return nil }
        if reduceMotion {
            return (cursor: geometry.centers[destination], addProgress: 0)
        }
        if !directEntrance.showsAddCue {
            let sourceCenter = geometry.centers[source]
            let destinationCenter = geometry.centers[destination]
            return (
                cursor: sourceCenter + (destinationCenter - sourceCenter) * directEntrance.selectorProgress,
                addProgress: 0
            )
        }
        guard destination > source else { return nil }
        let previous = destination - 1
        let addCenter = geometry.centers[previous] + geometry.widths[previous] / 2 + 32
        return (
            cursor: addCenter + (geometry.centers[destination] - addCenter) * directEntrance.selectorProgress,
            addProgress: 1 - directEntrance.selectorProgress
        )
    }
}

/// Geometry stays independent of list identity: the plus is an overscroll destination,
/// never an entry in the library or in the strip's resting layout.
struct ListSelectorGeometry {
    let widths: [CGFloat]
    static let spacing: CGFloat = 8
    static let pullThreshold: CGFloat = 150

    let centers: [CGFloat]

    init(widths: [CGFloat]) {
        self.widths = widths
        var edge: CGFloat = 0
        centers = widths.map { width in
            defer { edge += width + Self.spacing }
            return edge + width / 2
        }
    }

    var plusCenter: CGFloat {
        (centers.last ?? 0) + (widths.last ?? 0) / 2 + 32
    }

    func pagePosition(at cursor: CGFloat, presentedAddProgress: CGFloat? = nil) -> CGFloat {
        guard let first = centers.first, cursor > first else { return 0 }
        guard let upper = centers.firstIndex(where: { $0 > cursor }) else {
            // Move the page enough to reveal the add cue while the tab strip stays centered.
            return CGFloat(max(0, centers.count - 1))
                + ListAddCueLayout.revealFraction * (presentedAddProgress ?? pullProgress(at: cursor))
        }
        let lower = upper - 1
        return CGFloat(lower) + (cursor - centers[lower]) / (centers[upper] - centers[lower])
    }

    func cursor(at pagePosition: CGFloat) -> CGFloat {
        guard !centers.isEmpty else { return 0 }
        let position = min(CGFloat(centers.count - 1), max(0, pagePosition))
        let lower = Int(floor(position))
        let upper = min(lower + 1, centers.count - 1)
        return centers[lower] + (centers[upper] - centers[lower]) * (position - CGFloat(lower))
    }

    func nearestIndex(to position: CGFloat) -> Int {
        centers.indices.min { abs(centers[$0] - position) < abs(centers[$1] - position) } ?? 0
    }

    func lensWidth(at position: CGFloat) -> CGFloat {
        guard let first = widths.first else { return 96 }
        guard let upper = centers.firstIndex(where: { $0 > position }) else { return widths.last ?? first }
        guard upper > 0 else { return first }
        let lower = upper - 1
        let fraction = (position - centers[lower]) / (centers[upper] - centers[lower])
        let blend = fraction * fraction * (3 - 2 * fraction)
        return widths[lower] + (widths[upper] - widths[lower]) * blend
    }

    func pullProgress(at position: CGFloat) -> CGFloat {
        min(1, max(0, position - (centers.last ?? 0)) / Self.pullThreshold)
    }

    func resisted(_ position: CGFloat) -> CGFloat {
        let first = centers.first ?? 0
        let last = centers.last ?? 0
        if position < first { return first + (position - first) * 0.3 }
        if position > last { return last + (position - last) * 0.35 }
        return position
    }
}

struct ListSelectorExpansion: Equatable {
    private(set) var distance: CGFloat = 0

    mutating func update(distance: CGFloat?) {
        self.distance = distance.map { max(self.distance, $0) } ?? 0
    }
}
