@testable import SnipSnapCloud
import XCTest
import CryptoKit
import Darwin

final class FakeCloudRecordTransportTests: XCTestCase {
    func testMetadataOnlyTransportCompletesInitialFetchWithinItsConfiguredZones() async throws {
        let server = FakeCloudServer()
        let metadata = CloudZoneID(name: "metadata", ownerName: "owner")
        let payload = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(cloudScope: "test", accountLineage: "account",
            generation: UUID(), zones: [metadata, payload])
        let writer = FakeCloudRecordTransport(server: server)
        let payloadID = CloudRecordID(zone: payload, name: "not-metadata")
        _ = try await writer.send(CloudOutboundBatch(operations: [
            .save(.text(id: payloadID, snipID: UUID(), text: "payload"))
        ]))
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace,
            automaticallyFetchedZones: [metadata])
        try await transport.start(state: nil)

        let initial = try await transport.fetch(scope: .all)

        XCTAssertTrue(initial.isInitialFetch)
        XCTAssertEqual(initial.engineState?.requiresInitialFetch, false)
        XCTAssertEqual(initial.zoneEvents, [.fetched(metadata)])
        XCTAssertTrue(initial.items.isEmpty)
    }

    func testFailedInitialZoneRetainsItsCursorUntilSuccessfulRefetch() async throws {
        let server = FakeCloudServer()
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        let namespace = CloudSyncNamespace(cloudScope: "test", accountLineage: "account",
            generation: UUID(), zones: [zone])
        let id = CloudRecordID(zone: zone, name: "record")
        let writer = FakeCloudRecordTransport(server: server)
        _ = try await writer.send(CloudOutboundBatch(operations: [
            .save(.text(id: id, snipID: UUID(), text: "must refetch"))
        ]))
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        try await transport.start(state: nil)
        await transport.failNextFetchedZone(zone, failure: .networkUnavailable)
        let failed = try await transport.fetch(scope: .all)
        XCTAssertTrue(failed.isInitialFetch)
        XCTAssertEqual(failed.engineState?.requiresInitialFetch, true)
        try await transport.confirmApplied(failed.id)

        let retried = try await transport.fetch(scope: .all)

        XCTAssertTrue(retried.isInitialFetch)
        XCTAssertEqual(retried.engineState?.requiresInitialFetch, false)
        XCTAssertEqual(retried.items.compactMap(\.id), [id])
    }

    func testPartialOrFailedInitialFetchKeepsReadinessBlocked() async throws {
        let metadata = CloudZoneID(name: "metadata", ownerName: "owner")
        let payload = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(cloudScope: "test", accountLineage: "account",
            generation: UUID(), zones: [metadata, payload])
        let transport = FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
        try await transport.start(state: nil)
        let partial = try await transport.fetch(scope: .zones([metadata]))
        XCTAssertTrue(partial.isInitialFetch)
        XCTAssertEqual(partial.engineState?.requiresInitialFetch, true)
        try await transport.confirmApplied(partial.id)
        await transport.failNextFetchedZone(payload, failure: .networkUnavailable)
        let failed = try await transport.fetch(scope: .all)
        XCTAssertTrue(failed.isInitialFetch)
        XCTAssertEqual(failed.engineState?.requiresInitialFetch, true)
        try await transport.confirmApplied(failed.id)
        let complete = try await transport.fetch(scope: .all)
        XCTAssertTrue(complete.isInitialFetch)
        XCTAssertEqual(complete.engineState?.requiresInitialFetch, false)
    }

    func testInitialFetchEvidenceComesFromStateBeforeTheFetchAndResetsWithTheEngine() async throws {
        let server = FakeCloudServer()
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        let namespace = CloudSyncNamespace(cloudScope: "test", accountLineage: "account",
            generation: UUID(), zones: [zone])
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        try await transport.start(state: nil)
        let zoneSave = try await transport.send(CloudOutboundBatch(operations: [], zonesToSave: [zone]))
        try await transport.confirmApplied(zoneSave.id)
        let initial = try await transport.fetch(scope: .all)
        XCTAssertTrue(initial.isInitialFetch)
        XCTAssertEqual(initial.engineState?.requiresInitialFetch, false)
        try await transport.confirmApplied(initial.id)
        let incremental = try await transport.fetch(scope: .all)
        XCTAssertFalse(incremental.isInitialFetch)
        XCTAssertTrue(incremental.zoneEvents.contains(.fetched(zone)))
        try await transport.confirmApplied(incremental.id)
        let reopened = FakeCloudRecordTransport(server: server, namespace: namespace)
        try await reopened.start(state: incremental.engineState)
        let restored = try await reopened.fetch(scope: .all)
        XCTAssertFalse(restored.isInitialFetch)
        try await reopened.confirmApplied(restored.id)
        await reopened.reset()
        try await reopened.start(state: nil)
        let restarted = try await reopened.fetch(scope: .all)
        XCTAssertTrue(restarted.isInitialFetch)
    }

    func testCloudAssetCopyNeedsFileAccessWithoutDirectoryReadAccess() throws {
        if geteuid() == 0 { throw XCTSkip("Root bypasses directory permissions.") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudAssetAccessTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationURL = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        defer {
            chmod(sourceDirectory.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        let source = sourceDirectory.appendingPathComponent("asset.bin")
        let bytes = Data("CloudKit attachment".utf8)
        try bytes.write(to: source)
        XCTAssertEqual(chmod(sourceDirectory.path, 0o100), 0)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let directory = open(sourceDirectory.path, O_RDONLY | O_DIRECTORY)
        if directory >= 0 { close(directory) }
        XCTAssertEqual(directory, -1)

        let receipt = try CloudAssetFileCopy.copy(
            recordID: CloudRecordID(zone: CloudZoneID(name: "payload", ownerName: "owner"), name: "asset"),
            field: "blob",
            source: source,
            destination: CloudAssetDestination(validating: destinationURL)
        )

        XCTAssertEqual(try Data(contentsOf: receipt.fileURL), bytes)
        XCTAssertEqual(receipt.byteCount, Int64(bytes.count))
        XCTAssertEqual(receipt.sha256, Data(SHA256.hash(data: bytes)))
    }

    func testCloudAssetCopyAcceptsADirectoryURLWithoutATrailingSlash() throws {
        // Use the app's cache location: normalizing /var temporary paths can
        // incidentally restore the directory slash and hide this failure.
        let cache = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        let root = cache
            .appendingPathComponent("CloudAssetDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = root.appendingPathComponent("destination", isDirectory: false)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("asset.bin")
        let bytes = Data("downloaded attachment".utf8)
        try bytes.write(to: source)
        XCTAssertFalse(destinationURL.hasDirectoryPath)

        let receipt = try CloudAssetFileCopy.copy(
            recordID: CloudRecordID(zone: CloudZoneID(name: "payload", ownerName: "owner"), name: "asset"),
            field: "blob",
            source: source,
            destination: CloudAssetDestination(validating: destinationURL)
        )

        XCTAssertEqual(try Data(contentsOf: receipt.fileURL), bytes)
        XCTAssertEqual(receipt.fileURL.deletingLastPathComponent().path, destinationURL.path)
    }

    func testCloudAssetCopyRejectsNonRegularSourcesAndLeavesNoOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudAssetTypeTests-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pipe = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        for source in [root, pipe] {
            XCTAssertThrowsError(try CloudAssetFileCopy.copy(
                recordID: CloudRecordID(zone: CloudZoneID(name: "payload", ownerName: "owner"), name: "asset"),
                field: "blob",
                source: source,
                destination: CloudAssetDestination(validating: destinationURL)
            ))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destinationURL.path).isEmpty)
    }

    func testCloudAssetCopyRejectsSymlinkSourceAndLeavesNoOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudAssetSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let regularURL = root.appendingPathComponent("regular.bin", isDirectory: false)
        let symlinkURL = root.appendingPathComponent("link.bin", isDirectory: false)
        try Data("payload".utf8).write(to: regularURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: regularURL)
        let destination = try CloudAssetDestination(validating: destinationURL)
        let recordID = CloudRecordID(
            zone: CloudZoneID(name: "payload", ownerName: "owner"),
            name: "asset-record"
        )

        XCTAssertThrowsError(
            try CloudAssetFileCopy.copy(
                recordID: recordID,
                field: "blob",
                source: symlinkURL,
                destination: destination
            )
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destinationURL.path).isEmpty)
    }

    func testRestoredEngineStateContinuesAfterTheLastConfirmedFetch() async throws {
        let server = FakeCloudServer()
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "test",
            accountLineage: "account",
            generation: UUID(),
            zones: [zone]
        )
        let writer = FakeCloudRecordTransport(server: server)
        let firstReader = FakeCloudRecordTransport(server: server, namespace: namespace)
        let firstID = CloudRecordID(zone: zone, name: "first")
        let secondID = CloudRecordID(zone: zone, name: "second")
        let firstSent = try await writer.send(
            CloudOutboundBatch(
                operations: [
                    .save(.text(id: firstID, snipID: UUID(), text: "first"))
                ]
            )
        )
        try await writer.confirmApplied(firstSent.id)
        let firstFetch = try await firstReader.fetch(scope: .all)
        let savedState = try XCTUnwrap(firstFetch.engineState)
        try await firstReader.confirmApplied(firstFetch.id)
        let secondSent = try await writer.send(
            CloudOutboundBatch(
                operations: [
                    .save(.text(id: secondID, snipID: UUID(), text: "second"))
                ]
            )
        )
        try await writer.confirmApplied(secondSent.id)

        let reopened = FakeCloudRecordTransport(server: server, namespace: namespace)
        try await reopened.start(state: savedState)
        let resumed = try await reopened.fetch(scope: .all)

        XCTAssertEqual(resumed.recordSnapshots.map(\.id), [secondID])
    }

    func testDesiredFieldsAndLargeAssetCopyMatchTheTransportContract() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeCloudAssetTests-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: sourceURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: sourceURL)
        let chunk = Data(repeating: 0x5a, count: 1_048_576)
        for _ in 0..<12 { try output.write(contentsOf: chunk) }
        try output.close()

        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server)
        let id = CloudRecordID(
            zone: CloudZoneID(name: "payload", ownerName: "owner"),
            name: "asset-record"
        )
        let draft = CloudRecordDraft(
            id: id,
            recordType: "Payload",
            schemaVersion: 4,
            routingFields: [
                "schemaVersion": .int64(4),
                "label": .string("visible"),
            ],
            encryptedFields: ["secret": .string("hidden")],
            assetFields: ["blob": CloudAssetUpload(fileURL: sourceURL)]
        )
        let sent = try await transport.send(CloudOutboundBatch(operations: [.save(draft)]))
        try await transport.confirmApplied(sent.id)
        try FileManager.default.removeItem(at: sourceURL)

        let projected = try await transport.fetchRecord(id, fields: ["label"])
        XCTAssertEqual(projected?.routingFields, ["label": .string("visible")])
        XCTAssertTrue(projected?.encryptedFields.isEmpty == true)
        XCTAssertTrue(projected?.assetFields.isEmpty == true)
        let metadataOnly = try await transport.fetchRecord(id, fields: [])
        XCTAssertTrue(metadataOnly?.routingFields.isEmpty == true)
        XCTAssertTrue(metadataOnly?.encryptedFields.isEmpty == true)
        XCTAssertTrue(metadataOnly?.assetFields.isEmpty == true)

        let destination = try CloudAssetDestination(validating: destinationURL)
        await transport.failNextAssetFetch()
        do {
            _ = try await transport.fetchAsset(id, field: "blob", destination: destination)
            XCTFail("Expected the injected asset failure.")
        } catch FakeCloudError.injectedAssetFailure {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destinationURL.path).isEmpty)

        let fetchedAsset = try await transport.fetchAsset(
            id,
            field: "blob",
            destination: destination
        )
        let receipt = try XCTUnwrap(fetchedAsset)
        let attributes = try FileManager.default.attributesOfItem(atPath: receipt.fileURL.path)
        XCTAssertEqual(receipt.recordID, id)
        XCTAssertEqual(receipt.field, "blob")
        XCTAssertEqual(receipt.byteCount, 12 * 1_048_576)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, receipt.byteCount)
        XCTAssertEqual(receipt.sha256.count, 32)
        XCTAssertEqual(
            try receipt.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true
        )
    }

    func testFetchKeepsOtherSuccessfulItemsFailuresAndZoneDeletionTogether() async throws {
        let server = FakeCloudServer()
        let writer = FakeCloudRecordTransport(server: server)
        let reader = FakeCloudRecordTransport(server: server)
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        let id = CloudRecordID(zone: zone, name: "partial-fetch")
        let successfulID = CloudRecordID(zone: zone, name: "partial-fetch-success")
        let draft = CloudRecordDraft.text(
            id: id,
            snipID: UUID(uuidString: "56565656-5656-5656-5656-565656565656")!,
            text: "keep success"
        )
        let successfulDraft = CloudRecordDraft.text(
            id: successfulID,
            snipID: UUID(uuidString: "57575757-5757-5757-5757-575757575757")!,
            text: "other success"
        )
        let sent = try await writer.send(CloudOutboundBatch(
            operations: [.save(draft), .save(successfulDraft)]
        ))
        try await writer.confirmApplied(sent.id)
        await server.emitZoneDeletion(zone, reason: .encryptedDataReset)
        await reader.failNextFetchedItem(id, failure: .retryable)

        let batch = try await reader.fetch(scope: .all)

        XCTAssertEqual(batch.recordSnapshots.map(\.id), [successfulID])
        XCTAssertTrue(
            batch.items.contains {
                guard case .failed(let failedID, .retryable) = $0 else { return false }
                return failedID == id
            }
        )
        XCTAssertEqual(
            batch.databaseEvents,
            [.zoneDeleted(zone, reason: .encryptedDataReset)]
        )
    }

    func testInjectedFetchAndSendFailuresDoNotAdvanceServerOrClientState() async throws {
        let server = FakeCloudServer()
        let writer = FakeCloudRecordTransport(server: server)
        let reader = FakeCloudRecordTransport(server: server)
        let id = CloudRecordID(
            zone: CloudZoneID(name: "metadata", ownerName: "owner"),
            name: "fault-record"
        )
        let draft = CloudRecordDraft.text(
            id: id,
            snipID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            text: "retry me"
        )

        await writer.failNextSend()
        do {
            _ = try await writer.send(CloudOutboundBatch(operations: [.save(draft)]))
            XCTFail("Expected the injected send failure.")
        } catch CloudTransportError.sendFailed {}
        let missingAfterFailure = try await reader.fetchRecord(id, fields: [])
        XCTAssertNil(missingAfterFailure)

        let accepted = try await writer.send(CloudOutboundBatch(operations: [.save(draft)]))
        try await writer.confirmApplied(accepted.id)
        await reader.failNextFetch()
        do {
            _ = try await reader.fetch(scope: .all)
            XCTFail("Expected the injected fetch failure.")
        } catch CloudTransportError.fetchFailed {}

        let retried = try await reader.fetch(scope: .all)
        XCTAssertEqual(retried.recordSnapshots.map(\.id), [id])
    }

    func testOneStaleSaveConflictsWhileAnotherItemStillSucceeds() async throws {
        let server = FakeCloudServer()
        let first = FakeCloudRecordTransport(server: server)
        let second = FakeCloudRecordTransport(server: server)
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        let firstID = CloudRecordID(zone: zone, name: "first")
        let secondID = CloudRecordID(zone: zone, name: "second")
        let firstSnipID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let secondSnipID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let seeded = try await first.send(
            CloudOutboundBatch(
                operations: [
                    .save(.text(id: firstID, snipID: firstSnipID, text: "first base")),
                    .save(.text(id: secondID, snipID: secondSnipID, text: "second base")),
                ]
            )
        )
        try await first.confirmApplied(seeded.id)
        let baseBatch = try await second.fetch(scope: .all)
        try await second.confirmApplied(baseBatch.id)
        let bases = Dictionary(
            uniqueKeysWithValues: baseBatch.recordSnapshots.map { ($0.id, $0) }
        )
        let firstBase = try XCTUnwrap(bases[firstID])
        let secondBase = try XCTUnwrap(bases[secondID])
        let firstWin = try await first.send(
            CloudOutboundBatch(
                operations: [
                    .save(
                        .text(
                            id: firstID,
                            snipID: firstSnipID,
                            text: "won first",
                            base: firstBase.shadow
                        )
                    )
                ]
            )
        )
        try await first.confirmApplied(firstWin.id)

        let result = try await second.send(
            CloudOutboundBatch(
                operations: [
                    .save(
                        .text(
                            id: firstID,
                            snipID: firstSnipID,
                            text: "stale first",
                            base: firstBase.shadow
                        )
                    ),
                    .save(
                        .text(
                            id: secondID,
                            snipID: secondSnipID,
                            text: "won second",
                            base: secondBase.shadow
                        )
                    ),
                ]
            )
        )

        guard case .conflict(let conflictedID, let serverRecord) = result.items[0] else {
            return XCTFail("Expected the stale item to conflict.")
        }
        XCTAssertEqual(conflictedID, firstID)
        XCTAssertEqual(serverRecord.encryptedFields["text"], .string("won first"))
        guard case .saved(let saved) = result.items[1] else {
            return XCTFail("Expected the unrelated item to save.")
        }
        XCTAssertEqual(saved.encryptedFields["text"], .string("won second"))
    }

    func testFetchDoesNotAdvanceUntilTheCallerConfirmsDurableApply() async throws {
        let server = FakeCloudServer()
        let writer = FakeCloudRecordTransport(server: server)
        let reader = FakeCloudRecordTransport(server: server)
        let id = CloudRecordID(
            zone: CloudZoneID(name: "metadata", ownerName: "owner"),
            name: "opaque-record"
        )
        let draft = CloudRecordDraft.text(
            id: id,
            snipID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            text: "remote text"
        )
        let accepted = try await writer.send(CloudOutboundBatch(operations: [.save(draft)]))
        try await writer.confirmApplied(accepted.id)

        let first = try await reader.fetch(scope: .zones([id.zone]))
        let retried = try await reader.fetch(scope: .zones([id.zone]))

        XCTAssertEqual(retried, first)
        try await reader.confirmApplied(first.id)
        let afterCommit = try await reader.fetch(scope: .zones([id.zone]))
        XCTAssertTrue(afterCommit.items.isEmpty)
    }

    func testSendReturnsOneResultPerSaveAndDelete() async throws {
        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server)
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        let savedID = CloudRecordID(zone: zone, name: "save")
        let deletedID = CloudRecordID(zone: zone, name: "delete")
        let draft = CloudRecordDraft.text(
            id: savedID,
            snipID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            text: "save me"
        )
        let deleteDraft = CloudRecordDraft.text(
            id: deletedID,
            snipID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            text: "delete me"
        )
        let seeded = try await transport.send(
            CloudOutboundBatch(operations: [.save(deleteDraft)])
        )
        guard case .saved(let deleteSnapshot) = seeded.items.first else {
            return XCTFail("Expected the delete fixture to save.")
        }
        try await transport.confirmApplied(seeded.id)

        let result = try await transport.send(
            CloudOutboundBatch(
                operations: [.save(draft), .delete(deletedID, base: deleteSnapshot.shadow)]
            )
        )

        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items[0].id, savedID)
        XCTAssertEqual(result.items[1], .deleted(deletedID))
    }

    // MARK: SM33-F2A atomic order writes

    func testAnOrderWriteWithAStaleMemberWritesNoMemberAndLeavesTheOthersUnsent() async throws {
        let fixture = try await OrderWriteFixture.published()
        try await fixture.moveOnAnotherDevice(fixture.a, to: 2)
        let reorder = CloudOutboundBatch(operations: [
            .save(fixture.draft(fixture.a, position: 1)),
            .save(fixture.draft(fixture.b, position: 0)),
        ])

        let sent = try await fixture.transport.send(reorder)

        XCTAssertEqual(sent.items.map(\.id), [fixture.a], "B failed only with its batch, so it reports nothing.")
        guard case .conflict(_, let current)? = sent.items.first else {
            return XCTFail("The stale member must report the server record.")
        }
        XCTAssertEqual(current.encryptedFields["position"], .int64(2))
        let b = await fixture.server.fullSnapshot(for: fixture.b)
        XCTAssertEqual(b?.shadow, fixture.shadows[fixture.b], "iCloud must apply no member of a failed group.")
        guard case .batch(let pending)? = await queuedTransportEvent(fixture.transport) else {
            return XCTFail("The send must commit through its reported records.")
        }
        XCTAssertEqual(pending.batch.id, sent.id)
        XCTAssertEqual(pending.outbound?.operations.map(\.id), [fixture.a])
        let events = await fixture.transport.events()
        XCTAssertTrue(events.contains(.sentAtomic(fixture.snipID, [fixture.a, fixture.b])))
        try await fixture.transport.confirmApplied(sent.id)
        let afterConfirm = await queuedTransportEvent(fixture.transport)
        XCTAssertNil(afterConfirm)
    }

    func testAnOrderWriteReportsEachMembersOwnErrorAndWritesNothing() async throws {
        let fixture = try await OrderWriteFixture.published()
        let missing = CloudRecordID(zone: fixture.zone, name: "deleted-elsewhere")
        await fixture.transport.failNextSentItem(fixture.b, failure: .quotaExceeded)
        let reorder = CloudOutboundBatch(operations: [
            .save(fixture.draft(fixture.a, position: 1)),
            .save(fixture.draft(fixture.b, position: 0)),
            .save(fixture.draft(missing, position: 2, base: fixture.shadows[fixture.a])),
        ])

        let sent = try await fixture.transport.send(reorder)

        XCTAssertEqual(sent.items, [.failed(fixture.b, .quotaExceeded), .unknownItem(missing)])
        for id in [fixture.a, fixture.b] {
            let current = await fixture.server.fullSnapshot(for: id)
            XCTAssertEqual(current?.shadow, fixture.shadows[id])
        }
    }

    func testAnOrderWriteCanReportOnlyItsFirstFailingMember() async throws {
        let fixture = try await OrderWriteFixture.published()
        try await fixture.moveOnAnotherDevice(fixture.a, to: 3)
        try await fixture.moveOnAnotherDevice(fixture.b, to: 2)
        await fixture.transport.reportOnlyFirstAtomicFailure()
        let reorder = CloudOutboundBatch(operations: [
            .save(fixture.draft(fixture.a, position: 1)),
            .save(fixture.draft(fixture.b, position: 0)),
        ])

        let aBefore = await fixture.server.fullSnapshot(for: fixture.a)
        let bBefore = await fixture.server.fullSnapshot(for: fixture.b)
        let sent = try await fixture.transport.send(reorder)

        XCTAssertEqual(sent.items.map(\.id), [fixture.a], "The other stale member fails with its batch.")
        guard case .batch(let pending)? = await queuedTransportEvent(fixture.transport) else {
            return XCTFail("The send must commit through its reported records.")
        }
        XCTAssertEqual(pending.batch.id, sent.id)
        XCTAssertEqual(pending.outbound?.operations.map(\.id), [fixture.a])
        let aAfter = await fixture.server.fullSnapshot(for: fixture.a)
        let bAfter = await fixture.server.fullSnapshot(for: fixture.b)
        XCTAssertEqual(aAfter, aBefore, "The failed atomic group must write no member.")
        XCTAssertEqual(bAfter, bBefore)
        try await fixture.transport.confirmApplied(sent.id)
        let afterConfirm = await queuedTransportEvent(fixture.transport)
        XCTAssertNil(afterConfirm)
    }

    func testAnOrderWriteNeitherFailsNorIsFailedByUnrelatedRecordsInTheSameSend() async throws {
        let fixture = try await OrderWriteFixture.published()
        let text = CloudRecordID(zone: fixture.zone, name: "text")
        let other = CloudRecordID(zone: fixture.zone, name: "other-snip")
        let seeded = try await fixture.transport.send(CloudOutboundBatch(operations: [
            .save(.text(id: text, snipID: UUID(), text: "seed")),
        ]))
        try await fixture.transport.confirmApplied(seeded.id)
        let succeeding = CloudOutboundBatch(operations: [
            .save(.text(id: text, snipID: UUID(), text: "stale")),
            .save(fixture.draft(fixture.a, position: 1)),
            .save(fixture.draft(fixture.b, position: 0)),
        ])

        let first = try await fixture.transport.send(succeeding)

        XCTAssertEqual(first.items.map(\.id), [text, fixture.a, fixture.b])
        guard case .conflict = first.items[0], case .saved = first.items[1],
              case .saved(let savedB) = first.items[2] else {
            return XCTFail("Only the stale text record may fail. Got \(first.items).")
        }
        let noPendingEvent = await queuedTransportEvent(fixture.transport)
        XCTAssertNil(noPendingEvent, "A send that reported every record commits directly.")
        try await fixture.transport.confirmApplied(first.id)
        let failing = CloudOutboundBatch(operations: [
            .save(fixture.draft(fixture.a, position: 2)),
            .save(.text(id: other, snipID: UUID(), text: "unrelated")),
            .save(fixture.draft(fixture.b, position: 1, base: savedB.shadow)),
        ])

        let second = try await fixture.transport.send(failing)

        XCTAssertEqual(second.items.map(\.id), [fixture.a, other], "B failed only with its batch.")
        guard case .conflict = second.items[0], case .saved = second.items[1] else {
            return XCTFail("The failed group must not fail the unrelated save. Got \(second.items).")
        }
    }

    func testASaveThatKeepsItsPositionIsNotAnOrderWrite() async throws {
        let fixture = try await OrderWriteFixture.published()
        var fields = fixture.draft(fixture.a, position: 0).encryptedFields
        fields["fileName"] = .string("renamed")
        let rename = CloudRecordDraft(id: fixture.a, recordType: CloudAttachmentRecordCodec.metadataRecordType,
            schemaVersion: 1, routingFields: ["schemaVersion": .int64(1)], encryptedFields: fields,
            base: fixture.shadows[fixture.a])

        XCTAssertFalse(CloudAttachmentOrderWrite.changesOrder(rename))
        XCTAssertTrue(CloudAttachmentOrderWrite.groups(in: [.save(rename)]).isEmpty)
        XCTAssertTrue(CloudAttachmentOrderWrite.changesOrder(fixture.draft(fixture.a, position: 1)))
        XCTAssertEqual(CloudAttachmentOrderWrite.groups(in: [
            .save(rename),
            .save(fixture.draft(fixture.b, position: 0)),
        ]), [fixture.snipID: [fixture.a, fixture.b]], "Every metadata save of a reordered snip joins its write.")
    }
}

