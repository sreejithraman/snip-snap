import CloudKit
import CryptoKit
import Foundation

public enum ClipboardCloudError: Error, Equatable, LocalizedError {
    case conflict, accountChanged, unavailable, invalidPayload, busy, payloadTooLarge
    public var errorDescription: String? {
        switch self {
        case .conflict: String(localized: "Clipboard history changed on another device. Try syncing again.", bundle: .main)
        case .accountChanged: String(localized: "Clipboard history belongs to a different iCloud account or library.", bundle: .main)
        case .unavailable: String(localized: "Clipboard sync is unavailable. Try again later.", bundle: .main)
        case .invalidPayload: String(localized: "A clipboard item could not be read.", bundle: .main)
        case .busy: String(localized: "Clipboard history is syncing.", bundle: .main)
        case .payloadTooLarge: String(localized: "This clipboard entry exceeds the 32 MB size limit.", bundle: .main)
        }
    }
}

package struct ClipboardCloudSnapshot: Sendable {
    package var entries: [UUID: Data]
    package var tombstones: [UUID: Date]
    package var retentionTombstones: [UUID: Date]
    package var version: Data?
    package init(entries: [UUID: Data] = [:], tombstones: [UUID: Date] = [:], retentionTombstones: [UUID: Date] = [:], version: Data? = nil) {
        self.entries = entries; self.tombstones = tombstones; self.retentionTombstones = retentionTombstones; self.version = version
    }
}

package final class ClipboardCloudCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    package func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    package func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

package protocol ClipboardCloudTransport: Sendable {
    func fetch() async throws -> ClipboardCloudSnapshot
    func save(_ snapshot: ClipboardCloudSnapshot, cancellation: ClipboardCloudCancellation) async throws
    func deleteAll() async throws
}

/// Immutable entry assets keep an edit from retransferring the rest of history.
/// One compare-and-swap manifest makes merging history and its tombstones atomic.
package enum ClipboardCloudRecordCodec {
    package static func manifestRecord(id: CKRecord.ID) -> CKRecord {
        CKRecord(recordType: "SnipSnapClipboardManifest", recordID: id)
    }
    package static func payloadRecord(id: CKRecord.ID) -> CKRecord {
        CKRecord(recordType: "SnipSnapClipboardPayload", recordID: id)
    }
    package static func setPayload(_ url: URL, on record: CKRecord) { record["payload"] = CKAsset(fileURL: url) }
}

