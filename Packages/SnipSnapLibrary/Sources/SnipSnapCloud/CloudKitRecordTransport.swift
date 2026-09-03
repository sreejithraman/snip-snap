import CloudKit
import Foundation

package actor CloudKitRecordTransport: CloudRecordTransport, CloudAutomaticSyncConfiguring,
    CloudAutomaticSyncScheduling, CKSyncEngineDelegate {
    private let database: CKDatabase
    private let namespace: CloudSyncNamespace
    private let automaticallyFetchedZones: Set<CloudZoneID>
    private var engine: CKSyncEngine?
    private var currentSerialization: Data?
    private var currentFetchZones: [CKRecordZone.ID] = []
    private var fetchedItems: [CloudFetchItemResult] = []
    private var fetchedDatabaseEvents: [CloudDatabaseEvent] = []
    private var fetchedZoneEvents: [CloudZoneEvent] = []
    private var outbound: [CloudRecordID: CloudOutboundOperation] = [:]
    private var outboundOrder: [CloudRecordID] = []
    private var sendResults: [CloudRecordID: CloudSendItemResult] = [:]
    private var sentDatabaseEvents: [CloudDatabaseEvent] = []
    private var sentZoneEvents: [CloudZoneEvent] = []
    private var currentOutboundBatch: CloudOutboundBatch?
    private var pending: CloudSyncBatch?
    private var isPerformingSyncOperation = false
    private var automaticBatchHandler: BatchHandler?
    private var accountChangeHandler: AccountChangeHandler?
    private var recordSendGate: RecordSendGate?
    private var engineStateHandler: EngineStateHandler?
    private var automaticFetchReady = false
    private var automaticSendReady = false
    private var fetchCycleInProgress = false
    private var sendCycleInProgress = false

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
        try start(state: state, initialOutbound: nil)
    }

    package func start(
        state: CloudEngineStateEnvelope?,
        initialOutbound: CloudOutboundBatch?
    ) throws {
        guard engine == nil else { return }
        let serialization = try Self.validate(namespace: namespace, state: state)
        currentSerialization = state?.serialization
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = automaticBatchHandler != nil
        currentFetchZones = automaticallyFetchedZones.map(CloudKitRecordMapper.zoneID(for:))
        engine = CKSyncEngine(configuration)
        if let initialOutbound {
            try schedule(initialOutbound)
        }
    }

    package func configureAutomaticSync(
        batchHandler: @escaping BatchHandler,
        accountChangeHandler: @escaping AccountChangeHandler,
        recordSendGate: @escaping RecordSendGate,
        engineStateHandler: @escaping EngineStateHandler
    ) {
        automaticBatchHandler = batchHandler
        self.accountChangeHandler = accountChangeHandler
        self.recordSendGate = recordSendGate
        self.engineStateHandler = engineStateHandler
    }

    package func reset() {
        engine = nil
        currentSerialization = nil
        currentFetchZones = []
        fetchedItems = []
        fetchedDatabaseEvents = []
        fetchedZoneEvents = []
        outbound = [:]
        outboundOrder = []
        sendResults = [:]
        sentDatabaseEvents = []
        sentZoneEvents = []
        currentOutboundBatch = nil
        pending = nil
        isPerformingSyncOperation = false
        automaticFetchReady = false
        automaticSendReady = false
        fetchCycleInProgress = false
        sendCycleInProgress = false
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
        guard !isPerformingSyncOperation, !fetchCycleInProgress, !sendCycleInProgress else {
            throw CloudTransportError.syncAlreadyRunning
        }
        isPerformingSyncOperation = true
        defer { isPerformingSyncOperation = false }
        currentFetchZones = automaticallyFetchedZones
            .filter { scope.contains($0) }
            .map(CloudKitRecordMapper.zoneID(for:))
        defer {
            currentFetchZones = automaticallyFetchedZones.map(CloudKitRecordMapper.zoneID(for:))
        }
        fetchedItems = []
        fetchedDatabaseEvents = []
        fetchedZoneEvents = []
        do {
            try await engine.fetchChanges(
                CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(currentFetchZones))
            )
        } catch {
            CloudSyncDiagnostics.record(error, operation: "record fetch")
            fetchedDatabaseEvents.append(.failed(nil, Self.failure(error)))
        }
        let batch = CloudFetchedBatch(
            id: UUID(),
            items: fetchedItems,
            databaseEvents: fetchedDatabaseEvents,
            zoneEvents: fetchedZoneEvents,
            engineState: envelope()
        )
        fetchedItems = []
        fetchedDatabaseEvents = []
        fetchedZoneEvents = []
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
        guard !isPerformingSyncOperation, !fetchCycleInProgress, !sendCycleInProgress else {
            throw CloudTransportError.syncAlreadyRunning
        }
        isPerformingSyncOperation = true
        defer { isPerformingSyncOperation = false }
        try schedule(batch)
        sendResults = [:]
        sentDatabaseEvents = []
        sentZoneEvents = []

        do {
            try await engine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .all))
        } catch {
            CloudSyncDiagnostics.record(error, operation: "record send")
            sentDatabaseEvents.append(.failed(nil, Self.failure(error)))
        }
        let items = outboundOrder.map { id in
            sendResults[id] ?? .failed(id, .retryable)
        }
        let result = CloudSentBatch(
            id: UUID(),
            items: items,
            databaseEvents: sentDatabaseEvents,
            zoneEvents: sentZoneEvents,
            engineState: envelope()
        )
        sendResults = [:]
        sentDatabaseEvents = []
        sentZoneEvents = []
        pending = .sent(result)
        return result
    }

    package func confirmApplied(_ batchID: UUID) async throws {
        guard let pending else { return }
        guard pending.id == batchID else {
            throw CloudTransportError.wrongBatchConfirmation
        }
        self.pending = nil
        if case .sent(let sent) = pending {
            let retrying = Self.retryingRecordIDs(in: sent)
            outbound = outbound.filter { retrying.contains($0.key) }
            outboundOrder = outboundOrder.filter(retrying.contains)
            currentOutboundBatch = outbound.isEmpty
                ? nil
                : CloudOutboundBatch(
                    operations: outboundOrder.compactMap { outbound[$0] },
                    zonesToSave: currentOutboundBatch?.zonesToSave ?? []
                )
            sendResults = [:]
        }
    }

    package nonisolated static func retryingRecordIDs(
        in batch: CloudSentBatch
    ) -> Set<CloudRecordID> {
        Set(batch.items.compactMap { result in
            guard case .failed(let id, let failure) = result,
                  failure.isRetryable
            else { return nil }
            return id
        })
    }

    package func drainAutomaticSyncEvents() async {
        await deliverAutomaticFetchIfNeeded()
        await deliverAutomaticSendIfNeeded()
    }

    package func scheduleAutomaticSync(_ batch: CloudOutboundBatch) throws {
        guard engine != nil else { throw CloudTransportError.notStarted }
        try schedule(batch)
    }

    package func pendingBatch() -> CloudPendingBatch? {
        guard let pending else { return nil }
        let pendingOutbound: CloudOutboundBatch?
        switch pending {
        case .fetched:
            pendingOutbound = nil
        case .sent:
            pendingOutbound = currentOutboundBatch
        }
        return CloudPendingBatch(batch: pending, outbound: pendingOutbound)
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
        do {
            let results = try await database.records(for: [recordID], desiredKeys: [field])
            guard let result = results[recordID] else { return nil }
            let record = try result.get()
            guard let asset = record[field] as? CKAsset, let source = asset.fileURL else {
                return nil
            }
            return try CloudAssetFileCopy.copy(
                recordID: id,
                field: field,
                source: source,
                destination: destination
            )
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    package func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            do {
                currentSerialization = try JSONEncoder().encode(update.stateSerialization)
                if !isPerformingSyncOperation,
                   !fetchCycleInProgress,
                   !sendCycleInProgress,
                   pending == nil,
                   let envelope = envelope(),
                   let engineStateHandler
                {
                    do {
                        try await engineStateHandler(envelope)
                    } catch {
                        automaticFetchReady = true
                        await deliverAutomaticFetchIfNeeded()
                    }
                }
            } catch {
                fetchedDatabaseEvents.append(.failed(nil, .invalidRecord))
            }
        case .fetchedDatabaseChanges(let changes):
            fetchedDatabaseEvents.append(
                contentsOf: changes.modifications.map {
                    .zoneChanged(CloudKitRecordMapper.id(for: $0.zoneID))
                }
            )
            fetchedDatabaseEvents.append(
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
                    fetchedDatabaseEvents.append(.zoneDeleted(zone, reason: .encryptedDataReset))
                } else {
                    fetchedZoneEvents.append(.failed(zone, Self.failure(error)))
                }
            } else {
                fetchedZoneEvents.append(.fetched(zone))
            }
        case .sentDatabaseChanges(let changes):
            sentDatabaseEvents.append(
                contentsOf: changes.savedZones.map {
                    .zoneSaved(CloudKitRecordMapper.id(for: $0.zoneID))
                }
            )
            sentDatabaseEvents.append(
                contentsOf: changes.failedZoneSaves.map {
                    let zone = CloudKitRecordMapper.id(for: $0.zone.zoneID)
                    return Self.isEncryptedDataReset($0.error)
                        ? .zoneDeleted(zone, reason: .encryptedDataReset)
                        : .failed(zone, Self.failure($0.error))
                }
            )
            sentDatabaseEvents.append(
                contentsOf: changes.failedZoneDeletes.map {
                    let zone = CloudKitRecordMapper.id(for: $0.key)
                    return Self.isEncryptedDataReset($0.value)
                        ? .zoneDeleted(zone, reason: .encryptedDataReset)
                        : .failed(zone, Self.failure($0.value))
                }
            )
            sentDatabaseEvents.append(
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
                    sentDatabaseEvents.append(.zoneDeleted(id.zone, reason: .encryptedDataReset))
                }
                sendResults[id] = sendResult(for: id, error: failure.error)
            }
            for (recordID, error) in changes.failedRecordDeletes {
                let id = CloudKitRecordMapper.id(for: recordID)
                if Self.isEncryptedDataReset(error) {
                    sentDatabaseEvents.append(.zoneDeleted(id.zone, reason: .encryptedDataReset))
                }
                sendResults[id] = sendResult(for: id, error: error)
            }
        case .willFetchChanges:
            fetchCycleInProgress = true
        case .didFetchChanges:
            fetchCycleInProgress = false
            if !isPerformingSyncOperation {
                automaticFetchReady = true
                await deliverAutomaticFetchIfNeeded()
            }
        case .willSendChanges:
            sendCycleInProgress = true
        case .didSendChanges:
            sendCycleInProgress = false
            if !isPerformingSyncOperation {
                automaticSendReady = true
                await deliverAutomaticSendIfNeeded()
            }
        case .accountChange:
            await accountChangeHandler?()
        default:
            break
        }
    }

    package func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        do {
            try await recordSendGate?()
        } catch {
            return nil
        }
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

    private func deliverAutomaticFetchIfNeeded() async {
        guard automaticFetchReady,
              !isPerformingSyncOperation,
              pending == nil,
              let automaticBatchHandler
        else { return }
        let batch = CloudFetchedBatch(
            id: UUID(),
            items: fetchedItems,
            databaseEvents: fetchedDatabaseEvents,
            zoneEvents: fetchedZoneEvents,
            engineState: envelope()
        )
        fetchedItems = []
        fetchedDatabaseEvents = []
        fetchedZoneEvents = []
        automaticFetchReady = false
        pending = .fetched(batch)
        do {
            try await automaticBatchHandler(.fetched(batch), nil)
        } catch {
            // Leave the batch pending so the next explicit sync can apply it.
        }
    }

    private func deliverAutomaticSendIfNeeded() async {
        if automaticSendReady, currentOutboundBatch == nil {
            automaticSendReady = false
            sendResults = [:]
            sentDatabaseEvents = []
            sentZoneEvents = []
            return
        }
        guard automaticSendReady,
              !isPerformingSyncOperation,
              pending == nil,
              let automaticBatchHandler,
              let currentOutboundBatch
        else { return }
        let items = outboundOrder.map { id in
            sendResults[id] ?? .failed(id, .retryable)
        }
        let batch = CloudSentBatch(
            id: UUID(),
            items: items,
            databaseEvents: sentDatabaseEvents,
            zoneEvents: sentZoneEvents,
            engineState: envelope()
        )
        sentDatabaseEvents = []
        sentZoneEvents = []
        automaticSendReady = false
        pending = .sent(batch)
        do {
            try await automaticBatchHandler(.sent(batch), currentOutboundBatch)
        } catch {
            // Leave the batch pending so the next explicit sync can apply it.
        }
    }

    private func schedule(_ batch: CloudOutboundBatch) throws {
        guard let engine else { throw CloudTransportError.notStarted }
        for operation in batch.operations {
            if outbound[operation.id] == nil { outboundOrder.append(operation.id) }
            outbound[operation.id] = operation
        }
        let zones = (currentOutboundBatch?.zonesToSave ?? []).union(batch.zonesToSave)
        currentOutboundBatch = CloudOutboundBatch(
            operations: outboundOrder.compactMap { outbound[$0] },
            zonesToSave: zones
        )
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
    }

    package nonisolated static func failure(_ error: Error) -> CloudOperationFailure {
        guard let error = error as? CKError else { return .retryable }
        return switch error.code {
        case .networkUnavailable: .networkUnavailable
        case .networkFailure, .serviceUnavailable, .serverResponseLost: .iCloudUnavailable
        case .requestRateLimited, .zoneBusy: .rateLimited
        case .notAuthenticated: .authenticationRequired
        case .accountTemporarilyUnavailable: .accountTemporarilyUnavailable
        case .quotaExceeded: .quotaExceeded
        case .incompatibleVersion: .updateRequired
        case .permissionFailure, .managedAccountRestricted: .accessDenied
        case .assetFileModified, .assetFileNotFound: .attachmentMissing
        case .assetNotAvailable: .attachmentUnavailable
        case .changeTokenExpired: .changeTokenExpired
        case .zoneNotFound: .zoneMissing
        case .operationCancelled: .retryable
        case let code where CloudKitRetryPolicy.isTransient(code): .retryable
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
