import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let snipSnapSnipDrag = UTType(exportedAs: "world.sree.snipsnap.snip-drag", conformingTo: .json)
}

struct SnipDragPayload: Codable, Equatable, Sendable, Transferable {
    let ids: [UUID]
    let text: String
    let attachmentURLs: [URL]
    let previewSourceLabel: String
    let previewIsDone: Bool

    init(
        ids: [UUID],
        text: String,
        attachmentURLs: [URL] = [],
        previewSourceLabel: String = "Snip Snap",
        previewIsDone: Bool = false
    ) {
        self.ids = ids
        self.text = text
        self.attachmentURLs = attachmentURLs
        self.previewSourceLabel = previewSourceLabel
        self.previewIsDone = previewIsDone
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .snipSnapSnipDrag)
            .visibility(.ownProcess)
        ProxyRepresentation(exporting: \.text)
    }

    static func make(snips: [Snip]) -> SnipDragPayload {
        make(snips: snips, attachmentURL: nil)
    }

    static func make(
        snips: [Snip],
        attachmentURL: ((SnipAttachment) -> URL)?
    ) -> SnipDragPayload {
        SnipDragPayload(
            ids: snips.map(\.id),
            text: snips.count == 1
                ? snips[0].content
                : SnipFormatter.formatInGivenOrder(snips: snips),
            attachmentURLs: attachmentURL.map { resolve in
                snips.flatMap(\.attachments).map(resolve)
            } ?? [],
            previewSourceLabel: snips.count == 1
                ? snips[0].displaySourceLabel
                : "\(snips.count) snips",
            previewIsDone: snips.allSatisfy(\.isDone)
        )
    }
}

struct SnipListGroup: Identifiable, Equatable {
    let listID: UUID
    let listName: String
    let snips: [Snip]

    var id: UUID { listID }
}

enum SnipListReorderTarget: Equatable {
    case before(UUID)
    case end

    var beforeID: UUID? {
        switch self {
        case .before(let id): id
        case .end: nil
        }
    }
}

enum SnipListReorderPlan {
    static func target(
        atWindowY windowY: CGFloat,
        orderedIDs: [UUID],
        movingIDs: Set<UUID>,
        rowFrames: [UUID: CGRect],
        rowFrameOffsetY: CGFloat = 0
    ) -> SnipListReorderTarget {
        let candidates = orderedIDs.compactMap { id -> (UUID, CGRect)? in
            guard !movingIDs.contains(id), let frame = rowFrames[id] else { return nil }
            return (id, frame.offsetBy(dx: 0, dy: rowFrameOffsetY))
        }
        .sorted { $0.1.midY > $1.1.midY }
        if let candidate = candidates.first(where: { windowY > $0.1.midY }) {
            return .before(candidate.0)
        }
        return .end
    }

    static func orderedIDs(
        from originalIDs: [UUID],
        movingIDs: [UUID],
        target: SnipListReorderTarget
    ) -> [UUID]? {
        let orderedMovingIDs = movingIDs.filter(originalIDs.contains)
        guard orderedMovingIDs.count == movingIDs.count else { return nil }
        let movingSet = Set(orderedMovingIDs)
        var result = originalIDs.filter { !movingSet.contains($0) }
        let destination = target.beforeID.flatMap(result.firstIndex(of:)) ?? result.endIndex
        result.insert(contentsOf: orderedMovingIDs, at: destination)
        return result
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
        guard wasAtTop, let snipID, isVisibleInModel else {
            pendingID = nil
            return nil
        }
        pendingID = snipID
        return nextDestination(visibleIDs: visibleIDs)
    }

    mutating func nextDestination(
        visibleIDs: [UUID]
    ) -> AddedSnipRevealDestination? {
        guard let pendingID, visibleIDs.contains(pendingID) else { return nil }
        self.pendingID = nil
        return .scrollViewTop
    }
}

struct SnipListSnapshot {
    let groups: [SnipListGroup]
    let orderedVisibleIDs: [UUID]

    private let selection: Set<UUID>
    private let selectedPayload: SnipDragPayload?

    init(
        visibleSnips: [Snip],
        allSnips: [Snip],
        lists: [SnipList],
        selection: Set<UUID>,
        keepsEmptyListID: UUID? = nil,
        attachmentURL: ((SnipAttachment) -> URL)? = nil
    ) {
        groups = Self.groups(
            for: visibleSnips,
            lists: lists,
            keepsEmptyListID: keepsEmptyListID
        )
        orderedVisibleIDs = groups.flatMap { $0.snips.map(\.id) }
        self.selection = selection
        self.attachmentURL = attachmentURL

        let selectedSnips = Self.groups(
            for: allSnips.filter { selection.contains($0.id) },
            lists: lists
        ).flatMap(\.snips)
        selectedPayload = selectedSnips.isEmpty
            ? nil
            : SnipDragPayload.make(snips: selectedSnips, attachmentURL: attachmentURL)
    }

    func dragPayload(for snip: Snip) -> SnipDragPayload {
        if selection.contains(snip.id), let selectedPayload {
            return selectedPayload
        }
        return SnipDragPayload.make(snips: [snip], attachmentURL: attachmentURL)
    }

    private let attachmentURL: ((SnipAttachment) -> URL)?

    private static func groups(
        for snips: [Snip],
        lists: [SnipList],
        keepsEmptyListID: UUID? = nil
    ) -> [SnipListGroup] {
        let grouped = Dictionary(grouping: snips, by: \.listID)
        return lists.compactMap { list in
            let snips = grouped[list.id] ?? []
            guard !snips.isEmpty || list.id == keepsEmptyListID else { return nil }
            return SnipListGroup(listID: list.id, listName: list.name, snips: snips)
        }
    }
}

