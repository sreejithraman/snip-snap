import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

/// A failed rollback can leave a transition stage that only reopen clears (SM23-L1, SM23-L2).
/// Mode operations run one at a time, so Try Again finds such a stage only as a leftover.
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
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
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
            namespace: namespace,
            server: server
        )
    }

    /// Retries `change` with a fresh coordinator on `persistence`, as a relaunch would.
    private func retry(
        _ change: StrandedChange,
        on persistence: SwiftDataSyncModePersistence,
        like stranded: StrandedTransition
    ) async throws -> ICloudSyncModeStatus {
        let namespace = stranded.namespace
        let server = stranded.server
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        switch change {
        case .enable:
            return try await coordinator.enableOrRetry()
        case .optOut:
            return try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        }
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
    let namespace: CloudSyncNamespace
    let server: FakeCloudServer
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
