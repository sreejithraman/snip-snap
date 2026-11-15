import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

/// A failed rollback can leave a transition stage that only reopen clears (SM23-L1, SM23-L2).
/// Try Again finishes only a rollback this process couldn't commit, not work in flight (SM23-F1).
/// Nor does it replay a full re-enable merge that this process is applying (SM23-F2).
extension ICloudSyncModeCoordinatorTests {
    func testEnableTryAgainUnfreezesASourceLeftFrozenByAFailedRestore() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strand(.enable, after: .finalSnapshotRead, root: root)
        let stuck = try await stranded.persistence.snapshot()
        XCTAssertEqual(stuck.transition?.phase, .sourceFrozen)
        do {
            try await add("refused", to: stranded.persistence.activeLibrary())
            XCTFail("A frozen source must refuse library writes.")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .modeTransitionInProgress)
        }

        let retried = try await stranded.coordinator.enableOrRetry()

        // Before the SM23-L1 fix, this fails: Try Again returns settingUp and the source stays
        // frozen.
        XCTAssertEqual(retried.state, .on)
        try await assertModeChangeFinished(stranded.persistence, on: .iCloudSync)
    }

    func testOptOutTryAgainUnfreezesASourceLeftFrozenByAFailedRestore() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strand(.optOut, after: .finalSnapshotRead, root: root)
        let stuck = try await stranded.persistence.snapshot()
        XCTAssertEqual(stuck.transition?.phase, .sourceFrozen)
        do {
            try await add("refused", to: stranded.persistence.activeLibrary())
            XCTFail("A frozen source must refuse library writes.")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .modeTransitionInProgress)
        }
        try await assertSyncWaits(for: stranded)

        let retried = try await stranded.coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)

        // Before the SM23-L1 fix, this fails: Try Again returns syncing and the source stays
        // frozen.
        XCTAssertEqual(retried.state, .off)
        try await assertModeChangeFinished(stranded.persistence, on: .localOnly)
    }

    func testEnableTryAgainReplacesACandidateLeftDeclaredByAFailedAbort() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strand(.enable, after: .candidateCreation, root: root)
        let stuck = try await stranded.persistence.snapshot()
        XCTAssertEqual(stuck.transition?.phase, .candidateDeclared)

        // Before the SM23-L2 fix, this throws missingStore: the adapter can't open a candidate
        // store that never left `.creating`.
        let retried = try await stranded.coordinator.enableOrRetry()

        XCTAssertEqual(retried.state, .on)
        try await assertModeChangeFinished(stranded.persistence, on: .iCloudSync)
    }

    func testOptOutTryAgainReplacesACandidateLeftDeclaredByAFailedAbort() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stranded = try await strand(.optOut, after: .candidateCreation, root: root)
        let stuck = try await stranded.persistence.snapshot()
        XCTAssertEqual(stuck.transition?.phase, .candidateDeclared)
        try await assertSyncWaits(for: stranded)

        let retried = try await stranded.coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)

        // Before the SM23-L2 fix, this fails: Try Again returns syncing and the candidate stays
        // declared.
        XCTAssertEqual(retried.state, .off)
        try await assertModeChangeFinished(stranded.persistence, on: .localOnly)
    }

    func testReopenUnfreezesASourceLeftFrozenByAFailedRestore() async throws {
        for change in [StrandedChange.enable, .optOut] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let stranded = try await strand(change, after: .finalSnapshotRead, root: root)

            let reopened = try SwiftDataSyncModePersistence(
                rootURL: root,
                defaultSyncProtocol: .legacyTextV1
            )

            let recovered = try await reopened.snapshot()
            XCTAssertEqual(recovered.transition?.phase, .candidateReady, "\(change)")
            try await add("after reopen", to: reopened.activeLibrary())
            let retried = try await retry(change, on: reopened, like: stranded)
            let finished: ICloudSyncModeState = change == .enable ? .on : .off
            XCTAssertEqual(retried.state, finished, "\(change)")
            try await assertModeChangeFinished(
                reopened,
                on: change == .enable ? .iCloudSync : .localOnly,
                holding: ["after reopen", "kept"]
            )
        }
    }

    func testReopenDropsACandidateLeftDeclaredByAFailedAbort() async throws {
        for change in [StrandedChange.enable, .optOut] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let stranded = try await strand(change, after: .candidateCreation, root: root)

            let reopened = try SwiftDataSyncModePersistence(
                rootURL: root,
                defaultSyncProtocol: .legacyTextV1
            )

            let recovered = try await reopened.snapshot()
            XCTAssertNil(recovered.transition, "\(change)")
            let retried = try await retry(change, on: reopened, like: stranded)
            let finished: ICloudSyncModeState = change == .enable ? .on : .off
            XCTAssertEqual(retried.state, finished, "\(change)")
            try await assertModeChangeFinished(
                reopened,
                on: change == .enable ? .iCloudSync : .localOnly
            )
        }
    }

    func testEnableTryAgainDoesNotUnfreezeAnEnableInFlight() async throws {
        try await assertTryAgainLeavesTheFreezeInFlight(for: .enable)
    }

    func testOptOutTryAgainDoesNotUnfreezeAnOptOutInFlight() async throws {
        try await assertTryAgainLeavesTheFreezeInFlight(for: .optOut)
    }

    func testEnableTryAgainDoesNotReplayAFullMergeInFlight() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pause = HeldStepPause()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .fullRecordV1,
            writeHook: { await pause.arrive(atHeldStep: $0 == .beforeFullReenablePlanApply) }
        )
        let server = FakeCloudServer()
        let texts = try await optOutAfterSyncing(persistence, server: server)

        // Before the SM23-F2 fix, Try Again takes the live intent for a leftover one: it replays
        // the staged plan and finishes the enable, so the held merge can't finish.
        try await assertTryAgainLeavesTheFullMergeInFlight(
            on: persistence,
            heldBy: pause,
            server: server,
            holding: texts
        )
    }

    func testEnableTryAgainDoesNotReplayAFullMergeAnotherTryAgainResumed() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeCloudServer()
        let initial = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .fullRecordV1
        )
        let texts = try await optOutAfterSyncing(initial, server: server)
        let crash = CrashInjector(point: .beforeCandidateMergeDurability)
        let crashing = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .fullRecordV1,
            crashHook: crash.hit
        )
        do {
            _ = try await modeCoordinator(on: crashing, server: server).enableOrRetry()
            XCTFail("The injected crash must end the enable.")
        } catch CrashInjector.Failure.injected {}
        let pause = HeldStepPause()
        let reopened = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .fullRecordV1,
            writeHook: { await pause.arrive(atHeldStep: $0 == .beforeFullReenablePlanApply) }
        )

        // Before the SM23-F2 fix, both Try Agains reconcile the durable intent: the second
        // replays the staged plan and finishes the enable, so the first can't finish its merge.
        try await assertTryAgainLeavesTheFullMergeInFlight(
            on: reopened,
            heldBy: pause,
            server: server,
            holding: texts
        )
    }

    func testFailedCancelSetupKeepsTheLibraryForTheNextEnable() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = DiskFullInjector()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1,
            crashHook: disk.hit,
            manifestWriter: disk.writer.write
        )
        try await add("kept", to: persistence.activeLibrary())
        try await add("also kept", to: persistence.activeLibrary())
        let coordinator = modeCoordinator(on: persistence, server: FakeCloudServer())
        disk.arm(at: .beforePointerSwap)
        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("The injected failure must end the enable.")
        } catch DiskFullInjector.Failure.injected {}
        let stuck = try await persistence.snapshot()
        XCTAssertEqual(stuck.transition?.phase, .firstSendComplete)

        do {
            try await persistence.cancelPendingICloudEnable()
            XCTFail("Cancel setup can't commit while the disk is full.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
        }
        disk.writer.failWrites = false

        let enabled = try await coordinator.enableOrRetry()

        // Before the SM23-F1 A1 fix, these fail: the failed cancel deleted the candidate's files,
        // so this enable reopens the candidate empty and swaps it in.
        XCTAssertEqual(enabled.state, .on)
        try await assertModeChangeFinished(
            persistence,
            on: .iCloudSync,
            holding: ["kept", "also kept"]
        )
    }

    /// Holds `change` at its final snapshot read, with the source frozen, while a second
    /// coordinator on the same persistence tries the same change. No gate is shared.
    private func assertTryAgainLeavesTheFreezeInFlight(
        for change: StrandedChange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pause = HeldStepPause()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1,
            // The first read made while the source is frozen is the final snapshot read.
            readHook: { await pause.arrive(atHeldStep: storedSourceIsFrozen(under: root)) }
        )
        try await add("kept", to: persistence.activeLibrary())
        let server = FakeCloudServer()
        let inFlight = modeCoordinator(on: persistence, server: server)
        let tryAgain = modeCoordinator(on: persistence, server: server)
        if change == .optOut {
            let enabled = try await inFlight.enableOrRetry()
            XCTAssertEqual(enabled.state, .on, file: file, line: line)
        }

        // Before the SM23-F1 fix, Try Again unfreezes the change in flight and starts its own
        // merge.
        let held = try await assertTryAgainWaits(
            for: change,
            heldBy: pause,
            inFlight: inFlight,
            tryAgain: tryAgain,
            on: persistence,
            file: file,
            line: line
        )

        XCTAssertEqual(held?.transition?.phase, .sourceFrozen, file: file, line: line)
        XCTAssertNotNil(held?.transition?.freezeToken, file: file, line: line)
    }

    /// Holds a full re-enable just before it applies its staged plan, with its merge intent
    /// durable, while a second coordinator on the same persistence tries the enable again.
    private func assertTryAgainLeavesTheFullMergeInFlight(
        on persistence: SwiftDataSyncModePersistence,
        heldBy pause: HeldStepPause,
        server: FakeCloudServer,
        holding texts: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let held = try await assertTryAgainWaits(
            for: .enable,
            heldBy: pause,
            inFlight: modeCoordinator(on: persistence, server: server),
            tryAgain: modeCoordinator(on: persistence, server: server),
            on: persistence,
            holding: texts,
            file: file,
            line: line
        )

        let transition = held?.transition
        XCTAssertEqual(transition?.phase, .sourceFrozen, file: file, line: line)
        XCTAssertNotNil(transition?.mergeIntent, file: file, line: line)
        XCTAssertEqual(
            transition?.mergeIntent?.fullReenablePlanID,
            transition?.id,
            file: file,
            line: line
        )
    }

    /// Holds `inFlight`'s `change` at the step `pause` holds, while `tryAgain` tries the same
    /// change on the same persistence. No gate is shared. Try Again must wait and leave the
    /// stored transition as it is. The held change must then finish holding exactly `texts`.
    /// Returns the storage seen while the change was held.
    private func assertTryAgainWaits(
        for change: StrandedChange,
        heldBy pause: HeldStepPause,
        inFlight: ICloudSyncModeCoordinator,
        tryAgain: ICloudSyncModeCoordinator,
        on persistence: SwiftDataSyncModePersistence,
        holding texts: [String] = ["kept"],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> SyncModeStorageSnapshot? {
        await pause.arm()
        let first = Task {
            do {
                let status = try await requestModeChange(change, on: inFlight)
                await pause.heldWorkFinished()
                return status
            } catch {
                await pause.heldWorkFinished()
                throw error
            }
        }
        await pause.waitUntilPaused()
        guard await pause.hasPaused else {
            _ = try await first.value
            XCTFail("\(change) finished without reaching its held step.", file: file, line: line)
            return nil
        }
        let held = try? await persistence.snapshot()

        let retried = await Task { try await requestModeChange(change, on: tryAgain) }.result
        let afterRetry = try? await persistence.snapshot()
        await pause.resume()

        let waiting: ICloudSyncModeState = change == .enable ? .settingUp : .syncing
        XCTAssertEqual(try retried.get().state, waiting, file: file, line: line)
        XCTAssertEqual(afterRetry?.transition, held?.transition, file: file, line: line)
        let finished = await first.result
        let done: ICloudSyncModeState = change == .enable ? .on : .off
        XCTAssertEqual(try finished.get().state, done, file: file, line: line)
        try await assertModeChangeFinished(
            persistence,
            on: change == .enable ? .iCloudSync : .localOnly,
            holding: texts,
            file: file,
            line: line
        )
        return held
    }

    /// Syncs a snip, opts out, and adds a snip while off, so the next enable is a full
    /// re-enable that applies a staged plan. Returns the texts that enable must end holding.
    private func optOutAfterSyncing(
        _ persistence: SwiftDataSyncModePersistence,
        server: FakeCloudServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String] {
        try await add("kept", to: persistence.activeLibrary())
        let coordinator = modeCoordinator(on: persistence, server: server)
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on, file: file, line: line)
        let optedOut = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(optedOut.state, .off, file: file, line: line)
        try await add("added while off", to: persistence.activeLibrary())
        return ["kept", "added while off"]
    }

    /// Runs `change` until `failure` strands its transition, then frees the disk. The failure
    /// also fails every manifest write after it, so the rollback can't commit either.
    private func strand(
        _ change: StrandedChange,
        after failure: StrandingFailure,
        root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> StrandedTransition {
        let disk = DiskFullInjector()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1,
            crashHook: disk.hit,
            manifestWriter: disk.writer.write,
            readHook: disk.failRead
        )
        try await add("kept", to: persistence.activeLibrary())
        let server = FakeCloudServer()
        let coordinator = modeCoordinator(on: persistence, server: server)
        if change == .optOut {
            let enabled = try await coordinator.enableOrRetry()
            XCTAssertEqual(enabled.state, .on, file: file, line: line)
        }
        switch failure {
        case .finalSnapshotRead: disk.armRead()
        case .candidateCreation: disk.arm(at: .beforeCandidateDurability)
        }
        do {
            switch change {
            case .enable:
                _ = try await coordinator.enableOrRetry()
            case .optOut:
                _ = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
            }
            XCTFail("The injected failure must end the mode change.", file: file, line: line)
        } catch DiskFullInjector.Failure.injected {}
        disk.writer.failWrites = false
        return StrandedTransition(
            persistence: persistence,
            coordinator: coordinator,
            server: server
        )
    }

    /// Retries `change` with a fresh coordinator on `persistence`, as a relaunch would.
    private func retry(
        _ change: StrandedChange,
        on persistence: SwiftDataSyncModePersistence,
        like stranded: StrandedTransition
    ) async throws -> ICloudSyncModeStatus {
        let coordinator = modeCoordinator(on: persistence, server: stranded.server)
        switch change {
        case .enable:
            return try await coordinator.enableOrRetry()
        case .optOut:
            return try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        }
    }

    private func modeCoordinator(
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

    /// iCloud sync of the active store waits while an opt-out holds its transition.
    private func assertSyncWaits(
        for stranded: StrandedTransition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await stranded.coordinator.syncActive()
            XCTFail("iCloud sync must wait for the opt-out.", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SyncModePersistenceError,
                .transitionInProgress,
                file: file,
                line: line
            )
        }
    }

    /// Checks that the mode change ended on a `kind` store holding exactly `texts`.
    private func assertModeChangeFinished(
        _ persistence: SwiftDataSyncModePersistence,
        on kind: SyncModeStoreKind,
        holding texts: [String] = ["kept"],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let storage = try await persistence.snapshot()
        XCTAssertNil(storage.transition, file: file, line: line)
        XCTAssertEqual(storage.activeStore.kind, kind, file: file, line: line)
        let library = try await persistence.activeLibrary()
        let stored = try await library.checkedSnapshot(sortedBy: .chronological).snips
        XCTAssertEqual(stored.map(\.content).sorted(), texts.sorted(), file: file, line: line)
    }
}

