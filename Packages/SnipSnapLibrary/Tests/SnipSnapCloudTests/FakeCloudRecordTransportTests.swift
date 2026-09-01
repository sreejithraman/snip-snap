@testable import SnipSnapCloud
import XCTest

final class FakeCloudRecordTransportTests: XCTestCase {
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

    func testFetchKeepsSuccessfulItemsFailuresAndZoneDeletionTogether() async throws {
        let server = FakeCloudServer()
        let writer = FakeCloudRecordTransport(server: server)
        let reader = FakeCloudRecordTransport(server: server)
        let zone = CloudZoneID(name: "metadata", ownerName: "owner")
        let id = CloudRecordID(zone: zone, name: "partial-fetch")
        let draft = CloudRecordDraft.text(
            id: id,
            snipID: UUID(uuidString: "56565656-5656-5656-5656-565656565656")!,
            text: "keep success"
        )
        let sent = try await writer.send(CloudOutboundBatch(operations: [.save(draft)]))
        try await writer.confirmApplied(sent.id)
        await server.emitZoneDeletion(zone, reason: .encryptedDataReset)
        await reader.failNextFetchedItem(id, failure: .retryable)

        let batch = try await reader.fetch(scope: .all)

        XCTAssertEqual(batch.recordSnapshots.map(\.id), [id])
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
}

private extension CloudFetchedBatch {
    var recordSnapshots: [CloudRecordSnapshot] {
        items.compactMap { item in
            guard case .record(let snapshot) = item else { return nil }
            return snapshot
        }
    }
}
