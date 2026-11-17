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

        failure.shouldFail = false
        let recovered = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(recovered.snips.map(\.content), ["last known"])
        let recoveredStorage = try await persistence.snapshot()
        XCTAssertNil(recoveredStorage.attentionReason)

        let reopened = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1
        )
        let reopenedStorage = try await reopened.snapshot()
        XCTAssertNil(reopenedStorage.attentionReason)
    }

    func testManagedBackupReadFailureDoesNotPublishOlderCachedContent() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = ReadFailureInjector()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1,
            readHook: failure.check
        )
        let library = try await persistence.activeLibrary()
        try await add("last known", to: library)
        let cached = await library.snapshot(sortedBy: .manual)
        let cachedSnip = try XCTUnwrap(cached.snips.first)

        let storeID = try await persistence.snapshot().activeStore.id
        let externalWriter = try await persistence.libraryForTransition(storeID: storeID)
        let list = try await createList(
            "Newly committed", systemImage: "folder.fill", in: externalWriter
        )
        let attachmentBytes = Data("newly committed attachment".utf8)
        let attachmentURL = root.appendingPathComponent("new.txt")
        try attachmentBytes.write(to: attachmentURL)
        let requestID = UUID()
        let update = try await externalWriter.perform(
            .add(
                content: "newly committed",
                origin: .share,
                source: SnipSource(applicationName: "External writer"),
                listID: list.id,
                attachmentURLs: [attachmentURL],
                requestID: requestID,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            sortedBy: .manual
        )
        let latestSnip = try XCTUnwrap(update.snapshot.snips.first { $0.requestID == requestID })
        let attachment = try XCTUnwrap(latestSnip.attachments.first)
        failure.shouldFail = true

        let display = await library.snapshot(sortedBy: .manual)
        XCTAssertEqual(display, cached)
        let failedDestination = root.appendingPathComponent("FailedBackup", isDirectory: true)
        do {
            let archive = try await library.archive()
            try JSONSnipArchiveTransfer.write(archive, to: failedDestination)
            XCTFail("A backup must report a store read failure instead of exporting cached content.")
        } catch ReadFailureInjector.Failure.injected {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDestination.path))
        let failedStorage = try await persistence.snapshot()
        XCTAssertEqual(failedStorage.attentionReason, .storeReadFailed)

        failure.shouldFail = false
        let archive = try await library.archive()
        XCTAssertEqual(Set(archive.snips.map(\.content)), ["last known", "newly committed"])
        XCTAssertEqual(archive.snips.first { $0.id == latestSnip.id }, latestSnip)
        XCTAssertEqual(archive.lists, [.inbox, list])
        XCTAssertEqual(archive.seenRequestIDs, [cachedSnip.requestID, requestID])
        let archivedAttachmentURL = try XCTUnwrap(archive.attachmentURLs[attachment.id])
        XCTAssertEqual(try Data(contentsOf: archivedAttachmentURL), attachmentBytes)
        let recoveredStorage = try await persistence.snapshot()
        XCTAssertNil(recoveredStorage.attentionReason)

        let recoveredDestination = root.appendingPathComponent("RecoveredBackup", isDirectory: true)
        try JSONSnipArchiveTransfer.write(archive, to: recoveredDestination)
        let restored = try JSONSnipArchiveTransfer.read(from: recoveredDestination)
        XCTAssertEqual(Set(restored.snips.map(\.content)), ["last known", "newly committed"])
        XCTAssertEqual(restored.snips.first { $0.id == latestSnip.id }, latestSnip)
        XCTAssertEqual(restored.lists.map(\.id), [SnipList.inboxID, list.id])
        XCTAssertEqual(restored.lists.map(\.name), ["Inbox", "Newly committed"])
        XCTAssertEqual(restored.lists.map(\.systemImage), ["tray.fill", "folder.fill"])
        XCTAssertEqual(restored.seenRequestIDs, [cachedSnip.requestID, requestID])
        let restoredAttachmentURL = try XCTUnwrap(restored.attachmentURLs[attachment.id])
        XCTAssertEqual(try Data(contentsOf: restoredAttachmentURL), attachmentBytes)
    }

    func testSuccessfulManagedReadDoesNotClearAnotherAttentionReason() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1
        )
        let library = try await persistence.activeLibrary()
        try await persistence.recordAttention(.terminalFetchFailure)

        _ = try await library.checkedSnapshot(sortedBy: .chronological)

        let storage = try await persistence.snapshot()
        XCTAssertEqual(storage.attentionReason, .terminalFetchFailure)
    }

    func testManagedReadFailureAndRecoveryDoNotClearAnotherAttentionReason() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = ReadFailureInjector()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1,
            readHook: failure.check
        )
        let library = try await persistence.activeLibrary()
        try await persistence.recordAttention(.terminalFetchFailure)
        failure.shouldFail = true

        do {
            _ = try await library.checkedSnapshot(sortedBy: .chronological)
            XCTFail("The checked read must report the store failure.")
        } catch ReadFailureInjector.Failure.injected {}
        let afterFailure = try await persistence.snapshot()
        XCTAssertEqual(afterFailure.attentionReason, .terminalFetchFailure)

        failure.shouldFail = false
        _ = try await library.checkedSnapshot(sortedBy: .chronological)
        let afterRecovery = try await persistence.snapshot()
        XCTAssertEqual(afterRecovery.attentionReason, .terminalFetchFailure)
    }

    func testOlderManagedReadSuccessDoesNotClearNewerReadFailure() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let overlap = ReadHealthOverlapGate()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            defaultSyncProtocol: .legacyTextV1,
            readHook: overlap.pauseFirstReadThenFailSecond
        )
        let fallback = try JSONSnipLibrary(fileURL: root.appendingPathComponent("fallback.json"))
        let first = persistence.activeLibrary(fallback: fallback)
        let firstRead = Task { try await first.checkedSnapshot(sortedBy: .chronological) }
        await overlap.waitUntilFirstReadPauses()

        let second = persistence.activeLibrary(fallback: fallback)
        do {
            _ = try await second.checkedSnapshot(sortedBy: .chronological)
            XCTFail("The newer checked read must fail.")
        } catch ReadHealthOverlapGate.Failure.injected {}
        let failed = try await persistence.snapshot()
        XCTAssertEqual(failed.attentionReason, .storeReadFailed)

        await overlap.resumeFirstRead()
        _ = try await firstRead.value

        let afterOlderSuccess = try await persistence.snapshot()
        XCTAssertEqual(afterOlderSuccess.attentionReason, .storeReadFailed)
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

