import CloudKit
import Foundation

/// The CKSyncEngine surface the record transport drives, so tests can supply a scripted engine.
protocol CloudKitRecordEngine: AnyObject, Sendable {
    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws
    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { get }
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])
    func remove(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])
}

extension CKSyncEngine: CloudKitRecordEngine {
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] {
        state.pendingRecordZoneChanges
    }

    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] {
        state.pendingDatabaseChanges
    }

    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        state.add(pendingRecordZoneChanges: changes)
    }

    func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        state.remove(pendingRecordZoneChanges: changes)
    }

    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        state.add(pendingDatabaseChanges: changes)
    }

    func remove(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        state.remove(pendingDatabaseChanges: changes)
    }
}

/// The CKSyncEngine events the record transport handles, with payloads tests can build.
enum CloudKitRecordEngineEvent: Sendable {
    /// The JSON-encoded engine state, or nil when CloudKit's serialization could not be encoded.
    case stateUpdate(Data?)
    case accountChange
    case fetchedDatabaseChanges(
        modifications: [CKRecordZone.ID],
        deletions: [(zoneID: CKRecordZone.ID, reason: CKDatabase.DatabaseChange.Deletion.Reason)]
    )
    case fetchedRecordZoneChanges(modifications: [CKRecord], deletions: [CKRecord.ID])
    case didFetchRecordZoneChanges(zoneID: CKRecordZone.ID, error: CKError?)
    case sentDatabaseChanges(
        savedZones: [CKRecordZone.ID],
        failedZoneSaves: [(zoneID: CKRecordZone.ID, error: CKError)],
        failedZoneDeletes: [(zoneID: CKRecordZone.ID, error: CKError)],
        deletedZoneIDs: [CKRecordZone.ID]
    )
    case sentRecordZoneChanges(
        savedRecords: [CKRecord],
        deletedRecordIDs: [CKRecord.ID],
        failedRecordSaves: [(recordID: CKRecord.ID, error: CKError)],
        failedRecordDeletes: [(recordID: CKRecord.ID, error: CKError)]
    )
    case willFetchChanges
    case didFetchChanges
    case willSendChanges
    case didSendChanges
    case other

    init(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let update):
            self = .stateUpdate(try? JSONEncoder().encode(update.stateSerialization))
        case .accountChange:
            self = .accountChange
        case .fetchedDatabaseChanges(let changes):
            self = .fetchedDatabaseChanges(
                modifications: changes.modifications.map(\.zoneID),
                deletions: changes.deletions.map { (zoneID: $0.zoneID, reason: $0.reason) }
            )
        case .fetchedRecordZoneChanges(let changes):
            self = .fetchedRecordZoneChanges(
                modifications: changes.modifications.map(\.record),
                deletions: changes.deletions.map(\.recordID)
            )
        case .didFetchRecordZoneChanges(let result):
            self = .didFetchRecordZoneChanges(zoneID: result.zoneID, error: result.error)
        case .sentDatabaseChanges(let changes):
            self = .sentDatabaseChanges(
                savedZones: changes.savedZones.map(\.zoneID),
                failedZoneSaves: changes.failedZoneSaves.map { (zoneID: $0.zone.zoneID, error: $0.error) },
                failedZoneDeletes: changes.failedZoneDeletes.map { (zoneID: $0.key, error: $0.value) },
                deletedZoneIDs: changes.deletedZoneIDs
            )
        case .sentRecordZoneChanges(let changes):
            self = .sentRecordZoneChanges(
                savedRecords: changes.savedRecords,
                deletedRecordIDs: changes.deletedRecordIDs,
                failedRecordSaves: changes.failedRecordSaves.map {
                    (recordID: $0.record.recordID, error: $0.error)
                },
                failedRecordDeletes: changes.failedRecordDeletes.map { (recordID: $0.key, error: $0.value) }
            )
        case .willFetchChanges:
            self = .willFetchChanges
        case .didFetchChanges:
            self = .didFetchChanges
        case .willSendChanges:
            self = .willSendChanges
        case .didSendChanges:
            self = .didSendChanges
        default:
            self = .other
        }
    }
}
