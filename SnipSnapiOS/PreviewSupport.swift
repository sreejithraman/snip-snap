import Foundation
import SnipSnapCore

actor PreviewSnipLibrary: SnipLibrary {
    static let snapshot = PreviewSnipLibrary(snapshot: .preview)
    static let empty = PreviewSnipLibrary(
        snapshot: SnipLibrarySnapshot(snips: [], lists: [.inbox])
    )

    private let storedSnapshot: SnipLibrarySnapshot

    init(snapshot: SnipLibrarySnapshot) {
        storedSnapshot = snapshot
    }

    func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        storedSnapshot
    }

    func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) throws -> SnipLibraryUpdate {
        SnipLibraryUpdate(snapshot: storedSnapshot, outcome: .none)
    }
}

extension SnipLibrarySnapshot {
    static let preview: SnipLibrarySnapshot = {
        let reading = SnipList(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
            name: "Reading",
            systemImage: "book.fill",
            position: 1
        )
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return SnipLibrarySnapshot(
            snips: [
                Snip(
                    id: UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!,
                    requestID: UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!,
                    createdAt: date,
                    content: "A saved thought for later.",
                    origin: .quickEntry,
                    listID: SnipList.inboxID
                ),
                Snip(
                    id: UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!,
                    requestID: UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!,
                    createdAt: date.addingTimeInterval(-600),
                    content: "https://example.com/long-form-reading",
                    origin: .quickEntry,
                    listID: reading.id
                ),
            ],
            lists: [.inbox, reading]
        )
    }()
}