actor ReadHealthOverlapGate {
    enum Failure: Error { case injected }

    private var firstReadPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    private var calls = 0

    func pauseFirstReadThenFailSecond() async throws {
        calls += 1
        switch calls {
        case 1:
            firstReadPaused = true
            pauseWaiters.forEach { $0.resume() }
            pauseWaiters = []
            await withCheckedContinuation { release = $0 }
        case 2:
            throw Failure.injected
        default:
            return
        }
    }

    func waitUntilFirstReadPauses() async {
        if firstReadPaused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resumeFirstRead() {
        release?.resume()
        release = nil
    }
}

extension ICloudSyncModeCoordinatorTests {
    func testSessionCheckedReadPairsLocalContentWithItsStoreAndRemainsWritable() async throws {
        let root = pairedReadRoot()
        let reads = PairedReadControl()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root, defaultSyncProtocol: .legacyTextV1, readHook: reads.hit
        )
        let library = try await persistence.activeLibrary()
        try await add("paired local", to: library)
        let before = try await persistence.snapshot()
        let session = SavedSnipsSession(library: library)
        let calls = reads.calls

        let observation = try await session.checkedRead(sortedBy: .chronological)

        XCTAssertEqual(reads.calls, calls + 1)
        XCTAssertEqual(observation.snapshot.snips.map(\.content), ["paired local"])
        let source = try XCTUnwrap(observation.source)
        XCTAssertEqual(source.storeID, before.activeStore.id)
        XCTAssertEqual(source.storageMode, .localOnly)
        XCTAssertNil(source.namespaceKey)
        let afterRead = try await persistence.snapshot()
        XCTAssertEqual(afterRead.activeStore, before.activeStore)
        XCTAssertFalse(afterRead.hasActiveMutationReservation)

        let checkedCalls = reads.calls
        let legacySnapshot = try await library.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(reads.calls, checkedCalls + 1)
        XCTAssertEqual(legacySnapshot.snips.map(\.content), ["paired local"])
        try await add("later local", to: library)
        let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let reopenedSession = SavedSnipsSession(library: try await reopened.activeLibrary())
        let durable = try await reopenedSession.checkedRead(sortedBy: .chronological)
        XCTAssertEqual(Set(durable.snapshot.snips.map(\.content)), ["paired local", "later local"])
        XCTAssertEqual(durable.source?.storeID, before.activeStore.id)
        XCTAssertEqual(durable.source?.storageMode, .localOnly)
        XCTAssertNil(durable.source?.namespaceKey)
    }

    func testSessionCheckedReadPairsTheFullCloudNamespaceAndThenTheLocalReplacement() async throws {
        let root = pairedReadRoot()
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let library = try await persistence.activeLibrary()
        let session = SavedSnipsSession(library: library)
        let initial = try await persistence.snapshot()
        try await persistence.activateEmptyCollection(namespace: testBinding())
        try await add("cloud collection", to: library)
        let cloudStore = try await persistence.snapshot()
        XCTAssertNotEqual(cloudStore.activeStore.id, initial.activeStore.id)

        let cloud = try await session.checkedRead(sortedBy: .chronological)

        XCTAssertEqual(cloud.snapshot.snips.map(\.content), ["cloud collection"])
        let cloudSource = try XCTUnwrap(cloud.source)
        XCTAssertEqual(cloudSource.storeID, cloudStore.activeStore.id)
        XCTAssertEqual(cloudSource.storageMode, .iCloudSync)
        XCTAssertEqual(cloudSource.namespaceKey,
            "AAAAAAAAABtzbmlwc25hcC1jbG91ZC1uYW1lc3BhY2UtdjEAAAAAAAAAB3ByaXZhdGUAAAAAAAAAB2FjY291bnQAAAAAAAAAJDk5OTk5OTk5LTk5OTktOTk5OS05OTk5LTk5OTk5OTk5OTk5OQAAAAAAAAAFb3duZXIAAAAAAAAACG1ldGFkYXRh")

        try await persistence.activateEmptyCollection(namespace: nil)
        try await add("replacement local", to: library)
        let localStore = try await persistence.snapshot()
        XCTAssertNotEqual(localStore.activeStore.id, cloudStore.activeStore.id)
        let local = try await session.checkedRead(sortedBy: .chronological)
        XCTAssertEqual(local.snapshot.snips.map(\.content), ["replacement local"])
        let localSource = try XCTUnwrap(local.source)
        XCTAssertEqual(localSource.storeID, localStore.activeStore.id)
        XCTAssertEqual(localSource.storageMode, .localOnly)
        XCTAssertNil(localSource.namespaceKey)
        let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let durable = try await (try await reopened.activeLibrary()).checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(durable.snips.map(\.content), ["replacement local"])
    }

    @MainActor
    func testSessionCheckedReadSelectsTheReplacementAfterItsPreparatoryHook() async throws {
        let binding = testBinding()
        try await withPairedReadOwnership { work in
            let root = pairedReadRoot()
            let reads = PairedReadControl()
            let persistence = try SwiftDataSyncModePersistence(
                rootURL: root, defaultSyncProtocol: .legacyTextV1, readHook: reads.hit
            )
            let library = try await persistence.activeLibrary()
            try await pairedReadAdd("before preparation", to: library)
            let session = SavedSnipsSession(library: library)
            work.retain(persistence)
            work.retain(library as AnyObject)
            work.retain(session)
            let oldStore = try await persistence.snapshot()
            let gate = work.gate()
            reads.pauseNextRead(at: gate)
            var result: Result<SnipLibraryReadObservation, any Error>?
            let read = work.start {
                do { result = .success(try await session.checkedRead(sortedBy: .chronological)) }
                catch { result = .failure(error) }
            }
            guard await work.ready(gate.entered, "preparatory read hook") else { return }

            var replacementError: (any Error)?
            let replacement = work.start {
                do {
                    try await persistence.activateEmptyCollection(namespace: binding)
                    let selectedID = try await persistence.snapshot().activeStore.id
                    let selectedLibrary = try await persistence.libraryForTransition(storeID: selectedID)
                    try await pairedReadAdd("selected after preparation", to: selectedLibrary)
                } catch { replacementError = error }
            }
            guard await work.ready(replacement.finished, "real replacement and durable write") else { return }
            if let replacementError { throw replacementError }
            let selected = try await persistence.snapshot()
            XCTAssertNotEqual(selected.activeStore.id, oldStore.activeStore.id)
            XCTAssertFalse(read.finished.isSet)
            XCTAssertTrue(gate.isHeld)
            gate.release()
            guard await work.completed(read, "paired read after preparation") else { return }
            let observation = try XCTUnwrap(result).get()
            XCTAssertEqual(observation.snapshot.snips.map(\.content), ["selected after preparation"])
            XCTAssertEqual(observation.source?.storeID, selected.activeStore.id)
            XCTAssertEqual(observation.source?.storageMode, .iCloudSync)
            XCTAssertEqual(observation.source?.namespaceKey,
                "AAAAAAAAABtzbmlwc25hcC1jbG91ZC1uYW1lc3BhY2UtdjEAAAAAAAAAB3ByaXZhdGUAAAAAAAAAB2FjY291bnQAAAAAAAAAJDk5OTk5OTk5LTk5OTktOTk5OS05OTk5LTk5OTk5OTk5OTk5OQAAAAAAAAAFb3duZXIAAAAAAAAACG1ldGFkYXRh")
        }
    }

    func testSessionRawCheckedReadIsUnboundAndUsesTheRealCheckedSnapshot() async throws {
        let root = pairedReadRoot()
        let storeURL = root.appendingPathComponent("raw.store")
        let raw = try SwiftDataSnipLibrary(storeURL: storeURL)
        try await add("raw durable", to: raw)
        let forwarding = PairedReadRawLibrary(library: raw)
        let session = SavedSnipsSession(library: forwarding)

        let observation = try await session.checkedRead(sortedBy: .chronological)

        XCTAssertEqual(observation.snapshot.snips.map(\.content), ["raw durable"])
        XCTAssertNil(observation.source)
        let calls = await forwarding.readCalls()
        XCTAssertEqual(calls.checked, 1)
        XCTAssertEqual(calls.unchecked, 0)
        try await add("raw still writable", to: forwarding)
        let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
        let durable = try await reopened.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(Set(durable.snips.map(\.content)), ["raw durable", "raw still writable"])
    }

    func testSessionRawCheckedReadPropagatesTheOriginalErrorWithoutFallback() async throws {
        let root = pairedReadRoot()
        let raw = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("raw.store"))
        try await add("raw before error", to: raw)
        let failure = PairedReadRawFailure()
        let forwarding = PairedReadRawLibrary(library: raw, failure: failure)
        let session = SavedSnipsSession(library: forwarding)

        do {
            _ = try await session.checkedRead(sortedBy: .chronological)
            XCTFail("An unbound checked read must propagate its original error.")
        } catch {
            XCTAssertTrue((error as? PairedReadRawFailure) === failure)
        }

        let calls = await forwarding.readCalls()
        XCTAssertEqual(calls.checked, 1)
        XCTAssertEqual(calls.unchecked, 0)
        let durable = try await raw.checkedSnapshot(sortedBy: .chronological)
        XCTAssertEqual(durable.snips.map(\.content), ["raw before error"])
    }

    func testSessionManagedCheckedReadPreservesReadFailureCacheAndOtherAttention() async throws {
        let root = pairedReadRoot()
        let reads = PairedReadControl()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root, defaultSyncProtocol: .legacyTextV1, readHook: reads.hit
        )
        let library = try await persistence.activeLibrary()
        try await add("known managed", to: library)
        let session = SavedSnipsSession(library: library)
        reads.shouldFail = true
        do {
            _ = try await session.checkedRead(sortedBy: .chronological)
            XCTFail("A managed checked read must not substitute its cached snapshot.")
        } catch PairedReadControl.Failure.injected {}
        let failed = try await persistence.snapshot()
        XCTAssertEqual(failed.attentionReason, .storeReadFailed)
        let cached = await library.snapshot(sortedBy: .chronological)
        XCTAssertEqual(cached.snips.map(\.content), ["known managed"])

        reads.shouldFail = false
        let recovered = try await session.checkedRead(sortedBy: .chronological)
        XCTAssertEqual(recovered.snapshot.snips.map(\.content), ["known managed"])
        XCTAssertEqual(recovered.source?.storeID, failed.activeStore.id)
        let healthy = try await persistence.snapshot()
        XCTAssertNil(healthy.attentionReason)
        try await persistence.recordAttention(.terminalFetchFailure)
        reads.shouldFail = true
        do {
            _ = try await session.checkedRead(sortedBy: .chronological)
            XCTFail("Another attention reason must not conceal the read error.")
        } catch PairedReadControl.Failure.injected {}
        reads.shouldFail = false
        _ = try await session.checkedRead(sortedBy: .chronological)
        let unrelated = try await persistence.snapshot()
        XCTAssertEqual(unrelated.attentionReason, .terminalFetchFailure)
    }

    func testSessionCheckedReadCachesSuccessfulContentBeforeAttentionClearThrows() async throws {
        let root = pairedReadRoot()
        let reads = PairedReadControl()
        let writer = PairedReadManifestWriter()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root, defaultSyncProtocol: .legacyTextV1,
            manifestWriter: writer.write, readHook: reads.hit
        )
        let library = try await persistence.activeLibrary()
        try await add("cached before clear", to: library)
        let session = SavedSnipsSession(library: library)
        let storeID = try await persistence.snapshot().activeStore.id
        let externalWriter = try await persistence.libraryForTransition(storeID: storeID)
        try await add("committed outside cache", to: externalWriter)
        try await persistence.recordAttention(.storeReadFailed)
        writer.failNextWrite()

        do {
            _ = try await session.checkedRead(sortedBy: .chronological)
            XCTFail("The checked read must report the failed recovered-attention commit.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
        }
        XCTAssertEqual(writer.failures, 1)
        let uncleared = try await persistence.snapshot()
        XCTAssertEqual(uncleared.attentionReason, .storeReadFailed)
        reads.shouldFail = true
        let cachedAfterClearError = await library.snapshot(sortedBy: .chronological)
        XCTAssertEqual(Set(cachedAfterClearError.snips.map(\.content)),
            ["cached before clear", "committed outside cache"])

        reads.shouldFail = false
        let recovered = try await session.checkedRead(sortedBy: .chronological)
        XCTAssertEqual(Set(recovered.snapshot.snips.map(\.content)),
            ["cached before clear", "committed outside cache"])
        XCTAssertEqual(recovered.source?.storeID, storeID)
        let healthy = try await persistence.snapshot()
        XCTAssertNil(healthy.attentionReason)
    }

    @MainActor
    func testSessionOlderPairedReadSuccessCannotClearANewerReadFailure() async throws {
        try await withPairedReadOwnership { work in
            let root = pairedReadRoot()
            let reads = PairedReadControl()
            let persistence = try SwiftDataSyncModePersistence(
                rootURL: root, defaultSyncProtocol: .legacyTextV1, readHook: reads.hit
            )
            let firstLibrary = try await persistence.activeLibrary()
            try await pairedReadAdd("overlapping durable", to: firstLibrary)
            let secondLibrary = try await persistence.activeLibrary()
            let first = SavedSnipsSession(library: firstLibrary)
            let second = SavedSnipsSession(library: secondLibrary)
            work.retain(persistence)
            work.retain(first)
            work.retain(second)
            let expectedStore = try await persistence.snapshot().activeStore.id
            let gate = work.gate()
            reads.pauseNextRead(at: gate)
            var result: Result<SnipLibraryReadObservation, any Error>?
            let older = work.start {
                do { result = .success(try await first.checkedRead(sortedBy: .chronological)) }
                catch { result = .failure(error) }
            }
            guard await work.ready(gate.entered, "older managed read") else { return }
            reads.shouldFail = true
            do {
                _ = try await second.checkedRead(sortedBy: .chronological)
                XCTFail("The newer managed read must report its actual read error.")
            } catch PairedReadControl.Failure.injected {}
            let failed = try await persistence.snapshot()
            XCTAssertEqual(failed.attentionReason, .storeReadFailed)
            XCTAssertTrue(gate.isHeld)
            XCTAssertFalse(older.finished.isSet)

            gate.release()
            guard await work.completed(older, "older read success") else { return }
            let observation = try XCTUnwrap(result).get()
            XCTAssertEqual(observation.snapshot.snips.map(\.content), ["overlapping durable"])
            XCTAssertEqual(observation.source?.storeID, expectedStore)
            XCTAssertEqual(observation.source?.storageMode, .localOnly)
            XCTAssertNil(observation.source?.namespaceKey)
            let afterOlder = try await persistence.snapshot()
            XCTAssertEqual(afterOlder.attentionReason, .storeReadFailed)
            reads.shouldFail = false
            _ = try await second.checkedRead(sortedBy: .chronological)
            let afterNewerRecovery = try await persistence.snapshot()
            XCTAssertNil(afterNewerRecovery.attentionReason)
        }
    }
}

