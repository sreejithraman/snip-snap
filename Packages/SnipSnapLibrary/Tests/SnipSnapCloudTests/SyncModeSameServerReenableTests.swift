import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

/// After an aborted enable, a fresh enable runs against a server that already holds the aborted
/// attempt's records (SM23-F4). It must end with one copy of each snip: no recovered copies and no
/// extra server records. An enable is aborted either by Try Again finding its candidate's files
/// gone (SM23-F3-D3) or by Cancel setup.
extension ICloudSyncModeCoordinatorTests {
    // (a)
    func testLegacyTextTryAgainWithAMissingCandidateAddsNoDuplicateSnips() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.tryAgain, syncProtocol: .legacyTextV1)
    }

    // (b)
    func testFullRecordTryAgainWithAMissingCandidateAddsNoDuplicateSnips() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(.tryAgain, syncProtocol: .fullRecordV1)
    }

    func testFullRecordTryAgainWithAMissingCandidateWithoutKeptBasesAddsNoDuplicateSnips()
        async throws
    {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .tryAgain,
            syncProtocol: .fullRecordV1,
            fullDisk: .manifestAndStore
        )
    }

    // (c)
    func testLegacyTextEnableAfterCancelSetupAddsNoDuplicateSnips() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .cancelSetupThenEnable,
            syncProtocol: .legacyTextV1
        )
    }

    // (d)
    func testFullRecordEnableAfterCancelSetupAddsNoDuplicateSnips() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .cancelSetupThenEnable,
            syncProtocol: .fullRecordV1
        )
    }

    func testFullRecordEnableAfterCancelSetupWithoutKeptBasesAddsNoDuplicateSnips() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .cancelSetupThenEnable,
            syncProtocol: .fullRecordV1,
            fullDisk: .manifestAndStore
        )
    }

    // (e)
    func testLegacyTextEnableAfterCancelSetupKeepsOneCopyOfASnipEditedInBetween() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .cancelSetupEditThenEnable,
            syncProtocol: .legacyTextV1
        )
    }

    func testFullRecordEnableAfterCancelSetupKeepsOneCopyOfASnipEditedInBetween() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .cancelSetupEditThenEnable,
            syncProtocol: .fullRecordV1
        )
    }

    func testFullRecordEnableAfterCancelSetupWithoutKeptBasesKeepsOneCopyOfASnipEditedInBetween()
        async throws
    {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .cancelSetupEditThenEnable,
            syncProtocol: .fullRecordV1,
            fullDisk: .manifestAndStore
        )
    }

    // (f)
    func testLegacyTextTryAgainAfterARelaunchKeepsOneCopyOfASnipEditedInBetween() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .relaunchEditThenTryAgain,
            syncProtocol: .legacyTextV1
        )
    }

    func testFullRecordTryAgainAfterARelaunchKeepsOneCopyOfASnipEditedInBetween() async throws {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .relaunchEditThenTryAgain,
            syncProtocol: .fullRecordV1
        )
    }

    func testFullRecordTryAgainAfterARelaunchWithoutKeptBasesKeepsOneCopyOfASnipEditedInBetween()
        async throws
    {
        try await assertFreshEnableKeepsOneCopyOfEachSnip(
            .relaunchEditThenTryAgain,
            syncProtocol: .fullRecordV1,
            fullDisk: .manifestAndStore
        )
    }

    private static let sameServerTexts = ["kept", "also kept"]
    private static let sameServerEditedText = "kept, edited before the fresh enable"

    /// Strands an enable whose first send reached the server, aborts it by `retry`, and runs the
    /// fresh enable on the same server. Checks that it ends On with exactly the original snips,
    /// by ID and content, no recovered copies, and no extra server records. An edit, where
    /// `retry` makes one, must land on the original snip.
    private func assertFreshEnableKeepsOneCopyOfEachSnip(
        _ retry: SameServerRetry,
        syncProtocol: SyncModeSyncProtocol,
        fullDisk: SameServerFullDisk.Extent = .manifestOnly,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strandAnEnableThatReachedTheServer(
            root: root,
            syncProtocol: syncProtocol,
            fullDisk: fullDisk,
            file: file,
            line: line
        )
        let editedSnip = try XCTUnwrap(
            stranded.originals.first(where: { $0.content == Self.sameServerTexts[0] }),
            file: file,
            line: line
        )
        var expected = Dictionary(uniqueKeysWithValues: stranded.originals.map {
            ($0.id, $0.content)
        })

        let status: ICloudSyncModeStatus
        let persistence: SwiftDataSyncModePersistence
        switch retry {
        case .tryAgain:
            try await removeCandidateFiles(of: stranded)
            stranded.disk.free()
            persistence = stranded.persistence
            status = try await stranded.coordinator.enableOrRetry()
        case .relaunchEditThenTryAgain:
            stranded.disk.free()
            do {
                try await edit(
                    editedSnip.id,
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
            persistence = try SwiftDataSyncModePersistence(
                rootURL: root,
                defaultSyncProtocol: syncProtocol,
                crashHook: stranded.disk.hit,
                diagnostics: stranded.probe.recorder
            )
            let reopened = try await persistence.snapshot()
            XCTAssertEqual(reopened.transition?.phase, .candidateReady, file: file, line: line)
            try await edit(editedSnip.id, to: Self.sameServerEditedText, in: persistence)
            expected[editedSnip.id] = Self.sameServerEditedText
            status = try await sameServerCoordinator(on: persistence, server: stranded.server)
                .enableOrRetry()
        case .cancelSetupThenEnable, .cancelSetupEditThenEnable:
            stranded.disk.free()
            try await stranded.persistence.cancelPendingICloudEnable()
            let cancelled = try await stranded.persistence.snapshot()
            XCTAssertNil(cancelled.transition, file: file, line: line)
            if retry == .cancelSetupEditThenEnable {
                try await edit(
                    editedSnip.id,
                    to: Self.sameServerEditedText,
                    in: stranded.persistence
                )
                expected[editedSnip.id] = Self.sameServerEditedText
            }
            persistence = stranded.persistence
            status = try await stranded.coordinator.enableOrRetry()
        }

        XCTAssertEqual(status.state, .on, file: file, line: line)
        let storage = try await persistence.snapshot()
        XCTAssertNil(storage.transition, file: file, line: line)
        XCTAssertEqual(storage.activeStore.kind, .iCloudSync, file: file, line: line)
        XCTAssertEqual(
            stranded.probe.count(.missing(operation: "sync.setup")),
            retry.abortsAMissingCandidate ? 1 : 0,
            "Only Try Again with the candidate's files gone aborts through SM23-F3-D3.",
            file: file,
            line: line
        )
        let swapped = stranded.disk.transitionIDsAtSwap
        XCTAssertEqual(swapped.count, 2, file: file, line: line)
        XCTAssertEqual(swapped.first, stranded.transition.id, file: file, line: line)
        let fresh = try XCTUnwrap(swapped.last, file: file, line: line)
        XCTAssertNotEqual(
            fresh,
            stranded.transition.id,
            "The fresh enable must swap in a new transition.",
            file: file,
            line: line
        )

        let active = try await persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        let recoveredIDs = Set(stranded.originals.flatMap { original in
            [stranded.transition.id, fresh].map {
                SnipLibraryTransferPlanner.derivedUUID(transitionID: $0, sourceID: original.id)
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
        let serverSnipRecords = await stranded.server
            .storedRecordTypes(in: textZone(makeNamespace()))
            .filter { $0 == "Snip" }
        XCTAssertEqual(
            serverSnipRecords.count,
            expected.count,
            "The server must hold one snip record per snip.",
            file: file,
            line: line
        )
        let serverTexts = await stranded.server.storedTextValues()
        XCTAssertEqual(serverTexts, expected.values.sorted(), file: file, line: line)
    }

    /// Adds the snips and runs an enable until its first send reached `server`, then fails its
    /// pointer swap on a full disk, so it stays at `firstSendComplete` with the source frozen.
    /// The disk stays full.
    private func strandAnEnableThatReachedTheServer(
        root: URL,
        syncProtocol: SyncModeSyncProtocol,
        fullDisk: SameServerFullDisk.Extent,
        file: StaticString,
        line: UInt
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
        let originals = try await persistence.activeLibrary()
            .checkedSnapshot(sortedBy: .manual).snips
        let server = FakeCloudServer()
        let coordinator = sameServerCoordinator(on: persistence, server: server)
        disk.armAtPointerSwap()
        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("The injected failure must end the enable.", file: file, line: line)
        } catch SameServerFullDisk.Failure.injected {}
        let stuck = try await persistence.snapshot()
        let transition = try XCTUnwrap(stuck.transition, file: file, line: line)
        XCTAssertEqual(transition.phase, .firstSendComplete, file: file, line: line)
        let sent = await server.storedTextValues()
        XCTAssertEqual(
            sent,
            Self.sameServerTexts.sorted(),
            "The aborted enable must reach the server.",
            file: file,
            line: line
        )
        return SameServerStrandedEnable(
            persistence: persistence,
            coordinator: coordinator,
            server: server,
            disk: disk,
            probe: probe,
            transition: transition,
            originals: originals
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

private struct SameServerStrandedEnable {
    let persistence: SwiftDataSyncModePersistence
    let coordinator: ICloudSyncModeCoordinator
    let server: FakeCloudServer
    let disk: SameServerFullDisk
    let probe: StoreOpenDiagnosticProbe
    let transition: SyncModeTransition
    let originals: [Snip]
}

/// Fails the first pointer swap and, from then on, every manifest write, like a disk that fills
/// mid-change. `free()` frees the disk. It also notes which stored transition each pointer swap
/// was about to activate.
private final class SameServerFullDisk: @unchecked Sendable {
    enum Failure: Error { case injected }

    enum Extent {
        /// Store saves still succeed, so a full-record restore keeps the sent records' accepted
        /// bases in the source (SM23-F3's strand).
        case manifestOnly
        /// Store saves fail too, so the restore keeps nothing, as after a process death.
        case manifestAndStore
    }

    let writer = FailingManifestWriter()
    private let extent: Extent
    private let manifestURL: URL
    private let lock = NSLock()
    private var isArmed = false
    private var storeIsFull = false
    private var swapTransitionIDs: [UUID] = []

    init(root: URL, extent: Extent) {
        self.extent = extent
        manifestURL = root.appendingPathComponent("activation.json", isDirectory: false)
    }

    var transitionIDsAtSwap: [UUID] { lock.withLock { swapTransitionIDs } }

    func armAtPointerSwap() {
        lock.withLock { isArmed = true }
    }

    func free() {
        writer.failWrites = false
        lock.withLock { storeIsFull = false }
    }

    func hit(_ point: SyncModeCrashPoint) throws {
        guard point == .beforePointerSwap else { return }
        let transitionID = storedTransitionID()
        let fills = lock.withLock { () -> Bool in
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
