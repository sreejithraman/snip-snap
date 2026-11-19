import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

/// After an aborted enable, a fresh enable runs against a server that already holds the aborted
/// attempt's records (SM23-F4). An enable is aborted either by Try Again finding its candidate's
/// files gone (SM23-F3-D3) or by Cancel setup, which only aborts. Every shipped build starts its
/// enables as full-record. An acknowledged setup send gives the source a baseline for merging
/// a later edit. An older interrupted setup can have no such evidence, so a later edit may
/// need a visible recovered copy.
extension ICloudSyncModeCoordinatorTests {
    // (b)
    func testFullRecordTryAgainWithAMissingCandidateAddsNoDuplicateSnips() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.tryAgain)
    }

    func testFullRecordTryAgainWithAMissingCandidateWithoutKeptBasesAddsNoDuplicateSnips()
        async throws
    {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.tryAgain, legacyWithoutSetupRetry: true)
    }

    // (d)
    func testFullRecordEnableAfterCancelSetupAddsNoDuplicateSnips() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.cancelSetupThenEnable)
    }

    func testFullRecordEnableAfterCancelSetupWithoutKeptBasesAddsNoDuplicateSnips() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .cancelSetupThenEnable,
            legacyWithoutSetupRetry: true
        )
    }

    // (e)
    func testFullRecordEnableAfterCancelSetupKeepsOneCopyOfASnipEditedInBetween() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.cancelSetupEditThenEnable)
    }

    // The SM23-F4 Cancel-path residual: Cancel setup aborts with no kept bases to merge the edit
    // against.
    func testFullRecordEnableAfterCancelSetupWithoutKeptBasesKeepsTheEditAsARecoveredCopy()
        async throws
    {
        try await assertFreshEnableKeepsTheEditAsARecoveredCopy(.cancelSetupEditThenEnable)
    }

    // (f)
    func testFullRecordTryAgainAfterARelaunchKeepsOneCopyOfASnipEditedInBetween() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.relaunchEditThenTryAgain)
    }

    // The SM23-F4 D3-path residual: Try Again aborts with no kept bases to merge the edit against.
    func testFullRecordTryAgainAfterARelaunchWithoutKeptBasesKeepsTheEditAsARecoveredCopy()
        async throws
    {
        try await assertFreshEnableKeepsTheEditAsARecoveredCopy(.relaunchEditThenTryAgain)
    }

    func testFullRecordTryAgainKeepsDeletionOfAcknowledgedSnip() async throws {
        try await assertSetupRetryAfterDeletingSnip(.acknowledged)
    }

    func testFullRecordTryAgainKeepsServerEditAfterAcknowledgedSnipWasDeletedLocally() async throws {
        try await assertSetupRetryAfterDeletingSnip(.serverEdited)
    }

    func testFullRecordTryAgainKeepsServerSnipWithoutDeletionEvidence() async throws {
        try await assertSetupRetryAfterDeletingSnip(.missingAcknowledgement)
    }

    func testSetupRetryChecksDeletedSourceBeforeRecoveringOldFullMergeIntent() async throws {
        for point: SyncModeCrashPoint in [.beforeCandidateMergeDurability, .afterCandidateMergeDurability] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let persistence = try SwiftDataSyncModePersistence(rootURL: root)
            let local = try await persistence.activeLibrary()
            try await add("acknowledged", to: local)
            try await add("unsent", to: local)
            let original = try await local.checkedSnapshot(sortedBy: .manual)
            let deleted = try XCTUnwrap(original.snips.first { $0.content == "acknowledged" })
            let survivor = try XCTUnwrap(original.snips.first { $0.id != deleted.id })
            let namespace = makeNamespace()
            let zone = textZone(namespace)
            let deletedID = CloudRecordID.snip(deleted.id, in: zone)
            let server = FakeCloudServer()
            let firstTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
            await firstTransport.failNextSentItem(.snip(survivor.id, in: zone), failure: .retryable)
            let first = ICloudSyncModeCoordinator(
                persistence: persistence, namespace: namespace, textZone: zone,
                makeTransport: { firstTransport }
            )
            let partial = try await first.enableOrRetry()
            XCTAssertEqual(partial.state, .settingUp)
            _ = try await local.perform(.delete(ids: [deleted.id]), sortedBy: .manual)

            let crash = CrashInjector(point: point)
            let old = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
            let state = try await old.snapshot()
            let transition = try XCTUnwrap(state.transition)
            let evidence = await old.setupRetryEvidence(namespace: namespace.binding)
            XCTAssertEqual(evidence?.acknowledgedSnipKeys.map(\.reference.domainID), [deleted.id])
            let candidate = try await old.libraryForTransition(storeID: transition.candidateStoreID)
            let raw = CloudFullSyncPersistence(library: candidate, namespace: namespace, dataZone: zone)
            let settlement = try await raw.currentModeSeedSettlement(
                candidates: transition.seedSettlementCandidates, namespace: namespace.binding
            )
            try await old.prepareRetryFetch(settlement: settlement)
            let oldFetch = FakeCloudRecordTransport(server: server, namespace: namespace)
            let driver = CloudFullSyncCoordinator(store: raw, transport: oldFetch, fetchScope: .zones([zone]))
            _ = try await driver.fetchRemote()
            try await old.recordPreparationComplete()
            let prepared = try await old.snapshot()
            let token = try await old.freezeSource()
            let source = try await old.finalSnapshot(using: token)
            let revision = try await old.candidateRevision(transitionID: transition.id)
            // Model a retry that predates the hold by staging the actual old merge,
            // with the accepted peer copy still present in its plan.
            let generated = try await raw.makeReenableApplyPlan(
                source: source, transitionID: transition.id, targetRevision: revision,
                priorSeedProvenance: try XCTUnwrap(prepared.transition).seedProvenance,
                retryEvidence: evidence
            )
            let plan = try XCTUnwrap(generated)
            XCTAssertTrue(plan.snips.contains { $0.id == deleted.id })
            do {
                _ = try await old.mergeFullReenableSnapshot(source, using: token, plan: plan)
                XCTFail("Expected the old setup to stop at \(point).")
            } catch CrashInjector.Failure.injected {}
            let intent = try await old.snapshot().transition?.mergeIntent
            XCTAssertEqual(intent?.fullReenablePlanID, transition.id)
            let applied = try await candidate.recognizesAppliedCloudFullReenable(
                CloudFullReenableCommitProof(
                    namespaceKey: namespace.namespaceKey, transitionID: transition.id,
                    digest: try XCTUnwrap(intent).planDigest
                )
            )
            XCTAssertEqual(applied, point == .afterCandidateMergeDurability)

            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            let retryTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
            let retry = ICloudSyncModeCoordinator(
                persistence: reopened, namespace: namespace, textZone: zone,
                makeTransport: { retryTransport }
            )
            let held = try await retry.enableOrRetry()
            XCTAssertEqual(held.state, .needsAttention)
            let heldStorage = try await reopened.snapshot()
            XCTAssertEqual(heldStorage.activeStore.id, transition.sourceStoreID)
            XCTAssertEqual(heldStorage.transition?.candidateStoreID, transition.candidateStoreID)
            XCTAssertEqual(heldStorage.transition?.phase, .candidateReady)
            XCTAssertNil(heldStorage.transition?.mergeIntent)
            let durableSource = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(durableSource.snips.map(\.id), [survivor.id])
            let retained = await reopened.setupRetryEvidence(namespace: namespace.binding)
            XCTAssertEqual(retained?.acknowledgedSnipKeys, evidence?.acknowledgedSnipKeys)
            let beforeRemoval = await retryTransport.events()
            XCTAssertTrue(beforeRemoval.contains(.fetched))
            XCTAssertFalse(beforeRemoval.contains { if case .sent = $0 { return true }; return false })
            let remote = await server.fullSnapshot(for: deletedID)
            XCTAssertEqual(try CloudFullRecordCodec.snip(from: XCTUnwrap(remote)).text, .value(deleted.content))

            let peer = FakeCloudRecordTransport(server: server, namespace: namespace)
            try await peer.start(state: nil)
            let removed = try await peer.send(CloudOutboundBatch(operations: [
                .delete(deletedID, base: try XCTUnwrap(remote).shadow)
            ]))
            XCTAssertEqual(removed.items, [.deleted(deletedID)])
            try await peer.confirmApplied(removed.id)
            let released = try await retry.enableOrRetry()
            XCTAssertEqual(released.state, .on)
            let final = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(final.snips.map(\.id), [survivor.id])
            let deletionCount = await server.acceptedDeletionCount()
            XCTAssertEqual(deletionCount, 1)
        }
    }

    private enum DeletedSetupSnip {
        case acknowledged
        case serverEdited
        case missingAcknowledgement
    }

    private func assertSetupRetryAfterDeletingSnip(
        _ scenario: DeletedSetupSnip,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root, fullDisk: .manifestAndStore, file: file, line: line
        )
        stranded.disk.free()
        let deletedID = stranded.keptSnipID
        let keptID = try XCTUnwrap(stranded.originals.keys.first { $0 != deletedID }, file: file, line: line)
        let editable = try relaunch(stranded, root: root)
        let source = try await editable.activeLibrary()
        let beforeDeletion = try await source.checkedSnapshot(sortedBy: .manual)
        let deleted = try XCTUnwrap(beforeDeletion.snips.first { $0.id == deletedID }, file: file, line: line)
        let storage = try await editable.snapshot()
        XCTAssertEqual(storage.activeStore.id, stranded.transition.sourceStoreID, file: file, line: line)
        XCTAssertEqual(storage.activeStore.kind, .localOnly, file: file, line: line)
        XCTAssertEqual(storage.transition?.phase, .candidateReady, file: file, line: line)
        _ = try await source.perform(.delete(ids: [deletedID]), sortedBy: .manual)
        let keptText: String
        if scenario == .missingAcknowledgement {
            // A local edit with no baseline exercises the separate recovered-snip path.
            keptText = try XCTUnwrap(stranded.originals[keptID], file: file, line: line)
        } else {
            keptText = "kept with a new local edit"
            try await edit(keptID, to: keptText, in: editable)
        }

        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let recordID = CloudRecordID.snip(deletedID, in: zone)
        let stored = await stranded.server.fullSnapshot(for: recordID)
        let accepted = try CloudFullRecordCodec.snip(from: XCTUnwrap(stored, file: file, line: line))
        XCTAssertEqual(accepted.domainID, deletedID, file: file, line: line)
        XCTAssertEqual(accepted.text, .value(deleted.content), file: file, line: line)

        var expected = [keptID: keptText]
        var expectedServer = stranded.originals
        switch scenario {
        case .acknowledged:
            break
        case .serverEdited:
            let changed = Snip(
                id: deletedID,
                requestID: deleted.requestID,
                createdAt: deleted.createdAt,
                updatedAt: deleted.updatedAt.addingTimeInterval(5),
                content: "edited by another device",
                origin: deleted.origin,
                source: deleted.source,
                listID: deleted.listID,
                manualSortKey: deleted.manualSortKey
            )
            let writer = FakeCloudRecordTransport(server: stranded.server, namespace: namespace)
            let sent = try await writer.send(CloudOutboundBatch(operations: [
                .save(CloudFullRecordCodec.snipDraft(changed, accepted: accepted))
            ]))
            guard case .saved = try XCTUnwrap(sent.items.first, file: file, line: line) else {
                return XCTFail("The independent edit must reach the server.", file: file, line: line)
            }
            expected[deletedID] = changed.content
            expectedServer[deletedID] = changed.content
        case .missingAcknowledgement:
            try stripSetupRetryEvidence(of: stranded, root: root, file: file, line: line)
            expected[deletedID] = deleted.content
        }

        let reopened = try relaunch(stranded, root: root)
        let reopenedStorage = try await reopened.snapshot()
        XCTAssertEqual(reopenedStorage.activeStore.id, storage.activeStore.id, file: file, line: line)
        let durable = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(durable.snips.map(\.id), [keptID], file: file, line: line)
        XCTAssertEqual(durable.snips.map(\.content), [keptText], file: file, line: line)
        let key = CloudSetupRetryRecordKey(
            reference: CloudEntityReference(kind: .snip, domainID: deletedID),
            identity: CloudFullSyncPersistence.storageIdentity(recordID)
        )
        let evidence = await reopened.setupRetryEvidence(namespace: namespace.binding)
        if scenario == .missingAcknowledgement {
            XCTAssertNil(evidence?.baseline(for: key), file: file, line: line)
        } else {
            let baseline = try XCTUnwrap(evidence?.baseline(for: key), file: file, line: line)
            XCTAssertEqual(evidence?.requiresRecovery(for: key), false, file: file, line: line)
            for fields in [baseline.sourceFields, baseline.serverFields] {
                let snip = try JSONDecoder().decode(CloudSnipMergeFields.self, from: fields)
                XCTAssertEqual(snip.id, deletedID, file: file, line: line)
                XCTAssertEqual(snip.text, deleted.content, file: file, line: line)
            }
        }

        let transport = FakeCloudRecordTransport(server: stranded.server, namespace: namespace)
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened, namespace: namespace, textZone: zone, makeTransport: { transport }
        )
        let result = try await retry.enableOrRetry()
        let active = try await reopened.snapshot()
        if scenario != .missingAcknowledgement {
            XCTAssertEqual(result.state, .needsAttention, file: file, line: line)
            XCTAssertEqual(active.activeStore.id, storage.activeStore.id, file: file, line: line)
            XCTAssertEqual(active.activeStore.kind, .localOnly, file: file, line: line)
            XCTAssertEqual(active.transition?.phase, .candidateReady, file: file, line: line)
            let held = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(held.snips.map(\.id), [keptID], file: file, line: line)
            let events = await transport.events()
            XCTAssertTrue(events.contains(.fetched), file: file, line: line)
            XCTAssertFalse(events.contains { if case .sent = $0 { return true }; return false }, file: file, line: line)
            try await assertSameServerSnips(stranded.server, texts: expectedServer, file: file, line: line)
            if scenario == .acknowledged {
                try await assertSetupRetryCompletesAfterPeerRemoval(
                    root: root, server: stranded.server, deletedRecordID: recordID, survivorID: keptID
                )
            }
            return
        }
        XCTAssertEqual(result.state, .on, file: file, line: line)
        XCTAssertEqual(active.activeStore.kind, .iCloudSync, file: file, line: line)
        XCTAssertNil(active.transition, file: file, line: line)
        let final = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.count, expected.count, file: file, line: line)
        XCTAssertEqual(
            Dictionary(final.snips.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first }),
            expected, file: file, line: line
        )
        try await assertSameServerSnips(stranded.server, texts: expected, file: file, line: line)
    }

    private func assertSetupRetryCompletesAfterPeerRemoval(
        root: URL, server: FakeCloudServer, deletedRecordID: CloudRecordID, survivorID: UUID
    ) async throws {
        let namespace = makeNamespace()
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let beforeRetry = try await reopened.snapshot()
        let candidateID = try XCTUnwrap(beforeRetry.transition?.candidateStoreID)
        let editedText = "edited while setup was held"
        try await edit(survivorID, to: editedText, in: reopened)
        let candidate = try await reopened.libraryForTransition(storeID: candidateID)
        let before = try await candidate.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
        let savedToken = try JSONDecoder().decode(
            CloudEngineStateEnvelope.self, from: XCTUnwrap(before.engineState)
        )
        XCTAssertFalse(savedToken.requiresInitialFetch)

        let failed = FakeCloudRecordTransport(server: server, namespace: namespace)
        await failed.failNextFetch()
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened, namespace: namespace, textZone: deletedRecordID.zone,
            makeTransport: { failed }
        )
        let failedResult = try await retry.enableOrRetry()
        XCTAssertEqual(failedResult.state, .needsAttention)
        let failedEvents = await failed.events()
        XCTAssertEqual(failedEvents, [.started, .fetched])
        let held = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(held.snips.map(\.id), [survivorID])
        XCTAssertEqual(held.snips.map(\.content), [editedText])

        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        let stored = await server.fullSnapshot(for: deletedRecordID)
        let removed = try await writer.send(CloudOutboundBatch(operations: [
            .delete(deletedRecordID, base: XCTUnwrap(stored).shadow)
        ]))
        guard case .deleted? = removed.items.first else { return XCTFail("The peer must remove the record.") }
        // Older setup could persist remoteFetched before a guarded source read.
        try await reopened.recordPreparationComplete()
        let incompleteFake = FakeCloudRecordTransport(server: server, namespace: namespace)
        let incomplete = SetupRetryDeleteProbeTransport(incompleteFake, omitFetchCompletion: true)
        let incompleteRetry = ICloudSyncModeCoordinator(
            persistence: reopened, namespace: namespace, textZone: deletedRecordID.zone,
            makeTransport: { incomplete }
        )
        let incompleteResult = try await incompleteRetry.enableOrRetry()
        XCTAssertEqual(incompleteResult.state, .needsAttention)
        let incompleteEvents = await incompleteFake.events()
        XCTAssertTrue(incompleteEvents.contains(.fetched))
        XCTAssertFalse(incompleteEvents.contains { if case .sent = $0 { return true }; return false })
        let afterIncomplete = try await reopened.snapshot()
        XCTAssertEqual(afterIncomplete.activeStore.id, beforeRetry.activeStore.id)
        XCTAssertEqual(afterIncomplete.transition?.phase, .candidateReady)

        let survivor = try await sameServerCoordinator(
            on: reopened, server: server
        ).enableOrRetry()
        XCTAssertEqual(survivor.state, .on)
        let completed = try await reopened.snapshot()
        XCTAssertEqual(completed.activeStore.id, candidateID)
        XCTAssertNil(completed.transition)
        let final = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [survivorID])
        XCTAssertEqual(final.snips.map(\.content), [editedText])
        try await assertSameServerSnips(server, texts: [survivorID: editedText])
        let deletionCount = await server.acceptedDeletionCount()
        XCTAssertEqual(deletionCount, 1, "Only the peer submitted a deletion.")
    }

    func testFullRecordTryAgainAfterReopeningKeepsBothDevicesEdits() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: .manifestAndStore,
            history: .turnedOffThenEditedOnBothSides
        )
        let expected = stranded.originals
        let editedID = stranded.keptSnipID
        XCTAssertEqual(expected[editedID], Self.sameServerTextEditedWhileOff)
        XCTAssertEqual(
            expected.values.sorted(),
            [Self.sameServerTexts[1], Self.sameServerTextEditedWhileOff]
        )
        try await assertSameServerSnips(stranded.server, texts: expected, doneSnipID: editedID)

        stranded.disk.free()
        let reopened = try relaunch(stranded, root: root)
        let beforeRetry = try await reopened.snapshot()
        XCTAssertEqual(beforeRetry.activeStore.id, stranded.transition.sourceStoreID)
        XCTAssertEqual(beforeRetry.transition?.candidateStoreID, stranded.transition.candidateStoreID)
        let namespace = makeNamespace()
        let snipRecordID = CloudRecordID.snip(editedID, in: textZone(namespace))
        let key = CloudSetupRetryRecordKey(
            reference: CloudEntityReference(kind: .snip, domainID: editedID),
            identity: CloudFullSyncPersistence.storageIdentity(snipRecordID)
        )
        let evidence = await reopened.setupRetryEvidence(namespace: namespace.binding)
        let baseline = try XCTUnwrap(evidence?.baseline(for: key))
        let decoder = JSONDecoder()
        let frozen = try decoder.decode(CloudSnipMergeFields.self, from: baseline.sourceFields)
        let acknowledged = try decoder.decode(CloudSnipMergeFields.self, from: baseline.serverFields)
        XCTAssertFalse(frozen.isDone)
        XCTAssertTrue(acknowledged.isDone)

        let status = try await sameServerCoordinator(on: reopened, server: stranded.server)
            .enableOrRetry()

        XCTAssertEqual(status.state, .on)
        let afterRetry = try await reopened.snapshot()
        XCTAssertEqual(afterRetry.activeStore.kind, .iCloudSync)
        XCTAssertNil(afterRetry.transition)
        XCTAssertEqual(stranded.probe.count(.missing(operation: "sync.setup")), 0)
        let active = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual).snips
        XCTAssertEqual(active.count, expected.count)
        XCTAssertEqual(
            Dictionary(active.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first }),
            expected
        )
        XCTAssertEqual(
            active.filter(\.isDone).map(\.id),
            [editedID],
            "Try Again must preserve the other device's Done mark in the active library."
        )
        try await assertSameServerSnips(stranded.server, texts: expected, doneSnipID: editedID)
    }

    func testFullRecordTryAgainAfterReopeningKeepsTextChangedBackToOriginal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: .manifestAndStore,
            history: .turnedOffThenEditedLocally
        )
        let snipID = stranded.keptSnipID
        let original = Self.sameServerOriginalText
        let firstEdit = Self.sameServerFirstEditText
        XCTAssertEqual(stranded.originals, [snipID: firstEdit])

        stranded.disk.free()
        let reopened = try relaunch(stranded, root: root)
        let beforeRetry = try await reopened.snapshot()
        XCTAssertEqual(beforeRetry.activeStore.id, stranded.transition.sourceStoreID)
        XCTAssertEqual(beforeRetry.transition?.candidateStoreID, stranded.transition.candidateStoreID)
        try await edit(snipID, to: original, in: reopened)

        let localBeforeRetry = try await reopened.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        XCTAssertEqual(localBeforeRetry.map(\.id), [snipID])
        XCTAssertEqual(localBeforeRetry.map(\.content), [original])
        try await assertSameServerSnips(stranded.server, texts: [snipID: firstEdit])

        let status = try await sameServerCoordinator(on: reopened, server: stranded.server)
            .enableOrRetry()

        XCTAssertEqual(status.state, .on)
        let afterRetry = try await reopened.snapshot()
        XCTAssertEqual(afterRetry.activeStore.kind, .iCloudSync)
        XCTAssertNil(afterRetry.transition)
        let localAfterRetry = try await reopened.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        XCTAssertEqual(localAfterRetry.map(\.id), [snipID])
        XCTAssertEqual(localAfterRetry.map(\.content), [original])
        try await assertSameServerSnips(stranded.server, texts: [snipID: original])
    }

    func testFullRecordTryAgainAfterReopeningLegacySetupKeepsRestoredTextAsARecoveredCopy()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: .manifestAndStore,
            history: .turnedOffThenEditedLocally
        )
        let snipID = stranded.keptSnipID
        XCTAssertEqual(stranded.originals, [snipID: Self.sameServerFirstEditText])

        stranded.disk.free()
        try stripSetupRetryEvidence(of: stranded, root: root)
        let reopened = try relaunch(stranded, root: root)
        let beforeRetry = try await reopened.snapshot()
        XCTAssertEqual(beforeRetry.activeStore.id, stranded.transition.sourceStoreID)
        XCTAssertEqual(beforeRetry.transition?.candidateStoreID, stranded.transition.candidateStoreID)
        XCTAssertEqual(beforeRetry.transition?.phase, .candidateReady)
        try await edit(snipID, to: Self.sameServerOriginalText, in: reopened)
        try await assertSameServerSnips(stranded.server, texts: stranded.originals)

        let status = try await sameServerCoordinator(on: reopened, server: stranded.server)
            .enableOrRetry()

        XCTAssertEqual(status.state, .on)
        let afterRetry = try await reopened.snapshot()
        XCTAssertEqual(afterRetry.activeStore.id, stranded.transition.candidateStoreID)
        XCTAssertNil(afterRetry.transition)
        XCTAssertEqual(stranded.probe.count(.missing(operation: "sync.setup")), 0)
        let recoveredID = SnipLibraryTransferPlanner.derivedUUID(
            transitionID: stranded.transition.id,
            sourceID: snipID
        )
        let expected = [
            snipID: Self.sameServerFirstEditText,
            recoveredID: Self.sameServerOriginalText,
        ]
        let active = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual).snips
        XCTAssertEqual(active.count, expected.count)
        XCTAssertEqual(
            Dictionary(active.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first }),
            expected
        )
        try await assertSameServerSnips(stranded.server, texts: expected)
    }

    func testFullRecordFreshEnableKeepsAnAcceptedRecoveredSnip() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: .manifestAndStore
        )
        stranded.disk.free()
        try stripSetupRetryEvidence(of: stranded, root: root)
        let persistence = try relaunch(stranded, root: root)
        try await persistence.cancelPendingICloudEnable()
        try await edit(stranded.keptSnipID, to: Self.sameServerEditedText, in: persistence)

        let coordinator = sameServerCoordinator(on: persistence, server: stranded.server)
        stranded.disk.armAtPointerSwap()
        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("The setup that uploaded the recovered snip must stop before activation.")
        } catch SameServerFullDisk.Failure.injected {}
        let interrupted = try await persistence.snapshot()
        let transition = try XCTUnwrap(interrupted.transition)
        let recoveredID = SnipLibraryTransferPlanner.derivedUUID(
            transitionID: transition.id,
            sourceID: stranded.keptSnipID
        )
        var expected = stranded.originals
        expected[recoveredID] = Self.sameServerEditedText
        try await assertSameServerSnips(stranded.server, texts: expected)

        stranded.disk.free()
        try await persistence.cancelPendingICloudEnable()
        let result = try await coordinator.enableOrRetry()

        XCTAssertEqual(result.state, .on)
        let active = try await persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(active.snips.count, expected.count)
        XCTAssertEqual(
            Dictionary(active.snips.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first }),
            expected
        )
        try await assertSameServerSnips(stranded.server, texts: expected)
    }

    // Cancelling the re-enable must preserve the other device's Done mark on the next enable.
    func testFullRecordEnableAfterCancelSetupKeepsAServerChangeMadeWhileSyncWasOff() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let enabled = try await freshEnableOnTheSameServer(
            after: .cancelSetupThenEnable,
            fullDisk: .manifestAndStore,
            history: .turnedOffThenEditedOnBothSides,
            root: root
        )

        try await assertEndedOnThroughAFreshTransition(enabled)
        try await assertOneCopyOfEachSnip(
            in: enabled.persistence,
            expected: enabled.expected,
            transitionIDs: enabled.stranded.disk.transitionIDsAtSwap,
            server: enabled.stranded.server
        )
        try await assertKeptTheOtherDevicesChange(
            to: enabled.editedSnipID,
            in: enabled.persistence,
            server: enabled.stranded.server
        )
    }

    private func assertSameServerSnips(
        _ server: FakeCloudServer,
        texts: [UUID: String],
        doneSnipID: UUID? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let zone = textZone(makeNamespace())
        let snipRecords = await server.storedRecordTypes(in: zone).filter { $0 == "Snip" }
        XCTAssertEqual(snipRecords.count, texts.count, file: file, line: line)
        for (id, text) in texts {
            let recordID = CloudRecordID.snip(id, in: zone)
            let stored = await server.fullSnapshot(for: recordID)
            let record = try CloudFullRecordCodec.snip(from: XCTUnwrap(stored, file: file, line: line))
            XCTAssertEqual(record.id, recordID, file: file, line: line)
            XCTAssertEqual(record.domainID, id, file: file, line: line)
            XCTAssertEqual(record.text, .value(text), file: file, line: line)
            XCTAssertEqual(
                record.isDone,
                .value(id == doneSnipID),
                "Unexpected Done mark on server record \(recordID.name).",
                file: file,
                line: line
            )
        }
    }

    /// Checks that `persistence`'s active library holds exactly `expected`, by ID and content,
    /// with no recovered copy that any of `transitionIDs` derives, and that `server` holds one
    /// snip record per snip, with the same texts.
    func assertOneCopyOfEachSnip(
        in persistence: SwiftDataSyncModePersistence,
        expected: [UUID: String],
        transitionIDs: [UUID],
        server: FakeCloudServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let active = try await persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        let recoveredIDs = Set(expected.keys.flatMap { snipID in
            transitionIDs.map {
                SnipLibraryTransferPlanner.derivedUUID(transitionID: $0, sourceID: snipID)
            }
        })
        XCTAssertEqual(
            active.filter { recoveredIDs.contains($0.id) }.map(\.content).sorted(),
            [],
            "The merge added recovered copies.",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Dictionary(active.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first }),
            expected,
            "The active library must hold exactly the original snips, by ID and content.",
            file: file,
            line: line
        )
        let serverSnipRecords = await server
            .storedRecordTypes(in: textZone(makeNamespace()))
            .filter { $0 == "Snip" }
        XCTAssertEqual(
            serverSnipRecords.count,
            expected.count,
            "The server must hold one snip record per snip.",
            file: file,
            line: line
        )
        let serverTexts = await server.storedTextValues()
        XCTAssertEqual(serverTexts, expected.values.sorted(), file: file, line: line)
    }

    private static let sameServerTexts = ["kept", "also kept"]
    private static let sameServerEditedText = "kept, edited before the fresh enable"
    private static let sameServerTextEditedWhileOff = "kept, edited while sync was off"
    private static let sameServerOriginalText = "original"
    private static let sameServerFirstEditText = "first edit"

    /// Checks that `snipID` keeps both changes `.turnedOffThenEditedOnBothSides` made: this
    /// device's text and the other device's done mark, locally and on `server`.
    private func assertKeptTheOtherDevicesChange(
        to snipID: UUID,
        in persistence: SwiftDataSyncModePersistence,
        server: FakeCloudServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let active = try await persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        let snip = try XCTUnwrap(active.first(where: { $0.id == snipID }), file: file, line: line)
        XCTAssertEqual(snip.content, Self.sameServerTextEditedWhileOff, file: file, line: line)
        XCTAssertTrue(
            snip.isDone,
            "The merge reverted the other device's done mark.",
            file: file,
            line: line
        )
        let stored = await server.fullSnapshot(for: .snip(snipID, in: textZone(makeNamespace())))
        let record = try CloudFullRecordCodec.snip(from: XCTUnwrap(stored, file: file, line: line))
        XCTAssertEqual(
            record.isDone,
            .value(true),
            "The fresh send reverted the other device's done mark on the server.",
            file: file,
            line: line
        )
    }

    /// Reopens an older interrupted setup, then checks the original ID and the recovered edit
    /// after a fresh enable, locally and on the server.
    private func assertFreshEnableKeepsTheEditAsARecoveredCopy(
        _ retry: SameServerRetry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let enabled = try await freshEnableOnTheSameServer(
            after: retry,
            fullDisk: .manifestAndStore,
            legacyWithoutSetupRetry: true,
            root: root,
            file: file,
            line: line
        )

        try await assertEndedOnThroughAFreshTransition(enabled, file: file, line: line)
        let fresh = try XCTUnwrap(
            enabled.stranded.disk.transitionIDsAtSwap.last,
            file: file,
            line: line
        )
        var expected = enabled.stranded.originals
        let recoveredID = SnipLibraryTransferPlanner.derivedUUID(
            transitionID: fresh,
            sourceID: enabled.editedSnipID
        )
        expected[recoveredID] = Self.sameServerEditedText
        let active = try await enabled.persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        XCTAssertEqual(active.count, expected.count, file: file, line: line)
        XCTAssertEqual(
            Dictionary(active.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first }),
            expected,
            "The original must keep the server's text and the edit a recovered copy.",
            file: file,
            line: line
        )
        let serverSnipRecords = await enabled.stranded.server
            .storedRecordTypes(in: textZone(makeNamespace()))
            .filter { $0 == "Snip" }
        XCTAssertEqual(serverSnipRecords.count, 3, file: file, line: line)
        let serverTexts = await enabled.stranded.server.storedTextValues()
        XCTAssertEqual(serverTexts, expected.values.sorted(), file: file, line: line)
    }

    /// Runs the fresh enable `retry` names, and checks that it ends On through a new transition
    /// with exactly one copy of each snip. An edit, where `retry` makes one, must land on the
    /// original snip.
    private func assertFreshEnableKeepsOneCopyOfEachSnip(
        _ retry: SameServerRetry,
        legacyWithoutSetupRetry: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let enabled = try await freshEnableOnTheSameServer(
            after: retry,
            fullDisk: legacyWithoutSetupRetry ? .manifestAndStore : .manifestOnly,
            legacyWithoutSetupRetry: legacyWithoutSetupRetry,
            root: root,
            file: file,
            line: line
        )

        try await assertEndedOnThroughAFreshTransition(enabled, file: file, line: line)
        try await assertOneCopyOfEachSnip(
            in: enabled.persistence,
            expected: enabled.expected,
            transitionIDs: enabled.stranded.disk.transitionIDsAtSwap,
            server: enabled.stranded.server,
            file: file,
            line: line
        )
    }

    /// Strands an enable whose first send reached the server, aborts it by `retry`, and runs the
    /// fresh enable on the same server.
    private func freshEnableOnTheSameServer(
        after retry: SameServerRetry,
        fullDisk: SameServerFullDisk.Extent,
        history: SameServerHistory = .localOnly,
        legacyWithoutSetupRetry: Bool = false,
        root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> SameServerFreshEnable {
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: fullDisk,
            history: history,
            file: file,
            line: line
        )
        let editedSnipID = stranded.keptSnipID
        var expected = stranded.originals
        stranded.disk.free()
        if legacyWithoutSetupRetry {
            try stripSetupRetryEvidence(of: stranded, root: root, file: file, line: line)
        }

        let persistence: SwiftDataSyncModePersistence
        switch retry {
        case .tryAgain:
            try await removeCandidateFiles(of: stranded)
            persistence = legacyWithoutSetupRetry
                ? try relaunch(stranded, root: root)
                : stranded.persistence
        case .relaunchEditThenTryAgain:
            do {
                try await edit(
                    editedSnipID,
                    to: Self.sameServerEditedText,
                    in: stranded.persistence
                )
                XCTFail(
                    "The stranded enable keeps the source frozen, so an edit needs a relaunch.",
                    file: file,
                    line: line
                )
            } catch {
                XCTAssertEqual(
                    error as? SnipLibraryError,
                    .modeTransitionInProgress,
                    file: file,
                    line: line
                )
            }
            try await removeCandidateFiles(of: stranded)
            persistence = try relaunch(stranded, root: root)
            let reopened = try await persistence.snapshot()
            XCTAssertEqual(reopened.transition?.phase, .candidateReady, file: file, line: line)
            try await edit(editedSnipID, to: Self.sameServerEditedText, in: persistence)
            expected[editedSnipID] = Self.sameServerEditedText
        case .cancelSetupThenEnable, .cancelSetupEditThenEnable:
            persistence = legacyWithoutSetupRetry
                ? try relaunch(stranded, root: root)
                : stranded.persistence
            try await persistence.cancelPendingICloudEnable()
            let cancelled = try await persistence.snapshot()
            XCTAssertNil(cancelled.transition, file: file, line: line)
            if retry == .cancelSetupEditThenEnable {
                try await edit(editedSnipID, to: Self.sameServerEditedText, in: persistence)
                expected[editedSnipID] = Self.sameServerEditedText
            }
        }
        let status = try await sameServerCoordinator(on: persistence, server: stranded.server)
            .enableOrRetry()
        return SameServerFreshEnable(
            retry: retry,
            stranded: stranded,
            persistence: persistence,
            status: status,
            editedSnipID: editedSnipID,
            expected: expected
        )
    }

    private func assertEndedOnThroughAFreshTransition(
        _ enabled: SameServerFreshEnable,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertEqual(
            enabled.status.state,
            .on,
            "The fresh enable stopped with \(String(describing: enabled.status.attentionReason)).",
            file: file,
            line: line
        )
        let storage = try await enabled.persistence.snapshot()
        XCTAssertNil(storage.transition, file: file, line: line)
        XCTAssertEqual(storage.activeStore.kind, .iCloudSync, file: file, line: line)
        XCTAssertEqual(
            enabled.stranded.probe.count(.missing(operation: "sync.setup")),
            enabled.retry.abortsAMissingCandidate ? 1 : 0,
            "Only Try Again with the candidate's files gone aborts through SM23-F3-D3.",
            file: file,
            line: line
        )
        let swapped = enabled.stranded.disk.transitionIDsAtSwap
        XCTAssertEqual(swapped.count, 2, file: file, line: line)
        XCTAssertEqual(swapped.first, enabled.stranded.transition.id, file: file, line: line)
        XCTAssertNotEqual(
            swapped.last,
            enabled.stranded.transition.id,
            "The fresh enable must swap in a new transition.",
            file: file,
            line: line
        )
    }

    /// Adds the snips, applies `history`, and runs a full-record enable until its first send
    /// reached `server`. Then it fails the pointer swap on a disk that fills as `fullDisk` says,
    /// so the enable stays at `firstSendComplete` with the source frozen. The disk stays full.
    private func strandAnEnableThatReachedTheServer(
        root: URL,
        fullDisk: SameServerFullDisk.Extent,
        history: SameServerHistory = .localOnly,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> SameServerStrandedEnable {
        let disk = SameServerFullDisk(root: root, extent: fullDisk)
        let probe = StoreOpenDiagnosticProbe()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .fullRecordV1,
            crashHook: disk.hit,
            manifestWriter: disk.writer.write,
            afterMutationBeforeSave: disk.checkStoreSave,
            diagnostics: probe.recorder
        )
        let texts = history == .turnedOffThenEditedLocally
            ? [Self.sameServerOriginalText]
            : Self.sameServerTexts
        for text in texts {
            try await add(text, to: persistence.activeLibrary())
        }
        let added = try await persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        let keptSnipID = try XCTUnwrap(
            added.first(where: { $0.content == texts[0] })?.id,
            file: file,
            line: line
        )
        let server = FakeCloudServer()
        if history != .localOnly {
            let coordinator = sameServerCoordinator(on: persistence, server: server)
            let enabled = try await coordinator.enableOrRetry()
            XCTAssertEqual(enabled.state, .on, file: file, line: line)
            let turnedOff = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
            XCTAssertEqual(turnedOff.state, .off, file: file, line: line)
        }
        switch history {
        case .localOnly:
            break
        case .turnedOffThenEditedLocally:
            try await assertSameServerSnips(
                server,
                texts: [keptSnipID: Self.sameServerOriginalText],
                file: file,
                line: line
            )
            try await edit(keptSnipID, to: Self.sameServerFirstEditText, in: persistence)
        case .turnedOffThenEditedOnBothSides:
            try await editOnBothSides(
                keptSnipID,
                in: persistence,
                server: server,
                file: file,
                line: line
            )
        }
        let originals = try await persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        disk.armAtPointerSwap()
        do {
            _ = try await sameServerCoordinator(on: persistence, server: server).enableOrRetry()
            XCTFail("The injected failure must end the enable.", file: file, line: line)
        } catch SameServerFullDisk.Failure.injected {}
        let stuck = try await persistence.snapshot()
        let transition = try XCTUnwrap(stuck.transition, file: file, line: line)
        XCTAssertEqual(transition.phase, .firstSendComplete, file: file, line: line)
        let sent = await server.storedTextValues()
        XCTAssertEqual(
            sent,
            originals.map(\.content).sorted(),
            "The aborted enable must reach the server.",
            file: file,
            line: line
        )
        return SameServerStrandedEnable(
            persistence: persistence,
            server: server,
            disk: disk,
            probe: probe,
            transition: transition,
            keptSnipID: keptSnipID,
            originals: Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0.content) })
        )
    }

    /// With sync off, another device marks `snipID` done and this device edits its text.
    private func editOnBothSides(
        _ snipID: UUID,
        in persistence: SwiftDataSyncModePersistence,
        server: FakeCloudServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let local = try await persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        let snip = try XCTUnwrap(local.first(where: { $0.id == snipID }), file: file, line: line)
        let namespace = makeNamespace()
        let stored = await server.fullSnapshot(for: .snip(snipID, in: textZone(namespace)))
        let accepted = try CloudFullRecordCodec.snip(from: XCTUnwrap(stored, file: file, line: line))
        let done = Snip(
            id: snip.id,
            requestID: snip.requestID,
            createdAt: snip.createdAt,
            updatedAt: snip.updatedAt.addingTimeInterval(5),
            content: snip.content,
            origin: snip.origin,
            source: snip.source,
            listID: snip.listID,
            isDone: true,
            manualSortKey: snip.manualSortKey
        )
        let otherDevice = FakeCloudRecordTransport(server: server, namespace: namespace)
        let sent = try await otherDevice.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.snipDraft(done, accepted: accepted))
        ]))
        guard case .saved = try XCTUnwrap(sent.items.first, file: file, line: line) else {
            return XCTFail("The other device's change must reach the server.", file: file, line: line)
        }

        try await edit(snipID, to: Self.sameServerTextEditedWhileOff, in: persistence)
    }

    /// Reopens the stranded enable's root as the next launch of today's build does.
    private func relaunch(
        _ stranded: SameServerStrandedEnable,
        root: URL
    ) throws -> SwiftDataSyncModePersistence {
        try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: stranded.disk.hit,
            diagnostics: stranded.probe.recorder
        )
    }

    private func stripSetupRetryEvidence(
        of stranded: SameServerStrandedEnable,
        root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try mutateManifest(at: root.appendingPathComponent("activation.json")) { manifest in
            var stores = try XCTUnwrap(manifest["stores"] as? [[String: Any]], file: file, line: line)
            let sourceIndex = try XCTUnwrap(
                stores.firstIndex {
                    ($0["id"] as? String).flatMap(UUID.init(uuidString:))
                        == stranded.transition.sourceStoreID
                },
                file: file,
                line: line
            )
            let removed = stores[sourceIndex].removeValue(forKey: "setupRetryHistory")
            _ = try XCTUnwrap(
                removed,
                "The fixture must strip persisted setup evidence.",
                file: file,
                line: line
            )
            manifest["stores"] = stores
        }
    }

    private func edit(
        _ snipID: UUID,
        to text: String,
        in persistence: SwiftDataSyncModePersistence
    ) async throws {
        let library = try await persistence.activeLibrary()
        let current = try await library.checkedSnapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(current.snips.first(where: { $0.id == snipID }))
        _ = try await library.perform(
            .update(
                id: snip.id,
                content: text,
                attachmentURLs: nil,
                expectedUpdatedAt: snip.updatedAt,
                now: snip.updatedAt.addingTimeInterval(10)
            ),
            sortedBy: .manual
        )
    }

    private func removeCandidateFiles(of stranded: SameServerStrandedEnable) async throws {
        let listed = await stranded.persistence.store(id: stranded.transition.candidateStoreID)
        let candidate = try XCTUnwrap(listed)
        let candidateRoot = await stranded.persistence.storeURL(candidate)
        try FileManager.default.removeItem(at: candidateRoot)
    }

    private func sameServerCoordinator(
        on persistence: SwiftDataSyncModePersistence,
        server: FakeCloudServer
    ) -> ICloudSyncModeCoordinator {
        let namespace = makeNamespace()
        return ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
    }
}