private func pairedReadRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnipSnapPairedRead-\(UUID().uuidString)", isDirectory: true)
    print("OFFLINE-PAIRED-READ retained unique root (store-close completion unobservable): \(root.path)")
    return root
}

private func pairedReadAdd(_ text: String, to library: any SnipLibrary) async throws {
    _ = try await library.perform(
        .add(
            content: text, origin: .quickEntry, source: nil,
            listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: Date()
        ),
        sortedBy: .chronological
    )
}

private final class PairedReadRawFailure: Error, @unchecked Sendable {}

private actor PairedReadRawLibrary: SnipLibrary {
    private let library: SwiftDataSnipLibrary
    private let failure: PairedReadRawFailure?
    private var checked = 0
    private var unchecked = 0

    init(library: SwiftDataSnipLibrary, failure: PairedReadRawFailure? = nil) {
        self.library = library
        self.failure = failure
    }

    func snapshot(sortedBy sortMode: SnipSortMode) async -> SnipLibrarySnapshot {
        unchecked += 1
        return await library.snapshot(sortedBy: sortMode)
    }

    func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot {
        checked += 1
        let snapshot = try await library.checkedSnapshot(sortedBy: sortMode)
        if let failure { throw failure }
        return snapshot
    }

    func perform(_ command: SnipLibraryCommand, sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryUpdate {
        try await library.perform(command, sortedBy: sortMode)
    }

    func readCalls() -> (checked: Int, unchecked: Int) { (checked, unchecked) }
}

private final class PairedReadControl: @unchecked Sendable {
    enum Failure: Error { case injected }
    private let lock = NSLock()
    private var count = 0
    private var failing = false
    private var nextGate: PairedReadGate?
    var calls: Int { lock.withLock { count } }
    var shouldFail: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func pauseNextRead(at gate: PairedReadGate) {
        lock.withLock { nextGate = gate }
    }

    func hit() async throws {
        let (gate, fails) = lock.withLock {
            count += 1
            let gate = nextGate
            nextGate = nil
            return (gate, failing)
        }
        if let gate { try await gate.suspend() }
        try Task.checkCancellation()
        if fails { throw Failure.injected }
    }
}

private final class PairedReadManifestWriter: @unchecked Sendable {
    enum Failure: Error { case injected }
    private let lock = NSLock()
    private var armed = false
    private var failed = 0
    var failures: Int { lock.withLock { failed } }

    func failNextWrite() { lock.withLock { armed = true } }

    func write(_ data: Data, to url: URL) throws {
        let fails = lock.withLock {
            guard armed else { return false }
            armed = false
            failed += 1
            return true
        }
        if fails { throw Failure.injected }
        try data.write(to: url, options: .atomic)
    }
}

private final class PairedReadSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var isSet: Bool { lock.withLock { fired } }

    func fire() {
        let pending = lock.withLock {
            fired = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume(returning: true) }
    }

    func observe() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Bool? = lock.withLock {
                    if fired { return true }
                    if Task.isCancelled { return false }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            self.lock.withLock { self.waiters.removeValue(forKey: id) }?.resume(returning: false)
        }
    }

    func wait(for timeout: Duration) async -> Bool {
        if isSet { return true }
        guard timeout > .zero else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.observe() }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch {}
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

