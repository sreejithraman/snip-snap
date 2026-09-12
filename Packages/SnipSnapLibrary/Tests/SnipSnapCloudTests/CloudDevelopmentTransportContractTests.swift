@_spi(Maintainer) @testable import SnipSnapCloud
import XCTest

final class CloudDevelopmentTransportContractTests: XCTestCase {
    func testConfirmationKeepsCheckpointOrderAndStopsAtItsBatch() async throws {
        let target = CloudSyncBatch.fetched(CloudFetchedBatch(id: UUID(), items: [], engineState: nil))
        let checkpoint = UUID()
        let later = UUID()
        let namespace = CloudSyncNamespace(cloudScope: "test", accountLineage: "account", generation: UUID(), zones: [])
        let transport = ContractEventTransport(events: [
            .checkpoint(checkpoint, CloudEngineStateEnvelope(namespace: namespace, serialization: Data())),
            .batch(CloudPendingBatch(batch: target, outbound: nil)),
            .accountChange(later)
        ])

        try await CloudDevelopmentTransportContract.confirm(target, transport: transport, validateAccount: {})

        let confirmed = await transport.confirmed
        let remaining = await transport.pendingEvent()
        XCTAssertEqual(confirmed, [checkpoint, target.id])
        XCTAssertEqual(remaining?.id, later)
    }

    func testConfirmationRejectsAnotherBatchWithoutAcknowledgingIt() async throws {
        let target = CloudSyncBatch.fetched(CloudFetchedBatch(id: UUID(), items: [], engineState: nil))
        let other = CloudSyncBatch.fetched(CloudFetchedBatch(id: UUID(), items: [], engineState: nil))
        let transport = ContractEventTransport(events: [.batch(CloudPendingBatch(batch: other, outbound: nil))])

        do {
            try await CloudDevelopmentTransportContract.confirm(target, transport: transport, validateAccount: {})
            XCTFail("Expected the unexpected batch to stop confirmation.")
        } catch {
            XCTAssertEqual(error as? CloudDevelopmentTransportContract.ContractError, .unexpectedBatch)
        }
        let confirmed = await transport.confirmed
        XCTAssertTrue(confirmed.isEmpty)
    }

    func testConfirmationValidatesAccountBeforeAcknowledgingItsEvent() async throws {
        for changed in [false, true] {
            let target = CloudSyncBatch.fetched(CloudFetchedBatch(id: UUID(), items: [], engineState: nil))
            let accountEvent = UUID()
            let transport = ContractEventTransport(events: [
                .accountChange(accountEvent), .batch(CloudPendingBatch(batch: target, outbound: nil))
            ])
            var validations = 0
            do {
                try await CloudDevelopmentTransportContract.confirm(target, transport: transport) {
                    validations += 1
                    if changed { throw CloudDevelopmentTransportContract.ContractError.accountChanged }
                }
                XCTAssertFalse(changed)
            } catch {
                XCTAssertTrue(changed)
                XCTAssertEqual(error as? CloudDevelopmentTransportContract.ContractError, .accountChanged)
            }
            let confirmed = await transport.confirmed
            XCTAssertEqual(validations, 1)
            XCTAssertEqual(confirmed, changed ? [] : [accountEvent, target.id])
        }
    }

    func testMatchingSaveAndFetchCannotHideLostText() async throws {
        let server = FakeCloudServer()
        let zone = CloudZoneID(name: "corrupt-text", ownerName: "owner")
        let draft = CloudRecordDraft.text(id: .random(in: zone), snipID: UUID(), text: "Keep this text")
        do {
            try await CloudDevelopmentTransportContract.exercise(
                transport: TextDroppingTransport(base: FakeCloudRecordTransport(server: server)),
                reader: FakeCloudRecordTransport(server: server), name: "corrupt", zone: zone, drafts: [draft]
            )
            XCTFail("Matching acknowledgements must not hide lost text.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("second client fetch"))
            XCTAssertTrue(error.localizedDescription.contains("savedRecordChanged"))
        }
    }

    func testNewZoneSupportsInitialFetchBeforeRecordWrites() async throws {
        let server = FakeCloudServer()
        let zone = CloudZoneID(name: "empty-contract-zone", ownerName: "owner")
        let transport = FakeCloudRecordTransport(server: server)
        let draft = CloudRecordDraft.text(id: .random(in: zone), snipID: UUID(), text: "contract")

        try await CloudDevelopmentTransportContract.exercise(
            transport: transport, reader: FakeCloudRecordTransport(server: server),
            name: "fake", zone: zone, drafts: [draft]
        )

        let exists = await server.hasZone(zone)
        XCTAssertTrue(exists)
        let remaining = await server.fullSnapshot(for: draft.id)
        XCTAssertNil(remaining)
    }

    func testSecondClientReceivesAttachmentBytesAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("payload")
        try Data([0, 1, 255, 128, 42]).write(to: source)
        let server = FakeCloudServer()
        let zone = CloudZoneID(name: "asset-contract-zone", ownerName: "owner")
        let draft = CloudRecordDraft(id: .random(in: zone), recordType: "AttachmentPayload",
            schemaVersion: 1, routingFields: ["schemaVersion": .int64(1)], encryptedFields: [:],
            assetFields: ["payload": CloudAssetUpload(fileURL: source)])

        try await CloudDevelopmentTransportContract.exercise(
            transport: FakeCloudRecordTransport(server: server),
            reader: FakeCloudRecordTransport(server: server),
            name: "fake", zone: zone, drafts: [draft]
        )

        let remaining = await server.fullSnapshot(for: draft.id)
        XCTAssertNil(remaining)
    }

