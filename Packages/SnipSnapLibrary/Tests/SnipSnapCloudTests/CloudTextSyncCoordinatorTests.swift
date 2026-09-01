@testable import SnipSnapCloud
import XCTest

final class CloudTextSyncCoordinatorTests: XCTestCase {
    func testConcurrentSyncIsRejectedWhileTheFirstRunIsSuspended() async throws {
        let transport = BlockingCloudRecordTransport()
        let coordinator = CloudTextSyncCoordinator(
            store: TestCloudTextPersistence(),
            transport: transport
        )
        let first = Task { try await coordinator.sync() }
        await transport.waitUntilFetchStarts()

        do {
            try await coordinator.sync()
            XCTFail("Expected a second sync run to be rejected.")
        } catch CloudTransportError.syncAlreadyRunning {}

        await transport.releaseFetch()
        try await first.value
    }

    func testSentBatchReplaysUntilDurableApplyThenConfirms() async throws {
        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server)
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        let id = CloudRecordID(zone: zone, name: "accepted-once")
        let draft = CloudRecordDraft.text(
            id: id,
            snipID: UUID(uuidString: "abababab-abab-abab-abab-abababababab")!,
            text: "keep the receipt"
        )
        let store = TestCloudTextPersistence(
            pending: CloudOutboundBatch(operations: [.save(draft)])
        )
        let coordinator = CloudTextSyncCoordinator(store: store, transport: transport)
        await store.failNextSentApply()

        do {
            try await coordinator.sync()
            XCTFail("Expected the first durable sent-result apply to fail.")
        } catch TestStoreError.applyFailed {}

        try await coordinator.sync()

        let acceptedCount = await server.acceptedOperationCount(for: id)
        let sentAttempts = await store.sentApplyAttempts()
        let acceptedSent = await store.hasAcceptedSentResult()
        XCTAssertEqual(acceptedCount, 1)
        XCTAssertEqual(sentAttempts, 2)
        XCTAssertTrue(acceptedSent)
    }

    func testApplyFailureReplaysTheSameFetchedBatchOnRetry() async throws {
        let server = FakeCloudServer()
        let writer = FakeCloudRecordTransport(server: server)
        let reader = FakeCloudRecordTransport(server: server)
        let store = TestCloudTextPersistence()
        let coordinator = CloudTextSyncCoordinator(store: store, transport: reader)
        let id = CloudRecordID(
            zone: CloudZoneID(name: "metadata", ownerName: "owner"),
            name: "remote-record"
        )
        let draft = CloudRecordDraft.text(
            id: id,
            snipID: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            text: "must retry"
        )
        _ = try await writer.send(CloudOutboundBatch(operations: [.save(draft)]))
        await store.failNextApply()

        do {
            try await coordinator.sync()
            XCTFail("Expected the first durable apply to fail.")
        } catch TestStoreError.applyFailed {}

        try await coordinator.sync()

        let texts = await store.texts()
        let attempts = await store.applyAttempts()
        XCTAssertEqual(texts, ["must retry"])
        XCTAssertEqual(attempts, 2)
    }
}

private actor BlockingCloudRecordTransport: CloudRecordTransport {
    private var fetchStarted = false
    private var fetchContinuation: CheckedContinuation<Void, Never>?

    func start(state: CloudEngineStateEnvelope?) {}

    func fetch(scope: CloudFetchScope) async -> CloudFetchedBatch {
        fetchStarted = true
        await withCheckedContinuation { fetchContinuation = $0 }
        return CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
    }

    func send(_ batch: CloudOutboundBatch) -> CloudSentBatch {
        CloudSentBatch(id: UUID(), items: [], engineState: nil)
    }

    func confirmApplied(_ batchID: UUID) {}

    func fetchRecord(
        _ id: CloudRecordID,
        fields: Set<String>
    ) -> CloudRecordSnapshot? {
        nil
    }

    func fetchAsset(
        _ id: CloudRecordID,
        field: String,
        destination: CloudAssetDestination
    ) -> CloudAssetReceipt? {
        nil
    }

    func waitUntilFetchStarts() async {
        while !fetchStarted { await Task.yield() }
    }

    func releaseFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }
}

private enum TestStoreError: Error {
    case applyFailed
}

private actor TestCloudTextPersistence: CloudTextSyncPersistence {
    private var failApply = false
    private var failSentApply = false
    private var attempts = 0
    private var sentAttempts = 0
    private var acceptedSent = false
    private var records: [CloudRecordID: CloudTextRecord] = [:]
    private var pending: CloudOutboundBatch
    private var staged: [CloudSyncBatch] = []

    init(pending: CloudOutboundBatch = CloudOutboundBatch(operations: [])) {
        self.pending = pending
    }

    func failNextApply() {
        failApply = true
    }

    func failNextSentApply() {
        failSentApply = true
    }

    func loadEngineState() -> CloudEngineStateEnvelope? {
        nil
    }

    func stagedBatches() -> [CloudSyncBatch] {
        staged
    }

    func pendingChanges() -> CloudOutboundBatch {
        pending
    }

    func stage(_ batch: CloudSyncBatch) {
        staged.append(batch)
    }

    func applyStaged(_ id: UUID) throws {
        guard let index = staged.firstIndex(where: { $0.id == id }) else { return }
        let batch = staged[index]
        switch batch {
        case .fetched(let fetched):
            if !fetched.items.isEmpty { attempts += 1 }
            if failApply {
                failApply = false
                throw TestStoreError.applyFailed
            }
            for item in fetched.items {
                switch item {
                case .record(let snapshot):
                    let text = try CloudTextRecord(snapshot: snapshot)
                    records[text.id] = text
                case .deleted(let id):
                    records[id] = nil
                case .failed:
                    break
                }
            }
        case .sent:
            sentAttempts += 1
            if failSentApply {
                failSentApply = false
                throw TestStoreError.applyFailed
            }
            acceptedSent = true
            pending = CloudOutboundBatch(operations: [])
        }
        staged.remove(at: index)
    }

    func clear() {}

    func texts() -> [String] {
        records.values.map(\.text).sorted()
    }

    func applyAttempts() -> Int {
        attempts
    }

    func sentApplyAttempts() -> Int {
        sentAttempts
    }

    func hasAcceptedSentResult() -> Bool {
        acceptedSent
    }
}