private final class PairedReadGate: @unchecked Sendable {
    let entered = PairedReadSignal()
    private let released = PairedReadSignal()
    var isHeld: Bool { entered.isSet && !released.isSet }

    func suspend() async throws {
        entered.fire()
        guard await released.observe() else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func release() { released.fire() }
}

@MainActor
private final class PairedReadTask {
    let finished: PairedReadSignal
    let task: Task<Void, Never>

    init(_ operation: @escaping @MainActor () async -> Void) {
        let completion = PairedReadSignal()
        finished = completion
        task = Task {
            await operation()
            completion.fire()
        }
    }
}

@MainActor
private final class PairedReadOwnership {
    private var gates: [PairedReadGate] = []
    private var tasks: [PairedReadTask] = []
    private var resources: [AnyObject] = []
    private var retainedAfterFailedJoin: PairedReadOwnership?

    func retain(_ resource: AnyObject) { resources.append(resource) }

    func gate() -> PairedReadGate {
        let gate = PairedReadGate()
        gates.append(gate)
        return gate
    }

    func start(_ operation: @escaping @MainActor () async -> Void) -> PairedReadTask {
        let task = PairedReadTask(operation)
        tasks.append(task)
        return task
    }

    func ready(_ signal: PairedReadSignal, _ stage: String) async -> Bool {
        let ready = await signal.wait(for: .seconds(30))
        XCTAssertTrue(ready, "Paired-read setup/readiness failed: \(stage)")
        return ready
    }

    func completed(_ operation: PairedReadTask, _ stage: String) async -> Bool {
        let completed = await operation.finished.wait(for: .seconds(2))
        XCTAssertTrue(completed, "Paired-read completion failed: \(stage)")
        return completed
    }

    func cleanUp() async {
        let cleanup = Task { @MainActor [self] in
            gates.forEach { $0.release() }
            tasks.forEach { $0.task.cancel() }
            let deadline = ContinuousClock.now + .seconds(30)
            var settled = true
            for operation in tasks {
                let joined = await operation.finished.wait(for: deadline - ContinuousClock.now)
                XCTAssertTrue(joined, "Paired-read cleanup could not join an owned caller; retaining ownership")
                if joined { await operation.task.value } else { settled = false }
            }
            guard settled else {
                retainedAfterFailedJoin = self
                return
            }
            tasks.removeAll()
            gates.removeAll()
            resources.removeAll()
        }
        await cleanup.value
    }
}

@MainActor
private func withPairedReadOwnership(
    _ operation: @MainActor (PairedReadOwnership) async throws -> Void
) async throws {
    let work = PairedReadOwnership()
    do { try await operation(work) }
    catch {
        await work.cleanUp()
        throw error
    }
    await work.cleanUp()
}
