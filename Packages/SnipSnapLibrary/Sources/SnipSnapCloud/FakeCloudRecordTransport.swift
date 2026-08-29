import Foundation

package enum FakeCloudError: Error, Equatable, Sendable {
    case injectedFetchFailure
    case injectedSendFailure
    case injectedAssetFailure
    case wrongBatchConfirmation
}

package enum FakeCloudTransportEvent: Equatable, Sendable {
    case started
    case fetched
    case sent([CloudRecordID])
    case confirmed(UUID)
}

package enum FakeCloudControlTransportEvent: Equatable, Sendable {
    case fetchedControl
    case createdZones(Set<CloudZoneID>)
    case savedControl(UUID)
    case controlConflict(UUID)
    case deletedZones(Set<CloudZoneID>)
}

package actor FakeCloudServer {
    private enum Event {
        case saved(sequence: Int, CloudRecordSnapshot)
        case deleted(sequence: Int, CloudRecordID)
        case database(sequence: Int, CloudDatabaseEvent, CloudZoneID)

        var sequence: Int {
            switch self {
            case .saved(let sequence, _), .deleted(let sequence, _),
                 .database(let sequence, _, _):
                sequence
            }
        }

        var zone: CloudZoneID {
            switch self {
            case .saved(_, let snapshot): snapshot.id.zone
            case .deleted(_, let id): id.zone
            case .database(_, _, let zone): zone
            }
        }
    }

    private var records: [CloudRecordID: CloudRecordSnapshot] = [:]
    private var events: [Event] = []
    private var nextSequence = 1
    private var acceptedCounts: [CloudRecordID: Int] = [:]
    private var acceptedDeleteCount = 0
    private var assets: [CloudRecordID: [String: URL]] = [:]
    private var zones: Set<CloudZoneID> = []
    private var control: CloudCollectionDescriptor?
    private var controlVersion = 0
    private let assetRoot: URL

    package init() {
        assetRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeCloudServer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: assetRoot)
    }

    private func save(_ draft: CloudRecordDraft) throws -> CloudSendItemResult {
        if let current = records[draft.id] {
            guard draft.base == current.shadow else {
                return .conflict(draft.id, server: current)
            }
        } else if draft.base != nil {
            return .unknownItem(draft.id)
        }

        let snapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))
        var storedAssets: [String: URL] = [:]
        for (field, upload) in draft.assetFields {
            let destination = assetRoot.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: upload.fileURL, to: destination)
            storedAssets[field] = destination
        }
        if !storedAssets.isEmpty { assets[draft.id] = storedAssets }
        records[draft.id] = snapshot
        events.append(.saved(sequence: nextSequence, snapshot))
        nextSequence += 1
        acceptedCounts[draft.id, default: 0] += 1
        return .saved(snapshot)
    }

    private func delete(_ id: CloudRecordID, base: CloudRecordShadow?) -> CloudSendItemResult {
        guard let current = records[id] else { return .unknownItem(id) }
        guard base == current.shadow else {
            return .conflict(id, server: current)
        }
        records[id] = nil
        assets[id] = nil
        events.append(.deleted(sequence: nextSequence, id))
        nextSequence += 1
        acceptedCounts[id, default: 0] += 1
        acceptedDeleteCount += 1
        return .deleted(id)
    }

    package func send(
        _ batch: CloudOutboundBatch,
        failures: [CloudRecordID: CloudOperationFailure]
    ) throws -> CloudSentBatch {
        guard Set(batch.operations.map(\.id)).count == batch.operations.count else {
            throw CloudTransportError.invalidRecord
        }
        let items = try batch.operations.map { operation in
            if let failure = failures[operation.id] {
                return CloudSendItemResult.failed(operation.id, failure)
            }
            switch operation {
            case .save(let draft): return try save(draft)
            case .delete(let id, let base): return delete(id, base: base)
            }
        }
        return CloudSentBatch(
            id: UUID(),
            items: items,
            databaseEvents: batch.zonesToSave.map(CloudDatabaseEvent.zoneSaved),
            engineState: nil
        )
    }

    package func changes(
        after cursors: [CloudZoneID: Int],
        scope: CloudFetchScope,
        failures: [CloudRecordID: CloudOperationFailure]
    ) -> (batch: CloudFetchedBatch, cursors: [CloudZoneID: Int]) {
        let matching = events.filter { event in
            scope.contains(event.zone) && event.sequence > (cursors[event.zone] ?? 0)
        }
        var advanced = cursors
        for event in matching {
            advanced[event.zone] = max(advanced[event.zone] ?? 0, event.sequence)
        }
        var latestByID: [CloudRecordID: Event] = [:]
        var databaseEvents: [CloudDatabaseEvent] = []
        for event in matching {
            switch event {
            case .saved(_, let snapshot): latestByID[snapshot.id] = event
            case .deleted(_, let id): latestByID[id] = event
            case .database(_, let value, _): databaseEvents.append(value)
            }
        }
        let latest = latestByID.values.sorted { $0.sequence < $1.sequence }
        var items = latest.compactMap { event -> CloudFetchItemResult? in
            switch event {
            case .saved(_, let snapshot): .record(snapshot)
            case .deleted(_, let id): .deleted(id)
            case .database: nil
            }
        }
        for (id, failure) in failures.sorted(by: { $0.key.name < $1.key.name }) {
            items.append(.failed(id, failure))
        }
        return (
            CloudFetchedBatch(
                id: UUID(),
                items: items,
                databaseEvents: databaseEvents,
                engineState: nil
            ),
            advanced
        )
    }

    package func snapshot(
        for id: CloudRecordID,
        fields: Set<String>
    ) throws -> CloudRecordSnapshot? {
        guard let snapshot = records[id] else { return nil }
        let record = try snapshot.shadow.record()
        return try CloudKitRecordMapper.snapshot(
            record,
            desiredFields: fields
        )
    }

    package func fullSnapshot(for id: CloudRecordID) -> CloudRecordSnapshot? {
        records[id]
    }

    package func asset(for id: CloudRecordID, field: String) -> URL? {
        assets[id]?[field]
    }

    package func acceptedOperationCount(for id: CloudRecordID) -> Int {
        acceptedCounts[id, default: 0]
    }

    package func acceptedDeletionCount() -> Int { acceptedDeleteCount }

    package func storedTextValues() -> [String] {
        records.values.compactMap { snapshot in
            guard case .string(let text)? = snapshot.encryptedFields["text"] else { return nil }
            return text
        }.sorted()
    }

    package func emitZoneDeletion(_ zone: CloudZoneID, reason: CloudZoneDeletionReason) {
        let event = CloudDatabaseEvent.zoneDeleted(zone, reason: reason)
        events.append(.database(sequence: nextSequence, event, zone))
        nextSequence += 1
    }

    package func seedControl(_ descriptor: CloudCollectionDescriptor) {
        control = descriptor
        controlVersion += 1
        zones.formUnion(descriptor.zones)
    }

    package func removeControl() {
        control = nil
        controlVersion += 1
    }

    package func fetchControl() -> CloudCollectionControlRecord? {
        control.map {
            CloudCollectionControlRecord(
                descriptor: $0,
                version: Data(String(controlVersion).utf8)
            )
        }
    }

    package func createZones(_ values: Set<CloudZoneID>) {
        zones.formUnion(values)
    }

    package func saveControl(
        _ descriptor: CloudCollectionDescriptor,
        replacing version: Data?
    ) -> CloudCollectionControlSaveResult {
        let current = fetchControl()
        guard current?.version == version else {
            if let current { return .conflict(current) }
            control = descriptor
            controlVersion += 1
            return .accepted(fetchControl()!)
        }
        control = descriptor
        controlVersion += 1
        return .accepted(fetchControl()!)
    }

    package func deleteZones(_ values: Set<CloudZoneID>) {
        zones.subtract(values)
        let recordIDs = records.keys.filter { values.contains($0.zone) }
        for id in recordIDs {
            records[id] = nil
            assets[id] = nil
        }
    }

    package func controlDescriptor() -> CloudCollectionDescriptor? { control }
    package func hasZone(_ zone: CloudZoneID) -> Bool { zones.contains(zone) }
}

