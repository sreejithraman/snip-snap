import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

final class SwiftDataCloudTextPersistenceTests: XCTestCase {
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
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertTrue(pending.operations.isEmpty)
        XCTAssertEqual(pending.zonesToSave, [zone])

        let coordinator = CloudTextSyncCoordinator(
            store: bridge,
            transport: FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
        )
        try await coordinator.sync()
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
        XCTAssertEqual(stored.namespaceState.phase, .seeding)
        XCTAssertTrue(stored.namespaceState.approvedSnipIDs.isEmpty)
        XCTAssertEqual(pending.zonesToSave, [zone])

        let coordinator = CloudTextSyncCoordinator(
            store: bridge,
            transport: FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
        )
        try await coordinator.sync()
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        var stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
            namespaceKey: namespace.canonicalKey
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
            namespaceKey: namespace.canonicalKey
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
            namespaceKey: namespace.canonicalKey
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
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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

        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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
            namespaceKey: namespace.canonicalKey
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
            namespaceKey: namespace.canonicalKey
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
            namespaceKey: namespace.canonicalKey
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
        let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
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

        try await bridge.clear()
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

    private func markRemoteChecked(_ bridge: SwiftDataCloudTextPersistence) async throws {
        let batch = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
        try await bridge.stage(.fetched(batch))
        try await bridge.applyStaged(batch.id)
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
