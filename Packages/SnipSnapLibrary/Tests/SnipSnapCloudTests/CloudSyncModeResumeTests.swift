import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

/// A failed rollback can leave a transition stage that only reopen clears (SM23-L1, SM23-L2).
/// Try Again finishes only a rollback this process couldn't commit, not work in flight (SM23-F1).
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
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pause = FrozenSourceReadPause()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1,
            readHook: { await pause.read(sourceFrozen: storedSourceIsFrozen(under: root)) }
        )
        try await add("kept", to: persistence.activeLibrary())
        let server = FakeCloudServer()
        // Two coordinators on one persistence, with no shared gate between them.
        let inFlight = modeCoordinator(on: persistence, server: server)
        let tryAgain = modeCoordinator(on: persistence, server: server)
        let firstEnable = Task {
            do {
                let status = try await inFlight.enableOrRetry()
                await pause.heldWorkFinished()
                return status
            } catch {
                await pause.heldWorkFinished()
                throw error
            }
        }
        await pause.waitUntilPaused()
        guard await pause.hasPaused else {
            _ = try await firstEnable.value
            XCTFail("The enable finished without reaching its final snapshot read.")
            return
        }
        let held = try? await persistence.snapshot()

        let retried = await Task { try await tryAgain.enableOrRetry() }.result
        let afterRetry = try? await persistence.snapshot()
        await pause.resume()

        XCTAssertEqual(held?.transition?.phase, .sourceFrozen)
        XCTAssertNotNil(held?.transition?.freezeToken)
        // Before the SM23-F1 fix, these fail: Try Again unfreezes the enable in flight and
        // starts its own merge.
        XCTAssertEqual(try retried.get().state, .settingUp)
        XCTAssertEqual(afterRetry?.transition, held?.transition)
        let enabled = try await firstEnable.value
        XCTAssertEqual(enabled.state, .on)
        try await assertModeChangeFinished(persistence, on: .iCloudSync)
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

/// Holds the first library read made while the source is frozen, which is the final snapshot
/// read, until `resume()`.
private actor FrozenSourceReadPause {
    private(set) var hasPaused = false
    private var heldWorkIsDone = false
    private var isResumed = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func read(sourceFrozen: Bool) async {
        guard sourceFrozen, !hasPaused else { return }
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
