import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testEnableFetchesRemoteBeforeExplicitlyEnrollingUniqueLocalRecords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
                    .save(
                        .text(
                            id: CloudRecordID(zone: textZone(namespace), name: "same-id"),
                            snipID: sharedID,
                            text: "remote edit"
                        )
                    )
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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

        let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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

    func testRetryablePartialFirstSendThenEditRefetchesAndUpdatesAcceptedShadow() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let source = try await persistence.activeLibrary()
        try await add("edit me", to: source)
        try await add("retry item", to: source)
        let before = await source.snapshot(sortedBy: .chronological)
        let editedID = try XCTUnwrap(before.snips.first(where: { $0.content == "edit me" })?.id)
        let failedID = try XCTUnwrap(before.snips.first(where: { $0.content == "retry item" })?.id)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        let failed = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: failedID
        )
        XCTAssertEqual(failed.state, .settingUp)
        _ = try await source.perform(
            .update(
                id: editedID,
                content: "edited after partial send",
                attachmentURLs: nil,
                expectedUpdatedAt: before.snips.first(where: { $0.id == editedID })?.updatedAt,
                now: Date()
            ),
            sortedBy: .chronological
        )

        let result = try await coordinator.enableOrRetry()
        let active = try await persistence.activeLibrary()
        let texts = await active.snapshot(sortedBy: .chronological).snips.map(\.content).sorted()
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(result.state, .on)
        XCTAssertEqual(texts, ["edited after partial send", "retry item"])
        XCTAssertEqual(remoteTexts, texts)
    }

    func testRetryablePartialFirstSendThenDeleteRefetchesAndDeletesAcceptedShadow() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let source = try await persistence.activeLibrary()
        try await add("delete me", to: source)
        try await add("retry item", to: source)
        let before = await source.snapshot(sortedBy: .chronological)
        let deletedID = try XCTUnwrap(before.snips.first(where: { $0.content == "delete me" })?.id)
        let failedID = try XCTUnwrap(before.snips.first(where: { $0.content == "retry item" })?.id)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        let failed = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: failedID
        )
        XCTAssertEqual(failed.state, .settingUp)
        _ = try await source.perform(.delete(ids: [deletedID]), sortedBy: .chronological)

        let result = try await coordinator.enableOrRetry()
        let active = try await persistence.activeLibrary()
        let texts = await active.snapshot(sortedBy: .chronological).snips.map(\.content)
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(result.state, .on)
        XCTAssertEqual(texts, ["retry item"])
        XCTAssertEqual(remoteTexts, ["retry item"])
    }

    func testTwoPartialSendFailuresRetainProvenanceAcrossEditThenDeleteAndEdit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let source = try await persistence.activeLibrary()
        try await add("settles twice", to: source)
        try await add("fails twice", to: source)
        let before = await source.snapshot(sortedBy: .chronological)
        let settled = try XCTUnwrap(before.snips.first(where: { $0.content == "settles twice" }))
        let failed = try XCTUnwrap(before.snips.first(where: { $0.content == "fails twice" }))
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        _ = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: failed.id
        )
        _ = try await source.perform(
            .update(
                id: settled.id,
                content: "accepted on second send",
                attachmentURLs: nil,
                expectedUpdatedAt: settled.updatedAt,
                now: Date()
            ),
            sortedBy: .chronological
        )
        _ = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: failed.id
        )

        _ = try await source.perform(.delete(ids: [settled.id]), sortedBy: .chronological)
        _ = try await source.perform(
            .update(
                id: failed.id,
                content: "edited after two failures",
                attachmentURLs: nil,
                expectedUpdatedAt: failed.updatedAt,
                now: Date()
            ),
            sortedBy: .chronological
        )
        let result = try await coordinator.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(remoteTexts, ["edited after two failures"])
    }

    func testAcceptedSeedEditThatRetryablyFailsDoesNotAdvanceItsProvenance() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let source = try await persistence.activeLibrary()
        try await add("edit this twice", to: source)
        try await add("first failure", to: source)
        let before = await source.snapshot(sortedBy: .chronological)
        let edited = try XCTUnwrap(before.snips.first(where: { $0.content == "edit this twice" }))
        let firstFailureID = try XCTUnwrap(
            before.snips.first(where: { $0.content == "first failure" })?.id
        )
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        _ = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: firstFailureID
        )
        _ = try await source.perform(
            .update(
                id: edited.id,
                content: "edit must retry",
                attachmentURLs: nil,
                expectedUpdatedAt: edited.updatedAt,
                now: Date()
            ),
            sortedBy: .chronological
        )
        let failedEdit = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: edited.id
        )
        XCTAssertEqual(failedEdit.state, .settingUp)

        let result = try await coordinator.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(remoteTexts.sorted(), ["edit must retry", "first failure"])
    }

    func testAcceptedSeedDeleteThatRetryablyFailsDoesNotAdvanceItsProvenance() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let source = try await persistence.activeLibrary()
        try await add("delete must retry", to: source)
        try await add("first failure", to: source)
        let before = await source.snapshot(sortedBy: .chronological)
        let deletedID = try XCTUnwrap(
            before.snips.first(where: { $0.content == "delete must retry" })?.id
        )
        let firstFailureID = try XCTUnwrap(
            before.snips.first(where: { $0.content == "first failure" })?.id
        )
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        _ = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: firstFailureID
        )
        _ = try await source.perform(.delete(ids: [deletedID]), sortedBy: .chronological)
        let failedDelete = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: deletedID
        )
        XCTAssertEqual(failedDelete.state, .settingUp)

        let result = try await coordinator.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(remoteTexts, ["first failure"])
    }

    func testRetryablePartialFirstSendThenRemoteOnlyEditWinsOnFreshFetch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let source = try await persistence.activeLibrary()
        try await add("remote wins", to: source)
        try await add("retry item", to: source)
        let before = await source.snapshot(sortedBy: .chronological)
        let remoteID = try XCTUnwrap(before.snips.first(where: { $0.content == "remote wins" })?.id)
        let failedID = try XCTUnwrap(before.snips.first(where: { $0.content == "retry item" })?.id)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        _ = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: failedID
        )
        let recordID = try await cloudRecordID(
            for: remoteID,
            persistence: persistence,
            namespace: namespace
        )
        try await editRemote(
            recordID: recordID,
            snipID: remoteID,
            text: "edited on another device",
            server: server
        )

        let result = try await coordinator.enableOrRetry()
        let texts = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological).snips.map(\.content).sorted()
        XCTAssertEqual(result.state, .on)
        XCTAssertEqual(texts, ["edited on another device", "retry item"])
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(remoteTexts, texts)
    }

    func testRetryablePartialFirstSendCombinesLocalMetadataWithRemoteText() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let source = try await persistence.activeLibrary()
        try await add("combine", to: source)
        try await add("retry item", to: source)
        let before = await source.snapshot(sortedBy: .chronological)
        let combinedID = try XCTUnwrap(before.snips.first(where: { $0.content == "combine" })?.id)
        let failedID = try XCTUnwrap(before.snips.first(where: { $0.content == "retry item" })?.id)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        _ = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: failedID
        )
        let recordID = try await cloudRecordID(
            for: combinedID,
            persistence: persistence,
            namespace: namespace
        )
        try await editRemote(
            recordID: recordID,
            snipID: combinedID,
            text: "remote text",
            server: server
        )
        _ = try await source.perform(
            .setDone(ids: [combinedID], done: true),
            sortedBy: .chronological
        )

        let result = try await coordinator.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let active = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        let combined = try XCTUnwrap(active.snips.first(where: { $0.id == combinedID }))
        XCTAssertEqual(combined.content, "remote text")
        XCTAssertTrue(combined.isDone)
    }

    func testRetryablePartialFirstSendThenDivergentLocalAndRemoteEditsNeedAttention() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let source = try await persistence.activeLibrary()
        try await add("diverge", to: source)
        try await add("retry item", to: source)
        let before = await source.snapshot(sortedBy: .chronological)
        let changed = try XCTUnwrap(before.snips.first(where: { $0.content == "diverge" }))
        let failedID = try XCTUnwrap(before.snips.first(where: { $0.content == "retry item" })?.id)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        _ = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: failedID
        )
        let recordID = try await cloudRecordID(
            for: changed.id,
            persistence: persistence,
            namespace: namespace
        )
        try await editRemote(
            recordID: recordID,
            snipID: changed.id,
            text: "remote edit",
            server: server
        )
        _ = try await source.perform(
            .update(
                id: changed.id,
                content: "local edit",
                attachmentURLs: nil,
                expectedUpdatedAt: changed.updatedAt,
                now: Date()
            ),
            sortedBy: .chronological
        )

        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("Divergent two-sided edits must not choose a winner.")
        } catch SnipLibraryError.transferConflict(.snipIdentity(let id)) {
            XCTAssertEqual(id, changed.id)
        }
        let status = try await coordinator.status()
        XCTAssertEqual(status.state, .needsAttention)
        XCTAssertEqual(status.attentionReason, .transferConflict)
        let remoteTexts = await server.storedTextValues().sorted()
        XCTAssertEqual(remoteTexts, ["remote edit"])
        let local = await source.snapshot(sortedBy: .chronological).snips.map(\.content).sorted()
        XCTAssertEqual(local, ["local edit", "retry item"])
    }

    func testRetrySettlementTracksOnlyRecordsSentInTheCurrentAttempt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let source = try await persistence.activeLibrary()
        try await add("source A", to: source)
        try await add("source B", to: source)
        let sourceSnapshot = await source.snapshot(sortedBy: .chronological)
        let aID = try XCTUnwrap(sourceSnapshot.snips.first(where: { $0.content == "source A" })?.id)
        let bID = try XCTUnwrap(sourceSnapshot.snips.first(where: { $0.content == "source B" })?.id)
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )

        let first = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: bID
        )
        XCTAssertEqual(first.state, .settingUp)
        let aRecordID = try await cloudRecordID(
            for: aID,
            persistence: persistence,
            namespace: namespace
        )
        let bRecordID = try await cloudRecordID(
            for: bID,
            persistence: persistence,
            namespace: namespace
        )
        try await editRemote(
            recordID: aRecordID,
            snipID: aID,
            text: "remote A",
            server: server
        )

        let second = try await failFirstSendRetryably(
            coordinator: coordinator,
            persistence: persistence,
            transport: transport,
            namespace: namespace,
            failedSnipID: bID
        )
        XCTAssertEqual(second.state, .settingUp)
        let sentRecordBatches = await transport.events().compactMap { event -> [CloudRecordID]? in
            guard case .sent(let recordIDs) = event, !recordIDs.isEmpty else { return nil }
            return recordIDs
        }
        XCTAssertEqual(sentRecordBatches.last, [bRecordID])

        let third = try await coordinator.enableOrRetry()
        XCTAssertEqual(third.state, .on)
        let activeTexts = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological).snips.map(\.content).sorted()
        let serverTexts = await server.storedTextValues()
        let acceptedACount = await server.acceptedOperationCount(for: aRecordID)
        XCTAssertEqual(activeTexts, ["remote A", "source B"])
        XCTAssertEqual(serverTexts, activeTexts)
        XCTAssertEqual(acceptedACount, 2)
    }

}
