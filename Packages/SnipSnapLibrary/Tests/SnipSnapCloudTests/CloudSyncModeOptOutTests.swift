import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testOfflineOptOutCopiesCurrentCacheOnlyAfterExplicitStaleChoiceAndNeverDeletesCloud() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        try await add("cached", to: persistence.activeLibrary())
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        try await publishActiveStore(
            persistence: persistence, namespace: namespace, textZone: textZone(namespace),
            transport: transport
        )
        let cloudStoreID = try await persistence.snapshot().activeStore.id
        let callsBefore = await transport.events()

        let canceled = try await coordinator.optOut(.cancel)
        let afterCancel = try await persistence.snapshot()
        let optedOut = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        let deletionCount = await server.acceptedDeletionCount()
        let cloudTexts = await server.storedTextValues()
        let callsAfter = await transport.events()
        XCTAssertEqual(canceled.state, .on)
        XCTAssertEqual(afterCancel.activeStore.id, cloudStoreID)
        XCTAssertEqual(optedOut.state, .off)
        XCTAssertEqual(deletionCount, 0)
        XCTAssertEqual(cloudTexts, ["cached"])
        XCTAssertEqual(callsAfter, callsBefore)
        let active = try await persistence.activeLibrary()
        let copiedTexts = await active.snapshot(sortedBy: .chronological).snips.map(\.content)
        XCTAssertEqual(copiedTexts, ["cached"])
    }

    func testFailureBeforePointerSwapKeepsSourceAndFailureAfterSwapKeepsCloudActive() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let injector = CrashInjector(point: .beforePointerSwap)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, crashHook: injector.hit)
        try await add("durable", to: persistence.activeLibrary())
        let originalID = try await persistence.snapshot().activeStore.id
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("Expected the injected crash.")
        } catch CrashInjector.Failure.injected {}
        let crashed = try await persistence.snapshot()
        let sentBeforeSwap = await server.storedTextValues()
        XCTAssertEqual(crashed.activeStore.id, originalID)
        XCTAssertNil(crashed.transition)
        XCTAssertEqual(try storeRootCount(in: root), 1)
        XCTAssertTrue(sentBeforeSwap.isEmpty)
        try await add("still writable", to: persistence.activeLibrary())

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let resumed = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let resumedResult = try await resumed.enableOrRetry()
        let resumedStorage = try await reopened.snapshot()
        XCTAssertEqual(resumedResult.state, .on)
        XCTAssertNotEqual(resumedStorage.activeStore.id, originalID)

        let secondRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let afterSwap = CrashInjector(point: .afterPointerSwap)
        let secondPersistence = try SwiftDataSyncModePersistence(
            rootURL: secondRoot,
            crashHook: afterSwap.hit
        )
        try await add("after", to: secondPersistence.activeLibrary())
        let second = ICloudSyncModeCoordinator(
            persistence: secondPersistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace) }
        )
        do {
            _ = try await second.enableOrRetry()
            XCTFail("Expected the injected crash.")
        } catch CrashInjector.Failure.injected {}
        let final = try await secondPersistence.snapshot()
        XCTAssertEqual(final.activeStore.kind, .iCloudSync)
        XCTAssertEqual(final.transition?.phase, .swapped)
        let recovered = try SwiftDataSyncModePersistence(rootURL: secondRoot)
        let recoveredState = try await recovered.snapshot()
        XCTAssertEqual(recoveredState.activeStore.id, final.activeStore.id)
        XCTAssertNil(recoveredState.transition)
        let recoveredLibrary = try await recovered.activeLibrary()
        let texts = try await recoveredLibrary.checkedSnapshot(sortedBy: .manual).snips.map(\.content)
        XCTAssertEqual(texts, ["after"])
    }

    func testFailedCandidateMergeKeepsLocalSourceRetryableAfterReopen() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let injector = CrashInjector(point: .afterCandidateMergeDurability)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, crashHook: injector.hit)
        try await add("survives merge crash", to: persistence.activeLibrary())
        let originalID = try await persistence.snapshot().activeStore.id
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )

        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("Expected the injected crash.")
        } catch CrashInjector.Failure.injected {}
        let crashed = try await persistence.snapshot()
        XCTAssertEqual(crashed.activeStore.id, originalID)
        XCTAssertNil(crashed.transition)
        XCTAssertEqual(try storeRootCount(in: root), 1)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let result = try await retry.enableOrRetry()
        try await publishActiveStore(
            persistence: reopened, namespace: namespace, textZone: textZone(namespace),
            transport: FakeCloudRecordTransport(server: server, namespace: namespace)
        )
        let serverTexts = await server.storedTextValues()
        XCTAssertEqual(result.state, .on)
        XCTAssertEqual(serverTexts, ["survives merge crash"])
    }

    func testFreshOptOutFetchesRemoteChangesIntoANewLocalCopyWithoutCloudDelete() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        try await add("first", to: persistence.activeLibrary())
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let initialTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let enabled = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { initialTransport }
        )
        _ = try await enabled.enableOrRetry()
        try await seed(
            "remote before opt out",
            id: CloudRecordID(zone: textZone(namespace), name: "later"),
            server: server
        )

        let refreshTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { refreshTransport }
        )
        let result = try await coordinator.optOut(.refreshThenCopy)
        let active = try await persistence.activeLibrary()
        let texts = await active.snapshot(sortedBy: .chronological).snips.map(\.content).sorted()
        let deletes = await server.acceptedDeletionCount()
        XCTAssertEqual(result.state, .off)
        XCTAssertEqual(texts, ["first", "remote before opt out"])
        XCTAssertEqual(deletes, 0)
    }

    func testCandidateCrashPointsNeverChangeTheActivePointer() async throws {
        for point in [
            SyncModeCrashPoint.afterCandidateManifest,
            .beforeCandidateDurability,
            .afterCandidateDurability,
        ] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let injector = CrashInjector(point: point)
            let persistence = try SwiftDataSyncModePersistence(rootURL: root, crashHook: injector.hit)
            let activeID = try await persistence.snapshot().activeStore.id
            do {
                _ = try await persistence.beginTransition(to: .iCloudSync, namespace: testBinding())
                XCTFail("Expected the injected crash.")
            } catch CrashInjector.Failure.injected {}
            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            let snapshot = try await reopened.snapshot()
            XCTAssertEqual(snapshot.activeStore.id, activeID)
            XCTAssertNil(snapshot.transition)
            XCTAssertEqual(try storeRootCount(in: root), 1)
        }
    }

    func testManifestWriteFailureDoesNotChangeActorMemory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FailingManifestWriter()
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, manifestWriter: writer.write)
        writer.failWrites = true
        do {
            try await persistence.recordAttention(.storageFailure)
            XCTFail("Expected the injected manifest write failure.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
        }
        let snapshot = try await persistence.snapshot()
        XCTAssertNil(snapshot.attentionReason)
    }

    func testNamespaceAccountAndGenerationMismatchCannotReadOrCopyPriorCache() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let enabled = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        _ = try await enabled.enableOrRetry()
        let mismatches = [
            CloudSyncNamespace(
                cloudScope: namespace.cloudScope,
                accountLineage: "other-account",
                generation: namespace.generation,
                zones: namespace.zones
            ),
            CloudSyncNamespace(
                cloudScope: namespace.cloudScope,
                accountLineage: namespace.accountLineage,
                generation: UUID(),
                zones: namespace.zones
            ),
        ]
        for mismatch in mismatches {
            let coordinator = ICloudSyncModeCoordinator(
                persistence: persistence,
                namespace: mismatch,
                textZone: textZone(mismatch),
                makeTransport: { FakeCloudRecordTransport(server: server, namespace: mismatch) }
            )
            do {
                _ = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
                XCTFail("A mismatched namespace must not copy the prior cache.")
            } catch {
                XCTAssertEqual(error as? SyncModePersistenceError, .namespaceMismatch)
            }
        }
    }

}
