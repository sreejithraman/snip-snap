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

    /// Runs the fresh enable `retry` names on a disk where the restore keeps no bases, and checks
    /// that it ends On through a new transition. The edited snip's original ID keeps the server's
    /// text, and the edit lands in a recovered copy that the fresh transition derives, locally and
    /// on the server.
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
/// `Extent` names, like a disk that fills mid-change. `free()` frees the disk. From the armed
/// swap on, it also notes which stored transition each pointer swap was about to activate.
private final class SameServerFullDisk: @unchecked Sendable {
    enum Failure: Error { case injected }

    enum Extent {
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
