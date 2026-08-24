import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let snipSnapClipDrag = UTType(exportedAs: "world.sree.snipsnap.clip-drag", conformingTo: .json)
}

struct ClipDragPayload: Codable, Equatable, Sendable, Transferable {
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
        CodableRepresentation(contentType: .snipSnapClipDrag)
            .visibility(.ownProcess)
        ProxyRepresentation(exporting: \.text)
    }

    static func make(items: [CaptureItem]) -> ClipDragPayload {
        make(items: items, attachmentURL: nil)
    }

    static func make(
        items: [CaptureItem],
        attachmentURL: ((ClipAttachment) -> URL)?
    ) -> ClipDragPayload {
        ClipDragPayload(
            ids: items.map(\.id),
            text: items.count == 1
                ? items[0].content
                : CopyFormatter.formatInGivenOrder(items: items),
            attachmentURLs: attachmentURL.map { resolve in
                items.flatMap(\.attachments).map(resolve)
            } ?? [],
            previewSourceLabel: items.count == 1
                ? items[0].displaySourceLabel
                : "\(items.count) clips",
            previewIsDone: items.allSatisfy(\.isDone)
        )
    }
}

enum ExternalClipDragCompletion {
    static func shouldMarkDone(after operation: DropOperation) -> Bool {
        operation == .copy
    }
}

enum ClipDragListSlot: Equatable {
    case item(UUID)
    case originGap(UUID)
    case destinationGap
}

enum ClipDragListLayout {
    static func slots(
        itemIDs: [UUID],
        draggingIDs: Set<UUID>,
        destinationBeforeID: UUID?,
        showsDestinationGap: Bool,
        preservesOriginGaps: Bool
    ) -> [ClipDragListSlot] {
        guard !draggingIDs.isEmpty else { return itemIDs.map(ClipDragListSlot.item) }

        if preservesOriginGaps {
            return itemIDs.map { id in
                draggingIDs.contains(id) ? .originGap(id) : .item(id)
            }
        }

        var slots = itemIDs
            .filter { !draggingIDs.contains($0) }
            .map(ClipDragListSlot.item)
        guard showsDestinationGap else { return slots }

        let insertionIndex = destinationBeforeID.flatMap { beforeID in
            slots.firstIndex(of: .item(beforeID))
        } ?? slots.endIndex
        slots.insert(.destinationGap, at: insertionIndex)
        return slots
    }
}

struct InboxItemGroup: Identifiable, Equatable {
    let sectionID: UUID
    let section: String
    let items: [CaptureItem]

    var id: UUID { sectionID }
}

struct InboxListSnapshot {
    let groups: [InboxItemGroup]
    let orderedVisibleIDs: [UUID]

    private let selection: Set<UUID>
    private let selectedPayload: ClipDragPayload?

    init(
        visibleItems: [CaptureItem],
        allItems: [CaptureItem],
        sections: [SnipSnapSection],
        selection: Set<UUID>,
        keepsEmptySectionID: UUID? = nil,
        attachmentURL: ((ClipAttachment) -> URL)? = nil
    ) {
        groups = Self.groups(
            for: visibleItems,
            sections: sections,
            keepsEmptySectionID: keepsEmptySectionID
        )
        orderedVisibleIDs = groups.flatMap { $0.items.map(\.id) }
        self.selection = selection
        self.attachmentURL = attachmentURL

        let selectedItems = Self.groups(
            for: allItems.filter { selection.contains($0.id) },
            sections: sections
        ).flatMap(\.items)
        selectedPayload = selectedItems.isEmpty
            ? nil
            : ClipDragPayload.make(items: selectedItems, attachmentURL: attachmentURL)
    }

    func dragPayload(for item: CaptureItem) -> ClipDragPayload {
        if selection.contains(item.id), let selectedPayload {
            return selectedPayload
        }
        return ClipDragPayload.make(items: [item], attachmentURL: attachmentURL)
    }

    private let attachmentURL: ((ClipAttachment) -> URL)?

    private static func groups(
        for items: [CaptureItem],
        sections: [SnipSnapSection],
        keepsEmptySectionID: UUID? = nil
    ) -> [InboxItemGroup] {
        let grouped = Dictionary(grouping: items, by: \.sectionID)
        return sections.compactMap { section in
            let items = grouped[section.id] ?? []
            guard !items.isEmpty || section.id == keepsEmptySectionID else { return nil }
            return InboxItemGroup(sectionID: section.id, section: section.name, items: items)
        }
    }
}

