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
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: false)
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

    @MainActor
    func testSetupRetryRetainsPointerDeleteAcrossCrashCancelReplacementAndActivation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let staged = try await Self.stageOldPointerDelete(fixture)
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
        try await Self.recordPointerFailure(in: fixture, candidate: candidate)

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
        let installCrash = CrashInjector(point: .afterSetupPointerDeleteHandoff)
        let releasing = try SwiftDataSyncModePersistence(rootURL: root, crashHook: installCrash.hit)
        let releaseProbe = SetupRetryDeleteProbeTransport(fixture.transport())
        let releaseLifecycle = try fixture.lifecycle(releasing, transport: releaseProbe)
        do {
            _ = try await releaseLifecycle.enableICloudSync()
            XCTFail("Expected the crash after the retained receipt handoff.")
        } catch CrashInjector.Failure.injected {}
        let beforeFinish = try await releasing.snapshot()
        XCTAssertEqual(beforeFinish.transition?.phase, .pointerSwapped)
        XCTAssertEqual(beforeFinish.activeStore.id, replacedID)
        let installLedger = try await replacementStore.cloudAttachmentStorageSnapshot(
            namespaceKey: fixture.namespace.namespaceKey
        )
        XCTAssertTrue(installLedger.cleanups.isEmpty)
        let receiptsAtSwap = await releasing.retainedSetupPointerDeletes(in: fixture.namespace.binding)
        XCTAssertEqual(receiptsAtSwap, [retained])

        let finalProbe = SetupRetryDeleteProbeTransport(fixture.transport())
        let flakyControl = PendingOfflineThenOnlineControlTransport(server: fixture.server)
        let offline = try SwiftDataSyncModePersistence(rootURL: root)
        let offlineLifecycle = try fixture.lifecycle(offline, transport: finalProbe, control: flakyControl)
        do {
            _ = try await offlineLifecycle.retrySynchronization()
            XCTFail("A transient control read must leave deferred completion pending.")
        } catch let error as CloudSyncIssueError {
            XCTAssertEqual(error.issue, .waitingForConnection)
        }
        let locallyFinished = try await offline.snapshot()
        XCTAssertNil(locallyFinished.transition)
        XCTAssertEqual(locallyFinished.activeStore.id, replacedID)
        XCTAssertTrue(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))

        await flakyControl.goOnline()
        let final = try SwiftDataSyncModePersistence(rootURL: root)
        let finalLifecycle = try fixture.lifecycle(final, transport: finalProbe, control: flakyControl)
        let enabled = try await finalLifecycle.retrySynchronization()
        XCTAssertEqual(enabled, .deferredICloudSyncEnabled(
            .init(binding: fixture.namespace.binding, storeID: replacedID)
        ))
        let settings = SyncedContentSettingsModel(mode: .localOnly)
        let hasIssue = try await enabled.applyDeferredEnableCompletion(
            to: settings,
            started: settings.recordSyncStarted(),
            reload: { _ = try await finalLifecycle.activeLibrary() },
            acknowledge: { try await finalLifecycle.acknowledgeDeferredEnableCompletion(for: $0, whileCurrent: $1) }
        )
        XCTAssertFalse(hasIssue)
        XCTAssertEqual(settings.mode, .iCloudSync)
        XCTAssertFalse(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
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

        let activeProbe = SetupRetryDeleteProbeTransport(
            fixture.transport(), beforeSending: { outbound in
                if outbound.operations.contains(where: { $0.id == fixture.payloadID || $0.id == fixture.pointerID }) {
                    XCTFail("Setup receipt identities must never be submitted for deletion.")
                    throw CloudTransportError.sendFailed
                }
            }
        )
        let activeSync = fixture.coordinator(final, transport: activeProbe)
        _ = try await activeSync.syncActive()
        _ = try await activeSync.syncActive()
        let submitted = await activeProbe.suppliedDeletes
        XCTAssertTrue(submitted.isEmpty)
        let afterRetryCount = await fixture.server.acceptedDeletionCount()
        XCTAssertEqual(afterRetryCount, acceptedDeletes)
        let reloadedReceipts = await final.retainedSetupPointerDeletes(in: fixture.namespace.binding)
        XCTAssertEqual(reloadedReceipts, [retained])
        try await fixture.assertPayloadSurvives()
    }

    @MainActor
    func testDeferredEnableSurvivesInlineRetirementAndRolloverUntilSettingsReloads() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        _ = try await Self.stageOldPointerDelete(fixture)
        let local = try await fixture.persistence.activeLibrary()
        _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        try await fixture.removePeerParent()
        let crash = CrashInjector(point: .afterRetiredCleanupDeclared)
        let crashing = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
        let enabling = try fixture.lifecycle(crashing, transport: SetupRetryDeleteProbeTransport(fixture.transport()))
        do {
            _ = try await enabling.enableICloudSync()
            XCTFail("Expected interruption after the inline retirement commit.")
        } catch CrashInjector.Failure.injected {}
        let finished = try await crashing.snapshot()
        XCTAssertNil(finished.transition)
        XCTAssertEqual(finished.activeStore.namespace, fixture.namespace.binding)
        XCTAssertTrue(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
        let startup = SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: root)
        XCTAssertEqual(startup, .active(fixture.namespace.binding))
        let initialSettings = SnipSnapCloudAppAssembly.settingsStartupState(rootURL: root, startupState: startup)
        XCTAssertEqual(initialSettings.mode, .localOnly)
        XCTAssertEqual(initialSettings.state, .enabling(.checkingAccount))

        let server = fixture.server
        let control = PendingOfflineThenOnlineControlTransport(server: server)
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let failFirstFetchInGeneration = Mutex<UUID?>(nil)
        let recordFetches = Mutex(0)
        let lifecycle = SnipSnapICloudSyncLifecycle(
            rootURL: root,
            sourceLibrary: try JSONSnipLibrary(fileURL: root.appendingPathComponent("legacy.json")),
            syncModeStore: SnipSyncModeStore(reopened), cloudScope: "private",
            accountLineage: "account", ownerName: "owner", controlTransport: control,
            makeRecordTransport: { context in
                SetupRetryDeleteProbeTransport(FakeCloudRecordTransport(server: server, namespace: context.namespace,
                    automaticallyFetchedZones: [context.metadataZone]), beforeFetching: {
                    guard failFirstFetchInGeneration.withLock({ $0 == context.namespace.generation }) else { return }
                    let first = recordFetches.withLock { count in
                        count += 1
                        return count == 1
                    }
                    if first { throw CloudSyncIssueError(.waitingForConnection) }
                })
            }, makeDescriptor: { CloudCollectionDescriptor.fresh(ownerName: "owner") }
        )
        let session = SnipSnapCloudSyncSession(
            synchronize: { try await lifecycle.synchronize() }, retry: { try await lifecycle.retrySynchronization() },
            enable: { try await lifecycle.enableICloudSync() },
            acknowledgeEnable: { try await lifecycle.acknowledgeDeferredEnableCompletion(for: $0, whileCurrent: $1) },
            delete: { .completed }, activeLibrary: { try await lifecycle.activeLibrary() }
        )
        let settings = SyncedContentSettingsModel(mode: initialSettings.mode, initialState: initialSettings.state)
        do {
            try await lifecycle.scheduleAutomaticSync()
            XCTFail("Expected a transient control failure, not offline completion.")
        } catch let error as CloudSyncIssueError { XCTAssertEqual(error.issue, .waitingForConnection) }
        XCTAssertEqual(settings.mode, .localOnly)
        XCTAssertTrue(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))

        let newDescriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
        let newBinding = newDescriptor.namespace(cloudScope: "private", accountLineage: "account").binding
        failFirstFetchInGeneration.withLock { $0 = newDescriptor.generation }
        await server.seedControl(newDescriptor)
        let peerLibrary = try JSONSnipLibrary(fileURL: root.appendingPathComponent("new-peer.json"))
        try await Self.addSetupFixtureSnip("only in the new generation", to: peerLibrary)
        let peerSnapshot = try await peerLibrary.checkedSnapshot(sortedBy: .manual)
        let peer = try XCTUnwrap(peerSnapshot.snips.first)
        _ = try await server.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.snipDraft(peer, in: newDescriptor.metadataZone))
        ]), failures: [:])
        await control.goOnline()
        let adopted = try await session.retrySynchronization()
        let adoptedStore = try await reopened.snapshot().activeStore.id
        XCTAssertEqual(adopted, .deferredICloudSyncEnabled(
            .init(binding: newBinding, storeID: adoptedStore, issue: .waitingForConnection)
        ))
        XCTAssertTrue(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
        do {
            _ = try await adopted.applyDeferredEnableCompletion(
                to: settings,
                started: settings.recordSyncStarted(),
                reload: { throw CloudTransportError.fetchFailed },
                acknowledge: { try await session.acknowledgeDeferredEnableCompletion(for: $0, whileCurrent: $1) }
            )
            XCTFail("A failed app reload must leave completion available.")
        } catch CloudTransportError.fetchFailed {}
        XCTAssertEqual(settings.mode, .localOnly)
        XCTAssertTrue(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
        let carried = try await session.synchronize()
        XCTAssertEqual(carried, adopted)
        XCTAssertEqual(recordFetches.withLock { $0 }, 1)

        let result = try await session.retrySynchronization()
        XCTAssertEqual(result, .deferredICloudSyncEnabled(.init(binding: newBinding, storeID: adoptedStore)))
        XCTAssertGreaterThan(recordFetches.withLock { $0 }, 1)
        let nextDescriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
        await server.seedControl(nextDescriptor)
        _ = try await server.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.snipDraft(peer, in: nextDescriptor.metadataZone))
        ]), failures: [:])
        let superseded = try await session.acknowledgeDeferredEnableCompletion(
            for: .init(binding: newBinding, storeID: adoptedStore)
        )
        guard case .replaced = superseded else { return XCTFail("Expected a newly checked generation.") }
        XCTAssertEqual(settings.mode, .localOnly)
        XCTAssertTrue(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))

        let finalResult = try await session.retrySynchronization()
        let stopped = try await finalResult.applyDeferredEnableCompletion(
            to: settings, started: settings.recordSyncStarted(),
            reload: { settings.recordSyncStopped(.iCloudAccountChanged) },
            acknowledge: { _, _ in XCTFail("An older Settings operation cannot consume completion."); return .stale }
        )
        XCTAssertTrue(stopped)
        XCTAssertEqual(settings.state, .failed(.iCloudAccountChanged))
        XCTAssertTrue(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
        let stoppedDuringAcknowledgement = try await finalResult.applyDeferredEnableCompletion(
            to: settings, started: settings.recordSyncStarted(),
            reload: { _ = try await session.activeLibrary() },
            acknowledge: { binding, isCurrent in
                await MainActor.run { settings.recordSyncStopped(.signInRequired) }
                return try await session.acknowledgeDeferredEnableCompletion(for: binding, whileCurrent: isCurrent)
            }
        )
        XCTAssertTrue(stoppedDuringAcknowledgement)
        XCTAssertEqual(settings.state, .failed(.signInRequired))
        XCTAssertTrue(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
        let issue = try await finalResult.applyDeferredEnableCompletion(
            to: settings,
            started: settings.recordSyncStarted(),
            reload: {
                let library = try await session.activeLibrary().library
                let snapshot = try await library.checkedSnapshot(sortedBy: .manual)
                XCTAssertEqual(snapshot.snips.map(\.id), [peer.id])
                XCTAssertEqual(settings.mode, .localOnly)
            }, acknowledge: { binding, isCurrent in
                let mode = await settings.mode
                XCTAssertEqual(mode, .localOnly)
                return try await session.acknowledgeDeferredEnableCompletion(for: binding, whileCurrent: isCurrent)
            }
        )
        XCTAssertFalse(issue)
        XCTAssertEqual(settings.mode, .iCloudSync)
        XCTAssertFalse(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
    }

    func testSetupRetryKeepsTheRetainedReceiptWhenCandidateFilesAreMissing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let staged = try await Self.stageOldPointerDelete(fixture)
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

    func testSetupRetainsPayloadsWhenPeerMetadataArrivesDuringSetupSend() async throws {
        for change in ["recreate", "redirect", "alias"] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
            let staged = try await Self.stageOldPointerDelete(fixture)
            let local = try await fixture.persistence.activeLibrary()
            let snapshot = try await local.checkedSnapshot(sortedBy: .manual)
            let survivor = try XCTUnwrap(snapshot.snips.first { $0.content == "unrelated" })
            _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
            try await fixture.removePeerParent()

            let attachmentID = if change == "alias" {
                UUID()
            } else {
                try XCTUnwrap(UUID(uuidString: String(fixture.pointerID.name.dropFirst(2))))
            }
            let metadataID = CloudRecordID(
                zone: fixture.descriptor.metadataZone, name: "a-\(attachmentID.uuidString.lowercased())"
            )
            let payloadID = change == "redirect"
                ? CloudRecordID(zone: fixture.descriptor.payloadZone, name: UUID().uuidString.lowercased())
                : fixture.payloadID
            let bytes = change == "redirect" ? Data("independent peer bytes".utf8) : fixture.bytes
            let file = root.appendingPathComponent("late-peer.txt")
            try bytes.write(to: file)
            let metadata = CloudAttachmentMetadataValue(
                attachmentID: attachmentID, snipID: survivor.id, position: 0, fileName: "late-peer.txt",
                contentType: "text/plain", byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)),
                payloadIdentity: CloudAttachmentRecordCodec.identity(payloadID)
            )
            let publication = CloudAttachmentPublication(
                metadata: metadata, metadataIdentity: CloudAttachmentRecordCodec.identity(metadataID),
                sourceURL: file, payloadAccepted: true, payloadShadowData: nil,
                metadataAccepted: false, metadataShadowData: nil, revision: 0
            )
            let metadataDraft = try CloudAttachmentRecordCodec.metadataDraft(publication)
            let payloadDraft = try CloudAttachmentRecordCodec.payloadDraft(publication)
            let server = fixture.server
            let fake = fixture.transport()
            let inserted = Mutex(false)
            let probe = SetupRetryDeleteProbeTransport(fake, beforeSending: { _ in
                let first = inserted.withLock { flag in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                guard first else { return }
                let events = await fake.events()
                XCTAssertTrue(events.contains { if case .confirmed = $0 { return true }; return false })
                let operations: [CloudOutboundOperation] = change == "redirect"
                    ? [.save(payloadDraft), .save(metadataDraft)] : [.save(metadataDraft)]
                _ = try await server.send(CloudOutboundBatch(operations: operations), failures: [:])
            })
            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            let status = try await fixture.coordinator(reopened, transport: probe).enableOrRetry()
            XCTAssertEqual(status.state, .on, change)
            XCTAssertTrue(inserted.withLock { $0 }, change)
            let events = await fake.events()
            let sent = try XCTUnwrap(events.firstIndex { if case .sent = $0 { return true }; return false })
            XCTAssertTrue(events.dropFirst(sent + 1).contains(.fetched), change)
            let state = try await reopened.snapshot()
            XCTAssertEqual(state.activeStore.id, fixture.candidateID, change)
            XCTAssertNil(state.transition)
            _ = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID, activated: true)
            let candidate = try await reopened.libraryForTransition(storeID: fixture.candidateID)
            let ledger = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
            XCTAssertTrue(ledger.cleanups.isEmpty, change)
            let deletes = await probe.suppliedDeletes
            XCTAssertTrue(deletes.isEmpty, change)
            let peer = await server.fullSnapshot(for: metadataID)
            XCTAssertEqual(try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(peer)), metadata)
            try await fixture.assertPayloadSurvives()
        }
    }

    func testSetupProtectsRetainedPayloadQueuedByAliasTombstoneWithBothParentsKept() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let source = try await fixture.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        let otherParent = try XCTUnwrap(source.snips.first { $0.content == "unrelated" })
        let zone = fixture.descriptor.metadataZone
        let payload = CloudAttachmentRecordCodec.identity(fixture.payloadID)
        let early = try fixture.aliasDraft(parentID: otherParent.id)
        let late = try fixture.aliasDraft(parentID: otherParent.id)
        let server = fixture.server
        _ = try await server.send(CloudOutboundBatch(operations: [.save(early)]), failures: [:])
        let driver = CloudFullSyncCoordinator(store: fixture.raw, transport: fixture.transport(), fetchScope: .zones([zone]))
        try await driver.fetchRemote()
        let candidate = try await fixture.persistence.libraryForTransition(storeID: fixture.candidateID)
        let cached = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        XCTAssertTrue(cached.publications.contains { CloudAttachmentRecordCodec.recordID($0.metadataIdentity) == early.id })
        let staged = try await Self.stageOldPointerDelete(fixture)
        let earlyRecord = await server.fullSnapshot(for: early.id)
        let earlyDeleted = try await server.send(CloudOutboundBatch(operations: [
            .delete(early.id, base: try XCTUnwrap(earlyRecord).shadow)
        ]), failures: [:])
        XCTAssertEqual(earlyDeleted.items, [.deleted(early.id)])

        let fake = fixture.transport()
        let namespaceKey = fixture.namespace.namespaceKey
        let inserted = Mutex(false)
        let probe = SetupRetryDeleteProbeTransport(fake, idOnlyDeleteServer: server, beforeSending: { _ in
            let first = inserted.withLock { value in
                defer { value = true }
                return !value
            }
            guard first else { return }
            let afterTombstone = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
            XCTAssertEqual(afterTombstone.cleanups.map(\.identity), [payload])
            XCTAssertTrue(afterTombstone.publications.isEmpty)
            let events = await fake.events()
            XCTAssertTrue(events.contains(.fetched))
            XCTAssertTrue(events.contains { if case .confirmed = $0 { return true }; return false })
            _ = try await server.send(CloudOutboundBatch(operations: [.save(late)]), failures: [:])
        })
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let enabled = try await fixture.coordinator(reopened, transport: probe).enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        XCTAssertTrue(inserted.withLock { $0 })
        let intents = await probe.suppliedDeletes
        XCTAssertTrue(intents.isEmpty)
        let admissions = await probe.admissions
        XCTAssertTrue(admissions.contains { $0.blockedRecordIDs == [fixture.payloadID] })
        _ = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID, activated: true)
        let active = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(active.snips.map(\.id)), Set(source.snips.map(\.id)))
        XCTAssertTrue(active.snips.first { $0.id == otherParent.id }?.attachments.contains {
            "a-\($0.id.uuidString.lowercased())" == late.id.name
        } == true)
        try await fixture.assertPayloadSurvives()

        let lateRecord = await fixture.server.fullSnapshot(for: late.id)
        let removed = try await fixture.server.send(CloudOutboundBatch(operations: [
            .delete(late.id, base: try XCTUnwrap(lateRecord).shadow)
        ]), failures: [:])
        XCTAssertEqual(removed.items, [.deleted(late.id)])
        let retryProbe = SetupRetryDeleteProbeTransport(fixture.transport(),
            beforeSending: { outbound in
                guard !outbound.operations.contains(where: { $0.id == fixture.payloadID }) else {
                    XCTFail("An active alias tombstone must not release the payload.")
                    throw CloudTransportError.sendFailed
                }
            }
        )
        let live = fixture.coordinator(reopened, transport: retryProbe)
        _ = try await live.syncActive()
        _ = try await live.syncActive()
        let remaining = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
        XCTAssertEqual(remaining.cleanups.map(\.identity), [payload])
        let activeDeletes = await retryProbe.suppliedDeletes
        XCTAssertTrue(activeDeletes.isEmpty)
        try await fixture.assertPayloadSurvives()

    }

    func testSetupRetainsReceiptWhenCompleteInventoryOmitsCachedAliasWithoutTombstone() async throws {
        try await checkOmittedAliasTombstone(materializeBeforeRetry: true)
    }

    func testSetupCanFinishCheckingOmittedAliasAfterItsOrdinaryRemap() async throws {
        try await checkOmittedAliasTombstone(materializeBeforeRetry: false)
    }

    private func checkOmittedAliasTombstone(materializeBeforeRetry: Bool) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let source = try await fixture.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        let parent = try XCTUnwrap(source.snips.first { $0.content == "unrelated" })
        let alias = try fixture.aliasDraft(parentID: parent.id)
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [.save(alias)]), failures: [:])
        let driver = CloudFullSyncCoordinator(store: fixture.raw, transport: fixture.transport(),
            fetchScope: .zones([fixture.descriptor.metadataZone]))
        try await driver.fetchRemote()
        let candidate = try await fixture.persistence.libraryForTransition(storeID: fixture.candidateID)
        let namespaceKey = fixture.namespace.namespaceKey
        let aliasIdentity = CloudAttachmentRecordCodec.identity(alias.id)
        let fetched = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
        let downloadedAlias = try XCTUnwrap(fetched.publications.first { $0.metadataIdentity == aliasIdentity })
        XCTAssertTrue(downloadedAlias.metadataAccepted)
        XCTAssertNil(downloadedAlias.localSourceURL)
        if materializeBeforeRetry {
            // Settle the copy's source-path update while the peer still has the alias.
            let transfer = CloudAttachmentTransferCoordinator(
                library: candidate, namespace: fixture.namespace, payloadZone: fixture.descriptor.payloadZone,
                transport: fixture.transport(), maximumCacheBytes: CloudAttachmentTransferCoordinator.standardMaximumCacheBytes
            )
            let otherAttachments = Set(fetched.publications.map(\.metadata.attachmentID))
                .subtracting([downloadedAlias.metadata.attachmentID])
            _ = try await transfer.preserveAllAttachmentsForLocalCopy(excluding: otherAttachments)
            _ = try await driver.sendPending()
        }
        let staged = try await Self.stageOldPointerDelete(fixture)
        let cached = await fixture.server.fullSnapshot(for: alias.id)
        let priorShadow = try XCTUnwrap(cached).shadow
        let beforeRetry = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
        let priorAlias = try XCTUnwrap(beforeRetry.publications.first { $0.metadataIdentity == aliasIdentity })
        XCTAssertTrue(priorAlias.metadataAccepted)
        XCTAssertEqual(priorAlias.metadataShadowData, priorShadow.data)
        XCTAssertEqual(priorAlias.localSourceURL != nil, materializeBeforeRetry)
        if let durableFile = priorAlias.localSourceURL {
            XCTAssertEqual(try Data(contentsOf: durableFile), fixture.bytes)
        }
        XCTAssertEqual(priorAlias.metadata.payloadIdentity, CloudAttachmentRecordCodec.identity(fixture.payloadID))
        let removed = try await fixture.server.send(CloudOutboundBatch(operations: [
            .delete(alias.id, base: priorShadow)
        ]), failures: [:])
        XCTAssertEqual(removed.items, [.deleted(alias.id)])
        let replay = await fixture.server.changes(after: [:], scope: .zones([fixture.descriptor.metadataZone]), failures: [:])
        XCTAssertTrue(replay.batch.items.contains(.deleted(alias.id)))
        let cleanFetchIDs = Mutex<[UUID]>([])
        let confirmedFinalFetch = Mutex(false)
        let offeredAlias = Mutex<[CloudRecordDraft]>([])
        let aliasResults = Mutex<[CloudSendItemResult]>([])
        let metadataZone = fixture.descriptor.metadataZone
        let owed = CloudAttachmentRecordCodec.identity(fixture.payloadID)
        let beforeSwap = CrashInjector(point: .beforePointerSwap)
        let reopened = try SwiftDataSyncModePersistence(rootURL: root, crashHook: beforeSwap.hit)
        let reopenedCandidate = try await reopened.libraryForTransition(storeID: fixture.candidateID)
        let probe = SetupRetryDeleteProbeTransport(fixture.transport(), omittedTombstones: [alias.id], beforeSending: { outbound in
            for case .save(let draft) in outbound.operations where draft.id == alias.id {
                offeredAlias.withLock { $0.append(draft) }
            }
        }, afterSending: { _, sent in
            aliasResults.withLock { $0.append(contentsOf: sent.items.filter { $0.id == alias.id }) }
        }, afterFetching: { delivered in
            XCTAssertTrue(CloudFullSyncPersistence.isCleanInitialMetadataFetch(.fetched(delivered), dataZone: metadataZone))
            XCTAssertFalse(delivered.items.contains { $0.id == alias.id })
            cleanFetchIDs.withLock { $0.append(delivered.id) }
        }, afterConfirming: { batchID in
            let fetchNumber = cleanFetchIDs.withLock { ids in ids.last == batchID ? ids.count : nil }
            guard let fetchNumber else { return }
            let attachments = try await reopenedCandidate.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
            let publications = attachments.publications
            let aliasAtFinalCheck = publications.first { $0.metadataIdentity == aliasIdentity }
            if fetchNumber == 1 || materializeBeforeRetry {
                XCTAssertTrue(aliasAtFinalCheck?.metadataAccepted == true)
                XCTAssertEqual(aliasAtFinalCheck?.metadataShadowData, priorShadow.data)
                XCTAssertEqual(aliasAtFinalCheck?.metadata, priorAlias.metadata)
            } else {
                XCTAssertNil(aliasAtFinalCheck)
                XCTAssertTrue(publications.contains { publication in
                    publication.metadataAccepted && publication.metadata.snipID == priorAlias.metadata.snipID
                        && publication.metadata.sha256 == priorAlias.metadata.sha256
                        && publication.metadata.payloadIdentity != priorAlias.metadata.payloadIdentity
                })
                XCTAssertTrue(attachments.cleanups.contains { $0.identity == owed })
            }
            if fetchNumber == 2 { confirmedFinalFetch.withLock { $0 = true } }
        })
        do {
            _ = try await fixture.coordinator(reopened, transport: probe).enableOrRetry()
            XCTFail("Expected both otherwise-safe retries to reach the pre-swap hook.")
        } catch CrashInjector.Failure.injected {}
        let current = try await reopened.snapshot()
        XCTAssertEqual(current.activeStore.id, fixture.sourceStoreID)
        _ = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID)
        XCTAssertTrue(confirmedFinalFetch.withLock { $0 })
        let stored = try await reopenedCandidate.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
        let inventory = try XCTUnwrap(stored.namespaceState.initialFetchInventory)
        XCTAssertTrue(inventory.canProveAbsence)
        XCTAssertFalse(inventory.observed.contains(aliasIdentity))
        let aliasDrafts = offeredAlias.withLock { $0 }
        XCTAssertEqual(aliasDrafts.map(\.base), materializeBeforeRetry ? [] : [priorShadow])
        XCTAssertEqual(aliasResults.withLock { $0 }, materializeBeforeRetry ? [] : [.unknownItem(alias.id)])
        let attachments = try await reopenedCandidate.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
        XCTAssertEqual(attachments.publications.contains { $0.metadataIdentity == aliasIdentity }, materializeBeforeRetry)
        if materializeBeforeRetry { XCTAssertTrue(attachments.cleanups.isEmpty) }
        let offered = await probe.suppliedDeletes
        XCTAssertTrue(offered.isEmpty)
        try await fixture.assertPayloadSurvives()
    }

    func testSetupRecoveryChecksLiveGenerationBeforeSendingAndBeforeActivation() async throws {
        for changeDuringSend in [false, true] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
            let staged = try await Self.stageOldPointerDelete(fixture)
            let local = try await fixture.persistence.activeLibrary()
            _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
            try await fixture.removePeerParent()
            let server = fixture.server
            let other = CloudCollectionDescriptor.fresh(ownerName: "owner")
            let fake = fixture.transport()
            let probe = SetupRetryDeleteProbeTransport(
                fake,
                beforeSending: { _ in if changeDuringSend { await server.seedControl(other) } },
                afterFetching: { _ in if !changeDuringSend { await server.seedControl(other) } }
            )
            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            let lifecycle = try fixture.lifecycle(reopened, transport: probe)
            do {
                _ = try await lifecycle.enableICloudSync()
                XCTFail("The earlier generation cannot authorize setup.")
            } catch CloudCollectionError.syncNeedsAttention {}
            let state = try await reopened.snapshot()
            XCTAssertEqual(state.activeStore.id, fixture.sourceStoreID)
            _ = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID)
            let oldZoneStillExists = await server.hasZone(fixture.descriptor.metadataZone)
            XCTAssertTrue(oldZoneStillExists)
            let events = await fake.events()
            XCTAssertEqual(events.contains { if case .sent = $0 { return true }; return false }, changeDuringSend)
            let deletes = await probe.suppliedDeletes
            XCTAssertTrue(deletes.isEmpty)
            try await fixture.assertPayloadSurvives()
        }
    }

    func testCancelledNamespaceReceiptSurvivesAnotherActivationAndBlocksRecreatedPointerDelete() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let source = try await fixture.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        let aliasParent = try XCTUnwrap(source.snips.first { $0.content == "unrelated" })
        let staged = try await Self.stageOldPointerDelete(fixture)
        _ = try await fixture.lifecycle(fixture.persistence, transport: Self.peerRestoreProbe(fixture)).cancelPendingEnable()
        let original = try await fixture.assertRetainedPointerDelete(fixture.persistence, batchID: staged.batchID)

        let other = CloudCollectionDescriptor.fresh(ownerName: "owner")
        let otherNamespace = other.namespace(cloudScope: "private", accountLineage: "other-account")
        let otherServer = FakeCloudServer()
        await otherServer.seedControl(other)
        let enableOther = ICloudSyncModeCoordinator(
            persistence: fixture.persistence, namespace: otherNamespace, textZone: other.metadataZone,
            payloadZone: other.payloadZone, makeTransport: {
                FakeCloudRecordTransport(server: otherServer, namespace: otherNamespace,
                    automaticallyFetchedZones: [other.metadataZone])
            }
        )
        let enabled = try await enableOther.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let retained = await reopened.retainedSetupPointerDeletes(in: fixture.namespace.binding)
        XCTAssertEqual(retained, [original])
        let otherReceipts = await reopened.retainedSetupPointerDeletes(in: otherNamespace.binding)
        XCTAssertTrue(otherReceipts.isEmpty)
        let otherHistory = await reopened.setupRetryEvidence(namespace: fixture.namespace.binding)
        XCTAssertNil(otherHistory)
        try await reopened.activateEmptyCollection(namespace: fixture.namespace.binding)

        let active = try await reopened.snapshot().activeStore
        let library = try await reopened.libraryForTransition(storeID: active.id)
        let local = try await reopened.activeLibrary()
        let context = CloudCollectionSyncContext(namespace: fixture.namespace,
            metadataZone: fixture.descriptor.metadataZone, payloadZone: fixture.descriptor.payloadZone)
        let raw = CloudFullSyncPersistence(library: library, namespace: context.namespace,
            dataZone: context.metadataZone, payloadZone: context.payloadZone, modePersistence: reopened)
        let alias = try fixture.aliasDraft(parentID: aliasParent.id)
        let attachmentID = try XCTUnwrap(UUID(uuidString: String(fixture.pointerID.name.dropFirst(2))))
        let newPayload = CloudRecordID(zone: context.payloadZone, name: UUID().uuidString.lowercased())
        let newFile = root.appendingPathComponent("new-pointer.txt")
        let bytes = Data("the recreated pointer's separate bytes".utf8)
        try bytes.write(to: newFile)
        let metadata = CloudAttachmentMetadataValue(attachmentID: attachmentID, snipID: fixture.deleted.id,
            position: 0, fileName: "new-pointer.txt", contentType: "text/plain", byteCount: Int64(bytes.count),
            sha256: Data(SHA256.hash(data: bytes)), payloadIdentity: CloudAttachmentRecordCodec.identity(newPayload))
        let fresh = CloudAttachmentPublication(metadata: metadata, metadataIdentity: original.key.pointer,
            sourceURL: newFile, payloadAccepted: false, payloadShadowData: nil, metadataAccepted: false,
            metadataShadowData: nil, revision: 0)
        let oldRecord = try CloudKitRecordMapper.snapshot(fixture.shadow.record())
        let recreatedOld = CloudRecordDraft(id: oldRecord.id, recordType: oldRecord.recordType,
            schemaVersion: oldRecord.schemaVersion, routingFields: oldRecord.routingFields,
            encryptedFields: oldRecord.encryptedFields, base: nil)
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [
            .save(recreatedOld), .save(alias), .save(CloudAttachmentRecordCodec.payloadDraft(fresh))
        ]), failures: [:])
        let probe = SetupRetryDeleteProbeTransport(fixture.transport(), beforeSending: { outbound in
            try Self.refuseDeletes(in: outbound, for: [fixture.payloadID])
        })
        let driver = CloudFullRecordCollectionSyncDriver(persistence: reopened, makeTransport: { _ in probe })
        _ = try await driver.fetch(context)
        let oldLocal = try await local.checkedSnapshot(sortedBy: .manual)
        let oldSnip = try XCTUnwrap(oldLocal.snips.first { $0.id == fixture.deleted.id })
        XCTAssertEqual(oldSnip.attachments.map(\.id), [attachmentID])
        _ = try await local.perform(.editAttachments(snipID: oldSnip.id, content: oldSnip.content, edits: [],
            expectedUpdatedAt: oldSnip.updatedAt, now: oldSnip.updatedAt.addingTimeInterval(1)), sortedBy: .manual)
        let oldIntent = try await raw.pendingChanges()
        XCTAssertFalse(oldIntent.operations.contains { $0.id == fixture.pointerID })
        let freshPointer = try CloudAttachmentRecordCodec.metadataDraft(fresh)
        let oldServer = await fixture.server.fullSnapshot(for: fixture.pointerID)
        let redirect = CloudRecordDraft(id: freshPointer.id, recordType: freshPointer.recordType,
            schemaVersion: freshPointer.schemaVersion, routingFields: freshPointer.routingFields,
            encryptedFields: freshPointer.encryptedFields, base: try XCTUnwrap(oldServer).shadow)
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [.save(redirect)]), failures: [:])
        _ = try await driver.fetch(context)
        let rebased = try await library.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        let rebasedPointer = try XCTUnwrap(rebased.publications.first { $0.metadataIdentity == original.key.pointer })
        XCTAssertFalse(rebasedPointer.isLocallyPresent)
        XCTAssertEqual(rebasedPointer.metadata.payloadIdentity, metadata.payloadIdentity)
        let rebasedIntent = try await raw.pendingChanges()
        XCTAssertFalse(rebasedIntent.operations.contains { $0.id == fixture.pointerID })
        let peerRedirect = await fixture.server.fullSnapshot(for: fixture.pointerID)
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [
            .delete(fixture.pointerID, base: try XCTUnwrap(peerRedirect).shadow)
        ]), failures: [:])
        _ = try await driver.fetch(context)
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [.save(freshPointer)]), failures: [:])
        _ = try await driver.fetch(context)
        let aliasRecord = await fixture.server.fullSnapshot(for: alias.id)
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [
            .delete(alias.id, base: try XCTUnwrap(aliasRecord).shadow)
        ]), failures: [:])
        _ = try await driver.fetch(context)
        let received = try await library.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        let fetched = try XCTUnwrap(received.publications.first { $0.metadataIdentity == original.key.pointer })
        XCTAssertEqual(fetched.revision, 1)
        XCTAssertEqual(fetched.metadata, metadata)
        XCTAssertTrue(received.cleanups.contains { $0.identity == CloudAttachmentRecordCodec.identity(fixture.payloadID) })
        let admission = try await raw.outboundAdmission()
        XCTAssertEqual(admission.blockedRecordIDs, [fixture.payloadID])

        let snips = try await local.checkedSnapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(snips.snips.first { $0.id == fixture.deleted.id })
        XCTAssertEqual(snip.attachments.map(\.id), [attachmentID])
        _ = try await local.perform(.editAttachments(snipID: snip.id, content: snip.content, edits: [],
            expectedUpdatedAt: snip.updatedAt, now: snip.updatedAt.addingTimeInterval(1)), sortedBy: .manual)
        let planned = try await raw.pendingChanges()
        XCTAssertFalse(planned.operations.contains { $0.id == fixture.pointerID || $0.id == fixture.payloadID })
        let settled = try await raw.isSyncSettled()
        XCTAssertFalse(settled)
        let issue = try await raw.unresolvedSyncIssue()
        XCTAssertEqual(issue, .appDataIssue)

        // The peer revives the original pointer after the local removal was planned.
        let current = await fixture.server.fullSnapshot(for: fixture.pointerID)
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [
            .delete(fixture.pointerID, base: try XCTUnwrap(current).shadow)
        ]), failures: [:])
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [.save(recreatedOld)]), failures: [:])
        let startup = ResumedAttachmentOfferTransport(fixture.transport())
        let activeDriver = CloudFullRecordCollectionSyncDriver(persistence: reopened, makeTransport: { _ in startup })
        try await activeDriver.prepareAutomaticSync(context)
        let initial = await startup.suppliedInitialOperations
        let offered = try await startup.checkedInitialOffer()
        try Self.refuseDeletes(in: .init(operations: initial + offered), for: [fixture.pointerID, fixture.payloadID])
        let blockedPayloads = await startup.blockedRecordIDs
        XCTAssertEqual(blockedPayloads, [fixture.payloadID])
        let startupEvents = await startup.fake.events()
        XCTAssertFalse(startupEvents.contains(.fetched))

        let idOnly = SetupRetryDeleteProbeTransport(fixture.transport(), idOnlyDeleteServer: fixture.server,
            beforeSending: { batch in try Self.refuseDeletes(in: batch, for: [fixture.pointerID, fixture.payloadID]) })
        if !offered.isEmpty { _ = try await idOnly.send(.init(operations: offered)) }
        let deletes = await idOnly.suppliedDeletes
        XCTAssertTrue(deletes.isEmpty)
        let peer = await fixture.server.fullSnapshot(for: fixture.pointerID)
        XCTAssertEqual(try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(peer)).payloadIdentity,
            CloudAttachmentRecordCodec.identity(fixture.payloadID))
        try await fixture.assertPayloadSurvives()
    }

    func testReceivedPointerDeleteIsRetainedBeforeAccountGateAndEarlierEvents() async throws {
        for queued in [false, true] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true, sourceOwnsPointer: true)
            let local = try await fixture.persistence.activeLibrary()
            let source = try await local.checkedSnapshot(sortedBy: .manual)
            let snip = try XCTUnwrap(source.snips.first { $0.id == fixture.deleted.id })
            _ = try await local.perform(.editAttachments(snipID: snip.id, content: snip.content, edits: [],
                expectedUpdatedAt: snip.updatedAt, now: snip.updatedAt.addingTimeInterval(1)), sortedBy: .manual)
            let account = SetupTestAccount()
            let received = Mutex<UUID?>(nil)
            let priorCheckpoint = Mutex<CloudEngineStateEnvelope?>(nil)
            let probe = SetupRetryDeleteProbeTransport(fixture.transport(),
                queueAcceptedDeleteBehindAccountEvent: queued,
                beforeSending: { batch in
                    if batch.operations.contains(where: { $0.id == fixture.pointerID }) {
                        let state = try await fixture.raw.loadEngineState()
                        priorCheckpoint.withLock { $0 = state }
                    }
                }, afterSending: { _, sent in
                    guard sent.items.contains(.deleted(fixture.pointerID)) else { return }
                    received.withLock { $0 = sent.id }
                    await account.set(.temporarilyUnavailable)
                })
            let first = try fixture.lifecycle(fixture.persistence, transport: probe, account: account)
            do {
                let result = try await first.enableICloudSync()
                guard case .settingUp = result else { return XCTFail("The server response cannot bypass the account guard.") }
            } catch ICloudAccountGateError.temporarilyUnavailable {}
            let id = try XCTUnwrap(received.withLock { $0 })
            let durable = try await fixture.assertRetainedPointerDelete(fixture.persistence, batchID: id)
            let confirmed = await probe.fake.events()
            XCTAssertFalse(confirmed.contains(.confirmed(id)))
            let checkpoint = try await fixture.raw.loadEngineState()
            XCTAssertEqual(checkpoint, priorCheckpoint.withLock { $0 })
            let staged = try await fixture.raw.stagedBatches()
            XCTAssertFalse(staged.contains { $0.batchID == id })
            if queued {
                let event = await probe.pendingEvent()
                guard case .accountChange? = event else { return XCTFail("The earlier event must still await acknowledgement.") }
            }
            try await fixture.assertPayloadSurvives()

            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            let cancelling = try fixture.lifecycle(reopened, transport: Self.peerRestoreProbe(fixture), account: account)
            let cancelled = try await cancelling.cancelPendingEnable()
            XCTAssertEqual(cancelled, .cancelled)
            let afterCancel = try await fixture.assertRetainedPointerDelete(reopened, batchID: id)
            XCTAssertEqual(afterCancel, durable)
            await account.set(.available(accountLineage: "account"))
            let retryProbe = Self.peerRestoreProbe(fixture)
            let retry = try fixture.lifecycle(reopened, transport: retryProbe, account: account)
            let result = try await retry.enableICloudSync()
            guard case .checked = result else { return XCTFail("Expected the retained same-account completion.") }
            let afterReturn = try await fixture.assertRetainedPointerDelete(reopened, batchID: id, activated: true)
            XCTAssertEqual(afterReturn, durable)
            let deletes = await retryProbe.suppliedDeletes
            XCTAssertTrue(deletes.isEmpty)
            try await fixture.assertPayloadSurvives()
        }
    }

    @MainActor
    func testRestoreRequiresRemoteBytesBeforeSendingAndAfterMatchingCache() async throws {
        for failure in ["missing", "wrong bytes", "lost after first check"] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
            let local = try await fixture.persistence.activeLibrary()
            _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
            let reads = Mutex(0)
            let sends = Mutex(0)
            let probe = SetupRetryDeleteProbeTransport(fixture.transport(), beforeSending: { batch in
                try Self.refuseDeletes(in: batch, for: [fixture.pointerID, fixture.payloadID, fixture.deletedID])
                let first = sends.withLock { value in value += 1; return value == 1 }
                if first, failure == "lost after first check" {
                    XCTAssertEqual(reads.withLock { $0 }, 1)
                    try await Self.removePeerPayload(fixture)
                }
            }, beforeAssetFetch: { id in
                XCTAssertEqual(id, fixture.payloadID)
                reads.withLock { $0 += 1 }
            })
            let lifecycle = try fixture.lifecycle(fixture.persistence, transport: probe)
            let settings = Self.settingsForPeerRestore(fixture, lifecycle: lifecycle)
            await settings.enableICloudSync()
            let offer = try XCTUnwrap(settings.peerCopyOffer)
            XCTAssertEqual(reads.withLock { $0 }, 0)
            let attachmentID = try XCTUnwrap(UUID(uuidString: String(fixture.pointerID.name.dropFirst(2))))
            let candidate = try await fixture.persistence.libraryForTransition(storeID: fixture.candidateID)
            let transfer = CloudAttachmentTransferCoordinator(library: candidate, namespace: fixture.namespace,
                payloadZone: fixture.descriptor.payloadZone, transport: fixture.transport(),
                maximumCacheBytes: CloudAttachmentTransferCoordinator.standardMaximumCacheBytes)
            let cached = try await transfer.download(attachmentID: attachmentID)
            XCTAssertEqual(try Data(contentsOf: cached), fixture.bytes)

            if failure != "lost after first check" {
                try await Self.removePeerPayload(fixture)
                if failure == "wrong bytes" {
                    let otherBytes = Data(repeating: 0x2a, count: fixture.bytes.count)
                    let file = root.appendingPathComponent("mismatched.txt")
                    try otherBytes.write(to: file)
                    let record = await fixture.server.fullSnapshot(for: fixture.pointerID)
                    let metadata = try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(record))
                    let publication = CloudAttachmentPublication(metadata: metadata,
                        metadataIdentity: CloudAttachmentRecordCodec.identity(fixture.pointerID), sourceURL: file,
                        payloadAccepted: false, payloadShadowData: nil, metadataAccepted: false, metadataShadowData: nil, revision: 0)
                    let saved = try await fixture.server.send(.init(operations: [
                        .save(CloudAttachmentRecordCodec.payloadDraft(publication))
                    ]), failures: [:])
                    XCTAssertEqual(saved.items.map(\.id), [fixture.payloadID])
                }
            }

            await settings.restoreSetupPeerCopies(offer)
            XCTAssertEqual(settings.mode, .localOnly, failure)
            let state = try await fixture.persistence.snapshot()
            XCTAssertEqual(state.activeStore.id, fixture.sourceStoreID, failure)
            let final = try await local.checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(Set(final.snips.map(\.id)), fixture.remainingIDs)
            XCTAssertEqual(reads.withLock { $0 }, failure == "lost after first check" ? 2 : 1)
            if failure != "lost after first check" { XCTAssertEqual(sends.withLock { $0 }, 0) }
            let supplied = await probe.suppliedDeletes
            XCTAssertTrue(supplied.isEmpty)
            let peer = await fixture.server.fullSnapshot(for: fixture.pointerID)
            XCTAssertNotNil(peer)
        }
    }

    private static func removePeerPayload(_ fixture: SetupRetryPointerFixture) async throws {
        let stored = await fixture.server.fullSnapshot(for: fixture.payloadID)
        let sent = try await fixture.server.send(.init(operations: [
            .delete(fixture.payloadID, base: try XCTUnwrap(stored).shadow)
        ]), failures: [:])
        XCTAssertEqual(sent.items, [.deleted(fixture.payloadID)])
    }

    @MainActor
    func testRealSessionCancelDistinguishesPendingSetupFromACompletedSwap() async throws {
        for switches in [false, true] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
            _ = try await Self.stageOldPointerDelete(fixture)
            let local = try await fixture.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
            let remaining = try XCTUnwrap(local.snips.first { $0.content == "unsent" })
            let fake = fixture.transport()
            if !switches {
                await fake.failNextSentItem(.snip(remaining.id, in: fixture.descriptor.metadataZone), failure: .retryable)
            }
            await fake.pauseNextSend()
            let probe = SetupRetryDeleteProbeTransport(fake, beforeSending: { outbound in
                try Self.refuseDeletes(in: outbound, for: [fixture.pointerID, fixture.payloadID])
            })
            let lifecycle = try fixture.lifecycle(fixture.persistence, transport: probe)
            let session = Self.settingsSession(lifecycle)
            let requested = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let reloads = Mutex(0)
            let settings = SyncedContentSettingsModel(mode: .localOnly,
                enableAction: { try await session.enableICloudSync() },
                cancelEnableAction: {
                    requested.continuation.yield(())
                    return try await session.cancelICloudSyncSetup()
                },
                acknowledgeEnableAction: { try await session.acknowledgeDeferredEnableCompletion(for: $0, whileCurrent: $1) })
            settings.setEnableCompletionAction {
                _ = try await session.activeLibrary()
                reloads.withLock { $0 += 1 }
            }

            let enable = Task { @MainActor in await settings.enableICloudSync() }
            await fake.waitUntilSendPauses()
            let cancel = Task { @MainActor in await settings.cancelICloudSyncSetup() }
            var entered = requested.stream.makeAsyncIterator()
            _ = await entered.next()
            await fake.resumeSend()
            await enable.value
            await cancel.value

            let active = try await fixture.persistence.snapshot()
            XCTAssertNil(active.transition)
            XCTAssertEqual(active.activeStore.id, switches ? fixture.candidateID : fixture.sourceStoreID)
            XCTAssertEqual(settings.mode, switches ? .iCloudSync : .localOnly)
            XCTAssertEqual(settings.state, .ready)
            XCTAssertEqual(reloads.withLock { $0 > 0 }, switches)
            XCTAssertFalse(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
            let deletes = await probe.suppliedDeletes
            XCTAssertTrue(deletes.isEmpty)
            try await fixture.assertPayloadSurvives()
        }
    }

    @MainActor
    func testReceiptFreeRestoreRelaunchesOfflineAndAdoptsOnlyTheCheckedGeneration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let local = try await fixture.persistence.activeLibrary()
        _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        let firstLifecycle = try fixture.lifecycle(fixture.persistence, transport: Self.peerRestoreProbe(fixture))
        let settings = Self.settingsForPeerRestore(fixture, lifecycle: firstLifecycle)
        await settings.enableICloudSync()
        let offer = try XCTUnwrap(settings.peerCopyOffer)
        let crash = CrashInjector(point: .afterPointerSwap)
        let crashing = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
        let probe = Self.peerRestoreProbe(fixture)
        let attempting = try fixture.lifecycle(crashing, transport: probe)
        do {
            _ = try await Self.settingsSession(attempting).restoreSetupPeerCopies(offer)
            XCTFail("Expected interruption after the receipt-free pointer swap.")
        } catch CrashInjector.Failure.injected {}
        let atSwap = try await crashing.snapshot()
        XCTAssertEqual(atSwap.activeStore.id, fixture.candidateID)
        XCTAssertEqual(atSwap.transition?.phase, .pointerSwapped)
        XCTAssertFalse(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
        let startup = SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: root)
        XCTAssertEqual(startup, .checkingEnable(fixture.namespace.binding))
        let initialSettings = SnipSnapCloudAppAssembly.settingsStartupState(rootURL: root, startupState: startup)
        XCTAssertEqual(initialSettings.mode, .localOnly)
        XCTAssertEqual(initialSettings.state, .enabling(.checkingAccount))
        let receipts = await crashing.retainedSetupPointerDeletes(in: fixture.namespace.binding)
        XCTAssertTrue(receipts.isEmpty)

        let control = PendingOfflineThenOnlineControlTransport(server: fixture.server)
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let server = fixture.server
        let automaticResult = Mutex<SnipSnapCloudSyncResult?>(nil)
        let retry = SnipSnapICloudSyncLifecycle(rootURL: root,
            sourceLibrary: try JSONSnipLibrary(fileURL: root.appendingPathComponent("legacy.json")),
            syncModeStore: SnipSyncModeStore(reopened), cloudScope: "private", accountLineage: "account",
            ownerName: "owner", controlTransport: control,
            makeRecordTransport: { context in
                FakeCloudRecordTransport(server: server, namespace: context.namespace,
                    automaticallyFetchedZones: [context.metadataZone])
            }, makeDescriptor: { CloudCollectionDescriptor.fresh(ownerName: "owner") },
            automaticResultHandler: { result in automaticResult.withLock { $0 = result } })
        let session = Self.settingsSession(retry)
        do {
            try await retry.scheduleAutomaticSync()
            XCTFail("A receipt-free restore now requires a checked completion.")
        } catch let error as CloudSyncIssueError { XCTAssertEqual(error.issue, .waitingForConnection) }
        XCTAssertTrue(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
        XCTAssertNil(automaticResult.withLock { $0 })
        let offline = try await reopened.snapshot()
        XCTAssertNil(offline.transition)

        let newer = CloudCollectionDescriptor.fresh(ownerName: "owner")
        let binding = newer.namespace(cloudScope: "private", accountLineage: "account").binding
        await server.seedControl(newer)
        await control.goOnline()
        try await retry.scheduleAutomaticSync()
        let active = try await reopened.snapshot()
        XCTAssertNotEqual(active.activeStore.id, fixture.candidateID)
        let outcome = try XCTUnwrap(automaticResult.withLock { $0 })
        let expected = SnipSnapDeferredEnableCompletion(binding: binding, storeID: active.activeStore.id)
        XCTAssertEqual(outcome, .deferredICloudSyncEnabled(expected))
        let reloadedSettings = SyncedContentSettingsModel(mode: initialSettings.mode, initialState: initialSettings.state,
            acknowledgeEnableAction: { try await session.acknowledgeDeferredEnableCompletion(for: $0, whileCurrent: $1) })
        let reloaded = Mutex(false)
        reloadedSettings.setEnableCompletionAction {
            _ = try await session.activeLibrary()
            reloaded.withLock { $0 = true }
        }
        try await reloadedSettings.completeScheduledEnable(expected)
        XCTAssertTrue(reloaded.withLock { $0 })
        XCTAssertEqual(reloadedSettings.mode, .iCloudSync)
        XCTAssertFalse(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
    }

    func testExplicitRetryResumesReceiptOnlySetupWithBothParentsKept() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let sent = try await Self.stageOldPointerDelete(fixture)
        let incomplete = SetupRetryDeleteProbeTransport(fixture.transport(), omitFetchCompletion: true)
        let initial = try fixture.lifecycle(fixture.persistence, transport: incomplete)
        do {
            _ = try await initial.enableICloudSync()
            XCTFail("An incomplete fetch must keep setup pending.")
        } catch CloudCollectionError.syncNeedsAttention {}
        XCTAssertTrue(PendingICloudSyncEnable.needsAttention(at: root))
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let probe = Self.peerRestoreProbe(fixture)
        let lifecycle = try fixture.lifecycle(reopened, transport: probe)
        let result = try await Self.settingsSession(lifecycle).retrySynchronization()
        XCTAssertEqual(result, .deferredICloudSyncEnabled(.init(binding: fixture.namespace.binding, storeID: fixture.candidateID)))
        _ = try await fixture.assertRetainedPointerDelete(reopened, batchID: sent.batchID, activated: true)
        let deletes = await probe.suppliedDeletes
        XCTAssertTrue(deletes.isEmpty)
    }

    @MainActor
    func testCheckedRestoreReloadsTheIsolatedLibraryIfTheAccountStopsDuringAcknowledgement() async throws {
        for next: ICloudAccountState in [.noAccount, .available(accountLineage: "other-account")] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
            let local = try await fixture.persistence.activeLibrary()
            _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
            let account = SetupTestAccount()
            let probe = Self.peerRestoreProbe(fixture)
            let lifecycle = try fixture.lifecycle(fixture.persistence, transport: probe, account: account)
            let settings = Self.settingsForPeerRestore(fixture, lifecycle: lifecycle)
            var reloaded: [(store: UUID, showedPeerCopy: Bool)] = []
            settings.setEnableCompletionAction {
                let active = try await lifecycle.activeLibrary()
                let data = try await active.library.checkedSnapshot(sortedBy: .manual)
                let storage = try await fixture.persistence.snapshot()
                reloaded.append((storage.activeStore.id, data.snips.contains { $0.id == fixture.deleted.id }))
                if reloaded.count == 1 { await account.set(next) }
            }
            await settings.enableICloudSync()
            let offer = try XCTUnwrap(settings.peerCopyOffer)
            await settings.restoreSetupPeerCopies(offer)

            let final = try await fixture.persistence.snapshot()
            XCTAssertEqual(final.activeStore.kind, .localOnly)
            XCTAssertEqual(reloaded.map(\.store), [fixture.candidateID, final.activeStore.id])
            XCTAssertEqual(reloaded.map(\.showedPeerCopy), [true, false])
            XCTAssertEqual(settings.mode, .localOnly)
            XCTAssertEqual(settings.state, .failed(next == .noAccount ? .signInRequired : .iCloudAccountChanged))
            XCTAssertFalse(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
            let deletes = await probe.suppliedDeletes
            XCTAssertTrue(deletes.isEmpty)
            try await fixture.assertPayloadSurvives()
        }
    }

    @MainActor
    func testLateOrdinaryEnableReloadsButCannotOverrideAStopOrCancel() async throws {
        let settings = SyncedContentSettingsModel(mode: .localOnly, initialState: .enabling(.checkingAccount),
            cancelEnableAction: { .cancelled }, hasFailedPendingEnable: { true })
        let started = settings.recordSyncStarted()
        var reloads = 0
        try await SnipSnapCloudSyncResult.iCloudSyncEnabled.applyEnableProgress(to: settings, started: started) {
            reloads += 1
            settings.recordSyncStopped(.iCloudAccountChanged)
        }
        XCTAssertEqual(settings.state, .failed(.iCloudAccountChanged))
        XCTAssertEqual(settings.mode, .localOnly)
        let beforeCancel = settings.recordSyncStarted()
        await settings.cancelICloudSyncSetup()
        try await SnipSnapCloudSyncResult.iCloudSyncSettingUp(.checkingAccount)
            .applyEnableProgress(to: settings, started: beforeCancel) { reloads += 1 }
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(settings.state, .ready)
        XCTAssertEqual(settings.mode, .localOnly)
    }

    @MainActor
    func testFreshConsentCannotOverrideRecoveryFromTheFinalFetch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        _ = try await Self.stageOldPointerDelete(fixture)
        let remoteSource = try JSONSnipLibrary(fileURL: root.appendingPathComponent("peer-list.json"))
        let created = try await remoteSource.perform(.createList(name: "Independent list", systemImage: "list.bullet"), sortedBy: .manual)
        let list = try XCTUnwrap(created.snapshot.lists.first { $0.name == "Independent list" })
        let added = try await remoteSource.perform(.add(content: "peer child", origin: .quickEntry,
            source: nil, listID: list.id, attachmentURLs: [], requestID: UUID(), now: .distantPast), sortedBy: .manual)
        let child = try XCTUnwrap(added.snapshot.snips.first)
        let zone = fixture.descriptor.metadataZone
        let listDraft = try CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [
            .save(listDraft), .save(CloudFullRecordCodec.snipDraft(child, in: zone))
        ]), failures: [:])
        let serverList = await fixture.server.fullSnapshot(for: listDraft.id)
        let observedList = try XCTUnwrap(serverList)
        let late = Mutex(false)
        let probe = SetupRetryDeleteProbeTransport(fixture.transport(), beforeSending: { outbound in
            try Self.refuseDeletes(in: outbound, for: [fixture.deletedID, fixture.pointerID, fixture.payloadID])
            guard late.withLock({ value in defer { value = true }; return !value }) else { return }
            let sent = try await fixture.server.send(CloudOutboundBatch(operations: [
                .delete(observedList.id, base: observedList.shadow)
            ]), failures: [:])
            XCTAssertEqual(sent.items, [.deleted(observedList.id)])
        })
        let local = try await fixture.persistence.activeLibrary()
        _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        let lifecycle = try fixture.lifecycle(fixture.persistence, transport: probe)
        let settings = Self.settingsForPeerRestore(fixture, lifecycle: lifecycle)
        await settings.enableICloudSync()
        let offer = try XCTUnwrap(settings.peerCopyOffer)
        XCTAssertFalse(late.withLock { $0 })
        await settings.restoreSetupPeerCopies(offer)
        XCTAssertTrue(late.withLock { $0 })
        XCTAssertEqual(settings.mode, .localOnly)
        XCTAssertNil(settings.peerCopyOffer)
        let state = try await fixture.persistence.snapshot()
        XCTAssertEqual(state.activeStore.id, fixture.sourceStoreID)
        let candidate = try await fixture.persistence.libraryForTransition(storeID: fixture.candidateID)
        let recovery = try await candidate.cloudFullRecoveryEvents(namespaceKey: fixture.namespace.namespaceKey)
        XCTAssertTrue(recovery.contains { $0.kind == .deletedListPlacement })
        let localAfter = try await local.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(localAfter.snips.map(\.id)), fixture.remainingIDs)
        try await fixture.assertPayloadSurvives()
    }

    @MainActor
    func testInlineReceiptEnableCanReenterSetupAfterAccountIsolation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let stage = try await Self.stageOldPointerDelete(fixture)
        let first = try fixture.lifecycle(fixture.persistence, transport: Self.peerRestoreProbe(fixture))
        let settings = Self.settingsForPeerRestore(fixture, lifecycle: first)
        await settings.enableICloudSync()
        XCTAssertEqual(settings.mode, .iCloudSync)
        XCTAssertFalse(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
        _ = try await fixture.assertRetainedPointerDelete(fixture.persistence, batchID: stage.batchID, activated: true)

        _ = try await fixture.persistence.isolateActiveCloudStore(reason: .signedOut)
        try await fixture.persistence.resolveAccountIsolation(.remove)
        settings.recordSyncStopped(.signInRequired)
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let before = try await reopened.snapshot()
        XCTAssertEqual(before.activeStore.kind, .localOnly)
        let fresh = try fixture.lifecycle(reopened, transport: Self.peerRestoreProbe(fixture))
        let reentered = Self.settingsForPeerRestore(fixture, lifecycle: fresh)
        await reentered.enableICloudSync()
        XCTAssertEqual(reentered.mode, .iCloudSync)
        XCTAssertFalse(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
        _ = try await fixture.assertRetainedPointerDelete(reopened, batchID: stage.batchID, activated: true)
        try await fixture.assertPayloadSurvives()
    }

    @MainActor
    func testSettingsReoffersAfterProtectedPeerAttachmentTombstone() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        _ = try await Self.stageOldPointerDelete(fixture)
        let alias = try fixture.aliasDraft(parentID: fixture.deleted.id)
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [.save(alias)]), failures: [:])
        let local = try await fixture.persistence.activeLibrary()
        _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        let probe = Self.peerRestoreProbe(fixture)
        let lifecycle = try fixture.lifecycle(fixture.persistence, transport: probe)
        let settings = Self.settingsForPeerRestore(fixture, lifecycle: lifecycle)
        await settings.enableICloudSync()
        let stale = try XCTUnwrap(settings.peerCopyOffer)
        XCTAssertEqual(stale.copies.first?.attachmentNames, ["alias.txt"])
        let serverAlias = await fixture.server.fullSnapshot(for: alias.id)
        let removed = try await fixture.server.send(CloudOutboundBatch(operations: [
            .delete(alias.id, base: try XCTUnwrap(serverAlias).shadow)
        ]), failures: [:])
        XCTAssertEqual(removed.items, [.deleted(alias.id)])
        await settings.restoreSetupPeerCopies(stale)
        let fresh = try XCTUnwrap(settings.peerCopyOffer)
        XCTAssertEqual(fresh.copies.first?.attachmentNames, [])
        XCTAssertEqual(settings.mode, .localOnly)
        await settings.restoreSetupPeerCopies(fresh)
        XCTAssertEqual(settings.mode, .iCloudSync)
        let active = try await lifecycle.activeLibrary().library.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(active.snips.first { $0.id == fixture.deleted.id }?.attachments, [])
        XCTAssertFalse(PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: root))
        let deletes = await probe.suppliedDeletes
        XCTAssertTrue(deletes.isEmpty)
        try await fixture.assertPayloadSurvives()
    }

    @MainActor
    func testSettingsRestoresOnlyFreshlyConfirmedPeerTextAndAttachments() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let staged = try await Self.stageOldPointerDelete(fixture)
        let alias = try fixture.aliasDraft(parentID: fixture.deleted.id)
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [.save(alias)]), failures: [:])
        let local = try await fixture.persistence.activeLibrary()
        _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        let verifiedAssets = Mutex<[CloudRecordID]>([])
        let probe = SetupRetryDeleteProbeTransport(fixture.transport(), beforeSending: { outbound in
            try Self.refuseDeletes(in: outbound, for: [fixture.deletedID, fixture.pointerID, fixture.payloadID])
        }, beforeAssetFetch: { id in verifiedAssets.withLock { $0.append(id) } })
        let lifecycle = try fixture.lifecycle(fixture.persistence, transport: probe)
        let settings = Self.settingsForPeerRestore(fixture, lifecycle: lifecycle)
        let loaded = Mutex(false)
        settings.setEnableCompletionAction {
            _ = try await lifecycle.activeLibrary()
            loaded.withLock { $0 = true }
        }
        await settings.enableICloudSync()
        let offered = try XCTUnwrap(settings.peerCopyOffer)
        XCTAssertEqual(offered.copies.map(\.id), [fixture.deleted.id])
        XCTAssertEqual(offered.copies.first?.content, fixture.deleted.content)
        XCTAssertEqual(offered.copies.first?.listName, SnipList.inbox.name)
        XCTAssertEqual(offered.copies.first?.attachmentNames, ["alias.txt"])
        XCTAssertEqual(settings.mode, .localOnly)
        let held = try await local.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(held.snips.map(\.id)), fixture.remainingIDs)
        let survivor = try XCTUnwrap(held.snips.first { $0.content == "unrelated" })
        _ = try await local.perform(.update(
            id: survivor.id, content: "local edit while choosing", attachmentURLs: nil,
            expectedUpdatedAt: survivor.updatedAt, now: survivor.updatedAt.addingTimeInterval(1)
        ), sortedBy: .manual)

        try await Self.changePeerFields(in: fixture, id: fixture.deletedID, changed: ["text": .string("newer peer text")])
        await settings.restoreSetupPeerCopies(offered)
        let newerText = try XCTUnwrap(settings.peerCopyOffer)
        XCTAssertNotEqual(newerText, offered)
        XCTAssertEqual(newerText.copies.first?.content, "newer peer text")
        XCTAssertEqual(settings.mode, .localOnly)
        XCTAssertFalse(loaded.withLock { $0 })

        try await Self.changePeerFields(in: fixture, id: alias.id, changed: ["fileName": .string("renamed on peer.txt")])
        await settings.restoreSetupPeerCopies(newerText)
        let newerAttachment = try XCTUnwrap(settings.peerCopyOffer)
        XCTAssertNotEqual(newerAttachment, newerText)
        XCTAssertEqual(newerAttachment.copies.first?.attachmentNames, ["renamed on peer.txt"])
        XCTAssertEqual(settings.mode, .localOnly)
        let stillLocal = try await fixture.persistence.snapshot()
        XCTAssertEqual(stillLocal.activeStore.id, fixture.sourceStoreID)
        await settings.restoreSetupPeerCopies(newerText)
        XCTAssertEqual(settings.peerCopyOffer, newerAttachment)
        XCTAssertTrue(verifiedAssets.withLock { $0.isEmpty })

        await settings.restoreSetupPeerCopies(newerAttachment)
        XCTAssertEqual(settings.mode, .iCloudSync)
        XCTAssertEqual(verifiedAssets.withLock { $0 }, [fixture.payloadID, fixture.payloadID])
        XCTAssertTrue(loaded.withLock { $0 })
        XCTAssertNil(settings.peerCopyOffer)
        let active = try await fixture.persistence.snapshot()
        XCTAssertEqual(active.activeStore.id, fixture.candidateID)
        let library = try await fixture.persistence.libraryForTransition(storeID: active.activeStore.id)
        let final = try await library.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(final.snips.map(\.id)), fixture.remainingIDs.union([fixture.deleted.id]))
        XCTAssertEqual(final.snips.count, fixture.remainingIDs.count + 1)
        let restored = try XCTUnwrap(final.snips.first { $0.id == fixture.deleted.id })
        XCTAssertEqual(restored.content, "newer peer text")
        XCTAssertEqual(restored.listID, SnipList.inbox.id)
        XCTAssertEqual(restored.attachments.map(\.fileName), ["renamed on peer.txt"])
        XCTAssertEqual(final.snips.first { $0.id == survivor.id }?.content, "local edit while choosing")
        let attachment = try XCTUnwrap(restored.attachments.first)
        let expectedAttachmentID = try XCTUnwrap(UUID(uuidString: String(alias.id.name.dropFirst(2))))
        XCTAssertEqual(attachment.id, expectedAttachmentID)
        let transfer = CloudAttachmentTransferCoordinator(
            library: library, namespace: fixture.namespace, payloadZone: fixture.descriptor.payloadZone,
            transport: fixture.transport(), maximumCacheBytes: CloudAttachmentTransferCoordinator.standardMaximumCacheBytes
        )
        let downloaded = try await transfer.download(attachmentID: attachment.id)
        XCTAssertEqual(try Data(contentsOf: downloaded), fixture.bytes)
        _ = try await fixture.assertRetainedPointerDelete(fixture.persistence, batchID: staged.batchID, activated: true)
        let submitted = await probe.suppliedDeletes
        XCTAssertTrue(submitted.isEmpty)
        try await fixture.assertPayloadSurvives()
    }

    @MainActor
    func testSettingsReopenRequiresCompletePeerProofAndCancelInvalidatesAnOffer() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        _ = try await Self.stageOldPointerDelete(fixture)
        let alias = try fixture.aliasDraft(parentID: fixture.deleted.id)
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [.save(alias)]), failures: [:])
        let local = try await fixture.persistence.activeLibrary()
        _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        let firstLifecycle = try fixture.lifecycle(fixture.persistence, transport: Self.peerRestoreProbe(fixture))
        let first = Self.settingsForPeerRestore(fixture, lifecycle: firstLifecycle)
        await first.enableICloudSync()
        let beforeReopen = try XCTUnwrap(first.peerCopyOffer)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        for incomplete in [
            SetupRetryDeleteProbeTransport(fixture.transport(), omitFetchCompletion: true),
            SetupRetryDeleteProbeTransport(fixture.transport(), omittedRecords: [alias.id])
        ] {
            let interrupted = try fixture.lifecycle(reopened, transport: incomplete)
            do {
                _ = try await interrupted.restoreSetupPeerCopies(beforeReopen)
                XCTFail("Missing completion or known attachment metadata must not authorize restore.")
            } catch CloudCollectionError.syncNeedsAttention {}
            let partial = try await reopened.snapshot()
            XCTAssertEqual(partial.activeStore.id, fixture.sourceStoreID)
            let submitted = await incomplete.suppliedDeletes
            XCTAssertTrue(submitted.isEmpty)
        }

        let probe = Self.peerRestoreProbe(fixture)
        let lifecycle = try fixture.lifecycle(reopened, transport: probe)
        let settings = Self.settingsForPeerRestore(fixture, lifecycle: lifecycle)
        XCTAssertNil(settings.peerCopyOffer)
        let started = settings.recordSyncStarted(refreshingSetupOffer: true)
        do {
            _ = try await lifecycle.retrySynchronization()
            XCTFail("Retry only presents the offer.")
        } catch let offer as SyncedContentPeerCopyOffer {
            settings.recordSetupPeerCopyOffer(offer, started: started)
        }
        let checked = try XCTUnwrap(settings.peerCopyOffer)
        XCTAssertEqual(checked, beforeReopen)
        await settings.cancelICloudSyncSetup()
        XCTAssertNil(settings.peerCopyOffer)
        XCTAssertEqual(settings.mode, .localOnly)
        do {
            _ = try await lifecycle.restoreSetupPeerCopies(checked)
            XCTFail("Cancellation must invalidate the offer.")
        } catch CloudCollectionError.syncNeedsAttention {}
        let cancelled = try await reopened.snapshot()
        XCTAssertEqual(cancelled.activeStore.id, fixture.sourceStoreID)
        XCTAssertNil(cancelled.transition)
        let deletes = await probe.suppliedDeletes
        XCTAssertTrue(deletes.isEmpty)
    }

    @MainActor
    func testSettingsRechecksConsentAfterSetupSendsAndAfterAnUnswappedCrash() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        _ = try await Self.stageOldPointerDelete(fixture)
        let local = try await fixture.persistence.activeLibrary()
        _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        let changed = Mutex(false)
        let probe = SetupRetryDeleteProbeTransport(fixture.transport(), beforeSending: { outbound in
            try Self.refuseDeletes(in: outbound, for: [fixture.deletedID, fixture.pointerID, fixture.payloadID])
            guard changed.withLock({ value in defer { value = true }; return !value }) else { return }
            try await Self.changePeerFields(in: fixture, id: fixture.deletedID, changed: ["text": .string("peer edit during setup")])
        })
        let lifecycle = try fixture.lifecycle(fixture.persistence, transport: probe)
        let settings = Self.settingsForPeerRestore(fixture, lifecycle: lifecycle)
        await settings.enableICloudSync()
        let original = try XCTUnwrap(settings.peerCopyOffer)
        XCTAssertFalse(changed.withLock { $0 })
        await settings.restoreSetupPeerCopies(original)
        let rechecked = try XCTUnwrap(settings.peerCopyOffer)
        XCTAssertTrue(changed.withLock { $0 })
        XCTAssertEqual(rechecked.copies.first?.content, "peer edit during setup")
        XCTAssertEqual(settings.mode, .localOnly)
        let writable = try await local.checkedSnapshot(sortedBy: .manual)
        XCTAssertFalse(writable.snips.contains { $0.id == fixture.deleted.id })

        let crash = CrashInjector(point: .afterCandidateMergeDurability)
        let crashing = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
        let interrupted = try fixture.lifecycle(crashing, transport: Self.peerRestoreProbe(fixture))
        do {
            _ = try await interrupted.restoreSetupPeerCopies(rechecked)
            XCTFail("Expected interruption after the unswapped candidate commit.")
        } catch CrashInjector.Failure.injected {}
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let retryProbe = Self.peerRestoreProbe(fixture)
        let retry = try fixture.lifecycle(reopened, transport: retryProbe)
        let afterCrash = Self.settingsForPeerRestore(fixture, lifecycle: retry)
        await afterCrash.enableICloudSync()
        XCTAssertEqual(afterCrash.mode, .localOnly)
        XCTAssertEqual(afterCrash.peerCopyOffer, rechecked)
        let active = try await reopened.snapshot()
        XCTAssertEqual(active.activeStore.id, fixture.sourceStoreID)
        let deletes = await retryProbe.suppliedDeletes
        XCTAssertTrue(deletes.isEmpty)
        try await fixture.assertPayloadSurvives()
    }

    @MainActor
    func testSettingsRetryCanFinishWhenTheCheckedPeerCopyIsGone() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        _ = try await Self.stageOldPointerDelete(fixture)
        let local = try await fixture.persistence.activeLibrary()
        _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        let probe = Self.peerRestoreProbe(fixture)
        let lifecycle = try fixture.lifecycle(fixture.persistence, transport: probe)
        let settings = Self.settingsForPeerRestore(fixture, lifecycle: lifecycle)
        await settings.enableICloudSync()
        XCTAssertNotNil(settings.peerCopyOffer)
        try await fixture.removePeerParent()
        _ = try await lifecycle.retrySynchronization()
        let final = try await fixture.persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(final.snips.map(\.id)), fixture.remainingIDs)
        let submitted = await probe.suppliedDeletes
        XCTAssertTrue(submitted.isEmpty)
        try await fixture.assertPayloadSurvives()
    }

    @MainActor
    func testSettingsRejectsPeerConsentAfterGenerationChanges() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let local = try await fixture.persistence.activeLibrary()
        _ = try await local.perform(.delete(ids: [fixture.deleted.id]), sortedBy: .manual)
        let probe = Self.peerRestoreProbe(fixture)
        let lifecycle = try fixture.lifecycle(fixture.persistence, transport: probe)
        let settings = Self.settingsForPeerRestore(fixture, lifecycle: lifecycle)
        await settings.enableICloudSync()
        let offered = try XCTUnwrap(settings.peerCopyOffer)
        let replacement = CloudCollectionDescriptor.fresh(ownerName: "owner")
        await fixture.server.seedControl(replacement)
        await settings.restoreSetupPeerCopies(offered)
        XCTAssertEqual(settings.mode, .localOnly)
        XCTAssertNil(settings.peerCopyOffer)
        let current = try await fixture.persistence.snapshot()
        XCTAssertEqual(current.activeStore.id, fixture.sourceStoreID)
        let original = await fixture.server.fullSnapshot(for: fixture.deletedID)
        XCTAssertNotNil(original)
        let deletes = await probe.suppliedDeletes
        XCTAssertTrue(deletes.isEmpty)
    }

    @MainActor
    private static func settingsForPeerRestore(
        _ fixture: SetupRetryPointerFixture, lifecycle: SnipSnapICloudSyncLifecycle
    ) -> SyncedContentSettingsModel {
        let session = settingsSession(lifecycle)
        let settings = SyncedContentSettingsModel(
            mode: .localOnly,
            enableAction: { try await session.enableICloudSync() },
            restorePeerCopiesAction: { try await session.restoreSetupPeerCopies($0) },
            cancelEnableAction: { try await session.cancelICloudSyncSetup() },
            acknowledgeEnableAction: { try await session.acknowledgeDeferredEnableCompletion(for: $0, whileCurrent: $1) },
            hasFailedPendingEnable: { SnipSnapCloudAppAssembly.hasPendingSetup(rootURL: fixture.root) }
        )
        settings.setEnableCompletionAction { _ = try await session.activeLibrary() }
        return settings
    }

    private static func settingsSession(
        _ lifecycle: SnipSnapICloudSyncLifecycle, gate: AsyncOperationGate = AsyncOperationGate()
    ) -> SnipSnapCloudSyncSession {
        SnipSnapCloudSyncSession(
            synchronize: { try await lifecycle.synchronize() }, retry: { try await lifecycle.retrySynchronization() },
            enable: { try await lifecycle.enableICloudSync(offerPeerCopies: true) },
            restoreSetupPeerCopies: { try await lifecycle.restoreSetupPeerCopies($0) },
            acknowledgeEnable: { try await lifecycle.acknowledgeDeferredEnableCompletion(for: $0, whileCurrent: $1) },
            cancelEnable: { try await lifecycle.cancelPendingEnable() },
            delete: { .completed }, activeLibrary: { try await lifecycle.activeLibrary() }, operationGate: gate
        )
    }

    private static func peerRestoreProbe(_ fixture: SetupRetryPointerFixture) -> SetupRetryDeleteProbeTransport {
        SetupRetryDeleteProbeTransport(fixture.transport(), beforeSending: { outbound in
            try Self.refuseDeletes(in: outbound, for: [fixture.deletedID, fixture.pointerID, fixture.payloadID])
        })
    }

    private static func changePeerFields(
        in fixture: SetupRetryPointerFixture, id: CloudRecordID, changed: [String: CloudFieldValue]
    ) async throws {
        let snapshot = await fixture.server.fullSnapshot(for: id)
        let original = try XCTUnwrap(snapshot)
        let changed = CloudRecordDraft(
            id: original.id, recordType: original.recordType, schemaVersion: original.schemaVersion,
            routingFields: original.routingFields, encryptedFields: original.encryptedFields.merging(changed) { _, new in new },
            base: original.shadow
        )
        let result = try await fixture.server.send(CloudOutboundBatch(operations: [.save(changed)]), failures: [:])
        XCTAssertTrue(result.items.contains { if case .saved(let record) = $0 { record.id == id } else { false } })
    }

    private static func refuseDeletes(in batch: CloudOutboundBatch, for protected: Set<CloudRecordID>) throws {
        if batch.operations.contains(where: {
            if case .delete(let id, _) = $0 { return protected.contains(id) }
            return false
        }) {
            XCTFail("Protected pointer and payload deletes must be rejected before reaching the server.")
            throw CloudTransportError.sendFailed
        }
    }

    func testSetupRetainsPayloadWhenOrdinaryPublisherRecreatesPointerBeforeFirstActiveOffer() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let senderRoot = root.appendingPathComponent("sender")
        let sender = try SwiftDataSyncModePersistence(rootURL: senderRoot)
        let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
        let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account")
        let context = CloudCollectionSyncContext(namespace: namespace, metadataZone: descriptor.metadataZone,
            payloadZone: descriptor.payloadZone)
        let server = FakeCloudServer()
        await server.seedControl(descriptor)
        let makeTransport: @Sendable () -> FakeCloudRecordTransport = {
            FakeCloudRecordTransport(server: server, namespace: namespace, automaticallyFetchedZones: [descriptor.metadataZone])
        }
        func enable(_ mode: SwiftDataSyncModePersistence) async throws -> SwiftDataSnipLibrary {
            let coordinator = ICloudSyncModeCoordinator(
                persistence: mode, namespace: namespace, textZone: descriptor.metadataZone,
                payloadZone: descriptor.payloadZone, makeTransport: { makeTransport() }
            )
            let status = try await coordinator.enableOrRetry()
            XCTAssertEqual(status.state, .on)
            return try await mode.libraryForTransition(storeID: status.activeStoreID)
        }
        let local = try await sender.activeLibrary()
        try await Self.addSetupFixtureSnip("ordinary sender", to: local)
        let senderLibrary = try await enable(sender)
        let senderEdits = try await sender.activeLibrary()
        let original = try await senderEdits.checkedSnapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(original.snips.first)
        let bytes = Data("payload whose first pointer acknowledgement was lost".utf8)
        let file = root.appendingPathComponent("ordinary.txt")
        try bytes.write(to: file)
        let edited = try await senderEdits.perform(.editAttachments(
            snipID: snip.id, content: snip.content, edits: [.added(sourceURL: file)],
            expectedUpdatedAt: snip.updatedAt, now: snip.updatedAt.addingTimeInterval(1)
        ), sortedBy: .manual)
        let attachment = try XCTUnwrap(edited.snapshot.snips.first?.attachments.first)
        let pointerID = CloudRecordID(zone: descriptor.metadataZone, name: "a-\(attachment.id.uuidString.lowercased())")
        let raw = CloudFullSyncPersistence(library: senderLibrary, namespace: namespace,
            dataZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone)
        let loseAcknowledgement = SetupRetryDeleteProbeTransport(makeTransport(), afterSending: { outbound, sent in
            let submitted = outbound.operations.compactMap { operation -> CloudRecordDraft? in
                guard case .save(let draft) = operation, draft.id == pointerID else { return nil }
                return draft
            }
            guard let draft = submitted.first else { return }
            XCTAssertNil(draft.base)
            XCTAssertTrue(sent.items.contains { if case .saved(let value) = $0 { value.id == pointerID } else { false } })
            throw CloudTransportError.sendFailed
        })
        let senderDriver = CloudFullSyncCoordinator(store: raw, transport: loseAcknowledgement)
        _ = try await senderDriver.sendPending()  // Apply the payload acknowledgement.
        let payloadCommitted = try await senderLibrary.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
        let pending = try XCTUnwrap(payloadCommitted.publications.first)
        XCTAssertTrue(pending.payloadAccepted)
        XCTAssertFalse(pending.metadataAccepted)
        XCTAssertNil(pending.metadataShadowData)
        let payloadID = CloudAttachmentRecordCodec.recordID(pending.metadata.payloadIdentity)
        let beforeLoss = try await raw.loadEngineState()
        XCTAssertEqual(beforeLoss?.requiresInitialFetch, false)
        do {
            _ = try await senderDriver.sendPending()
            XCTFail("Expected the accepted first pointer response to stop before local staging.")
        } catch CloudTransportError.sendFailed {}
        let firstPointer = await server.fullSnapshot(for: pointerID)
        XCTAssertEqual(try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(firstPointer)).payloadIdentity,
            pending.metadata.payloadIdentity)

        let peerRoot = root.appendingPathComponent("peer")
        let preSwap = CrashInjector(point: .beforePointerSwap)
        let peer = try SwiftDataSyncModePersistence(rootURL: peerRoot, crashHook: preSwap.hit)
        let peerLocal = try await peer.activeLibrary()
        try await Self.addSetupFixtureSnip("independent setup source", to: peerLocal)
        do {
            _ = try await enable(peer)
            XCTFail("Expected setup to reach the pre-swap hook.")
        } catch CrashInjector.Failure.injected {}
        let peerStore = try await peer.snapshot()
        let peerCandidateID = try XCTUnwrap(peerStore.transition?.candidateStoreID)
        let peerLibrary = try await peer.libraryForTransition(storeID: peerCandidateID)
        let seen = try await peerLibrary.checkedSnapshot(sortedBy: .manual)
        let peerSnip = try XCTUnwrap(seen.snips.first { $0.id == snip.id })
        XCTAssertEqual(peerSnip.attachments.map(\.id), [attachment.id])
        let aliasParent = try XCTUnwrap(seen.snips.first { $0.content == "independent setup source" })

        // A cached alias queues an ordinary cleanup independently of the retained receipt.
        let aliasID = UUID()
        let aliasPointer = CloudRecordID(zone: descriptor.metadataZone, name: "a-\(aliasID.uuidString.lowercased())")
        let acceptedPointer = try XCTUnwrap(firstPointer)
        let aliasDraft = CloudRecordDraft(
            id: aliasPointer, recordType: acceptedPointer.recordType, schemaVersion: acceptedPointer.schemaVersion,
            routingFields: acceptedPointer.routingFields,
            encryptedFields: acceptedPointer.encryptedFields.merging([
                "attachmentID": .string(aliasID.uuidString.lowercased()),
                "snipID": .string(aliasParent.id.uuidString.lowercased())
            ]) { _, new in new },
            base: nil
        )
        _ = try await server.send(CloudOutboundBatch(operations: [.save(aliasDraft)]), failures: [:])
        let peerRaw = CloudFullSyncPersistence(library: peerLibrary, namespace: namespace,
            dataZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone)
        let peerDriver = CloudFullSyncCoordinator(store: peerRaw, transport: makeTransport(),
            fetchScope: .zones([descriptor.metadataZone]))
        try await peerDriver.fetchRemote()
        let withAlias = try await peerLibrary.checkedSnapshot(sortedBy: .manual)
        let editedParent = try XCTUnwrap(withAlias.snips.first { $0.id == peerSnip.id })
        XCTAssertEqual(withAlias.snips.first { $0.id == aliasParent.id }?.attachments.map(\.id), [aliasID])
        _ = try await peerLibrary.perform(.editAttachments(
            snipID: peerSnip.id, content: peerSnip.content, edits: [],
            expectedUpdatedAt: editedParent.updatedAt, now: editedParent.updatedAt.addingTimeInterval(1)
        ), sortedBy: .manual)
        let pendingDelete = try await peerRaw.pendingChanges()
        let delete = try XCTUnwrap(pendingDelete.operations.first {
            if case .delete(pointerID, _) = $0 { return true }
            return false
        })
        let pointerOnly = CloudOutboundBatch(operations: [delete])
        let sent = try await server.send(pointerOnly, failures: [:])
        XCTAssertEqual(sent.items, [.deleted(pointerID)])
        try await peerRaw.stage(.sent(sent), outbound: pointerOnly)
        let aliasBeforeDelete = await server.fullSnapshot(for: aliasPointer)
        let removedAlias = try await server.send(CloudOutboundBatch(operations: [
            .delete(aliasPointer, base: try XCTUnwrap(aliasBeforeDelete).shadow)
        ]), failures: [:])
        XCTAssertEqual(removedAlias.items, [.deleted(aliasPointer)])
        let pointerBeforeResume = await server.fullSnapshot(for: pointerID)
        XCTAssertNil(pointerBeforeResume)
        let retainedPayload = await server.asset(for: payloadID, field: CloudAttachmentRecordCodec.assetField)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retainedPayload)), bytes)

        let reopened = try SwiftDataSyncModePersistence(rootURL: senderRoot)
        let reopenedID = try await reopened.snapshot().activeStore.id
        let reopenedLibrary = try await reopened.libraryForTransition(storeID: reopenedID)
        let reopenedRaw = CloudFullSyncPersistence(library: reopenedLibrary, namespace: namespace,
            dataZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone)
        let afterLoss = try await reopenedRaw.loadEngineState()
        XCTAssertEqual(afterLoss, beforeLoss)
        let stages = try await reopenedRaw.stagedBatches()
        XCTAssertTrue(stages.isEmpty)
        let durable = try await reopenedLibrary.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(durable.publications, [pending])
        let startup = ResumedAttachmentOfferTransport(makeTransport())
        let ordinary = CloudFullRecordCollectionSyncDriver(persistence: reopened, makeTransport: { _ in startup },
            beforeRecordWork: { _ in
                guard await server.fetchControl()?.descriptor == descriptor else { throw CloudCollectionError.syncNeedsAttention }
            })
        try await ordinary.prepareAutomaticSync(context)
        let startedWith = await startup.resumedState
        XCTAssertEqual(startedWith, beforeLoss)
        let offers = try await startup.checkedInitialOffer()
        let draft = try XCTUnwrap(offers.compactMap { operation -> CloudRecordDraft? in
            guard case .save(let draft) = operation, draft.id == pointerID else { return nil }
            return draft
        }.first)
        XCTAssertNil(draft.base)
        let metadata = try CloudAttachmentRecordCodec.metadata(from: draft,
            metadataZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone)
        XCTAssertEqual(metadata.payloadIdentity, pending.metadata.payloadIdentity)
        XCTAssertFalse(offers.contains { if case .delete = $0 { true } else { false } })
        let eventsBeforeSave = await startup.fake.events()
        XCTAssertFalse(eventsBeforeSave.contains(.fetched))
        let checked = Mutex<[UUID]>([])
        let recreated = Mutex(false)
        let setup = SetupRetryDeleteProbeTransport(makeTransport(), beforeSending: { outbound in
            try Self.refuseDeletes(in: outbound, for: [pointerID, payloadID])
        }, afterFetching: { batch in
            checked.withLock { $0.append(batch.id) }
        }, afterConfirming: { id in
            guard checked.withLock({ $0.last == id && $0.count == 2 }) else { return }
            let result = try await startup.send(CloudOutboundBatch(operations: [.save(draft)]))
            let saved = try XCTUnwrap(result.items.compactMap { item in
                if case .saved(let record) = item { return record }
                return nil
            }.first)
            XCTAssertEqual(saved.id, pointerID)
            XCTAssertEqual(try CloudAttachmentRecordCodec.metadata(from: saved).payloadIdentity, pending.metadata.payloadIdentity)
            recreated.withLock { $0 = true }
        })
        let enabling = try SwiftDataSyncModePersistence(rootURL: peerRoot)
        let peerMode = ICloudSyncModeCoordinator(
            persistence: enabling, namespace: namespace, textZone: descriptor.metadataZone,
            payloadZone: descriptor.payloadZone, makeTransport: { setup }
        )
        let enabled = try await peerMode.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        XCTAssertTrue(recreated.withLock { $0 })
        let storedReceipts = await enabling.retainedSetupPointerDeletes(in: namespace.binding)
        XCTAssertEqual(storedReceipts.map(\.key), [.init(batchID: sent.id, pointer: CloudAttachmentRecordCodec.identity(pointerID))])
        XCTAssertEqual(storedReceipts.first?.payloadIdentities, [pending.metadata.payloadIdentity])
        let setupDeletes = await setup.suppliedDeletes
        XCTAssertTrue(setupDeletes.isEmpty)

        let activeMode = try SwiftDataSyncModePersistence(rootURL: peerRoot)
        let activeID = try await activeMode.snapshot().activeStore.id
        XCTAssertEqual(activeID, peerCandidateID)
        let activeLibrary = try await activeMode.libraryForTransition(storeID: activeID)
        let beforeActiveFetch = try await activeLibrary.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(beforeActiveFetch.cleanups.contains { $0.identity == pending.metadata.payloadIdentity })
        XCTAssertFalse(beforeActiveFetch.publications.contains { $0.metadataIdentity == CloudAttachmentRecordCodec.identity(pointerID) })
        let activeStartup = ResumedAttachmentOfferTransport(makeTransport())
        let active = CloudFullRecordCollectionSyncDriver(persistence: activeMode, makeTransport: { _ in activeStartup })
        try await active.prepareAutomaticSync(context)
        let firstOffer = try await activeStartup.checkedInitialOffer()
        try Self.refuseDeletes(in: CloudOutboundBatch(operations: firstOffer), for: [pointerID, payloadID])
        let initial = await activeStartup.suppliedInitialOperations
        XCTAssertFalse(initial.contains { $0.id == payloadID || $0.id == pointerID })
        let providerBlocks = await activeStartup.blockedRecordIDs
        XCTAssertEqual(providerBlocks, [payloadID])
        let activeEvents = await activeStartup.fake.events()
        XCTAssertFalse(activeEvents.contains(.fetched))
        _ = try await active.fetch(context)
        let visible = try await activeLibrary.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(visible.snips.first { $0.id == snip.id }?.attachments.map(\.id), [attachment.id])
        let reopenedReceipts = await activeMode.retainedSetupPointerDeletes(in: namespace.binding)
        XCTAssertEqual(reopenedReceipts, storedReceipts)
        try await active.prepareManualRetry(context)
        let afterRetry = await activeMode.retainedSetupPointerDeletes(in: namespace.binding)
        XCTAssertEqual(afterRetry, storedReceipts)

        let ordinaryProbe = SetupRetryDeleteProbeTransport(makeTransport(), beforeSending: { outbound in
            try Self.refuseDeletes(in: outbound, for: [pointerID, payloadID])
        })
        let ordinaryActive = CloudFullRecordCollectionSyncDriver(persistence: activeMode, makeTransport: { _ in ordinaryProbe })
        let adoptedEdits = try await activeMode.activeLibrary()
        let adopted = try await adoptedEdits.checkedSnapshot(sortedBy: .manual)
        let other = try XCTUnwrap(adopted.snips.first { $0.id == aliasParent.id })
        let otherFile = root.appendingPathComponent("unrelated.txt")
        try Data("unrelated file".utf8).write(to: otherFile)
        let added = try await adoptedEdits.perform(.editAttachments(
            snipID: other.id, content: other.content, edits: [.added(sourceURL: otherFile)],
            expectedUpdatedAt: other.updatedAt, now: other.updatedAt.addingTimeInterval(1)
        ), sortedBy: .manual)
        let otherEdited = try XCTUnwrap(added.snapshot.snips.first { $0.id == other.id })
        _ = try await ordinaryActive.send(context)
        let published = try await activeLibrary.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
        let otherPublication = try XCTUnwrap(published.publications.first { $0.metadata.snipID == other.id })
        XCTAssertTrue(otherPublication.metadataAccepted)
        let otherPayload = CloudAttachmentRecordCodec.recordID(otherPublication.metadata.payloadIdentity)
        let otherPointer = CloudAttachmentRecordCodec.recordID(otherPublication.metadataIdentity)
        _ = try await adoptedEdits.perform(.editAttachments(
            snipID: other.id, content: other.content, edits: [],
            expectedUpdatedAt: otherEdited.updatedAt, now: otherEdited.updatedAt.addingTimeInterval(1)
        ), sortedBy: .manual)
        _ = try await ordinaryActive.send(context)
        let ordinaryDeletes = await ordinaryProbe.suppliedDeletes
        XCTAssertEqual(ordinaryDeletes, [otherPointer, otherPayload])
        let settledOtherPayload = await server.fullSnapshot(for: otherPayload)
        XCTAssertNil(settledOtherPayload)

        try await activeMode.activateEmptyCollection(namespace: nil)
        try await activeMode.activateEmptyCollection(namespace: namespace.binding)
        let replacement = try SwiftDataSyncModePersistence(rootURL: peerRoot)
        let replacementID = try await replacement.snapshot().activeStore.id
        XCTAssertNotEqual(replacementID, activeID)
        let replacementLibrary = try await replacement.libraryForTransition(storeID: replacementID)
        let replacementRaw = CloudFullSyncPersistence(library: replacementLibrary, namespace: namespace,
            dataZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone, modePersistence: replacement)
        let replacementAdmission = try await replacementRaw.outboundAdmission()
        XCTAssertEqual(replacementAdmission.blockedRecordIDs, [payloadID])
        let replacementReceipts = await replacement.retainedSetupPointerDeletes(in: namespace.binding)
        XCTAssertEqual(replacementReceipts, storedReceipts)
        let intact = await server.asset(for: payloadID, field: CloudAttachmentRecordCodec.assetField)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(intact)), bytes)
    }

    func testSetupRetainedReceiptKeepsExactReplacementLineageAcrossRemap() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true)
        let replacementFile = root.appendingPathComponent("replacement.txt")
        let replacementBytes = Data("replacement attachment".utf8)
        try replacementBytes.write(to: replacementFile)
        let staged = try await Self.stageOldPointerDelete(fixture, replacementFile: replacementFile)
        try await CloudSetupRetryCapture.retainStagedPointerDeletes(in: fixture.persistence)
        let receipt = try await fixture.assertRetainedPointerDelete(fixture.persistence, batchID: staged.batchID)
        let dependency = try XCTUnwrap(receipt.replacementDependencies?.first)
        let replacementID = dependency.attachmentID
        let originalID = try XCTUnwrap(UUID(uuidString: String(fixture.pointerID.name.dropFirst(2))))
        try await fixture.raw.commitStagedBatch(
            staged, deferredSetupPointerDeletes: [originalID: .init(receipt: receipt, metadataShadow: fixture.shadow.data)]
        )
        let candidate = try await fixture.persistence.libraryForTransition(storeID: fixture.candidateID)
        let driver = CloudFullSyncCoordinator(
            store: fixture.raw, transport: fixture.transport(), fetchScope: .zones([fixture.descriptor.metadataZone]),
            initializeOutboundOnStart: false
        )
        try await driver.prepareManualRetry(forceInitialFetch: true)
        try await driver.fetchRemote()
        let before = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        let pending = try XCTUnwrap(before.publications.first)
        XCTAssertFalse(pending.metadataAccepted)
        XCTAssertEqual(pending.metadata.attachmentID, replacementID)
        let replacementDraft = try CloudAttachmentRecordCodec.metadataDraft(pending)
        let missing = CloudSentBatch(id: UUID(), items: [.unknownItem(replacementDraft.id)], engineState: nil)
        try await fixture.raw.stage(.sent(missing), outbound: CloudOutboundBatch(operations: [.save(replacementDraft)]))
        let stages = try await fixture.raw.stagedBatches()
        let remap = try XCTUnwrap(stages.first { $0.batchID == missing.id })
        try await fixture.raw.commitStagedBatch(remap, setupReplacements: [dependency])
        let remaps = try await candidate.setupPointerReplacementRemaps(namespaceKey: fixture.namespace.namespaceKey)
        let remappedID = try XCTUnwrap(remaps[dependency]).target.attachmentID
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        try await CloudSetupRetryCapture.retainStagedPointerDeletes(in: reopened)
        let promoted = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID)
        XCTAssertEqual(promoted.replacementDependencies?.map(\.attachmentID), [remappedID])
        let remappedStorage = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        let remapped = try XCTUnwrap(remappedStorage.publications.first)
        XCTAssertEqual(remapped.metadata.attachmentID, remappedID)
        let duplicateID = UUID()
        let duplicateMetadata = CloudAttachmentMetadataValue(
            attachmentID: duplicateID, snipID: remapped.metadata.snipID, position: remapped.metadata.position,
            fileName: remapped.metadata.fileName, contentType: remapped.metadata.contentType,
            byteCount: remapped.metadata.byteCount, sha256: remapped.metadata.sha256,
            payloadIdentity: CloudAttachmentRecordCodec.identity(CloudRecordID(
                zone: fixture.descriptor.payloadZone, name: UUID().uuidString.lowercased()
            ))
        )
        let duplicate = CloudAttachmentPublication(
            metadata: duplicateMetadata, metadataIdentity: CloudAttachmentRecordCodec.identity(CloudRecordID(
                zone: fixture.descriptor.metadataZone, name: "a-\(duplicateID.uuidString.lowercased())"
            )), sourceURL: replacementFile, payloadAccepted: true, payloadShadowData: nil,
            metadataAccepted: false, metadataShadowData: nil, revision: 0
        )
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [
            .save(CloudAttachmentRecordCodec.payloadDraft(duplicate)),
            .save(CloudAttachmentRecordCodec.metadataDraft(duplicate))
        ]), failures: [:])
        try await driver.prepareManualRetry(forceInitialFetch: true)
        try await driver.fetchRemote()
        let afterDuplicate = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        let stillPending = try XCTUnwrap(afterDuplicate.publications.first { $0.metadata.attachmentID == remappedID })
        XCTAssertFalse(stillPending.metadataAccepted)
        try await candidate.commitCloudAttachmentTransitions(
            namespaceKey: fixture.namespace.namespaceKey,
            transitions: [.operationFailed(attachmentID: remappedID, expectedRevision: stillPending.revision, failure: .accessDenied)]
        )
        let afterFailure = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID)
        XCTAssertEqual(afterFailure, promoted)

        let publishing = CloudAttachmentPublication(
            metadata: remapped.metadata, metadataIdentity: remapped.metadataIdentity,
            sourceURL: replacementFile, payloadAccepted: true, payloadShadowData: nil,
            metadataAccepted: false, metadataShadowData: nil, revision: 0
        )
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [
            .save(CloudAttachmentRecordCodec.payloadDraft(publishing)),
            .save(CloudAttachmentRecordCodec.metadataDraft(publishing))
        ]), failures: [:])
        try await driver.prepareManualRetry(forceInitialFetch: true)
        try await driver.fetchRemote()
        let publishedID = CloudAttachmentRecordCodec.recordID(remapped.metadataIdentity)
        let published = await fixture.server.fullSnapshot(for: publishedID)
        let accepted = try XCTUnwrap(published)
        let wrongBytes = Data("different replacement content".utf8)
        let wrongFile = root.appendingPathComponent("wrong-bytes.txt")
        try wrongBytes.write(to: wrongFile)
        let wrongPayloadID = CloudRecordID(zone: fixture.descriptor.payloadZone, name: UUID().uuidString.lowercased())
        let wrongMetadata = CloudAttachmentMetadataValue(
            attachmentID: remappedID, snipID: remapped.metadata.snipID, position: remapped.metadata.position,
            fileName: remapped.metadata.fileName, contentType: remapped.metadata.contentType,
            byteCount: Int64(wrongBytes.count), sha256: Data(SHA256.hash(data: wrongBytes)),
            payloadIdentity: CloudAttachmentRecordCodec.identity(wrongPayloadID)
        )
        let wrongPublication = CloudAttachmentPublication(
            metadata: wrongMetadata, metadataIdentity: remapped.metadataIdentity,
            sourceURL: wrongFile, payloadAccepted: true, payloadShadowData: nil,
            metadataAccepted: false, metadataShadowData: accepted.shadow.data, revision: 0
        )
        let otherParent = try XCTUnwrap(fixture.remainingIDs.sorted { $0.uuidString < $1.uuidString }.first)
        let wrongParent = CloudRecordDraft(
            id: accepted.id, recordType: accepted.recordType, schemaVersion: accepted.schemaVersion,
            routingFields: accepted.routingFields,
            encryptedFields: accepted.encryptedFields.merging(["snipID": .string(otherParent.uuidString.lowercased())]) { _, new in new },
            base: accepted.shadow
        )
        for changed in [
            [CloudOutboundOperation.save(wrongParent)],
            [.save(try CloudAttachmentRecordCodec.payloadDraft(wrongPublication)),
                .save(try CloudAttachmentRecordCodec.metadataDraft(wrongPublication))]
        ] {
            var operations = changed
            let latest = await fixture.server.fullSnapshot(for: publishedID)
            let base = try XCTUnwrap(latest).shadow
            if case .save(let draft) = operations.removeLast() {
                operations.append(.save(CloudRecordDraft(
                    id: draft.id, recordType: draft.recordType, schemaVersion: draft.schemaVersion,
                    routingFields: draft.routingFields, encryptedFields: draft.encryptedFields, base: base
                )))
            }
            let changedResult = try await fixture.server.send(CloudOutboundBatch(operations: operations), failures: [:])
            XCTAssertTrue(changedResult.items.contains { if case .saved(let value) = $0 { value.id == publishedID } else { false } })
            try await driver.prepareManualRetry(forceInitialFetch: true)
            try await driver.fetchRemote()
            let observedReceipt = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID)
            XCTAssertEqual(observedReceipt, promoted)
        }
        let latest = await fixture.server.fullSnapshot(for: publishedID)
        let reordered = CloudRecordDraft(
            id: accepted.id, recordType: accepted.recordType, schemaVersion: accepted.schemaVersion,
            routingFields: accepted.routingFields,
            encryptedFields: accepted.encryptedFields.merging([
                "position": .int64(2), "fileName": .string("a normal rename.txt")
            ]) { _, new in new },
            base: try XCTUnwrap(latest).shadow
        )
        let reorderedResult = try await fixture.server.send(
            CloudOutboundBatch(operations: [.save(reordered)]), failures: [:]
        )
        let reorderedRecord = try XCTUnwrap(reorderedResult.items.compactMap { item in
            if case .saved(let record) = item { return record }
            return nil
        }.first)
        XCTAssertEqual(try CloudAttachmentRecordCodec.metadata(from: reorderedRecord).position, 2)
        try await driver.prepareManualRetry(forceInitialFetch: true)
        try await driver.fetchRemote()
        let reorderedReceipt = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID)
        XCTAssertEqual(reorderedReceipt, promoted)
        let finalLedger = try await candidate.cloudAttachmentStorageSnapshot(
            namespaceKey: fixture.namespace.namespaceKey
        )
        XCTAssertTrue(finalLedger.cleanups.isEmpty)
        try await fixture.assertPayloadSurvives()

        let probe = SetupRetryDeleteProbeTransport(fixture.transport())
        try await fixture.lifecycle(reopened, transport: probe).cancelPendingEnable()
        let cancelled = try await fixture.assertRetainedPointerDelete(reopened, batchID: staged.batchID)
        XCTAssertEqual(cancelled.replacementDependencies?.map(\.attachmentID), [remappedID])
        let replacement = try SwiftDataSyncModePersistence(rootURL: root)
        let result = try await fixture.lifecycle(replacement, transport: probe).enableICloudSync()
        guard case .checked = result else { return XCTFail("Expected a store-bound enable completion.") }
        let newStore = try await replacement.snapshot().activeStore.id
        XCTAssertNotEqual(newStore, fixture.candidateID)
        let library = try await replacement.libraryForTransition(storeID: newStore)
        let newLedger = try await library.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        XCTAssertTrue(newLedger.cleanups.isEmpty)
        let retained = try await fixture.assertRetainedPointerDelete(replacement, batchID: staged.batchID, activated: true)
        XCTAssertEqual(retained, cancelled)
        let deletes = await probe.suppliedDeletes
        XCTAssertTrue(deletes.isEmpty)
        try await fixture.assertPayloadSurvives()
    }

    func testSetupReconstructsUnpublishedReplacementAfterCancelAndPayloadCollision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Self.setupRetryPointerFixture(root: root, pointerOnDeletedSnip: true, sourceOwnsPointer: true)
        let source = try await fixture.persistence.activeLibrary()
        let replacementFile = root.appendingPathComponent("replacement.txt")
        let bytes = Data("user's replacement bytes".utf8)
        try bytes.write(to: replacementFile)
        let edited = try await source.perform(.editAttachments(
            snipID: fixture.deleted.id, content: fixture.deleted.content,
            edits: [.added(sourceURL: replacementFile)], expectedUpdatedAt: fixture.deleted.updatedAt,
            now: fixture.deleted.updatedAt.addingTimeInterval(1)
        ), sortedBy: .manual)
        let attachment = try XCTUnwrap(edited.snapshot.snips.first { $0.id == fixture.deleted.id }?.attachments.first)
        let fake = fixture.transport()
        let failingUpload = SetupRetryDeleteProbeTransport(fake, beforeSending: { batch in
            for case .save(let draft) in batch.operations where draft.recordType == CloudAttachmentRecordCodec.payloadRecordType {
                await fake.failNextSentItem(draft.id, failure: .retryable)
            }
        })
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let interrupted = try await fixture.coordinator(reopened, transport: failingUpload).enableOrRetry()
        XCTAssertEqual(interrupted.state, .settingUp)
        let failedSetup = await reopened.setupRetryEvidence(namespace: fixture.namespace.binding)
        let retained = try XCTUnwrap(failedSetup?.acceptedPointerDeletes.first)
        let dependency = try XCTUnwrap(retained.replacementDependencies?.first)
        XCTAssertEqual(dependency.attachmentID, attachment.id)
        let originalAllocation = CloudAttachmentRecordCodec.recordID(dependency.payloadIdentity)
        let replacementPointer = CloudRecordID(
            zone: fixture.descriptor.metadataZone, name: "a-\(attachment.id.uuidString.lowercased())"
        )
        let beforeCancel = await fixture.server.fullSnapshot(for: replacementPointer)
        XCTAssertNil(beforeCancel)
        try await fixture.lifecycle(reopened, transport: failingUpload).cancelPendingEnable()

        let occupiedBytes = Data("unrelated existing payload".utf8)
        let occupiedFile = root.appendingPathComponent("occupied.txt")
        try occupiedBytes.write(to: occupiedFile)
        let occupied = CloudAttachmentPublication(
            metadata: .init(attachmentID: UUID(), snipID: fixture.deleted.id, position: 0, fileName: "occupied.txt",
                contentType: "text/plain", byteCount: Int64(occupiedBytes.count),
                sha256: Data(SHA256.hash(data: occupiedBytes)), payloadIdentity: dependency.payloadIdentity),
            metadataIdentity: CloudAttachmentRecordCodec.identity(replacementPointer),
            sourceURL: occupiedFile, payloadAccepted: false, payloadShadowData: nil,
            metadataAccepted: false, metadataShadowData: nil, revision: 0
        )
        _ = try await fixture.server.send(CloudOutboundBatch(operations: [
            .save(CloudAttachmentRecordCodec.payloadDraft(occupied))
        ]), failures: [:])
        let fresh = try SwiftDataSyncModePersistence(rootURL: root)
        let probe = SetupRetryDeleteProbeTransport(fixture.transport())
        let outcome = try await fixture.lifecycle(fresh, transport: probe).enableICloudSync()
        guard case .checked = outcome else { return XCTFail("Expected a store-bound enable completion.") }
        let events = await probe.fake.events()
        XCTAssertTrue(events.contains { if case .sent(let ids) = $0 { ids.contains(originalAllocation) } else { false } })
        let publishedPointer = await fixture.server.fullSnapshot(for: replacementPointer)
        let published = try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(publishedPointer))
        XCTAssertEqual(published.attachmentID, attachment.id)
        XCTAssertEqual(published.snipID, fixture.deleted.id)
        XCTAssertEqual(published.sha256, Data(SHA256.hash(data: bytes)))
        XCTAssertNotEqual(published.payloadIdentity, dependency.payloadIdentity)
        let replacementPayload = await fixture.server.asset(
            for: CloudAttachmentRecordCodec.recordID(published.payloadIdentity), field: CloudAttachmentRecordCodec.assetField
        )
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replacementPayload)), bytes)
        let survivingOccupied = await fixture.server.asset(for: originalAllocation, field: CloudAttachmentRecordCodec.assetField)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(survivingOccupied)), occupiedBytes)
        let deletes = await probe.suppliedDeletes
        XCTAssertTrue(deletes.isEmpty)
        try await fixture.assertPayloadSurvives()
    }

    func testSetupCancelRetainsAnUnconsumedLegacyReceiptButIgnoresAnUnknownPointer() async throws {
        for accepted in [true, false] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try await Self.setupRetryPointerFixture(
                root: root, pointerOnDeletedSnip: true, sourceOwnsPointer: !accepted
            )
            if !accepted {
                _ = try await fixture.server.send(CloudOutboundBatch(operations: [
                    .delete(fixture.pointerID, base: fixture.shadow)
                ]), failures: [:])
            }
            let staged = try await Self.stageOldPointerDelete(fixture, accepted: accepted)
            let candidate = try await fixture.persistence.libraryForTransition(storeID: fixture.candidateID)
            if accepted {
                try await Self.recordPointerFailure(in: fixture, candidate: candidate)
            }
            let restarted = try SwiftDataSyncModePersistence(rootURL: root)
            let probe = SetupRetryDeleteProbeTransport(fixture.transport())
            if !accepted {
                let local = try await restarted.activeLibrary()
                let before = try await local.checkedSnapshot(sortedBy: .manual)
                let kept = try XCTUnwrap(before.snips.first { $0.id == fixture.deleted.id })
                XCTAssertEqual(kept.attachments.map { "a-\($0.id.uuidString.lowercased())" }, [fixture.pointerID.name])
                let removal = try await local.perform(.editAttachments(
                    snipID: kept.id, content: kept.content, edits: [],
                    expectedUpdatedAt: kept.updatedAt, now: kept.updatedAt.addingTimeInterval(1)
                ), sortedBy: .manual)
                XCTAssertEqual(removal.snapshot.snips.first { $0.id == kept.id }?.attachments, [])
                let held = try await fixture.coordinator(restarted, transport: probe).enableOrRetry()
                XCTAssertEqual(held.state, .needsAttention)
                let ledger = try await candidate.cloudAttachmentStorageSnapshot(
                    namespaceKey: fixture.namespace.namespaceKey
                )
                XCTAssertTrue(ledger.cleanups.isEmpty)
                let remaining = try await fixture.raw.stagedBatches()
                XCTAssertEqual(remaining.map(\.batchID), [staged.batchID])
            }
            try await fixture.lifecycle(restarted, transport: probe).cancelPendingEnable()
            let afterCancel = try SwiftDataSyncModePersistence(rootURL: root)
            let history = await afterCancel.setupRetryEvidence(namespace: fixture.namespace.binding)
            XCTAssertEqual(history?.acceptedPointerDeletes.map(\.key.batchID), accepted ? [staged.batchID] : [])
            let cancelled = try await afterCancel.snapshot()
            XCTAssertNil(cancelled.transition)
            let events = await probe.fake.events()
            XCTAssertTrue(events.isEmpty)
            if !accepted {
                let freshProbe = SetupRetryDeleteProbeTransport(fixture.transport())
                let outcome = try await fixture.lifecycle(afterCancel, transport: freshProbe).enableICloudSync()
                XCTAssertEqual(outcome, .enabled)
                let active = try await afterCancel.activeLibrary().checkedSnapshot(sortedBy: .manual)
                XCTAssertEqual(active.snips.first { $0.id == fixture.deleted.id }?.attachments, [])
                let activeID = try await afterCancel.snapshot().activeStore.id
                XCTAssertNotEqual(activeID, fixture.candidateID)
                let fresh = try await afterCancel.libraryForTransition(storeID: activeID)
                let ledger = try await fresh.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
                XCTAssertTrue(ledger.cleanups.isEmpty)
                let deletes = await freshProbe.suppliedDeletes
                XCTAssertTrue(deletes.isEmpty)
            }
            try await fixture.assertPayloadSurvives()
        }
    }

    private static func addSetupFixtureSnip(_ content: String, to library: any SnipLibrary) async throws {
        _ = try await library.perform(.add(
            content: content, origin: .quickEntry, source: nil, listID: SnipList.inbox.id,
            attachmentURLs: [], requestID: UUID(), now: Date()
        ), sortedBy: .chronological)
    }

    private static func recordPointerFailure(
        in fixture: SetupRetryPointerFixture, candidate: SwiftDataSnipLibrary
    ) async throws {
        let snapshot = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
        let publication = try XCTUnwrap(snapshot.publications.first {
            $0.metadataIdentity == CloudAttachmentRecordCodec.identity(fixture.pointerID)
        })
        try await candidate.commitCloudAttachmentTransitions(
            namespaceKey: fixture.namespace.namespaceKey,
            transitions: [.operationFailed(
                attachmentID: publication.metadata.attachmentID,
                expectedRevision: publication.revision, failure: .retryable
            )]
        )
    }

    private static func stageOldPointerDelete(
        _ fixture: SetupRetryPointerFixture, accepted: Bool = true, replacementFile: URL? = nil
    ) async throws -> CloudFullBatchCommit {
        let candidate = try await fixture.persistence.libraryForTransition(storeID: fixture.candidateID)
        let before = try await candidate.checkedSnapshot(sortedBy: .manual)
        let attached = try XCTUnwrap(before.snips.first { $0.id == fixture.deleted.id })
        XCTAssertEqual(attached.attachments.count, 1)
        _ = try await candidate.perform(
            .editAttachments(
                snipID: attached.id, content: attached.content,
                edits: replacementFile.map { [.added(sourceURL: $0)] } ?? [],
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
        XCTAssertTrue(commit.attachmentTransitions.contains {
            if case .metadataDeleteAccepted = $0 { return true }
            return false
        })
        let initialLedger = try await candidate.cloudAttachmentStorageSnapshot(
            namespaceKey: fixture.namespace.namespaceKey
        )
        XCTAssertTrue(initialLedger.cleanups.isEmpty)

        return commit
    }

    private static func setupRetryPointerFixture(
        root: URL, pointerOnDeletedSnip: Bool, sourceOwnsPointer: Bool = false
    ) async throws -> SetupRetryPointerFixture {
        let crash = CrashInjector(point: .beforePointerSwap)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, crashHook: { point in
            if sourceOwnsPointer { try crash.hit(point) }
        })
        let local = try await persistence.activeLibrary()
        let bytes = Data("peer payload".utf8)
        let file = root.appendingPathComponent("peer.txt")
        try bytes.write(to: file)
        for text in ["acknowledged", "unrelated", "unsent"] {
            if text == "acknowledged", sourceOwnsPointer {
                _ = try await local.perform(.add(
                    content: text, origin: .quickEntry, source: nil, listID: SnipList.inbox.id,
                    attachmentURLs: [file], requestID: UUID(), now: .distantPast
                ), sortedBy: .manual)
            } else {
                try await addSetupFixtureSnip(text, to: local)
            }
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
        if !sourceOwnsPointer {
            await first.failNextSentItem(.snip(unsent.id, in: zone), failure: .retryable)
        }
        let firstSetup = ICloudSyncModeCoordinator(
            persistence: persistence, namespace: namespace, textZone: zone, payloadZone: descriptor.payloadZone,
            makeTransport: { first }
        )
        do {
            let partial = try await firstSetup.enableOrRetry()
            XCTAssertFalse(sourceOwnsPointer, "Expected interruption after the original attachment was accepted.")
            XCTAssertEqual(partial.state, .settingUp)
        } catch CrashInjector.Failure.injected {
            XCTAssertTrue(sourceOwnsPointer)
        }
        let history = await persistence.setupRetryEvidence(namespace: namespace.binding)
        XCTAssertTrue(history?.acknowledgedSnipKeys.contains { $0.reference.domainID == deleted.id } == true)

        let storage = try await persistence.snapshot()
        let candidateID = try XCTUnwrap(storage.transition?.candidateStoreID)
        let candidate = try await persistence.libraryForTransition(storeID: candidateID)
        let raw = CloudFullSyncPersistence(
            library: candidate, namespace: namespace, dataZone: zone, payloadZone: descriptor.payloadZone
        )
        if sourceOwnsPointer {
            let attachments = try await candidate.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
            let id = try XCTUnwrap(deleted.attachments.first?.id)
            let publication = try XCTUnwrap(attachments.publications.first { $0.metadata.attachmentID == id })
            let pointerID = CloudAttachmentRecordCodec.recordID(publication.metadataIdentity)
            let accepted = await server.fullSnapshot(for: pointerID)
            return SetupRetryPointerFixture(
                root: root, persistence: persistence, server: server, descriptor: descriptor, namespace: namespace,
                sourceStoreID: storage.activeStore.id, candidateID: candidateID, deleted: deleted,
                remainingIDs: [unrelated.id, unsent.id], pointerID: pointerID, shadow: try XCTUnwrap(accepted).shadow,
                payloadID: CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity), bytes: bytes, raw: raw
            )
        }

        let attachmentID = UUID()
        let pointerID = CloudRecordID(zone: zone, name: "a-\(attachmentID.uuidString.lowercased())")
        let payloadID = CloudRecordID(zone: descriptor.payloadZone, name: UUID().uuidString.lowercased())
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
        try await checkSetupRetryWithOldAndNewPointerReceipts(addLatePeerReference: false)
    }

    func testFullSetupRetryKeepsOldAndNewPointerReceiptsWhenPeerReferencesOwedBytes() async throws {
        try await checkSetupRetryWithOldAndNewPointerReceipts(addLatePeerReference: true)
    }

    private func checkSetupRetryWithOldAndNewPointerReceipts(addLatePeerReference: Bool) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let crash = CrashInjector(point: .beforePointerSwap)
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: crash.hit
        )
        let removedURL = root.appendingPathComponent("removed.txt")
        let keptURL = root.appendingPathComponent("kept.txt")
        let olderURL = root.appendingPathComponent("older.txt")
        let keptBytes = Data("attachment the user kept".utf8)
        let olderBytes = Data("attachment already deleted remotely".utf8)
        try Data("attachment the user removed".utf8).write(to: removedURL)
        try keptBytes.write(to: keptURL)
        try olderBytes.write(to: olderURL)
        let local = try await persistence.activeLibrary()
        let added = try await local.perform(
            .add(
                content: "snip with two files",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [removedURL, keptURL, olderURL],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )
        let snip = try XCTUnwrap(added.snapshot.snips.first)
        let removed = try XCTUnwrap(snip.attachments.first { $0.fileName == "removed.txt" })
        let kept = try XCTUnwrap(snip.attachments.first { $0.fileName == "kept.txt" })
        let older = try XCTUnwrap(snip.attachments.first { $0.fileName == "older.txt" })
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
        let olderPublication = try XCTUnwrap(publications.publications.first { $0.metadata.attachmentID == older.id })
        let olderPointerID = CloudAttachmentRecordCodec.recordID(olderPublication.metadataIdentity)
        let olderPayloadID = CloudAttachmentRecordCodec.recordID(olderPublication.metadata.payloadIdentity)
        _ = try await candidate.perform(
            .editAttachments(
                snipID: snip.id, content: snip.content,
                edits: [.existing(attachmentID: removed.id), .existing(attachmentID: kept.id)],
                expectedUpdatedAt: nil, now: snip.updatedAt.addingTimeInterval(1)
            ), sortedBy: .manual
        )
        let raw = CloudFullSyncPersistence(
            library: candidate, namespace: namespace, dataZone: metadataZone, payloadZone: payloadZone
        )
        let oldChanges = try await raw.pendingChanges()
        let olderOperation = try XCTUnwrap(oldChanges.operations.first {
            if case .delete(olderPointerID, _) = $0 { return true }
            return false
        })
        let olderOutbound = CloudOutboundBatch(operations: [olderOperation])
        let oldTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        try await oldTransport.start(state: nil)
        let olderSent = try await oldTransport.send(olderOutbound)
        XCTAssertEqual(olderSent.items, [.deleted(olderPointerID)])
        try await raw.stage(.sent(olderSent), outbound: olderOutbound)
        try await CloudSetupRetryCapture.retainStagedPointerDeletes(in: persistence)
        let beforeRetryEvidence = await persistence.setupRetryEvidence(namespace: namespace.binding)
        XCTAssertEqual(beforeRetryEvidence?.acceptedPointerDeletes.map(\.key.batchID), [olderSent.id])
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
        XCTAssertEqual(frozen.setupSourceAttachmentIDs, [removed.id, kept.id, older.id])

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
        let fake = FakeCloudRecordTransport(
            server: server, namespace: namespace, automaticallyFetchedZones: [metadataZone]
        )
        let peerID = UUID()
        let peerPointerID = CloudRecordID(zone: metadataZone, name: "a-\(peerID.uuidString.lowercased())")
        let peerMetadata = CloudAttachmentMetadataValue(
            attachmentID: peerID, snipID: snip.id, position: 2, fileName: "peer-reuse.txt",
            contentType: "text/plain", byteCount: Int64(olderBytes.count),
            sha256: Data(SHA256.hash(data: olderBytes)), payloadIdentity: olderPublication.metadata.payloadIdentity
        )
        let peerDraft = try CloudAttachmentRecordCodec.metadataDraft(CloudAttachmentPublication(
            metadata: peerMetadata, metadataIdentity: CloudAttachmentRecordCodec.identity(peerPointerID),
            sourceURL: nil, payloadAccepted: true, payloadShadowData: nil,
            metadataAccepted: false, metadataShadowData: nil, revision: 0
        ))
        let probe = SetupRetryDeleteProbeTransport(fake, beforeSending: { outbound in
            guard addLatePeerReference, outbound.operations.contains(where: {
                if case .delete(removedPointerID, _) = $0 { return true }
                return false
            }) else { return }
            let fetchEvents = await fake.events()
            XCTAssertTrue(fetchEvents.contains { if case .confirmed = $0 { return true }; return false })
            let sent = try await server.send(CloudOutboundBatch(operations: [.save(peerDraft)]), failures: [:])
            XCTAssertEqual(sent.items.map(\.id), [peerPointerID])
        })
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: metadataZone,
            payloadZone: payloadZone,
            makeTransport: { probe }
        )
        let result = try await retry.enableOrRetry()

        XCTAssertEqual(result.state, .on, "\(result)")
        let active = try await reopened.activeLibrary()
        let final = try await active.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [snip.id])
        XCTAssertEqual(Set(final.snips.first?.attachments.map(\.id) ?? []), addLatePeerReference ? [kept.id, peerID] : [kept.id])
        let copiedURL = try XCTUnwrap(final.attachmentURLs[kept.id])
        XCTAssertEqual(try Data(contentsOf: copiedURL), keptBytes)
        let deletedPointer = await server.fullSnapshot(for: removedPointerID)
        XCTAssertNil(deletedPointer)
        let sends = await probe.suppliedDeletes
        XCTAssertEqual(sends, [removedPointerID])
        let events = await fake.events()
        let deletionIndex = try XCTUnwrap(events.firstIndex {
            if case .sent(let ids) = $0 { return ids.contains(removedPointerID) }
            return false
        })
        XCTAssertTrue(events.dropFirst(deletionIndex + 1).contains(.fetched))
        let olderAsset = await server.asset(for: olderPayloadID, field: CloudAttachmentRecordCodec.assetField)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(olderAsset)), olderBytes)
        let evidence = await reopened.retainedSetupPointerDeletes(in: namespace.binding)
        XCTAssertEqual(Set(evidence.map(\.key.pointer)), [
            CloudAttachmentRecordCodec.identity(olderPointerID), CloudAttachmentRecordCodec.identity(removedPointerID)
        ])
        if addLatePeerReference {
            let remotePeer = await server.fullSnapshot(for: peerPointerID)
            XCTAssertEqual(try CloudAttachmentRecordCodec.metadata(from: XCTUnwrap(remotePeer)), peerMetadata)
        }
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
        _ persistence: SwiftDataSyncModePersistence, transport: SetupRetryDeleteProbeTransport,
        control: (any CloudCollectionControlTransport)? = nil,
        account: (any ICloudAccountStateSource)? = nil,
        automaticResultHandler: @escaping @Sendable (SnipSnapCloudSyncResult) -> Void = { _ in }
    ) throws -> SnipSnapICloudSyncLifecycle {
        SnipSnapICloudSyncLifecycle(
            rootURL: root,
            sourceLibrary: try JSONSnipLibrary(fileURL: root.appendingPathComponent("legacy.json")),
            syncModeStore: SnipSyncModeStore(persistence),
            cloudScope: "private", accountLineage: "account", accountStateSource: account, ownerName: "owner",
            controlTransport: control ?? FakeCloudControlTransport(server: server),
            makeRecordTransport: { _ in transport },
            makeDescriptor: { [descriptor] in descriptor }, automaticResultHandler: automaticResultHandler
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

    func aliasDraft(parentID: UUID) throws -> CloudRecordDraft {
        let id = UUID()
        return try CloudAttachmentRecordCodec.metadataDraft(CloudAttachmentPublication(
            metadata: .init(attachmentID: id, snipID: parentID, position: 0, fileName: "alias.txt",
                contentType: "text/plain", byteCount: Int64(bytes.count),
                sha256: Data(SHA256.hash(data: bytes)), payloadIdentity: CloudAttachmentRecordCodec.identity(payloadID)),
            metadataIdentity: CloudAttachmentRecordCodec.identity(CloudRecordID(
                zone: descriptor.metadataZone, name: "a-\(id.uuidString.lowercased())"
            )), sourceURL: nil, payloadAccepted: true, payloadShadowData: nil,
            metadataAccepted: false, metadataShadowData: nil, revision: 0
        ))
    }

    func removePeerParent() async throws {
        let peerParent = await server.fullSnapshot(for: deletedID)
        let removed = try await server.send(CloudOutboundBatch(operations: [
            .delete(deletedID, base: try XCTUnwrap(peerParent).shadow)
        ]), failures: [:])
        XCTAssertEqual(removed.items, [.deleted(deletedID)])
    }

    func assertRetainedPointerDelete(
        _ persistence: SwiftDataSyncModePersistence, batchID: UUID, activated: Bool = false
    ) async throws -> CloudSetupPointerDelete {
        let receipts = if activated {
            await persistence.retainedSetupPointerDeletes(in: namespace.binding)
        } else {
            await persistence.setupRetryEvidence(namespace: namespace.binding)?.acceptedPointerDeletes ?? []
        }
        XCTAssertEqual(receipts.count, 1)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.key.batchID, batchID)
        XCTAssertEqual(receipt.key.pointer, CloudAttachmentRecordCodec.identity(pointerID))
        XCTAssertEqual(receipt.payloads.map(\.identity), [CloudAttachmentRecordCodec.identity(payloadID)])
        return receipt
    }
}

