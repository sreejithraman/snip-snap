import Foundation

public struct ClipboardHistoryState: Codable, Equatable, Sendable {
    public static let limit = 100
    public static let representationByteLimit = 16 * 1_024 * 1_024
    public static let entryByteLimit = 32 * 1_024 * 1_024
    public static let historyByteLimit = 96 * 1_024 * 1_024
    public private(set) var entries: [ClipboardEntry]
    public private(set) var tombstones: [UUID: Date]

    public private(set) var retentionTombstones: [UUID: Date]

    private enum CodingKeys: String, CodingKey { case entries, tombstones, retentionTombstones }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try values.decode([ClipboardEntry].self, forKey: .entries),
                  tombstones: try values.decodeIfPresent([UUID: Date].self, forKey: .tombstones) ?? [:],
                  retentionTombstones: try values.decodeIfPresent([UUID: Date].self, forKey: .retentionTombstones) ?? [:])
    }

    public init(entries: [ClipboardEntry] = [], tombstones: [UUID: Date] = [:], retentionTombstones: [UUID: Date] = [:]) {
        self.entries = entries; self.tombstones = tombstones; self.retentionTombstones = retentionTombstones
        normalize()
    }

    public mutating func insert(_ entry: ClipboardEntry) {
        if let index = entries.firstIndex(where: { $0.hasSamePayload(as: entry) }) {
            // Copying again updates recency while keeping identity and pin order.
            entries[index].capturedAt = max(entries[index].capturedAt, entry.capturedAt)
            entries[index].modifiedAt = max(entries[index].modifiedAt, entry.modifiedAt)
        } else { entries.append(entry) }
        normalize()
    }

    public mutating func replace(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }; entries.append(entry); normalize()
    }

    public mutating func setPinned(_ pinned: Bool, id: UUID, at date: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isPinned != pinned else { return }
        entries[index].pinnedAt = pinned ? date : nil
        entries[index].modifiedAt = date
        normalize()
    }

    public mutating func delete(id: UUID, at date: Date = Date()) {
        for deletedID in [id] + (entries.first { $0.id == id }?.duplicateIDs ?? []) {
            tombstones[deletedID] = max(tombstones[deletedID] ?? .distantPast, date)
        }
        entries.removeAll { $0.id == id }
    }

    public mutating func clearUnpinned(at date: Date = Date()) {
        for entry in entries where !entry.isPinned {
            for id in [entry.id] + entry.duplicateIDs { retentionTombstones[id] = max(retentionTombstones[id] ?? .distantPast, date) }
        }
        entries.removeAll { !$0.isPinned }
    }

    public mutating func merge(_ other: ClipboardHistoryState) {
        for (id, date) in other.tombstones { tombstones[id] = max(tombstones[id] ?? .distantPast, date) }
        for (id, date) in other.retentionTombstones { retentionTombstones[id] = max(retentionTombstones[id] ?? .distantPast, date) }
        entries.append(contentsOf: other.entries)
        normalize()
    }

    public static func ordered(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            let leftDate = lhs.pinnedAt ?? lhs.capturedAt
            let rightDate = rhs.pinnedAt ?? rhs.capturedAt
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public static func trimmed(_ entries: [ClipboardEntry], maximumEntryBytes: Int = entryByteLimit,
                               maximumHistoryBytes: Int = historyByteLimit, maximumCount: Int = limit) -> [ClipboardEntry] {
        var bytes = 0; var examinedCount = 0; var budgetExhausted = false
        return entries.filter { entry in
            if entry.isPinned { return true }
            guard !budgetExhausted, examinedCount < maximumCount else { return false }
            examinedCount += 1
            guard entry.byteCount <= maximumEntryBytes else { return false }
            guard entry.byteCount <= maximumHistoryBytes - bytes else {
                budgetExhausted = true
                return false
            }
            bytes += entry.byteCount
            return true
        }
    }

    private mutating func normalize() {
        // Carry a deletion through every known alias before filtering old snapshots.
        for entry in entries {
            let ids = [entry.id] + entry.duplicateIDs
            if let deletedAt = ids.compactMap({ tombstones[$0] }).max() {
                for id in ids { tombstones[id] = max(tombstones[id] ?? .distantPast, deletedAt) }
            }
        }
        // Deletion wins over stale updates, including edits from an offline device.
        let live = entries.filter { entry in
            let ids = [entry.id] + entry.duplicateIDs
            return ids.allSatisfy { tombstones[$0] == nil }
                && (entry.isPinned || ids.allSatisfy { retentionTombstones[$0] == nil })
        }
        var byID: [UUID: ClipboardEntry] = [:]
        for entry in live {
            if let old = byID[entry.id] {
                var latest = Self.preferred(old, entry)
                latest.hasBeenShared = old.hasBeenShared || entry.hasBeenShared
                latest.duplicateIDs = Array(Set(old.duplicateIDs + entry.duplicateIDs)).sorted { $0.uuidString < $1.uuidString }
                byID[entry.id] = latest
            }
            else { byID[entry.id] = entry }
        }
        var byPayload: [String: ClipboardEntry] = [:]
        for entry in byID.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let key = entry.fingerprint
            guard let old = byPayload[key] else { byPayload[key] = entry; continue }
            let latest = Self.preferred(old, entry)
            // Stable identity independent of device merge order, with newest metadata.
            var merged = ClipboardEntry(id: min(old.id.uuidString, entry.id.uuidString) == old.id.uuidString ? old.id : entry.id,
                capturedAt: max(old.capturedAt, entry.capturedAt), sourceApplication: latest.sourceApplication,
                items: latest.items, plainText: latest.plainText, pinnedAt: latest.pinnedAt,
                modifiedAt: latest.modifiedAt, sourceDeviceName: latest.sourceDeviceName,
                ownedFiles: latest.ownedFiles,
                duplicateIDs: Array(Set(old.duplicateIDs + entry.duplicateIDs + [old.id, entry.id])).sorted { $0.uuidString < $1.uuidString },
                hasBeenShared: old.hasBeenShared || entry.hasBeenShared, payloadFingerprint: latest.payloadFingerprint)
            let alreadyMerged = old.duplicateIDs.contains(entry.id) || entry.duplicateIDs.contains(old.id)
            if !alreadyMerged && (old.isPinned || entry.isPinned) {
                merged.pinnedAt = [old.pinnedAt, entry.pinnedAt].compactMap { $0 }.max()
                if merged.ownedFiles.isEmpty { merged.ownedFiles = old.ownedFiles.isEmpty ? entry.ownedFiles : old.ownedFiles }
            }
            byPayload[key] = merged
        }
        let normalized = Array(byPayload.values)
        // Local-only files must not evict shared history on another device.
        let shared = Self.trimmed(Self.ordered(normalized.filter(\.isSyncEligible)))
        let local = Self.trimmed(Self.ordered(normalized.filter { !$0.isSyncEligible }))
        entries = Self.ordered(shared + local)
        let retainedIDs = Set(entries.map(\.id))
        let trimDate = normalized.map(\.capturedAt).max() ?? .distantPast
        for entry in normalized where !retainedIDs.contains(entry.id) {
            for id in [entry.id] + entry.duplicateIDs { retentionTombstones[id] = max(retentionTombstones[id] ?? .distantPast, trimDate) }
        }
    }

    private static func preferred(_ lhs: ClipboardEntry, _ rhs: ClipboardEntry) -> ClipboardEntry {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs }
        // A fixed byte comparison also resolves equal-clock updates the same way on each device.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let left = (try? encoder.encode(lhs)) ?? Data()
        let right = (try? encoder.encode(rhs)) ?? Data()
        return left.lexicographicallyPrecedes(right) ? rhs : lhs
    }
}
