import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testEnableFetchesRemoteBeforeExplicitlyEnrollingUniqueLocalRecords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .fullRecordV1)
        let local = try await persistence.activeLibrary()
        try await add("local", to: local)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let remoteID = CloudRecordID(zone: textZone(namespace), name: "remote")
        try await seed("remote", id: remoteID, server: server)
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        let result = try await coordinator.enableOrRetry()

        XCTAssertEqual(result.state, .on)
        let active = try await persistence.activeLibrary()
        let activeTexts = await active.snapshot(sortedBy: .chronological).snips.map(\.content).sorted()
        let serverTexts = await server.storedTextValues()
        XCTAssertEqual(activeTexts, ["local", "remote"])
        XCTAssertEqual(serverTexts, ["local", "remote"])
        XCTAssertEqual(try storeRootCount(in: root), 1)
        let calls = await transport.events()
        let fetchIndex = try XCTUnwrap(calls.firstIndex(of: .fetched))
        let sendIndex = try XCTUnwrap(calls.firstIndex(where: {
            if case .sent = $0 { return true }
            return false
        }))
        XCTAssertLessThan(fetchIndex, sendIndex)
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

    func testOfflineEnableKeepsLocalStoreUsableAndReopenRetriesThePendingTransition() async throws {
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

    func testFailedFirstSendKeepsSourceActiveAndRetryRefetchesFinalWrites() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .fullRecordV1)
        try await add("retry me", to: persistence.activeLibrary())
        let originalID = try await persistence.snapshot().activeStore.id
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let failing = FakeCloudRecordTransport(server: server, namespace: namespace)
        await failing.failNextSend()
        let first = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { failing }
        )

        let failedResult = try await first.enableOrRetry()
        let failedStorage = try await persistence.snapshot()
        XCTAssertEqual(failedResult.state, .settingUp)
        XCTAssertNil(failedResult.attentionReason)
        XCTAssertEqual(failedStorage.activeStore.id, originalID)
        try await add("written after failed send", to: try await persistence.activeLibrary())

        let retryTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let retry = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { retryTransport }
        )
        let retryResult = try await retry.enableOrRetry()
        let serverTexts = await server.storedTextValues()
        XCTAssertEqual(retryResult.state, .on)
        XCTAssertEqual(serverTexts, ["retry me", "written after failed send"])
    }
}