/// How the stranded enable is aborted before the fresh enable.
private enum SameServerRetry: Equatable {
    /// Try Again in the same process finds the candidate's files gone. The stranded transition
    /// keeps the source frozen until then, so no edit can land first.
    case tryAgain
    /// A relaunch moves the stranded transition back to `candidateReady`, which unfreezes the
    /// source. The user edits a snip, and Try Again then finds the candidate's files gone.
    case relaunchEditThenTryAgain
    case cancelSetupThenEnable
    case cancelSetupEditThenEnable

    var abortsAMissingCandidate: Bool {
        self == .tryAgain || self == .relaunchEditThenTryAgain
    }
}

/// What happened to the snips before the stranded enable.
private enum SameServerHistory: Equatable {
    /// The snips were only ever local.
    case localOnly
    /// A single synced snip was edited locally after turning sync off.
    case turnedOffThenEditedLocally
    /// The snips were synced, then sync was turned off, which kept their bases. Another device
    /// then marked the "kept" snip done, and this device edited its text.
    case turnedOffThenEditedOnBothSides
}

private struct SameServerStrandedEnable {
    let persistence: SwiftDataSyncModePersistence
    let server: FakeCloudServer
    let disk: SameServerFullDisk
    let probe: StoreOpenDiagnosticProbe
    let transition: SyncModeTransition
    /// The snip first added as "kept".
    let keptSnipID: UUID
    /// The source's snips when the stranded enable started.
    let originals: [UUID: String]
}

