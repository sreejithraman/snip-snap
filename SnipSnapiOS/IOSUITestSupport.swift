import Foundation
import SnipSnapCore

#if DEBUG
actor RecoveryUITestSnipLibrary: SnipLibrary {
    private let listID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let snipID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let recoveredSnipID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let recoveredListID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private var snips: [Snip]
    private var lists: [SnipList]
    private var recovery: SnipRecoverySnapshot

    init() {
        let list = SnipList(
            id: listID,
            name: "Server Notes",
            systemImage: "folder",
            position: 1
        )
        let current = Snip(
            id: snipID,
            content: "Current text from iCloud",
            origin: .quickEntry,
            listID: listID
        )
        let recoveredValue = Snip(
            id: recoveredSnipID,
            content: "Recovered text from this device",
            origin: .quickEntry,
            source: SnipSource(applicationName: "Notes"),
            listID: listID,
            isDone: true
        )
        snips = [current]
        lists = [.inbox, list]
        recovery = SnipRecoverySnapshot(
            pendingSnips: [
                RecoveredSnip(
                    id: recoveredSnipID,
                    currentSnipID: snipID,
                    recovered: recoveredValue,
                    conflictingFields: [.text, .source, .done]
                )
            ],
            pendingLists: [
                RecoveredListEdit(
                    id: recoveredListID,
                    currentListID: listID,
                    recovered: SnipList(
                        id: listID,
                        name: "Recovered Notes",
                        systemImage: "star",
                        position: list.position,
                        sortKey: list.sortKey
                    ),
                    conflictingFields: [.name, .icon]
                )
            ]
        )
    }

    func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        SnipLibrarySnapshot(snips: Snip.sorted(snips, by: sortMode), lists: lists)
    }

    func checkedSnapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        snapshot(sortedBy: sortMode)
    }

    func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) throws -> SnipLibraryUpdate {
        guard case .pruneAttachments = command else {
            throw SnipLibraryError.storeUnavailable
        }
        return SnipLibraryUpdate(snapshot: snapshot(sortedBy: sortMode), outcome: .none)
    }

    func recoverySnapshot(in scope: SnipRecoveryScope) -> SnipRecoverySnapshot {
        recovery
    }

    func resolveRecovery(
        _ id: UUID,
        in scope: SnipRecoveryScope,
        choice: SnipRecoveryChoice
    ) throws -> SnipLibrarySnapshot {
        if let pending = recovery.pendingSnips.first(where: { $0.id == id }) {
            try resolve(pending, choice: choice)
            recovery = SnipRecoverySnapshot(
                promotedSnips: recovery.promotedSnips,
                pendingLists: recovery.pendingLists
            )
        } else if let pending = recovery.pendingLists.first(where: { $0.id == id }) {
            try resolve(pending, choice: choice)
            recovery = SnipRecoverySnapshot(
                pendingSnips: recovery.pendingSnips,
                promotedSnips: recovery.promotedSnips
            )
        } else {
            throw SnipLibraryError.recoveryNotFound
        }
        return snapshot(sortedBy: .chronological)
    }

    private func resolve(_ pending: RecoveredSnip, choice: SnipRecoveryChoice) throws {
        guard let index = snips.firstIndex(where: { $0.id == pending.currentSnipID }) else {
            throw SnipLibraryError.recoveryChanged
        }
        switch choice {
        case .keepCurrent:
            break
        case .useRecovered:
            snips[index] = applying(pending.recovered, to: snips[index], fields: pending.conflictingFields)
        case .keepBoth:
            snips.append(pending.recovered)
            recovery = SnipRecoverySnapshot(
                pendingSnips: recovery.pendingSnips,
                promotedSnips: recovery.promotedSnips + [pending.promoted()],
                pendingLists: recovery.pendingLists
            )
        case .editSnip(let edited):
            snips[index] = applying(edited, to: snips[index], fields: pending.conflictingFields)
        case .editList:
            throw SnipLibraryError.invalidRecoveryChoice
        }
    }

    private func resolve(_ pending: RecoveredListEdit, choice: SnipRecoveryChoice) throws {
        guard let index = lists.firstIndex(where: { $0.id == pending.currentListID }) else {
            throw SnipLibraryError.recoveryChanged
        }
        switch choice {
        case .keepCurrent:
            break
        case .useRecovered:
            lists[index] = applying(pending.recovered, to: lists[index], fields: pending.conflictingFields)
        case .editList(let edited):
            lists[index] = applying(edited, to: lists[index], fields: pending.conflictingFields)
        case .keepBoth, .editSnip:
            throw SnipLibraryError.invalidRecoveryChoice
        }
    }

    private func applying(
        _ candidate: Snip,
        to current: Snip,
        fields: Set<RecoveredSnipField>
    ) -> Snip {
        var result = current
        if fields.contains(.text) { result.content = candidate.content }
        if fields.contains(.source) { result.source = candidate.source }
        if fields.contains(.done) { result.isDone = candidate.isDone }
        if fields.contains(.placement) { result.listID = candidate.listID }
        return result
    }

    private func applying(
        _ candidate: SnipList,
        to current: SnipList,
        fields: Set<RecoveredListField>
    ) -> SnipList {
        SnipList(
            id: current.id,
            name: fields.contains(.name) ? candidate.name : current.name,
            systemImage: fields.contains(.icon) ? candidate.systemImage : current.systemImage,
            position: current.position,
            sortKey: current.sortKey
        )
    }
}
#endif

#if DEBUG
actor UITestAppleAccountCacheHandler: AppleAccountCacheHandling {
    private var didResolve = false
    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
        didResolve ? nil : .signedOut
    }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {
        didResolve = true
    }
}
#endif
