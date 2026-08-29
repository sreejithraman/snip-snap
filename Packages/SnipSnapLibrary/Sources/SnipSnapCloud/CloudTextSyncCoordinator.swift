import Foundation

package protocol CloudTextSyncPersistence: Sendable {
    func loadEngineState() async throws -> CloudEngineStateEnvelope?
    func stagedBatches() async throws -> [CloudSyncBatch]
    func stage(_ batch: CloudSyncBatch) async throws
    func applyStaged(_ id: UUID) async throws
    func pendingChanges() async throws -> CloudOutboundBatch
    func clear() async throws
}

package actor CloudTextSyncCoordinator {
    private let store: any CloudTextSyncPersistence
    private let transport: any CloudRecordTransport
    private var started = false
    private var isSyncing = false

    package init(
        store: any CloudTextSyncPersistence,
        transport: any CloudRecordTransport
    ) {
        self.store = store
        self.transport = transport
    }

    package func sync() async throws {
        guard !isSyncing else { throw CloudTransportError.syncAlreadyRunning }
        isSyncing = true
        defer { isSyncing = false }

        try await recoverStagedBatches()
        if !started {
            try await transport.start(state: store.loadEngineState())
            started = true
        }

        let fetched = try await transport.fetch(scope: .all)
        try await commit(.fetched(fetched))

        let outbound = try await store.pendingChanges()
        guard !outbound.operations.isEmpty || !outbound.zonesToSave.isEmpty else { return }
        let sent = try await transport.send(outbound)
        try await commit(.sent(sent))
    }

    private func recoverStagedBatches() async throws {
        for batch in try await store.stagedBatches() {
            try await store.applyStaged(batch.id)
            try await transport.confirmApplied(batch.id)
        }
    }

    private func commit(_ batch: CloudSyncBatch) async throws {
        try await store.stage(batch)
        try await store.applyStaged(batch.id)
        try await transport.confirmApplied(batch.id)
    }
}
