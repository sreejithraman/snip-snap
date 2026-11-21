import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testEnableSwapsTheMergedStoreBeforeNormalOutboundUpload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .fullRecordV1)
        let local = try await persistence.activeLibrary()
        try await add("local", to: local)
        let originalID = try await persistence.snapshot().activeStore.id
        let server = FakeCloudServer()
        let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
        let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account")
        let remoteID = CloudRecordID(zone: descriptor.metadataZone, name: "remote")
        try await seed("remote", id: remoteID, server: server)
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone,
            makeTransport: { transport }
        )

        let result = try await coordinator.enableOrRetry()

        XCTAssertEqual(result.state, .on)
        let active = try await persistence.activeLibrary()
        let activeTexts = await active.snapshot(sortedBy: .chronological).snips.map(\.content).sorted()
        let enabled = try await persistence.snapshot()
        XCTAssertNotEqual(enabled.activeStore.id, originalID)
        XCTAssertNil(enabled.transition)
        XCTAssertEqual(activeTexts, ["local", "remote"])
        XCTAssertEqual(try storeRootCount(in: root), 1)
        let beforeUpload = await server.storedTextValues()
        XCTAssertEqual(beforeUpload, ["remote"])

        let driver = CloudFullRecordCollectionSyncDriver(persistence: persistence, makeTransport: { _ in transport })
        let context = CloudCollectionSyncContext(namespace: namespace,
            metadataZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone)
        _ = try await driver.fetch(context)
        _ = try await driver.send(context)
        let serverTexts = await server.storedTextValues()
        XCTAssertEqual(serverTexts, ["local", "remote"])
        let calls = await transport.events()
        let fetchIndex = try XCTUnwrap(calls.firstIndex(of: .fetched))
        let sendIndex = try XCTUnwrap(calls.firstIndex(where: {
            if case .sent = $0 { return true }
            return false
        }))
        XCTAssertLessThan(fetchIndex, sendIndex)
    }

    func testFirstEnableUsesEditsMadeThroughTheAppLibraryDuringFetch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("Local/snips.store"))
        try await add("before setup", to: original)
        let syncRoot = root.appendingPathComponent("SyncMode")
        let assembly = SnipLibraryAssembly(library: original, syncModeRootURL: syncRoot)
        XCTAssertFalse(SyncModeActivationManifestReader.hasActivationManifest(atSyncModeRootURL: syncRoot))
        let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
        let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account")
        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.pauseNextFetch()
        let lifecycle = SnipSnapICloudSyncLifecycle(
            rootURL: syncRoot, sourceLibrary: original, syncModeStore: assembly.syncModeStore,
            cloudScope: namespace.cloudScope, accountLineage: namespace.accountLineage,
            ownerName: "owner", controlTransport: FakeCloudControlTransport(server: server),
            makeRecordTransport: { _ in transport }, makeDescriptor: { descriptor }
        )
        let scheduled = expectation(description: "The session schedules upload after activation")
        let session = SnipSnapCloudSyncSession(
            synchronize: { try await lifecycle.synchronize() },
            scheduleAutomaticSync: {
                let before = await server.storedTextValues()
                XCTAssertTrue(before.isEmpty)
                try await lifecycle.scheduleAutomaticSync()
                scheduled.fulfill()
            },
            enable: { try await lifecycle.enableICloudSync() },
            delete: { try await lifecycle.deleteSyncedContent() },
            activeLibrary: { try await lifecycle.activeLibrary() }
        )

        let enabling = Task { try await session.enableICloudSync() }
        await transport.waitUntilFetchPauses()
        do {
            try await add("during fetch", to: assembly.library)
        } catch {
            await transport.resumeFetch()
            _ = await enabling.result
            throw error
        }
        await transport.resumeFetch()
        let outcome = try await enabling.value
        XCTAssertEqual(outcome, .enabled)
        await fulfillment(of: [scheduled], timeout: 5)
        let visible = try await assembly.library.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(visible.snips.map(\.content)), ["before setup", "during fetch"])
        let cloud = await server.storedTextValues()
        XCTAssertEqual(Set(cloud), ["before setup", "during fetch"])
    }

    func testEnableKeepsRemoteIdentityAndAddsARecoveredCopyForSameIDLocalText() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .fullRecordV1)
        let sharedID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let local = try await persistence.activeLibrary()
        _ = try await local.perform(
            .restore(
                snips: [
                    Snip(
                        id: sharedID,
                        content: "local edit",
                        origin: .quickEntry,
                        listID: SnipList.inboxID
                    )
                ]
            ),
            sortedBy: .chronological
        )
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let writer = FakeCloudRecordTransport(server: server)
        _ = try await writer.send(
            CloudOutboundBatch(
                operations: [
                    .save(try CloudFullRecordCodec.snipDraft(
                        Snip(id: sharedID, content: "remote edit", origin: .quickEntry, listID: SnipList.inboxID),
                        in: textZone(namespace)
                    ))
                ]
            )
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )

        let result = try await coordinator.enableOrRetry()
        let active = try await persistence.activeLibrary()
        let snapshot = await active.snapshot(sortedBy: .chronological)
        let fixed = snapshot.snips.first(where: { $0.id == sharedID })
        XCTAssertEqual(result.state, .on)
        XCTAssertEqual(fixed?.content, "remote edit")
        XCTAssertEqual(snapshot.snips.map(\.content).sorted(), ["local edit", "remote edit"])
        XCTAssertEqual(Set(snapshot.snips.map(\.id)).count, 2)
    }

    func testOfflineEnableDiscardsCandidateAndReopenCanRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .fullRecordV1)
        let local = try await persistence.activeLibrary()
        try await add("kept local", to: local)
        let originalID = try await persistence.snapshot().activeStore.id
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let offline = FakeCloudRecordTransport(server: server, namespace: namespace)
        await offline.failNextFetch()
        let first = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { offline }
        )

        let offlineResult = try await first.enableOrRetry()
        let offlineStorage = try await persistence.snapshot()
        let localTexts = await local.snapshot(sortedBy: .chronological).snips.map(\.content)
        XCTAssertEqual(offlineResult.state, .settingUp)
        XCTAssertEqual(offlineResult.syncIssue, .someChangesPending)
        XCTAssertEqual(offlineStorage.activeStore.id, originalID)
        XCTAssertEqual(localTexts, ["kept local"])
        XCTAssertNil(offlineStorage.transition)
        XCTAssertEqual(try storeRootCount(in: root), 1)
        try await add("edited after failed fetch", to: local)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .fullRecordV1)
        let online = FakeCloudRecordTransport(server: server, namespace: namespace)
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { online }
        )
        let retryResult = try await retry.enableOrRetry()
        let retryStorage = try await reopened.snapshot()
        XCTAssertEqual(retryResult.state, .on)
        XCTAssertNotEqual(retryStorage.activeStore.id, originalID)
    }

    func testCancellationBeforeSwapDiscardsCandidateAndLeavesSourceWritable() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        try await add("kept local", to: source)
        let originalID = try await persistence.snapshot().activeStore.id
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let gate = CloudApplyGate()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence, namespace: namespace, textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) },
            checkSetupCollection: { try await gate.pause() }
        )

        let enable = Task { try await coordinator.enableOrRetry() }
        await gate.waitUntilPaused()
        let pending = try await persistence.snapshot()
        XCTAssertEqual(pending.activeStore.id, originalID)
        XCTAssertEqual(pending.transition?.phase, .merged)
        enable.cancel()
        await gate.resume()
        do {
            _ = try await enable.value
            XCTFail("Cancellation must stop the swap")
        } catch is CancellationError {}

        let failed = try await persistence.snapshot()
        XCTAssertEqual(failed.activeStore.id, originalID)
        XCTAssertNil(failed.transition)
        XCTAssertEqual(try storeRootCount(in: root), 1)
        try await add("saved after cancel", to: source)
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let library = try await reopened.activeLibrary()
        let texts = try await library.checkedSnapshot(sortedBy: .manual).snips.map(\.content)
        XCTAssertEqual(Set(texts), ["kept local", "saved after cancel"])
        let cloud = await server.storedTextValues()
        XCTAssertTrue(cloud.isEmpty)
    }

    func testEditDuringMergeKeepsTheSourceAndTheNextEnableUsesTheEdit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        try await add("original", to: source)
        let originalID = try await persistence.snapshot().activeStore.id
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let gate = CloudApplyGate()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence, namespace: namespace, textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) },
            checkSetupCollection: { try await gate.pause() }
        )
        let enable = Task { try await coordinator.enableOrRetry() }
        await gate.waitUntilPaused()
        do {
            try await add("saved during merge", to: source)
        } catch {
            await gate.resume()
            _ = await enable.result
            throw error
        }
        await gate.resume()
        do {
            _ = try await enable.value
            XCTFail("An edit after the source snapshot must invalidate that candidate")
        } catch SyncModePersistenceError.transitionInProgress {}

        let failed = try await persistence.snapshot()
        XCTAssertEqual(failed.activeStore.id, originalID)
        XCTAssertNil(failed.transition)
        XCTAssertEqual(try storeRootCount(in: root), 1)
        let retry = ICloudSyncModeCoordinator(
            persistence: persistence, namespace: namespace, textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        _ = try await retry.enableOrRetry()
        let texts = try await source.checkedSnapshot(sortedBy: .manual).snips.map(\.content)
        XCTAssertEqual(Set(texts), ["original", "saved during merge"])
    }
}