package actor FakeCloudControlTransport: CloudCollectionControlTransport {
    private let server: FakeCloudServer
    private var eventLog: [FakeCloudControlTransportEvent] = []
    private var shouldPauseNextControlSave = false
    private var controlSavePaused = false
    private var controlSavePauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var controlSaveRelease: CheckedContinuation<Void, Never>?
    private var shouldFailNextZoneDelete = false

    package init(server: FakeCloudServer) {
        self.server = server
    }

    package func seedControl(_ descriptor: CloudCollectionDescriptor) async {
        await server.seedControl(descriptor)
    }

    package func removeControl() async {
        await server.removeControl()
    }

    package func fetchControl() async -> CloudCollectionControlRecord? {
        eventLog.append(.fetchedControl)
        return await server.fetchControl()
    }

    package func createZones(_ zones: Set<CloudZoneID>) async {
        eventLog.append(.createdZones(zones))
        await server.createZones(zones)
    }

    package func saveControl(
        _ descriptor: CloudCollectionDescriptor,
        replacing version: Data?
    ) async -> CloudCollectionControlSaveResult {
        if shouldPauseNextControlSave {
            shouldPauseNextControlSave = false
            controlSavePaused = true
            controlSavePauseWaiters.forEach { $0.resume() }
            controlSavePauseWaiters = []
            await withCheckedContinuation { controlSaveRelease = $0 }
        }
        let result = await server.saveControl(descriptor, replacing: version)
        switch result {
        case .accepted:
            eventLog.append(.savedControl(descriptor.generation))
        case .conflict(let current):
            eventLog.append(.controlConflict(current.descriptor.generation))
        }
        return result
    }

    package func deleteZones(_ zones: Set<CloudZoneID>) async throws {
        if shouldFailNextZoneDelete {
            shouldFailNextZoneDelete = false
            throw CloudTransportError.sendFailed
        }
        eventLog.append(.deletedZones(zones))
        await server.deleteZones(zones)
    }

    package func events() -> [FakeCloudControlTransportEvent] { eventLog }

    package func pauseNextControlSave() {
        shouldPauseNextControlSave = true
    }

    package func failNextZoneDelete() {
        shouldFailNextZoneDelete = true
    }

    package func waitUntilControlSavePauses() async {
        if controlSavePaused { return }
        await withCheckedContinuation { controlSavePauseWaiters.append($0) }
    }

    package func resumeControlSave() {
        controlSaveRelease?.resume()
        controlSaveRelease = nil
        controlSavePaused = false
    }
}

