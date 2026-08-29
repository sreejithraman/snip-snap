import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

final class ICloudSyncModeCoordinatorTests: XCTestCase {
    func testEnableFetchesRemoteBeforeExplicitlyEnrollingUniqueLocalRecords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        XCTAssertEqual(offlineStorage.activeStore.id, originalID)
        XCTAssertEqual(localTexts, ["kept local"])

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let cloudStoreID = try await persistence.snapshot().activeStore.id
        let callsBefore = await transport.events()

        let canceled = try await coordinator.optOut(.cancel)
        let afterCancel = try await persistence.snapshot()
        let optedOut = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        let deletionCount = await server.acceptedDeletionCount()
        let callsAfter = await transport.events()
        XCTAssertEqual(canceled.state, .on)
        XCTAssertEqual(afterCancel.activeStore.id, cloudStoreID)
        XCTAssertEqual(optedOut.state, .off)
        XCTAssertEqual(deletionCount, 0)
        XCTAssertEqual(callsAfter, callsBefore)
        let active = try await persistence.activeLibrary()
        let copiedTexts = await active.snapshot(sortedBy: .chronological).snips.map(\.content)
        XCTAssertEqual(copiedTexts, ["cached"])
    }

    func testCrashBeforePointerSwapLeavesAResumableBootstrapAndAfterSwapLeavesCloudActive() async throws {
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
        XCTAssertEqual(crashed.transition?.phase, .candidateReady)
        XCTAssertEqual(sentBeforeSwap, ["durable"])

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
        XCTAssertEqual(final.transition?.phase, .pointerSwapped)
    }

    func testCrashAfterCandidateMergeDurabilityReopensWithoutStrandingLocalEnrollment() async throws {
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
        XCTAssertEqual(crashed.transition?.phase, .candidateReady)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let result = try await retry.enableOrRetry()
        let serverTexts = await server.storedTextValues()
        XCTAssertEqual(result.state, .on)
        XCTAssertEqual(serverTexts, ["survives merge crash"])
    }

    func testMergeIntentOwnsAppliedCandidateAcrossProcessDeathAndFreshSourceChanges() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let firstAttachment = inputs.appendingPathComponent("first.txt")
        let secondAttachment = inputs.appendingPathComponent("second.txt")
        try Data("first bytes".utf8).write(to: firstAttachment, options: .atomic)
        try Data("second bytes".utf8).write(to: secondAttachment, options: .atomic)

        let crash = CrashInjector(point: .afterCandidateMergeDurability)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
        let source = try await persistence.activeLibrary()
        let list = try await createList("Before Crash", systemImage: "circle", in: source)
        _ = try await source.perform(
            .add(
                content: "attachment survives",
                origin: .quickEntry,
                source: nil,
                listID: list.id,
                attachmentURLs: [firstAttachment],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        try await add("delete after reopen", to: source)
        let before = await source.snapshot(sortedBy: .chronological)
        let attached = try XCTUnwrap(
            before.snips.first(where: { $0.content == "attachment survives" })
        )
        let deletedID = try XCTUnwrap(
            before.snips.first(where: { $0.content == "delete after reopen" })?.id
        )

        _ = try await persistence.beginTransition(
            to: .iCloudSync,
            namespace: testBinding()
        )
        try await persistence.recordPreparationComplete()
        let token = try await persistence.freezeSource()
        let frozen = try await persistence.finalSnapshot(using: token)
        do {
            _ = try await persistence.mergeFinalSnapshot(frozen, using: token)
            XCTFail("Expected process death after the candidate write.")
        } catch CrashInjector.Failure.injected {}
        let interrupted = try await persistence.snapshot()
        XCTAssertEqual(interrupted.transition?.phase, .sourceFrozen)
        XCTAssertNotNil(interrupted.transition?.mergeIntent)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let recovered = try await reopened.snapshot()
        XCTAssertEqual(recovered.transition?.phase, .candidateReady)
        XCTAssertNil(recovered.transition?.mergeIntent)
        XCTAssertTrue(recovered.transition?.seededListIDs.contains(list.id) == true)
        let reopenedSource = try await reopened.activeLibrary()
        _ = try await reopenedSource.perform(
            .delete(ids: [deletedID]),
            sortedBy: .chronological
        )
        _ = try await reopenedSource.perform(
            .updateList(id: list.id, name: "After Reopen", systemImage: "checkmark.circle"),
            sortedBy: .chronological
        )
        _ = try await reopenedSource.perform(
            .update(
                id: attached.id,
                content: attached.content,
                attachmentURLs: [secondAttachment],
                expectedUpdatedAt: attached.updatedAt,
                now: Date()
            ),
            sortedBy: .chronological
        )

        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let result = try await retry.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let active = try await reopened.activeLibrary()
        let snapshot = try await active.checkedSnapshot(sortedBy: .manual)
        XCTAssertNil(snapshot.snips.first(where: { $0.id == deletedID }))
        XCTAssertEqual(
            snapshot.lists.first(where: { $0.id == list.id }),
            SnipList(
                id: list.id,
                name: "After Reopen",
                systemImage: "checkmark.circle",
                position: list.position
            )
        )
        let finalSnip = try XCTUnwrap(snapshot.snips.first(where: { $0.id == attached.id }))
        let finalAttachment = try XCTUnwrap(finalSnip.attachments.first)
        let finalURL = try XCTUnwrap(snapshot.attachmentURLs[finalAttachment.id])
        XCTAssertEqual(try Data(contentsOf: finalURL), Data("second bytes".utf8))
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(remoteTexts, ["attachment survives"])
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

    func testFreezeIncludesPriorWritesRejectsLaterWritesAndSurvivesReopen() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let managed = try await persistence.activeLibrary()
        _ = try await persistence.beginTransition(to: .iCloudSync, namespace: testBinding())
        try await persistence.recordPreparationComplete()
        try await add("before freeze", to: managed)

        let token = try await persistence.freezeSource()
        XCTAssertEqual(token.revision, 1)
        do {
            try await add("too late", to: managed)
            XCTFail("A write must not succeed while the source is frozen.")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .modeTransitionInProgress)
        }
        let final = try await persistence.finalSnapshot(using: token)
        XCTAssertEqual(final.snips.map(\.content), ["before freeze"])
        _ = try await persistence.mergeFinalSnapshot(final, using: token)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let reopenedStorage = try await reopened.snapshot()
        XCTAssertEqual(reopenedStorage.transition?.phase, .candidateReady)
        try await add("after unfreeze", to: await reopened.activeLibrary())
    }

    func testEveryPreSwapFrozenPhaseReopensWritableAndRefetchesAfterEditOrDelete() async throws {
        let phases: [SyncModeTransitionPhase] = [
            .sourceFrozen, .recordsMerged, .enrollmentApproved, .firstSendStarted,
            .firstSendComplete,
        ]
        for phase in phases {
            for deletes in [false, true] {
                let root = temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let persistence = try SwiftDataSyncModePersistence(rootURL: root)
                let source = try await persistence.activeLibrary()
                try await add("base", to: source)
                let sourceSnapshot = await source.snapshot(sortedBy: .chronological)
                let original = try XCTUnwrap(sourceSnapshot.snips.first)
                _ = try await persistence.beginTransition(
                    to: .iCloudSync,
                    namespace: testBinding()
                )
                try await persistence.recordPreparationComplete()
                let token = try await persistence.freezeSource()
                if phase != .sourceFrozen {
                    let frozen = try await persistence.finalSnapshot(using: token)
                    let result = try await persistence.mergeFinalSnapshot(frozen, using: token)
                    if phase != .recordsMerged {
                        try await persistence.recordEnrollmentApproved(
                            expected: result.approvedSnipIDs
                        )
                    }
                    if phase == .firstSendStarted || phase == .firstSendComplete {
                        try await persistence.recordFirstSendStarted()
                    }
                    if phase == .firstSendComplete {
                        try await persistence.recordFirstSendComplete()
                    }
                }
                let beforeReopen = try await persistence.snapshot()
                XCTAssertEqual(beforeReopen.transition?.phase, phase)

                let reopened = try SwiftDataSyncModePersistence(rootURL: root)
                let afterReopen = try await reopened.snapshot()
                XCTAssertEqual(afterReopen.transition?.phase, .candidateReady)
                let reopenedSource = try await reopened.activeLibrary()
                if deletes {
                    _ = try await reopenedSource.perform(
                        .delete(ids: [original.id]),
                        sortedBy: .chronological
                    )
                } else {
                    _ = try await reopenedSource.perform(
                        .update(
                            id: original.id,
                            content: "edited after \(phase.rawValue)",
                            attachmentURLs: nil,
                            expectedUpdatedAt: original.updatedAt,
                            now: Date()
                        ),
                        sortedBy: .chronological
                    )
                }
                let server = FakeCloudServer()
                let namespace = makeNamespace()
                let coordinator = ICloudSyncModeCoordinator(
                    persistence: reopened,
                    namespace: namespace,
                    textZone: textZone(namespace),
                    makeTransport: {
                        FakeCloudRecordTransport(server: server, namespace: namespace)
                    }
                )
                let result = try await coordinator.enableOrRetry()
                XCTAssertEqual(result.state, .on, "phase=\(phase), deletes=\(deletes)")
                let expected = deletes ? [] : ["edited after \(phase.rawValue)"]
                let remoteTexts = await server.storedTextValues()
                XCTAssertEqual(remoteTexts, expected)
            }
        }
    }

    func testListRenameDeleteAndAdditionReplaceOnlySeededCandidateListsOnRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        let renamedID = try await createList("Rename Me", systemImage: "pencil", in: source).id
        let deletedID = try await createList("Delete Me", systemImage: "trash", in: source).id
        try await add("accepted", to: source)
        try await add("fails", to: source)
        let sourceSnips = await source.snapshot(sortedBy: .chronological).snips
        let failedID = try XCTUnwrap(sourceSnips.first(where: { $0.content == "fails" })?.id)
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
        let failedStorage = try await persistence.snapshot()
        let transition = try XCTUnwrap(failedStorage.transition)
        let candidate = try await persistence.libraryForTransition(storeID: transition.candidateStoreID)
        let targetOnly = try await createList(
            "Target Only",
            systemImage: "cloud",
            in: candidate
        )

        _ = try await source.perform(
            .updateList(id: renamedID, name: "Renamed", systemImage: "checkmark"),
            sortedBy: .chronological
        )
        _ = try await source.perform(.deleteList(id: deletedID), sortedBy: .chronological)
        let added = try await createList("Added Later", systemImage: "plus", in: source)
        let expectedSource = await source.snapshot(sortedBy: .chronological).lists

        let result = try await coordinator.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let actual = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological).lists
        XCTAssertEqual(actual.first(where: { $0.id == renamedID }), expectedSource.first {
            $0.id == renamedID
        })
        XCTAssertNil(actual.first(where: { $0.id == deletedID }))
        XCTAssertEqual(actual.first(where: { $0.id == added.id }), added)
        XCTAssertEqual(actual.first(where: { $0.id == targetOnly.id }), targetOnly)
        let expectedSeededOrder = expectedSource.map(\.id).filter { $0 != SnipList.inboxID }
        let actualSeededOrder = actual.map(\.id).filter { expectedSeededOrder.contains($0) }
        XCTAssertEqual(actualSeededOrder, expectedSeededOrder)
    }

    func testSeededListChangesSurviveHardReopenBeforeRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        let renamedID = try await createList("Before", systemImage: "circle", in: source).id
        let deletedID = try await createList("Remove", systemImage: "xmark", in: source).id
        _ = try await persistence.beginTransition(to: .iCloudSync, namespace: testBinding())
        try await persistence.recordPreparationComplete()
        let token = try await persistence.freezeSource()
        let frozen = try await persistence.finalSnapshot(using: token)
        _ = try await persistence.mergeFinalSnapshot(frozen, using: token)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let reopenedSource = try await reopened.activeLibrary()
        _ = try await reopenedSource.perform(
            .updateList(id: renamedID, name: "After", systemImage: "checkmark.circle"),
            sortedBy: .chronological
        )
        _ = try await reopenedSource.perform(.deleteList(id: deletedID), sortedBy: .chronological)
        let added = try await createList("New After Reopen", systemImage: "plus.circle", in: reopenedSource)
        let expected = await reopenedSource.snapshot(sortedBy: .chronological).lists
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )

        let result = try await coordinator.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let actual = await (try await reopened.activeLibrary())
            .snapshot(sortedBy: .chronological).lists
        XCTAssertEqual(actual.first(where: { $0.id == renamedID }), expected.first {
            $0.id == renamedID
        })
        XCTAssertNil(actual.first(where: { $0.id == deletedID }))
        XCTAssertEqual(actual.first(where: { $0.id == added.id }), added)
    }

    func testFreezeTokenIsRevisionScopedAndSingleUse() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        _ = try await persistence.beginTransition(to: .iCloudSync, namespace: testBinding())
        try await persistence.recordPreparationComplete()
        let token = try await persistence.freezeSource()
        _ = try await persistence.finalSnapshot(using: token)
        do {
            _ = try await persistence.finalSnapshot(using: token)
            XCTFail("A freeze token must be single use.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .invalidFreezeToken)
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

    func testSendAttemptManifestFailureStopsTransportBeforeAnyBatchLeaves() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FailNextManifestWriter()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: writer.armAtSendAttempt,
            manifestWriter: writer.write
        )
        let source = try await persistence.activeLibrary()
        try await add("must not send", to: source)
        let sourceStoreID = try await persistence.snapshot().activeStore.id
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
            XCTFail("The send-attempt manifest write must fail.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
        }
        let sent = await transport.events().contains { event in
            if case .sent = event { return true }
            return false
        }
        let storage = try await persistence.snapshot()
        XCTAssertFalse(sent)
        XCTAssertEqual(storage.activeStore.id, sourceStoreID)
        try await add("source remains writable", to: source)
    }

    func testEnrollmentApprovalCrashReappliesApprovalAfterReopen() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let injector = CrashInjector(point: .afterEnrollmentApproval)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, crashHook: injector.hit)
        try await add("approved once", to: await persistence.activeLibrary())
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let first = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        do {
            _ = try await first.enableOrRetry()
            XCTFail("Expected the approval crash.")
        } catch CrashInjector.Failure.injected {}
        let crashed = try await persistence.snapshot()
        XCTAssertEqual(crashed.transition?.phase, .remoteFetched)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let result = try await retry.enableOrRetry()
        let serverTexts = await server.storedTextValues()
        XCTAssertEqual(result.state, .on)
        XCTAssertEqual(serverTexts, ["approved once"])
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
                _ = try await coordinator.status()
                XCTFail("A mismatched namespace must not reopen the prior cache.")
            } catch {
                XCTAssertEqual(error as? SyncModePersistenceError, .namespaceMismatch)
            }
            do {
                _ = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
                XCTFail("A mismatched namespace must not copy the prior cache.")
            } catch {
                XCTAssertEqual(error as? SyncModePersistenceError, .namespaceMismatch)
            }
        }
    }

    func testStatusReadsSettingUpWhileEnableWaitsForRemoteFetch() async throws {
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, writeHook: gate.hit)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, writeHook: crash.hit)
        do {
            try await add("not committed", to: try await persistence.activeLibrary())
            XCTFail("Expected the write crash.")
        } catch WriteCrashInjector.Failure.injected {}
        let crashedStorage = try await persistence.snapshot()
        XCTAssertEqual(crashedStorage.activeStore.revision, 1)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
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
        XCTAssertEqual(failed.transition?.phase, .remoteFetched)
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
            rootURL: root,
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
            rootURL: root,
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

    private func failFirstSendRetryably(
        coordinator: ICloudSyncModeCoordinator,
        persistence: SwiftDataSyncModePersistence,
        transport: FakeCloudRecordTransport,
        namespace: CloudSyncNamespace,
        failedSnipID: UUID
    ) async throws -> ICloudSyncModeStatus {
        await transport.pauseNextSend()
        let enable = Task { try await coordinator.enableOrRetry() }
        await transport.waitUntilSendPauses()
        let storage = try await persistence.snapshot()
        let transition = try XCTUnwrap(storage.transition)
        let candidate = try await persistence.libraryForTransition(
            storeID: transition.candidateStoreID
        )
        let cloud = try await candidate.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
        let failed = try XCTUnwrap(cloud.records.first(where: { $0.snipID == failedSnipID }))
        await transport.failNextSentItem(
            CloudRecordID(
                zone: CloudZoneID(name: failed.identity.zoneName, ownerName: failed.identity.ownerName),
                name: failed.identity.recordName
            ),
            failure: .retryable
        )
        await transport.resumeSend()
        return try await enable.value
    }

    private func add(_ text: String, to library: any SnipLibrary) async throws {
        _ = try await library.perform(
            .add(
                content: text,
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

    private func createList(
        _ name: String,
        systemImage: String,
        in library: any SnipLibrary
    ) async throws -> SnipList {
        let update = try await library.perform(
            .createList(name: name, systemImage: systemImage),
            sortedBy: .chronological
        )
        guard case .listCreated(let list) = update.outcome else {
            throw SnipLibraryError.invalidStore
        }
        return list
    }

    private func seed(_ text: String, id: CloudRecordID, server: FakeCloudServer) async throws {
        let writer = FakeCloudRecordTransport(server: server)
        _ = try await writer.send(
            CloudOutboundBatch(
                operations: [
                    .save(.text(id: id, snipID: UUID(), text: text))
                ]
            )
        )
    }

    private func cloudRecordID(
        for snipID: UUID,
        persistence: SwiftDataSyncModePersistence,
        namespace: CloudSyncNamespace
    ) async throws -> CloudRecordID {
        let storage = try await persistence.snapshot()
        let transition = try XCTUnwrap(storage.transition)
        let candidate = try await persistence.libraryForTransition(
            storeID: transition.candidateStoreID
        )
        let cloud = try await candidate.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
        let record = try XCTUnwrap(cloud.records.first(where: { $0.snipID == snipID }))
        return CloudRecordID(
            zone: CloudZoneID(name: record.identity.zoneName, ownerName: record.identity.ownerName),
            name: record.identity.recordName
        )
    }

    private func editRemote(
        recordID: CloudRecordID,
        snipID: UUID,
        text: String,
        server: FakeCloudServer
    ) async throws {
        let remote = try await server.snapshot(
            for: recordID,
            fields: ["schemaVersion", "snipID", "text"]
        )
        let current = try XCTUnwrap(remote)
        let writer = FakeCloudRecordTransport(server: server)
        let sent = try await writer.send(
            CloudOutboundBatch(
                operations: [
                    .save(.text(id: recordID, snipID: snipID, text: text, base: current.shadow))
                ]
            )
        )
        guard sent.items.count == 1, case .saved = sent.items[0] else {
            XCTFail("The remote edit was not accepted.")
            return
        }
    }

    private func makeNamespace() -> CloudSyncNamespace {
        CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            zones: [CloudZoneID(name: "metadata", ownerName: "owner")]
        )
    }

    private func textZone(_ namespace: CloudSyncNamespace) -> CloudZoneID {
        namespace.zones.first!
    }

    private func testBinding() -> ICloudSyncNamespaceBinding {
        let namespace = makeNamespace()
        return ICloudSyncNamespaceBinding(
            scope: namespace.cloudScope,
            accountLineage: namespace.accountLineage,
            generation: namespace.generation,
            zones: Set(namespace.zones.map {
                ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
            })
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudSyncModeCoordinatorTests-\(UUID().uuidString)")
    }

    private func storeRootCount(in root: URL) throws -> Int {
        let stores = root.appendingPathComponent("stores", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: stores,
            includingPropertiesForKeys: nil
        ).count
    }
}

private actor CloudApplyGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func pause() async throws {
        paused = true
        waiters.forEach { $0.resume() }
        waiters = []
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        release?.resume()
        release = nil
        paused = false
    }
}

private final class CrashInjector: @unchecked Sendable {
    enum Failure: Error { case injected }

    private let lock = NSLock()
    private let point: SyncModeCrashPoint
    private var didFail = false

    init(point: SyncModeCrashPoint) { self.point = point }

    func hit(_ point: SyncModeCrashPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard point == self.point, !didFail else { return }
        didFail = true
        throw Failure.injected
    }
}

private final class FailingManifestWriter: @unchecked Sendable {
    enum Failure: Error { case injected }

    private let lock = NSLock()
    var failWrites = false

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        let shouldFail = failWrites
        lock.unlock()
        if shouldFail { throw Failure.injected }
        try data.write(to: url, options: .atomic)
    }
}

