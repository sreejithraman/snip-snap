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

        try await prepare()
        try await fetchAndCommit()
        try await sendAndCommit()
    }

    package func fetchRemote(
        beforeApply: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        guard !isSyncing else { throw CloudTransportError.syncAlreadyRunning }
        isSyncing = true
        defer { isSyncing = false }

        try await prepare()
        try await fetchAndCommit(beforeApply: beforeApply)
    }

    package func sendPending(
        beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void = { _ in }
    ) async throws {
        guard !isSyncing else { throw CloudTransportError.syncAlreadyRunning }
        isSyncing = true
        defer { isSyncing = false }

        try await prepare()
        try await sendAndCommit(beforeSend: beforeSend)
    }

    private func prepare() async throws {
        try await recoverStagedBatches()
        if !started {
            try await transport.start(state: store.loadEngineState())
            started = true
        }
    }

    private func fetchAndCommit(
        beforeApply: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        let fetched = try await transport.fetch(scope: .all)
        try await beforeApply()
        try await commit(.fetched(fetched))
    }

    private func sendAndCommit(
        beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void = { _ in }
    ) async throws {
        let outbound = try await store.pendingChanges()
        guard !outbound.operations.isEmpty || !outbound.zonesToSave.isEmpty else { return }
        try await beforeSend(outbound)
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