private actor SetupTestAccount: ICloudAccountStateSource {
    private var state: ICloudAccountState = .available(accountLineage: "account")
    func currentAccountState() -> ICloudAccountState { state }
    func set(_ new: ICloudAccountState) { state = new }
}

actor SetupRetryDeleteProbeTransport: CloudRecordTransport {
    let fake: FakeCloudRecordTransport
    let omitFetchCompletion: Bool
    let interruptConfirmation: Bool
    let idOnlyDeleteServer: FakeCloudServer?
    let beforeSending: @Sendable (CloudOutboundBatch) async throws -> Void
    let queueAcceptedDeleteBehindAccountEvent: Bool
    let beforeAssetFetch: @Sendable (CloudRecordID) async throws -> Void
    private var receivedEvents: [CloudRecordTransportEvent] = []
    let afterSending: @Sendable (CloudOutboundBatch, CloudSentBatch) async throws -> Void
    let beforeFetching: @Sendable () async throws -> Void
    let afterFetching: @Sendable (CloudFetchedBatch) async throws -> Void
    let afterConfirming: @Sendable (UUID) async throws -> Void
    let omittedTombstones: Set<CloudRecordID>
    let omittedRecords: Set<CloudRecordID>
    private(set) var resumed = false
    private(set) var receivedInitialOutbound = false
    private(set) var suppliedDeletes: [CloudRecordID] = []
    private(set) var admissions: [CloudRecordOutboundAdmission] = []
    var suppliedDeleteIDs: Set<CloudRecordID> { Set(suppliedDeletes) }

    init(
        _ fake: FakeCloudRecordTransport,
        omitFetchCompletion: Bool = false,
        interruptConfirmation: Bool = false,
        idOnlyDeleteServer: FakeCloudServer? = nil,
        omittedTombstones: Set<CloudRecordID> = [],
        omittedRecords: Set<CloudRecordID> = [],
        queueAcceptedDeleteBehindAccountEvent: Bool = false,
        beforeSending: @escaping @Sendable (CloudOutboundBatch) async throws -> Void = { _ in },
        afterSending: @escaping @Sendable (CloudOutboundBatch, CloudSentBatch) async throws -> Void = { _, _ in },
        beforeFetching: @escaping @Sendable () async throws -> Void = {},
        afterFetching: @escaping @Sendable (CloudFetchedBatch) async throws -> Void = { _ in },
        beforeAssetFetch: @escaping @Sendable (CloudRecordID) async throws -> Void = { _ in },
        afterConfirming: @escaping @Sendable (UUID) async throws -> Void = { _ in }
    ) {
        self.fake = fake
        self.omitFetchCompletion = omitFetchCompletion
        self.interruptConfirmation = interruptConfirmation
        self.idOnlyDeleteServer = idOnlyDeleteServer
        self.omittedTombstones = omittedTombstones
        self.omittedRecords = omittedRecords
        self.beforeSending = beforeSending
        self.afterSending = afterSending
        self.queueAcceptedDeleteBehindAccountEvent = queueAcceptedDeleteBehindAccountEvent
        self.beforeAssetFetch = beforeAssetFetch
        self.beforeFetching = beforeFetching
        self.afterFetching = afterFetching
        self.afterConfirming = afterConfirming
    }

    func start(state: CloudEngineStateEnvelope?) async throws {
        if state != nil { resumed = true }
        try await fake.start(state: state)
    }

    func start(
        state: CloudEngineStateEnvelope?, initialOutbound: CloudOutboundBatch?,
        outboundAdmission: CloudRecordOutboundAdmission
    ) async throws {
        admissions.append(outboundAdmission)
        if initialOutbound != nil { receivedInitialOutbound = true }
        try await start(state: state)
    }

    func reset() async {
        await fake.reset()
    }

    func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
        try await beforeFetching()
        let batch = try await fake.fetch(scope: scope)
        let delivered = if omitFetchCompletion || !omittedTombstones.isEmpty || !omittedRecords.isEmpty {
            CloudFetchedBatch(
                id: batch.id, items: batch.items.filter {
                    switch $0 {
                    case .deleted(let id): !omittedTombstones.contains(id)
                    case .record(let record): !omittedRecords.contains(record.id)
                    case .failed: true
                    }
                }, databaseEvents: batch.databaseEvents,
                zoneEvents: omitFetchCompletion ? [] : batch.zoneEvents,
                engineState: batch.engineState, isInitialFetch: batch.isInitialFetch
            )
        } else {
            batch
        }
        try await afterFetching(delivered)
        return delivered
    }

    func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
        // The production provider submits only the IDs of these deletes.
        for case .delete(let id, _) in batch.operations {
            suppliedDeletes.append(id)
        }
        try await beforeSending(batch)
        let sent: CloudSentBatch
        if let idOnlyDeleteServer {
            var operations: [CloudOutboundOperation] = []
            for operation in batch.operations {
                if case .delete(let id, _) = operation {
                    let current = await idOnlyDeleteServer.fullSnapshot(for: id)
                    operations.append(.delete(id, base: current?.shadow))
                } else {
                    operations.append(operation)
                }
            }
            sent = try await fake.send(CloudOutboundBatch(operations: operations, zonesToSave: batch.zonesToSave))
        } else {
            sent = try await fake.send(batch)
        }
        if queueAcceptedDeleteBehindAccountEvent,
            !CloudSetupRetryCapture.acceptedPointerDeletes(in: sent, outbound: batch).isEmpty,
            let state = sent.engineState
        {
            receivedEvents = [.accountChange(UUID()),
                .checkpoint(UUID(), .init(namespace: state.namespace, serialization: Data([0xfa]), requiresInitialFetch: false)),
                .batch(.init(batch: .sent(sent), outbound: batch))]
        }
        try await afterSending(batch, sent)
        return sent
    }

    func pendingEvent() async -> CloudRecordTransportEvent? { receivedEvents.first }

    func confirmApplied(_ batchID: UUID) async throws {
        if interruptConfirmation { throw CloudTransportError.fetchFailed }
        if let event = receivedEvents.first, event.id == batchID {
            receivedEvents.removeFirst()
            if case .batch = event { try await fake.confirmApplied(batchID) }
        } else {
            try await fake.confirmApplied(batchID)
        }
        try await afterConfirming(batchID)
    }

    func confirmApplied(_ batchID: UUID, outboundAdmission: CloudRecordOutboundAdmission) async throws {
        admissions.append(outboundAdmission)
        try await confirmApplied(batchID)
    }

    func fetchRecord(_ id: CloudRecordID, fields: Set<String>) async throws -> CloudRecordSnapshot? {
        try await fake.fetchRecord(id, fields: fields)
    }

    func fetchAsset(
        _ id: CloudRecordID, field: String, destination: CloudAssetDestination
    ) async throws -> CloudAssetReceipt? {
        try await beforeAssetFetch(id)
        return try await fake.fetchAsset(id, field: field, destination: destination)
    }
}