private actor WriteReservationGate {
    private var reserved = false
    private var reservationWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func hit(_ point: SyncModeWritePoint) async throws {
        guard point == .afterRevisionReserved else { return }
        reserved = true
        reservationWaiters.forEach { $0.resume() }
        reservationWaiters = []
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilReserved() async {
        if reserved { return }
        await withCheckedContinuation { reservationWaiters.append($0) }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

private actor WriteCrashInjector {
    enum Failure: Error { case injected }
    private var didFail = false

    func hit(_ point: SyncModeWritePoint) async throws {
        guard point == .afterRevisionReserved else { return }
        guard !didFail else { return }
        didFail = true
        throw Failure.injected
    }
}

private final class ReadFailureInjector: @unchecked Sendable {
    enum Failure: Error { case injected }
    private let lock = NSLock()
    private var value = false

    var shouldFail: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func check() throws {
        if lock.withLock({ value }) { throw Failure.injected }
    }
}

private final class FailNextManifestWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failNext = false

    func armAtPointer(_ point: SyncModeCrashPoint) {
        guard point == .beforePointerSwap else { return }
        lock.withLock { failNext = true }
    }

    func armAtSendAttempt(_ point: SyncModeCrashPoint) {
        guard point == .beforeSendAttemptManifest else { return }
        lock.withLock { failNext = true }
    }

    func armAtWriteClear(_ point: SyncModeWritePoint) async throws {
        guard point == .beforeReservationCleared else { return }
        lock.withLock { failNext = true }
    }

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            defer { failNext = false }
            return failNext
        }
        if shouldFail { throw FailingManifestWriter.Failure.injected }
        try data.write(to: url, options: .atomic)
    }
}
