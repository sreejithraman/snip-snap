import Foundation
import SnipSnapCore

struct IOSUndoHistory {
    private static let limit = 100

    struct Selection {
        let listID: UUID
        let snipID: UUID?
        let snipIDs: Set<UUID>
    }

    struct Placement {
        let listID: UUID
        let orderedIDs: [UUID]
    }

    enum InverseEdit {
        case delete(ids: Set<UUID>)
        case restore(snips: [Snip])
        case update(before: Snip, expectedUpdatedAt: Date)
        case setDone(states: [UUID: Bool])
        case placements([Placement])
        case deleteList(id: UUID)
        case updateList(SnipList)
        case restoreList(SnipList, placements: [Placement])

        func command(now: Date) -> SnipLibraryCommand {
            switch self {
            case .delete(let ids):
                .delete(ids: ids)
            case .restore(let snips):
                .restore(snips: snips)
            case .update(let before, let expectedUpdatedAt):
                .update(
                    id: before.id,
                    content: before.content,
                    attachmentURLs: nil,
                    expectedUpdatedAt: expectedUpdatedAt,
                    now: now
                )
            case .setDone(let states):
                .batch([
                    .setDone(ids: Set(states.filter(\.value).map(\.key)), done: true),
                    .setDone(ids: Set(states.filter { !$0.value }.map(\.key)), done: false),
                ])
            case .placements(let placements):
                Self.placementCommand(placements)
            case .deleteList(let id):
                .deleteList(id: id)
            case .updateList(let list):
                .updateList(id: list.id, name: list.name, systemImage: list.systemImage)
            case .restoreList(let list, let placements):
                .batch([.restoreList(list), Self.placementCommand(placements)])
            }
        }

        var requiredListIDs: Set<UUID> {
            switch self {
            case .restore(let snips):
                Set(snips.map(\.listID))
            case .placements(let placements):
                Set(placements.map(\.listID))
            case .restoreList(let list, let placements):
                Set(placements.map(\.listID)).subtracting([list.id])
            default:
                []
            }
        }

        var membershipGuardListIDs: Set<UUID> {
            switch self {
            case .deleteList(let id):
                [id]
            default:
                []
            }
        }

        private static func placementCommand(_ placements: [Placement]) -> SnipLibraryCommand {
            .batch(
                placements.map {
                    .place(ids: $0.orderedIDs, in: $0.listID, before: nil, basedOn: .manual)
                }
            )
        }
    }

    struct Operation {
        let name: String
        let expectation: SnipLibraryExpectation
        let inverse: InverseEdit
        let selection: Selection
    }

    private var operations: [Operation] = []

    var canUndo: Bool { !operations.isEmpty }
    var title: String { operations.last.map { "Undo \($0.name)" } ?? "Undo" }
    var latest: Operation? { operations.last }

    mutating func record(
        name: String,
        before: SnipLibrarySnapshot,
        after: SnipLibrarySnapshot,
        touchedListIDs: Set<UUID>,
        inverse: InverseEdit,
        selection: Selection
    ) {
        operations.append(
            Operation(
                name: name,
                expectation: Self.expectation(
                    before: before,
                    after: after,
                    touchedListIDs: touchedListIDs,
                    inverse: inverse
                ),
                inverse: inverse,
                selection: selection
            )
        )
        if operations.count > Self.limit {
            operations.removeFirst(operations.count - Self.limit)
        }
    }

    mutating func discardLatest() {
        guard !operations.isEmpty else { return }
        operations.removeLast()
    }

    static func placements(
        in snapshot: SnipLibrarySnapshot,
        listIDs: Set<UUID>
    ) -> [Placement] {
        snapshot.lists.filter { listIDs.contains($0.id) }.map { list in
            Placement(
                listID: list.id,
                orderedIDs: Snip.sorted(
                    snapshot.snips.filter { $0.listID == list.id },
                    by: .manual
                ).map(\.id)
            )
        }
    }

    private static func expectation(
        before: SnipLibrarySnapshot,
        after: SnipLibrarySnapshot,
        touchedListIDs: Set<UUID>,
        inverse: InverseEdit
    ) -> SnipLibraryExpectation {
        let beforeSnips = Dictionary(uniqueKeysWithValues: before.snips.map { ($0.id, $0) })
        let afterSnips = Dictionary(uniqueKeysWithValues: after.snips.map { ($0.id, $0) })
        let beforeLists = Dictionary(uniqueKeysWithValues: before.lists.map { ($0.id, $0) })
        let afterLists = Dictionary(uniqueKeysWithValues: after.lists.map { ($0.id, $0) })
        let membershipListIDs = touchedListIDs.union(inverse.membershipGuardListIDs)
        return SnipLibraryExpectation(
            expectedSnips: after.snips.filter {
                beforeSnips[$0.id] != $0 || touchedListIDs.contains($0.listID)
            },
            absentSnipIDs: Set(beforeSnips.keys).subtracting(afterSnips.keys),
            expectedLists: after.lists.filter { beforeLists[$0.id] != $0 },
            absentListIDs: Set(beforeLists.keys).subtracting(afterLists.keys),
            requiredListIDs: inverse.requiredListIDs,
            expectedListMemberships: Dictionary(
                uniqueKeysWithValues: membershipListIDs.compactMap { listID in
                    guard afterLists[listID] != nil else { return nil }
                    return (
                        listID,
                        Set(after.snips.lazy.filter { $0.listID == listID }.map(\.id))
                    )
                }
            )
        )
    }
}
