import Foundation

enum InboxPinnedHeaderGlass {
    static func hasScrolled(visibleOriginY: CGFloat) -> Bool {
        visibleOriginY > 0.5
    }

    static func isVisible(isPinned: Bool, hasScrolled: Bool) -> Bool {
        isPinned && hasScrolled
    }

    static func updatedSections(
        _ sections: Set<UUID>,
        sectionID: UUID,
        isPinned: Bool
    ) -> Set<UUID>? {
        guard sections.contains(sectionID) != isPinned else { return nil }
        var updated = sections
        if isPinned {
            updated.insert(sectionID)
        } else {
            updated.remove(sectionID)
        }
        return updated
    }
}

enum InboxAddedClipRevealDestination: Equatable {
    case scrollViewTop
}

struct InboxAddedClipRevealState {
    private var pendingID: UUID?

    mutating func record(
        clipID: UUID?,
        wasAtTop: Bool,
        isVisibleInModel: Bool,
        visibleIDs: [UUID]
    ) -> InboxAddedClipRevealDestination? {
        guard wasAtTop,
              let clipID,
              isVisibleInModel else {
            pendingID = nil
            return nil
        }
        pendingID = clipID
        return nextDestination(visibleIDs: visibleIDs)
    }

    mutating func nextDestination(
        visibleIDs: [UUID]
    ) -> InboxAddedClipRevealDestination? {
        guard let pendingID,
              visibleIDs.contains(pendingID) else { return nil }
        self.pendingID = nil
        return .scrollViewTop
    }
}

@MainActor
final class InboxListGeometry {
    enum Element: Hashable {
        case row(UUID)
        case sectionFooter(UUID)
        case heading(UUID)
        case entry(ClipListEntryID)
        case dropSurface(ClipListEntryID)
        case sectionFooterDropSurface(UUID)
    }

    struct ScrollSnapshot: Equatable {
        var visibleOrigin: CGPoint = .zero
        var contentHeight: CGFloat = 0
        var viewportHeight: CGFloat = 0
    }

    private var frames: [Element: CGRect] = [:]
    private(set) var scrollSnapshot = ScrollSnapshot()

    func record(_ frame: CGRect, for element: Element) {
        frames[element] = frame
    }

    func remove(_ element: Element) {
        frames.removeValue(forKey: element)
    }

    func retainRows(_ ids: Set<UUID>) {
        frames = frames.filter { element, _ in
            if case .row(let id) = element {
                return ids.contains(id)
            }
            return true
        }
    }

    func updateScroll(_ snapshot: ScrollSnapshot) {
        scrollSnapshot = snapshot
    }

    func pinnedSectionIDs() -> Set<UUID> {
        let pinLine = scrollSnapshot.visibleOrigin.y + 0.5
        let current = frames.compactMap { element, frame -> (UUID, CGFloat)? in
            guard case .heading(let sectionID) = element,
                  frame.minY <= pinLine else { return nil }
            return (sectionID, frame.minY)
        }.max { $0.1 < $1.1 }
        return current.map { [$0.0] } ?? []
    }

    func frame(for element: Element) -> CGRect? {
        frames[element]
    }

    func sectionBodyFrame(
        sectionID: UUID,
        rowIDs: [UUID],
        entryIDs: [ClipListEntryID]
    ) -> CGRect? {
        let entryFrames = entryIDs.compactMap { frames[.entry($0)] }
        let rowFrames = rowIDs.compactMap { frames[.row($0)] }
        let bodyFrames = entryFrames.isEmpty ? rowFrames : entryFrames
        guard let first = bodyFrames.first else {
            return frames[.sectionFooter(sectionID)]
        }
        return bodyFrames.dropFirst().reduce(first) { $0.union($1) }
    }

    func contentPoint(fromLocalPoint point: CGPoint, in element: Element) -> CGPoint? {
        guard let frame = frames[element] else { return nil }
        return CGPoint(x: frame.minX + point.x, y: frame.minY + point.y)
    }

    func contentPoint(fromViewportPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x + scrollSnapshot.visibleOrigin.x,
            y: point.y + scrollSnapshot.visibleOrigin.y
        )
    }

    func viewportPoint(fromContentPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - scrollSnapshot.visibleOrigin.x,
            y: point.y - scrollSnapshot.visibleOrigin.y
        )
    }

    func insertionID(atContentPoint point: CGPoint, among items: [CaptureItem]) -> UUID? {
        items.first { item in
            guard let frame = frames[.row(item.id)] else { return false }
            return point.y < frame.midY
        }?.id
    }

    func hasPlacementFrames(in sectionID: UUID, among items: [CaptureItem]) -> Bool {
        if items.isEmpty {
            return frames[.sectionFooter(sectionID)] != nil
                || frames[.heading(sectionID)] != nil
        }
        return items.contains { frames[.row($0.id)] != nil }
    }

    func dragGapHeight(for ids: [UUID]) -> CGFloat {
        let heights = ids.compactMap { frames[.row($0)]?.height }
        guard heights.count == ids.count else {
            return CGFloat(ids.count) * 72 + CGFloat(max(ids.count - 1, 0)) * 8
        }
        return heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * 8
    }
}
