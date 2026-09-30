/// Presentation choices for clipboard history, separate from its retention and sync order.
public struct ClipboardViewOptions: Equatable, Sendable {
    public var onlyPinned: Bool
    public var newestFirst: Bool

    public init(onlyPinned: Bool = false, newestFirst: Bool = true) {
        self.onlyPinned = onlyPinned
        self.newestFirst = newestFirst
    }

    public func apply(to entries: [ClipboardEntry]) -> [ClipboardEntry] {
        let ordered = ClipboardHistoryState.ordered(entries.filter {
            !onlyPinned || $0.isPinned
        })
        guard newestFirst else {
            return ordered.filter(\.isPinned) + ordered.filter { !$0.isPinned }.reversed()
        }
        return ordered
    }
}