package struct ClipboardCloudPayloadReference: Codable, Equatable {
    package let recordName: String
    package let digest: String
    package init(data: Data, recordName: String = UUID().uuidString) {
        self.recordName = recordName
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

package actor CloudKitClipboardTransport: ClipboardCloudTransport {
    private struct Manifest: Codable {
        var entries: [UUID: ClipboardCloudPayloadReference]
        var tombstones: [UUID: Date]
        var retentionTombstones: [UUID: Date]?
    }
    private let database: CKDatabase
    private let zone: CKRecordZone.ID
    private var cache: [String: Data] = [:]
    private var uploaded: Set<String> = []
    private var zoneReady = false
    private var fetchedReferences: Set<String> = []
    package init(database: CKDatabase, generation: String) {
        self.database = database
        let digest = Self.digest(Data(generation.utf8))
        zone = CKRecordZone.ID(zoneName: "SnipSnapClipboard-" + String(digest.prefix(24)))
    }
    private func prepare() async throws {
        guard !zoneReady else { return }
        _ = try await database.save(CKRecordZone(zoneID: zone))
        zoneReady = true
    }
    package func fetch() async throws -> ClipboardCloudSnapshot {
        try await prepare()
        let record: CKRecord
        do { record = try await database.record(for: CKRecord.ID(recordName: "manifest", zoneID: zone)) }
        catch let error as CKError where error.code == .unknownItem {
            cache = [:]; uploaded = []; fetchedReferences = []
            return ClipboardCloudSnapshot()
        }
        guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else { throw ClipboardCloudError.invalidPayload }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        fetchedReferences = Set(manifest.entries.values.map(\.recordName))
        uploaded = fetchedReferences
        cache = cache.filter { fetchedReferences.contains($0.key) }
        var entries: [UUID: Data] = [:]
        for (id, reference) in manifest.entries {
            let recordName = reference.recordName
            if let data = cache[recordName] { entries[id] = data; continue }
            let payload = try await database.record(for: CKRecord.ID(recordName: recordName, zoneID: zone))
            guard let asset = payload["payload"] as? CKAsset, let url = asset.fileURL else { throw ClipboardCloudError.invalidPayload }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1_024 * 1_024 else { throw ClipboardCloudError.payloadTooLarge }
            let data = try Data(contentsOf: url)
            guard Self.digest(data) == reference.digest else { throw ClipboardCloudError.invalidPayload }
            entries[id] = data; cache[recordName] = data; uploaded.insert(recordName)
        }
        return ClipboardCloudSnapshot(entries: entries, tombstones: manifest.tombstones,
                                      retentionTombstones: manifest.retentionTombstones ?? [:], version: try CloudRecordShadow.archive(record).data)
    }
    package func save(_ snapshot: ClipboardCloudSnapshot, cancellation: ClipboardCloudCancellation) async throws {
        try cancellation.check()
        try await prepare()
        try cancellation.check()
        var references: [UUID: ClipboardCloudPayloadReference] = [:]
        for (id, data) in snapshot.entries {
            try cancellation.check()
            let recordName = cache.first { $0.value == data }?.key ?? UUID().uuidString
            references[id] = ClipboardCloudPayloadReference(data: data, recordName: recordName)
            guard !uploaded.contains(recordName) else { continue }
            let record = ClipboardCloudRecordCodec.payloadRecord(id: CKRecord.ID(recordName: recordName, zoneID: zone))
            try await saveAsset(data, record: record, policy: .allKeys, cancellation: cancellation)
            cache[recordName] = data; uploaded.insert(recordName)
        }
        let record: CKRecord
        if let version = snapshot.version { record = try CloudRecordShadow(data: version).record() }
        else { record = ClipboardCloudRecordCodec.manifestRecord(id: CKRecord.ID(recordName: "manifest", zoneID: zone)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(Manifest(entries: references, tombstones: snapshot.tombstones, retentionTombstones: snapshot.retentionTombstones))
        let obsolete = fetchedReferences.subtracting(references.values.map(\.recordName))
        do {
            try await saveAsset(data, record: record, policy: .ifServerRecordUnchanged,
                                deleting: obsolete.map { CKRecord.ID(recordName: $0, zoneID: zone) }, cancellation: cancellation)
        } catch let error as CKError {
            if Self.isConflict(error, recordID: record.recordID) { throw ClipboardCloudError.conflict }
            throw error
        }
        for recordName in obsolete { cache[recordName] = nil; uploaded.remove(recordName) }
        fetchedReferences = Set(references.values.map(\.recordName))
    }

    package static func isConflict(_ error: CKError, recordID: CKRecord.ID) -> Bool {
        if error.code == .serverRecordChanged { return true }
        guard error.code == .partialFailure,
              let nested = error.partialErrorsByItemID?[recordID] as? CKError else { return false }
        return nested.code == .serverRecordChanged
    }

    private func saveAsset(_ data: Data, record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy,
                           deleting: [CKRecord.ID] = [], cancellation: ClipboardCloudCancellation) async throws {
        try cancellation.check()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        ClipboardCloudRecordCodec.setPayload(url, on: record)
        try cancellation.check()
        let results = try await database.modifyRecords(saving: [record], deleting: deleting, savePolicy: policy, atomically: true)
        guard let result = results.saveResults[record.recordID] else { throw ClipboardCloudError.invalidPayload }
        _ = try result.get()
    }
    package func deleteAll() async throws {
        do { _ = try await database.deleteRecordZone(withID: zone) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem { }
        zoneReady = false; uploaded = []; cache = [:]; fetchedReferences = []
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
