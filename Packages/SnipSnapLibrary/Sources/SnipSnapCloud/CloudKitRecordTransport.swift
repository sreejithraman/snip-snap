import CloudKit
import Foundation
import SnipSnapCore

package actor CloudKitRecordTransport: CloudRecordTransport, CloudAutomaticSyncConfiguring,
    CloudAutomaticSyncScheduling, CKSyncEngineDelegate {
    typealias RecordReader = @Sendable (
        _ recordIDs: [CKRecord.ID], _ desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]
    typealias EngineFactory = @Sendable (
        _ serialization: CKSyncEngine.State.Serialization?,
        _ automaticallySync: Bool,
        _ delegate: CloudKitRecordTransport
    ) -> any CloudKitRecordEngine

    private let namespace: CloudSyncNamespace
    private let automaticallyFetchedZones: Set<CloudZoneID>
    private let readRecords: RecordReader
    private let bound: CloudKitCallBound
    private let makeEngine: EngineFactory
    private var lifecycle = EngineLifecycle.stopped
    private var outboundQueue = CloudRecordOutboundQueue()
    private let mailbox = CloudRecordTransportMailbox()
    private var recordSendGate: RecordSendGate?
    private let diagnostics: AppDiagnosticRecorder
    private var lastDiagnosticSnapshot: AppDiagnosticEvent?

    package init(
        database: CKDatabase,
        namespace: CloudSyncNamespace,
        automaticallyFetchedZones: Set<CloudZoneID>? = nil,
        diagnostics: AppDiagnosticRecorder = AppDiagnosticRecorder.live,
        bound: CloudKitCallBound = .standard
    ) {
        self.init(
            namespace: namespace,
            automaticallyFetchedZones: automaticallyFetchedZones,
            diagnostics: diagnostics,
            bound: bound,
            readRecords: { recordIDs, desiredKeys in
                try await database.configuredWith(
                    configuration: bound.configuration(.transfer)
                ) { configured in
                    try await configured.records(for: recordIDs, desiredKeys: desiredKeys)
                }
            },
            makeEngine: { serialization, automaticallySync, delegate in
                var configuration = CKSyncEngine.Configuration(
                    database: database,
                    stateSerialization: serialization,
                    delegate: delegate
                )
                configuration.automaticallySync = automaticallySync
                return CKSyncEngine(configuration)
            }
        )
    }

    init(
        namespace: CloudSyncNamespace,
        automaticallyFetchedZones: Set<CloudZoneID>?,
        diagnostics: AppDiagnosticRecorder,
        bound: CloudKitCallBound = .standard,
        readRecords: @escaping RecordReader,
        makeEngine: @escaping EngineFactory
    ) {
        self.namespace = namespace
        self.automaticallyFetchedZones = automaticallyFetchedZones ?? namespace.zones
        self.diagnostics = diagnostics
        self.bound = bound
        self.readRecords = readRecords
        self.makeEngine = makeEngine
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
        guard case .stopped = lifecycle else { return }
        let serialization = try Self.validate(namespace: namespace, state: state)
        outboundQueue.restoreAdmission(outboundAdmission)
        let engine = makeEngine(serialization, recordSendGate != nil && !outboundAdmission.blocksAll, self)
        lifecycle = .running(RunningEngine(
            engine: engine,
            serialization: state?.serialization,
            initialFetch: state?.requiresInitialFetch == false ? .completed : .required
        ))
        observePendingAdmission()
        if let initialOutbound {
            try scheduleAutomaticSync(initialOutbound)
        }
        recordDiagnosticSnapshot()
    }

    package func configureAutomaticSync(
        workAvailableHandler: @escaping WorkAvailableHandler,
        recordSendGate: @escaping RecordSendGate
    ) {
        mailbox.configure(workAvailable: workAvailableHandler)
        self.recordSendGate = recordSendGate
    }

    package func reset() async {
        runningEngine?.cycles.finishAll()
        lifecycle = .stopped
        outboundQueue = CloudRecordOutboundQueue()
        mailbox.reset()
        recordDiagnosticSnapshot(reason: .stopped)
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
        guard let running = runningEngine else { throw CloudTransportError.notStarted }
        try await finishCurrentSyncCycle()
        guard isCurrent(running) else { throw CloudTransportError.notStarted }
        guard case .idle = running.explicitTransfer else { throw CloudTransportError.syncAlreadyRunning }
        let zones = automaticallyFetchedZones.filter { scope.contains($0) }
            .map(CloudKitRecordMapper.zoneID(for:))
        running.explicitTransfer = .fetching(zones: zones, result: nil)
        defer { running.explicitTransfer = .idle }
        running.fetchedBatch.isInitialFetch = running.initialFetch == .required
        do {
            try await running.engine.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(zones)))
        } catch {
            guard isCurrent(running) else { throw CloudTransportError.notStarted }
            CloudSyncDiagnostics.record(error, operation: "record fetch")
            running.fetchedBatch.databaseEvents.append(.failed(nil, Self.failure(error)))
            finishFetchedBatch(of: running)
        }
        guard isCurrent(running) else { throw CloudTransportError.notStarted }
        if let result = running.explicitTransfer.fetchedResult { return result }
        return finishFetchedBatch(of: running)
    }

    package func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
        guard Set(batch.operations.map(\.id)).count == batch.operations.count else {
            throw CloudTransportError.invalidRecord
        }
        guard let running = runningEngine else { throw CloudTransportError.notStarted }
        try await finishCurrentSyncCycle()
        guard isCurrent(running) else { throw CloudTransportError.notStarted }
        guard case .idle = running.explicitTransfer else { throw CloudTransportError.syncAlreadyRunning }
        running.explicitTransfer = .sending(result: nil)
        defer { running.explicitTransfer = .idle }
        try scheduleAutomaticSync(batch)
        do {
            try await running.engine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .all))
        } catch {
            guard isCurrent(running) else { throw CloudTransportError.notStarted }
            CloudSyncDiagnostics.record(error, operation: "record send")
            running.sentBatch.databaseEvents.append(.failed(nil, Self.failure(error)))
            if outboundQueue.cycle == nil { outboundQueue.beginCycle() }
            finishSentBatch(of: running)
        }
        guard isCurrent(running) else { throw CloudTransportError.notStarted }
        if let result = running.explicitTransfer.sentResult { return result }
        if outboundQueue.cycle == nil { outboundQueue.beginCycle() }
        return finishSentBatch(of: running)
    }

    package func confirmApplied(_ batchID: UUID) async throws {
        try confirmApplied(batchID, durableAdmission: nil)
    }

    package func confirmApplied(_ batchID: UUID, outboundAdmission: CloudRecordOutboundAdmission) async throws {
        try confirmApplied(batchID, durableAdmission: outboundAdmission)
    }

    private func confirmApplied(_ batchID: UUID, durableAdmission: CloudRecordOutboundAdmission?) throws {
        guard let event = try mailbox.confirm(batchID) else { return }
        if runningEngine?.unverifiedAccountEvent == batchID {
            runningEngine?.unverifiedAccountEvent = nil
        }
        if let durableAdmission {
            outboundQueue.confirmAdmission(batchID, durable: durableAdmission)
        } else if case .batch(let pending) = event {
            outboundQueue.confirmLegacyAdmission(pending.batch)
        }
        if case .batch(let pending) = event, case .sent(let sent) = pending.batch {
            outboundQueue.confirm(sent)
        }
        observePendingAdmission()
        recordDiagnosticSnapshot()
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

    package func finishCurrentSyncCycle() async throws {
        while let completion = runningEngine?.cycles.completion {
            try await completion.wait()
        }
        try Task.checkCancellation()
    }

    package func pendingEvent() -> CloudRecordTransportEvent? { mailbox.first }

    package func fetchRecord(
        _ id: CloudRecordID,
        fields: Set<String>
    ) async throws -> CloudRecordSnapshot? {
        let recordID = CloudKitRecordMapper.recordID(for: id)
        do {
            let results = try await boundedRead([recordID], Array(fields).sorted())
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
        var stage = CloudSyncDiagnostics.AttachmentStage.cloudKitRequest
        CloudSyncDiagnostics.attachmentStarted(stage)
        do {
            let results = try await boundedRead([recordID], [field])
            CloudSyncDiagnostics.attachmentSucceeded(stage)
            stage = .cloudKitRecord
            CloudSyncDiagnostics.attachmentStarted(stage)
            guard let result = results[recordID] else {
                CloudSyncDiagnostics.attachmentMissing(stage)
                return nil
            }
            let record = try result.get()
            CloudSyncDiagnostics.attachmentSucceeded(stage)
            stage = .cloudKitAssetURL
            CloudSyncDiagnostics.attachmentStarted(stage)
            guard let asset = record[field] as? CKAsset, let source = asset.fileURL else {
                CloudSyncDiagnostics.attachmentMissing(stage)
                return nil
            }
            CloudSyncDiagnostics.attachmentSucceeded(stage)
            stage = .assetCopy
            CloudSyncDiagnostics.attachmentStarted(stage)
            let receipt = try CloudAssetFileCopy.copy(
                recordID: id,
                field: field,
                source: source,
                destination: destination
            )
            CloudSyncDiagnostics.attachmentSucceeded(stage, byteCount: receipt.byteCount)
            return receipt
        } catch let error as CKError where error.code == .unknownItem {
            CloudSyncDiagnostics.attachmentMissing(.cloudKitRecord)
            return nil
        } catch {
            CloudSyncDiagnostics.attachmentFailed(stage, error: error)
            throw error
        }
    }

    /// Reads records with the transfer limits and the read backstop.
    private func boundedRead(
        _ recordIDs: [CKRecord.ID],
        _ desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        try await bound.read(.transfer) { [readRecords] in
            try await readRecords(recordIDs, desiredKeys)
        }
    }

    package func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        handle(CloudKitRecordEngineEvent(event), from: syncEngine)
    }

    func handle(_ event: CloudKitRecordEngineEvent, from syncEngine: any CloudKitRecordEngine) {
        guard let running = session(for: syncEngine) else { return }
        switch event {
        case .stateUpdate(let serialization):
            if let serialization {
                running.serialization = serialization
                if case .idle = running.cycles, let state = envelope(of: running) {
                    mailbox.append(.checkpoint(UUID(), state))
                }
            } else {
                running.fetchedBatch.databaseEvents.append(.failed(nil, .invalidRecord))
            }
        case .fetchedDatabaseChanges(let modifications, let deletions):
            running.fetchedBatch.databaseEvents.append(
                contentsOf: modifications.map {
                    .zoneChanged(CloudKitRecordMapper.id(for: $0))
                }
            )
            running.fetchedBatch.databaseEvents.append(
                contentsOf: deletions.map {
                    .zoneDeleted(
                        CloudKitRecordMapper.id(for: $0.zoneID),
                        reason: Self.deletionReason($0.reason)
                    )
                }
            )
        case .fetchedRecordZoneChanges(let modifications, let deletions):
            for record in modifications {
                do {
                    running.fetchedBatch.items.append(
                        .record(try CloudKitRecordMapper.snapshot(record))
                    )
                } catch {
                    running.fetchedBatch.items.append(
                        .failed(
                            CloudKitRecordMapper.id(for: record.recordID),
                            .invalidRecord
                        )
                    )
                }
            }
            running.fetchedBatch.items.append(
                contentsOf: deletions.map {
                    .deleted(CloudKitRecordMapper.id(for: $0))
                }
            )
        case .didFetchRecordZoneChanges(let zoneID, let error):
            let zone = CloudKitRecordMapper.id(for: zoneID)
            if let error {
                if Self.isEncryptedDataReset(error) {
                    running.fetchedBatch.databaseEvents.append(.zoneDeleted(zone, reason: .encryptedDataReset))
                } else {
                    running.fetchedBatch.zoneEvents.append(.failed(zone, Self.failure(error)))
                }
            } else {
                running.fetchedBatch.zoneEvents.append(.fetched(zone))
            }
        case .sentDatabaseChanges(let savedZones, let failedZoneSaves, let failedZoneDeletes,
                                  let deletedZoneIDs):
            running.sentBatch.databaseEvents.append(
                contentsOf: savedZones.map {
                    .zoneSaved(CloudKitRecordMapper.id(for: $0))
                }
            )
            running.sentBatch.databaseEvents.append(
                contentsOf: failedZoneSaves.map {
                    let zone = CloudKitRecordMapper.id(for: $0.zoneID)
                    return Self.isEncryptedDataReset($0.error)
                        ? .zoneDeleted(zone, reason: .encryptedDataReset)
                        : .failed(zone, Self.failure($0.error))
                }
            )
            running.sentBatch.databaseEvents.append(
                contentsOf: failedZoneDeletes.map {
                    let zone = CloudKitRecordMapper.id(for: $0.zoneID)
                    return Self.isEncryptedDataReset($0.error)
                        ? .zoneDeleted(zone, reason: .encryptedDataReset)
                        : .failed(zone, Self.failure($0.error))
                }
            )
            running.sentBatch.databaseEvents.append(
                contentsOf: deletedZoneIDs.map {
                    .zoneDeleted(CloudKitRecordMapper.id(for: $0), reason: .deleted)
                }
            )
        case .sentRecordZoneChanges(let savedRecords, let deletedRecordIDs, let failedRecordSaves,
                                    let failedRecordDeletes):
            for record in savedRecords {
                do {
                    let snapshot = try CloudKitRecordMapper.snapshot(record)
                    running.sentBatch.results[snapshot.id] = .saved(snapshot)
                } catch {
                    let id = CloudKitRecordMapper.id(for: record.recordID)
                    running.sentBatch.results[id] = .failed(id, .invalidRecord)
                }
            }
            for recordID in deletedRecordIDs {
                let id = CloudKitRecordMapper.id(for: recordID)
                running.sentBatch.results[id] = .deleted(id)
            }
            for failure in failedRecordSaves {
                let id = CloudKitRecordMapper.id(for: failure.recordID)
                if Self.isEncryptedDataReset(failure.error) {
                    running.sentBatch.databaseEvents.append(.zoneDeleted(id.zone, reason: .encryptedDataReset))
                }
                running.sentBatch.results[id] = sendResult(for: id, error: failure.error)
            }
            for (recordID, error) in failedRecordDeletes {
                let id = CloudKitRecordMapper.id(for: recordID)
                if Self.isEncryptedDataReset(error) {
                    running.sentBatch.databaseEvents.append(.zoneDeleted(id.zone, reason: .encryptedDataReset))
                }
                running.sentBatch.results[id] = sendResult(for: id, error: error)
            }
        case .willFetchChanges:
            diagnostics.record(.started(operation: "sync.fetch"))
            running.cycles.begin(.fetch)
            running.fetchedBatch.isInitialFetch = running.initialFetch == .required
        case .didFetchChanges:
            running.cycles.end(.fetch)
            finishFetchedBatch(of: running)
        case .willSendChanges:
            diagnostics.record(.started(operation: "sync.send"))
            running.cycles.begin(.send)
            outboundQueue.beginCycle()
        case .didSendChanges:
            running.cycles.end(.send)
            finishSentBatch(of: running)
        case .accountChange:
            let id = UUID()
            running.unverifiedAccountEvent = id
            mailbox.append(.accountChange(id))
        case .other:
            break
        }
        observePendingAdmission()
        recordDiagnosticSnapshot()
    }

    package func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await nextRecordZoneChangeBatch(scope: context.options.scope, from: syncEngine)
    }

    func nextRecordZoneChangeBatch(
        scope: CKSyncEngine.SendChangesOptions.Scope,
        from syncEngine: any CloudKitRecordEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let running = session(for: syncEngine) else { return nil }
        guard running.initialFetch == .completed, running.unverifiedAccountEvent == nil,
              !mailbox.blocksRecordProvider,
              !outboundQueue.admission.blocksAll else {
            recordDiagnosticSnapshot()
            return nil
        }
        do {
            try await recordSendGate?()
        } catch {
            if !CloudSyncDiagnostics.isCancellation(error) {
                diagnostics.record(.failure(operation: "sync.provider", error: error, visibility: .background))
            }
            return nil
        }
        guard isCurrent(running), running.initialFetch == .completed,
              running.unverifiedAccountEvent == nil, !mailbox.blocksRecordProvider,
              !outboundQueue.admission.blocksAll else { return nil }
        let pendingIDs = Set(syncEngine.pendingRecordZoneChanges.filter {
            scope.contains($0)
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
        guard let batch, isCurrent(running), outboundQueue.cycle?.id == sendCycle.id,
              running.unverifiedAccountEvent == nil, !outboundQueue.admission.blocksAll,
              !mailbox.blocksRecordProvider else { return nil }
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
        nextFetchChangesOptions()
    }

    func nextFetchChangesOptions() -> CKSyncEngine.FetchChangesOptions {
        CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(fetchZoneIDs))
    }

    private var runningEngine: RunningEngine? {
        guard case .running(let running) = lifecycle else { return nil }
        return running
    }

    private func session(for engine: any CloudKitRecordEngine) -> RunningEngine? {
        guard let running = runningEngine, running.engine === engine else { return nil }
        return running
    }

    private func isCurrent(_ running: RunningEngine) -> Bool {
        runningEngine === running
    }

    private var fetchZoneIDs: [CKRecordZone.ID] {
        guard let running = runningEngine else { return [] }
        return running.explicitTransfer.fetchZones
            ?? automaticallyFetchedZones.map(CloudKitRecordMapper.zoneID(for:))
    }

    private func recordMappingFailed(_ id: CloudRecordID, cycleID: UUID, from source: any CloudKitRecordEngine) {
        guard let running = session(for: source), outboundQueue.cycle?.id == cycleID else { return }
        outboundQueue.recordSupplied([id])
        running.sentBatch.results[id] = .failed(id, .invalidRecord)
    }

    private func envelope(of running: RunningEngine) -> CloudEngineStateEnvelope? {
        running.serialization.map {
            CloudEngineStateEnvelope(
                namespace: namespace, serialization: $0,
                requiresInitialFetch: running.initialFetch == .required
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
        guard let running = runningEngine else { return }
        let fetched = running.fetchedBatch
        let sent = running.sentBatch
        outboundQueue.observe(.fetched(CloudFetchedBatch(id: fetched.id, items: fetched.items,
            databaseEvents: fetched.databaseEvents, engineState: nil)), zones: namespace.zones)
        outboundQueue.observe(.sent(CloudSentBatch(id: sent.id, items: [],
            databaseEvents: sent.databaseEvents, engineState: nil)), zones: namespace.zones)
        let engine = running.engine
        let admission = outboundQueue.admission
        let blockedChanges = engine.pendingRecordZoneChanges.filter { change in
            let id: CKRecord.ID
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID): id = recordID
            @unknown default: return admission.blocksAll
            }
            return admission.blocksAll || admission.blockedRecordIDs.contains(CloudKitRecordMapper.id(for: id))
        }
        if !blockedChanges.isEmpty { engine.remove(pendingRecordZoneChanges: blockedChanges) }
        if admission.blocksAll, !engine.pendingDatabaseChanges.isEmpty {
            engine.remove(pendingDatabaseChanges: engine.pendingDatabaseChanges)
        }
    }

    private func recordDiagnosticSnapshot(reason explicitReason: AppDiagnosticSyncReason? = nil) {
        let counts = mailbox.diagnosticCounts
        let admission = outboundQueue.admission
        let initialFetchPending = runningEngine.map { $0.initialFetch == .required } ?? true
        let reason = explicitReason ?? (initialFetchPending ? .initialFetch
            : mailbox.blocksRecordProvider ? .uncommittedEvents
            : admission.blocksAll ? .recoveryBlocked
            : !admission.blockedRecordIDs.isEmpty ? .recordBlocked
            : outboundQueue.pendingOperationCount > 0 ? .pendingWork : nil)
        let snapshot = AppDiagnosticEvent.syncSnapshot(scope: .transport,
            environment: CloudSyncDiagnostics.environment, reason: reason,
            pendingUploads: outboundQueue.pendingOperationCount,
            pendingDownloads: counts.downloads + (runningEngine?.fetchedBatch.items.count ?? 0),
            pendingEvents: counts.events, blockedRecords: admission.blockedRecordIDs.count)
        guard snapshot != lastDiagnosticSnapshot else { return }
        lastDiagnosticSnapshot = snapshot
        diagnostics.record(snapshot)
    }

    @discardableResult
    private func finishFetchedBatch(of running: RunningEngine) -> CloudFetchedBatch {
        observePendingAdmission()
        completeInitialFetchIfReady(running)
        let draft = running.fetchedBatch
        let batch = CloudFetchedBatch(
            id: draft.id, items: draft.items, databaseEvents: draft.databaseEvents,
            zoneEvents: draft.zoneEvents,
            engineState: running.cycles.isRunning(.send) ? nil : envelope(of: running),
            isInitialFetch: draft.isInitialFetch
        )
        running.fetchedBatch = FetchedBatchDraft()
        mailbox.append(.batch(CloudPendingBatch(batch: .fetched(batch), outbound: nil)))
        running.explicitTransfer.recordFinished(batch)
        recordDiagnosticSnapshot()
        return batch
    }

    @discardableResult
    private func finishSentBatch(of running: RunningEngine) -> CloudSentBatch {
        observePendingAdmission()
        let draft = running.sentBatch
        running.sentBatch = SentBatchDraft()
        let sent = outboundQueue.finishCycle(draft.id)
        let batch = CloudSentBatch(
            id: draft.id,
            items: sent.operations.map { draft.results[$0.id] ?? .failed($0.id, .retryable) },
            databaseEvents: draft.databaseEvents,
            engineState: running.cycles.isRunning(.fetch) ? nil : envelope(of: running)
        )
        mailbox.append(.batch(CloudPendingBatch(batch: .sent(batch), outbound: sent)))
        running.explicitTransfer.recordFinished(batch)
        recordDiagnosticSnapshot()
        return batch
    }

    private func completeInitialFetchIfReady(_ running: RunningEngine) {
        let draft = running.fetchedBatch
        let completed = Set(draft.zoneEvents.compactMap { event -> CloudZoneID? in
            guard case .fetched(let zone) = event else { return nil }
            return zone
        })
        let fetched = CloudFetchedBatch(
            id: UUID(), items: draft.items, databaseEvents: draft.databaseEvents,
            zoneEvents: draft.zoneEvents, engineState: nil
        )
        if automaticallyFetchedZones.isSubset(of: completed),
           !CloudSyncIssueError.blocksOutbound(in: .fetched(fetched)) {
            running.initialFetch = .completed
        }
    }

    package func scheduleAutomaticSync(_ batch: CloudOutboundBatch) throws {
        guard let engine = runningEngine?.engine else { throw CloudTransportError.notStarted }
        defer { recordDiagnosticSnapshot() }
        let admitted = outboundQueue.schedule(batch)
        let desired = outboundQueue.current
        let records = Dictionary(desired.operations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let obsoleteRecords = engine.pendingRecordZoneChanges.filter { change in
            switch change {
            case .saveRecord(let id):
                if case .save? = records[CloudKitRecordMapper.id(for: id)] { return false }
            case .deleteRecord(let id):
                if case .delete? = records[CloudKitRecordMapper.id(for: id)] { return false }
            @unknown default: break
            }
            return true
        }
        let obsoleteZones = engine.pendingDatabaseChanges.filter { change in
            switch change {
            case .saveZone(let zone): !desired.zonesToSave.contains(CloudKitRecordMapper.id(for: zone.zoneID))
            case .deleteZone: true
            @unknown default: true
            }
        }
        if !obsoleteRecords.isEmpty { engine.remove(pendingRecordZoneChanges: obsoleteRecords) }
        if !obsoleteZones.isEmpty { engine.remove(pendingDatabaseChanges: obsoleteZones) }
        // A newer snapshot can withdraw queued work during a cycle, but cannot add
        // new record bodies until that cycle's exact acknowledgement commits.
        guard let admitted else { return }
        if !admitted.zonesToSave.isEmpty {
            engine.add(
                pendingDatabaseChanges: admitted.zonesToSave.map {
                    .saveZone(CKRecordZone(zoneID: CloudKitRecordMapper.zoneID(for: $0)))
                }
            )
        }
        if !admitted.operations.isEmpty {
            engine.add(
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

private enum EngineLifecycle {
    case stopped
    case running(RunningEngine)
}

/// Everything that lives exactly as long as one engine. Reset discards it whole, so its
/// identity is the session token late callbacks are checked against.
private final class RunningEngine {
    let engine: any CloudKitRecordEngine
    var serialization: Data?
    var initialFetch: InitialFetch
    var cycles = EngineCycles.idle
    // The engine clears its pending requests on an account change. Hold the
    // provider until the ordered consumer has checked the new account.
    var unverifiedAccountEvent: UUID?
    var explicitTransfer = ExplicitTransfer.idle
    var fetchedBatch = FetchedBatchDraft()
    var sentBatch = SentBatchDraft()

    init(engine: any CloudKitRecordEngine, serialization: Data?, initialFetch: InitialFetch) {
        self.engine = engine
        self.serialization = serialization
        self.initialFetch = initialFetch
    }
}

private enum InitialFetch {
    case required
    case completed
}

private enum EngineCycleKind {
    case fetch
    case send
}

/// Overlapping fetch and send cycles share one completion, finished when the last one ends.
private enum EngineCycles {
    case idle
    case running(Set<EngineCycleKind>, CloudRecordCycleCompletion)

    var completion: CloudRecordCycleCompletion? {
        guard case .running(_, let completion) = self else { return nil }
        return completion
    }

    func isRunning(_ kind: EngineCycleKind) -> Bool {
        guard case .running(let kinds, _) = self else { return false }
        return kinds.contains(kind)
    }

    mutating func begin(_ kind: EngineCycleKind) {
        switch self {
        case .idle:
            self = .running([kind], CloudRecordCycleCompletion())
        case .running(var kinds, let completion):
            kinds.insert(kind)
            self = .running(kinds, completion)
        }
    }

    mutating func end(_ kind: EngineCycleKind) {
        guard case .running(var kinds, let completion) = self, kinds.contains(kind) else { return }
        kinds.remove(kind)
        if kinds.isEmpty {
            self = .idle
            completion.finish()
        } else {
            self = .running(kinds, completion)
        }
    }

    mutating func finishAll() {
        let completion = self.completion
        self = .idle
        completion?.finish()
    }
}

/// At most one explicit fetch or send runs on an engine. It keeps the batch its own cycle finished.
private enum ExplicitTransfer {
    case idle
    case fetching(zones: [CKRecordZone.ID], result: CloudFetchedBatch?)
    case sending(result: CloudSentBatch?)

    var fetchZones: [CKRecordZone.ID]? {
        guard case .fetching(let zones, _) = self else { return nil }
        return zones
    }

    var fetchedResult: CloudFetchedBatch? {
        guard case .fetching(_, let result) = self else { return nil }
        return result
    }

    var sentResult: CloudSentBatch? {
        guard case .sending(let result) = self else { return nil }
        return result
    }

    mutating func recordFinished(_ batch: CloudFetchedBatch) {
        guard case .fetching(let zones, _) = self else { return }
        self = .fetching(zones: zones, result: batch)
    }

    mutating func recordFinished(_ batch: CloudSentBatch) {
        guard case .sending = self else { return }
        self = .sending(result: batch)
    }
}

private struct FetchedBatchDraft {
    let id = UUID()
    var isInitialFetch = false
    var items: [CloudFetchItemResult] = []
    var databaseEvents: [CloudDatabaseEvent] = []
    var zoneEvents: [CloudZoneEvent] = []
}

private struct SentBatchDraft {
    let id = UUID()
    var results: [CloudRecordID: CloudSendItemResult] = [:]
    var databaseEvents: [CloudDatabaseEvent] = []
}