enum ClipDropBehavior: Equatable {
    case exact
    case sectionTop
    case chronological
}

struct ClipDropPlan: Equatable {
    let sectionID: UUID
    let beforeID: UUID?
    let behavior: ClipDropBehavior
    let showsInsertion: Bool
}

enum ClipDropPlanner {
    static func plan(
        payloadIDs: [UUID],
        items: [CaptureItem],
        targetSectionID: UUID,
        pointerBeforeID: UUID?,
        isOverHeading: Bool,
        sortMode: ClipSortMode,
        filtersActive: Bool
    ) -> ClipDropPlan? {
        let movingIDs = Set(payloadIDs)
        guard !movingIDs.isEmpty else { return nil }

        let movingItems = items.filter { movingIDs.contains($0.id) }
        guard movingItems.count == movingIDs.count else { return nil }

        let sourceSections = Set(movingItems.map(\.sectionID))
        let sameSection = sourceSections.count == 1 && sourceSections.first == targetSectionID
        let targetItems = CaptureItem.sorted(
            items.filter { $0.sectionID == targetSectionID && !movingIDs.contains($0.id) },
            by: sortMode
        )

        if !filtersActive && (sortMode == .manual || sameSection) {
            let validPointerID = pointerBeforeID.flatMap { candidate in
                targetItems.contains(where: { $0.id == candidate }) ? candidate : nil
            }
            return ClipDropPlan(
                sectionID: targetSectionID,
                beforeID: isOverHeading ? targetItems.first?.id : validPointerID,
                behavior: .exact,
                showsInsertion: true
            )
        }

        if sortMode == .manual {
            guard !sameSection else { return nil }
            return ClipDropPlan(
                sectionID: targetSectionID,
                beforeID: targetItems.first?.id,
                behavior: .sectionTop,
                showsInsertion: false
            )
        }

        guard !sameSection else { return nil }
        let beforeID = movingItems.count == 1
            ? chronologicalInsertionID(for: movingItems[0], in: targetItems)
            : nil
        return ClipDropPlan(
            sectionID: targetSectionID,
            beforeID: beforeID,
            behavior: .chronological,
            showsInsertion: movingItems.count == 1
        )
    }

    private static func chronologicalInsertionID(
        for movingItem: CaptureItem,
        in targetItems: [CaptureItem]
    ) -> UUID? {
        let ordered = CaptureItem.sorted(targetItems + [movingItem], by: .chronological)
        guard let movingIndex = ordered.firstIndex(where: { $0.id == movingItem.id }) else {
            return nil
        }
        return ordered.dropFirst(movingIndex + 1).first(where: { $0.id != movingItem.id })?.id
    }
}

enum InboxSelection {
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

enum InboxFilter {
    static func apply(
        items: [CaptureItem],
        query: String,
        completionFilter: CompletionFilter,
        sectionNames: [UUID: String] = [:]
    ) -> [CaptureItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            switch completionFilter {
            case .all:
                break
            case .done:
                guard item.isDone else { return false }
            case .notDone:
                guard !item.isDone else { return false }
            }
            guard !needle.isEmpty else { return true }
            return item.content.localizedCaseInsensitiveContains(needle)
                || item.attachments.contains { $0.fileName.localizedCaseInsensitiveContains(needle) }
                || sectionNames[item.sectionID]?.localizedCaseInsensitiveContains(needle) == true
                || item.displaySourceLabel.localizedCaseInsensitiveContains(needle)
                || item.source?.url?.localizedCaseInsensitiveContains(needle) == true
        }
    }
}

enum CopyFormatter {
    static func formatForClipboard(items: [CaptureItem]) -> String {
        guard items.count != 1 else { return items[0].content }
        return formatAsList(items: items)
    }

    static func format(items: [CaptureItem]) -> String {
        sorted(items)
            .map(format)
            .joined(separator: "\n\n---\n\n")
    }

    private static func formatAsList(items: [CaptureItem]) -> String {
        sorted(items)
            .map { item in
                let indented = format(item).replacingOccurrences(of: "\n", with: "\n  ")
                return "- \(indented)"
            }
            .joined(separator: "\n")
    }

    static func formatInGivenOrder(items: [CaptureItem]) -> String {
        items
            .map(format)
            .joined(separator: "\n\n---\n\n")
    }

    private static func sorted(_ items: [CaptureItem]) -> [CaptureItem] {
        items.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func format(_ item: CaptureItem) -> String {
        var parts = [item.content]
        if let source = item.source {
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