private enum StrandedChange { case enable, optOut }

private enum StrandingFailure {
    /// The final snapshot read fails after the source froze, so the restore must unfreeze it.
    case finalSnapshotRead
    /// Creating the candidate store fails after its declaration, so the abort must remove it.
    case candidateCreation
}

private struct StrandedTransition {
    let persistence: SwiftDataSyncModePersistence
    let coordinator: ICloudSyncModeCoordinator
    let server: FakeCloudServer
}

private func requestModeChange(
    _ change: StrandedChange,
    on coordinator: ICloudSyncModeCoordinator
) async throws -> ICloudSyncModeStatus {
    switch change {
    case .enable:
        return try await coordinator.enableOrRetry()
    case .optOut:
        return try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
    }
}

/// Once armed, holds the first arrival at the held step until `resume()`. Later arrivals pass,
/// so a second change never waits on it.
private actor HeldStepPause {
    private(set) var hasPaused = false
    private var isArmed = false
    private var heldWorkIsDone = false
    private var isResumed = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func arm() {
        isArmed = true
    }

    func arrive(atHeldStep isHeldStep: Bool) async {
        guard isArmed, isHeldStep, !hasPaused else { return }
        hasPaused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters = []
        guard !isResumed else { return }
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilPaused() async {
        if hasPaused || heldWorkIsDone { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    /// Ends `waitUntilPaused()` for work that finished without reaching the read.
    func heldWorkFinished() {
        heldWorkIsDone = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters = []
    }

    func resume() {
        isResumed = true
        release?.resume()
        release = nil
    }
}

private func storedSourceIsFrozen(under root: URL) -> Bool {
    let manifestURL = root.appendingPathComponent("activation.json", isDirectory: false)
    let manifest = try? JSONDecoder().decode(
        SwiftDataSyncModePersistence.Manifest.self,
        from: Data(contentsOf: manifestURL)
    )
    return manifest?.transition?.phase == .sourceFrozen
}

/// Fails one step of a mode change and, from then on, every manifest write, like a disk that
/// fills mid-change. Setting `writer.failWrites` to false frees the disk.
private final class DiskFullInjector: @unchecked Sendable {
    enum Failure: Error { case injected }

    let writer = FailingManifestWriter()
    private let lock = NSLock()
    private var armedPoint: SyncModeCrashPoint?
    private var readArmed = false

    func arm(at point: SyncModeCrashPoint) {
        lock.withLock { armedPoint = point }
    }

    func armRead() {
        lock.withLock { readArmed = true }
    }

    func hit(_ point: SyncModeCrashPoint) throws {
        let fails = lock.withLock { () -> Bool in
            guard armedPoint == point else { return false }
            armedPoint = nil
            return true
        }
        if fails { try fillDisk() }
    }

    func failRead() throws {
        let fails = lock.withLock { () -> Bool in
            defer { readArmed = false }
            return readArmed
        }
        if fails { try fillDisk() }
    }

    private func fillDisk() throws {
        writer.failWrites = true
        throw Failure.injected
    }
}
