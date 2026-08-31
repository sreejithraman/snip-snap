import CloudKit
import Foundation

package actor CloudKitRecordTransport: CloudRecordTransport, CKSyncEngineDelegate {
    private let database: CKDatabase
    private let namespace: CloudSyncNamespace
    private let automaticallyFetchedZones: Set<CloudZoneID>
    private var engine: CKSyncEngine?
    private var currentSerialization: Data?
    private var currentFetchZones: [CKRecordZone.ID] = []
    private var fetchedItems: [CloudFetchItemResult] = []
    private var databaseEvents: [CloudDatabaseEvent] = []
    private var zoneEvents: [CloudZoneEvent] = []
    private var outbound: [CloudRecordID: CloudOutboundOperation] = [:]
    private var outboundOrder: [CloudRecordID] = []
    private var sendResults: [CloudRecordID: CloudSendItemResult] = [:]
    private var pending: CloudSyncBatch?
    private var isPerformingSyncOperation = false

    package init(
        database: CKDatabase,
        namespace: CloudSyncNamespace,
        automaticallyFetchedZones: Set<CloudZoneID>? = nil
    ) {
        self.database = database
        self.namespace = namespace
        self.automaticallyFetchedZones = automaticallyFetchedZones ?? namespace.zones
    }

    package func start(state: CloudEngineStateEnvelope?) throws {
        guard engine == nil else { return }
        let serialization = try Self.validate(namespace: namespace, state: state)
        currentSerialization = state?.serialization
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = false
        engine = CKSyncEngine(configuration)
    }

    package nonisolated static func validate(
        namespace: CloudSyncNamespace,
        state: CloudEngineStateEnvelope?
    ) throws -> CKSyncEngine.State.Serialization? {
        guard let state else { return nil }
        guard state.namespace == namespace else {
            throw CloudTransportError.stateNamespaceMismatch
        }
        do {
            return try JSONDecoder().decode(
                CKSyncEngine.State.Serialization.self,
                from: state.serialization
            )
        } catch {
            throw CloudTransportError.invalidEngineState
        }
    }

    package func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
        if case .fetched(let batch)? = pending { return batch }
        if pending != nil { throw CloudTransportError.wrongBatchConfirmation }
        guard let engine else { throw CloudTransportError.notStarted }
        guard !isPerformingSyncOperation else { throw CloudTransportError.syncAlreadyRunning }
        isPerformingSyncOperation = true
        defer { isPerformingSyncOperation = false }
        currentFetchZones = automaticallyFetchedZones
            .filter { scope.contains($0) }
            .map(CloudKitRecordMapper.zoneID(for:))
        fetchedItems = []
        databaseEvents = []
        zoneEvents = []
        do {
            try await engine.fetchChanges(
                CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(currentFetchZones))
            )
        } catch {
            databaseEvents.append(.failed(nil, Self.failure(error)))
        }
        let batch = CloudFetchedBatch(
            id: UUID(),
            items: fetchedItems,
            databaseEvents: databaseEvents,
            zoneEvents: zoneEvents,
            engineState: envelope()
        )
        pending = .fetched(batch)
        return batch
    }

    package func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
        guard Set(batch.operations.map(\.id)).count == batch.operations.count else {
            throw CloudTransportError.invalidRecord
        }
        if case .sent(let result)? = pending { return result }
        if pending != nil { throw CloudTransportError.wrongBatchConfirmation }
        guard let engine else { throw CloudTransportError.notStarted }
        guard !isPerformingSyncOperation else { throw CloudTransportError.syncAlreadyRunning }
        isPerformingSyncOperation = true
        defer { isPerformingSyncOperation = false }
        outbound = Dictionary(uniqueKeysWithValues: batch.operations.map { ($0.id, $0) })
        outboundOrder = batch.operations.map(\.id)
        sendResults = [:]
        databaseEvents = []
        zoneEvents = []

        engine.state.add(
            pendingDatabaseChanges: batch.zonesToSave.map {
                .saveZone(CKRecordZone(zoneID: CloudKitRecordMapper.zoneID(for: $0)))
            }
        )
        engine.state.add(
            pendingRecordZoneChanges: batch.operations.map { operation in
                let recordID = CloudKitRecordMapper.recordID(for: operation.id)
                return switch operation {
                case .save: .saveRecord(recordID)
                case .delete: .deleteRecord(recordID)
                }
            }
        )
        do {
            try await engine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .all))
        } catch {
            databaseEvents.append(.failed(nil, Self.failure(error)))
        }
        let items = outboundOrder.map { id in
            sendResults[id] ?? .failed(id, .retryable)
        }
        let result = CloudSentBatch(
            id: UUID(),
            items: items,
            databaseEvents: databaseEvents,
            zoneEvents: zoneEvents,
            engineState: envelope()
        )
        pending = .sent(result)
        return result
    }

    package func confirmApplied(_ batchID: UUID) throws {
        guard let pending else { return }
        guard pending.id == batchID else {
            throw CloudTransportError.wrongBatchConfirmation
        }
        self.pending = nil
    }

    package func fetchRecord(
        _ id: CloudRecordID,
        fields: Set<String>
    ) async throws -> CloudRecordSnapshot? {
        let recordID = CloudKitRecordMapper.recordID(for: id)
        do {
            let results = try await database.records(
                for: [recordID],
                desiredKeys: Array(fields).sorted()
            )
            guard let result = results[recordID] else { return nil }
            do {
                return try CloudKitRecordMapper.snapshot(
                    result.get(),
                    desiredFields: fields
                )
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw CloudTransportError.fetchFailed
        }
    }

    package func fetchAsset(
        _ id: CloudRecordID,
        field: String,
        destination: CloudAssetDestination
    ) async throws -> CloudAssetReceipt? {
        let recordID = CloudKitRecordMapper.recordID(for: id)
        let box = CloudAssetFetchResultBox()
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: [recordID])
            operation.desiredKeys = [field]
            operation.perRecordResultBlock = { _, result in
                switch result {
                case .success(let record):
                    guard let asset = record[field] as? CKAsset,
                          let source = asset.fileURL
                    else {
                        box.set(.success(nil))
                        return
                    }
                    do {
                        box.set(
                            .success(
                                try CloudAssetFileCopy.copy(
                                    recordID: id,
                                    field: field,
                                    source: source,
                                    destination: destination
                                )
                            )
                        )
                    } catch {
                        box.set(.failure(error))
                    }
                case .failure(let error as CKError) where error.code == .unknownItem:
                    box.set(.success(nil))
                case .failure(let error):
                    box.set(.failure(error))
                }
            }
            operation.fetchRecordsResultBlock = { result in
                if let copied = box.take() {
                    continuation.resume(with: copied)
                    return
                }
                switch result {
                case .success:
                    continuation.resume(returning: nil)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    package func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            do {
                currentSerialization = try JSONEncoder().encode(update.stateSerialization)
            } catch {
                databaseEvents.append(.failed(nil, .invalidRecord))
            }
        case .fetchedDatabaseChanges(let changes):
            databaseEvents.append(
                contentsOf: changes.modifications.map {
                    .zoneChanged(CloudKitRecordMapper.id(for: $0.zoneID))
                }
            )
            databaseEvents.append(
                contentsOf: changes.deletions.map {
                    .zoneDeleted(
                        CloudKitRecordMapper.id(for: $0.zoneID),
                        reason: Self.deletionReason($0.reason)
                    )
                }
            )
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                do {
                    fetchedItems.append(
                        .record(try CloudKitRecordMapper.snapshot(modification.record))
                    )
                } catch {
                    fetchedItems.append(
                        .failed(
                            CloudKitRecordMapper.id(for: modification.record.recordID),
                            .invalidRecord
                        )
                    )
                }
            }
            fetchedItems.append(
                contentsOf: changes.deletions.map {
                    .deleted(CloudKitRecordMapper.id(for: $0.recordID))
                }
            )
        case .didFetchRecordZoneChanges(let result):
            let zone = CloudKitRecordMapper.id(for: result.zoneID)
            if let error = result.error {
                if Self.isEncryptedDataReset(error) {
                    databaseEvents.append(.zoneDeleted(zone, reason: .encryptedDataReset))
                } else {
                    zoneEvents.append(.failed(zone, Self.failure(error)))
                }
            } else {
                zoneEvents.append(.fetched(zone))
            }
        case .sentDatabaseChanges(let changes):
            databaseEvents.append(
                contentsOf: changes.savedZones.map {
                    .zoneSaved(CloudKitRecordMapper.id(for: $0.zoneID))
                }
            )
            databaseEvents.append(
                contentsOf: changes.failedZoneSaves.map {
                    let zone = CloudKitRecordMapper.id(for: $0.zone.zoneID)
                    return Self.isEncryptedDataReset($0.error)
                        ? .zoneDeleted(zone, reason: .encryptedDataReset)
                        : .failed(zone, Self.failure($0.error))
                }
            )
            databaseEvents.append(
                contentsOf: changes.failedZoneDeletes.map {
                    let zone = CloudKitRecordMapper.id(for: $0.key)
                    return Self.isEncryptedDataReset($0.value)
                        ? .zoneDeleted(zone, reason: .encryptedDataReset)
                        : .failed(zone, Self.failure($0.value))
                }
            )
            databaseEvents.append(
                contentsOf: changes.deletedZoneIDs.map {
                    .zoneDeleted(CloudKitRecordMapper.id(for: $0), reason: .deleted)
                }
            )
        case .sentRecordZoneChanges(let changes):
            for record in changes.savedRecords {
                do {
                    let snapshot = try CloudKitRecordMapper.snapshot(record)
                    sendResults[snapshot.id] = .saved(snapshot)
                } catch {
                    let id = CloudKitRecordMapper.id(for: record.recordID)
                    sendResults[id] = .failed(id, .invalidRecord)
                }
            }
            for recordID in changes.deletedRecordIDs {
                let id = CloudKitRecordMapper.id(for: recordID)
                sendResults[id] = .deleted(id)
            }
            for failure in changes.failedRecordSaves {
                let id = CloudKitRecordMapper.id(for: failure.record.recordID)
                if Self.isEncryptedDataReset(failure.error) {
                    databaseEvents.append(.zoneDeleted(id.zone, reason: .encryptedDataReset))
                }
                sendResults[id] = sendResult(for: id, error: failure.error)
            }
            for (recordID, error) in changes.failedRecordDeletes {
                let id = CloudKitRecordMapper.id(for: recordID)
                if Self.isEncryptedDataReset(error) {
                    databaseEvents.append(.zoneDeleted(id.zone, reason: .encryptedDataReset))
                }
                sendResults[id] = sendResult(for: id, error: error)
            }
        default:
            break
        }
    }

    package func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pendingChanges,
            recordProvider: { [weak self] recordID in
                guard let self,
                      let draft = await self.draftToSend(
                          CloudKitRecordMapper.id(for: recordID)
                      )
                else { return nil }
                do {
                    return try CloudKitRecordMapper.record(for: draft)
                } catch {
                    await self.recordMappingFailed(draft.id)
                    return nil
                }
            }
        )
    }

    package func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(currentFetchZones))
    }

    private func draftToSend(_ id: CloudRecordID) -> CloudRecordDraft? {
        guard case .save(let draft)? = outbound[id] else { return nil }
        return draft
    }

    private func recordMappingFailed(_ id: CloudRecordID) {
        sendResults[id] = .failed(id, .invalidRecord)
    }

    private func envelope() -> CloudEngineStateEnvelope? {
        currentSerialization.map {
            CloudEngineStateEnvelope(namespace: namespace, serialization: $0)
        }
    }

    private func sendResult(for id: CloudRecordID, error: CKError) -> CloudSendItemResult {
        guard let operation = outbound[id] else { return .failed(id, .rejected) }
        if error.code == .serverRecordChanged,
           let server = error.serverRecord,
           let snapshot = try? CloudKitRecordMapper.snapshot(server)
        {
            return .conflict(operation.id, server: snapshot)
        }
        if error.code == .unknownItem { return .unknownItem(id) }
        return .failed(id, Self.failure(error))
    }

    private nonisolated static func failure(_ error: Error) -> CloudOperationFailure {
        guard let error = error as? CKError else { return .retryable }
        return switch error.code {
        case .quotaExceeded: .quotaExceeded
        case .networkFailure, .networkUnavailable, .requestRateLimited, .serviceUnavailable,
             .zoneBusy: .retryable
        case .zoneNotFound: .zoneMissing
        default: .rejected
        }
    }

    package nonisolated static func isEncryptedDataReset(_ error: Error) -> Bool {
        guard let error = error as? CKError, error.code == .zoneNotFound else { return false }
        return error.userInfo[CKErrorUserDidResetEncryptedDataKey] as? Bool == true
    }

    private nonisolated static func deletionReason(
        _ reason: CKDatabase.DatabaseChange.Deletion.Reason
    ) -> CloudZoneDeletionReason {
        switch reason {
        case .deleted: .deleted
        case .purged: .purged
        case .encryptedDataReset: .encryptedDataReset
        @unknown default: .deleted
        }
    }
}

private final class CloudAssetFetchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CloudAssetReceipt?, Error>?

    func set(_ result: Result<CloudAssetReceipt?, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.result = result
    }

    func take() -> Result<CloudAssetReceipt?, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
