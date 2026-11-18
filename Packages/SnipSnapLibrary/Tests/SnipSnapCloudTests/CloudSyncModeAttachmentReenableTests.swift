import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testSecondDeviceCanEnableSyncWithAnUncachedRemoteAttachment() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("attachment from the first device".utf8)
        let sourceURL = root.appendingPathComponent("attachment.txt")
        try bytes.write(to: sourceURL)
        let metadataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(),
            zones: [metadataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let first = try SwiftDataSyncModePersistence(rootURL: root.appendingPathComponent("first"))
        let local = try await first.activeLibrary()
        let added = try await local.perform(
            .add(
                content: "saved on the first device",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [sourceURL],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        let attachment = try XCTUnwrap(snip.attachments.first)
        let firstCoordinator = ICloudSyncModeCoordinator(
            persistence: first,
            namespace: namespace,
            textZone: metadataZone,
            payloadZone: payloadZone,
            makeTransport: {
                FakeCloudRecordTransport(
                    server: server, namespace: namespace,
                    automaticallyFetchedZones: [metadataZone]
                )
            }
        )
        let firstEnabled = try await firstCoordinator.enableOrRetry()
        XCTAssertEqual(firstEnabled.state, .on)

        let second = try SwiftDataSyncModePersistence(
            rootURL: root.appendingPathComponent("second"),
            attachmentCacheRootURL: root.appendingPathComponent("second-cache")
        )
        let secondCoordinator = ICloudSyncModeCoordinator(
            persistence: second,
            namespace: namespace,
            textZone: metadataZone,
            payloadZone: payloadZone,
            makeTransport: {
                FakeCloudRecordTransport(
                    server: server, namespace: namespace,
                    automaticallyFetchedZones: [metadataZone]
                )
            }
        )

        let secondEnabled = try await secondCoordinator.enableOrRetry()

        XCTAssertEqual(secondEnabled.state, .on)
        let active = try await second.activeLibrary()
        let snapshot = try await active.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(snapshot.snips.map(\.id), [snip.id])
        XCTAssertEqual(snapshot.snips.first?.attachments.map(\.id), [attachment.id])
        let attachmentURL = try XCTUnwrap(snapshot.attachmentURLs[attachment.id])
        XCTAssertEqual(try Data(contentsOf: attachmentURL), bytes)
    }

    func testFullSetupRetryKeepsRemoteAttachmentAddedToAcknowledgedSnip() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root.appendingPathComponent("local"))
        let local = try await persistence.activeLibrary()
        try await add("accepted on first send", to: local)
        try await add("retry on next send", to: local)
        let initial = try await local.checkedSnapshot(sortedBy: .manual)
        let accepted = try XCTUnwrap(initial.snips.first { $0.content == "accepted on first send" })
        let failed = try XCTUnwrap(initial.snips.first { $0.content == "retry on next send" })
        let metadataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(),
            zones: [metadataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let firstTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await firstTransport.failNextSentItem(.snip(failed.id, in: metadataZone), failure: .retryable)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: metadataZone,
            payloadZone: payloadZone,
            makeTransport: { firstTransport }
        )
        let partial = try await coordinator.enableOrRetry()
        XCTAssertEqual(partial.state, .settingUp)

        let remote = try SwiftDataSyncModePersistence(rootURL: root.appendingPathComponent("remote"))
        let remoteCoordinator = ICloudSyncModeCoordinator(
            persistence: remote,
            namespace: namespace,
            textZone: metadataZone,
            payloadZone: payloadZone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let remoteEnabled = try await remoteCoordinator.enableOrRetry()
        XCTAssertEqual(remoteEnabled.state, .on)
        let remoteLibrary = try await remote.activeLibrary()
        let remoteSnapshot = try await remoteLibrary.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(remoteSnapshot.snips.map(\.id), [accepted.id])
        let bytes = Data("attached on the second device".utf8)
        let file = root.appendingPathComponent("remote.txt")
        try bytes.write(to: file)
        let edited = try await remoteLibrary.perform(
            .update(
                id: accepted.id,
                content: accepted.content,
                attachmentURLs: [file],
                expectedUpdatedAt: nil,
                now: accepted.updatedAt.addingTimeInterval(1)
            ),
            sortedBy: .manual
        )
        let attachment = try XCTUnwrap(edited.snapshot.snips.first?.attachments.first)
        let remoteSynced = try await remoteCoordinator.syncActive()
        XCTAssertEqual(remoteSynced.state, .on)

        let retry = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: metadataZone,
            payloadZone: payloadZone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let result = try await retry.enableOrRetry()

        XCTAssertEqual(result.state, .on, "\(result)")
        let active = try await persistence.activeLibrary()
        let final = try await active.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(final.snips.map(\.id)), [accepted.id, failed.id])
        let merged = try XCTUnwrap(final.snips.first { $0.id == accepted.id })
        XCTAssertEqual(merged.attachments.map(\.id), [attachment.id])
        let copiedURL = try XCTUnwrap(final.attachmentURLs[attachment.id])
        XCTAssertEqual(try Data(contentsOf: copiedURL), bytes)
    }

    func testFullSetupRetryDoesNotRestoreAttachmentRemovedAfterAcknowledgement() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let crash = CrashInjector(point: .beforePointerSwap)
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: crash.hit
        )
        let removedURL = root.appendingPathComponent("removed.txt")
        let keptURL = root.appendingPathComponent("kept.txt")
        let keptBytes = Data("attachment the user kept".utf8)
        try Data("attachment the user removed".utf8).write(to: removedURL)
        try keptBytes.write(to: keptURL)
        let local = try await persistence.activeLibrary()
        let added = try await local.perform(
            .add(
                content: "snip with two files",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [removedURL, keptURL],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        let removed = try XCTUnwrap(snip.attachments.first { $0.fileName == "removed.txt" })
        let kept = try XCTUnwrap(snip.attachments.first { $0.fileName == "kept.txt" })
        let metadataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(),
            zones: [metadataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: metadataZone,
            payloadZone: payloadZone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("Expected the interruption before switching to the iCloud store")
        } catch CrashInjector.Failure.injected {}
        let storage = try await persistence.snapshot()
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let transition = try XCTUnwrap(storage.transition)
        let candidate = try await persistence.libraryForTransition(storeID: transition.candidateStoreID)
        let publications = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
        let removedPublication = try XCTUnwrap(publications.publications.first {
            $0.metadata.attachmentID == removed.id
        })
        let removedPointerID = CloudAttachmentRecordCodec.recordID(removedPublication.metadataIdentity)
        let remotePointer = await server.fullSnapshot(for: removedPointerID)
        XCTAssertNotNil(remotePointer)

        // The retry may have only the remote pointer when the previous candidate copy is lost.
        try await candidate.quarantineCloudNamespaceState(namespaceKey: namespace.namespaceKey)
        let removeAttachment = SnipLibraryCommand.editAttachments(
            snipID: snip.id,
            content: snip.content,
            edits: [.existing(attachmentID: kept.id)],
            expectedUpdatedAt: nil,
            now: snip.updatedAt.addingTimeInterval(1)
        )
        _ = try await candidate.perform(removeAttachment, sortedBy: .manual)
        let removedPayloadID = CloudAttachmentRecordCodec.recordID(removedPublication.metadata.payloadIdentity)
        let remotePayload = await server.fullSnapshot(for: removedPayloadID)
        let payload = try XCTUnwrap(remotePayload)
        _ = try await FakeCloudRecordTransport(server: server, namespace: namespace).send(
            CloudOutboundBatch(operations: [.delete(removedPayloadID, base: payload.shadow)])
        )
        let unavailablePayload = await server.fullSnapshot(for: removedPayloadID)
        XCTAssertNil(unavailablePayload)

        _ = try await local.perform(removeAttachment, sortedBy: .manual)
        let result = try await coordinator.enableOrRetry()

        XCTAssertEqual(result.state, .on, "\(result)")
        let active = try await persistence.activeLibrary()
        let final = try await active.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [snip.id])
        XCTAssertEqual(final.snips.first?.attachments.map(\.id), [kept.id])
        let copiedURL = try XCTUnwrap(final.attachmentURLs[kept.id])
        XCTAssertEqual(try Data(contentsOf: copiedURL), keptBytes)
        let deletedPointer = await server.fullSnapshot(for: removedPointerID)
        XCTAssertNil(deletedPointer)
    }

    func testFullReenableUsesLocalAttachmentCopyWhenRemoteDownloadIsNotCached() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("kept attachment".utf8)
        let sourceURL = root.appendingPathComponent("attachment.txt")
        try bytes.write(to: sourceURL)
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            attachmentCacheRootURL: root.appendingPathComponent("Caches")
        )
        let local = try await persistence.activeLibrary()
        let added = try await local.perform(
            .add(
                content: "saved with attachment",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [sourceURL],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        let attachment = try XCTUnwrap(snip.attachments.first)
        let metadataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(),
            zones: [metadataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: metadataZone,
            payloadZone: payloadZone,
            makeTransport: {
                FakeCloudRecordTransport(
                    server: server,
                    namespace: namespace,
                    automaticallyFetchedZones: [metadataZone]
                )
            }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let optedOut = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(optedOut.state, .off)

        let reenableTransport = FakeCloudRecordTransport(
            server: server, namespace: namespace, automaticallyFetchedZones: [metadataZone]
        )
        await reenableTransport.failNextAssetFetch()
        let reenableCoordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: metadataZone,
            payloadZone: payloadZone,
            makeTransport: { reenableTransport }
        )
        let reenabled = try await reenableCoordinator.enableOrRetry()

        XCTAssertEqual(reenabled.state, .on)
        let storage = try await persistence.snapshot()
        let active = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
        let final = try await active.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [snip.id])
        XCTAssertEqual(final.snips.first?.content, "saved with attachment")
        XCTAssertEqual(final.snips.first?.attachments.map(\.id), [attachment.id])
        let copiedURL = try XCTUnwrap(final.attachmentURLs[attachment.id])
        XCTAssertEqual(try Data(contentsOf: copiedURL), bytes)
    }
}
