import Foundation

enum PinnedListHeaderGlass {
    static func hasScrolled(visibleOriginY: CGFloat) -> Bool {
        visibleOriginY > 0.5
    }

    static func isVisible(isPinned: Bool, hasScrolled: Bool) -> Bool {
        isPinned && hasScrolled
    }

    static func updatedLists(
        _ lists: Set<UUID>,
        listID: UUID,
        isPinned: Bool
    ) -> Set<UUID>? {
        guard lists.contains(listID) != isPinned else { return nil }
        var updated = lists
        if isPinned {
            updated.insert(listID)
        } else {
            updated.remove(listID)
        }
        return updated
    }
}

enum AddedSnipRevealDestination: Equatable {
    case scrollViewTop
}

struct AddedSnipRevealState {
    private var pendingID: UUID?

    mutating func record(
        snipID: UUID?,
        wasAtTop: Bool,
        isVisibleInModel: Bool,
        visibleIDs: [UUID]
    ) -> AddedSnipRevealDestination? {
        guard wasAtTop,
              let snipID,
              isVisibleInModel else {
            pendingID = nil
            return nil
        }
        pendingID = snipID
        return nextDestination(visibleIDs: visibleIDs)
    }

    mutating func nextDestination(
        visibleIDs: [UUID]
    ) -> AddedSnipRevealDestination? {
        guard let pendingID,
              visibleIDs.contains(pendingID) else { return nil }
        self.pendingID = nil
        return .scrollViewTop
    }
}

@MainActor
final class SnipListGeometry {
    enum Element: Hashable {
        case row(UUID)
        case listFooter(UUID)
        case heading(UUID)
        case entry(SnipListEntryID)
        case dropSurface(SnipListEntryID)
        case listFooterDropSurface(UUID)
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

    func retainSnips(_ ids: Set<UUID>) {
        frames = frames.filter { entry in
            switch entry.key {
            case .row(let id):
                ids.contains(id)
            case .entry(let entryID), .dropSurface(let entryID):
                switch entryID {
                case .snip(let id), .originGap(let id):
                    ids.contains(id)
                case .destinationGap:
                    true
                }
            default:
                true
            }
        }
    }

    func updateScroll(_ snapshot: ScrollSnapshot) {
        scrollSnapshot = snapshot
    }

    func pinnedListIDs() -> Set<UUID> {
        let pinLine = scrollSnapshot.visibleOrigin.y + 0.5
        let current = frames.compactMap { element, frame -> (UUID, CGFloat)? in
            guard case .heading(let listID) = element,
                  frame.minY <= pinLine else { return nil }
            return (listID, frame.minY)
        }.max { $0.1 < $1.1 }
        return current.map { [$0.0] } ?? []
    }

    func frame(for element: Element) -> CGRect? {
        frames[element]
    }

    func listBodyFrame(
        listID: UUID,
        rowIDs: [UUID],
        entryIDs: [SnipListEntryID]
    ) -> CGRect? {
        let entryFrames = entryIDs.compactMap { frames[.entry($0)] }
        let rowFrames = rowIDs.compactMap { frames[.row($0)] }
        let bodyFrames = entryFrames.isEmpty ? rowFrames : entryFrames
        guard let first = bodyFrames.first else {
            return frames[.listFooter(listID)]
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

    func insertionID(atContentPoint point: CGPoint, among snips: [Snip]) -> UUID? {
        snips.first { snip in
            guard let frame = frames[.row(snip.id)] else { return false }
            return point.y < frame.midY
        }?.id
    }

    func hasPlacementFrames(in listID: UUID, among snips: [Snip]) -> Bool {
        if snips.isEmpty {
            return frames[.listFooter(listID)] != nil
                || frames[.heading(listID)] != nil
        }
        return snips.contains { frames[.row($0.id)] != nil }
    }

    func dragGapHeight(for ids: [UUID]) -> CGFloat {
        let heights = ids.compactMap { frames[.row($0)]?.height }
        guard heights.count == ids.count else {
            return CGFloat(ids.count) * 72 + CGFloat(max(ids.count - 1, 0)) * 8
        }
        return heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * 8
    }
}