private struct SameServerFreshEnable {
    let retry: SameServerRetry
    let stranded: SameServerStrandedEnable
    let persistence: SwiftDataSyncModePersistence
    let status: ICloudSyncModeStatus
    let editedSnipID: UUID
    /// The originals, with the edit on its original snip.
    let expected: [UUID: String]
}

/// Fails the first pointer swap after `armAtPointerSwap()` and, from then on, the writes its
/// `Extent` names, like a disk that fills mid-change. `free()` frees the disk. From the armed
/// swap on, it also notes which stored transition each pointer swap was about to activate.
private final class SameServerFullDisk: @unchecked Sendable {
    enum Failure: Error { case injected }

    enum Extent {
        /// Store saves still succeed.
        case manifestOnly
        /// Both store and manifest writes fail after the pointer swap fault.
        case manifestAndStore
    }

    let writer = FailingManifestWriter()
    private let extent: Extent
    private let manifestURL: URL
    private let lock = NSLock()
    private var wasArmed = false
    private var isArmed = false
    private var storeIsFull = false
    private var swapTransitionIDs: [UUID] = []

    init(root: URL, extent: Extent) {
        self.extent = extent
        manifestURL = root.appendingPathComponent("activation.json", isDirectory: false)
    }

    var transitionIDsAtSwap: [UUID] { lock.withLock { swapTransitionIDs } }

    func armAtPointerSwap() {
        lock.withLock {
            wasArmed = true
            isArmed = true
        }
    }

    func free() {
        writer.failWrites = false
        lock.withLock { storeIsFull = false }
    }

    func hit(_ point: SyncModeCrashPoint) throws {
        guard point == .beforePointerSwap else { return }
        let transitionID = storedTransitionID()
        let fills = lock.withLock { () -> Bool in
            guard wasArmed else { return false }
            if let transitionID { swapTransitionIDs.append(transitionID) }
            guard isArmed else { return false }
            isArmed = false
            storeIsFull = extent == .manifestAndStore
            return true
        }
        guard fills else { return }
        writer.failWrites = true
        throw Failure.injected
    }

    func checkStoreSave() throws {
        if lock.withLock({ storeIsFull }) { throw Failure.injected }
    }

    private func storedTransitionID() -> UUID? {
        let manifest = try? JSONDecoder().decode(
            SwiftDataSyncModePersistence.Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        return manifest?.transition?.id
    }
}