// Use the same existential dispatch as the coordinator, rather than the concrete actor's
// synchronous overload competing with the protocol's async default.
private func queuedTransportEvent(_ transport: any CloudRecordTransport) async -> CloudRecordTransportEvent? {
    await transport.pendingEvent()
}

/// One snip with attachment metadata records A0 and B1, published on a fake server.
private struct OrderWriteFixture {
    let server: FakeCloudServer
    let transport: FakeCloudRecordTransport
    let zone = CloudZoneID(name: "data", ownerName: "owner")
    let snipID: UUID
    let a: CloudRecordID
    let b: CloudRecordID
    let shadows: [CloudRecordID: CloudRecordShadow]

    static func published() async throws -> Self {
        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server)
        let zone = CloudZoneID(name: "data", ownerName: "owner")
        let snipID = UUID()
        let a = CloudRecordID(zone: zone, name: "a-1")
        let b = CloudRecordID(zone: zone, name: "a-2")
        let sent = try await transport.send(CloudOutboundBatch(operations: [
            .save(metadataDraft(a, snipID: snipID, position: 0, base: nil)),
            .save(metadataDraft(b, snipID: snipID, position: 1, base: nil)),
        ]))
        try await transport.confirmApplied(sent.id)
        var shadows: [CloudRecordID: CloudRecordShadow] = [:]
        for item in sent.items {
            guard case .saved(let snapshot) = item else { throw CloudTransportError.invalidRecord }
            shadows[snapshot.id] = snapshot.shadow
        }
        return Self(server: server, transport: transport, snipID: snipID, a: a, b: b, shadows: shadows)
    }

    func draft(_ id: CloudRecordID, position: Int64, base: CloudRecordShadow? = nil) -> CloudRecordDraft {
        Self.metadataDraft(id, snipID: snipID, position: position, base: base ?? shadows[id])
    }

    /// Another device's save lands first, so this device's base for the record goes stale.
    func moveOnAnotherDevice(_ id: CloudRecordID, to position: Int64) async throws {
        let other = FakeCloudRecordTransport(server: server)
        var fields = draft(id, position: position).encryptedFields
        fields["fileName"] = .string("moved elsewhere")
        _ = try await other.send(CloudOutboundBatch(operations: [
            .save(CloudRecordDraft(id: id, recordType: CloudAttachmentRecordCodec.metadataRecordType,
                schemaVersion: 1, routingFields: ["schemaVersion": .int64(1)], encryptedFields: fields,
                base: shadows[id])),
        ]))
    }

    private static func metadataDraft(
        _ id: CloudRecordID,
        snipID: UUID,
        position: Int64,
        base: CloudRecordShadow?
    ) -> CloudRecordDraft {
        CloudRecordDraft(
            id: id,
            recordType: CloudAttachmentRecordCodec.metadataRecordType,
            schemaVersion: 1,
            routingFields: ["schemaVersion": .int64(1)],
            encryptedFields: [
                "snipID": .string(snipID.uuidString.lowercased()),
                "position": .int64(position),
                "fileName": .string(id.name),
            ],
            base: base
        )
    }
}

private extension CloudFetchedBatch {
    var recordSnapshots: [CloudRecordSnapshot] {
        items.compactMap { item in
            guard case .record(let snapshot) = item else { return nil }
            return snapshot
        }
    }
}
