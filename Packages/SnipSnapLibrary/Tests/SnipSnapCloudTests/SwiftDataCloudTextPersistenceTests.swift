import SnipSnapCore
import SwiftData
@testable import SnipSnapCloud
@testable import SnipSnapPersistence
import XCTest

final class SwiftDataCloudTextPersistenceTests: XCTestCase {
    func testSuccessfulZoneEventsDoNotRequireAttentionButFailedEventsDo() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let fetched = CloudFetchedBatch(id: UUID(), items: [],
            databaseEvents: [.zoneChanged(zone)], zoneEvents: [.fetched(zone)], engineState: nil)
        try await bridge.stage(.fetched(fetched))
        try await bridge.applyStaged(fetched.id)
        let saved = CloudSentBatch(id: UUID(), items: [],
            databaseEvents: [.zoneSaved(zone)], engineState: nil)
        try await bridge.stage(.sent(saved))
        try await bridge.applyStaged(saved.id)
        let success = try await bridge.enrollmentEvidence()
        XCTAssertFalse(success.needsAttention)
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.recoveryEvents.count, 3)

        let failed = CloudFetchedBatch(id: UUID(), items: [],
            zoneEvents: [.failed(zone, .accessDenied)], engineState: nil)
        try await bridge.stage(.fetched(failed))
        try await bridge.applyStaged(failed.id)
        let failure = try await bridge.enrollmentEvidence()
        XCTAssertTrue(failure.needsAttention)
    }

    func testAlreadyStoredSuccessfulZoneEventsDoNotRequireAttention() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let events = try [
            SwiftDataCloudTextPersistence.RecoveryInput.zone(.fetched(zone)),
            .database(.zoneChanged(zone)), .database(.zoneSaved(zone))
        ].map { try SwiftDataCloudTextPersistence.recoveryEvent($0, batchID: UUID()) }
        let batch = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
        try await bridge.stage(.fetched(batch))
        let active = try XCTUnwrap(CloudNamespaceStateStorage.notEnrolled
            .committingFetch(.complete(remoteSnipIDs: [], localSnipIDs: []))
            .approvingSeed([], localSnipIDs: []))
        try await library.applyCloudTextFetched(namespaceKey: namespace.namespaceKey,
            mutations: [], recoveryEvents: events, engineState: nil,
            namespaceState: active, stagedBatchID: batch.id)

        let evidence = try await bridge.enrollmentEvidence()
        let status = try await bridge.statusEvidence()

        XCTAssertFalse(evidence.needsAttention)
        XCTAssertFalse(status.needsAttention)
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(Set(stored.recoveryEvents.map(\.payload)), Set(events.map(\.payload)))

        let malformedBatch = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
        try await bridge.stage(.fetched(malformedBatch))
        try await library.applyCloudTextFetched(namespaceKey: namespace.namespaceKey,
            mutations: [], recoveryEvents: [.init(key: "malformed", payload: Data())],
            engineState: nil, namespaceState: nil, stagedBatchID: malformedBatch.id)
        let malformed = try await bridge.statusEvidence()
        XCTAssertTrue(malformed.needsAttention)
    }

    func testStoredTextShadowKeepsOpaqueSystemFieldsTokenWhenPlanningEdit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snips.store")
        let library = try SwiftDataSnipLibrary(storeURL: storeURL)
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "accepted text",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        try await approveAllLocalSnips(bridge, library: library)
        guard case .save(let initialDraft) = try await bridge.pendingChanges().operations.first else {
            return XCTFail("Expected the initial save.")
        }
        let accepted = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: initialDraft)
        )
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)

        let token = Data("opaque stored CAS token".utf8)
        XCTAssertNotEqual(accepted.shadow.systemFields, token)
        let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
        let configuration = ModelConfiguration(
            "SnipSnapLocal",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let context = ModelContext(try ModelContainer(
            for: schema,
            migrationPlan: SnipSnapSchemaMigrationPlan.self,
            configurations: [configuration]
        ))
        let storedRecord = try XCTUnwrap(
            try context.fetch(FetchDescriptor<StoredCloudTextRecord>()).first
        )
        XCTAssertEqual(storedRecord.shadowData, accepted.shadow.data)
        storedRecord.systemFields = token
        try context.save()

        _ = try await library.perform(
            .update(
                id: snip.id,
                content: "edited text",
                attachmentURLs: nil,
                expectedUpdatedAt: nil,
                now: Date(timeIntervalSince1970: 200)
            ),
            sortedBy: .chronological
        )

        guard case .save(let edit) = try await bridge.pendingChanges().operations.first else {
            return XCTFail("Expected an edit save.")
        }
        XCTAssertEqual(edit.base?.data, accepted.shadow.data)
        XCTAssertEqual(edit.base?.systemFields, token)
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.records.first?.systemFields, token)
    }

    func testNamespaceRequiresRemoteFetchAndExplicitSeedApproval() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "local only until approved",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let snipID = try XCTUnwrap(added.snapshot.snips.first?.id)
        _ = try await library.perform(
            .add(
                content: "stay local",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )

        let beforeFetch = try await bridge.pendingChanges()
        XCTAssertTrue(beforeFetch.operations.isEmpty)
        do {
            try await bridge.approveSeeding(snipIDs: [snipID])
            XCTFail("Expected a remote fetch before approval.")
        } catch CloudNamespaceEnrollmentError.remoteFetchRequired {}

        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [snipID])
        let pending = try await bridge.pendingChanges()
        XCTAssertEqual(pending.operations.count, 1)
        guard case .save(let approvedDraft) = pending.operations.first else {
            return XCTFail("Expected one approved seed save.")
        }
        XCTAssertEqual(approvedDraft.routingFields["snipID"], .string(snipID.uuidString.lowercased()))
        _ = try await library.perform(
            .add(
                content: "created while seed is pending",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let accepted = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: approvedDraft)
        )
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)
        let afterSeed = try await bridge.pendingChanges()
        XCTAssertTrue(afterSeed.operations.isEmpty)

        _ = try await library.perform(
            .add(
                content: "created after enrollment",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let afterEnrollment = try await bridge.pendingChanges()
        XCTAssertEqual(afterEnrollment.operations.count, 1)
    }

    func testNewLineageAndGenerationDoNotInheritUploadEnrollment() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let firstNamespace = makeNamespace()
        let zone = try XCTUnwrap(firstNamespace.zones.first)
        let first = SwiftDataCloudTextPersistence(
            library: library,
            namespace: firstNamespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "belongs only to approved namespace",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let snipID = try XCTUnwrap(added.snapshot.snips.first?.id)
        try await markRemoteChecked(first)
        try await first.approveSeeding(snipIDs: [snipID])
        let firstPending = try await first.pendingChanges()
        XCTAssertEqual(firstPending.operations.count, 1)

        let otherLineageNamespace = CloudSyncNamespace(
            cloudScope: firstNamespace.cloudScope,
            accountLineage: "account-b",
            generation: firstNamespace.generation,
            zones: firstNamespace.zones
        )
        let otherGenerationNamespace = CloudSyncNamespace(
            cloudScope: firstNamespace.cloudScope,
            accountLineage: firstNamespace.accountLineage,
            generation: UUID(),
            zones: firstNamespace.zones
        )
        let otherLineage = SwiftDataCloudTextPersistence(
            library: library,
            namespace: otherLineageNamespace,
            textZone: zone
        )
        let otherGeneration = SwiftDataCloudTextPersistence(
            library: library,
            namespace: otherGenerationNamespace,
            textZone: zone
        )

        let lineagePending = try await otherLineage.pendingChanges()
        let generationPending = try await otherGeneration.pendingChanges()
        XCTAssertTrue(lineagePending.operations.isEmpty)
        XCTAssertTrue(generationPending.operations.isEmpty)
    }

    func testMissingZoneAllowsApprovedFirstSeedButBlocksKnownNamespace() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "approved seed",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let snipID = try XCTUnwrap(added.snapshot.snips.first?.id)
        let missing = CloudFetchedBatch(
            id: UUID(),
            items: [],
            zoneEvents: [.failed(zone, .zoneMissing)],
            engineState: nil
        )
        try await bridge.stage(.fetched(missing))
        try await bridge.applyStaged(missing.id)
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .remoteCheckedMissingZone)
        let beforeApproval = try await bridge.pendingChanges()
        XCTAssertTrue(beforeApproval.operations.isEmpty)

        try await bridge.approveSeeding(snipIDs: [snipID])
        let server = FakeCloudServer()
        let coordinator = CloudTextSyncCoordinator(
            store: bridge,
            transport: FakeCloudRecordTransport(server: server, namespace: namespace)
        )
        try await coordinator.sync()
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertEqual(stored.records.first?.acceptedText, "approved seed")

        let missingAgain = CloudFetchedBatch(
            id: UUID(),
            items: [],
            zoneEvents: [.failed(zone, .zoneMissing)],
            engineState: nil
        )
        try await bridge.stage(.fetched(missingAgain))
        try await bridge.applyStaged(missingAgain.id)
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .blocked)
        XCTAssertFalse(stored.recoveryEvents.isEmpty)
        let blockedPending = try await bridge.pendingChanges()
        XCTAssertTrue(blockedPending.operations.isEmpty)
    }

    func testEmptyApprovalCreatesMissingZoneBeforeActivation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let missing = CloudFetchedBatch(
            id: UUID(),
            items: [],
            zoneEvents: [.failed(zone, .zoneMissing)],
            engineState: nil
        )
        try await bridge.stage(.fetched(missing))
        try await bridge.applyStaged(missing.id)
        try await bridge.approveSeeding(snipIDs: [])

        var pending = try await bridge.pendingChanges()
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertTrue(pending.operations.isEmpty)
        XCTAssertEqual(pending.zonesToSave, [zone])

        let coordinator = CloudTextSyncCoordinator(
            store: bridge,
            transport: FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
        )
        try await coordinator.sync()
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertFalse(stored.namespaceState.zoneCreationPending)

        _ = try await library.perform(
            .add(
                content: "created after empty seed",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        pending = try await bridge.pendingChanges()
        XCTAssertEqual(pending.operations.count, 1)
    }

    func testDeletingLastMissingZoneSeedStillCreatesZoneBeforeActivation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "delete before zone create",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let snipID = try XCTUnwrap(added.snapshot.snips.first?.id)
        let missing = CloudFetchedBatch(
            id: UUID(),
            items: [],
            zoneEvents: [.failed(zone, .zoneMissing)],
            engineState: nil
        )
        try await bridge.stage(.fetched(missing))
        try await bridge.applyStaged(missing.id)
        try await bridge.approveSeeding(snipIDs: [snipID])
        _ = try await library.perform(.delete(ids: [snipID]), sortedBy: .chronological)

        let pending = try await bridge.pendingChanges()
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertTrue(stored.namespaceState.approvedSnipIDs.isEmpty)
        XCTAssertEqual(pending.zonesToSave, [zone])

        let coordinator = CloudTextSyncCoordinator(
            store: bridge,
            transport: FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
        )
        try await coordinator.sync()
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertFalse(stored.namespaceState.zoneCreationPending)
    }

    func testMissingZoneSendRetriesDuringSeedAndBlocksAfterActivation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "seed",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [snip.id])
        let missingFetchDuringSeed = CloudFetchedBatch(
            id: UUID(),
            items: [],
            zoneEvents: [.failed(zone, .zoneMissing)],
            engineState: nil
        )
        try await bridge.stage(.fetched(missingFetchDuringSeed))
        try await bridge.applyStaged(missingFetchDuringSeed.id)
        let pendingAfterMissingFetch = try await bridge.pendingChanges()
        XCTAssertEqual(pendingAfterMissingFetch.zonesToSave, [zone])
        guard case .save(let draft) = pendingAfterMissingFetch.operations.first else {
            return XCTFail("Expected an approved seed save.")
        }
        let missingDuringSeed = CloudSentBatch(
            id: UUID(),
            items: [.failed(draft.id, .zoneMissing)],
            engineState: nil
        )
        try await bridge.stage(.sent(missingDuringSeed))
        try await bridge.applyStaged(missingDuringSeed.id)
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        let retry = try await bridge.pendingChanges()
        XCTAssertEqual(retry.operations.count, 1)
        XCTAssertEqual(retry.zonesToSave, [zone])

        let accepted = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))
        let saved = CloudSentBatch(
            id: UUID(),
            items: [.saved(accepted)],
            databaseEvents: [.zoneSaved(zone)],
            engineState: nil
        )
        try await bridge.stage(.sent(saved))
        try await bridge.applyStaged(saved.id)
        _ = try await library.perform(
            .update(
                id: snip.id,
                content: "edited",
                attachmentURLs: nil,
                expectedUpdatedAt: nil,
                now: Date(timeIntervalSince1970: 200)
            ),
            sortedBy: .chronological
        )
        let missingAfterActivation = CloudSentBatch(
            id: UUID(),
            items: [.failed(draft.id, .zoneMissing)],
            zoneEvents: [.failed(zone, .zoneMissing)],
            engineState: nil
        )
        try await bridge.stage(.sent(missingAfterActivation))
        try await bridge.applyStaged(missingAfterActivation.id)
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let blocked = try await bridge.pendingChanges()
        XCTAssertEqual(stored.namespaceState.phase, .blocked)
        XCTAssertTrue(blocked.operations.isEmpty)
    }

    func testItemOnlyMissingZoneAfterCleanFetchArmsZoneCreation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "zone disappears before send",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let snipID = try XCTUnwrap(added.snapshot.snips.first?.id)
        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [snipID])
        let firstPending = try await bridge.pendingChanges()
        XCTAssertTrue(firstPending.zonesToSave.isEmpty)
        guard let recordID = firstPending.operations.first?.id else {
            return XCTFail("Expected the approved seed.")
        }

        let missing = CloudSentBatch(
            id: UUID(),
            items: [.failed(recordID, .zoneMissing)],
            engineState: nil
        )
        try await bridge.stage(.sent(missing))
        try await bridge.applyStaged(missing.id)

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let retry = try await bridge.pendingChanges()
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertTrue(stored.namespaceState.zoneCreationPending)
        XCTAssertEqual(retry.zonesToSave, [zone])
        XCTAssertEqual(retry.operations.count, 1)
    }

    func testFailedFirstFetchCannotUnlockSeedApproval() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "must not upload",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let snipID = try XCTUnwrap(added.snapshot.snips.first?.id)
        let failed = CloudFetchedBatch(
            id: UUID(),
            items: [],
            databaseEvents: [.failed(nil, .retryable)],
            engineState: nil
        )
        try await bridge.stage(.fetched(failed))
        try await bridge.applyStaged(failed.id)

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .notEnrolled)
        do {
            try await bridge.approveSeeding(snipIDs: [snipID])
            XCTFail("Expected a successful remote check before approval.")
        } catch CloudNamespaceEnrollmentError.remoteFetchRequired {}
        let pending = try await bridge.pendingChanges()
        XCTAssertTrue(pending.operations.isEmpty)
    }

    func testRemoteArrivalDoesNotCancelApprovedSeedMembership() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "approved local",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let approvedID = try XCTUnwrap(added.snapshot.snips.first?.id)
        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [approvedID])
        let remote = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(
                for: .text(id: .random(in: zone), snipID: UUID(), text: "remote arrival")
            )
        )
        let fetched = CloudFetchedBatch(id: UUID(), items: [.record(remote)], engineState: nil)
        try await bridge.stage(.fetched(fetched))
        try await bridge.applyStaged(fetched.id)

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let pending = try await bridge.pendingChanges()
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [approvedID])
        XCTAssertEqual(pending.operations.count, 1)
        guard case .save(let draft) = pending.operations.first else {
            return XCTFail("Expected the approved local seed.")
        }
        XCTAssertEqual(draft.routingFields["snipID"], .string(approvedID.uuidString.lowercased()))
    }

    func testDeletingTheLastApprovedSeedFinishesEnrollmentWithoutUploadingIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "delete before send",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let snipID = try XCTUnwrap(added.snapshot.snips.first?.id)
        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [snipID])
        _ = try await library.perform(.delete(ids: [snipID]), sortedBy: .chronological)

        let pending = try await bridge.pendingChanges()
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(pending.operations.isEmpty)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertTrue(stored.namespaceState.approvedSnipIDs.isEmpty)

        _ = try await library.perform(
            .add(
                content: "after enrollment",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let afterEnrollment = try await bridge.pendingChanges()
        XCTAssertEqual(afterEnrollment.operations.count, 1)
        XCTAssertTrue(stored.records.isEmpty)
    }

    func testTerminalSeedFailureFinishesEnrollmentWithDurableRecovery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "rejected seed",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let snipID = try XCTUnwrap(added.snapshot.snips.first?.id)
        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [snipID])
        guard let recordID = try await bridge.pendingChanges().operations.first?.id else {
            return XCTFail("Expected one approved seed.")
        }
        let rejected = CloudSentBatch(
            id: UUID(),
            items: [.failed(recordID, .rejected)],
            engineState: nil
        )
        try await bridge.stage(.sent(rejected))
        try await bridge.applyStaged(rejected.id)

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let pending = try await bridge.pendingChanges()
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertNotNil(stored.records.first?.recoveryData)
        XCTAssertTrue(pending.operations.isEmpty)
    }

    func testWrongZoneAndChangedIdentityBindingBecomeRecoveryInputs() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let wrongZone = CloudZoneID(name: "payload", ownerName: zone.ownerName)
        let wrong = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(
                for: .text(id: .random(in: wrongZone), snipID: UUID(), text: "wrong zone")
            )
        )
        let wrongBatch = CloudFetchedBatch(id: UUID(), items: [.record(wrong)], engineState: nil)
        try await bridge.stage(.fetched(wrongBatch))
        try await bridge.applyStaged(wrongBatch.id)
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .notEnrolled)
        XCTAssertTrue(stored.records.isEmpty)
        XCTAssertEqual(stored.recoveryEvents.count, 1)

        let originalSnipID = UUID()
        let recordID = CloudRecordID.random(in: zone)
        let original = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(
                for: .text(id: recordID, snipID: originalSnipID, text: "original")
            )
        )
        let originalBatch = CloudFetchedBatch(
            id: UUID(),
            items: [.record(original)],
            engineState: nil
        )
        try await bridge.stage(.fetched(originalBatch))
        try await bridge.applyStaged(originalBatch.id)
        let changedBinding = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(
                for: .text(
                    id: recordID,
                    snipID: UUID(),
                    text: "changed binding",
                    base: original.shadow
                )
            )
        )
        let changedBatch = CloudFetchedBatch(
            id: UUID(),
            items: [.record(changedBinding)],
            engineState: nil
        )
        try await bridge.stage(.fetched(changedBatch))
        try await bridge.applyStaged(changedBatch.id)
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let local = await library.snapshot(sortedBy: .chronological)
        XCTAssertEqual(stored.records.first?.snipID, originalSnipID)
        XCTAssertEqual(local.snips.first?.id, originalSnipID)
        XCTAssertEqual(local.snips.first?.content, "original")
        XCTAssertEqual(stored.recoveryEvents.count, 2)
    }

    func testTextJournalStagesAssetSnapshotAsARecoveryItemWithoutPersistingItsURL() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("asset.bin")
        try Data([1, 2, 3]).write(to: sourceURL)
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let draft = CloudRecordDraft(
            id: .random(in: zone),
            recordType: "Payload",
            schemaVersion: 1,
            routingFields: ["schemaVersion": .int64(1)],
            encryptedFields: [:],
            assetFields: ["blob": CloudAssetUpload(fileURL: sourceURL)]
        )
        let snapshot = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: draft)
        )
        let batch = CloudFetchedBatch(id: UUID(), items: [.record(snapshot)], engineState: nil)

        try await bridge.stage(.fetched(batch))
        try await bridge.applyStaged(batch.id)

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(stored.stagedBatches.isEmpty)
        XCTAssertEqual(stored.recoveryEvents.count, 1)
        XCTAssertFalse(stored.recoveryEvents[0].payload.contains(Data(sourceURL.path.utf8)))
    }

    func testSentApplyFailureReplaysFromDurableStageAfterRelaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snips.store")
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let initialLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
        _ = try await initialLibrary.perform(
            .add(
                content: "accepted once",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )
        let enrollmentStore = SwiftDataCloudTextPersistence(
            library: initialLibrary,
            namespace: namespace,
            textZone: zone
        )
        try await approveAllLocalSnips(enrollmentStore, library: initialLibrary)

        let gate = CloudApplyFailureGate(failOnCall: 3)
        let failingLibrary = try SwiftDataSnipLibrary(
            storeURL: storeURL,
            afterMutationBeforeSave: { try gate.call() }
        )
        let server = FakeCloudServer()
        let firstStore = SwiftDataCloudTextPersistence(
            library: failingLibrary,
            namespace: namespace,
            textZone: zone
        )
        let firstCoordinator = CloudTextSyncCoordinator(
            store: firstStore,
            transport: FakeCloudRecordTransport(server: server)
        )
        do {
            try await firstCoordinator.sync()
            XCTFail("Expected sent-result commit to fail.")
        } catch CloudApplyFailureGate.Failure.injected {}

        let staged = try await failingLibrary.cloudTextSyncSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertEqual(staged.stagedBatches.count, 1)

        let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
        let reopenedStore = SwiftDataCloudTextPersistence(
            library: reopenedLibrary,
            namespace: namespace,
            textZone: zone
        )
        let reopenedCoordinator = CloudTextSyncCoordinator(
            store: reopenedStore,
            transport: FakeCloudRecordTransport(server: server)
        )
        try await reopenedCoordinator.sync()

        let recovered = try await reopenedLibrary.cloudTextSyncSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let recordID = try XCTUnwrap(recovered.records.first).identity
        let cloudID = CloudRecordID(
            zone: CloudZoneID(name: recordID.zoneName, ownerName: recordID.ownerName),
            name: recordID.recordName
        )
        let acceptedCount = await server.acceptedOperationCount(for: cloudID)
        XCTAssertTrue(recovered.stagedBatches.isEmpty)
        XCTAssertEqual(recovered.records.first?.acceptedText, "accepted once")
        XCTAssertEqual(acceptedCount, 1)
    }

    func testPartialSentOutcomesAndZoneEventsRemainDurable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        for text in ["succeeds", "needs recovery"] {
            _ = try await library.perform(
                .add(
                    content: text,
                    origin: .quickEntry,
                    source: nil,
                    listID: SnipList.inboxID,
                    attachmentURLs: [],
                    requestID: UUID(),
                    now: Date()
                ),
                sortedBy: .chronological
            )
        }
        try await approveAllLocalSnips(bridge, library: library)
        let outbound = try await bridge.pendingChanges()
        guard outbound.operations.count == 2,
              case .save(let first) = outbound.operations[0],
              case .save(let second) = outbound.operations[1]
        else {
            return XCTFail("Expected two local saves.")
        }
        let saved = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: first))
        let sent = CloudSentBatch(
            id: UUID(),
            items: [.saved(saved), .failed(second.id, .retryable)],
            databaseEvents: [.zoneChanged(zone)],
            zoneEvents: [.fetched(zone)],
            engineState: nil
        )
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)

        let snapshot = try await library.cloudTextSyncSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let savedText = try CloudTextRecord(snapshot: saved).text
        let savedRecord = snapshot.records.first { $0.identity.recordName == first.id.name }
        let failedRecord = snapshot.records.first { $0.identity.recordName == second.id.name }
        XCTAssertEqual(savedRecord?.acceptedText, savedText)
        XCTAssertNil(savedRecord?.recoveryData)
        XCTAssertNotNil(failedRecord?.recoveryData)
        XCTAssertEqual(snapshot.recoveryEvents.count, 2)
        XCTAssertTrue(snapshot.stagedBatches.isEmpty)
        let retry = try await bridge.pendingChanges()
        XCTAssertEqual(retry.operations.map(\.id), [second.id])
    }

    func testZonePurgeBlocksPendingLocalSends() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        _ = try await library.perform(
            .add(
                content: "must wait for recovery",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        try await approveAllLocalSnips(bridge, library: library)
        let batch = CloudFetchedBatch(
            id: UUID(),
            items: [],
            databaseEvents: [.zoneDeleted(zone, reason: .purged)],
            engineState: nil
        )

        try await bridge.stage(.fetched(batch))
        try await bridge.applyStaged(batch.id)

        let pending = try await bridge.pendingChanges()
        XCTAssertTrue(pending.operations.isEmpty)
    }

    func testMalformedAndValidFetchedItemsCommitIndependently() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let valid = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(
                for: .text(id: .random(in: zone), snipID: UUID(), text: "valid")
            )
        )
        let malformedDraft = CloudRecordDraft(
            id: .random(in: zone),
            recordType: "Snip",
            schemaVersion: 1,
            routingFields: ["schemaVersion": .int64(1)],
            encryptedFields: ["text": .string("missing snip id")]
        )
        let malformed = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: malformedDraft)
        )
        let envelope = CloudEngineStateEnvelope(namespace: namespace, serialization: Data([7]))
        let batch = CloudFetchedBatch(
            id: UUID(),
            items: [.record(valid), .record(malformed)],
            engineState: envelope
        )

        try await bridge.stage(.fetched(batch))
        try await bridge.applyStaged(batch.id)

        let local = await library.snapshot(sortedBy: .chronological)
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(local.snips.map(\.content), ["valid"])
        XCTAssertEqual(local.snips.first?.origin, .quickEntry)
        XCTAssertEqual(local.snips.first?.listID, SnipList.inboxID)
        let committedEnvelope = try await bridge.loadEngineState()
        XCTAssertEqual(committedEnvelope, envelope)
        XCTAssertEqual(stored.recoveryEvents.count, 1)
        XCTAssertTrue(stored.stagedBatches.isEmpty)
    }

    func testDuplicateFetchedSnipIDKeepsOneRecordAndStagesRecoveryForTheOther() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let snipID = UUID()
        let first = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(
                for: .text(id: .random(in: zone), snipID: snipID, text: "first")
            )
        )
        let second = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(
                for: .text(id: .random(in: zone), snipID: snipID, text: "second")
            )
        )
        let batch = CloudFetchedBatch(
            id: UUID(),
            items: [.record(first), .record(second)],
            engineState: nil
        )

        try await bridge.stage(.fetched(batch))
        try await bridge.applyStaged(batch.id)

        let local = await library.snapshot(sortedBy: .chronological)
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(local.snips.map(\.content), ["first"])
        XCTAssertEqual(stored.records.count, 1)
        XCTAssertEqual(stored.recoveryEvents.count, 1)
        XCTAssertTrue(stored.stagedBatches.isEmpty)
    }

    func testRepeatedFetchedIdentityAppliesOnlyTheLatestValue() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let id = CloudRecordID.random(in: zone)
        let snipID = UUID()
        let first = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: .text(id: id, snipID: snipID, text: "first"))
        )
        let second = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(
                for: .text(id: id, snipID: snipID, text: "second", base: first.shadow)
            )
        )
        let batch = CloudFetchedBatch(
            id: UUID(),
            items: [.record(first), .record(second)],
            engineState: nil
        )

        try await bridge.stage(.fetched(batch))
        try await bridge.applyStaged(batch.id)

        let local = await library.snapshot(sortedBy: .chronological)
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(local.snips.map(\.content), ["second"])
        XCTAssertEqual(stored.records.first?.acceptedText, "second")
        XCTAssertNil(stored.records.first?.recoveryData)
    }

    func testMalformedSuccessfulSendReceiptBlocksAnAutomaticResend() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        _ = try await library.perform(
            .add(
                content: "accepted but malformed",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        try await approveAllLocalSnips(bridge, library: library)
        guard case .save(let draft) = try await bridge.pendingChanges().operations.first else {
            return XCTFail("Expected one local save.")
        }
        let malformed = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(
                for: CloudRecordDraft(
                    id: draft.id,
                    recordType: "Snip",
                    schemaVersion: 1,
                    routingFields: ["schemaVersion": .int64(1)],
                    encryptedFields: ["text": .string("accepted but malformed")]
                )
            )
        )
        let sent = CloudSentBatch(id: UUID(), items: [.saved(malformed)], engineState: nil)

        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let pending = try await bridge.pendingChanges()
        XCTAssertNotNil(stored.records.first?.recoveryData)
        XCTAssertTrue(pending.operations.isEmpty)
    }

    func testFetchedSnipsReceiveDistinctManualPositions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let snapshots = try ["first", "second"].map { text in
            try CloudKitRecordMapper.snapshot(
                CloudKitRecordMapper.record(
                    for: .text(id: .random(in: zone), snipID: UUID(), text: text)
                )
            )
        }
        let batch = CloudFetchedBatch(
            id: UUID(),
            items: snapshots.map(CloudFetchItemResult.record),
            engineState: nil
        )

        try await bridge.stage(.fetched(batch))
        try await bridge.applyStaged(batch.id)

        let local = await library.snapshot(sortedBy: .manual)
        XCTAssertEqual(Set(local.snips.map(\.manualPosition)).count, 2)
    }

    func testLocallyDeletedUnsyncedRecordIsRemovedWithoutACloudDelete() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "never sent",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let snipID = try XCTUnwrap(added.snapshot.snips.first?.id)
        try await approveAllLocalSnips(bridge, library: library)
        let reserved = try await bridge.pendingChanges()
        XCTAssertEqual(reserved.operations.count, 1)
        _ = try await library.perform(.delete(ids: [snipID]), sortedBy: .chronological)

        let pending = try await bridge.pendingChanges()
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(pending.operations.isEmpty)
        XCTAssertTrue(stored.records.isEmpty)
    }

    func testSentConflictAndUnknownItemDoNotLoopAutomatically() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        for text in ["local conflict", "local unknown"] {
            _ = try await library.perform(
                .add(
                    content: text,
                    origin: .quickEntry,
                    source: nil,
                    listID: SnipList.inboxID,
                    attachmentURLs: [],
                    requestID: UUID(),
                    now: Date()
                ),
                sortedBy: .chronological
            )
        }
        try await approveAllLocalSnips(bridge, library: library)
        let outbound = try await bridge.pendingChanges()
        guard outbound.operations.count == 2,
              case .save(let conflictDraft) = outbound.operations[0],
              case .string(let snipIDValue)? = conflictDraft.routingFields["snipID"],
              let snipID = UUID(uuidString: snipIDValue)
        else {
            return XCTFail("Expected two local saves.")
        }
        let serverDraft = CloudRecordDraft.text(
            id: conflictDraft.id,
            snipID: snipID,
            text: "server text"
        )
        let server = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: serverDraft)
        )
        let unknownID = outbound.operations[1].id
        let sent = CloudSentBatch(
            id: UUID(),
            items: [
                .conflict(conflictDraft.id, server: server),
                .unknownItem(unknownID),
            ],
            engineState: nil
        )
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)

        let snapshot = try await library.cloudTextSyncSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let pending = try await bridge.pendingChanges()
        XCTAssertEqual(snapshot.records.filter { $0.recoveryData != nil }.count, 2)
        XCTAssertEqual(
            snapshot.records.first { $0.identity.recordName == conflictDraft.id.name }?.acceptedText,
            "server text"
        )
        XCTAssertTrue(pending.operations.isEmpty)
    }

    func testRemoteEditKeepsDirtyLocalTextAndCreatesRecoveryInput() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "base",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        try await approveAllLocalSnips(bridge, library: library)
        guard case .save(let firstDraft) = try await bridge.pendingChanges().operations.first else {
            return XCTFail("Expected the initial save.")
        }
        let accepted = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: firstDraft)
        )
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)

        _ = try await library.perform(
            .update(
                id: snip.id,
                content: "local unsent",
                attachmentURLs: nil,
                expectedUpdatedAt: nil,
                now: Date(timeIntervalSince1970: 200)
            ),
            sortedBy: .chronological
        )
        let remoteDraft = CloudRecordDraft.text(
            id: firstDraft.id,
            snipID: snip.id,
            text: "remote",
            base: accepted.shadow
        )
        let remote = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: remoteDraft)
        )
        let fetched = CloudFetchedBatch(id: UUID(), items: [.record(remote)], engineState: nil)
        try await bridge.stage(.fetched(fetched))
        try await bridge.applyStaged(fetched.id)

        let local = await library.snapshot(sortedBy: .chronological)
        let cloud = try await library.cloudTextSyncSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let pending = try await bridge.pendingChanges()
        XCTAssertEqual(local.snips.map(\.content), ["local unsent"])
        XCTAssertEqual(cloud.records.first?.acceptedText, "remote")
        XCTAssertNotNil(cloud.records.first?.recoveryData)
        XCTAssertTrue(pending.operations.isEmpty)
    }

    func testRemoteDeleteKeepsDirtyLocalTextAndCreatesRecoveryInput() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "base",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        try await approveAllLocalSnips(bridge, library: library)
        guard case .save(let draft) = try await bridge.pendingChanges().operations.first else {
            return XCTFail("Expected the initial save.")
        }
        let accepted = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)
        _ = try await library.perform(
            .update(
                id: snip.id,
                content: "keep local",
                attachmentURLs: nil,
                expectedUpdatedAt: nil,
                now: Date(timeIntervalSince1970: 200)
            ),
            sortedBy: .chronological
        )

        let fetched = CloudFetchedBatch(
            id: UUID(),
            items: [.deleted(draft.id)],
            engineState: nil
        )
        try await bridge.stage(.fetched(fetched))
        try await bridge.applyStaged(fetched.id)

        let local = await library.snapshot(sortedBy: .chronological)
        let cloud = try await library.cloudTextSyncSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertEqual(local.snips.map(\.content), ["keep local"])
        XCTAssertNil(cloud.records.first?.acceptedText)
        XCTAssertNil(cloud.records.first?.shadowData)
        XCTAssertNotNil(cloud.records.first?.recoveryData)
    }

    func testRemoteEditDoesNotRecreateALocallyDeletedSnip() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "base",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        try await approveAllLocalSnips(bridge, library: library)
        guard case .save(let draft) = try await bridge.pendingChanges().operations.first else {
            return XCTFail("Expected the initial save.")
        }
        let accepted = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)
        _ = try await library.perform(.delete(ids: [snip.id]), sortedBy: .chronological)
        let remote = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(
                for: .text(
                    id: draft.id,
                    snipID: snip.id,
                    text: "remote edit",
                    base: accepted.shadow
                )
            )
        )
        let fetched = CloudFetchedBatch(id: UUID(), items: [.record(remote)], engineState: nil)

        try await bridge.stage(.fetched(fetched))
        try await bridge.applyStaged(fetched.id)

        let local = await library.snapshot(sortedBy: .chronological)
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(local.snips.isEmpty)
        XCTAssertEqual(stored.records.first?.acceptedText, "remote edit")
        XCTAssertNotNil(stored.records.first?.recoveryData)
        let pending = try await bridge.pendingChanges()
        XCTAssertTrue(pending.operations.isEmpty)
    }

    func testCleanRemoteDeleteRemovesOrphanAttachmentFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.txt")
        try Data("body".utf8).write(to: sourceURL)
        let library = try SwiftDataSnipLibrary(
            storeURL: directory.appendingPathComponent("snips.store")
        )
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: zone
        )
        let added = try await library.perform(
            .add(
                content: "with file",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [sourceURL],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )
        let attachment = try XCTUnwrap(added.snapshot.snips.first?.attachments.first)
        let storedURL = try XCTUnwrap(added.snapshot.attachmentURLs[attachment.id])
        try await approveAllLocalSnips(bridge, library: library)
        guard case .save(let draft) = try await bridge.pendingChanges().operations.first else {
            return XCTFail("Expected the initial save.")
        }
        let accepted = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)
        let fetched = CloudFetchedBatch(
            id: UUID(),
            items: [.deleted(draft.id)],
            engineState: nil
        )

        try await bridge.stage(.fetched(fetched))
        try await bridge.applyStaged(fetched.id)

        let local = await library.snapshot(sortedBy: .chronological)
        XCTAssertTrue(local.snips.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    }

    func testFetchedTextShadowAndEngineStateCommitTogetherOrNotAtAll() async throws {
        enum InjectedFailure: Error { case save }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snips.store")
        _ = try SwiftDataSnipLibrary(storeURL: storeURL)
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let snipID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let draft = CloudRecordDraft.text(
            id: .random(in: zone),
            snipID: snipID,
            text: "atomic remote text"
        )
        let remote = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: draft)
        )
        let envelope = CloudEngineStateEnvelope(
            namespace: namespace,
            serialization: Data([0x01, 0x02])
        )
        let batch = CloudFetchedBatch(
            id: UUID(),
            items: [.record(remote)],
            engineState: envelope
        )
        let failingLibrary = try SwiftDataSnipLibrary(
            storeURL: storeURL,
            afterMutationBeforeSave: { throw InjectedFailure.save }
        )
        let failingBridge = SwiftDataCloudTextPersistence(
            library: failingLibrary,
            namespace: namespace,
            textZone: zone
        )

        try await failingBridge.stage(.fetched(batch))
        do {
            try await failingBridge.applyStaged(batch.id)
            XCTFail("Expected the injected transaction failure.")
        } catch is InjectedFailure {}

        let afterFailure = await failingLibrary.snapshot(sortedBy: .chronological)
        let failedState = try await failingBridge.loadEngineState()
        XCTAssertTrue(afterFailure.snips.isEmpty)
        XCTAssertNil(failedState)

        let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
        let bridge = SwiftDataCloudTextPersistence(
            library: reopened,
            namespace: namespace,
            textZone: zone
        )
        try await bridge.applyStaged(batch.id)

        let committed = await reopened.snapshot(sortedBy: .chronological)
        let committedState = try await bridge.loadEngineState()
        XCTAssertEqual(committed.snips.map(\.content), ["atomic remote text"])
        XCTAssertEqual(committedState, envelope)

        try await reopened.clearCloudTextSyncState(namespaceKey: namespace.namespaceKey)
        let clearedState = try await bridge.loadEngineState()
        XCTAssertNil(clearedState)
        let afterClear = await reopened.snapshot(sortedBy: .chronological)
        XCTAssertEqual(afterClear.snips.map(\.content), ["atomic remote text"])
    }

    func testRecordIdentityAndShadowSurviveStoreReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snips.store")
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let firstLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
        let added = try await firstLibrary.perform(
            .add(
                content: "before",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        let firstBridge = SwiftDataCloudTextPersistence(
            library: firstLibrary,
            namespace: namespace,
            textZone: zone
        )
        try await approveAllLocalSnips(firstBridge, library: firstLibrary)
        let pending = try await firstBridge.pendingChanges()
        guard case .save(let firstDraft) = pending.operations.first else {
            return XCTFail("Expected one new text save.")
        }
        let accepted = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: firstDraft)
        )
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await firstBridge.stage(.sent(sent))
        try await firstBridge.applyStaged(sent.id)

        let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
        _ = try await reopenedLibrary.perform(
            .update(
                id: snip.id,
                content: "after reopen",
                attachmentURLs: nil,
                expectedUpdatedAt: nil,
                now: Date(timeIntervalSince1970: 200)
            ),
            sortedBy: .chronological
        )
        let reopenedBridge = SwiftDataCloudTextPersistence(
            library: reopenedLibrary,
            namespace: namespace,
            textZone: zone
        )

        let reopenedPending = try await reopenedBridge.pendingChanges()

        guard case .save(let reopenedDraft) = reopenedPending.operations.first else {
            return XCTFail("Expected one edited text save.")
        }
        XCTAssertEqual(reopenedDraft.id, firstDraft.id)
        XCTAssertEqual(reopenedDraft.base, accepted.shadow)
        XCTAssertEqual(reopenedDraft.encryptedFields["text"], .string("after reopen"))
    }

    func testTwoDurableClientsExchangeTextThroughTheFake() async throws {
        let firstDirectory = temporaryDirectory()
        let secondDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let firstLibrary = try SwiftDataSnipLibrary(
            storeURL: firstDirectory.appendingPathComponent("snips.store")
        )
        let secondLibrary = try SwiftDataSnipLibrary(
            storeURL: secondDirectory.appendingPathComponent("snips.store")
        )
        let firstStore = SwiftDataCloudTextPersistence(
            library: firstLibrary,
            namespace: namespace,
            textZone: zone
        )
        let secondStore = SwiftDataCloudTextPersistence(
            library: secondLibrary,
            namespace: namespace,
            textZone: zone
        )
        let server = FakeCloudServer()
        let first = CloudTextSyncCoordinator(
            store: firstStore,
            transport: FakeCloudRecordTransport(server: server)
        )
        let second = CloudTextSyncCoordinator(
            store: secondStore,
            transport: FakeCloudRecordTransport(server: server)
        )
        _ = try await firstLibrary.perform(
            .add(
                content: "from Mac",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 100)
            ),
            sortedBy: .chronological
        )
        try await approveAllLocalSnips(firstStore, library: firstLibrary)

        try await first.sync()
        try await second.sync()
        let onSecond = await secondLibrary.snapshot(sortedBy: .chronological)
        XCTAssertEqual(onSecond.snips.map(\.content), ["from Mac"])

        let secondSnip = try XCTUnwrap(onSecond.snips.first)
        _ = try await secondLibrary.perform(
            .update(
                id: secondSnip.id,
                content: "from iPhone",
                attachmentURLs: nil,
                expectedUpdatedAt: secondSnip.updatedAt,
                now: Date(timeIntervalSince1970: 200)
            ),
            sortedBy: .chronological
        )
        try await second.sync()
        try await first.sync()

        let finalFirst = await firstLibrary.snapshot(sortedBy: .chronological)
        let finalSecond = await secondLibrary.snapshot(sortedBy: .chronological)
        XCTAssertEqual(finalFirst.snips.map(\.content), ["from iPhone"])
        XCTAssertEqual(finalSecond.snips.map(\.content), ["from iPhone"])
    }

    func testModeMergeRequiresARemoteCheckAndSeedsAMissingZoneAcrossReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snips.store")
        let library = try SwiftDataSnipLibrary(storeURL: storeURL)
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let approved = try await addSnip("approved by the merge", to: library)
        let excluded = try await addSnip("left local", to: library)

        do {
            try await bridge.approveModeMerge(snipIDs: [approved])
            XCTFail("Expected a remote fetch before a mode merge.")
        } catch CloudNamespaceEnrollmentError.remoteFetchRequired {}
        let missing = CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.failed(zone, .zoneMissing)],
            engineState: nil)
        try await bridge.stage(.fetched(missing))
        try await bridge.applyStaged(missing.id)
        try await bridge.approveModeMerge(snipIDs: [approved])

        let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
        let reopened = SwiftDataCloudTextPersistence(
            library: reopenedLibrary, namespace: namespace, textZone: zone
        )
        let stored = try await reopenedLibrary.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [approved])
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [excluded])
        XCTAssertTrue(stored.namespaceState.zoneCreationPending)
        let pending = try await reopened.pendingChanges()
        XCTAssertEqual(pending.operations.count, 1)
        XCTAssertEqual(pending.zonesToSave, [zone])
    }

    // SM27-H2: a seeding mode merge must keep the zone creation a missing zone still needs.
    func testSeedingModeMergeKeepsPendingZoneCreationUntilTheZoneIsSaved() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snips.store")
        let library = try SwiftDataSnipLibrary(storeURL: storeURL)
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let first = try await addSnip("first approval", to: library)
        let second = try await addSnip("second approval", to: library)
        let missing = CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.failed(zone, .zoneMissing)],
            engineState: nil)
        try await bridge.stage(.fetched(missing))
        try await bridge.applyStaged(missing.id)
        try await bridge.approveSeeding(snipIDs: [first])

        try await bridge.approveModeMerge(snipIDs: [second])
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [second])
        // The merge excludes the approval it drops, because it never reached iCloud.
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [first])
        XCTAssertTrue(stored.namespaceState.zoneCreationPending)
        try await bridge.approveModeMerge(snipIDs: [second])
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [second])
        XCTAssertTrue(stored.namespaceState.zoneCreationPending)

        // Like seed pruning, an empty approval cannot finish seeding before the zone exists.
        try await bridge.approveModeMerge(snipIDs: [])
        let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
        let reopened = SwiftDataCloudTextPersistence(
            library: reopenedLibrary, namespace: namespace, textZone: zone
        )
        stored = try await reopenedLibrary.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertTrue(stored.namespaceState.approvedSnipIDs.isEmpty)
        XCTAssertTrue(stored.namespaceState.zoneCreationPending)
        let pending = try await reopened.pendingChanges()
        XCTAssertEqual(pending, CloudOutboundBatch(operations: [], zonesToSave: [zone]))

        let zoneSaved = CloudSentBatch(id: UUID(), items: [], databaseEvents: [.zoneSaved(zone)],
            engineState: nil)
        try await reopened.stage(.sent(zoneSaved))
        try await reopened.applyStaged(zoneSaved.id)
        stored = try await reopenedLibrary.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertFalse(stored.namespaceState.zoneCreationPending)
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [first, second])
    }

    // SM27-F1 H5: like seed pruning, an empty re-merge that finishes seeding must exclude every
    // live snip without a sent record, so snips the merge did not approve stay off iCloud. The
    // placeholder rows seeding reserves before a send do not count as sent.
    func testSeedingModeMergeWithoutPendingZoneCreationExcludesUnlinkedSnipsOnAnEmptyApproval() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let first = try await addSnip("first approval", to: library)
        let second = try await addSnip("second approval", to: library)
        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [first])
        _ = try await bridge.pendingChanges()

        try await bridge.approveModeMerge(snipIDs: [second])
        _ = try await bridge.pendingChanges()
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [second])
        // The merge excludes the approval it drops, because it never reached iCloud.
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [first])
        XCTAssertFalse(stored.namespaceState.zoneCreationPending)
        XCTAssertEqual(Set(stored.records.map(\.snipID)), [first, second])
        XCTAssertTrue(stored.records.allSatisfy { $0.acceptedText == nil }, "neither row was sent")

        try await bridge.approveModeMerge(snipIDs: [])
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertTrue(stored.namespaceState.approvedSnipIDs.isEmpty)
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [first, second])
        XCTAssertFalse(stored.namespaceState.zoneCreationPending)
        let pending = try await bridge.pendingChanges()
        XCTAssertTrue(pending.operations.isEmpty, "the empty merge uploads neither unapproved snip")
    }

    // SM27-F1 H5: a seed iCloud accepted stays linked when an empty re-merge finishes seeding, so
    // only the snip with a placeholder row is excluded.
    func testSeedingModeMergeEmptyApprovalKeepsADeliveredSeedLinked() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let first = try await addSnip("delivered seed", to: library)
        let second = try await addSnip("approved but never sent", to: library)
        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [first])
        guard case .save(let draft) = try await bridge.pendingChanges().operations.first else {
            return XCTFail("Expected the approved seed.")
        }
        let accepted = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)

        try await bridge.approveModeMerge(snipIDs: [second])
        _ = try await bridge.pendingChanges()
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [second])
        XCTAssertEqual(Set(stored.records.map(\.snipID)), [first, second])

        try await bridge.approveModeMerge(snipIDs: [])
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [second], "the sent seed stays linked")
        let pending = try await bridge.pendingChanges()
        XCTAssertTrue(pending.operations.isEmpty, "the other snip stays local")
    }

    // SM27-F2: the snip a re-merge supersedes holds only a placeholder row, so the re-merge excludes
    // it. Delivering the re-merged seed keeps it excluded instead of uploading it.
    func testSeedingModeMergeDeliveryExcludesTheSupersededPlaceholder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let (superseded, remerged, remergedSave) = try await seedThenRemerge(bridge, library: library)
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(Set(stored.records.map(\.snipID)), [superseded, remerged])
        XCTAssertTrue(stored.records.allSatisfy { $0.acceptedText == nil }, "neither row was sent")

        let accepted = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: remergedSave))
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)

        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [superseded], "the delivered seed stays linked")
        let pending = try await bridge.pendingChanges()
        XCTAssertTrue(pending.operations.isEmpty, "the superseded snip stays local")
    }

    // SM27-F2: as above, but seed pruning finishes the re-merged seeding. The superseded snip stays
    // excluded instead of uploading.
    func testSeedingModeMergePruningExcludesTheSupersededPlaceholder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let (superseded, remerged, _) = try await seedThenRemerge(bridge, library: library)
        _ = try await library.perform(.delete(ids: [remerged]), sortedBy: .chronological)

        let pending = try await bridge.pendingChanges()
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [superseded])
        XCTAssertTrue(pending.operations.isEmpty, "the superseded snip stays local")
    }

    // SM27-F2 guard: excluding the superseded placeholder doesn't strand it. A later active merge
    // that approves it again stops excluding it, and its placeholder row then uploads.
    func testActiveModeMergeReapprovingTheSupersededPlaceholderUploadsIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let (superseded, _, remergedSave) = try await seedThenRemerge(bridge, library: library)
        let accepted = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: remergedSave))
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)

        try await bridge.approveModeMerge(snipIDs: [superseded])
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertTrue(stored.namespaceState.excludedSnipIDs.isEmpty)
        let pending = try await bridge.pendingChanges()
        guard case .save(let draft) = pending.operations.first, pending.operations.count == 1 else {
            return XCTFail("Expected the re-approved snip to upload.")
        }
        XCTAssertEqual(draft.routingFields["snipID"], .string(superseded.uuidString.lowercased()))
    }

    // SM27-F2 guard: a later seeding merge that approves the superseded placeholder again stops
    // excluding it, so its placeholder row uploads.
    func testSeedingModeMergeReapprovingTheSupersededPlaceholderUploadsIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let (superseded, remerged, _) = try await seedThenRemerge(bridge, library: library)
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [superseded], "the re-merge excludes it")

        try await bridge.approveModeMerge(snipIDs: [superseded, remerged])
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [superseded, remerged])
        XCTAssertTrue(stored.namespaceState.excludedSnipIDs.isEmpty)
        let pending = try await bridge.pendingChanges()
        XCTAssertEqual(savedTexts(in: pending), [
            superseded: "superseded by the re-merge",
            remerged: "approved by the re-merge",
        ])
    }

    // SM27-F2 ADV-2 guard: excluding the superseded placeholder leaves the delivered seed linked,
    // so a later edit to it uploads.
    func testSeedingModeMergeDeliveredSeedKeepsItsLaterEditsSyncing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let (_, remerged, remergedSave) = try await seedThenRemerge(bridge, library: library)
        try await deliver(remergedSave, through: bridge)

        _ = try await library.perform(
            .update(
                id: remerged,
                content: "edited after delivery",
                attachmentURLs: nil,
                expectedUpdatedAt: nil,
                now: Date()
            ),
            sortedBy: .chronological
        )

        let pending = try await bridge.pendingChanges()
        XCTAssertEqual(savedTexts(in: pending)[remerged], "edited after delivery")
    }

    // SM27-F2 guard (Primary F1): an active merge that approves the superseded placeholder again
    // along with a fresh snip seeds only the fresh one. Delivering it keeps the placeholder linked,
    // so the placeholder uploads.
    func testActiveModeMergeReapprovalWithAFreshSnipUploadsThePlaceholderAfterDelivery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let (superseded, fresh, freshSave) = try await reapproveWithAFreshSnip(bridge, library: library)
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [fresh])
        XCTAssertTrue(stored.namespaceState.excludedSnipIDs.isEmpty)

        try await deliver(freshSave, through: bridge)

        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertTrue(stored.namespaceState.excludedSnipIDs.isEmpty, "the re-approved snip stays linked")
        let pending = try await bridge.pendingChanges()
        XCTAssertEqual(savedTexts(in: pending), [superseded: "superseded by the re-merge"])
    }

    // SM27-F2 guard (Primary F1): as above, but the fresh snip is deleted before its send, so seed
    // pruning finishes seeding. The re-approved placeholder stays linked and uploads.
    func testActiveModeMergeReapprovalWithAFreshSnipUploadsThePlaceholderAfterPruning() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let (superseded, fresh, _) = try await reapproveWithAFreshSnip(bridge, library: library)
        _ = try await library.perform(.delete(ids: [fresh]), sortedBy: .chronological)

        let pending = try await bridge.pendingChanges()
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertTrue(stored.namespaceState.excludedSnipIDs.isEmpty, "the re-approved snip stays linked")
        XCTAssertEqual(savedTexts(in: pending), [superseded: "superseded by the re-merge"])
    }

    // SM27-F2 ADV-1 guard: an active merge that seeds a fresh snip leaves a snip whose save is in
    // flight linked. Delivering the seed finishes seeding without excluding it, so it still uploads.
    func testActiveModeMergeSeedDeliveryKeepsAnInFlightSnipSyncing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let (inFlight, addition, additionSave) = try await mergeWhileASaveIsInFlight(bridge, library: library)
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [addition])
        XCTAssertTrue(stored.namespaceState.excludedSnipIDs.isEmpty)

        try await deliver(additionSave, through: bridge)

        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertTrue(stored.namespaceState.excludedSnipIDs.isEmpty, "the in-flight snip stays linked")
        let pending = try await bridge.pendingChanges()
        XCTAssertEqual(savedTexts(in: pending), [inFlight: "save in flight"])
    }

    // SM27-F2 ADV-1 guard: as above, but the fresh snip is deleted before its send, so seed pruning
    // finishes seeding. The in-flight snip stays linked and uploads.
    func testActiveModeMergeSeedPruningKeepsAnInFlightSnipSyncing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let (inFlight, addition, _) = try await mergeWhileASaveIsInFlight(bridge, library: library)
        _ = try await library.perform(.delete(ids: [addition]), sortedBy: .chronological)

        let pending = try await bridge.pendingChanges()
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertTrue(stored.namespaceState.excludedSnipIDs.isEmpty, "the in-flight snip stays linked")
        XCTAssertEqual(savedTexts(in: pending), [inFlight: "save in flight"])
    }

    // SM27-H3: a snip excluded at the first seed and approved by a later merge keeps syncing.
    func testActiveModeMergeApprovalOfAnExcludedSnipKeepsItsLaterEditsSyncing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try SwiftDataSnipLibrary(storeURL: directory.appendingPathComponent("snips.store"))
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let server = FakeCloudServer()
        let coordinator = CloudTextSyncCoordinator(
            store: bridge,
            transport: FakeCloudRecordTransport(server: server, namespace: namespace)
        )
        let seeded = try await addSnip("seeded first", to: library)
        let later = try await addSnip("approved by a later merge", to: library)
        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [seeded])
        try await coordinator.sendPending()
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [later])

        try await bridge.approveModeMerge(snipIDs: [later])
        try await coordinator.sendPending()
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let seededValues = await server.storedTextValues()
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertEqual(seededValues, ["approved by a later merge", "seeded first"])

        _ = try await library.perform(
            .update(
                id: later,
                content: "edited after the merge",
                attachmentURLs: nil,
                expectedUpdatedAt: nil,
                now: Date()
            ),
            sortedBy: .chronological
        )
        try await coordinator.sendPending()

        let editedValues = await server.storedTextValues()
        XCTAssertEqual(editedValues, ["edited after the merge", "seeded first"])
    }

    func testActiveModeMergeSeedsOnlyUnlinkedApprovals() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snips.store")
        let library = try SwiftDataSnipLibrary(storeURL: storeURL)
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let linked = try await addSnip("already synced", to: library)
        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [linked])
        guard case .save(let draft) = try await bridge.pendingChanges().operations.first else {
            return XCTFail("Expected the approved seed.")
        }
        let accepted = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)
        let added = try await addSnip("added by the merge", to: library)
        let leftLocal = try await addSnip("left local by the merge", to: library)

        try await bridge.approveModeMerge(snipIDs: [linked, added])

        let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
        let reopened = SwiftDataCloudTextPersistence(
            library: reopenedLibrary, namespace: namespace, textZone: zone
        )
        let stored = try await reopenedLibrary.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [added])
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [leftLocal])
        XCTAssertFalse(stored.namespaceState.zoneCreationPending)
        let pending = try await reopened.pendingChanges()
        guard case .save(let addedDraft) = pending.operations.first, pending.operations.count == 1 else {
            return XCTFail("Expected one seed for the merged addition.")
        }
        XCTAssertEqual(addedDraft.routingFields["snipID"], .string(added.uuidString.lowercased()))
    }

    func testRemoteCheckFetchOutcomesActivateFromRemoteRecordsAndBlockAfterwards() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snips.store")
        let library = try SwiftDataSnipLibrary(storeURL: storeURL)
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let local = try await addSnip("local before the first fetch", to: library)
        let phases: [(CloudFetchedBatch, CloudNamespaceBootstrapPhase)] = [
            (CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.failed(zone, .zoneMissing)],
                engineState: nil), .remoteCheckedMissingZone),
            (CloudFetchedBatch(id: UUID(), items: [], engineState: nil), .remoteChecked),
            (CloudFetchedBatch(id: UUID(), items: [], databaseEvents: [.zoneDeleted(zone, reason: .deleted)],
                engineState: nil), .remoteCheckedMissingZone),
        ]
        for (batch, phase) in phases {
            try await bridge.stage(.fetched(batch))
            try await bridge.applyStaged(batch.id)
            let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
            XCTAssertEqual(stored.namespaceState.phase, phase)
            XCTAssertTrue(stored.namespaceState.approvedSnipIDs.isEmpty)
            XCTAssertTrue(stored.namespaceState.excludedSnipIDs.isEmpty)
            XCTAssertFalse(stored.namespaceState.zoneCreationPending)
        }
        let remote = try CloudKitRecordMapper.snapshot(
            CloudKitRecordMapper.record(for: .text(id: .random(in: zone), snipID: UUID(), text: "remote"))
        )
        let fetched = CloudFetchedBatch(id: UUID(), items: [.record(remote)], engineState: nil)
        try await bridge.stage(.fetched(fetched))
        try await bridge.applyStaged(fetched.id)

        let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
        let reopened = SwiftDataCloudTextPersistence(
            library: reopenedLibrary, namespace: namespace, textZone: zone
        )
        var stored = try await reopenedLibrary.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [local])
        let activePending = try await reopened.pendingChanges()
        XCTAssertTrue(activePending.operations.isEmpty)

        let incomplete = CloudFetchedBatch(id: UUID(), items: [], databaseEvents: [.failed(nil, .retryable)],
            engineState: nil)
        try await reopened.stage(.fetched(incomplete))
        try await reopened.applyStaged(incomplete.id)
        stored = try await reopenedLibrary.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [local])

        let missing = CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.failed(zone, .zoneMissing)],
            engineState: nil)
        try await reopened.stage(.fetched(missing))
        try await reopened.applyStaged(missing.id)
        stored = try await reopenedLibrary.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .blocked)
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [local])
    }

    func testDestructiveResetBlocksSeedingAndKeepsItsApprovalsAcrossReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snips.store")
        let library = try SwiftDataSnipLibrary(storeURL: storeURL)
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let approved = try await addSnip("approved before the reset", to: library)
        let excluded = try await addSnip("excluded before the reset", to: library)
        let missing = CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.failed(zone, .zoneMissing)],
            engineState: nil)
        try await bridge.stage(.fetched(missing))
        try await bridge.applyStaged(missing.id)
        try await bridge.approveSeeding(snipIDs: [approved])
        let purge = CloudFetchedBatch(id: UUID(), items: [],
            databaseEvents: [.zoneDeleted(zone, reason: .purged)], engineState: nil)
        try await bridge.stage(.fetched(purge))
        try await bridge.applyStaged(purge.id)
        let clean = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
        try await bridge.stage(.fetched(clean))
        try await bridge.applyStaged(clean.id)

        let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
        let reopened = SwiftDataCloudTextPersistence(
            library: reopenedLibrary, namespace: namespace, textZone: zone
        )
        let stored = try await reopenedLibrary.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .blocked)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [approved])
        XCTAssertEqual(stored.namespaceState.excludedSnipIDs, [excluded])
        XCTAssertFalse(stored.namespaceState.zoneCreationPending)
        let pending = try await reopened.pendingChanges()
        XCTAssertEqual(pending, CloudOutboundBatch(operations: []))
        do {
            try await reopened.approveSeeding(snipIDs: [approved])
            XCTFail("Expected a blocked namespace to refuse seed approval.")
        } catch CloudNamespaceEnrollmentError.remoteFetchRequired {}
        do {
            try await reopened.approveModeMerge(snipIDs: [approved])
            XCTFail("Expected a blocked namespace to refuse a mode merge.")
        } catch CloudNamespaceEnrollmentError.remoteFetchRequired {}
    }

    func testSeedSendWithoutTheZoneSaveKeepsZoneCreationPending() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("snips.store")
        let library = try SwiftDataSnipLibrary(storeURL: storeURL)
        let namespace = makeNamespace()
        let zone = try XCTUnwrap(namespace.zones.first)
        let bridge = SwiftDataCloudTextPersistence(library: library, namespace: namespace, textZone: zone)
        let seed = try await addSnip("seed before the zone exists", to: library)
        let missing = CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.failed(zone, .zoneMissing)],
            engineState: nil)
        try await bridge.stage(.fetched(missing))
        try await bridge.applyStaged(missing.id)
        try await bridge.approveSeeding(snipIDs: [seed])
        guard case .save(let draft) = try await bridge.pendingChanges().operations.first else {
            return XCTFail("Expected the approved seed.")
        }
        let accepted = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))
        let savedWithoutZone = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(savedWithoutZone))
        try await bridge.applyStaged(savedWithoutZone.id)

        let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
        let reopened = SwiftDataCloudTextPersistence(
            library: reopenedLibrary, namespace: namespace, textZone: zone
        )
        var stored = try await reopenedLibrary.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertEqual(stored.namespaceState.approvedSnipIDs, [seed])
        XCTAssertTrue(stored.namespaceState.zoneCreationPending)
        let pending = try await reopened.pendingChanges()
        XCTAssertEqual(pending, CloudOutboundBatch(operations: [], zonesToSave: [zone]))

        let zoneSaved = CloudSentBatch(id: UUID(), items: [], databaseEvents: [.zoneSaved(zone)],
            engineState: nil)
        try await reopened.stage(.sent(zoneSaved))
        try await reopened.applyStaged(zoneSaved.id)
        stored = try await reopenedLibrary.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.namespaceState.phase, .active)
        XCTAssertTrue(stored.namespaceState.approvedSnipIDs.isEmpty)
        XCTAssertTrue(stored.namespaceState.excludedSnipIDs.isEmpty)
        XCTAssertFalse(stored.namespaceState.zoneCreationPending)
    }

    private func addSnip(_ content: String, to library: SwiftDataSnipLibrary) async throws -> UUID {
        let added = try await library.perform(
            .add(
                content: content,
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        guard case .add(.added(let id)) = added.outcome else { throw UnexpectedAddOutcome() }
        return id
    }

    private func markRemoteChecked(_ bridge: SwiftDataCloudTextPersistence) async throws {
        let batch = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
        try await bridge.stage(.fetched(batch))
        try await bridge.applyStaged(batch.id)
    }

    /// Seeds `superseded` until it holds a placeholder row, then re-merges to approve `remerged`
    /// instead. Returns the re-merged seed's save, which must be the only pending operation.
    private func seedThenRemerge(
        _ bridge: SwiftDataCloudTextPersistence,
        library: SwiftDataSnipLibrary
    ) async throws -> (superseded: UUID, remerged: UUID, remergedSave: CloudRecordDraft) {
        let superseded = try await addSnip("superseded by the re-merge", to: library)
        let remerged = try await addSnip("approved by the re-merge", to: library)
        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [superseded])
        _ = try await bridge.pendingChanges()
        try await bridge.approveModeMerge(snipIDs: [remerged])
        let remergedSave = try await onlySave(of: remerged, in: bridge.pendingChanges())
        return (superseded, remerged, remergedSave)
    }

    /// `seedThenRemerge`, then delivering the re-merged seed leaves `superseded` excluded with its
    /// placeholder row. An active merge then approves it again along with `fresh`. Returns the fresh
    /// snip's save, which must be the only pending operation.
    private func reapproveWithAFreshSnip(
        _ bridge: SwiftDataCloudTextPersistence,
        library: SwiftDataSnipLibrary
    ) async throws -> (superseded: UUID, fresh: UUID, freshSave: CloudRecordDraft) {
        let (superseded, _, remergedSave) = try await seedThenRemerge(bridge, library: library)
        try await deliver(remergedSave, through: bridge)
        let fresh = try await addSnip("approved with the superseded snip", to: library)
        try await bridge.approveModeMerge(snipIDs: [superseded, fresh])
        let freshSave = try await onlySave(of: fresh, in: bridge.pendingChanges())
        return (superseded, fresh, freshSave)
    }

    /// Delivers a first seed and leaves `inFlight` active with a placeholder row whose save never
    /// lands. An active merge then seeds `addition`. Returns the addition's save, which must be the
    /// only pending operation.
    private func mergeWhileASaveIsInFlight(
        _ bridge: SwiftDataCloudTextPersistence,
        library: SwiftDataSnipLibrary
    ) async throws -> (inFlight: UUID, addition: UUID, additionSave: CloudRecordDraft) {
        let seed = try await addSnip("delivered seed", to: library)
        try await markRemoteChecked(bridge)
        try await bridge.approveSeeding(snipIDs: [seed])
        let seedSave = try await onlySave(of: seed, in: bridge.pendingChanges())
        try await deliver(seedSave, through: bridge)
        let inFlight = try await addSnip("save in flight", to: library)
        _ = try await onlySave(of: inFlight, in: bridge.pendingChanges())
        let addition = try await addSnip("added by the merge", to: library)
        try await bridge.approveModeMerge(snipIDs: [addition])
        let additionSave = try await onlySave(of: addition, in: bridge.pendingChanges())
        return (inFlight, addition, additionSave)
    }

    /// Commits iCloud's acceptance of `save`, as its send batch would.
    private func deliver(
        _ save: CloudRecordDraft,
        through bridge: SwiftDataCloudTextPersistence
    ) async throws {
        let accepted = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: save))
        let sent = CloudSentBatch(id: UUID(), items: [.saved(accepted)], engineState: nil)
        try await bridge.stage(.sent(sent))
        try await bridge.applyStaged(sent.id)
    }

    /// The batch's only operation, which must save `snipID`.
    private func onlySave(of snipID: UUID, in batch: CloudOutboundBatch) throws -> CloudRecordDraft {
        guard batch.operations.count == 1, case .save(let draft) = batch.operations[0],
            draft.routingFields["snipID"] == .string(snipID.uuidString.lowercased())
        else { throw UnexpectedPendingChanges() }
        return draft
    }

    /// The text each save in `batch` uploads, keyed by snip.
    private func savedTexts(in batch: CloudOutboundBatch) -> [UUID: String] {
        var texts: [UUID: String] = [:]
        for case .save(let draft) in batch.operations {
            guard case .string(let snipID)? = draft.routingFields["snipID"],
                case .string(let text)? = draft.encryptedFields["text"],
                let id = UUID(uuidString: snipID)
            else { continue }
            texts[id] = text
        }
        return texts
    }

    private func approveAllLocalSnips(
        _ bridge: SwiftDataCloudTextPersistence,
        library: SwiftDataSnipLibrary
    ) async throws {
        try await markRemoteChecked(bridge)
        let local = await library.snapshot(sortedBy: .chronological)
        try await bridge.approveSeeding(snipIDs: Set(local.snips.map(\.id)))
    }

    private func makeNamespace() -> CloudSyncNamespace {
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        return CloudSyncNamespace(
            cloudScope: "test-scope",
            accountLineage: "account-a",
            generation: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
            zones: [zone]
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftDataCloudTextPersistenceTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class CloudApplyFailureGate: @unchecked Sendable {
    enum Failure: Error { case injected }

    private let lock = NSLock()
    private let failOnCall: Int
    private var calls = 0

    init(failOnCall: Int) {
        self.failOnCall = failOnCall
    }

    func call() throws {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if calls == failOnCall { throw Failure.injected }
    }
}

private struct UnexpectedAddOutcome: Error {}

private struct UnexpectedPendingChanges: Error {}
