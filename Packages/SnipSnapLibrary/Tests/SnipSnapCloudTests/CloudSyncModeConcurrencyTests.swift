import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testSecondEnableIsRejectedWhileFirstWaitsForRemoteFetch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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

    func testManagedReadFailureReturnsRealCacheAndRecordsAttention() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = ReadFailureInjector()
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, readHook: failure.check)
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
            rootURL: root
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
            rootURL: root
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
            readHook: overlap.pauseFirstReadThenFailSecond
        )
        let first = persistence.lazyActiveLibrary()
        let firstRead = Task { try await first.checkedSnapshot(sortedBy: .chronological) }
        await overlap.waitUntilFirstReadPauses()

        let second = persistence.lazyActiveLibrary()
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, readHook: failure.check)
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
        XCTAssertNil(failed.transition)
        XCTAssertEqual(failed.attentionReason, .transitionFailure)
        try await add("still writable", to: source)
    }

    func testTerminalFetchFailureNeedsAttentionWhileSourceStaysActive() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
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

        _ = try SwiftDataSyncModePersistence(rootURL: root)
        XCTAssertEqual(try storeRootCount(in: root), 1)
    }

    func testOptOutPointerSwappedResumeDoesNotRequireOldICloudNamespace() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let enabled = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace) }
        )
        _ = try await enabled.enableOrRetry()
        let transition = try await persistence.beginTransition(to: .localOnly, namespace: nil)
        let source = try await persistence.sourceSnapshot(for: transition)
        _ = try await persistence.mergeCandidate(source, for: transition)
        try await persistence.markCandidateMerged(transitionID: transition.id)
        try await persistence.swapPointer(transitionID: transition.id, sourceRevision: source.revision)

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

    func testPointerManifestFailureKeepsWritableSourceAndRecordsAttention() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FailNextManifestWriter()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: writer.armAtPointer,
            manifestWriter: writer.write
        )
        try await add("kept", to: try await persistence.activeLibrary())
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
        XCTAssertNil(failed.transition)
        XCTAssertEqual(failed.attentionReason, .transitionFailure)
        try await add("source stays writable", to: try await persistence.activeLibrary())
    }

    func testActiveCloudApplyLeaseRejectsOptOutUntilApplyFinishes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        _ = try await coordinator.enableOrRetry()
        let activeStoreID = try await persistence.snapshot().activeStore.id
        let lease = try await persistence.activeCloudMutation(storeID: activeStoreID)
        let gate = CloudApplyGate()
        let applying = Task { try await lease.run { try await gate.pause() } }
        await gate.waitUntilPaused()

        do {
            _ = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
            XCTFail("Opt-out must not cross an active Cloud apply lease.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .transitionInProgress)
        }
        let blocked = try await persistence.snapshot()
        XCTAssertEqual(blocked.activeStore.id, activeStoreID)
        XCTAssertNil(blocked.transition)
        await gate.resume()
        try await applying.value
        let finished = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(finished.state, .off)
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