private actor ResumedAttachmentOfferTransport: CloudRecordTransport, CloudAutomaticSyncConfiguring, CloudAutomaticSyncScheduling {
    let fake: FakeCloudRecordTransport
    private(set) var resumedState: CloudEngineStateEnvelope?
    private var initial: CloudOutboundBatch?
    private var scheduled: CloudOutboundBatch?
    private var admission = CloudRecordOutboundAdmission.open
    private var sendGate: RecordSendGate?

    var suppliedInitialOperations: [CloudOutboundOperation] { initial?.operations ?? [] }
    var blockedRecordIDs: Set<CloudRecordID> { admission.blockedRecordIDs }

    init(_ fake: FakeCloudRecordTransport) { self.fake = fake }

    func configureAutomaticSync(
        workAvailableHandler: @escaping WorkAvailableHandler,
        recordSendGate: @escaping RecordSendGate
    ) {
        sendGate = recordSendGate
    }

    func scheduleAutomaticSync(_ batch: CloudOutboundBatch) { scheduled = batch }

    func start(state: CloudEngineStateEnvelope?) async throws { try await fake.start(state: state) }

    func start(state: CloudEngineStateEnvelope?, initialOutbound: CloudOutboundBatch?,
        outboundAdmission: CloudRecordOutboundAdmission) async throws {
        resumedState = state
        initial = initialOutbound
        admission = outboundAdmission
        try await start(state: state)
    }

    func checkedInitialOffer() async throws -> [CloudOutboundOperation] {
        guard let sendGate, resumedState?.requiresInitialFetch == false,
            !admission.blocksAll, let initial, let scheduled else { throw CloudTransportError.invalidEngineState }
        try await sendGate()
        return initial.operations.filter {
            scheduled.operations.contains($0) && !admission.blockedRecordIDs.contains($0.id)
        }
    }

    func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch { try await fake.fetch(scope: scope) }

    func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
        guard batch.operations.allSatisfy({ if case .save = $0 { true } else { false } }) else {
            throw CloudTransportError.invalidRecord
        }
        return try await fake.send(batch)
    }

    func confirmApplied(_ batchID: UUID) async throws { try await fake.confirmApplied(batchID) }

    func fetchRecord(_ id: CloudRecordID, fields: Set<String>) async throws -> CloudRecordSnapshot? {
        try await fake.fetchRecord(id, fields: fields)
    }

    func fetchAsset(_ id: CloudRecordID, field: String, destination: CloudAssetDestination) async throws -> CloudAssetReceipt? {
        try await fake.fetchAsset(id, field: field, destination: destination)
    }
}
