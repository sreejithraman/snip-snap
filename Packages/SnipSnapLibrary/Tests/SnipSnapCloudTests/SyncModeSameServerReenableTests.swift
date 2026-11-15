import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

/// After an aborted enable, a fresh enable runs against a server that already holds the aborted
/// attempt's records (SM23-F4). It must end with one copy of each snip: no recovered copies and no
/// extra server records. An enable is aborted either by Try Again finding its candidate's files
/// gone (SM23-F3-D3) or by Cancel setup. Every shipped build starts its enables as full-record.
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

    func testFullRecordEnableAfterCancelSetupWhenTheRestoreKeptNoBasesAddsNoDuplicateSnips()
        async throws
    {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .cancelSetupThenEnable,
            fullDisk: .manifestAndStore
        )
    }

    // (e)
    func testFullRecordEnableAfterCancelSetupKeepsOneCopyOfASnipEditedInBetween() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.cancelSetupEditThenEnable)
    }

    func testFullRecordEnableAfterCancelSetupWhenTheRestoreKeptNoBasesKeepsOneCopyOfASnipEditedInBetween()
        async throws
    {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .cancelSetupEditThenEnable,
            fullDisk: .manifestAndStore
        )
    }

    // (f)
    func testFullRecordTryAgainAfterARelaunchKeepsOneCopyOfASnipEditedInBetween() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.relaunchEditThenTryAgain)
    }

    // The SM23-F4 D3-path residual: Try Again aborts with no kept bases to merge the edit against.
    func testFullRecordTryAgainAfterARelaunchWithoutKeptBasesKeepsTheEditAsARecoveredCopy()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let enabled = try await freshEnableOnTheSameServer(
            after: .relaunchEditThenTryAgain,
            fullDisk: .manifestAndStore,
            root: root
        )

        try await assertEndedOnThroughAFreshTransition(enabled)
        let fresh = try XCTUnwrap(enabled.stranded.disk.transitionIDsAtSwap.last)
        var expected = enabled.stranded.originals
        let recoveredID = SnipLibraryTransferPlanner.derivedUUID(
            transitionID: fresh,
            sourceID: enabled.editedSnipID
        )
        expected[recoveredID] = Self.sameServerEditedText
        let active = try await enabled.persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        XCTAssertEqual(
            Dictionary(active.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first }),
            expected,
            "The original must keep the server's text and the edit a recovered copy."
        )
        let serverSnipRecords = await enabled.stranded.server
            .storedRecordTypes(in: textZone(makeNamespace()))
            .filter { $0 == "Snip" }
        XCTAssertEqual(serverSnipRecords.count, 3)
        let serverTexts = await enabled.stranded.server.storedTextValues()
        XCTAssertEqual(serverTexts, expected.values.sorted())
    }

    // SM23-F4 D3 = A: keeping the sent records' bases is best effort.
    func testCancelSetupThatCantKeepTheSentBasesStillAbortsAndRecordsTheFailure() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: .manifestAndStore
        )
        stranded.disk.freeManifest()
        let recordedBefore = stranded.probe.events.count

        try await stranded.persistence.cancelPendingICloudEnable()

        let expected: [AppDiagnosticEvent] = [
            .failure(
                operation: "sync.cancel_setup",
                error: SameServerFullDisk.Failure.injected,
                visibility: .background
            )
        ]
        XCTAssertEqual(
            Array(stranded.probe.events.dropFirst(recordedBefore)),
            expected,
            "Cancel setup must record that it couldn't keep the sent records' bases."
        )
        let storage = try await stranded.persistence.snapshot()
        XCTAssertNil(storage.transition)
        XCTAssertEqual(storage.activeStore.id, stranded.transition.sourceStoreID)
        stranded.disk.free()
        let bases = try await sourceBases(of: stranded)
        XCTAssertEqual(bases, [], "The failed promotion must leave no partial bases.")
        let kept = try await stranded.persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        XCTAssertEqual(
            Dictionary(kept.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first }),
            stranded.originals
        )
        let snipID = try XCTUnwrap(stranded.originals.keys.first)
        try await edit(snipID, to: Self.sameServerEditedText, in: stranded.persistence)
    }

    // SM23-F4-D5 = A: the bases a turn-off kept are the true common ancestor, so Cancel setup
    // must not replace them with the merged records the aborted re-enable sent.
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

    // SM23-F4-D5 = A: the same rule on the restore path. The restore commits, so Try Again
    // merges the same transition again against the bases the restore kept.
    func testFullRecordTryAgainAfterARestoreKeepsAServerChangeMadeWhileSyncWasOff() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: .swapOnly,
            history: .turnedOffThenEditedOnBothSides
        )

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

    // Cancel setup keeps the sent records' bases only for a full-record attempt whose candidate
    // still has its files (SM23-F4 F2).
    func testCancelSetupOfALegacyEnableWritesNoBasesAndRecordsNothing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: .manifestOnly,
            syncProtocol: .legacyTextV1
        )
        XCTAssertEqual(stranded.transition.syncProtocol, .legacyTextV1)
        XCTAssertNotNil(stranded.transition.sendAttempt)
        stranded.disk.free()

        try await assertCancelSetupWritesNoBasesAndRecordsNothing(stranded)
    }

    func testCancelSetupAfterARestoreClearedTheSendAttemptWritesNoBasesAndRecordsNothing()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: .swapOnly
        )
        XCTAssertEqual(stranded.transition.syncProtocol, .fullRecordV1)
        XCTAssertNil(stranded.transition.sendAttempt)
        let restored = try await sourceBases(of: stranded)
        XCTAssertFalse(restored.isEmpty, "The restore must have kept the sent records' bases.")

        try await assertCancelSetupWritesNoBasesAndRecordsNothing(stranded)
    }

    func testCancelSetupWithACandidateWhoseFilesAreGoneWritesNoBasesAndRecordsNothing()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: .manifestOnly
        )
        XCTAssertEqual(stranded.transition.syncProtocol, .fullRecordV1)
        XCTAssertNotNil(stranded.transition.sendAttempt)
        try await removeCandidateFiles(of: stranded)
        stranded.disk.free()

        try await assertCancelSetupWritesNoBasesAndRecordsNothing(stranded)
        XCTAssertEqual(
            stranded.probe.count(.failure(
                operation: "sync.cancel_setup",
                error: SyncModePersistenceError.missingStore,
                visibility: .background
            )),
            0,
            "Cancel setup must not open a candidate whose files are gone."
        )
    }

    func testCancelSetupWhoseAbortCantCommitThrowsAndKeepsTheSentBasesAndTheTransition()
        async throws
    {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            fullDisk: .manifestAndStore
        )
        stranded.disk.freeStore()
        let recordedBefore = stranded.probe.events.count

        do {
            try await stranded.persistence.cancelPendingICloudEnable()
            XCTFail("Cancel setup can't commit its abort while manifest writes fail.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
        }

        XCTAssertEqual(Array(stranded.probe.events.dropFirst(recordedBefore)), [])
        let storage = try await stranded.persistence.snapshot()
        XCTAssertEqual(storage.transition?.id, stranded.transition.id)
        XCTAssertEqual(storage.activeStore.id, stranded.transition.sourceStoreID)
        let bases = try await sourceBases(of: stranded)
        var sent = Set(stranded.originals.keys.map {
            CloudEntityReference(kind: .snip, domainID: $0)
        })
        sent.insert(CloudEntityReference(kind: .list, domainID: SnipList.inboxID))
        XCTAssertEqual(
            Set(bases.map(\.reference)),
            sent,
            "The promotion before the failed abort must keep the sent records' bases."
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

    /// Cancels `stranded`'s enable, and checks that it aborts without changing the source's
    /// dormant bases or recording a diagnostic.
    private func assertCancelSetupWritesNoBasesAndRecordsNothing(
        _ stranded: SameServerStrandedEnable,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let before = try await sourceBases(of: stranded)
        let recordedBefore = stranded.probe.events.count

        try await stranded.persistence.cancelPendingICloudEnable()

        let storage = try await stranded.persistence.snapshot()
        XCTAssertNil(storage.transition, file: file, line: line)
        XCTAssertEqual(
            storage.activeStore.id,
            stranded.transition.sourceStoreID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            Array(stranded.probe.events.dropFirst(recordedBefore)),
            [],
            "Cancel setup must record nothing here.",
            file: file,
            line: line
        )
        let after = try await sourceBases(of: stranded)
        XCTAssertEqual(after, before, "Cancel setup must not write bases here.", file: file, line: line)
    }

    private func sourceBases(of stranded: SameServerStrandedEnable) async throws -> [CloudDormantBase] {
        try await stranded.persistence.libraryForTransition(storeID: stranded.transition.sourceStoreID)
            .dormantCloudBases()
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

    /// Adds the snips, applies `history`, and runs an enable until its first send reached
    /// `server`. Then it fails the pointer swap as `fullDisk` says. On a full disk, the enable
    /// stays at `firstSendComplete` with the source frozen, and the disk stays full.
    private func strandAnEnableThatReachedTheServer(
        root: URL,
        fullDisk: SameServerFullDisk.Extent,
        syncProtocol: SyncModeSyncProtocol = .fullRecordV1,
        history: SameServerHistory = .localOnly,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> SameServerStrandedEnable {
        let disk = SameServerFullDisk(root: root, extent: fullDisk)
        let probe = StoreOpenDiagnosticProbe()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: syncProtocol,
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
/// `Extent` names, like a disk that fills mid-change. `free()` frees the disk, `freeManifest()`
/// only its manifest writes, and `freeStore()` only its store saves. From the armed swap on, it
/// also notes which stored transition each pointer swap was about to activate.
private final class SameServerFullDisk: @unchecked Sendable {
    enum Failure: Error { case injected }

    enum Extent {
        /// Only the swap fails. The restore keeps the sent records' accepted bases in the source
        /// and commits, so the enable goes back to `candidateReady` for Try Again.
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
        freeManifest()
        freeStore()
    }

    func freeManifest() {
        writer.failWrites = false
    }

    func freeStore() {
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