    func testCleanupFailurePreservesTheOriginalFailure() async {
        do {
            try await CloudDevelopmentTransportContract.runWithCleanup(
                operation: { throw ProbeError.operation }, cleanup: { throw ProbeError.delete }
            )
            XCTFail("Both failures must be reported.")
        } catch {
            let failure = error as? CloudDevelopmentTransportContract.StepFailure
            XCTAssertTrue(failure?.detail.contains(ProbeError.operation.localizedDescription) == true)
            XCTAssertTrue(failure?.detail.contains(ProbeError.delete.localizedDescription) == true)
        }
    }

    func testOperationFailureStillRetriesAndConfirmsZoneCleanup() async throws {
        let probe = CleanupProbe(deleteFailures: 1, zoneExistsResults: [true, false])

        do {
            try await CloudDevelopmentTransportContract.runWithCleanup(
                operation: { throw ProbeError.operation },
                cleanup: {
                    try await CloudDevelopmentTransportContract.cleanupZone(
                        delete: { try await probe.deleteZone() },
                        zoneExists: { await probe.zoneExists() }
                    )
                }
            )
            XCTFail("Expected the operation error after cleanup.")
        } catch {
            XCTAssertEqual(error as? ProbeError, .operation)
        }

        let calls = await probe.calls()
        XCTAssertEqual(calls.delete, 2)
        XCTAssertEqual(calls.verify, 2)
    }

    func testUnconfirmedCleanupFailsTheContractAfterThreeAttempts() async {
        let probe = CleanupProbe(deleteFailures: 3, zoneExistsResults: [true, true, true])

        do {
            try await CloudDevelopmentTransportContract.runWithCleanup(
                operation: {},
                cleanup: {
                    try await CloudDevelopmentTransportContract.cleanupZone(
                        delete: { try await probe.deleteZone() },
                        zoneExists: { await probe.zoneExists() }
                    )
                }
            )
            XCTFail("Expected unconfirmed cleanup to fail the contract.")
        } catch {
            XCTAssertEqual(
                error as? CloudDevelopmentTransportContract.ContractError,
                .zoneCleanupWasNotConfirmed
            )
        }

        let calls = await probe.calls()
        XCTAssertEqual(calls.delete, 3)
        XCTAssertEqual(calls.verify, 3)
    }
}

private enum ProbeError: Error {
    case unused
    case operation
    case delete
}

private actor CleanupProbe {
    private var remainingDeleteFailures: Int
    private var remainingZoneExistsResults: [Bool]
    private var deleteCalls = 0
    private var verifyCalls = 0

    init(deleteFailures: Int, zoneExistsResults: [Bool]) {
        remainingDeleteFailures = deleteFailures
        remainingZoneExistsResults = zoneExistsResults
    }

    func deleteZone() throws {
        deleteCalls += 1
        if remainingDeleteFailures > 0 {
            remainingDeleteFailures -= 1
            throw ProbeError.delete
        }
    }

    func zoneExists() -> Bool {
        verifyCalls += 1
        return remainingZoneExistsResults.isEmpty
            ? true
            : remainingZoneExistsResults.removeFirst()
    }

    func calls() -> (delete: Int, verify: Int) {
        (deleteCalls, verifyCalls)
    }
}

private actor ContractEventTransport: CloudRecordTransport {
    private var events: [CloudRecordTransportEvent]
    private(set) var confirmed: [UUID] = []

    init(events: [CloudRecordTransportEvent]) { self.events = events }
    func pendingEvent() async -> CloudRecordTransportEvent? { events.first }
    func confirmApplied(_ id: UUID) throws {
        guard events.first?.id == id else { throw CloudTransportError.wrongBatchConfirmation }
        confirmed.append(id)
        events.removeFirst()
    }
    func start(state: CloudEngineStateEnvelope?) throws { throw ProbeError.unused }
    func fetch(scope: CloudFetchScope) throws -> CloudFetchedBatch { throw ProbeError.unused }
    func send(_ batch: CloudOutboundBatch) throws -> CloudSentBatch { throw ProbeError.unused }
    func fetchRecord(_ id: CloudRecordID, fields: Set<String>) throws -> CloudRecordSnapshot? {
        throw ProbeError.unused
    }
    func fetchAsset(_ id: CloudRecordID, field: String, destination: CloudAssetDestination) throws -> CloudAssetReceipt? {
        throw ProbeError.unused
    }
}

private struct TextDroppingTransport: CloudRecordTransport {
    let base: FakeCloudRecordTransport
    func start(state: CloudEngineStateEnvelope?) async throws { try await base.start(state: state) }
    func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch { try await base.fetch(scope: scope) }
    func confirmApplied(_ id: UUID) async throws { try await base.confirmApplied(id) }
    func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
        let operations = batch.operations.map { operation -> CloudOutboundOperation in
            guard case .save(let draft) = operation else { return operation }
            return .save(CloudRecordDraft(id: draft.id, recordType: draft.recordType,
                schemaVersion: draft.schemaVersion, routingFields: draft.routingFields,
                encryptedFields: [:], assetFields: draft.assetFields, base: draft.base))
        }
        return try await base.send(CloudOutboundBatch(operations: operations, zonesToSave: batch.zonesToSave))
    }
    func fetchRecord(_ id: CloudRecordID, fields: Set<String>) async throws -> CloudRecordSnapshot? {
        try await base.fetchRecord(id, fields: fields)
    }
    func fetchAsset(_ id: CloudRecordID, field: String, destination: CloudAssetDestination) async throws -> CloudAssetReceipt? {
        try await base.fetchAsset(id, field: field, destination: destination)
    }
}
