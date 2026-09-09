import Foundation

public struct LibrarySearchResults: Sendable {
    public struct ListMatches: Identifiable, Sendable {
        public var id: UUID { list.id }
        public let list: SnipList
        public let snips: [Snip]
    }

    public let lists: [ListMatches]
    public let clipboard: [ClipboardEntry]
    public var count: Int { lists.reduce(clipboard.count) { $0 + $1.snips.count } }
    public var isEmpty: Bool { count == 0 }

    public init(
        query: String,
        snips: [Snip],
        lists: [SnipList],
        clipboard: [ClipboardEntry],
        sortMode: SnipSortMode,
        sourceLabel: (Snip) -> String
    ) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            self.lists = []
            self.clipboard = []
            return
        }
        let matches = SnipFilter.apply(
            snips: snips,
            query: needle,
            completionFilter: .all,
            listNames: Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.name) }),
            sourceLabel: sourceLabel
        )
        let byList = Dictionary(grouping: matches, by: \.listID)
        self.lists = lists.compactMap { list in
            guard let snips = byList[list.id], !snips.isEmpty else { return nil }
            return ListMatches(list: list, snips: Snip.sorted(snips, by: sortMode))
        }
        self.clipboard = clipboard.filter { $0.searchText.localizedCaseInsensitiveContains(needle) }
    }
}
