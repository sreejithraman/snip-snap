import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import Synchronization
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testSetupRetryKeepsLocalDeletionWhenPeerEditsAfterFetch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localRoot = root.appendingPathComponent("local")
        let persistence = try SwiftDataSyncModePersistence(rootURL: localRoot)
        let local = try await persistence.activeLibrary()
        try await add("acknowledged before setup stops", to: local)
        try await add("still needs an outbound save", to: local)
        let initial = try await local.checkedSnapshot(sortedBy: .manual)
        let deleted = try XCTUnwrap(initial.snips.first { $0.content == "acknowledged before setup stops" })
        let survivor = try XCTUnwrap(initial.snips.first { $0.id != deleted.id })
        let metadataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private", accountLineage: "account", generation: UUID(),
            zones: [metadataZone, payloadZone]
        )
        let deletedID = CloudRecordID.snip(deleted.id, in: metadataZone)
        let survivorID = CloudRecordID.snip(survivor.id, in: metadataZone)
        let server = FakeCloudServer()
        let firstTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await firstTransport.failNextSentItem(survivorID, failure: .retryable)
        let first = ICloudSyncModeCoordinator(
            persistence: persistence, namespace: namespace, textZone: metadataZone,
            payloadZone: payloadZone, makeTransport: { firstTransport }
        )
        let partial = try await first.enableOrRetry()
        XCTAssertEqual(partial.state, .settingUp)
        let key = CloudSetupRetryRecordKey(
            reference: CloudEntityReference(kind: .snip, domainID: deleted.id),
            identity: CloudFullSyncPersistence.storageIdentity(deletedID)
        )
        let evidence = await persistence.setupRetryEvidence(namespace: namespace.binding)
        _ = try XCTUnwrap(evidence?.baseline(for: key))
        let peer = try SwiftDataSyncModePersistence(rootURL: root.appendingPathComponent("peer"))
        let peerCoordinator = ICloudSyncModeCoordinator(
            persistence: peer, namespace: namespace, textZone: metadataZone, payloadZone: payloadZone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let peerEnabled = try await peerCoordinator.enableOrRetry()
        XCTAssertEqual(peerEnabled.state, .on)
        let peerLibrary = try await peer.activeLibrary()
        let bytes = Data("the peer's attachment bytes".utf8)
        let file = root.appendingPathComponent("peer.txt")
        try bytes.write(to: file)
        let attached = try await peerLibrary.perform(
            .update(
                id: deleted.id, content: deleted.content, attachmentURLs: [file],
                expectedUpdatedAt: nil, now: deleted.updatedAt.addingTimeInterval(1)
            ),
            sortedBy: .manual
        )
        let attachment = try XCTUnwrap(attached.snapshot.snips.first?.attachments.first)
        let attachmentSynced = try await peerCoordinator.syncActive()
        XCTAssertEqual(attachmentSynced.state, .on)
        let metadataID = CloudRecordID(zone: metadataZone, name: "a-\(attachment.id.uuidString.lowercased())")
        let published = await server.fullSnapshot(for: metadataID)
        let pointer = try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(published))
        let payloadID = CloudAttachmentRecordCodec.recordID(pointer.payloadIdentity)
        // A previously fetched pointer whose parent has not arrived
        // distinguishes read-only checks from outbound reconciliation.
        let unmaterialized = CloudAttachmentMetadataValue(
            attachmentID: UUID(), snipID: UUID(), position: 0, fileName: "unmaterialized.txt",
            contentType: pointer.contentType, byteCount: pointer.byteCount, sha256: pointer.sha256,
            payloadIdentity: CloudTextStorageIdentity(
                zoneName: payloadZone.name, ownerName: payloadZone.ownerName,
                recordName: UUID().uuidString.lowercased()
            )
        )
        let unmaterializedID = CloudRecordID(
            zone: metadataZone, name: "a-\(unmaterialized.attachmentID.uuidString.lowercased())"
        )
        let orphan = CloudAttachmentPublication(
            metadata: unmaterialized, metadataIdentity: CloudAttachmentRecordCodec.identity(unmaterializedID),
            sourceURL: nil, payloadAccepted: false, payloadShadowData: nil,
            metadataAccepted: false, metadataShadowData: nil, revision: 0
        )
        let peerWriter = FakeCloudRecordTransport(server: server, namespace: namespace)

        let retryTransport = FakeCloudRecordTransport(
            server: server, namespace: namespace, automaticallyFetchedZones: [metadataZone]
        )
        await retryTransport.pauseNextFetch()
        let observedTransport = SetupRetryDeleteProbeTransport(retryTransport)
        let eventsBeforePeerEdit = Mutex<[FakeCloudTransportEvent]?>(nil)
        let peerText = "edited by the peer after retry fetched"
        let reopened = try SwiftDataSyncModePersistence(rootURL: localRoot, readHook: {
            let events = await retryTransport.events()
            // Managed reads can call the hook earlier. The frozen source read
            // is after fetch confirmation and before the first outbound batch.
            guard events.contains(.fetched), case .confirmed? = events.last else { return }
            let firstRead = eventsBeforePeerEdit.withLock { captured in
                guard captured == nil else { return false }
                captured = events
                return true
            }
            guard firstRead else { return }
            _ = try await peerLibrary.perform(
                .update(
                    id: deleted.id, content: peerText, attachmentURLs: nil,
                    expectedUpdatedAt: nil, now: deleted.updatedAt.addingTimeInterval(2)
                ),
                sortedBy: .manual
            )
            let peerSynced = try await peerCoordinator.syncActive()
            XCTAssertEqual(peerSynced.state, .on)
        })
        let before = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(before.snips.map(\.id)), [deleted.id, survivor.id])
        let reopenedEvidence = await reopened.setupRetryEvidence(namespace: namespace.binding)
        XCTAssertEqual(reopenedEvidence?.baseline(for: key), evidence?.baseline(for: key))

        let retry = ICloudSyncModeCoordinator(
            persistence: reopened, namespace: namespace, textZone: metadataZone, payloadZone: payloadZone,
            makeTransport: { observedTransport }
        )
        let initialStorage = try await reopened.snapshot()
        let candidateID = try XCTUnwrap(initialStorage.transition?.candidateStoreID)
        let candidate = try await reopened.libraryForTransition(storeID: candidateID)
        let orphanRecord = try CloudKitRecordMapper.record(for: CloudAttachmentRecordCodec.metadataDraft(orphan))
        let orphanShadow = try CloudKitRecordMapper.snapshot(orphanRecord).shadow
        try await candidate.commitCloudAttachmentTransitions(
            namespaceKey: namespace.namespaceKey,
            transitions: [.remoteMetadataAccepted(
                metadata: unmaterialized, metadataIdentity: orphan.metadataIdentity,
                shadowData: orphanShadow.data, systemFields: orphanShadow.systemFields
            )]
        )
        let oldState = try await candidate.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let savedToken = try JSONDecoder().decode(
            CloudEngineStateEnvelope.self, from: XCTUnwrap(oldState.engineState)
        )
        XCTAssertFalse(savedToken.requiresInitialFetch)
        let enabling = Task { try await retry.enableOrRetry() }
        await retryTransport.waitUntilFetchPauses()
        do {
            let editable = try await reopened.activeLibrary()
            _ = try await editable.perform(.delete(ids: [deleted.id]), sortedBy: .manual)
        } catch {
            await retryTransport.resumeFetch()
            _ = try? await enabling.value
            throw error
        }
        await retryTransport.resumeFetch()
        let status = try await enabling.value

        let atPeerEdit = try XCTUnwrap(eventsBeforePeerEdit.withLock { $0 })
        let events = await retryTransport.events()
        XCTAssertEqual(Array(events.prefix(atPeerEdit.count)), atPeerEdit)
        let suppliedIDs = events.dropFirst(atPeerEdit.count).flatMap { event -> [CloudRecordID] in
            guard case .sent(let ids) = event else { return [] }
            return ids
        }
        XCTAssertFalse(atPeerEdit.contains { event in
            if case .sent = event { return true }
            return false
        })
        XCTAssertTrue(suppliedIDs.isEmpty, "A hold must also withhold the survivor's save.")
        XCTAssertFalse(events.contains { if case .sent = $0 { return true }; return false })
        let resumed = await observedTransport.resumed
        let initialOutbound = await observedTransport.receivedInitialOutbound
        XCTAssertTrue(resumed)
        XCTAssertFalse(initialOutbound)
        let deletes = await observedTransport.suppliedDeleteIDs
        XCTAssertEqual(deletes.intersection([deletedID, metadataID, payloadID]), [])

        let stored = await server.fullSnapshot(for: deletedID)
        XCTAssertEqual(try CloudFullRecordCodec.snip(from: XCTUnwrap(stored)).text, .value(peerText))
        let finalPointer = await server.fullSnapshot(for: metadataID)
        XCTAssertEqual(try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(finalPointer)), pointer)
        let payload = await server.asset(for: payloadID, field: CloudAttachmentRecordCodec.assetField)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(payload)), bytes)
        let storage = try await reopened.snapshot()
        XCTAssertEqual(status.state, .needsAttention)
        XCTAssertEqual(storage.activeStore.id, initialStorage.activeStore.id)
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        XCTAssertEqual(storage.transition?.phase, .candidateReady)
        let attachmentStorage = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(attachmentStorage.cleanups.isEmpty)
        let publications = Dictionary(uniqueKeysWithValues: attachmentStorage.publications.map {
            ($0.metadata.attachmentID, $0)
        })
        XCTAssertEqual(publications[attachment.id]?.metadata, pointer)
        XCTAssertEqual(publications[unmaterialized.attachmentID]?.isLocallyPresent, true)
        let candidateState = try await candidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(candidateState.pendingDeletes.isEmpty)
        let final = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [survivor.id], "Retry silently restored the deleted snip.")

        // A parent may be gone while its pointer or immutable payload remains.
        // Its cached attachment must neither promote a recovered snip nor
        // schedule a payload cleanup ahead of a user-approved restart.
        let parentRemoval = try await peerWriter.send(CloudOutboundBatch(operations: [
            .delete(deletedID, base: XCTUnwrap(stored).shadow)
        ]))
        guard case .deleted? = parentRemoval.items.first else {
            return XCTFail("The peer must remove the parent record.")
        }
        try await peerWriter.confirmApplied(parentRemoval.id)
        let oldFetch = FakeCloudRecordTransport(
            server: server, namespace: namespace, automaticallyFetchedZones: [metadataZone]
        )
        try await oldFetch.start(state: nil)
        let fetched = try await oldFetch.fetch(scope: .zones([metadataZone]))
        XCTAssertTrue(fetched.items.contains { if case .deleted(deletedID) = $0 { return true }; return false })
        let oldPersistence = CloudFullSyncPersistence(
            library: candidate, namespace: namespace, dataZone: metadataZone, payloadZone: payloadZone
        )
        try await oldPersistence.stage(.fetched(fetched))
        let later = try SwiftDataSyncModePersistence(rootURL: localRoot)
        let staleTransport = FakeCloudRecordTransport(
            server: server, namespace: namespace, automaticallyFetchedZones: [metadataZone]
        )
        let stale = ICloudSyncModeCoordinator(
            persistence: later, namespace: namespace, textZone: metadataZone, payloadZone: payloadZone,
            makeTransport: { staleTransport }
        )
        let staleStatus = try await stale.enableOrRetry()
        XCTAssertEqual(staleStatus.state, .needsAttention)
        let staleEvents = await staleTransport.events()
        XCTAssertEqual(staleEvents, [.started, .fetched])
        let heldStorage = try await later.snapshot()
        XCTAssertEqual(heldStorage.transition?.candidateStoreID, candidateID)
        XCTAssertEqual(heldStorage.transition?.phase, .candidateReady)
        let heldCandidate = try await later.libraryForTransition(storeID: candidateID)
        let staged = try await heldCandidate.stagedCloudFullBatches(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(staged.isEmpty)
        let heldAttachments = try await heldCandidate.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(heldAttachments, attachmentStorage)
        let review = try await heldCandidate.recoverySnapshot(in: SnipRecoveryScope(namespace.namespaceKey.rawValue))
        XCTAssertTrue(review.promotedSnips.isEmpty)

        let pointerRemoval = try await peerWriter.send(CloudOutboundBatch(operations: [
            .delete(metadataID, base: XCTUnwrap(finalPointer).shadow)
        ]))
        XCTAssertEqual(pointerRemoval.items, [.deleted(metadataID)])
        try await peerWriter.confirmApplied(pointerRemoval.id)
        try await later.cancelPendingICloudEnable()
        let fresh = ICloudSyncModeCoordinator(
            persistence: later, namespace: namespace, textZone: metadataZone, payloadZone: payloadZone,
            makeTransport: {
                FakeCloudRecordTransport(
                    server: server, namespace: namespace, automaticallyFetchedZones: [metadataZone]
                )
            }
        )
        let freshStatus = try await fresh.enableOrRetry()
        XCTAssertEqual(freshStatus.state, .on)
        let finalLibrary = try await later.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(finalLibrary.snips.map(\.id), [survivor.id])
        let survivingPayload = await server.asset(for: payloadID, field: CloudAttachmentRecordCodec.assetField)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(survivingPayload)), bytes)
        let deletionCount = await server.acceptedDeletionCount()
        XCTAssertEqual(deletionCount, 2, "Only the peer sent a deletion.")
    }

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
        let beforeReorder = try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(sentPointer))

        let peerRefreshed = try await peerCoordinator.syncActive()
        XCTAssertEqual(peerRefreshed.state, .on)
        _ = try await peerLibrary.perform(
            .editAttachments(
                snipID: snip.id, content: snip.content,
                edits: (remoteIDs + [removed.id]).map { .existing(attachmentID: $0) },
                expectedUpdatedAt: nil, now: snip.updatedAt.addingTimeInterval(3)
            ),
            sortedBy: .manual
        )
        let peerReordered = try await peerCoordinator.syncActive()
        XCTAssertEqual(peerReordered.state, .on)
        let reorderedPointer = await server.fullSnapshot(for: pointerID(removed.id))
        XCTAssertEqual(reorderedPointer?.id, sentPointer?.id)
        let afterReorder = try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(reorderedPointer))
        XCTAssertNotEqual(afterReorder.position, beforeReorder.position)
        XCTAssertEqual(afterReorder.attachmentID, beforeReorder.attachmentID)
        XCTAssertEqual(afterReorder.snipID, beforeReorder.snipID)
        XCTAssertEqual(afterReorder.payloadIdentity, beforeReorder.payloadIdentity)
        XCTAssertEqual(afterReorder.sha256, beforeReorder.sha256)

        let reopened = try SwiftDataSyncModePersistence(rootURL: localRoot)
        try await reopened.cancelPendingICloudEnable()
        let source = try await reopened.activeLibrary()
        _ = try await source.perform(
            .editAttachments(
                snipID: snip.id, content: snip.content, edits: [], expectedUpdatedAt: nil,
                now: snip.updatedAt.addingTimeInterval(4)
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

actor SetupRetryDeleteProbeTransport: CloudRecordTransport {
    let fake: FakeCloudRecordTransport
    let omitFetchCompletion: Bool
    private(set) var resumed = false
    private(set) var receivedInitialOutbound = false
    private(set) var suppliedDeleteIDs: Set<CloudRecordID> = []

    init(_ fake: FakeCloudRecordTransport, omitFetchCompletion: Bool = false) {
        self.fake = fake
        self.omitFetchCompletion = omitFetchCompletion
    }

    func start(state: CloudEngineStateEnvelope?) async throws {
        if state != nil { resumed = true }
        try await fake.start(state: state)
    }

    func start(
        state: CloudEngineStateEnvelope?, initialOutbound: CloudOutboundBatch?,
        outboundAdmission: CloudRecordOutboundAdmission
    ) async throws {
        if initialOutbound != nil { receivedInitialOutbound = true }
        try await start(state: state)
    }

    func reset() async {
        await fake.reset()
    }

    func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
        let batch = try await fake.fetch(scope: scope)
        guard omitFetchCompletion else { return batch }
        return CloudFetchedBatch(
            id: batch.id, items: batch.items, databaseEvents: batch.databaseEvents,
            zoneEvents: [], engineState: batch.engineState, isInitialFetch: batch.isInitialFetch
        )
    }

    func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
        // The production provider submits only the IDs of these deletes.
        for case .delete(let id, _) in batch.operations {
            suppliedDeleteIDs.insert(id)
        }
        return try await fake.send(batch)
    }

    func confirmApplied(_ batchID: UUID) async throws {
        try await fake.confirmApplied(batchID)
    }

    func fetchRecord(_ id: CloudRecordID, fields: Set<String>) async throws -> CloudRecordSnapshot? {
        try await fake.fetchRecord(id, fields: fields)
    }

    func fetchAsset(
        _ id: CloudRecordID, field: String, destination: CloudAssetDestination
    ) async throws -> CloudAssetReceipt? {
        try await fake.fetchAsset(id, field: field, destination: destination)
    }
}