enum SnipSelection {
    struct Modifiers: OptionSet {
        let rawValue: Int

        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
    }

    struct Update: Equatable {
        let selection: Set<UUID>
        let anchor: UUID?
        let focus: UUID?
    }

    static func click(
        _ id: UUID,
        orderedIDs: [UUID],
        selection: Set<UUID>,
        anchor: UUID?,
        focus: UUID?,
        modifiers: Modifiers
    ) -> Update {
        guard orderedIDs.contains(id) else {
            return Update(selection: selection, anchor: anchor, focus: focus)
        }

        if modifiers.contains(.shift) {
            guard !selection.isEmpty,
                  let rangeAnchor = anchor,
                  selection.contains(rangeAnchor),
                  orderedIDs.contains(rangeAnchor) else {
                return Update(selection: selection, anchor: anchor, focus: focus)
            }
            let range = ids(from: rangeAnchor, through: id, in: orderedIDs)
            return Update(
                selection: modifiers.contains(.command) ? selection.union(range) : range,
                anchor: rangeAnchor,
                focus: id
            )
        }

        if modifiers.contains(.command) {
            var updated = selection
            if !updated.insert(id).inserted {
                updated.remove(id)
            }
            return Update(
                selection: updated,
                anchor: updated.contains(id) ? id : validAnchor(nil, selection: updated, in: orderedIDs),
                focus: updated.contains(id) ? id : validAnchor(nil, selection: updated, in: orderedIDs)
            )
        }

        return Update(selection: [], anchor: nil, focus: nil)
    }

    static func move(
        by offset: Int,
        orderedIDs: [UUID],
        selection: Set<UUID>,
        anchor: UUID?,
        focus: UUID?,
        extending: Bool
    ) -> Update {
        guard !orderedIDs.isEmpty, offset != 0 else {
            return Update(selection: selection, anchor: anchor, focus: focus)
        }

        let current = focus.flatMap {
            selection.contains($0) && orderedIDs.contains($0) ? $0 : nil
        }
            ?? orderedIDs.first(where: selection.contains)
        let currentIndex = current.flatMap(orderedIDs.firstIndex)
        let destinationIndex: Int
        if let currentIndex {
            destinationIndex = min(max(currentIndex + offset, 0), orderedIDs.count - 1)
        } else {
            destinationIndex = offset > 0 ? 0 : orderedIDs.count - 1
        }
        let destination = orderedIDs[destinationIndex]

        guard extending else {
            return Update(selection: [destination], anchor: destination, focus: destination)
        }

        let rangeAnchor = validAnchor(anchor, selection: selection, in: orderedIDs) ?? destination
        return Update(
            selection: ids(from: rangeAnchor, through: destination, in: orderedIDs),
            anchor: rangeAnchor,
            focus: destination
        )
    }

    private static func validAnchor(
        _ anchor: UUID?,
        selection: Set<UUID>,
        in orderedIDs: [UUID]
    ) -> UUID? {
        if let anchor, selection.contains(anchor), orderedIDs.contains(anchor) {
            return anchor
        }
        return orderedIDs.first(where: selection.contains)
    }

    private static func ids(
        from anchor: UUID,
        through focus: UUID,
        in orderedIDs: [UUID]
    ) -> Set<UUID> {
        guard let anchorIndex = orderedIDs.firstIndex(of: anchor),
              let focusIndex = orderedIDs.firstIndex(of: focus) else { return [] }
        return Set(orderedIDs[min(anchorIndex, focusIndex)...max(anchorIndex, focusIndex)])
    }
}

enum SnipFilter {
    static func apply(
        snips: [Snip],
        query: String,
        completionFilter: SnipCompletionFilter,
        listNames: [UUID: String] = [:]
    ) -> [Snip] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snips.filter { snip in
            switch completionFilter {
            case .all:
                break
            case .done:
                guard snip.isDone else { return false }
            case .notDone:
                guard !snip.isDone else { return false }
            }
            guard !needle.isEmpty else { return true }
            return snip.content.localizedCaseInsensitiveContains(needle)
                || snip.attachments.contains { $0.fileName.localizedCaseInsensitiveContains(needle) }
                || listNames[snip.listID]?.localizedCaseInsensitiveContains(needle) == true
                || snip.displaySourceLabel.localizedCaseInsensitiveContains(needle)
                || snip.source?.url?.localizedCaseInsensitiveContains(needle) == true
        }
    }
}

enum SnipFormatter {
    static func formatForClipboard(snips: [Snip]) -> String {
        guard snips.count != 1 else { return snips[0].content }
        return formatAsList(snips: snips)
    }

    static func format(snips: [Snip]) -> String {
        sorted(snips)
            .map(format)
            .joined(separator: "\n\n---\n\n")
    }

    private static func formatAsList(snips: [Snip]) -> String {
        sorted(snips)
            .map { snip in
                let indented = format(snip).replacingOccurrences(of: "\n", with: "\n  ")
                return "- \(indented)"
            }
            .joined(separator: "\n")
    }

    static func formatInGivenOrder(snips: [Snip]) -> String {
        snips
            .map(format)
            .joined(separator: "\n\n---\n\n")
    }

    private static func sorted(_ snips: [Snip]) -> [Snip] {
        snips.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func format(_ snip: Snip) -> String {
        var parts = [snip.content]
        if let source = snip.source {
            let label = source.conciseLabel
            if !label.isEmpty {
                parts.append("Source: \(label)")
            }
            if let url = source.url, !url.isEmpty {
                parts.append("URL: \(url)")
            }
        }
        return parts.joined(separator: "\n")
    }
}
