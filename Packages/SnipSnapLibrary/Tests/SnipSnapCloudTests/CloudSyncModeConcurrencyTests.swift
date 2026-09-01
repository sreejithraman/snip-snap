import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testStatusReadsSettingUpWhileEnableWaitsForRemoteFetch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.pauseNextFetch()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )
        let enable = Task { try await coordinator.enableOrRetry() }
        await transport.waitUntilFetchPauses()
        let live = try await coordinator.status()
        XCTAssertEqual(live.state, .settingUp)
        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("A second mode change must fail while setup is running.")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .modeTransitionInProgress)
        }
        await transport.resumeFetch()
        let result = try await enable.value
        XCTAssertEqual(result.state, .on)
    }

    func testRevisionReservationSerializesWriteAdmissionWithFreeze() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = WriteReservationGate()
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1, writeHook: gate.hit)
        let library = try await persistence.activeLibrary()
        let write = Task {
            _ = try await library.perform(
                .add(
                    content: "admitted",
                    origin: .quickEntry,
                    source: nil,
                    listID: SnipList.inboxID,
                    attachmentURLs: [],
                    requestID: UUID(),
                    now: Date()
                ),
                sortedBy: .chronological
            )
        }
        await gate.waitUntilReserved()

        do {
            _ = try await persistence.beginTransition(to: .iCloudSync, namespace: testBinding())
            XCTFail("Freeze setup must not pass a reserved write.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .transitionInProgress)
        }
        await gate.resume()
        try await write.value

        _ = try await persistence.beginTransition(to: .iCloudSync, namespace: testBinding())
        try await persistence.recordPreparationComplete()
        let token = try await persistence.freezeSource()
        let final = try await persistence.finalSnapshot(using: token)
        XCTAssertEqual(token.revision, 1)
        XCTAssertEqual(final.snips.map(\.content), ["admitted"])
    }

    func testCrashWithReservedRevisionReopensAtThatRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let crash = WriteCrashInjector()
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1, writeHook: crash.hit)
        do {
            try await add("not committed", to: try await persistence.activeLibrary())
            XCTFail("Expected the write crash.")
        } catch WriteCrashInjector.Failure.injected {}
        let crashedStorage = try await persistence.snapshot()
        XCTAssertEqual(crashedStorage.activeStore.revision, 1)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let recoveredStorage = try await reopened.snapshot()
        XCTAssertEqual(recoveredStorage.activeStore.revision, 1)
        try await add("after reopen", to: try await reopened.activeLibrary())
        let snapshot = try await reopened.snapshot()
        let data = await (try await reopened.activeLibrary()).snapshot(sortedBy: .chronological)
        XCTAssertEqual(snapshot.activeStore.revision, 2)
        XCTAssertEqual(data.snips.map(\.content), ["after reopen"])
    }

    func testManagedReadFailureReturnsRealCacheAndRecordsAttention() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = ReadFailureInjector()
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1, readHook: failure.check)
        let library = try await persistence.activeLibrary()
        try await add("last known", to: library)
        failure.shouldFail = true

        do {
            _ = try await library.checkedSnapshot(sortedBy: .chronological)
            XCTFail("The checked read must report the store failure.")
        } catch ReadFailureInjector.Failure.injected {}
        let cached = await library.snapshot(sortedBy: .chronological)
        let storage = try await persistence.snapshot()
        XCTAssertEqual(cached.snips.map(\.content), ["last known"])
        XCTAssertEqual(storage.attentionReason, .storeReadFailed)
    }

    func testTransferReadFaultNeverActivatesCandidateAndRestoresWritableSource() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = ReadFailureInjector()
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1, readHook: failure.check)
        let source = try await persistence.activeLibrary()
        try await add("kept", to: source)
        let sourceID = try await persistence.snapshot().activeStore.id
        let namespace = makeNamespace()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace) }
        )
        failure.shouldFail = true

        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("The transfer read must fail.")
        } catch ReadFailureInjector.Failure.injected {}
        let failed = try await persistence.snapshot()
        XCTAssertEqual(failed.activeStore.id, sourceID)
        XCTAssertEqual(failed.transition?.phase, .remoteFetched)
        XCTAssertEqual(failed.attentionReason, .transitionFailure)
        try await add("still writable", to: source)
    }

    func testTerminalFetchFailureNeedsAttentionWhileSourceStaysActive() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let sourceID = try await persistence.snapshot().activeStore.id
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
        await transport.failNextFetchTerminally()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        let result = try await coordinator.enableOrRetry()

        XCTAssertEqual(result.state, .needsAttention)
        XCTAssertEqual(result.attentionReason, .terminalFetchFailure)
        let storage = try await persistence.snapshot()
        XCTAssertEqual(storage.activeStore.id, sourceID)
    }

    func testRetiredCleanupDeclarationSurvivesCrashAndReopen() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let crash = CrashInjector(point: .afterRetiredCleanupDeclared)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1, crashHook: crash.hit)
        let namespace = makeNamespace()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace) }
        )
        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("Expected the cleanup declaration crash.")
        } catch CrashInjector.Failure.injected {}
        let crashedStorage = try await persistence.snapshot()
        XCTAssertNil(crashedStorage.transition)
        XCTAssertEqual(try storeRootCount(in: root), 2)

        _ = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        XCTAssertEqual(try storeRootCount(in: root), 1)
    }

    func testOptOutPointerSwappedResumeDoesNotRequireOldICloudNamespace() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let namespace = makeNamespace()
        let enabled = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace) }
        )
        _ = try await enabled.enableOrRetry()
        _ = try await persistence.beginTransition(to: .localOnly, namespace: nil)
        try await persistence.recordPreparationComplete()
        let token = try await persistence.freezeSource()
        let source = try await persistence.finalSnapshot(using: token)
        let result = try await persistence.mergeFinalSnapshot(source, using: token)
        try await persistence.recordEnrollmentApproved(expected: result.approvedSnipIDs)
        try await persistence.recordNoSendRequired()
        try await persistence.swapPointer()

        let other = CloudSyncNamespace(
            cloudScope: namespace.cloudScope,
            accountLineage: "signed-in-later",
            generation: UUID(),
            zones: namespace.zones
        )
        let resumed = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: other,
            textZone: textZone(other),
            makeTransport: { FakeCloudRecordTransport(server: FakeCloudServer(), namespace: other) }
        )
        let status = try await resumed.optOut(.useCurrentCacheAfterStaleDataWarning)
        let finished = try await persistence.snapshot()

        XCTAssertEqual(status.state, .off)
        XCTAssertNil(finished.transition)
    }

    func testPointerManifestFailureUnfreezesWritableSourceAndRecordsAttention() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FailNextManifestWriter()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root, defaultSyncProtocol: .legacyTextV1,
            crashHook: writer.armAtPointer,
            manifestWriter: writer.write
        )
        let sourceID = try await persistence.snapshot().activeStore.id
        let namespace = makeNamespace()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace) }
        )
        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("Expected the pointer manifest failure.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
        }
        let failed = try await persistence.snapshot()
        XCTAssertEqual(failed.activeStore.id, sourceID)
        XCTAssertEqual(failed.transition?.phase, .candidateReady)
        XCTAssertEqual(failed.attentionReason, .transitionFailure)
        try await add("source stays writable", to: try await persistence.activeLibrary())
    }

    func testStatusReadsSyncingWhileFreshOptOutFetches() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let initial = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        _ = try await initial.enableOrRetry()
        let paused = FakeCloudRecordTransport(server: server, namespace: namespace)
        await paused.pauseNextFetch()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { paused }
        )
        let optOut = Task { try await coordinator.optOut(.refreshThenCopy) }
        await paused.waitUntilFetchPauses()

        let live = try await coordinator.status()

        XCTAssertEqual(live.state, .syncing)
        await paused.resumeFetch()
        let finished = try await optOut.value
        XCTAssertEqual(finished.state, .off)
    }

    func testOptOutRefreshReservationBlocksWritesAndTransitionAdmissionUntilApplyFinishes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let enabled = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        _ = try await enabled.enableOrRetry()
        let managed = try await persistence.activeLibrary()
        let refresh = FakeCloudRecordTransport(server: server, namespace: namespace)
        await refresh.pauseNextFetch()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { refresh }
        )
        let optOut = Task { try await coordinator.optOut(.refreshThenCopy) }
        await refresh.waitUntilFetchPauses()

        do {
            try await add("must wait", to: managed)
            XCTFail("An app write must not cross the refresh reservation.")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .modeTransitionInProgress)
        }
        do {
            _ = try await persistence.beginTransition(to: .localOnly, namespace: nil)
            XCTFail("A freeze transition must not cross the refresh reservation.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .transitionInProgress)
        }
        await refresh.resumeFetch()
        let finished = try await optOut.value
        XCTAssertEqual(finished.state, .off)
    }

    func testActiveCloudApplyLeaseRejectsOptOutUntilApplyFinishes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let initial = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        _ = try await initial.enableOrRetry()
        try await seed(
            "arrives during active sync",
            id: CloudRecordID(zone: textZone(namespace), name: "lease-test"),
            server: server
        )
        let gate = CloudApplyGate()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) },
            applyHook: gate.pause
        )
        let syncing = Task { try await coordinator.syncActive() }
        await gate.waitUntilPaused()
        let liveStatus = try await coordinator.status()
        XCTAssertEqual(liveStatus.state, .syncing)

        do {
            _ = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
            XCTFail("Opt-out must not cross an active Cloud apply lease.")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .modeTransitionInProgress)
        }
        await gate.resume()
        let syncResult = try await syncing.value
        XCTAssertEqual(syncResult.state, .on)
        let finished = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(finished.state, .off)
    }

    func testWriteClearFailureKeepsAdvancedRevisionAndCommittedData() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FailNextManifestWriter()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root, defaultSyncProtocol: .legacyTextV1,
            manifestWriter: writer.write,
            writeHook: writer.armAtWriteClear
        )
        let library = try await persistence.activeLibrary()
        do {
            try await add("committed before fence clear", to: library)
            XCTFail("The caller must see the manifest failure.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
        }
        let storage = try await persistence.snapshot()
        let stored = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(storage.activeStore.revision, 1)
        XCTAssertEqual(stored.snips.map(\.content), ["committed before fence clear"])

        _ = try await persistence.beginTransition(to: .iCloudSync, namespace: testBinding())
        try await persistence.recordPreparationComplete()
        let token = try await persistence.freezeSource()
        let final = try await persistence.finalSnapshot(using: token)
        XCTAssertEqual(token.revision, 1)
        XCTAssertEqual(final.snips.map(\.content), ["committed before fence clear"])
    }

}
