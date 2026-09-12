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
    private var fetchedBatchID = UUID()
    private var sentBatchID = UUID()
    private var fetchedItems: [CloudFetchItemResult] = []
    private var fetchedDatabaseEvents: [CloudDatabaseEvent] = []
    private var fetchedZoneEvents: [CloudZoneEvent] = []
    private var outboundQueue = CloudRecordOutboundQueue()
    private var sendResults: [CloudRecordID: CloudSendItemResult] = [:]
    private var sentDatabaseEvents: [CloudDatabaseEvent] = []
    private var sentZoneEvents: [CloudZoneEvent] = []
    private let mailbox = CloudRecordTransportMailbox()
    private var explicitFetchedBatch: CloudFetchedBatch?
    private var explicitSentBatch: CloudSentBatch?
    private var cycleCompletion: CloudRecordCycleCompletion?
    private var isPerformingSyncOperation = false
    private var automaticallySync = false
    private var recordSendGate: RecordSendGate?
    private var fetchCycleInProgress = false
    private var sendCycleInProgress = false
    private var requiresInitialFetch = true

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
        try start(state: state, initialOutbound: initialOutbound, outboundAdmission: .open)
    }

    package func start(
        state: CloudEngineStateEnvelope?,
        initialOutbound: CloudOutboundBatch?,
        outboundAdmission: CloudRecordOutboundAdmission
    ) throws {
        guard engine == nil else { return }
        let serialization = try Self.validate(namespace: namespace, state: state)
        outboundQueue.restoreAdmission(outboundAdmission)
        currentSerialization = state?.serialization
        requiresInitialFetch = state == nil || state?.requiresInitialFetch == true
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = automaticallySync && !outboundAdmission.blocksAll
        currentFetchZones = automaticallyFetchedZones.map(CloudKitRecordMapper.zoneID(for:))
        engine = CKSyncEngine(configuration)
        observePendingAdmission()
        if let initialOutbound {
            try schedule(initialOutbound)
        }
    }

    package func configureAutomaticSync(
        workAvailableHandler: @escaping WorkAvailableHandler,
        recordSendGate: @escaping RecordSendGate
    ) {
        automaticallySync = true
        mailbox.configure(workAvailable: workAvailableHandler)
        self.recordSendGate = recordSendGate
    }

    package func reset() {
        engine = nil
        currentSerialization = nil
        currentFetchZones = []
        fetchedBatchID = UUID()
        sentBatchID = UUID()
        fetchedItems = []
        fetchedDatabaseEvents = []
        fetchedZoneEvents = []
        outboundQueue = CloudRecordOutboundQueue()
        sendResults = [:]
        sentDatabaseEvents = []
        sentZoneEvents = []
        mailbox.reset()
        explicitFetchedBatch = nil
        explicitSentBatch = nil
        isPerformingSyncOperation = false
        fetchCycleInProgress = false
        sendCycleInProgress = false
        requiresInitialFetch = true
        resumeCycleWaiters()
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
        guard let engine else { throw CloudTransportError.notStarted }
        try await waitForCurrentCycle()
        guard self.engine === engine else { throw CloudTransportError.notStarted }
        guard !isPerformingSyncOperation else { throw CloudTransportError.syncAlreadyRunning }
        isPerformingSyncOperation = true
        defer { if self.engine === engine { isPerformingSyncOperation = false } }
        explicitFetchedBatch = nil
        currentFetchZones = automaticallyFetchedZones.filter { scope.contains($0) }
            .map(CloudKitRecordMapper.zoneID(for:))
        defer {
            if self.engine === engine {
                currentFetchZones = automaticallyFetchedZones.map(CloudKitRecordMapper.zoneID(for:))
            }
        }
        do {
            try await engine.fetchChanges(
                CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(currentFetchZones))
            )
        } catch {
            guard self.engine === engine else { throw CloudTransportError.notStarted }
            CloudSyncDiagnostics.record(error, operation: "record fetch")
            fetchedDatabaseEvents.append(.failed(nil, Self.failure(error)))
            finishFetchCycle()
        }
        guard self.engine === engine else { throw CloudTransportError.notStarted }
        if explicitFetchedBatch == nil { finishFetchCycle() }
        return explicitFetchedBatch!
    }

    package func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
        guard Set(batch.operations.map(\.id)).count == batch.operations.count else {
            throw CloudTransportError.invalidRecord
        }
        guard let engine else { throw CloudTransportError.notStarted }
        try await waitForCurrentCycle()
        guard self.engine === engine else { throw CloudTransportError.notStarted }
        guard !isPerformingSyncOperation else { throw CloudTransportError.syncAlreadyRunning }
        isPerformingSyncOperation = true
        defer { if self.engine === engine { isPerformingSyncOperation = false } }
        explicitSentBatch = nil
        try schedule(batch)
        do {
            try await engine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .all))
        } catch {
            guard self.engine === engine else { throw CloudTransportError.notStarted }
            CloudSyncDiagnostics.record(error, operation: "record send")
            sentDatabaseEvents.append(.failed(nil, Self.failure(error)))
            if outboundQueue.cycle == nil { outboundQueue.beginCycle() }
            finishSendCycle()
        }
        guard self.engine === engine else { throw CloudTransportError.notStarted }
        if explicitSentBatch == nil {
            if outboundQueue.cycle == nil { outboundQueue.beginCycle() }
            finishSendCycle()
        }
        return explicitSentBatch!
    }

    package func confirmApplied(_ batchID: UUID) async throws {
        try confirmApplied(batchID, durableAdmission: nil)
    }

    package func confirmApplied(_ batchID: UUID, outboundAdmission: CloudRecordOutboundAdmission) async throws {
        try confirmApplied(batchID, durableAdmission: outboundAdmission)
    }

    private func confirmApplied(_ batchID: UUID, durableAdmission: CloudRecordOutboundAdmission?) throws {
        guard let event = try mailbox.confirm(batchID) else { return }
        if let durableAdmission {
            outboundQueue.confirmAdmission(batchID, durable: durableAdmission)
        } else if case .batch(let pending) = event {
            outboundQueue.confirmLegacyAdmission(pending.batch)
        }
        if case .batch(let pending) = event, case .sent(let sent) = pending.batch {
            outboundQueue.confirm(sent)
        }
        observePendingAdmission()
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

    package func finishCurrentSyncCycle() async throws { try await waitForCurrentCycle() }

    package func scheduleAutomaticSync(_ batch: CloudOutboundBatch) throws {
        try schedule(batch)
    }

    package func pendingEvent() -> CloudRecordTransportEvent? { mailbox.first }

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
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let update):
            do {
                currentSerialization = try JSONEncoder().encode(update.stateSerialization)
                if !fetchCycleInProgress, !sendCycleInProgress, let state = envelope() {
                    mailbox.append(.checkpoint(UUID(), state))
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
            if cycleCompletion == nil { cycleCompletion = CloudRecordCycleCompletion() }
            fetchCycleInProgress = true
        case .didFetchChanges:
            fetchCycleInProgress = false
            finishFetchCycle()
            resumeCycleWaiters()
        case .willSendChanges:
            if cycleCompletion == nil { cycleCompletion = CloudRecordCycleCompletion() }
            sendCycleInProgress = true
            outboundQueue.beginCycle()
        case .didSendChanges:
            sendCycleInProgress = false
            finishSendCycle()
            resumeCycleWaiters()
        case .accountChange:
            mailbox.append(.accountChange(UUID()))
        default:
            break
        }
        observePendingAdmission()
    }

    package func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine, !requiresInitialFetch, !mailbox.hasUncommittedRecords,
              !outboundQueue.admission.blocksAll else { return nil }
        do {
            try await recordSendGate?()
        } catch {
            return nil
        }
        guard syncEngine === engine, !requiresInitialFetch, !mailbox.hasUncommittedRecords,
              !outboundQueue.admission.blocksAll else { return nil }
        let pendingIDs = Set(syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }.compactMap { change -> CloudRecordID? in
            switch change {
            case .saveRecord(let id), .deleteRecord(let id): CloudKitRecordMapper.id(for: id)
            @unknown default: nil
            }
        })
        guard let sendCycle = outboundQueue.cycle else { return nil }
        let pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = sendCycle.operations(
            pendingIDs: pendingIDs
        ).map { operation in
            let id = CloudKitRecordMapper.recordID(for: operation.id)
            return switch operation {
            case .save: .saveRecord(id)
            case .delete: .deleteRecord(id)
            }
        }
        let batch = await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pendingChanges,
            recordProvider: { [weak self] recordID in
                guard let draft = sendCycle.draft(CloudKitRecordMapper.id(for: recordID))
                else { return nil }
                do {
                    return try CloudKitRecordMapper.record(for: draft)
                } catch {
                    await self?.recordMappingFailed(draft.id, cycleID: sendCycle.id, from: syncEngine)
                    return nil
                }
            }
        )
        guard let batch, syncEngine === engine, outboundQueue.cycle?.id == sendCycle.id,
              !outboundQueue.admission.blocksAll, !mailbox.hasUncommittedRecords else { return nil }
        let suppliedIDs = Set((batch.recordsToSave.map(\.recordID) + batch.recordIDsToDelete)
            .map(CloudKitRecordMapper.id(for:)))
        guard Set(outboundQueue.cycle?.operations(pendingIDs: suppliedIDs).map(\.id) ?? []) == suppliedIDs
        else { return nil }
        outboundQueue.recordSupplied(suppliedIDs)
        return batch
    }

    package func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(currentFetchZones))
    }

    private func recordMappingFailed(_ id: CloudRecordID, cycleID: UUID, from source: CKSyncEngine) {
        guard source === engine, outboundQueue.cycle?.id == cycleID else { return }
        outboundQueue.recordSupplied([id])
        sendResults[id] = .failed(id, .invalidRecord)
    }

    private func envelope() -> CloudEngineStateEnvelope? {
        currentSerialization.map {
            CloudEngineStateEnvelope(
                namespace: namespace, serialization: $0,
                requiresInitialFetch: requiresInitialFetch
            )
        }
    }

    private func sendResult(for id: CloudRecordID, error: CKError) -> CloudSendItemResult {
        guard outboundQueue.cycle?.outbound.operations.contains(where: { $0.id == id }) == true
        else { return .failed(id, .rejected) }
        if error.code == .serverRecordChanged,
           let server = error.serverRecord,
           let snapshot = try? CloudKitRecordMapper.snapshot(server)
        {
            return .conflict(id, server: snapshot)
        }
        if error.code == .unknownItem { return .unknownItem(id) }
        return .failed(id, Self.failure(error))
    }

    private func observePendingAdmission() {
        outboundQueue.observe(.fetched(CloudFetchedBatch(id: fetchedBatchID, items: fetchedItems,
            databaseEvents: fetchedDatabaseEvents, engineState: nil)), zones: namespace.zones)
        outboundQueue.observe(.sent(CloudSentBatch(id: sentBatchID, items: [],
            databaseEvents: sentDatabaseEvents, engineState: nil)), zones: namespace.zones)
        guard let engine else { return }
        let admission = outboundQueue.admission
        let blockedChanges = engine.state.pendingRecordZoneChanges.filter { change in
            let id: CKRecord.ID
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID): id = recordID
            @unknown default: return admission.blocksAll
            }
            return admission.blocksAll || admission.blockedRecordIDs.contains(CloudKitRecordMapper.id(for: id))
        }
        if !blockedChanges.isEmpty { engine.state.remove(pendingRecordZoneChanges: blockedChanges) }
        if admission.blocksAll, !engine.state.pendingDatabaseChanges.isEmpty {
            engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        }
    }

    private func finishFetchCycle() {
        observePendingAdmission()
        updateInitialFetchReadiness()
        let batch = CloudFetchedBatch(
            id: fetchedBatchID, items: fetchedItems, databaseEvents: fetchedDatabaseEvents,
            zoneEvents: fetchedZoneEvents, engineState: sendCycleInProgress ? nil : envelope()
        )
        fetchedItems = []
        fetchedDatabaseEvents = []
        fetchedZoneEvents = []
        fetchedBatchID = UUID()
        mailbox.append(.batch(CloudPendingBatch(batch: .fetched(batch), outbound: nil)))
        if isPerformingSyncOperation { explicitFetchedBatch = batch }
    }

    private func finishSendCycle() {
        observePendingAdmission()
        let id = sentBatchID
        sentBatchID = UUID()
        let sent = outboundQueue.finishCycle(id)
        let batch = CloudSentBatch(
            id: id,
            items: sent.operations.map { sendResults[$0.id] ?? .failed($0.id, .retryable) },
            databaseEvents: sentDatabaseEvents,
            zoneEvents: sentZoneEvents,
            engineState: fetchCycleInProgress ? nil : envelope()
        )
        sendResults = [:]
        sentDatabaseEvents = []
        sentZoneEvents = []
        mailbox.append(.batch(CloudPendingBatch(batch: .sent(batch), outbound: sent)))
        if isPerformingSyncOperation { explicitSentBatch = batch }
    }

    private func waitForCurrentCycle() async throws {
        while let completion = cycleCompletion {
            try await completion.wait()
        }
        try Task.checkCancellation()
    }

    private func resumeCycleWaiters() {
        guard !fetchCycleInProgress, !sendCycleInProgress else { return }
        let completion = cycleCompletion
        cycleCompletion = nil
        completion?.finish()
    }

    private func updateInitialFetchReadiness() {
        let completed = Set(fetchedZoneEvents.compactMap { event -> CloudZoneID? in
            guard case .fetched(let zone) = event else { return nil }
            return zone
        })
        let fetched = CloudFetchedBatch(
            id: UUID(), items: fetchedItems, databaseEvents: fetchedDatabaseEvents,
            zoneEvents: fetchedZoneEvents, engineState: nil
        )
        if automaticallyFetchedZones.isSubset(of: completed),
           !CloudSyncIssueError.blocksOutbound(in: .fetched(fetched)) {
            requiresInitialFetch = false
        }
    }

    private func schedule(_ batch: CloudOutboundBatch) throws {
        guard let engine else { throw CloudTransportError.notStarted }
        let admitted = outboundQueue.schedule(batch)
        let desired = outboundQueue.current
        let records = Dictionary(desired.operations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let obsoleteRecords = engine.state.pendingRecordZoneChanges.filter { change in
            switch change {
            case .saveRecord(let id):
                if case .save? = records[CloudKitRecordMapper.id(for: id)] { return false }
            case .deleteRecord(let id):
                if case .delete? = records[CloudKitRecordMapper.id(for: id)] { return false }
            @unknown default: break
            }
            return true
        }
        let obsoleteZones = engine.state.pendingDatabaseChanges.filter { change in
            switch change {
            case .saveZone(let zone): !desired.zonesToSave.contains(CloudKitRecordMapper.id(for: zone.zoneID))
            case .deleteZone: true
            @unknown default: true
            }
        }
        if !obsoleteRecords.isEmpty { engine.state.remove(pendingRecordZoneChanges: obsoleteRecords) }
        if !obsoleteZones.isEmpty { engine.state.remove(pendingDatabaseChanges: obsoleteZones) }
        // A newer snapshot can withdraw queued work during a cycle, but cannot add
        // new record bodies until that cycle's exact acknowledgement commits.
        guard let admitted else { return }
        if !admitted.zonesToSave.isEmpty {
            engine.state.add(
                pendingDatabaseChanges: admitted.zonesToSave.map {
                    .saveZone(CKRecordZone(zoneID: CloudKitRecordMapper.zoneID(for: $0)))
                }
            )
        }
        if !admitted.operations.isEmpty {
            engine.state.add(
                pendingRecordZoneChanges: admitted.operations.map { operation in
                    let recordID = CloudKitRecordMapper.recordID(for: operation.id)
                    return switch operation {
                    case .save: .saveRecord(recordID)
                    case .delete: .deleteRecord(recordID)
                    }
                }
            )
        }
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
