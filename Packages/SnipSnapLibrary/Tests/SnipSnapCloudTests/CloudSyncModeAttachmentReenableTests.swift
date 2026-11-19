import CryptoKit
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import Synchronization
import XCTest

extension ICloudSyncModeCoordinatorTests {
    @MainActor
    func testSetupRetryKeepsLocalDeletionWhenPeerEditsAfterFetch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localRoot = root.appendingPathComponent("local")
        let persistence = try SwiftDataSyncModePersistence(rootURL: localRoot)
        let local = try await persistence.activeLibrary()
        for content in ["acknowledged before setup stops", "still needs an outbound save"] {
            _ = try await local.perform(
                .add(
                    content: content, origin: .quickEntry, source: nil, listID: SnipList.inboxID,
                    attachmentURLs: [], requestID: UUID(), now: Date()
                ),
                sortedBy: .manual
            )
        }
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
        let descriptor = CloudCollectionDescriptor(
            generation: namespace.generation, metadataZone: metadataZone, payloadZone: payloadZone
        )
        await server.seedControl(descriptor)
        let legacySource = try JSONSnipLibrary(fileURL: root.appendingPathComponent("legacy.json"))
        func settings(
            persistence: SwiftDataSyncModePersistence,
            transport: FakeCloudRecordTransport
        ) -> SyncedContentSettingsModel {
            let lifecycle = SnipSnapICloudSyncLifecycle(
                rootURL: localRoot,
                sourceLibrary: legacySource,
                syncModeStore: SnipSyncModeStore(persistence),
                cloudScope: "private", accountLineage: "account", ownerName: "owner",
                controlTransport: FakeCloudControlTransport(server: server),
                makeRecordTransport: { _ in transport },
                makeDescriptor: { descriptor }
            )
            let startup = SnipSnapCloudAppAssembly.settingsStartupState(
                rootURL: localRoot,
                startupState: SyncModeActivationManifestReader.iCloudStartupState(
                    atSyncModeRootURL: localRoot
                )
            )
            return SyncedContentSettingsModel(
                mode: startup.mode,
                initialState: startup.state,
                issueMapper: SnipSnapCloudSyncIssueMapper.issue(for:),
                enableAction: { try await lifecycle.enableICloudSync() },
                cancelEnableAction: { try await lifecycle.cancelPendingEnable() },
                hasFailedPendingEnable: { SnipSnapCloudAppAssembly.hasPendingSetup(rootURL: localRoot) }
            )
        }
        let heldSettings = settings(persistence: later, transport: staleTransport)
        await heldSettings.enableICloudSync()
        XCTAssertEqual(heldSettings.state, .failed(.appDataIssue))
        XCTAssertTrue(heldSettings.canCancelEnable)
        XCTAssertTrue(heldSettings.isSyncRequested)
        XCTAssertTrue(heldSettings.canEnable)
        XCTAssertTrue(heldSettings.canRetryFailedSync)
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
        let afterRestart = try SwiftDataSyncModePersistence(rootURL: localRoot)
        let freshTransport = FakeCloudRecordTransport(
            server: server, namespace: namespace, automaticallyFetchedZones: [metadataZone]
        )
        let restartedSettings = settings(persistence: afterRestart, transport: freshTransport)
        XCTAssertEqual(restartedSettings.state, .failed(.appDataIssue))
        XCTAssertTrue(restartedSettings.canCancelEnable)
        XCTAssertTrue(restartedSettings.isSyncRequested)
        await restartedSettings.cancelICloudSyncSetup()
        XCTAssertEqual(restartedSettings.mode, .localOnly)
        XCTAssertEqual(restartedSettings.state, .ready)
        XCTAssertFalse(restartedSettings.canCancelEnable)
        XCTAssertFalse(restartedSettings.isSyncRequested)
        let cancelled = try await afterRestart.snapshot()
        XCTAssertNil(cancelled.transition)
        XCTAssertEqual(cancelled.activeStore.id, initialStorage.activeStore.id)
        let retained = await afterRestart.setupRetryEvidence(namespace: namespace.binding)
        XCTAssertEqual(retained?.baseline(for: key), evidence?.baseline(for: key))
        await restartedSettings.enableICloudSync()
        XCTAssertEqual(restartedSettings.mode, .iCloudSync)
        XCTAssertEqual(restartedSettings.state, .ready)
        let finalLibrary = try await afterRestart.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(finalLibrary.snips.map(\.id), [survivor.id])
        let survivingPayload = await server.asset(for: payloadID, field: CloudAttachmentRecordCodec.assetField)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(survivingPayload)), bytes)
        let deletionCount = await server.acceptedDeletionCount()
        XCTAssertEqual(deletionCount, 2, "Only the peer sent a deletion.")
    }

    func testSetupRetrySerializesSourceDeletionWithFetchedPointerCommit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await initial.activeLibrary()
        try await add("acknowledged", to: source)
        try await add("unsent", to: source)
        let original = try await source.checkedSnapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(original.snips.first { $0.content == "acknowledged" })
        let survivor = try XCTUnwrap(original.snips.first { $0.id != snip.id })
        let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
        let zone = descriptor.metadataZone
        let payloadZone = descriptor.payloadZone
        let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account")
        let snipID = CloudRecordID.snip(snip.id, in: zone)
        let server = FakeCloudServer()
        let firstTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await firstTransport.failNextSentItem(.snip(survivor.id, in: zone), failure: .retryable)
        let first = ICloudSyncModeCoordinator(
            persistence: initial, namespace: namespace, textZone: zone, payloadZone: payloadZone,
            makeTransport: { firstTransport }
        )
        let partial = try await first.enableOrRetry()
        XCTAssertEqual(partial.state, .settingUp)

        let attachmentID = UUID()
        let metadataID = CloudRecordID(zone: zone, name: "a-\(attachmentID.uuidString.lowercased())")
        let payloadID = CloudRecordID(zone: payloadZone, name: UUID().uuidString.lowercased())
        let bytes = Data("independently uploaded payload".utf8)
        let file = root.appendingPathComponent("peer.txt")
        try bytes.write(to: file)
        let metadata = CloudAttachmentMetadataValue(
            attachmentID: attachmentID, snipID: snip.id, position: 0, fileName: "peer.txt",
            contentType: "text/plain", byteCount: Int64(bytes.count),
            sha256: Data(SHA256.hash(data: bytes)),
            payloadIdentity: CloudAttachmentRecordCodec.identity(payloadID)
        )
        let publication = CloudAttachmentPublication(
            metadata: metadata, metadataIdentity: CloudAttachmentRecordCodec.identity(metadataID),
            sourceURL: file, payloadAccepted: true, payloadShadowData: nil,
            metadataAccepted: false, metadataShadowData: nil, revision: 0
        )
        _ = try await server.send(CloudOutboundBatch(operations: [
            .save(CloudAttachmentRecordCodec.payloadDraft(publication)),
            .save(CloudAttachmentRecordCodec.metadataDraft(publication))
        ]), failures: [:])
        let pointer = await server.fullSnapshot(for: metadataID)
        let shadow = try XCTUnwrap(pointer).shadow
        let storage = try await initial.snapshot()
        let candidateID = try XCTUnwrap(storage.transition?.candidateStoreID)
        let candidate = try await initial.libraryForTransition(storeID: candidateID)
        try await candidate.commitCloudAttachmentTransitions(
            namespaceKey: namespace.namespaceKey,
            transitions: [.remoteMetadataAccepted(
                metadata: metadata, metadataIdentity: publication.metadataIdentity,
                shadowData: shadow.data, systemFields: shadow.systemFields
            )]
        )
        let removal = try await server.send(
            CloudOutboundBatch(operations: [.delete(metadataID, base: shadow)]), failures: [:]
        )
        XCTAssertEqual(removal.items, [.deleted(metadataID)])
        let fake = FakeCloudRecordTransport(server: server, namespace: namespace)
        let probe = SetupRetryDeleteProbeTransport(fake, interruptConfirmation: true)
        let armSave = Mutex(false)
        let racingSource = Mutex<(any SnipLibrary)?>(nil)
        let deletionWasBlocked = Mutex<Bool?>(nil)
        let reopened = try SwiftDataSyncModePersistence(
            rootURL: root,
            readHook: {
                guard deletionWasBlocked.withLock({ $0 == nil }),
                    try await candidate.stagedCloudFullBatches(namespaceKey: namespace.namespaceKey)
                        .contains(where: { $0.attachmentTransitions.contains(.remoteMetadataDeleted(
                            metadataIdentity: publication.metadataIdentity
                        )) })
                else { return }
                armSave.withLock { $0 = true }
            },
            afterMutationBeforeSave: {
                let armed = armSave.withLock { armed in
                    defer { armed = false }
                    return armed
                }
                guard armed, let editable = racingSource.withLock({ $0 }) else { return }
                // This is the save of the staged pointer tombstone, after the source
                // check. The two stores have distinct file locks.
                let finished = DispatchSemaphore(value: 0)
                Task.detached {
                    defer { finished.signal() }
                    do {
                        _ = try await editable.perform(.delete(ids: [snip.id]), sortedBy: .manual)
                        deletionWasBlocked.withLock { $0 = false }
                    } catch SnipLibraryError.modeTransitionInProgress {
                        deletionWasBlocked.withLock { $0 = true }
                    } catch {
                        deletionWasBlocked.withLock { $0 = false }
                    }
                }
                guard finished.wait(timeout: .now() + 15) == .success else {
                    throw CloudTransportError.fetchFailed
                }
            }
        )
        let editable = try await reopened.activeLibrary()
        racingSource.withLock { $0 = editable }
        defer { racingSource.withLock { $0 = nil } }
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened, namespace: namespace, textZone: zone, payloadZone: payloadZone,
            makeTransport: { probe }
        )
        let paused = try await retry.enableOrRetry()
        XCTAssertNotEqual(paused.state, .on)
        XCTAssertEqual(deletionWasBlocked.withLock { $0 }, true)
        let firstIntents = await probe.suppliedDeleteIDs
        XCTAssertTrue(firstIntents.isEmpty)

        let later = try SwiftDataSyncModePersistence(rootURL: root)
        let stillEditable = try await later.activeLibrary()
        let beforeDelete = try await stillEditable.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(beforeDelete.snips.map(\.id)), [snip.id, survivor.id])
        let durableCandidate = try await later.libraryForTransition(storeID: candidateID)
        let ledger = try await durableCandidate.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(ledger.cleanups.map(\.identity), [metadata.payloadIdentity])
        XCTAssertTrue(ledger.publications.isEmpty)
        _ = try await stillEditable.perform(.delete(ids: [snip.id]), sortedBy: .manual)
        let nextProbe = SetupRetryDeleteProbeTransport(FakeCloudRecordTransport(server: server, namespace: namespace))
        let next = ICloudSyncModeCoordinator(
            persistence: later, namespace: namespace, textZone: zone, payloadZone: payloadZone,
            makeTransport: { nextProbe }
        )
        let held = try await next.enableOrRetry()
        XCTAssertEqual(held.state, .needsAttention)
        let unchangedLedger = try await durableCandidate.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(unchangedLedger, ledger)
        let heldDeletes = await nextProbe.suppliedDeleteIDs
        XCTAssertTrue(heldDeletes.isEmpty)
        let peer = await server.fullSnapshot(for: snipID)
        XCTAssertNotNil(peer)
        let payload = await server.asset(for: payloadID, field: CloudAttachmentRecordCodec.assetField)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(payload)), bytes)
        let final = try await stillEditable.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [survivor.id])
    }

    func testSetupRetryRejectsUnrelatedPointerCleanupFromFreshAndStagedFetch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await setupRetryPointerFixture(root: root, pointerOnDeletedSnip: false)
        let pointerDelete = CloudOutboundBatch(operations: [.delete(fixture.pointerID, base: fixture.shadow)])
        let removed = try await fixture.server.send(pointerDelete, failures: [:])
        XCTAssertEqual(removed.items, [.deleted(fixture.pointerID)])

        let fake = fixture.transport()
        let probe = SetupRetryDeleteProbeTransport(fake)
        await fake.pauseNextFetch()
        let source = try await fixture.persistence.activeLibrary()
        let retry = fixture.coordinator(fixture.persistence, transport: probe)
        let retrying = Task { try await retry.enableOrRetry() }
        await fake.waitUntilFetchPauses()
        do {
            _ = try await source.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        } catch {
            await fake.resumeFetch()
            _ = try? await retrying.value
            throw error
        }
        await fake.resumeFetch()
        let held = try await retrying.value
        XCTAssertEqual(held.state, .needsAttention)
        let resumed = await probe.resumed
        XCTAssertTrue(resumed)
        try await fixture.assertHeld(fixture.persistence, transport: probe)

        let staged = try await fixture.raw.stagedBatches()
        let heldBatch = try XCTUnwrap(staged.first)
        XCTAssertEqual(staged.count, 1)
        XCTAssertTrue(heldBatch.attachmentTransitions.contains(
            .remoteMetadataDeleted(metadataIdentity: CloudAttachmentRecordCodec.identity(fixture.pointerID))
        ))

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let freshCheck = SetupRetryDeleteProbeTransport(fixture.transport())
        let lifecycle = try fixture.lifecycle(reopened, transport: freshCheck)
        do {
            _ = try await lifecycle.enableICloudSync()
            XCTFail("The checked peer copy must keep setup pending.")
        } catch CloudCollectionError.syncNeedsAttention {}
        try await fixture.assertHeld(reopened, transport: freshCheck)
        let usedOldToken = await freshCheck.resumed
        XCTAssertFalse(usedOldToken)
        let checkedEvents = await freshCheck.fake.events()
        XCTAssertTrue(checkedEvents.contains(.fetched), "Try Again must check a fresh batch.")
        let stagedAfterRetry = try await fixture.raw.stagedBatches()
        XCTAssertEqual(stagedAfterRetry.count, 1)
        XCTAssertNotEqual(stagedAfterRetry.first?.batchID, heldBatch.batchID)
        XCTAssertTrue(SnipSnapCloudAppAssembly.hasPendingSetup(rootURL: root))

        let peerParent = await fixture.server.fullSnapshot(for: fixture.deletedID)
        let removedParent = try await fixture.server.send(CloudOutboundBatch(operations: [
            .delete(fixture.deletedID, base: try XCTUnwrap(peerParent).shadow)
        ]), failures: [:])
        XCTAssertEqual(removedParent.items, [.deleted(fixture.deletedID)])
        try await lifecycle.cancelPendingEnable()
        let cancelled = try await reopened.snapshot()
        XCTAssertNil(cancelled.transition)
        XCTAssertEqual(cancelled.activeStore.id, fixture.sourceStoreID)

        let anotherOpen = try SwiftDataSyncModePersistence(rootURL: root)
        let enabling = SetupRetryDeleteProbeTransport(fixture.transport())
        let newLifecycle = try fixture.lifecycle(anotherOpen, transport: enabling)
        let enabled = try await newLifecycle.enableICloudSync()
        XCTAssertEqual(enabled, .enabled)
        let active = try await anotherOpen.snapshot().activeStore
        XCTAssertNotEqual(active.id, fixture.candidateID)
        let library = try await anotherOpen.libraryForTransition(storeID: active.id)
        let final = try await library.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(final.snips.map(\.id)), fixture.remainingIDs)
        let ledger = try await library.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        XCTAssertTrue(ledger.cleanups.isEmpty)
        let deletes = await enabling.suppliedDeleteIDs
        XCTAssertTrue(deletes.isEmpty)
        try await fixture.assertPayloadSurvives()
    }

    func testSetupRetryRetainsPointerDeleteAcrossCrashCancelReplacementAndRelease() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let staged = try await stageOldPointerDelete(fixture)
        let candidate = try await fixture.persistence.libraryForTransition(storeID: fixture.candidateID)
        let beforeEngine = try await candidate.cloudTextSyncSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        let crash = CrashInjector(point: .afterSetupPointerDeleteRetention)
        let crashing = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
        let crashProbe = SetupRetryDeleteProbeTransport(fixture.transport())
        do {
            _ = try await fixture.coordinator(crashing, transport: crashProbe).enableOrRetry()
            XCTFail("Expected the crash after source retention.")
        } catch CrashInjector.Failure.injected {}
        let retained = try await fixture.assertRetainedPointerDelete(crashing, batchID: staged.batchID)
        let stagedAfterCrash = try await fixture.raw.stagedBatches()
        XCTAssertEqual(stagedAfterCrash, [staged])
        let engineAfterCrash = try await candidate.cloudTextSyncSnapshot(
            namespaceKey: fixture.namespace.namespaceKey
        )
        XCTAssertEqual(engineAfterCrash.engineState, beforeEngine.engineState)
        let crashEvents = await crashProbe.fake.events()
        XCTAssertTrue(crashEvents.isEmpty)
        try await fixture.assertPayloadSurvives()

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let local = try await reopened.activeLibrary()
        _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        let probe = SetupRetryDeleteProbeTransport(fixture.transport())
        let held = try await fixture.coordinator(reopened, transport: probe).enableOrRetry()
        XCTAssertEqual(held.state, .needsAttention)
        try await fixture.assertHeld(reopened, transport: probe, checkLedger: false)
        let retryEvents = await probe.fake.events()
        XCTAssertTrue(retryEvents.contains(.fetched))
        XCTAssertTrue(retryEvents.contains { if case .confirmed = $0 { return true }; return false })
        let replayed = try await candidate.commitCloudFullBatch(staged)
        XCTAssertEqual(replayed, .replayed)
        let afterRetry = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID)
        XCTAssertEqual(afterRetry, retained)
        let heldLedger = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        XCTAssertTrue(heldLedger.cleanups.isEmpty)

        let editable = try await local.checkedSnapshot(sortedBy: .manual)
        let survivor = try XCTUnwrap(editable.snips.first { $0.content == "unrelated" })
        _ = try await local.perform(.update(
            id: survivor.id, content: "edited while setup held", attachmentURLs: nil,
            expectedUpdatedAt: survivor.updatedAt, now: survivor.updatedAt.addingTimeInterval(1)
        ), sortedBy: .manual)
        let cancellation = try fixture.lifecycle(reopened, transport: SetupRetryDeleteProbeTransport(fixture.transport()))
        try await cancellation.cancelPendingEnable()
        let cancelled = try await reopened.snapshot()
        XCTAssertNil(cancelled.transition)
        XCTAssertEqual(cancelled.activeStore.id, fixture.sourceStoreID)
        _ = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID)

        let replacement = try SwiftDataSyncModePersistence(rootURL: root)
        let replacementProbe = SetupRetryDeleteProbeTransport(fixture.transport())
        let replacementHold = try await fixture.coordinator(replacement, transport: replacementProbe).enableOrRetry()
        XCTAssertEqual(replacementHold.state, .needsAttention)
        let replacementStatus = try await replacement.snapshot()
        let replacedID = try XCTUnwrap(replacementStatus.transition?.candidateStoreID)
        XCTAssertNotEqual(replacedID, fixture.candidateID)
        let replacementStore = try await replacement.libraryForTransition(storeID: replacedID)
        let replacementLedger = try await replacementStore.cloudAttachmentStorageSnapshot(
            namespaceKey: fixture.namespace.namespaceKey
        )
        XCTAssertTrue(replacementLedger.cleanups.isEmpty)
        let replacementDeletes = await replacementProbe.suppliedDeleteIDs
        XCTAssertTrue(replacementDeletes.isEmpty)
        try await fixture.assertPayloadSurvives()

        let peerParent = await fixture.server.fullSnapshot(for: fixture.deletedID)
        let removed = try await fixture.server.send(CloudOutboundBatch(operations: [
            .delete(fixture.deletedID, base: try XCTUnwrap(peerParent).shadow)
        ]), failures: [:])
        XCTAssertEqual(removed.items, [.deleted(fixture.deletedID)])
        let incompleteProbe = SetupRetryDeleteProbeTransport(fixture.transport(), omitFetchCompletion: true)
        _ = try await fixture.coordinator(replacement, transport: incompleteProbe).enableOrRetry()
        let stillLocal = try await replacement.snapshot()
        XCTAssertEqual(stillLocal.activeStore.id, fixture.sourceStoreID)
        let incompleteLedger = try await replacementStore.cloudAttachmentStorageSnapshot(
            namespaceKey: fixture.namespace.namespaceKey
        )
        XCTAssertTrue(incompleteLedger.cleanups.isEmpty)
        _ = try await fixture.assertRetainedPointerDelete(replacement, batchID: staged.batchID)
        let installCrash = CrashInjector(point: .afterSetupPointerDeleteCleanupInstall)
        let releasing = try SwiftDataSyncModePersistence(rootURL: root, crashHook: installCrash.hit)
        let releaseProbe = SetupRetryDeleteProbeTransport(fixture.transport())
        let releaseLifecycle = try fixture.lifecycle(releasing, transport: releaseProbe)
        do {
            _ = try await releaseLifecycle.enableICloudSync()
            XCTFail("Expected the crash after the authorized cleanup handoff.")
        } catch CrashInjector.Failure.injected {}
        let beforeFinish = try await releasing.snapshot()
        XCTAssertEqual(beforeFinish.transition?.phase, .pointerSwapped)
        XCTAssertEqual(beforeFinish.activeStore.id, replacedID)
        let installLedger = try await replacementStore.cloudAttachmentStorageSnapshot(
            namespaceKey: fixture.namespace.namespaceKey
        )
        XCTAssertEqual(installLedger.cleanups.map(\.identity), retained.payloads.map(\.identity))

        let final = try SwiftDataSyncModePersistence(rootURL: root)
        let finalProbe = SetupRetryDeleteProbeTransport(fixture.transport())
        let finalLifecycle = try fixture.lifecycle(final, transport: finalProbe)
        let enabled = try await finalLifecycle.retrySynchronization()
        XCTAssertEqual(enabled, .iCloudSyncEnabled)
        let finalStatus = try await final.snapshot()
        XCTAssertNil(finalStatus.transition)
        let finalLibrary = try await final.libraryForTransition(storeID: finalStatus.activeStore.id)
        let finalLedger = try await finalLibrary.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        XCTAssertEqual(finalLedger.cleanups, installLedger.cleanups)
        let finalContent = try await finalLibrary.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(finalContent.snips.map(\.id)), fixture.remainingIDs)
        XCTAssertEqual(finalContent.snips.first(where: { $0.id == survivor.id })?.content, "edited while setup held")
        for transport in [probe, replacementProbe, incompleteProbe, releaseProbe, finalProbe] {
            let deletes = await transport.suppliedDeleteIDs
            XCTAssertTrue(deletes.isEmpty)
        }
        try await fixture.assertPayloadSurvives()
        let acceptedDeletes = await fixture.server.acceptedDeletionCount()
        XCTAssertEqual(acceptedDeletes, 2, "Only the original pointer delete and the peer's parent deletion.")
    }

    func testSetupRetryKeepsTheRetainedReceiptWhenCandidateFilesAreMissing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let staged = try await stageOldPointerDelete(fixture)
        let crash = CrashInjector(point: .afterSetupPointerDeleteRetention)
        let capturing = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
        do {
            _ = try await fixture.coordinator(
                capturing, transport: SetupRetryDeleteProbeTransport(fixture.transport())
            ).enableOrRetry()
            XCTFail("Expected the receipt to be durable before the old candidate is consumed.")
        } catch CrashInjector.Failure.injected {}
        _ = try await fixture.assertRetainedPointerDelete(capturing, batchID: staged.batchID)
        let candidateRoot = root.appendingPathComponent(
            "stores/iCloudSync-\(fixture.candidateID.uuidString.lowercased())"
        )
        try FileManager.default.moveItem(at: candidateRoot, to: root.appendingPathComponent("offline-candidate"))
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await reopened.activeLibrary()
        _ = try await source.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        let probe = SetupRetryDeleteProbeTransport(fixture.transport())
        let held = try await fixture.coordinator(reopened, transport: probe).enableOrRetry()
        XCTAssertEqual(held.state, .needsAttention)
        let replaced = try await reopened.snapshot()
        let replacementID = try XCTUnwrap(replaced.transition?.candidateStoreID)
        XCTAssertNotEqual(replacementID, fixture.candidateID)
        XCTAssertEqual(replaced.activeStore.id, fixture.sourceStoreID)
        _ = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID)
        let events = await probe.fake.events()
        XCTAssertFalse(events.contains { if case .sent = $0 { return true }; return false })
        try await fixture.assertPayloadSurvives()
    }

    func testSetupCancelRetainsAnUnconsumedLegacyReceiptButIgnoresAnUnknownPointer() async throws {
        for accepted in [true, false] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try await setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
            if !accepted {
                _ = try await fixture.server.send(CloudOutboundBatch(operations: [
                    .delete(fixture.pointerID, base: fixture.shadow)
                ]), failures: [:])
            }
            let staged = try await stageOldPointerDelete(fixture, accepted: accepted)
            let restarted = try SwiftDataSyncModePersistence(rootURL: root)
            let probe = SetupRetryDeleteProbeTransport(fixture.transport())
            try await fixture.lifecycle(restarted, transport: probe).cancelPendingEnable()
            let afterCancel = try SwiftDataSyncModePersistence(rootURL: root)
            let history = await afterCancel.setupRetryEvidence(namespace: fixture.namespace.binding)
            XCTAssertEqual(history?.acceptedPointerDeletes.map(\.key.batchID), accepted ? [staged.batchID] : [])
            let cancelled = try await afterCancel.snapshot()
            XCTAssertNil(cancelled.transition)
            let events = await probe.fake.events()
            XCTAssertTrue(events.isEmpty)
            try await fixture.assertPayloadSurvives()
        }
    }

    private func stageOldPointerDelete(
        _ fixture: SetupRetryPointerFixture, accepted: Bool = true
    ) async throws -> CloudFullBatchCommit {
        let candidate = try await fixture.persistence.libraryForTransition(storeID: fixture.candidateID)
        let before = try await candidate.checkedSnapshot(sortedBy: .manual)
        let attached = try XCTUnwrap(before.snips.first { $0.id == fixture.deleted.id })
        XCTAssertEqual(attached.attachments.count, 1)
        _ = try await candidate.perform(
            .editAttachments(
                snipID: attached.id, content: attached.content, edits: [],
                expectedUpdatedAt: attached.updatedAt, now: attached.updatedAt.addingTimeInterval(1)
            ),
            sortedBy: .manual
        )
        let pending = try await fixture.raw.pendingChanges()
        let deletion = try XCTUnwrap(pending.operations.first {
            if case .delete(fixture.pointerID, _) = $0 { return true }
            return false
        })
        let outbound = CloudOutboundBatch(operations: [deletion])
        let oldTransport = fixture.transport()
        try await oldTransport.start(state: nil)
        let sent = try await oldTransport.send(outbound)
        XCTAssertEqual(sent.items, accepted ? [.deleted(fixture.pointerID)] : [.unknownItem(fixture.pointerID)])
        try await fixture.raw.stage(.sent(sent), outbound: outbound)
        let staged = try await fixture.raw.stagedBatches()
        XCTAssertEqual(staged.map(\.batchID), [sent.id])
        let commit = try XCTUnwrap(staged.first)
        if accepted {
            XCTAssertTrue(commit.attachmentTransitions.contains {
                if case .metadataDeleteAccepted = $0 { return true }
                return false
            })
        }
        let initialLedger = try await candidate.cloudAttachmentStorageSnapshot(
            namespaceKey: fixture.namespace.namespaceKey
        )
        XCTAssertTrue(initialLedger.cleanups.isEmpty)

        return commit
    }

    private func setupRetryPointerFixture(
        root: URL, pointerOnDeletedSnip: Bool
    ) async throws -> SetupRetryPointerFixture {
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let local = try await persistence.activeLibrary()
        for text in ["acknowledged", "unrelated", "unsent"] {
            try await add(text, to: local)
        }
        let original = try await local.checkedSnapshot(sortedBy: .manual)
        let deleted = try XCTUnwrap(original.snips.first { $0.content == "acknowledged" })
        let unrelated = try XCTUnwrap(original.snips.first { $0.content == "unrelated" })
        let unsent = try XCTUnwrap(original.snips.first { $0.content == "unsent" })
        let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
        let zone = descriptor.metadataZone
        let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account")
        let server = FakeCloudServer()
        await server.seedControl(descriptor)
        let first = FakeCloudRecordTransport(server: server, namespace: namespace, automaticallyFetchedZones: [zone])
        await first.failNextSentItem(.snip(unsent.id, in: zone), failure: .retryable)
        let firstSetup = ICloudSyncModeCoordinator(
            persistence: persistence, namespace: namespace, textZone: zone, payloadZone: descriptor.payloadZone,
            makeTransport: { first }
        )
        let partial = try await firstSetup.enableOrRetry()
        XCTAssertEqual(partial.state, .settingUp)
        let history = await persistence.setupRetryEvidence(namespace: namespace.binding)
        XCTAssertTrue(history?.acknowledgedSnipKeys.contains { $0.reference.domainID == deleted.id } == true)

        let attachmentID = UUID()
        let pointerID = CloudRecordID(zone: zone, name: "a-\(attachmentID.uuidString.lowercased())")
        let payloadID = CloudRecordID(zone: descriptor.payloadZone, name: UUID().uuidString.lowercased())
        let bytes = Data("peer payload".utf8)
        let file = root.appendingPathComponent("peer.txt")
        try bytes.write(to: file)
        let metadata = CloudAttachmentMetadataValue(
            attachmentID: attachmentID, snipID: pointerOnDeletedSnip ? deleted.id : unrelated.id,
            position: 0, fileName: "peer.txt", contentType: "text/plain", byteCount: Int64(bytes.count),
            sha256: Data(SHA256.hash(data: bytes)), payloadIdentity: CloudAttachmentRecordCodec.identity(payloadID)
        )
        let pointer = CloudAttachmentPublication(
            metadata: metadata, metadataIdentity: CloudAttachmentRecordCodec.identity(pointerID),
            sourceURL: file, payloadAccepted: true, payloadShadowData: nil, metadataAccepted: false,
            metadataShadowData: nil, revision: 0
        )
        _ = try await server.send(CloudOutboundBatch(operations: [
            .save(CloudAttachmentRecordCodec.payloadDraft(pointer)),
            .save(CloudAttachmentRecordCodec.metadataDraft(pointer))
        ]), failures: [:])
        let accepted = await server.fullSnapshot(for: pointerID)
        let shadow = try XCTUnwrap(accepted).shadow
        let storage = try await persistence.snapshot()
        let candidateID = try XCTUnwrap(storage.transition?.candidateStoreID)
        let candidate = try await persistence.libraryForTransition(storeID: candidateID)
        let raw = CloudFullSyncPersistence(
            library: candidate, namespace: namespace, dataZone: zone, payloadZone: descriptor.payloadZone
        )
        let fetch = FakeCloudRecordTransport(server: server, namespace: namespace, automaticallyFetchedZones: [zone])
        let driver = CloudFullSyncCoordinator(store: raw, transport: fetch, fetchScope: .zones([zone]))
        try await driver.fetchRemote()
        let publications = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(publications.publications.map(\.metadata), [metadata])
        XCTAssertTrue(publications.cleanups.isEmpty)
        return SetupRetryPointerFixture(
            root: root, persistence: persistence, server: server, descriptor: descriptor, namespace: namespace,
            sourceStoreID: storage.activeStore.id, candidateID: candidateID, deleted: deleted,
            remainingIDs: [unrelated.id, unsent.id], pointerID: pointerID, shadow: shadow,
            payloadID: payloadID, bytes: bytes, raw: raw
        )
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

private struct SetupRetryPointerFixture {
    let root: URL
    let persistence: SwiftDataSyncModePersistence
    let server: FakeCloudServer
    let descriptor: CloudCollectionDescriptor
    let namespace: CloudSyncNamespace
    let sourceStoreID: UUID
    let candidateID: UUID
    let deleted: Snip
    let remainingIDs: Set<UUID>
    let pointerID: CloudRecordID
    let shadow: CloudRecordShadow
    let payloadID: CloudRecordID
    let bytes: Data
    let raw: CloudFullSyncPersistence

    var deletedID: CloudRecordID { .snip(deleted.id, in: descriptor.metadataZone) }

    func transport() -> FakeCloudRecordTransport {
        FakeCloudRecordTransport(
            server: server, namespace: namespace, automaticallyFetchedZones: [descriptor.metadataZone]
        )
    }

    func coordinator(
        _ persistence: SwiftDataSyncModePersistence, transport: SetupRetryDeleteProbeTransport
    ) -> ICloudSyncModeCoordinator {
        ICloudSyncModeCoordinator(
            persistence: persistence, namespace: namespace, textZone: descriptor.metadataZone,
            payloadZone: descriptor.payloadZone, makeTransport: { transport }
        )
    }

    func lifecycle(
        _ persistence: SwiftDataSyncModePersistence, transport: SetupRetryDeleteProbeTransport
    ) throws -> SnipSnapICloudSyncLifecycle {
        SnipSnapICloudSyncLifecycle(
            rootURL: root,
            sourceLibrary: try JSONSnipLibrary(fileURL: root.appendingPathComponent("legacy.json")),
            syncModeStore: SnipSyncModeStore(persistence),
            cloudScope: "private", accountLineage: "account", ownerName: "owner",
            controlTransport: FakeCloudControlTransport(server: server),
            makeRecordTransport: { _ in transport },
            makeDescriptor: { [descriptor] in descriptor }
        )
    }

    func assertHeld(
        _ persistence: SwiftDataSyncModePersistence,
        transport: SetupRetryDeleteProbeTransport,
        checkLedger: Bool = true
    ) async throws {
        let storage = try await persistence.snapshot()
        XCTAssertEqual(storage.activeStore.id, sourceStoreID)
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        XCTAssertEqual(storage.transition?.candidateStoreID, candidateID)
        XCTAssertEqual(storage.transition?.phase, .candidateReady)
        let local = try await persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(local.snips.map(\.id)), remainingIDs)
        let evidence = await persistence.setupRetryEvidence(namespace: namespace.binding)
        XCTAssertTrue(evidence?.acknowledgedSnipKeys.contains { $0.reference.domainID == deleted.id } == true)
        if checkLedger {
            let candidate = try await persistence.libraryForTransition(storeID: candidateID)
            let ledger = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
            XCTAssertTrue(ledger.cleanups.isEmpty)
            XCTAssertTrue(ledger.publications.contains {
                CloudAttachmentRecordCodec.recordID($0.metadataIdentity) == pointerID
            })
        }
        let deletes = await transport.suppliedDeleteIDs
        XCTAssertTrue(deletes.isEmpty)
        let events = await transport.fake.events()
        XCTAssertFalse(events.contains { if case .sent = $0 { return true }; return false })
        let peer = await server.fullSnapshot(for: deletedID)
        XCTAssertEqual(try CloudFullRecordCodec.snip(from: XCTUnwrap(peer)).text, .value(deleted.content))
        try await assertPayloadSurvives()
    }

    func assertPayloadSurvives() async throws {
        let asset = await server.asset(for: payloadID, field: CloudAttachmentRecordCodec.assetField)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(asset)), bytes)
    }

    func assertRetainedPointerDelete(
        _ persistence: SwiftDataSyncModePersistence, batchID: UUID
    ) async throws -> CloudSetupPointerDelete {
        let history = await persistence.setupRetryEvidence(namespace: namespace.binding)
        let receipts = try XCTUnwrap(history).acceptedPointerDeletes
        XCTAssertEqual(receipts.count, 1)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.key.batchID, batchID)
        XCTAssertEqual(receipt.key.pointer, CloudAttachmentRecordCodec.identity(pointerID))
        XCTAssertEqual(receipt.payloads.map(\.identity), [CloudAttachmentRecordCodec.identity(payloadID)])
        return receipt
    }
}

actor SetupRetryDeleteProbeTransport: CloudRecordTransport {
    let fake: FakeCloudRecordTransport
    let omitFetchCompletion: Bool
    let interruptConfirmation: Bool
    private(set) var resumed = false
    private(set) var receivedInitialOutbound = false
    private(set) var suppliedDeleteIDs: Set<CloudRecordID> = []

    init(
        _ fake: FakeCloudRecordTransport,
        omitFetchCompletion: Bool = false,
        interruptConfirmation: Bool = false
    ) {
        self.fake = fake
        self.omitFetchCompletion = omitFetchCompletion
        self.interruptConfirmation = interruptConfirmation
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
        if interruptConfirmation { throw CloudTransportError.fetchFailed }
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