package actor FakeCloudRecordTransport: CloudRecordTransport {
    private let server: FakeCloudServer
    private let namespace: CloudSyncNamespace?
    private var committedCursors: [CloudZoneID: Int] = [:]
    private var pending: CloudSyncBatch?
    private var nextFetchFailure: FakeCloudError?
    private var nextTerminalFetchFailure: CloudTransportError?
    private var nextSendFailure: FakeCloudError?
    private var nextAssetFailure: FakeCloudError?
    private var fetchItemFailures: [CloudRecordID: CloudOperationFailure] = [:]
    private var sendItemFailures: [CloudRecordID: CloudOperationFailure] = [:]
    private var nextOmittedSentResult: CloudRecordID?
    private var nextDuplicatedSentResult: CloudRecordID?
    private var shouldReverseNextSentResults = false
    private var eventLog: [FakeCloudTransportEvent] = []
    private var shouldPauseNextFetch = false
    private var pausedFetch = false
    private var fetchPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchRelease: CheckedContinuation<Void, Never>?
    private var shouldPauseNextSend = false
    private var pausedSend = false
    private var sendPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendRelease: CheckedContinuation<Void, Never>?

    package init(server: FakeCloudServer, namespace: CloudSyncNamespace? = nil) {
        self.server = server
        self.namespace = namespace
    }

    package func start(state: CloudEngineStateEnvelope?) throws {
        eventLog.append(.started)
        guard let state else { return }
        if let namespace, state.namespace != namespace {
            throw CloudTransportError.stateNamespaceMismatch
        }
        do {
            committedCursors = try JSONDecoder().decode(
                [CloudZoneID: Int].self,
                from: state.serialization
            )
        } catch {
            throw CloudTransportError.invalidEngineState
        }
    }

    package func failNextFetch() { nextFetchFailure = .injectedFetchFailure }
    package func failNextFetchTerminally(_ error: CloudTransportError = .invalidEngineState) {
        nextTerminalFetchFailure = error
    }
    package func failNextSend() { nextSendFailure = .injectedSendFailure }
    package func failNextAssetFetch() { nextAssetFailure = .injectedAssetFailure }

    package func pauseNextFetch() { shouldPauseNextFetch = true }
    package func pauseNextSend() { shouldPauseNextSend = true }

    package func waitUntilFetchPauses() async {
        if pausedFetch { return }
        await withCheckedContinuation { fetchPauseWaiters.append($0) }
    }

    package func resumeFetch() {
        fetchRelease?.resume()
        fetchRelease = nil
        pausedFetch = false
    }

    package func waitUntilSendPauses() async {
        if pausedSend { return }
        await withCheckedContinuation { sendPauseWaiters.append($0) }
    }

    package func resumeSend() {
        sendRelease?.resume()
        sendRelease = nil
        pausedSend = false
    }

    package func failNextFetchedItem(
        _ id: CloudRecordID,
        failure: CloudOperationFailure
    ) {
        fetchItemFailures[id] = failure
    }

    package func failNextSentItem(
        _ id: CloudRecordID,
        failure: CloudOperationFailure
    ) {
        sendItemFailures[id] = failure
    }

    package func omitNextSentResult(_ id: CloudRecordID) {
        nextOmittedSentResult = id
    }

    package func duplicateNextSentResult(_ id: CloudRecordID) {
        nextDuplicatedSentResult = id
    }

    package func reverseNextSentResults() {
        shouldReverseNextSentResults = true
    }

    package func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
        eventLog.append(.fetched)
        if shouldPauseNextFetch {
            shouldPauseNextFetch = false
            pausedFetch = true
            fetchPauseWaiters.forEach { $0.resume() }
            fetchPauseWaiters = []
            await withCheckedContinuation { fetchRelease = $0 }
        }
        if case .fetched(let batch)? = pending { return batch }
        if pending != nil { throw FakeCloudError.wrongBatchConfirmation }
        if let failure = nextTerminalFetchFailure {
            nextTerminalFetchFailure = nil
            throw failure
        }
        if let failure = nextFetchFailure {
            nextFetchFailure = nil
            throw failure
        }
        let failures = fetchItemFailures
        fetchItemFailures = [:]
        let result = await server.changes(
            after: committedCursors,
            scope: scope,
            failures: failures
        )
        let batch = CloudFetchedBatch(
            id: result.batch.id,
            items: result.batch.items,
            databaseEvents: result.batch.databaseEvents,
            zoneEvents: result.batch.zoneEvents,
            engineState: envelope(for: result.cursors)
        )
        pending = .fetched(batch)
        pendingCursors = result.cursors
        return batch
    }

    private var pendingCursors: [CloudZoneID: Int]?

    package func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
        guard Set(batch.operations.map(\.id)).count == batch.operations.count else {
            throw CloudTransportError.invalidRecord
        }
        if shouldPauseNextSend {
            shouldPauseNextSend = false
            pausedSend = true
            sendPauseWaiters.forEach { $0.resume() }
            sendPauseWaiters = []
            await withCheckedContinuation { sendRelease = $0 }
        }
        if case .sent(let result)? = pending { return result }
        if pending != nil { throw FakeCloudError.wrongBatchConfirmation }
        eventLog.append(.sent(batch.operations.map(\.id).sorted { $0.name < $1.name }))
        if let failure = nextSendFailure {
            nextSendFailure = nil
            throw failure
        }
        let failures = sendItemFailures
        sendItemFailures = [:]
        let serverResult = try await server.send(batch, failures: failures)
        var items = serverResult.items
        if let id = nextOmittedSentResult {
            items.removeAll { $0.id == id }
            nextOmittedSentResult = nil
        }
        if let id = nextDuplicatedSentResult,
           let item = items.first(where: { $0.id == id }) {
            items.append(item)
            nextDuplicatedSentResult = nil
        }
        if shouldReverseNextSentResults {
            items.reverse()
            shouldReverseNextSentResults = false
        }
        let result = CloudSentBatch(
            id: serverResult.id,
            items: items,
            databaseEvents: serverResult.databaseEvents,
            zoneEvents: serverResult.zoneEvents,
            engineState: envelope(for: committedCursors)
        )
        pending = .sent(result)
        return result
    }

    package func confirmApplied(_ batchID: UUID) throws {
        eventLog.append(.confirmed(batchID))
        guard let pending else { return }
        guard pending.id == batchID else { throw FakeCloudError.wrongBatchConfirmation }
        if case .fetched = pending, let pendingCursors {
            committedCursors = pendingCursors
        }
        self.pending = nil
        pendingCursors = nil
    }

    package func fetchRecord(
        _ id: CloudRecordID,
        fields: Set<String>
    ) async throws -> CloudRecordSnapshot? {
        try await server.snapshot(for: id, fields: fields)
    }

    package func fetchAsset(
        _ id: CloudRecordID,
        field: String,
        destination: CloudAssetDestination
    ) async throws -> CloudAssetReceipt? {
        if let failure = nextAssetFailure {
            nextAssetFailure = nil
            throw failure
        }
        guard let source = await server.asset(for: id, field: field) else { return nil }
        return try CloudAssetFileCopy.copy(
            recordID: id,
            field: field,
            source: source,
            destination: destination
        )
    }

    private func envelope(
        for cursors: [CloudZoneID: Int]
    ) -> CloudEngineStateEnvelope? {
        guard let namespace,
              let serialization = try? JSONEncoder().encode(cursors)
        else { return nil }
        return CloudEngineStateEnvelope(namespace: namespace, serialization: serialization)
    }

    package func events() -> [FakeCloudTransportEvent] { eventLog }
}
