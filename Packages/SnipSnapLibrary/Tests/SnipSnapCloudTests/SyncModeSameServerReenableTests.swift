import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

/// After an aborted enable, a fresh enable runs against a server that already holds the aborted
/// attempt's records (SM23-F4). An enable is aborted either by Try Again finding its candidate's
/// files gone (SM23-F3-D3) or by Cancel setup, which only aborts. Every shipped build starts its
/// enables as full-record. When the source holds bases for those records, the fresh enable ends
/// with one copy of each snip. Without them, a snip edited between attempts ends as a visible
/// recovered copy.
extension ICloudSyncModeCoordinatorTests {
    // (b)
    func testFullRecordTryAgainWithAMissingCandidateAddsNoDuplicateSnips() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.tryAgain)
    }

    func testFullRecordTryAgainWithAMissingCandidateWithoutKeptBasesAddsNoDuplicateSnips()
        async throws
    {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.tryAgain, fullDisk: .manifestAndStore)
    }

    // (d)
    func testFullRecordEnableAfterCancelSetupAddsNoDuplicateSnips() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.cancelSetupThenEnable)
    }

    func testFullRecordEnableAfterCancelSetupWithoutKeptBasesAddsNoDuplicateSnips() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .cancelSetupThenEnable,
            fullDisk: .manifestAndStore
        )
    }

    // (e)
    func testFullRecordEnableAfterCancelSetupKeepsOneCopyOfASnipEditedInBetween() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.cancelSetupEditThenEnable)
    }

    // Qualified source evidence survives Cancel even when the restore could not save bases.
    func testFullRecordEnableAfterCancelSetupWithoutKeptBasesKeepsTheEditOnItsOriginalID()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let enabled = try await freshEnableOnTheSameServer(
            after: .cancelSetupEditThenEnable,
            fullDisk: .manifestAndStore,
            root: root
        )
        try await assertEndedOnThroughAFreshTransition(enabled)
        XCTAssertEqual(enabled.stranded.originals.count, 2)
        let otherID = try XCTUnwrap(enabled.stranded.originals.keys.first {
            $0 != enabled.editedSnipID
        })
        let expected = [
            enabled.editedSnipID: Self.sameServerEditedText,
            otherID: Self.sameServerTexts[1],
        ]
        try await assertOneCopyOfEachSnip(
            in: enabled.persistence,
            expected: expected,
            transitionIDs: enabled.stranded.disk.transitionIDsAtSwap,
            server: enabled.stranded.server
        )
        let active = try await enabled.persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(Set(active.map(\.id)), Set(expected.keys))
        let zone = textZone(makeNamespace())
        for (id, text) in expected {
            let local = try XCTUnwrap(active.first { $0.id == id })
            XCTAssertEqual(local.content, text)
            XCTAssertFalse(local.isDone)
            let stored = await enabled.stranded.server.fullSnapshot(for: .snip(id, in: zone))
            let record = try CloudFullRecordCodec.snip(from: XCTUnwrap(stored))
            XCTAssertEqual(record.domainID, id)
            XCTAssertEqual(record.text, .value(text))
            XCTAssertEqual(record.isDone, .value(false))
            for transitionID in enabled.stranded.disk.transitionIDsAtSwap {
                let recoveredID = SnipLibraryTransferPlanner.derivedUUID(
                    transitionID: transitionID,
                    sourceID: id
                )
                let recovered = await enabled.stranded.server.fullSnapshot(
                    for: .snip(recoveredID, in: zone)
                )
                XCTAssertNil(recovered)
            }
        }
    }

    // (f)
    func testFullRecordTryAgainAfterARelaunchKeepsOneCopyOfASnipEditedInBetween() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.relaunchEditThenTryAgain)
    }

    // Retained qualified source evidence survives without dormant bases or the old candidate.
    func testFullRecordTryAgainAfterARelaunchWithoutDormantBasesKeepsTheQualifiedEditOnItsOriginalID()
        async throws
    {
        try await assertFreshEnableKeepsTheQualifiedEditOnItsOriginalID(.relaunchEditThenTryAgain)
    }

    func testFrozenImportRefusalPreservesPendingManifestContinuity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = SameServerFullDisk(root: root, extent: .manifestOnly)
        let probe = StoreOpenDiagnosticProbe()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .fullRecordV1,
            crashHook: disk.hit,
            manifestWriter: disk.writer.write,
            afterMutationBeforeSave: disk.checkStoreSave,
            diagnostics: probe.recorder
        )
        let managed = try await persistence.activeLibrary()
        for text in Self.sameServerTexts { try await add(text, to: managed) }
        let initial = await persistence.manifest
        let sourceID = initial.activeStoreID
        let initialSource = try XCTUnwrap(initial.stores.first { $0.id == sourceID })
        let source = try await persistence.libraryForTransition(storeID: sourceID)
        let expectedSource = try await source.transferSnapshot(revision: initialSource.revision)
        let expectedRequests = try await source.archive().seenRequestIDs
        XCTAssertEqual(expectedSource.snips.map(\.content).sorted(), ["also kept", "kept"])
        XCTAssertEqual(expectedSource.snips.count, 2)
        XCTAssertEqual(expectedRequests, Set(expectedSource.snips.map(\.requestID)))
        let imported = Snip(
            content: "not imported while setup is frozen", origin: .quickEntry,
            manualSortKey: try SnipOrderKey.rebalanced(count: 1)[0]
        )
        let preview = try await managed.previewImport(
            SnipLibraryTransferSnapshot(
                revision: 0, snips: [imported], lists: [.inbox], attachmentData: [:]
            ),
            transitionID: UUID()
        )
        XCTAssertEqual(preview.addedSnipCount, 1)
        XCTAssertEqual(preview.source.snips, [imported])
        XCTAssertNil(initial.transition)
        let server = FakeCloudServer()
        disk.armAtPointerSwap()
        do {
            _ = try await sameServerCoordinator(on: persistence, server: server).enableOrRetry()
            XCTFail("Expected the real pointer failure and failed rollback")
        } catch SameServerFullDisk.Failure.injected {}
        disk.free()

        let manifestBefore = await persistence.manifest
        let transition = try XCTUnwrap(manifestBefore.transition)
        let freeze = try XCTUnwrap(transition.freezeToken)
        let sourceBefore = try XCTUnwrap(manifestBefore.stores.first { $0.id == sourceID })
        let frozenSource = try await source.transferSnapshot(revision: sourceBefore.revision)
        XCTAssertEqual(frozenSource, expectedSource)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let recordIDs = [CloudRecordID.list(SnipList.inbox.id, in: zone)]
            + expectedSource.snips.map { CloudRecordID.snip($0.id, in: zone) }
        var serverBefore: [CloudRecordID: CloudRecordSnapshot] = [:]
        var acceptedBefore: [CloudRecordID: Int] = [:]
        for id in recordIDs {
            let stored = await server.fullSnapshot(for: id)
            serverBefore[id] = try XCTUnwrap(stored)
            acceptedBefore[id] = await server.acceptedOperationCount(for: id)
        }
        let sentTexts = await server.storedTextValues()
        XCTAssertEqual(sentTexts, ["also kept", "kept"])
        let activationURL = root.appendingPathComponent("activation.json")
        let activationBytesBefore = try Data(contentsOf: activationURL)
        let activationBefore = try JSONDecoder().decode(
            SwiftDataSyncModePersistence.Manifest.self, from: activationBytesBefore
        )
        let evidenceFiles = FailedEnableEvidenceFile(root: root)
        let evidenceBefore = try XCTUnwrap(evidenceFiles.read(sourceID))
        let ticket = try XCTUnwrap(evidenceBefore.continuity.inFlight.value)
        let postimage = try XCTUnwrap(ticket.manifestPostimageDigest.value)
        let uncertainBefore = await persistence.failedEnableUncertainSources
        let owner = await persistence.failedEnableOwnerNonce
        let queuedBefore = await persistence.queuedWriterCount
        let activationDigest = await persistence.failedEnableActivationDigest(activationBefore)
        let group = try XCTUnwrap(evidenceBefore.namespaces.first {
            $0.binding == FailedEnableBinding(namespace.binding)
        })
        let capture = try XCTUnwrap(group.captures.last {
            $0.transitionID == FailedEnableEncoding.uuid(transition.id)
                && $0.candidateStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
        })
        let factsBefore = "[SM23-F5-REFUSAL] import before sequence=\(evidenceBefore.sequence) "
            + "continuity=\(evidenceBefore.continuity) uncertain=\(uncertainBefore)"
        XCTAssertEqual(activationBefore, manifestBefore, factsBefore)
        XCTAssertEqual(manifestBefore.activeStoreID, sourceID, factsBefore)
        XCTAssertEqual(transition.sourceStoreID, sourceID, factsBefore)
        XCTAssertEqual(transition.syncProtocol, .fullRecordV1, factsBefore)
        XCTAssertEqual(transition.phase, .firstSendComplete, factsBefore)
        XCTAssertTrue(transition.freezesSource, factsBefore)
        XCTAssertNil(manifestBefore.writeReservation, factsBefore)
        XCTAssertEqual(queuedBefore, 0, factsBefore)
        XCTAssertFalse(uncertainBefore.contains(sourceID), factsBefore)
        XCTAssertEqual(evidenceBefore.continuity.state, .verified, factsBefore)
        XCTAssertEqual(ticket.kind, .manifest, factsBefore)
        XCTAssertEqual(ticket.ownerNonce, FailedEnableEncoding.uuid(owner), factsBefore)
        XCTAssertEqual(ticket.previousActivationDigest, activationDigest, factsBefore)
        XCTAssertEqual(evidenceBefore.continuity.activationDigest, activationDigest, factsBefore)
        XCTAssertNotEqual(postimage, activationDigest, factsBefore)
        XCTAssertNil(ticket.reservedRevision.value, factsBefore)
        XCTAssertEqual(ticket.previousSourceRevision, String(sourceBefore.revision), factsBefore)
        XCTAssertEqual(ticket.previousSourceDigest, evidenceBefore.continuity.sourceDigest, factsBefore)
        XCTAssertEqual(evidenceBefore.continuity.sourceRevision, String(sourceBefore.revision), factsBefore)
        XCTAssertEqual(freeze.sourceStoreID, sourceID, factsBefore)
        XCTAssertEqual(capture.freeze.id, FailedEnableEncoding.uuid(freeze.id), factsBefore)
        XCTAssertEqual(capture.freeze.sourceRevision, String(freeze.revision), factsBefore)
        XCTAssertEqual(freeze.revision, sourceBefore.revision, factsBefore)
        XCTAssertEqual(capture.sourceDigest, evidenceBefore.continuity.sourceDigest, factsBefore)
        XCTAssertTrue(capture.armed, factsBefore)
        XCTAssertEqual(capture.records.count, 3, factsBefore)
        XCTAssertTrue(evidenceBefore.transfers.contains {
            $0.kind == .candidate && $0.state == .checked
                && $0.sourceCaptureIDs == [capture.id]
                && $0.destinationStoreID == capture.candidateStoreID
                && $0.sourceStoreID == FailedEnableEncoding.uuid(sourceID)
                && $0.namespace == group.binding
        }, factsBefore)
        for record in capture.records {
            XCTAssertNotNil(record.preparation.value.value, factsBefore)
            XCTAssertNotNil(record.observedAccepted.value, factsBefore)
            XCTAssertEqual(record.observedAccepted.value?.candidateStoreID, capture.candidateStoreID, factsBefore)
            switch try XCTUnwrap(record.source.value) {
            case .snip(let image):
                let snip = try image.domain
                XCTAssertEqual(snip, expectedSource.snips.first { $0.id == snip.id }, factsBefore)
            case .list(let image):
                let list = try image.domain
                XCTAssertEqual(list, expectedSource.lists.first { $0.id == list.id }, factsBefore)
            }
        }
        let stableBefore = await persistence.manifest
        XCTAssertEqual(stableBefore, manifestBefore, factsBefore)
        print(factsBefore)
        do {
            _ = try await managed.applyImport(preview)
            XCTFail("A frozen setup must refuse the managed import")
        } catch SnipLibraryError.modeTransitionInProgress {}
        let manifestAfter = await persistence.manifest
        let uncertainAfter = await persistence.failedEnableUncertainSources
        let queuedAfter = await persistence.queuedWriterCount
        let evidenceAfter = try XCTUnwrap(evidenceFiles.read(sourceID))
        let factsAfter = factsBefore + " after sequence=\(evidenceAfter.sequence) "
            + "continuity=\(evidenceAfter.continuity) uncertain=\(uncertainAfter)"
        XCTAssertEqual(manifestAfter, manifestBefore, factsAfter)
        XCTAssertNil(manifestAfter.writeReservation, factsAfter)
        XCTAssertEqual(queuedAfter, 0, factsAfter)
        XCTAssertEqual(uncertainAfter, uncertainBefore, factsAfter)
        XCTAssertEqual(evidenceAfter.continuity, evidenceBefore.continuity, factsAfter)
        XCTAssertEqual(evidenceAfter.namespaces, evidenceBefore.namespaces, factsAfter)
        XCTAssertEqual(evidenceAfter.transfers, evidenceBefore.transfers, factsAfter)
        XCTAssertEqual(evidenceAfter.blobs, evidenceBefore.blobs, factsAfter)
        let activationAfter = try JSONDecoder().decode(
            SwiftDataSyncModePersistence.Manifest.self, from: Data(contentsOf: activationURL)
        )
        let stableAfter = await persistence.manifest
        XCTAssertEqual(activationAfter, manifestAfter, factsAfter)
        XCTAssertEqual(stableAfter, manifestAfter, factsAfter)
        print(factsAfter)

        let afterSource = try await source.transferSnapshot(revision: sourceBefore.revision)
        let afterRequests = try await source.archive().seenRequestIDs
        XCTAssertEqual(afterSource, expectedSource)
        XCTAssertEqual(afterRequests, expectedRequests)
        XCTAssertFalse(afterRequests.contains(imported.requestID))
        XCTAssertEqual(afterSource.opaqueSyncStatePayload, expectedSource.opaqueSyncStatePayload)
        XCTAssertFalse(afterSource.snips.contains { $0.id == imported.id || $0.content == imported.content })
        let importedRecord = await server.fullSnapshot(for: .snip(imported.id, in: zone))
        let importedSaves = await server.acceptedOperationCount(for: .snip(imported.id, in: zone))
        XCTAssertNil(importedRecord)
        XCTAssertEqual(importedSaves, 0)
        let finalTexts = await server.storedTextValues()
        XCTAssertEqual(finalTexts, ["also kept", "kept"])
        for id in recordIDs {
            let stored = await server.fullSnapshot(for: id)
            let accepted = await server.acceptedOperationCount(for: id)
            XCTAssertEqual(stored, serverBefore[id])
            XCTAssertEqual(accepted, acceptedBefore[id])
        }
    }

    func testCancelledFrozenEditPreservesPendingManifestContinuity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root, fullDisk: .manifestOnly
        )
        stranded.disk.free()
        let persistence = stranded.persistence
        let managed = try await persistence.activeLibrary()
        let manifestBefore = await persistence.manifest
        let sourceID = manifestBefore.activeStoreID
        let sourceStore = try XCTUnwrap(manifestBefore.stores.first { $0.id == sourceID })
        let source = try await persistence.libraryForTransition(storeID: sourceID)
        let expectedSource = try await source.transferSnapshot(revision: sourceStore.revision)
        let expectedRequests = try await source.archive().seenRequestIDs
        XCTAssertEqual(expectedSource.snips.map(\.content).sorted(), ["also kept", "kept"])
        XCTAssertEqual(expectedSource.snips.count, 2)
        XCTAssertEqual(expectedRequests, Set(expectedSource.snips.map(\.requestID)))
        let original = try XCTUnwrap(expectedSource.snips.first { $0.id == stranded.keptSnipID })
        let cancelledText = "cancelled frozen edit must not be saved"
        let command = SnipLibraryCommand.update(
            id: original.id, content: cancelledText, attachmentURLs: nil,
            expectedUpdatedAt: original.updatedAt, now: original.updatedAt.addingTimeInterval(10)
        )
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let recordIDs = [CloudRecordID.list(SnipList.inbox.id, in: zone)]
            + expectedSource.snips.map { CloudRecordID.snip($0.id, in: zone) }
        var serverBefore: [CloudRecordID: CloudRecordSnapshot] = [:]
        var acceptedBefore: [CloudRecordID: Int] = [:]
        for id in recordIDs {
            let stored = await stranded.server.fullSnapshot(for: id)
            serverBefore[id] = try XCTUnwrap(stored)
            acceptedBefore[id] = await stranded.server.acceptedOperationCount(for: id)
        }
        let activationURL = root.appendingPathComponent("activation.json")
        let activationBefore = try JSONDecoder().decode(
            SwiftDataSyncModePersistence.Manifest.self, from: Data(contentsOf: activationURL)
        )
        let evidenceFiles = FailedEnableEvidenceFile(root: root)
        let evidenceBefore = try XCTUnwrap(evidenceFiles.read(sourceID))
        let ticket = try XCTUnwrap(evidenceBefore.continuity.inFlight.value)
        let postimage = try XCTUnwrap(ticket.manifestPostimageDigest.value)
        let uncertainBefore = await persistence.failedEnableUncertainSources
        let owner = await persistence.failedEnableOwnerNonce
        let queuedBefore = await persistence.queuedWriterCount
        let activationDigest = await persistence.failedEnableActivationDigest(activationBefore)
        let transition = try XCTUnwrap(manifestBefore.transition)
        let freeze = try XCTUnwrap(transition.freezeToken)
        let group = try XCTUnwrap(evidenceBefore.namespaces.first {
            $0.binding == FailedEnableBinding(namespace.binding)
        })
        let capture = try XCTUnwrap(group.captures.last {
            $0.transitionID == FailedEnableEncoding.uuid(transition.id)
                && $0.candidateStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
        })
        let modeFailuresBefore = stranded.probe.count(.writeAdmission(.failed, reason: .modeChange))
        let factsBefore = "[SM23-F5-REFUSAL] cancel before sequence=\(evidenceBefore.sequence) "
            + "continuity=\(evidenceBefore.continuity) uncertain=\(uncertainBefore)"
        XCTAssertEqual(activationBefore, manifestBefore, factsBefore)
        XCTAssertEqual(transition, stranded.transition, factsBefore)
        XCTAssertEqual(transition.sourceStoreID, sourceID, factsBefore)
        XCTAssertEqual(transition.syncProtocol, .fullRecordV1, factsBefore)
        XCTAssertEqual(transition.phase, .firstSendComplete, factsBefore)
        XCTAssertTrue(transition.freezesSource, factsBefore)
        XCTAssertNil(manifestBefore.writeReservation, factsBefore)
        XCTAssertEqual(queuedBefore, 0, factsBefore)
        XCTAssertFalse(uncertainBefore.contains(sourceID), factsBefore)
        XCTAssertEqual(evidenceBefore.continuity.state, .verified, factsBefore)
        XCTAssertEqual(ticket.kind, .manifest, factsBefore)
        XCTAssertEqual(ticket.ownerNonce, FailedEnableEncoding.uuid(owner), factsBefore)
        XCTAssertEqual(ticket.previousActivationDigest, activationDigest, factsBefore)
        XCTAssertEqual(evidenceBefore.continuity.activationDigest, activationDigest, factsBefore)
        XCTAssertNotEqual(postimage, activationDigest, factsBefore)
        XCTAssertNil(ticket.reservedRevision.value, factsBefore)
        XCTAssertEqual(ticket.previousSourceRevision, String(sourceStore.revision), factsBefore)
        XCTAssertEqual(ticket.previousSourceDigest, evidenceBefore.continuity.sourceDigest, factsBefore)
        XCTAssertEqual(evidenceBefore.continuity.sourceRevision, String(sourceStore.revision), factsBefore)
        XCTAssertEqual(freeze.sourceStoreID, sourceID, factsBefore)
        XCTAssertEqual(capture.freeze.id, FailedEnableEncoding.uuid(freeze.id), factsBefore)
        XCTAssertEqual(capture.freeze.sourceRevision, String(freeze.revision), factsBefore)
        XCTAssertEqual(freeze.revision, sourceStore.revision, factsBefore)
        XCTAssertEqual(capture.sourceDigest, evidenceBefore.continuity.sourceDigest, factsBefore)
        XCTAssertTrue(capture.armed, factsBefore)
        XCTAssertEqual(capture.records.count, 3, factsBefore)
        XCTAssertTrue(evidenceBefore.transfers.contains {
            $0.kind == .candidate && $0.state == .checked
                && $0.sourceCaptureIDs == [capture.id]
                && $0.destinationStoreID == capture.candidateStoreID
                && $0.sourceStoreID == FailedEnableEncoding.uuid(sourceID)
                && $0.namespace == group.binding
        }, factsBefore)
        for record in capture.records {
            XCTAssertNotNil(record.preparation.value.value, factsBefore)
            XCTAssertNotNil(record.observedAccepted.value, factsBefore)
            XCTAssertEqual(record.observedAccepted.value?.candidateStoreID, capture.candidateStoreID, factsBefore)
            switch try XCTUnwrap(record.source.value) {
            case .snip(let image):
                let snip = try image.domain
                XCTAssertEqual(snip, expectedSource.snips.first { $0.id == snip.id }, factsBefore)
            case .list(let image):
                let list = try image.domain
                XCTAssertEqual(list, expectedSource.lists.first { $0.id == list.id }, factsBefore)
            }
        }
        let stableBefore = await persistence.manifest
        XCTAssertEqual(stableBefore, manifestBefore, factsBefore)
        print(factsBefore)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await managed.perform(command, sortedBy: .manual)
        }
        do {
            _ = try await cancelled.value
            XCTFail("A self-cancelled frozen edit must throw CancellationError")
        } catch is CancellationError {}
        let manifestAfter = await persistence.manifest
        let uncertainAfter = await persistence.failedEnableUncertainSources
        let queuedAfter = await persistence.queuedWriterCount
        let evidenceAfter = try XCTUnwrap(evidenceFiles.read(sourceID))
        let modeFailuresAfter = stranded.probe.count(.writeAdmission(.failed, reason: .modeChange))
        let factsAfter = factsBefore + " after sequence=\(evidenceAfter.sequence) "
            + "continuity=\(evidenceAfter.continuity) uncertain=\(uncertainAfter)"
        XCTAssertEqual(manifestAfter, manifestBefore, factsAfter)
        XCTAssertNil(manifestAfter.writeReservation, factsAfter)
        XCTAssertEqual(queuedAfter, 0, factsAfter)
        XCTAssertEqual(modeFailuresAfter - modeFailuresBefore, 0, factsAfter)
        XCTAssertEqual(uncertainAfter, uncertainBefore, factsAfter)
        XCTAssertEqual(evidenceAfter.continuity, evidenceBefore.continuity, factsAfter)
        XCTAssertEqual(evidenceAfter.namespaces, evidenceBefore.namespaces, factsAfter)
        XCTAssertEqual(evidenceAfter.transfers, evidenceBefore.transfers, factsAfter)
        XCTAssertEqual(evidenceAfter.blobs, evidenceBefore.blobs, factsAfter)
        let activationAfter = try JSONDecoder().decode(
            SwiftDataSyncModePersistence.Manifest.self, from: Data(contentsOf: activationURL)
        )
        let stableAfter = await persistence.manifest
        XCTAssertEqual(activationAfter, manifestAfter, factsAfter)
        XCTAssertEqual(stableAfter, manifestAfter, factsAfter)
        print(factsAfter)

        let afterSource = try await source.transferSnapshot(revision: sourceStore.revision)
        let afterRequests = try await source.archive().seenRequestIDs
        XCTAssertEqual(afterSource, expectedSource)
        XCTAssertEqual(afterRequests, expectedRequests)
        XCTAssertEqual(afterSource.opaqueSyncStatePayload, expectedSource.opaqueSyncStatePayload)
        XCTAssertFalse(afterSource.snips.contains { $0.content == cancelledText })
        let finalTexts = await stranded.server.storedTextValues()
        XCTAssertEqual(finalTexts, ["also kept", "kept"])
        for id in recordIDs {
            let stored = await stranded.server.fullSnapshot(for: id)
            let accepted = await stranded.server.acceptedOperationCount(for: id)
            XCTAssertEqual(stored, serverBefore[id])
            XCTAssertEqual(accepted, acceptedBefore[id])
        }
    }

    // Cancel setup only aborts, so the bases a turn-off kept stay the common ancestor, and the
    // next merge keeps both devices' changes. Writing the aborted re-enable's sent records over
    // them would silently revert the other device's change (SM23-F4 review, F1).
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

    // A committed restore leaves source content unchanged; Try Again must keep both edits.
    func testFullRecordTryAgainAfterARestoreKeepsAServerChangeMadeWhileSyncWasOff() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: .swapOnly,
            history: .turnedOffThenEditedOnBothSides
        )

        let restored = try await stranded.persistence.snapshot()
        XCTAssertEqual(restored.activeStore.id, stranded.transition.sourceStoreID)
        XCTAssertEqual(restored.activeStore.kind, .localOnly)
        let source = try await stranded.persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        let snip = try XCTUnwrap(source.first(where: { $0.id == stranded.keptSnipID }))
        XCTAssertEqual(snip.content, Self.sameServerTextEditedWhileOff)
        XCTAssertFalse(snip.isDone)

        let status = try await sameServerCoordinator(
            on: stranded.persistence,
            server: stranded.server
        ).enableOrRetry()

        XCTAssertEqual(
            status.state,
            .on,
            "Try Again stopped with \(String(describing: status.attentionReason))."
        )
        let storage = try await stranded.persistence.snapshot()
        XCTAssertNil(storage.transition)
        XCTAssertEqual(storage.activeStore.kind, .iCloudSync)
        XCTAssertEqual(
            stranded.disk.transitionIDsAtSwap,
            [stranded.transition.id, stranded.transition.id],
            "Try Again must finish the restored transition."
        )
        try await assertOneCopyOfEachSnip(
            in: stranded.persistence,
            expected: stranded.originals,
            transitionIDs: [stranded.transition.id],
            server: stranded.server
        )
        try await assertKeptTheOtherDevicesChange(
            to: stranded.keptSnipID,
            in: stranded.persistence,
            server: stranded.server
        )
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

    /// Keeps the qualified edit on its original ID while retaining the first source and accepted bytes.
    private func assertFreshEnableKeepsTheQualifiedEditOnItsOriginalID(
        _ retry: SameServerRetry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let enabled = try await freshEnableOnTheSameServer(
            after: retry,
            fullDisk: .manifestAndStore,
            root: root,
            file: file,
            line: line
        )

        try await assertEndedOnThroughAFreshTransition(enabled, file: file, line: line)
        let firstTransition = enabled.stranded.transition
        let freshTransitionID = try XCTUnwrap(
            enabled.stranded.disk.transitionIDsAtSwap.last, file: file, line: line
        )
        let before = enabled.stranded.originalSourceBeforeEnable
        XCTAssertEqual(before.revision, 2, file: file, line: line)
        XCTAssertEqual(before.snips.count, 2, file: file, line: line)
        XCTAssertEqual(before.snips.map(\.content).sorted(), Self.sameServerTexts.sorted(), file: file, line: line)
        XCTAssertEqual(before.lists, [.inbox], file: file, line: line)
        XCTAssertTrue(before.attachmentData.isEmpty, file: file, line: line)
        XCTAssertTrue(before.attachmentFileURLs.isEmpty, file: file, line: line)
        XCTAssertTrue(before.attachmentFileDigests.isEmpty, file: file, line: line)
        let originalDormant = try CloudDormantAcceptedBaseBundle.decode(before.opaqueSyncStatePayload)
        XCTAssertTrue(originalDormant.entries.isEmpty, file: file, line: line)
        XCTAssertEqual(before.opaqueSyncStateDigest,
            FailedEnableEncoding.checksum(before.opaqueSyncStatePayload), file: file, line: line)
        let originalIDs = Set(before.snips.map(\.id))
        let requestIDs = Set(before.snips.map(\.requestID))
        XCTAssertEqual(originalIDs.count, 2, file: file, line: line)
        XCTAssertEqual(requestIDs.count, 2, file: file, line: line)
        let inbox = try XCTUnwrap(before.lists.first, file: file, line: line)
        XCTAssertEqual(inbox.id, SnipList.inbox.id, file: file, line: line)
        XCTAssertEqual(inbox.desiredName, "Inbox", file: file, line: line)
        XCTAssertEqual(inbox.resolvedName, "Inbox", file: file, line: line)
        XCTAssertEqual(inbox.systemImage, "tray.fill", file: file, line: line)
        XCTAssertNil(inbox.color, file: file, line: line)
        XCTAssertEqual(inbox.sortKey.data, Data([128, 0, 0, 0, 0, 0, 0, 0, 1, 128]), file: file, line: line)
        var expectedSnips = before.snips
        let editedIndex = try XCTUnwrap(expectedSnips.firstIndex { $0.id == enabled.editedSnipID },
            file: file, line: line)
        XCTAssertEqual(expectedSnips[editedIndex].content, "kept", file: file, line: line)
        XCTAssertEqual(before.snips.filter { $0.id != enabled.editedSnipID }.map(\.content),
            ["also kept"], file: file, line: line)
        expectedSnips[editedIndex].content = Self.sameServerEditedText
        expectedSnips[editedIndex].updatedAt = before.snips[editedIndex].updatedAt.addingTimeInterval(10)
        let snipPresence: [String: FailedEnablePresence] = [
            "createdAt": .value, "id": .value, "isDone": .value, "originRaw": .value,
            "pinnedAt": .value, "placement": .value, "requestID": .value,
            "source": .value, "text": .value, "updatedAt": .value,
        ]
        let listPresence: [String: FailedEnablePresence] = [
            "colorPreset": .value, "desiredName": .value, "id": .value,
            "orderKey": .value, "systemImage": .value, "updatedAt": .value,
        ]
        var originalImages: [FailedEnableReference: FailedEnableImage] = [:]
        var editedImages: [FailedEnableReference: FailedEnableImage] = [:]
        var originalQ: [FailedEnableReference: FailedEnablePreparedValue] = [:]
        var editedQ: [FailedEnableReference: FailedEnablePreparedValue] = [:]
        var expectedOverrides: [FailedEnableReference: FailedEnableImmutableOverrides] = [:]
        for (original, edited) in zip(before.snips, expectedSnips) {
            XCTAssertEqual(original.origin, .quickEntry, file: file, line: line)
            XCTAssertNil(original.source, file: file, line: line)
            XCTAssertFalse(original.isDone, file: file, line: line)
            XCTAssertNil(original.pinnedAt, file: file, line: line)
            XCTAssertEqual(original.listID, SnipList.inbox.id, file: file, line: line)
            XCTAssertTrue(original.attachments.isEmpty, file: file, line: line)
            let reference = FailedEnableReference(CloudEntityReference(kind: .snip, domainID: original.id))
            let createdAt = try FailedEnableEncoding.date(original.createdAt)
            let updatedAt = try FailedEnableEncoding.date(original.updatedAt)
            originalImages[reference] = .snip(try FailedEnableSnipImage(original, attachmentData: [:]))
            editedImages[reference] = .snip(try FailedEnableSnipImage(edited, attachmentData: [:]))
            let value = FailedEnableSnipValue(
                id: FailedEnableEncoding.uuid(original.id), requestID: FailedEnableEncoding.uuid(original.requestID),
                createdAt: createdAt, originRaw: SnipOrigin.quickEntry.rawValue, text: original.content,
                source: .init(nil), isDone: false, pinnedAt: .init(nil),
                placement: FailedEnablePlacement(listID: FailedEnableEncoding.uuid(inbox.id),
                    orderKey: original.manualSortKey.data), updatedAt: updatedAt
            )
            originalQ[reference] = FailedEnablePreparedValue(fields: .snip(value), presence: snipPresence)
            var editedValue = value
            editedValue.text = original.id == enabled.editedSnipID ? Self.sameServerEditedText : "also kept"
            editedValue.updatedAt = try FailedEnableEncoding.date(edited.updatedAt)
            editedQ[reference] = FailedEnablePreparedValue(fields: .snip(editedValue), presence: snipPresence)
            expectedOverrides[reference] = FailedEnableImmutableOverrides(
                requestID: FailedEnableEncoding.uuid(original.requestID), createdAt: createdAt,
                originRaw: SnipOrigin.quickEntry.rawValue
            )
        }
        let inboxReference = FailedEnableReference(CloudEntityReference(kind: .list, domainID: inbox.id))
        originalImages[inboxReference] = .list(FailedEnableListImage(inbox))
        editedImages[inboxReference] = .list(FailedEnableListImage(inbox))
        let inboxQ = FailedEnablePreparedValue(fields: .list(FailedEnableListValue(
            id: FailedEnableEncoding.uuid(inbox.id), desiredName: "Inbox", systemImage: "tray.fill",
            colorPreset: .init(nil), orderKey: inbox.sortKey.data, updatedAt: "0000000000000000"
        )), presence: listPresence)
        originalQ[inboxReference] = inboxQ
        editedQ[inboxReference] = inboxQ
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let files = FailedEnableEvidenceFile(root: root)
        let evidence = try XCTUnwrap(try files.read(firstTransition.sourceStoreID), file: file, line: line)
        XCTAssertEqual(evidence.sourceStoreID, FailedEnableEncoding.uuid(firstTransition.sourceStoreID),
            file: file, line: line)
        XCTAssertEqual(evidence.purpose, .installedEvidence, file: file, line: line)
        XCTAssertTrue(evidence.blobs.isEmpty, file: file, line: line)
        let group = try XCTUnwrap(evidence.namespaces.first {
            $0.binding == FailedEnableBinding(namespace.binding)
        }, file: file, line: line)
        XCTAssertTrue(group.alternatives.isEmpty, file: file, line: line)
        XCTAssertTrue(group.reviews.isEmpty, file: file, line: line)
        let firstCapture = try XCTUnwrap(group.captures.first {
            $0.transitionID == FailedEnableEncoding.uuid(firstTransition.id)
                && $0.candidateStoreID == FailedEnableEncoding.uuid(firstTransition.candidateStoreID)
        }, file: file, line: line)
        let firstFreeze = try XCTUnwrap(firstTransition.freezeToken, file: file, line: line)
        XCTAssertEqual(firstFreeze.sourceStoreID, firstTransition.sourceStoreID, file: file, line: line)
        XCTAssertEqual(firstFreeze.revision, before.revision, file: file, line: line)
        XCTAssertEqual(firstCapture.freeze.id, FailedEnableEncoding.uuid(firstFreeze.id), file: file, line: line)
        XCTAssertEqual(firstCapture.freeze.sourceRevision, String(before.revision), file: file, line: line)
        XCTAssertEqual(firstCapture.syncProtocol, .fullRecordV1, file: file, line: line)
        XCTAssertEqual(firstCapture.normalizer, 1, file: file, line: line)
        XCTAssertTrue(firstCapture.armed, file: file, line: line)
        XCTAssertTrue(firstCapture.predecessors.isEmpty, file: file, line: line)
        XCTAssertTrue(firstCapture.candidateDeletes.isEmpty, file: file, line: line)
        XCTAssertEqual(firstCapture.seenRequestIDs, requestIDs.map(FailedEnableEncoding.uuid).sorted(),
            file: file, line: line)
        XCTAssertEqual(Set(firstCapture.records.map(\.reference)), Set(originalImages.keys), file: file, line: line)
        XCTAssertEqual(firstCapture.records.count, 3, file: file, line: line)
        let firstTransfer = try XCTUnwrap(evidence.transfers.first {
            $0.sourceCaptureIDs == [firstCapture.id]
        }, file: file, line: line)
        XCTAssertEqual(firstTransfer.kind, .candidate, file: file, line: line)
        XCTAssertEqual(firstTransfer.state, .checked, file: file, line: line)
        XCTAssertEqual(firstTransfer.sourceStoreID, evidence.sourceStoreID, file: file, line: line)
        XCTAssertEqual(firstTransfer.destinationStoreID, firstCapture.candidateStoreID, file: file, line: line)
        XCTAssertEqual(firstTransfer.namespace, group.binding, file: file, line: line)
        XCTAssertEqual(firstTransfer.dormantDigest, FailedEnableEncoding.digest(before.opaqueSyncStatePayload),
            file: file, line: line)
        XCTAssertEqual(firstTransfer.outputs, originalImages.values.sorted {
            $0.reference.sortKey < $1.reference.sortKey
        }, file: file, line: line)
        XCTAssertTrue(firstTransfer.conflicts.isEmpty, file: file, line: line)
        XCTAssertTrue(firstTransfer.recoveryDescriptors.isEmpty, file: file, line: line)
        let committed = enabled.stranded.committedCandidateBeforeDiscard
        XCTAssertEqual(committed.readyEntities.count, 3, file: file, line: line)
        XCTAssertTrue(committed.deferredEntities.isEmpty, file: file, line: line)
        XCTAssertTrue(committed.conflicts.isEmpty, file: file, line: line)
        XCTAssertTrue(committed.pendingDeletes.isEmpty, file: file, line: line)
        XCTAssertTrue(committed.quarantines.isEmpty, file: file, line: line)
        let committedInbox = try XCTUnwrap(committed.readyEntities.first {
            $0.reference == CloudEntityReference(kind: .list, domainID: inbox.id)
        }, file: file, line: line)
        let committedInboxRecord = try CloudFullSyncPersistence.listRecord(committedInbox)
        if case .missing = committedInboxRecord.updatedAt {
            XCTFail("The real initial List save must contain its send timestamp.", file: file, line: line)
        }
        for record in firstCapture.records {
            let reference = try record.reference.domain
            XCTAssertEqual(record.sourceMembership, .present, file: file, line: line)
            XCTAssertEqual(record.source.value, originalImages[record.reference], file: file, line: line)
            XCTAssertFalse(record.originalAcceptedExists, file: file, line: line)
            XCTAssertEqual(record.preparation.normalizer, 1, file: file, line: line)
            XCTAssertEqual(record.preparation.classification, .nonconflicting, file: file, line: line)
            XCTAssertEqual(record.preparation.baseKind, .noBaseEnrollment, file: file, line: line)
            XCTAssertNil(record.preparation.baseDigest.value, file: file, line: line)
            XCTAssertNil(record.preparation.fetchedDigest.value, file: file, line: line)
            XCTAssertNil(record.preparation.reason.value, file: file, line: line)
            XCTAssertTrue(record.preparation.conflictFields.isEmpty, file: file, line: line)
            XCTAssertTrue(record.preparation.recoveryIdentities.isEmpty, file: file, line: line)
            let expected = try XCTUnwrap(originalQ[record.reference], file: file, line: line)
            XCTAssertEqual(record.preparation.value.value, expected, file: file, line: line)
            XCTAssertEqual(record.preparation.knownFields, expected.presence.keys.sorted(), file: file, line: line)
            XCTAssertEqual(record.preparation.normalizedLocal.acceptedPresence, expected.presence, file: file, line: line)
            XCTAssertTrue(record.preparation.normalizedLocal.defaults.isEmpty, file: file, line: line)
            XCTAssertEqual(record.preparation.normalizedLocal.immutableOverrides.value,
                expectedOverrides[record.reference], file: file, line: line)
            XCTAssertNil(record.unqualifiedObservation.value, file: file, line: line)
            let observation = try XCTUnwrap(record.observedAccepted.value, file: file, line: line)
            let actual = try XCTUnwrap(committed.readyEntities.first { $0.reference == reference },
                file: file, line: line)
            let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: observation.entityBase64)
            let identity = CloudTextStorageIdentity(zoneName: zone.name, ownerName: zone.ownerName,
                recordName: "\(reference.kind == .snip ? "s" : "l")-\(reference.domainID.uuidString.lowercased())")
            XCTAssertEqual(record.identity.domain, identity, file: file, line: line)
            XCTAssertEqual(actual.identity, identity, file: file, line: line)
            XCTAssertEqual(actual.schemaVersion, 3, file: file, line: line)
            XCTAssertEqual(actual.dependencyListID, reference.kind == .snip ? inbox.id : nil,
                file: file, line: line)
            XCTAssertFalse(actual.isDeferred, file: file, line: line)
            XCTAssertFalse(actual.wasMaterializedBeforeDeferral, file: file, line: line)
            XCTAssertFalse(actual.hasUnresolvedLegacyAbsence, file: file, line: line)
            XCTAssertNil(actual.graphRepair, file: file, line: line)
            XCTAssertNil(actual.deferredLocalMutation, file: file, line: line)
            XCTAssertEqual(observation.kind, .fullRecord, file: file, line: line)
            XCTAssertEqual(observation.candidateStoreID, firstCapture.candidateStoreID, file: file, line: line)
            let observedRevision = try FailedEnableEncoding.revision(observation.namespaceRevision)
            XCTAssertLessThanOrEqual(observedRevision, committed.namespaceState.revision, file: file, line: line)
            XCTAssertEqual(observation.localRevision, String(actual.localRevision), file: file, line: line)
            XCTAssertFalse(observation.isDeferred, file: file, line: line)
            XCTAssertFalse(observation.hasUnresolvedLegacyAbsence, file: file, line: line)
            XCTAssertEqual(observation.dependencyListID.value,
                actual.dependencyListID.map(FailedEnableEncoding.uuid), file: file, line: line)
            XCTAssertEqual(envelope.reference, actual.reference, file: file, line: line)
            XCTAssertEqual(envelope.identity, actual.identity, file: file, line: line)
            XCTAssertEqual(envelope.schemaVersion, actual.schemaVersion, file: file, line: line)
            XCTAssertEqual(envelope.acceptedData, actual.acceptedData, file: file, line: line)
            XCTAssertEqual(envelope.presenceData, actual.presenceData, file: file, line: line)
            XCTAssertEqual(envelope.shadowData, actual.shadowData, file: file, line: line)
            XCTAssertEqual(envelope.systemFields, actual.systemFields, file: file, line: line)
            XCTAssertEqual(envelope.dependencyListID, actual.dependencyListID, file: file, line: line)
            if reference.kind == .snip {
                let original = try XCTUnwrap(before.snips.first { $0.id == reference.domainID },
                    file: file, line: line)
                let accepted = try CloudFullSyncPersistence.snipRecord(actual)
                XCTAssertEqual(accepted, try JSONDecoder().decode(CloudTypedSnipRecord.self, from: actual.acceptedData),
                    file: file, line: line)
                XCTAssertEqual(accepted, try JSONDecoder().decode(CloudTypedSnipRecord.self, from: actual.presenceData),
                    file: file, line: line)
                XCTAssertEqual(accepted.storageVersion, 1, file: file, line: line)
                XCTAssertEqual(accepted.binding, .canonical, file: file, line: line)
                XCTAssertEqual(accepted.id, .snip(original.id, in: zone), file: file, line: line)
                XCTAssertEqual(accepted.domainID, original.id, file: file, line: line)
                XCTAssertEqual(accepted.schemaVersion, 3, file: file, line: line)
                XCTAssertEqual(accepted.requestID, .value(original.requestID), file: file, line: line)
                XCTAssertEqual(accepted.createdAt, .value(original.createdAt), file: file, line: line)
                XCTAssertEqual(accepted.updatedAt, .value(original.updatedAt), file: file, line: line)
                XCTAssertEqual(accepted.origin, .value(SnipOrigin.quickEntry.rawValue), file: file, line: line)
                XCTAssertEqual(accepted.text, .value(original.content), file: file, line: line)
                XCTAssertEqual(accepted.source, .value(nil), file: file, line: line)
                XCTAssertEqual(accepted.isDone, .value(false), file: file, line: line)
                XCTAssertNil(accepted.pinnedAt, file: file, line: line)
                XCTAssertEqual(accepted.placement, .value(CloudSnipPlacement(
                    listID: inbox.id, orderKey: original.manualSortKey)), file: file, line: line)
                XCTAssertEqual(accepted.shadow.data, actual.shadowData, file: file, line: line)
                XCTAssertEqual(accepted.shadow.systemFields, actual.systemFields, file: file, line: line)
            } else {
                let accepted = try CloudFullSyncPersistence.listRecord(actual)
                XCTAssertEqual(accepted, try JSONDecoder().decode(CloudTypedListRecord.self, from: actual.acceptedData),
                    file: file, line: line)
                XCTAssertEqual(accepted, try JSONDecoder().decode(CloudTypedListRecord.self, from: actual.presenceData),
                    file: file, line: line)
                XCTAssertEqual(accepted.storageVersion, 1, file: file, line: line)
                XCTAssertEqual(accepted.binding, .canonical, file: file, line: line)
                XCTAssertEqual(accepted.id, .list(inbox.id, in: zone), file: file, line: line)
                XCTAssertEqual(accepted.domainID, inbox.id, file: file, line: line)
                XCTAssertEqual(accepted.schemaVersion, 3, file: file, line: line)
                XCTAssertEqual(accepted.desiredName, .value("Inbox"), file: file, line: line)
                XCTAssertEqual(accepted.systemImage, .value("tray.fill"), file: file, line: line)
                XCTAssertEqual(accepted.color, .some(.value(nil)), file: file, line: line)
                XCTAssertEqual(accepted.orderKey, .value(inbox.sortKey), file: file, line: line)
                XCTAssertEqual(accepted.updatedAt, committedInboxRecord.updatedAt, file: file, line: line)
                XCTAssertEqual(accepted.shadow.data, actual.shadowData, file: file, line: line)
                XCTAssertEqual(accepted.shadow.systemFields, actual.systemFields, file: file, line: line)
            }
        }
        let freshCapture = try XCTUnwrap(group.captures.first {
            $0.transitionID == FailedEnableEncoding.uuid(freshTransitionID)
        }, file: file, line: line)
        XCTAssertNotEqual(freshCapture.candidateStoreID, firstCapture.candidateStoreID, file: file, line: line)
        XCTAssertEqual(freshCapture.syncProtocol, .fullRecordV1, file: file, line: line)
        XCTAssertEqual(freshCapture.normalizer, 1, file: file, line: line)
        XCTAssertTrue(freshCapture.armed, file: file, line: line)
        XCTAssertEqual(freshCapture.freeze.sourceRevision, String(before.revision + 1), file: file, line: line)
        XCTAssertNotEqual(freshCapture.freeze.id, firstCapture.freeze.id, file: file, line: line)
        XCTAssertNotEqual(freshCapture.sourceDigest, firstCapture.sourceDigest, file: file, line: line)
        XCTAssertTrue(freshCapture.predecessors.contains(firstCapture.id), file: file, line: line)
        XCTAssertTrue(freshCapture.candidateDeletes.isEmpty, file: file, line: line)
        XCTAssertEqual(freshCapture.seenRequestIDs, firstCapture.seenRequestIDs, file: file, line: line)
        XCTAssertEqual(Set(freshCapture.records.map(\.reference)), Set(editedImages.keys), file: file, line: line)
        XCTAssertEqual(freshCapture.records.count, 3, file: file, line: line)
        let editedReference = FailedEnableReference(CloudEntityReference(kind: .snip, domainID: enabled.editedSnipID))
        for record in freshCapture.records {
            XCTAssertEqual(record.sourceMembership, .present, file: file, line: line)
            XCTAssertEqual(record.source.value, editedImages[record.reference], file: file, line: line)
            let expected = try XCTUnwrap(editedQ[record.reference], file: file, line: line)
            let original = try XCTUnwrap(originalQ[record.reference], file: file, line: line)
            XCTAssertEqual(record.preparation.value.value, expected, file: file, line: line)
            XCTAssertEqual(record.preparation.normalizer, 1, file: file, line: line)
            XCTAssertEqual(record.preparation.knownFields, expected.presence.keys.sorted(), file: file, line: line)
            XCTAssertEqual(record.preparation.normalizedLocal.acceptedPresence, expected.presence, file: file, line: line)
            XCTAssertTrue(record.preparation.normalizedLocal.defaults.isEmpty, file: file, line: line)
            XCTAssertEqual(record.preparation.normalizedLocal.immutableOverrides.value,
                expectedOverrides[record.reference], file: file, line: line)
            XCTAssertEqual(record.preparation.baseKind, .sourceCapture, file: file, line: line)
            XCTAssertEqual(record.preparation.baseDigest.value,
                try FailedEnableEncoding.digest(original.fields), file: file, line: line)
            XCTAssertNotNil(record.preparation.fetchedDigest.value, file: file, line: line)
            XCTAssertEqual(record.preparation.classification,
                record.reference == editedReference ? .nonconflicting : .equalFetched, file: file, line: line)
            XCTAssertTrue(record.preparation.recoveryIdentities.isEmpty, file: file, line: line)
            XCTAssertTrue(record.preparation.conflictFields.isEmpty, file: file, line: line)
            XCTAssertNotNil(record.observedAccepted.value, file: file, line: line)
        }
        let freshTransfer = try XCTUnwrap(evidence.transfers.first {
            $0.sourceCaptureIDs == [freshCapture.id]
        }, file: file, line: line)
        XCTAssertEqual(freshTransfer.kind, .candidate, file: file, line: line)
        XCTAssertEqual(freshTransfer.state, .checked, file: file, line: line)
        XCTAssertEqual(freshTransfer.sourceStoreID, evidence.sourceStoreID, file: file, line: line)
        XCTAssertEqual(freshTransfer.destinationStoreID, freshCapture.candidateStoreID, file: file, line: line)
        XCTAssertEqual(freshTransfer.namespace, group.binding, file: file, line: line)
        XCTAssertEqual(freshTransfer.outputs, editedImages.values.sorted {
            $0.reference.sortKey < $1.reference.sortKey
        }, file: file, line: line)
        XCTAssertEqual(freshTransfer.dormantDigest, firstTransfer.dormantDigest, file: file, line: line)
        XCTAssertTrue(freshTransfer.conflicts.isEmpty, file: file, line: line)
        XCTAssertTrue(freshTransfer.recoveryDescriptors.isEmpty, file: file, line: line)
        var persistence = enabled.persistence
        var coordinator = sameServerCoordinator(on: persistence, server: enabled.stranded.server)
        for pass in 0..<3 {
            if pass == 1 {
                let repeated = try await coordinator.enableOrRetry()
                XCTAssertEqual(repeated.state, .on, file: file, line: line)
            } else if pass == 2 {
                persistence = try relaunch(enabled.stranded, root: root)
                coordinator = sameServerCoordinator(on: persistence, server: enabled.stranded.server)
                let reopened = try await coordinator.enableOrRetry()
                XCTAssertEqual(reopened.state, .on, file: file, line: line)
            }
            let storage = try await persistence.snapshot()
            XCTAssertNil(storage.transition, file: file, line: line)
            XCTAssertEqual(storage.activeStore.kind, .iCloudSync, file: file, line: line)
            XCTAssertEqual(FailedEnableEncoding.uuid(storage.activeStore.id), freshCapture.candidateStoreID,
                file: file, line: line)
            XCTAssertEqual(enabled.stranded.disk.transitionIDsAtSwap,
                [firstTransition.id, freshTransitionID], file: file, line: line)
            let active = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
            let final = try await active.transferSnapshot(revision: storage.activeStore.revision)
            XCTAssertEqual(final.snips, expectedSnips, file: file, line: line)
            XCTAssertEqual(Set(final.snips.map(\.id)), originalIDs, file: file, line: line)
            XCTAssertEqual(Set(final.snips.map(\.requestID)), requestIDs, file: file, line: line)
            XCTAssertEqual(final.snips.count, 2, file: file, line: line)
            XCTAssertEqual(final.lists, before.lists, file: file, line: line)
            XCTAssertEqual(final.attachmentData, before.attachmentData, file: file, line: line)
            XCTAssertTrue(final.attachmentFileURLs.isEmpty, file: file, line: line)
            XCTAssertTrue(final.attachmentFileDigests.isEmpty, file: file, line: line)
            XCTAssertEqual(final.opaqueSyncStatePayload, before.opaqueSyncStatePayload, file: file, line: line)
            XCTAssertEqual(final.opaqueSyncStateDigest, before.opaqueSyncStateDigest, file: file, line: line)
            let archive = try await active.archive()
            XCTAssertEqual(Set(archive.seenRequestIDs), requestIDs, file: file, line: line)
            let currentStorage = try await active.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
            XCTAssertTrue(currentStorage.deferredEntities.isEmpty, file: file, line: line)
            XCTAssertTrue(currentStorage.conflicts.isEmpty, file: file, line: line)
            XCTAssertTrue(currentStorage.pendingDeletes.isEmpty, file: file, line: line)
            XCTAssertTrue(currentStorage.quarantines.isEmpty, file: file, line: line)
            let recoveries = try await active.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
            XCTAssertTrue(recoveries.isEmpty, file: file, line: line)
            let serverRecords = await enabled.stranded.server.storedRecordTypes(in: zone)
            XCTAssertEqual(serverRecords.sorted(), ["List", "Snip", "Snip"], file: file, line: line)
            XCTAssertEqual(serverRecords.filter { $0 == "Snip" }.count, 2, file: file, line: line)
            let serverTexts = await enabled.stranded.server.storedTextValues()
            XCTAssertEqual(serverTexts, ["also kept", Self.sameServerEditedText].sorted(), file: file, line: line)
            for snip in expectedSnips {
                let remote = await enabled.stranded.server.fullSnapshot(for: .snip(snip.id, in: zone))
                let serverSnip = try CloudFullRecordCodec.snip(from: XCTUnwrap(remote, file: file, line: line))
                XCTAssertEqual(serverSnip.storageVersion, 1, file: file, line: line)
                XCTAssertEqual(serverSnip.binding, .canonical, file: file, line: line)
                XCTAssertEqual(serverSnip.id, .snip(snip.id, in: zone), file: file, line: line)
                XCTAssertEqual(serverSnip.domainID, snip.id, file: file, line: line)
                XCTAssertEqual(serverSnip.schemaVersion, 3, file: file, line: line)
                XCTAssertEqual(serverSnip.requestID, .value(snip.requestID), file: file, line: line)
                XCTAssertEqual(serverSnip.createdAt, .value(snip.createdAt), file: file, line: line)
                XCTAssertEqual(serverSnip.updatedAt, .value(snip.updatedAt), file: file, line: line)
                XCTAssertEqual(serverSnip.origin, .value(SnipOrigin.quickEntry.rawValue), file: file, line: line)
                XCTAssertEqual(serverSnip.text, .value(snip.content), file: file, line: line)
                XCTAssertEqual(serverSnip.source, .value(nil), file: file, line: line)
                XCTAssertEqual(serverSnip.isDone, .value(false), file: file, line: line)
                XCTAssertNil(serverSnip.pinnedAt, file: file, line: line)
                XCTAssertEqual(serverSnip.placement, .value(CloudSnipPlacement(
                    listID: inbox.id, orderKey: snip.manualSortKey)), file: file, line: line)
                for transitionID in [firstTransition.id, freshTransitionID] {
                    let recoveryID = SnipLibraryTransferPlanner.derivedUUID(
                        transitionID: transitionID, sourceID: snip.id)
                    XCTAssertFalse(originalIDs.contains(recoveryID), file: file, line: line)
                    XCTAssertFalse(final.snips.contains { $0.id == recoveryID }, file: file, line: line)
                    let unnecessary = await enabled.stranded.server.fullSnapshot(for: .snip(recoveryID, in: zone))
                    XCTAssertNil(unnecessary, file: file, line: line)
                }
            }
            let remoteInbox = await enabled.stranded.server.fullSnapshot(for: .list(inbox.id, in: zone))
            let serverInbox = try CloudFullRecordCodec.list(from: XCTUnwrap(remoteInbox, file: file, line: line))
            XCTAssertEqual(serverInbox.storageVersion, 1, file: file, line: line)
            XCTAssertEqual(serverInbox.binding, .canonical, file: file, line: line)
            XCTAssertEqual(serverInbox.id, .list(inbox.id, in: zone), file: file, line: line)
            XCTAssertEqual(serverInbox.domainID, inbox.id, file: file, line: line)
            XCTAssertEqual(serverInbox.schemaVersion, 3, file: file, line: line)
            XCTAssertEqual(serverInbox.desiredName, .value("Inbox"), file: file, line: line)
            XCTAssertEqual(serverInbox.systemImage, .value("tray.fill"), file: file, line: line)
            XCTAssertEqual(serverInbox.color, .some(.value(nil)), file: file, line: line)
            XCTAssertEqual(serverInbox.orderKey, .value(inbox.sortKey), file: file, line: line)
            XCTAssertEqual(serverInbox.updatedAt, committedInboxRecord.updatedAt, file: file, line: line)
            let retained = try XCTUnwrap(try files.read(firstTransition.sourceStoreID), file: file, line: line)
            let retainedGroup = try XCTUnwrap(retained.namespaces.first { $0.binding == group.binding },
                file: file, line: line)
            XCTAssertEqual(retainedGroup.captures.first { $0.id == firstCapture.id }, firstCapture,
                file: file, line: line)
            XCTAssertEqual(retainedGroup.captures.first { $0.id == freshCapture.id }, freshCapture,
                file: file, line: line)
            XCTAssertTrue(retained.transfers.contains(firstTransfer), file: file, line: line)
            XCTAssertTrue(retained.transfers.contains(freshTransfer), file: file, line: line)
            XCTAssertTrue(retainedGroup.alternatives.isEmpty, file: file, line: line)
            XCTAssertTrue(retainedGroup.reviews.isEmpty, file: file, line: line)
            XCTAssertEqual(retained.blobs, evidence.blobs, file: file, line: line)
        }
    }

    /// Runs the fresh enable `retry` names, and checks that it ends On through a new transition
    /// with exactly one copy of each snip. An edit, where `retry` makes one, must land on the
    /// original snip.
    private func assertFreshEnableKeepsOneCopyOfEachSnip(
        _ retry: SameServerRetry,
        fullDisk: SameServerFullDisk.Extent = .manifestOnly,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let enabled = try await freshEnableOnTheSameServer(
            after: retry,
            fullDisk: fullDisk,
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

        let persistence: SwiftDataSyncModePersistence
        switch retry {
        case .tryAgain:
            try await removeCandidateFiles(of: stranded)
            stranded.disk.free()
            persistence = stranded.persistence
        case .relaunchEditThenTryAgain:
            stranded.disk.free()
            let evidenceFiles = FailedEnableEvidenceFile(root: root)
            let sourceID = stranded.transition.sourceStoreID
            let activationURL = root.appendingPathComponent("activation.json")
            let activationBytesBefore = try Data(contentsOf: activationURL)
            let activationBefore = try JSONDecoder().decode(
                SwiftDataSyncModePersistence.Manifest.self, from: activationBytesBefore
            )
            let manifestBefore = await stranded.persistence.manifest
            let uncertainBefore = await stranded.persistence.failedEnableUncertainSources
            let ownerBefore = await stranded.persistence.failedEnableOwnerNonce
            let reopenBefore = await stranded.persistence.failedEnableReopenManifest
            let activationDigestBefore = await stranded.persistence.failedEnableActivationDigest(
                activationBefore
            )
            let frameBytesBefore = try Data(contentsOf: evidenceFiles.url(sourceID))
            let evidenceBefore = try XCTUnwrap(evidenceFiles.read(sourceID), file: file, line: line)
            let factsBefore = "[SM23-F5-FROZEN] before sequence=\(evidenceBefore.sequence) "
                + "continuity=\(evidenceBefore.continuity) uncertain=\(uncertainBefore) "
                + "owner=\(ownerBefore) activation=\(activationDigestBefore) "
                + "frame=\(FailedEnableEncoding.digest(frameBytesBefore))"
            let ticketBefore = try XCTUnwrap(
                evidenceBefore.continuity.inFlight.value, factsBefore, file: file, line: line
            )
            let postimageBefore = try XCTUnwrap(
                ticketBefore.manifestPostimageDigest.value, factsBefore, file: file, line: line
            )
            let sourceBefore = try XCTUnwrap(
                manifestBefore.stores.first { $0.id == sourceID }, factsBefore, file: file, line: line
            )
            let freezeBefore = try XCTUnwrap(
                stranded.transition.freezeToken, factsBefore, file: file, line: line
            )
            let namespaceBefore = try XCTUnwrap(
                stranded.transition.namespace, factsBefore, file: file, line: line
            )
            let groupBefore = try XCTUnwrap(
                evidenceBefore.namespaces.first { $0.binding == FailedEnableBinding(namespaceBefore) },
                factsBefore, file: file, line: line
            )
            let captureBefore = try XCTUnwrap(
                groupBefore.captures.last {
                    $0.transitionID == FailedEnableEncoding.uuid(stranded.transition.id)
                        && $0.candidateStoreID == FailedEnableEncoding.uuid(
                            stranded.transition.candidateStoreID
                        )
                }, factsBefore, file: file, line: line
            )
            let expectedReferences = Set(stranded.originals.keys.map {
                FailedEnableReference(CloudEntityReference(kind: .snip, domainID: $0))
            }).union([FailedEnableReference(CloudEntityReference(kind: .list, domainID: SnipList.inbox.id))])
            XCTAssertEqual(activationBefore, manifestBefore, factsBefore, file: file, line: line)
            XCTAssertEqual(manifestBefore.transition, stranded.transition, factsBefore, file: file, line: line)
            XCTAssertEqual(manifestBefore.activeStoreID, sourceID, factsBefore, file: file, line: line)
            XCTAssertEqual(stranded.transition.phase, .firstSendComplete, factsBefore, file: file, line: line)
            XCTAssertTrue(stranded.transition.freezesSource, factsBefore, file: file, line: line)
            XCTAssertNil(manifestBefore.writeReservation, factsBefore, file: file, line: line)
            XCTAssertNil(reopenBefore, factsBefore, file: file, line: line)
            XCTAssertFalse(uncertainBefore.contains(sourceID), factsBefore, file: file, line: line)
            XCTAssertEqual(evidenceBefore.continuity.state, .verified, factsBefore, file: file, line: line)
            XCTAssertEqual(ticketBefore.kind, .manifest, factsBefore, file: file, line: line)
            XCTAssertEqual(ticketBefore.ownerNonce, FailedEnableEncoding.uuid(ownerBefore), factsBefore, file: file, line: line)
            XCTAssertEqual(ticketBefore.previousActivationDigest, evidenceBefore.continuity.activationDigest, factsBefore, file: file, line: line)
            XCTAssertNotEqual(activationDigestBefore, "unavailable", factsBefore, file: file, line: line)
            XCTAssertEqual(postimageBefore.count, 64, factsBefore, file: file, line: line)
            XCTAssertTrue(postimageBefore.allSatisfy { "0123456789abcdef".contains($0) }, factsBefore, file: file, line: line)
            XCTAssertNotEqual(postimageBefore, ticketBefore.previousActivationDigest, factsBefore, file: file, line: line)
            XCTAssertTrue([ticketBefore.previousActivationDigest, postimageBefore].contains(activationDigestBefore), factsBefore, file: file, line: line)
            XCTAssertNil(ticketBefore.reservedRevision.value, factsBefore, file: file, line: line)
            XCTAssertEqual(ticketBefore.previousSourceRevision, String(sourceBefore.revision), factsBefore, file: file, line: line)
            XCTAssertEqual(ticketBefore.previousSourceDigest, evidenceBefore.continuity.sourceDigest, factsBefore, file: file, line: line)
            XCTAssertEqual(evidenceBefore.continuity.sourceRevision, String(sourceBefore.revision), factsBefore, file: file, line: line)
            XCTAssertEqual(captureBefore.freeze.id, FailedEnableEncoding.uuid(freezeBefore.id), factsBefore, file: file, line: line)
            XCTAssertEqual(captureBefore.freeze.sourceRevision, String(freezeBefore.revision), factsBefore, file: file, line: line)
            XCTAssertEqual(freezeBefore.revision, sourceBefore.revision, factsBefore, file: file, line: line)
            XCTAssertEqual(freezeBefore.sourceStoreID, sourceID, factsBefore, file: file, line: line)
            XCTAssertEqual(captureBefore.sourceDigest, evidenceBefore.continuity.sourceDigest, factsBefore, file: file, line: line)
            XCTAssertTrue(captureBefore.armed, factsBefore, file: file, line: line)
            XCTAssertEqual(Set(captureBefore.records.map(\.reference)), expectedReferences, factsBefore, file: file, line: line)
            XCTAssertTrue(evidenceBefore.transfers.contains {
                $0.kind == .candidate && $0.state == .checked
                    && $0.sourceCaptureIDs == [captureBefore.id]
                    && $0.sourceStoreID == FailedEnableEncoding.uuid(sourceID)
                    && $0.destinationStoreID == captureBefore.candidateStoreID
                    && $0.namespace == groupBefore.binding
            }, factsBefore, file: file, line: line)
            for record in captureBefore.records {
                XCTAssertNotNil(record.source.value, factsBefore, file: file, line: line)
                XCTAssertNotNil(record.preparation.value.value, factsBefore, file: file, line: line)
                XCTAssertNotNil(record.observedAccepted.value, factsBefore, file: file, line: line)
                XCTAssertEqual(record.observedAccepted.value?.candidateStoreID, captureBefore.candidateStoreID, factsBefore, file: file, line: line)
                if case .snip(let image)? = record.source.value {
                    let id = try FailedEnableEncoding.uuid(image.id)
                    XCTAssertEqual(image.text, stranded.originals[id], factsBefore, file: file, line: line)
                    XCTAssertFalse(image.isDone, factsBefore, file: file, line: line)
                }
            }
            let stableManifestBefore = await stranded.persistence.manifest
            XCTAssertEqual(stableManifestBefore, manifestBefore, factsBefore, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: activationURL), activationBytesBefore, factsBefore, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: evidenceFiles.url(sourceID)), frameBytesBefore, factsBefore, file: file, line: line)
            print(factsBefore)
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
            let activationBytesAfter = try Data(contentsOf: activationURL)
            let activationAfter = try JSONDecoder().decode(
                SwiftDataSyncModePersistence.Manifest.self, from: activationBytesAfter
            )
            let manifestAfter = await stranded.persistence.manifest
            let uncertainAfter = await stranded.persistence.failedEnableUncertainSources
            let ownerAfter = await stranded.persistence.failedEnableOwnerNonce
            let activationDigestAfter = await stranded.persistence.failedEnableActivationDigest(
                activationAfter
            )
            let frameBytesAfter = try Data(contentsOf: evidenceFiles.url(sourceID))
            let evidenceAfter = try XCTUnwrap(evidenceFiles.read(sourceID), factsBefore, file: file, line: line)
            let factsAfter = factsBefore + " after sequence=\(evidenceAfter.sequence) "
                + "continuity=\(evidenceAfter.continuity) uncertain=\(uncertainAfter) "
                + "owner=\(ownerAfter) activation=\(activationDigestAfter) "
                + "frame=\(FailedEnableEncoding.digest(frameBytesAfter))"
            XCTAssertEqual(activationAfter, manifestAfter, factsAfter, file: file, line: line)
            XCTAssertEqual(manifestAfter, manifestBefore, factsAfter, file: file, line: line)
            XCTAssertEqual(activationDigestAfter, activationDigestBefore, factsAfter, file: file, line: line)
            XCTAssertEqual(ownerAfter, ownerBefore, factsAfter, file: file, line: line)
            XCTAssertEqual(uncertainAfter, uncertainBefore, factsAfter, file: file, line: line)
            XCTAssertEqual(evidenceAfter.continuity.state, .verified, factsAfter, file: file, line: line)
            XCTAssertEqual(evidenceAfter.continuity.sourceRevision, evidenceBefore.continuity.sourceRevision, factsAfter, file: file, line: line)
            XCTAssertEqual(evidenceAfter.continuity.sourceDigest, evidenceBefore.continuity.sourceDigest, factsAfter, file: file, line: line)
            XCTAssertEqual(evidenceAfter.sourceStoreID, evidenceBefore.sourceStoreID, factsAfter, file: file, line: line)
            XCTAssertEqual(evidenceAfter.namespaces, evidenceBefore.namespaces, factsAfter, file: file, line: line)
            XCTAssertEqual(evidenceAfter.transfers, evidenceBefore.transfers, factsAfter, file: file, line: line)
            XCTAssertEqual(evidenceAfter.blobs, evidenceBefore.blobs, factsAfter, file: file, line: line)
            if let ticketAfter = evidenceAfter.continuity.inFlight.value {
                XCTAssertEqual(ticketAfter, ticketBefore, factsAfter, file: file, line: line)
                XCTAssertEqual(evidenceAfter.continuity.activationDigest, evidenceBefore.continuity.activationDigest, factsAfter, file: file, line: line)
            } else {
                XCTAssertEqual(postimageBefore, activationDigestAfter, factsAfter, file: file, line: line)
                XCTAssertEqual(evidenceAfter.continuity.activationDigest, activationDigestAfter, factsAfter, file: file, line: line)
            }
            let stableManifestAfter = await stranded.persistence.manifest
            XCTAssertEqual(stableManifestAfter, manifestAfter, factsAfter, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: activationURL), activationBytesAfter, factsAfter, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: evidenceFiles.url(sourceID)), frameBytesAfter, factsAfter, file: file, line: line)
            print(factsAfter)
            try await removeCandidateFiles(of: stranded)
            persistence = try relaunch(stranded, root: root)
            let reopened = try await persistence.snapshot()
            XCTAssertEqual(reopened.transition?.phase, .candidateReady, file: file, line: line)
            try await edit(editedSnipID, to: Self.sameServerEditedText, in: persistence)
            expected[editedSnipID] = Self.sameServerEditedText
        case .cancelSetupThenEnable, .cancelSetupEditThenEnable:
            stranded.disk.free()
            persistence = stranded.persistence
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
    /// reached `server`. Then it fails the pointer swap as `fullDisk` says. Only `.swapOnly`
    /// lets the restore commit; a full disk leaves `firstSendComplete` with the source frozen.
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
        for text in Self.sameServerTexts {
            try await add(text, to: persistence.activeLibrary())
        }
        let added = try await persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        let keptSnipID = try XCTUnwrap(
            added.first(where: { $0.content == Self.sameServerTexts[0] })?.id,
            file: file,
            line: line
        )
        let server = FakeCloudServer()
        if history == .turnedOffThenEditedOnBothSides {
            try await turnOffThenEditOnBothSides(
                keptSnipID,
                in: persistence,
                server: server,
                file: file,
                line: line
            )
        }
        let originals = try await persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        let inputManifest = await persistence.manifest
        let sourceStore = try XCTUnwrap(
            inputManifest.stores.first { $0.id == inputManifest.activeStoreID },
            file: file, line: line
        )
        let originalLibrary = try await persistence.libraryForTransition(storeID: sourceStore.id)
        let originalSourceBeforeEnable = try await originalLibrary.transferSnapshot(
            revision: sourceStore.revision
        )
        XCTAssertEqual(originalSourceBeforeEnable.snips, originals, file: file, line: line)
        disk.armAtPointerSwap()
        do {
            _ = try await sameServerCoordinator(on: persistence, server: server).enableOrRetry()
            XCTFail("The injected failure must end the enable.", file: file, line: line)
        } catch SameServerFullDisk.Failure.injected {}
        let stuck = try await persistence.snapshot()
        let transition = try XCTUnwrap(stuck.transition, file: file, line: line)
        XCTAssertEqual(
            transition.phase,
            fullDisk == .swapOnly ? .candidateReady : .firstSendComplete,
            file: file,
            line: line
        )
        let sent = await server.storedTextValues()
        XCTAssertEqual(
            sent,
            originals.map(\.content).sorted(),
            "The aborted enable must reach the server.",
            file: file,
            line: line
        )
        let candidateNamespace = try XCTUnwrap(transition.namespace, file: file, line: line)
        let candidate = try await persistence.libraryForTransition(storeID: transition.candidateStoreID)
        let committedCandidateBeforeDiscard = try await candidate.cloudFullStorageSnapshot(
            namespaceKey: candidateNamespace.namespaceKey
        )
        return SameServerStrandedEnable(
            persistence: persistence,
            server: server,
            disk: disk,
            probe: probe,
            transition: transition,
            keptSnipID: keptSnipID,
            originals: Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0.content) }),
            originalSourceBeforeEnable: originalSourceBeforeEnable,
            committedCandidateBeforeDiscard: committedCandidateBeforeDiscard
        )
    }

    /// Syncs the snips and turns sync off, which keeps their bases. Then another device marks
    /// `snipID` done, and this device edits its text.
    private func turnOffThenEditOnBothSides(
        _ snipID: UUID,
        in persistence: SwiftDataSyncModePersistence,
        server: FakeCloudServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let coordinator = sameServerCoordinator(on: persistence, server: server)
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on, file: file, line: line)
        let turnedOff = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(turnedOff.state, .off, file: file, line: line)

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
    let originalSourceBeforeEnable: SnipLibraryTransferSnapshot
    let committedCandidateBeforeDiscard: CloudFullStorageSnapshot
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
        /// Only the swap fails, so the restore commits and returns to `candidateReady`.
        case swapOnly
        /// Store saves still succeed, so a full-record restore keeps the sent records' accepted
        /// bases in the source, but can't commit (SM23-F3's strand).
        case manifestOnly
        /// Store saves fail too, so the restore keeps nothing, as after a process death.
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
        if extent != .swapOnly { writer.failWrites = true }
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
