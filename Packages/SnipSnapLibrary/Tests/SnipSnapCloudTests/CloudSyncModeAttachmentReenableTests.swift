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
            makeTransport: {
                FakeCloudRecordTransport(
                    server: server, namespace: namespace, automaticallyFetchedZones: [metadataZone]
                )
            }
        )
        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("Expected the interruption before switching to the iCloud store")
        } catch CrashInjector.Failure.injected {}
        let storage = try await persistence.snapshot()
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let transition = try XCTUnwrap(storage.transition)
        XCTAssertEqual(transition.phase, .candidateReady)
        let candidate = try await persistence.libraryForTransition(storeID: transition.candidateStoreID)
        let publications = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
        let removedPublication = try XCTUnwrap(publications.publications.first {
            $0.metadata.attachmentID == removed.id
        })
        let removedPointerID = CloudAttachmentRecordCodec.recordID(removedPublication.metadataIdentity)
        let removedPayloadID = CloudAttachmentRecordCodec.recordID(removedPublication.metadata.payloadIdentity)
        let remotePayload = await server.fullSnapshot(for: removedPayloadID)
        let payload = try XCTUnwrap(remotePayload)
        _ = try await FakeCloudRecordTransport(server: server, namespace: namespace).send(
            CloudOutboundBatch(operations: [.delete(removedPayloadID, base: payload.shadow)])
        )
        let unavailablePayload = await server.fullSnapshot(for: removedPayloadID)
        XCTAssertNil(unavailablePayload)
        let remotePointer = await server.fullSnapshot(for: removedPointerID)
        XCTAssertNotNil(remotePointer)

        let listedCandidate = await persistence.store(id: transition.candidateStoreID)
        let candidateStore = try XCTUnwrap(listedCandidate)
        let candidateRoot = await persistence.storeURL(candidateStore)
        try FileManager.default.removeItem(at: candidateRoot)
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let beforeRetry = try await reopened.snapshot()
        XCTAssertEqual(beforeRetry.activeStore.id, transition.sourceStoreID)
        XCTAssertEqual(beforeRetry.transition?.phase, .candidateReady)
        let retryEvidence = await reopened.setupRetryEvidence(namespace: namespace.binding)
        let snipKey = CloudSetupRetryRecordKey(
            reference: CloudEntityReference(kind: .snip, domainID: snip.id),
            identity: CloudFullSyncPersistence.storageIdentity(.snip(snip.id, in: metadataZone))
        )
        let baseline = try XCTUnwrap(retryEvidence?.baseline(for: snipKey))
        let frozen = try JSONDecoder().decode(CloudSnipMergeFields.self, from: baseline.sourceFields)
        XCTAssertEqual(frozen.setupSourceAttachmentIDs, [removed.id, kept.id])

        let source = try await reopened.activeLibrary()
        let edited = try await source.perform(
            .editAttachments(
                snipID: snip.id,
                content: snip.content,
                edits: [.existing(attachmentID: kept.id)],
                expectedUpdatedAt: nil,
                now: snip.updatedAt.addingTimeInterval(1)
            ),
            sortedBy: .manual
        )
        XCTAssertEqual(edited.snapshot.snips.first?.attachments.map(\.id), [kept.id])
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: metadataZone,
            payloadZone: payloadZone,
            makeTransport: {
                FakeCloudRecordTransport(
                    server: server, namespace: namespace, automaticallyFetchedZones: [metadataZone]
                )
            }
        )
        let result = try await retry.enableOrRetry()

        XCTAssertEqual(result.state, .on, "\(result)")
        let active = try await reopened.activeLibrary()
        let final = try await active.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [snip.id])
        XCTAssertEqual(final.snips.first?.attachments.map(\.id), [kept.id])
        let copiedURL = try XCTUnwrap(final.attachmentURLs[kept.id])
        XCTAssertEqual(try Data(contentsOf: copiedURL), keptBytes)
        let deletedPointer = await server.fullSnapshot(for: removedPointerID)
        XCTAssertNil(deletedPointer)
    }

    func testFullSetupRetryKeepsRemovalOfSeparatelyAcknowledgedAttachment() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private", accountLineage: "account", generation: UUID(),
            zones: [metadataZone, payloadZone]
        )
        let server = FakeCloudServer()
        func makeTransport() -> FakeCloudRecordTransport {
            FakeCloudRecordTransport(
                server: server, namespace: namespace, automaticallyFetchedZones: [metadataZone]
            )
        }
        func coordinator(
            _ persistence: SwiftDataSyncModePersistence, transport: FakeCloudRecordTransport
        ) -> ICloudSyncModeCoordinator {
            ICloudSyncModeCoordinator(
                persistence: persistence, namespace: namespace, textZone: metadataZone,
                payloadZone: payloadZone, makeTransport: { transport }
            )
        }
        func pointerID(_ attachmentID: UUID) -> CloudRecordID {
            CloudRecordID(zone: metadataZone, name: "a-\(attachmentID.uuidString.lowercased())")
        }

        let localRoot = root.appendingPathComponent("local")
        let crash = CrashInjector(point: .beforePointerSwap)
        let persistence = try SwiftDataSyncModePersistence(rootURL: localRoot, crashHook: crash.hit)
        let local = try await persistence.activeLibrary()
        try await add("acknowledged snip", to: local)
        try await add("interrupted seed", to: local)
        let initial = try await local.checkedSnapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(initial.snips.first { $0.content == "acknowledged snip" })
        let interrupted = try XCTUnwrap(initial.snips.first { $0.content == "interrupted seed" })
        let snipRecordID = CloudRecordID.snip(snip.id, in: metadataZone)
        let firstTransport = makeTransport()
        await firstTransport.failNextSentItem(.snip(interrupted.id, in: metadataZone), failure: .retryable)
        let first = try await coordinator(persistence, transport: firstTransport).enableOrRetry()
        XCTAssertEqual(first.state, .settingUp)
        let acknowledged = await server.fullSnapshot(for: snipRecordID)
        XCTAssertNotNil(acknowledged)

        let localFile = root.appendingPathComponent("remove.txt")
        try Data("local attachment to remove".utf8).write(to: localFile)
        let added = try await local.perform(
            .editAttachments(
                snipID: snip.id, content: snip.content, edits: [.added(sourceURL: localFile)],
                expectedUpdatedAt: snip.updatedAt, now: snip.updatedAt.addingTimeInterval(1)
            ),
            sortedBy: .manual
        )
        let removed = try XCTUnwrap(added.snapshot.snips.first { $0.id == snip.id }?.attachments.first)

        let peer = try SwiftDataSyncModePersistence(rootURL: root.appendingPathComponent("peer"))
        let peerCoordinator = coordinator(peer, transport: makeTransport())
        let peerEnabled = try await peerCoordinator.enableOrRetry()
        XCTAssertEqual(peerEnabled.state, .on)
        let peerLibrary = try await peer.activeLibrary()
        let remoteBytes = [Data("peer first attachment".utf8), Data("peer second attachment".utf8)]
        let remoteFiles = try remoteBytes.enumerated().map { index, bytes in
            let url = root.appendingPathComponent("peer-\(index).txt")
            try bytes.write(to: url)
            return url
        }
        let peerEdited = try await peerLibrary.perform(
            .editAttachments(
                snipID: snip.id, content: snip.content,
                edits: remoteFiles.map { .added(sourceURL: $0) },
                expectedUpdatedAt: nil, now: snip.updatedAt.addingTimeInterval(2)
            ),
            sortedBy: .manual
        )
        let remoteIDs = try XCTUnwrap(peerEdited.snapshot.snips.first?.attachments.map(\.id))
        XCTAssertEqual(remoteIDs.count, remoteBytes.count)
        let peerSynced = try await peerCoordinator.syncActive()
        XCTAssertEqual(peerSynced.state, .on)

        let secondTransport = makeTransport()
        do {
            _ = try await coordinator(persistence, transport: secondTransport).enableOrRetry()
            XCTFail("Expected the second setup attempt to stop before activation")
        } catch CrashInjector.Failure.injected {}
        let secondSends = await secondTransport.events().flatMap { event -> [CloudRecordID] in
            if case .sent(let ids) = event { return ids }
            return []
        }
        XCTAssertTrue(secondSends.contains(pointerID(removed.id)))
        XCTAssertFalse(secondSends.contains(snipRecordID))
        let sentPointer = await server.fullSnapshot(for: pointerID(removed.id))
        XCTAssertNotNil(sentPointer)

        let reopened = try SwiftDataSyncModePersistence(rootURL: localRoot)
        let source = try await reopened.activeLibrary()
        _ = try await source.perform(
            .editAttachments(
                snipID: snip.id, content: snip.content, edits: [], expectedUpdatedAt: nil,
                now: snip.updatedAt.addingTimeInterval(3)
            ),
            sortedBy: .manual
        )
        let result = try await coordinator(reopened, transport: makeTransport()).enableOrRetry()

        XCTAssertEqual(result.state, .on)
        let active = try await reopened.activeLibrary()
        let final = try await active.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(final.snips.map(\.id)), [snip.id, interrupted.id])
        let merged = try XCTUnwrap(final.snips.first { $0.id == snip.id })
        XCTAssertEqual(Set(merged.attachments.map(\.id)), Set(remoteIDs))
        XCTAssertNil(final.attachmentURLs[removed.id])
        let removedPointer = await server.fullSnapshot(for: pointerID(removed.id))
        XCTAssertNil(removedPointer)
        for (id, bytes) in zip(remoteIDs, remoteBytes) {
            let localURL = try XCTUnwrap(final.attachmentURLs[id])
            XCTAssertEqual(try Data(contentsOf: localURL), bytes)
            let pointer = await server.fullSnapshot(for: pointerID(id))
            let metadata = try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(pointer))
            let asset = await server.asset(
                for: CloudAttachmentRecordCodec.recordID(metadata.payloadIdentity),
                field: CloudAttachmentRecordCodec.assetField
            )
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(asset)), bytes)
        }
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
