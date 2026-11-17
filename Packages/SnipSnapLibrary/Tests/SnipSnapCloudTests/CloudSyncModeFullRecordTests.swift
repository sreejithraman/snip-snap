import CryptoKit
import SwiftData
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testFullReenableCanRetryAfterItsFirstSendWasRejected() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        try await add("before opting out", to: try await persistence.activeLibrary())
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let initial = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        _ = try await initial.enableOrRetry()
        _ = try await initial.optOut(.useCurrentCacheAfterStaleDataWarning)
        let local = try await persistence.activeLibrary()
        let before = try await local.checkedSnapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(before.snips.first)
        _ = try await local.perform(
            .update(
                id: snip.id,
                content: "offline edit survives retry",
                attachmentURLs: nil,
                expectedUpdatedAt: snip.updatedAt,
                now: Date(timeIntervalSince1970: 60)
            ),
            sortedBy: .manual
        )
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.failNextSentItem(.snip(snip.id, in: zone), failure: .rejected)
        let reenable = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { transport }
        )
        do {
            _ = try await reenable.enableOrRetry()
            XCTFail("The rejected re-enable send must be reported")
        } catch let error as CloudSyncIssueError {
            XCTAssertEqual(error.issue, .appDataIssue)
        }
        let interrupted = try await persistence.snapshot()
        XCTAssertEqual(interrupted.transition?.phase, .candidateReady)
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )

        let waitingForChoice = try await retry.enableOrRetry()

        let review = try await SnipSyncModeStore(reopened).failedEnableReview.snapshot()
        XCTAssertEqual(review.sourceStoreID, interrupted.activeStore.id)
        let issue = try XCTUnwrap(
            review.issues.first { $0.entityID == .snip(snip.id) },
            "The checked rejected-value retry must durably expose its local setup alternative"
        )
        guard case .snip(let localVersion)? = issue.localVersionAtReview else {
            return XCTFail("The setup comparison must retain the source snip")
        }
        XCTAssertEqual(localVersion.id, snip.id)
        XCTAssertEqual(localVersion.content, "offline edit survives retry")
        XCTAssertFalse(localVersion.isDone)
        let retainedBundle = try FailedEnableEvidenceFile(root: root)
            .read(interrupted.activeStore.id)
        let retained = try XCTUnwrap(retainedBundle)
        let storedIssue = try XCTUnwrap(retained.namespaces.flatMap(\.reviews).first {
            $0.reference.kind == .snip
                && $0.reference.domainID == snip.id.uuidString.lowercased()
        })
        XCTAssertEqual(issue.id.uuidString.lowercased(), storedIssue.id)

        XCTAssertEqual(waitingForChoice.state, .needsAttention)
        XCTAssertEqual(issue.reason, .unknownOutcome)
        XCTAssertEqual(issue.allowedChoices, [.useDevice])
        guard case .snip(let serverVersion)? = issue.serverFieldsAtReview else {
            return XCTFail("The checked iCloud fields must be visible for comparison")
        }
        XCTAssertEqual(serverVersion.content, "before opting out")
        let sourceBeforeChoice = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        let storageBeforeChoice = try await reopened.snapshot()
        let chosen = try await SnipSyncModeStore(reopened).failedEnableReview.choose(
            issue.id, selection: .useDevice, expecting: issue.expectation
        )
        XCTAssertEqual(chosen.selection, .useDevice)
        XCTAssertTrue(chosen.outputs.isEmpty)
        let storageAfterChoice = try await reopened.snapshot()
        let sourceAfterChoice = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(storageAfterChoice, storageBeforeChoice)
        XCTAssertEqual(sourceAfterChoice.snips, sourceBeforeChoice.snips)
        let result = try await retry.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let final = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [snip.id])
        XCTAssertEqual(final.snips.first?.content, "offline edit survives retry")
        XCTAssertEqual(final.snips.first?.isDone, false)
        let completedStorage = try await reopened.snapshot()
        XCTAssertNil(completedStorage.transition)
        let activeStore = try await reopened.libraryForTransition(storeID: completedStorage.activeStore.id)
        let activeRecovery = try await activeStore.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
        XCTAssertFalse(activeRecovery.contains { $0.kind == .terminalSend })
        let remoteText = await server.storedTextValues()
        XCTAssertEqual(remoteText, ["offline edit survives retry"])
        let remoteValue = await server.fullSnapshot(for: .snip(snip.id, in: zone))
        let remoteSnapshot = try XCTUnwrap(remoteValue)
        let remote = try CloudFullRecordCodec.snip(from: remoteSnapshot)
        XCTAssertEqual(remote.domainID, snip.id)
        XCTAssertEqual(remote.text, .value("offline edit survives retry"))
        XCTAssertEqual(remote.isDone, .value(false))
        XCTAssertEqual(remote.source, .value(nil))
        XCTAssertNil(final.snips.first?.source)
    }

    func testFullRecordEnableRetryClearsTerminalSendFailure() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        try await add("retry rejected send", to: source)
        let local = await source.snapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(local.snips.first)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.failNextSentItem(.snip(snip.id, in: zone), failure: .rejected)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { transport }
        )

        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("The first rejected send must be reported")
        } catch let error as CloudSyncIssueError {
            XCTAssertEqual(error.issue, .appDataIssue)
        }
        let interrupted = try await persistence.snapshot()
        XCTAssertEqual(interrupted.transition?.phase, .candidateReady)
        let candidate = try await persistence.libraryForTransition(
            storeID: try XCTUnwrap(interrupted.transition?.candidateStoreID)
        )
        let failedRecovery = try await candidate.cloudFullRecoveryEvents(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertEqual(failedRecovery.map(\.kind), [.terminalSend])

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )

        let waiting = try await retry.enableOrRetry()
        XCTAssertEqual(waiting.state, .needsAttention)
        let facade = SnipSyncModeStore(reopened).failedEnableReview
        let reviews = try await facade.snapshot()
        XCTAssertEqual(reviews.issues.map(\.entityID), [.snip(snip.id)])
        let issue = try XCTUnwrap(reviews.issues.first { $0.entityID == .snip(snip.id) })
        XCTAssertEqual(issue.reason, .unknownOutcome)
        XCTAssertEqual(issue.serverState, .absent)
        XCTAssertNil(issue.serverFieldsAtReview)
        XCTAssertEqual(issue.allowedChoices, [.recoverAsNew])
        XCTAssertTrue(issue.earlierLocalVersions.isEmpty)
        guard case .snip(let localVersion)? = issue.localVersionAtReview else {
            return XCTFail("Expected the retained local snip")
        }
        XCTAssertEqual(localVersion.id, snip.id)
        XCTAssertEqual(localVersion.requestID, snip.requestID)
        XCTAssertEqual(localVersion.content, "retry rejected send")
        XCTAssertFalse(localVersion.isDone)
        XCTAssertEqual(localVersion.listID, SnipList.inbox.id)
        XCTAssertTrue(localVersion.attachments.isEmpty)
        let sourceBeforeChoice = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        let storageBeforeChoice = try await reopened.snapshot()
        let chosen = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        XCTAssertEqual(chosen.issueID, issue.id)
        XCTAssertEqual(chosen.selection, .recoverAsNew)
        XCTAssertEqual(chosen.outputs.count, 1)
        let mapping = try XCTUnwrap(chosen.outputs.first)
        XCTAssertEqual(mapping.original, .snip(snip.id))
        guard case .snip(let outputID) = mapping.output else { return XCTFail("Expected a snip output") }
        let outputRequestID = try XCTUnwrap(mapping.requestID)
        XCTAssertEqual(Set([outputID, outputRequestID]).count, 2)
        let originalIDs = Set(local.snips.flatMap { [$0.id, $0.requestID] } + local.lists.map(\.id))
        XCTAssertTrue(Set([outputID, outputRequestID]).isDisjoint(with: originalIDs))
        XCTAssertTrue(mapping.attachments.isEmpty)
        let repeated = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        XCTAssertEqual(repeated, chosen)
        let storageAfterChoice = try await reopened.snapshot()
        let sourceAfterChoice = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(storageAfterChoice, storageBeforeChoice)
        XCTAssertEqual(sourceAfterChoice.snips, sourceBeforeChoice.snips)
        XCTAssertEqual(sourceAfterChoice.lists, sourceBeforeChoice.lists)

        let retried = try await retry.enableOrRetry()
        XCTAssertEqual(retried.state, .on)
        let completed = try await reopened.snapshot()
        XCTAssertNil(completed.transition)
        let active = try await reopened.libraryForTransition(storeID: completed.activeStore.id)
        let localAfterRetry = await active.snapshot(sortedBy: .manual)
        XCTAssertEqual(localAfterRetry.snips.count, 1)
        XCTAssertEqual(localAfterRetry.snips.map(\.id), [outputID])
        XCTAssertEqual(localAfterRetry.snips.first?.id, outputID)
        XCTAssertEqual(localAfterRetry.snips.first?.requestID, outputRequestID)
        XCTAssertEqual(localAfterRetry.snips.first?.content, "retry rejected send")
        XCTAssertEqual(localAfterRetry.snips.first?.isDone, false)
        XCTAssertEqual(localAfterRetry.snips.first?.listID, SnipList.inbox.id)
        XCTAssertFalse(localAfterRetry.snips.contains { $0.id == snip.id })
        let recovery = try await active.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(recovery.isEmpty)
        let remoteText = await server.storedTextValues()
        XCTAssertEqual(remoteText, ["retry rejected send"])
        let remoteTypes = await server.storedRecordTypes(in: zone)
        XCTAssertEqual(remoteTypes.filter { $0 == "Snip" }.count, 1)
        let oldRemote = await server.fullSnapshot(for: .snip(snip.id, in: zone))
        XCTAssertNil(oldRemote)
        let outputSnapshot = await server.fullSnapshot(for: .snip(outputID, in: zone))
        let outputRecord = try CloudFullRecordCodec.snip(from: try XCTUnwrap(outputSnapshot))
        XCTAssertEqual(outputRecord.id, .snip(outputID, in: zone))
        XCTAssertEqual(outputRecord.requestID, .value(outputRequestID))
        XCTAssertEqual(outputRecord.text, .value("retry rejected send"))
        XCTAssertEqual(outputRecord.isDone, .value(false))
        let repeatedContinue = try await retry.enableOrRetry()
        XCTAssertEqual(repeatedContinue.state, .on)
        let repeatedFinal = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(repeatedFinal.snips, localAfterRetry.snips)
    }

    func testFullRecordModeRetryResetsCursorAfterFailedFetchedRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        try await add("retry local send", to: source)
        let local = await source.snapshot(sortedBy: .manual)
        let localSnip = try XCTUnwrap(local.snips.first)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let firstTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await firstTransport.failNextSentItem(.snip(localSnip.id, in: zone), failure: .rejected)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { firstTransport }
        )

        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("The rejected first send must be reported")
        } catch let error as CloudSyncIssueError {
            XCTAssertEqual(error.issue, .appDataIssue)
        }

        let remoteSnip = Snip(content: "refetch after cursor reset", origin: .quickEntry)
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        let remoteWrite = try await writer.send(CloudOutboundBatch(operations: [
            .save(try CloudFullRecordCodec.snipDraft(remoteSnip, in: zone))
        ]))
        try await writer.confirmApplied(remoteWrite.id)

        let failedFetchTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await failedFetchTransport.failNextFetchedItem(
            .snip(remoteSnip.id, in: zone),
            failure: .invalidRecord
        )
        let failedFetchRetry = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { failedFetchTransport }
        )
        let failedFetch = try await failedFetchRetry.enableOrRetry()
        XCTAssertEqual(failedFetch.state, .needsAttention)

        let interrupted = try await persistence.snapshot()
        XCTAssertEqual(interrupted.transition?.phase, .candidateReady)
        let candidate = try await persistence.libraryForTransition(
            storeID: try XCTUnwrap(interrupted.transition?.candidateStoreID)
        )
        let raw = CloudFullSyncPersistence(
            library: candidate,
            namespace: namespace,
            dataZone: zone
        )
        let savedEngineState = try await raw.loadEngineState()
        XCTAssertNotNil(savedEngineState)
        let failedRecovery = try await candidate.cloudFullRecoveryEvents(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertEqual(
            try CloudFullSyncPersistence.failedFetchRecordIDs(failedRecovery),
            [.snip(remoteSnip.id, in: zone)]
        )

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let waiting = try await retry.enableOrRetry()
        XCTAssertEqual(waiting.state, .needsAttention)
        let beforeChoice = try await reopened.snapshot()
        XCTAssertEqual(beforeChoice.transition?.id, interrupted.transition?.id)
        XCTAssertEqual(beforeChoice.transition?.candidateStoreID, interrupted.transition?.candidateStoreID)
        let refetchedCandidate = try await reopened.libraryForTransition(
            storeID: try XCTUnwrap(beforeChoice.transition?.candidateStoreID))
        let refetchedStorage = try await refetchedCandidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        let refetchedEntity = try XCTUnwrap(refetchedStorage.readyEntities.first {
            $0.reference == CloudEntityReference(kind: .snip, domainID: remoteSnip.id)
        })
        let refetchedRecord = try CloudFullSyncPersistence.snipRecord(refetchedEntity)
        XCTAssertEqual(refetchedRecord.id, .snip(remoteSnip.id, in: zone))
        XCTAssertEqual(refetchedRecord.requestID, .value(remoteSnip.requestID))
        XCTAssertEqual(refetchedRecord.text, .value("refetch after cursor reset"))
        XCTAssertEqual(refetchedRecord.isDone, .value(false))
        let refetchedRecovery = try await refetchedCandidate.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(try CloudFullSyncPersistence.failedFetchRecordIDs(refetchedRecovery).isEmpty)
        let facade = SnipSyncModeStore(reopened).failedEnableReview
        let reviews = try await facade.snapshot()
        XCTAssertEqual(reviews.issues.map(\.entityID), [.snip(localSnip.id)])
        let issue = try XCTUnwrap(reviews.issues.first { $0.entityID == .snip(localSnip.id) })
        XCTAssertEqual(issue.reason, .unknownOutcome)
        XCTAssertEqual(issue.serverState, .absent)
        XCTAssertNil(issue.serverFieldsAtReview)
        XCTAssertEqual(issue.allowedChoices, [.recoverAsNew])
        XCTAssertTrue(issue.earlierLocalVersions.isEmpty)
        guard case .snip(let localVersion)? = issue.localVersionAtReview else {
            return XCTFail("Expected the retained local snip")
        }
        XCTAssertEqual(localVersion.id, localSnip.id)
        XCTAssertEqual(localVersion.requestID, localSnip.requestID)
        XCTAssertEqual(localVersion.content, "retry local send")
        XCTAssertFalse(localVersion.isDone)
        XCTAssertEqual(localVersion.listID, SnipList.inbox.id)
        XCTAssertTrue(localVersion.attachments.isEmpty)
        let sourceBeforeChoice = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        let storageBeforeChoice = try await reopened.snapshot()
        let chosen = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        XCTAssertEqual(chosen.issueID, issue.id)
        XCTAssertEqual(chosen.selection, .recoverAsNew)
        XCTAssertEqual(chosen.outputs.count, 1)
        let mapping = try XCTUnwrap(chosen.outputs.first)
        XCTAssertEqual(mapping.original, .snip(localSnip.id))
        guard case .snip(let outputID) = mapping.output else { return XCTFail("Expected a snip output") }
        let outputRequestID = try XCTUnwrap(mapping.requestID)
        XCTAssertEqual(Set([outputID, outputRequestID]).count, 2)
        let originalIDs = Set(local.snips.flatMap { [$0.id, $0.requestID] } + local.lists.map(\.id))
        XCTAssertTrue(Set([outputID, outputRequestID]).isDisjoint(with: originalIDs))
        XCTAssertTrue(mapping.attachments.isEmpty)
        let repeated = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        XCTAssertEqual(repeated, chosen)
        let storageAfterChoice = try await reopened.snapshot()
        let sourceAfterChoice = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(storageAfterChoice, storageBeforeChoice)
        XCTAssertEqual(sourceAfterChoice.snips, sourceBeforeChoice.snips)
        XCTAssertEqual(sourceAfterChoice.lists, sourceBeforeChoice.lists)

        XCTAssertFalse(Set([outputID, outputRequestID]).contains(remoteSnip.id))
        XCTAssertFalse(Set([outputID, outputRequestID]).contains(remoteSnip.requestID))
        let result = try await retry.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let active = try await reopened.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.count, 2)
        XCTAssertEqual(Set(final.snips.map(\.id)), Set([outputID, remoteSnip.id]))
        XCTAssertTrue(final.snips.contains(where: { $0.content == "refetch after cursor reset" }))
        let recovered = try XCTUnwrap(final.snips.first { $0.id == outputID })
        XCTAssertEqual(recovered.requestID, outputRequestID)
        XCTAssertEqual(recovered.content, "retry local send")
        XCTAssertFalse(recovered.isDone)
        XCTAssertEqual(recovered.listID, SnipList.inbox.id)
        let remoteKept = try XCTUnwrap(final.snips.first { $0.id == remoteSnip.id })
        XCTAssertEqual(remoteKept.requestID, remoteSnip.requestID)
        XCTAssertEqual(remoteKept.content, "refetch after cursor reset")
        XCTAssertFalse(remoteKept.isDone)
        XCTAssertFalse(final.snips.contains { $0.id == localSnip.id })
        let completed = try await reopened.snapshot()
        XCTAssertNil(completed.transition)
        let rawActive = try await reopened.libraryForTransition(storeID: completed.activeStore.id)
        let recovery = try await rawActive.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(recovery.isEmpty)
        let oldRemote = await server.fullSnapshot(for: .snip(localSnip.id, in: zone))
        XCTAssertNil(oldRemote)
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(remoteTexts, ["refetch after cursor reset", "retry local send"])
        let remoteTypes = await server.storedRecordTypes(in: zone)
        XCTAssertEqual(remoteTypes.filter { $0 == "Snip" }.count, 2)
        for (id, requestID, text) in [(outputID, outputRequestID, "retry local send"),
            (remoteSnip.id, remoteSnip.requestID, "refetch after cursor reset")] {
            let snapshot = await server.fullSnapshot(for: .snip(id, in: zone))
            let record = try CloudFullRecordCodec.snip(from: try XCTUnwrap(snapshot))
            XCTAssertEqual(record.id, .snip(id, in: zone))
            XCTAssertEqual(record.requestID, .value(requestID))
            XCTAssertEqual(record.text, .value(text))
            XCTAssertEqual(record.isDone, .value(false))
        }
        let repeatedContinue = try await retry.enableOrRetry()
        XCTAssertEqual(repeatedContinue.state, .on)
        let repeatedFinal = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(repeatedFinal.snips.map(\.id)), Set([outputID, remoteSnip.id]))
        XCTAssertEqual(repeatedFinal.snips.count, 2)
    }

    func testFullRecordEnableKeepsTypedFetchIssueWhileSetupWaits() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let zone = textZone(namespace)

        let writerPersistence = try SwiftDataSyncModePersistence(
            rootURL: root.appendingPathComponent("writer")
        )
        let writerLibrary = try await writerPersistence.activeLibrary()
        try await add("remote record", to: writerLibrary)
        let writerSnapshot = await writerLibrary.snapshot(sortedBy: .manual)
        let remoteSnip = try XCTUnwrap(writerSnapshot.snips.first)
        let writer = ICloudSyncModeCoordinator(
            persistence: writerPersistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let writerResult = try await writer.enableOrRetry()
        XCTAssertEqual(writerResult.state, .on)

        let readerPersistence = try SwiftDataSyncModePersistence(
            rootURL: root.appendingPathComponent("reader")
        )
        let readerTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await readerTransport.failNextFetchedItem(
            .snip(remoteSnip.id, in: zone),
            failure: .networkUnavailable
        )
        let reader = ICloudSyncModeCoordinator(
            persistence: readerPersistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { readerTransport }
        )

        let result = try await reader.enableOrRetry()

        XCTAssertEqual(result.state, .settingUp)
        XCTAssertEqual(result.syncIssue, .waitingForConnection)
        let readerStorage = try await readerPersistence.snapshot()
        XCTAssertEqual(readerStorage.activeStore.kind, .localOnly)
    }

    func testActiveSyncQuarantinesTerminalAttachmentFailureAndKeepsSending() async throws {
      for failure in [CloudOperationFailure.rejected, .zoneMissing] {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("initial.txt")
        try Data("initial attachment".utf8).write(to: sourceURL)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        _ = try await source.perform(
            .add(
                content: "attachment owner",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [sourceURL],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )
        let dataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(),
            zones: [dataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: dataZone,
            payloadZone: payloadZone,
            makeTransport: { transport }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let active = try await persistence.activeLibrary()
        let current = await active.snapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(current.snips.first)
        let oldAttachment = try XCTUnwrap(snip.attachments.first)
        let replacementURL = root.appendingPathComponent("replacement.txt")
        try Data("replacement bytes".utf8).write(to: replacementURL)
        _ = try await active.perform(
            .editAttachments(
                snipID: snip.id,
                content: snip.content,
                edits: [.replacement(
                    attachmentID: oldAttachment.id,
                    sourceURL: replacementURL
                )],
                expectedUpdatedAt: snip.updatedAt,
                now: Date(timeIntervalSince1970: 2)
            ),
            sortedBy: .manual
        )
        await transport.pauseNextSend()
        let failingSync = Task { try await coordinator.syncActive() }
        await transport.waitUntilSendPauses()
        let activeStore = try await persistence.snapshot().activeStore
        let activeLibrary = try await persistence.libraryForTransition(storeID: activeStore.id)
        let attachmentStorage = try await activeLibrary.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let replacement = try XCTUnwrap(attachmentStorage.publications.first(where: {
            !$0.payloadAccepted
        }))
        let failedPayloadID = CloudAttachmentRecordCodec.recordID(
            replacement.metadata.payloadIdentity
        )
        await transport.failNextSentItem(failedPayloadID, failure: failure)
        await transport.resumeSend()

        do {
            _ = try await failingSync.value
            XCTFail("The settled item problem must be reported")
        } catch let error as CloudSyncIssueError {
            XCTAssertEqual(error.issue, .appDataIssue)
        }
        try await add("unrelated after attachment failure", to: active)
        let laterResult = try await coordinator.syncActive()
        XCTAssertEqual(laterResult.state, .on)

        let after = try await activeLibrary.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertEqual(
            after.publications.first(where: {
                $0.metadata.attachmentID == replacement.metadata.attachmentID
            })?.lastFailure,
            failure == .rejected ? .rejected : .zoneMissing
        )
        let pending = try await CloudFullSyncPersistence(
            library: activeLibrary,
            namespace: namespace,
            dataZone: dataZone,
            payloadZone: payloadZone
        ).pendingChanges()
        XCTAssertTrue(pending.operations.isEmpty)
        XCTAssertTrue(pending.zonesToSave.isEmpty)
        let final = await active.snapshot(sortedBy: .manual)
        let unrelated = try XCTUnwrap(final.snips.first(where: {
            $0.content == "unrelated after attachment failure"
        }))
        let remoteUnrelated = await server.fullSnapshot(for: .snip(unrelated.id, in: dataZone))
        XCTAssertNotNil(remoteUnrelated)
        let recovery = try await activeLibrary.cloudFullRecoveryEvents(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertFalse(recovery.contains(where: { $0.kind == .terminalSend }))
      }
    }

    func testEnableWithExistingAttachmentPublishesPayloadAndMetadataBeforePointerSwap() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("existing.txt")
        try Data("existing attachment".utf8).write(to: sourceURL)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        _ = try await source.perform(
            .add(
                content: "enable with file",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [sourceURL],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )
        let dataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(),
            zones: [dataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: dataZone,
            payloadZone: payloadZone,
            makeTransport: { transport }
        )

        let result = try await coordinator.enableOrRetry()

        XCTAssertEqual(result.state, .on)
        let storage = try await persistence.snapshot()
        let active = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
        let attachments = try await active.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let publication = try XCTUnwrap(attachments.publications.first)
        XCTAssertTrue(publication.payloadAccepted)
        XCTAssertTrue(publication.metadataAccepted)
        let remotePayload = await server.fullSnapshot(
            for: CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
        )
        let remoteMetadata = await server.fullSnapshot(
            for: CloudAttachmentRecordCodec.recordID(publication.metadataIdentity)
        )
        XCTAssertNotNil(remotePayload)
        XCTAssertNotNil(remoteMetadata)
    }

    func testOptOutRedownloadsAnEvictedAttachmentBeforeMakingTheLocalCopy() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstBytes = Data(repeating: 0xA1, count: 32)
        let secondBytes = Data(repeating: 0xB2, count: 32)
        let firstSourceURL = root.appendingPathComponent("first.txt")
        let secondSourceURL = root.appendingPathComponent("second.txt")
        try firstBytes.write(to: firstSourceURL)
        try secondBytes.write(to: secondSourceURL)
        let dataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(),
            zones: [dataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let cacheRoot = root.appendingPathComponent("AppGroup/Library/Caches/CloudAttachments")
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            attachmentCacheRootURL: cacheRoot
        )
        let library = try await persistence.activeLibrary()
        let added = try await library.perform(
            .add(
                content: "attachment from another device",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [firstSourceURL, secondSourceURL],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )
        let attachments = try XCTUnwrap(added.snapshot.snips.first?.attachments)
        XCTAssertEqual(attachments.count, 2)
        let firstAttachmentID = attachments[0].id
        let secondAttachmentID = attachments[1].id
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: dataZone,
            payloadZone: payloadZone,
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let storage = try await persistence.snapshot()
        let activeLibrary = try await persistence.libraryForTransition(
            storeID: storage.activeStore.id
        )
        let beforeDownload = await activeLibrary.snapshot(sortedBy: .manual)
        let firstDurableURL = try XCTUnwrap(beforeDownload.attachmentURLs[firstAttachmentID])
        let secondDurableURL = try XCTUnwrap(beforeDownload.attachmentURLs[secondAttachmentID])
        let attachmentStorage = try await activeLibrary.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let publication = try XCTUnwrap(attachmentStorage.publications.first(where: {
            $0.metadata.attachmentID == secondAttachmentID
        }))
        let stagingRoot = try await activeLibrary.cloudAttachmentStagingRoot(
            namespaceKey: namespace.namespaceKey
        )
        let staged = stagingRoot.appendingPathComponent("test-download/payload")
        try FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try secondBytes.write(to: staged)
        _ = try await activeLibrary.installCloudAttachmentDownload(
            namespaceKey: namespace.namespaceKey,
            attachmentID: secondAttachmentID,
            expectedPayloadIdentity: publication.metadata.payloadIdentity,
            expectedField: CloudAttachmentRecordCodec.assetField,
            download: CloudAttachmentCacheDownload(
                payloadIdentity: publication.metadata.payloadIdentity,
                field: CloudAttachmentRecordCodec.assetField,
                fileURL: staged,
                byteCount: Int64(secondBytes.count),
                sha256: Data(SHA256.hash(data: secondBytes))
            ),
            maximumBytes: Int64(secondBytes.count),
            now: .distantPast
        )
        let cachedSnapshot = await activeLibrary.snapshot(sortedBy: .manual)
        let cached = try XCTUnwrap(cachedSnapshot.attachmentURLs[secondAttachmentID])
        XCTAssertTrue(cached.path.hasPrefix(cacheRoot.path + "/"))
        try await activeLibrary.reconcileCloudAttachments(
            namespaceKey: namespace.namespaceKey,
            metadataZoneName: dataZone.name,
            metadataOwnerName: dataZone.ownerName,
            payloadZoneName: payloadZone.name,
            payloadOwnerName: payloadZone.ownerName
        )
        try FileManager.default.removeItem(at: firstDurableURL)
        try FileManager.default.removeItem(at: secondDurableURL)
        let beforeOptOut = await activeLibrary.snapshot(sortedBy: .manual)
        XCTAssertNil(beforeOptOut.attachmentURLs[firstAttachmentID])
        XCTAssertEqual(beforeOptOut.attachmentURLs[secondAttachmentID], cached)

        let downloads = CloudAttachmentTransferCoordinator(
            library: activeLibrary,
            namespace: namespace,
            payloadZone: payloadZone,
            transport: FakeCloudRecordTransport(server: server, namespace: namespace),
            maximumCacheBytes: Int64(firstBytes.count)
        )
        let recoveredMissingBytes = try await downloads.preserveAllAttachmentsForLocalCopy()
        XCTAssertTrue(recoveredMissingBytes)
        let preserved = await activeLibrary.snapshot(sortedBy: .manual)
        let preservedFirst = try XCTUnwrap(preserved.attachmentURLs[firstAttachmentID])
        let preservedSecond = try XCTUnwrap(preserved.attachmentURLs[secondAttachmentID])
        XCTAssertEqual(try Data(contentsOf: preservedFirst), firstBytes)
        XCTAssertEqual(try Data(contentsOf: preservedSecond), secondBytes)
        XCTAssertFalse(preservedFirst.path.contains("CloudDownloads"))
        XCTAssertFalse(preservedSecond.path.contains("CloudDownloads"))

        let optedOut = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(optedOut.state, .off)
        let local = try await persistence.activeLibrary()
        let localSnapshot = await local.snapshot(sortedBy: .manual)
        let firstLocalURL = try XCTUnwrap(localSnapshot.attachmentURLs[firstAttachmentID])
        let secondLocalURL = try XCTUnwrap(localSnapshot.attachmentURLs[secondAttachmentID])
        XCTAssertEqual(try Data(contentsOf: firstLocalURL), firstBytes)
        XCTAssertEqual(try Data(contentsOf: secondLocalURL), secondBytes)
        XCTAssertFalse(firstLocalURL.path.contains("CloudDownloads"))
        XCTAssertFalse(secondLocalURL.path.contains("CloudDownloads"))
    }

    func testOptOutPreservesNewLocalAttachmentBeforeCloudReconciliation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(),
            zones: [dataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: dataZone,
            payloadZone: payloadZone,
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)

        let bytes = Data("local attachment before reconciliation".utf8)
        let sourceURL = root.appendingPathComponent("new-local.txt")
        try bytes.write(to: sourceURL)
        let modeStorage = try await persistence.snapshot()
        let cloudLibrary = try await persistence.libraryForTransition(
            storeID: modeStorage.activeStore.id
        )
        let added = try await cloudLibrary.perform(
            .add(
                content: "new local attachment",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [sourceURL],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )
        let attachmentID = try XCTUnwrap(added.snapshot.snips.first?.attachments.first?.id)
        let storage = try await cloudLibrary.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertTrue(storage.publications.isEmpty)

        let optedOut = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(optedOut.state, .off)
        let local = try await persistence.activeLibrary()
        let localSnapshot = await local.snapshot(sortedBy: .manual)
        let localURL = try XCTUnwrap(localSnapshot.attachmentURLs[attachmentID])
        XCTAssertEqual(try Data(contentsOf: localURL), bytes)
    }

    func testEnableWithExistingAttachmentKeepsPartialPayloadOwnedAcrossHardReopen() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("partial.txt")
        try Data("partial attachment".utf8).write(to: sourceURL)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        _ = try await source.perform(
            .add(
                content: "partial attachment enable",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [sourceURL],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )
        let sourceSnapshot = await source.snapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(sourceSnapshot.snips.first)
        let attachmentID = try XCTUnwrap(snip.attachments.first?.id)
        let dataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(),
            zones: [dataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.pauseNextSend()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: dataZone,
            payloadZone: payloadZone,
            makeTransport: { transport }
        )

        let enabling = Task { try await coordinator.enableOrRetry() }
        await transport.waitUntilSendPauses()
        await transport.failNextSentItem(.snip(snip.id, in: dataZone), failure: .rateLimited)
        await transport.resumeSend()
        let partial = try await enabling.value

        XCTAssertEqual(partial.state, .settingUp)
        XCTAssertEqual(partial.syncIssue, .retryingSoon)
        let partialStorage = try await persistence.snapshot()
        XCTAssertEqual(partialStorage.activeStore.kind, .localOnly)
        let transition = try XCTUnwrap(partialStorage.transition)
        let candidate = try await persistence.libraryForTransition(
            storeID: transition.candidateStoreID
        )
        let partialAttachments = try await candidate.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let partialPublication = try XCTUnwrap(
            partialAttachments.publications.first(where: {
                $0.metadata.attachmentID == attachmentID
            })
        )
        XCTAssertTrue(partialPublication.payloadAccepted)
        XCTAssertFalse(partialPublication.metadataAccepted)
        let partialRemotePayload = await server.fullSnapshot(
            for: CloudAttachmentRecordCodec.recordID(partialPublication.metadata.payloadIdentity)
        )
        XCTAssertNotNil(partialRemotePayload)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: dataZone,
            payloadZone: payloadZone,
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            }
        )
        let reviewStatus = try await retry.enableOrRetry()
        XCTAssertEqual(reviewStatus.state, .needsAttention)
        let facade = SnipSyncModeStore(reopened).failedEnableReview
        let review = try await facade.snapshot()
        let issue = try XCTUnwrap(review.issues.first { $0.entityID == .snip(snip.id) })
        XCTAssertEqual(issue.serverState, .absent)
        XCTAssertEqual(issue.allowedChoices, [.recoverAsNew])
        let chosen = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        let output = try XCTUnwrap(chosen.outputs.first)
        XCTAssertEqual(chosen.outputs.count, 1)
        XCTAssertEqual(output.original, .snip(snip.id))
        guard case .snip(let recoveredID) = output.output else { return XCTFail("Expected a snip mapping") }
        let requestID = try XCTUnwrap(output.requestID)
        let attachmentMap = try XCTUnwrap(output.attachments.first)
        XCTAssertEqual(output.attachments.count, 1)
        XCTAssertEqual(attachmentMap.originalID, attachmentID)
        XCTAssertEqual(Set([recoveredID, requestID, attachmentMap.outputID]).count, 3)
        XCTAssertTrue(Set([recoveredID, requestID, attachmentMap.outputID]).isDisjoint(with:
            Set([snip.id, snip.requestID, attachmentID])))
        let sourceAfterChoice = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(sourceAfterChoice.snips.map(\.id), [snip.id])
        XCTAssertEqual(sourceAfterChoice.snips.first?.content, "partial attachment enable")
        let completed = try await retry.enableOrRetry()

        XCTAssertEqual(completed.state, .on)
        let completedStorage = try await reopened.snapshot()
        let active = try await reopened.libraryForTransition(
            storeID: completedStorage.activeStore.id
        )
        let settled = try await active.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let publication = try XCTUnwrap(settled.publications.first)
        XCTAssertTrue(publication.payloadAccepted)
        XCTAssertTrue(publication.metadataAccepted)
        XCTAssertEqual(publication.metadata.attachmentID, attachmentMap.outputID)
        XCTAssertEqual(publication.metadata.snipID, recoveredID)
        let final = try await active.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.map(\.id), [recoveredID])
        XCTAssertEqual(final.snips.first?.requestID, requestID)
        XCTAssertEqual(final.snips.first?.content, "partial attachment enable")
        XCTAssertEqual(final.snips.first?.isDone, false)
        let localURL = try XCTUnwrap(final.attachmentURLs[attachmentMap.outputID])
        let expectedBytes = Data("partial attachment".utf8)
        XCTAssertEqual(try Data(contentsOf: localURL), expectedBytes)
        XCTAssertEqual(publication.metadata.byteCount, Int64(expectedBytes.count))
        XCTAssertEqual(publication.metadata.sha256, Data(SHA256.hash(data: expectedBytes)))
        let oldOriginal = await server.fullSnapshot(for: .snip(snip.id, in: dataZone))
        XCTAssertNil(oldOriginal)
        let remoteSnipValue = await server.fullSnapshot(for: .snip(recoveredID, in: dataZone))
        let remoteSnipSnapshot = try XCTUnwrap(remoteSnipValue)
        let remoteSnip = try CloudFullRecordCodec.snip(from: remoteSnipSnapshot)
        XCTAssertEqual(remoteSnip.domainID, recoveredID)
        XCTAssertEqual(remoteSnip.text, .value("partial attachment enable"))
        XCTAssertEqual(remoteSnip.isDone, .value(false))
        XCTAssertEqual(remoteSnip.requestID, .value(requestID))
        XCTAssertEqual(remoteSnip.createdAt, .value(snip.createdAt))
        XCTAssertEqual(remoteSnip.origin, .value(SnipOrigin.quickEntry.rawValue))
        let assetURL = await server.asset(for: CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity),
            field: CloudAttachmentRecordCodec.assetField)
        let remoteAssetURL = try XCTUnwrap(assetURL)
        XCTAssertEqual(try Data(contentsOf: remoteAssetURL), expectedBytes)
        let retainedPayload = await server.fullSnapshot(
            for: CloudAttachmentRecordCodec.recordID(partialPublication.metadata.payloadIdentity))
        XCTAssertNotNil(retainedPayload)
        let remoteMetadata = await server.fullSnapshot(
            for: CloudAttachmentRecordCodec.recordID(publication.metadataIdentity)
        )
        XCTAssertNotNil(remoteMetadata)
        let remoteMetadataSnapshot = try XCTUnwrap(remoteMetadata)
        let metadata = try CloudAttachmentRecordCodec.metadata(from: remoteMetadataSnapshot,
            metadataZone: dataZone, payloadZone: payloadZone)
        XCTAssertEqual(metadata.snipID, recoveredID)
        XCTAssertEqual(metadata.attachmentID, attachmentMap.outputID)
        XCTAssertEqual(metadata.sha256, Data(SHA256.hash(data: expectedBytes)))
        let repeated = try await retry.enableOrRetry()
        XCTAssertEqual(repeated.state, .on)
        let afterRepeated = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(afterRepeated.snips.map(\.id), [recoveredID])
    }

    func testLocalOnlyAttachmentSaveNeverCreatesCloudUploadWork() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("local-only.txt")
        try Data("local only".utf8).write(to: source)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let library = try await persistence.activeLibrary()

        let saved = try await library.perform(
            .add(
                content: "local attachment",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [source],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )

        XCTAssertEqual(saved.snapshot.snips.first?.attachments.count, 1)
        let allPaths = FileManager.default.enumerator(atPath: root.path)?.allObjects
            .compactMap { $0 as? String } ?? []
        XCTAssertFalse(allPaths.contains(where: { $0.contains("CloudAttachmentUploads") }))
        let storage = try await persistence.snapshot()
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
    }

    func testAttachmentSetupListsAllUnsupportedFilesBeforeStartingTransition() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let first = root.appendingPathComponent("first.bin")
        let second = root.appendingPathComponent("second.bin")
        try Data(repeating: 1, count: 5).write(to: first)
        try Data(repeating: 2, count: 6).write(to: second)
        let local = try await persistence.activeLibrary()
        _ = try await local.perform(
            .add(
                content: "local files",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [first, second],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )
        let dataZone = CloudZoneID(name: "data", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(),
            zones: [dataZone, payloadZone]
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: dataZone,
            payloadZone: payloadZone,
            attachmentPolicy: CloudAttachmentCompatibilityPolicy(maximumFileBytes: 4),
            makeTransport: {
                FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
            }
        )

        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("Expected setup to report unsupported files")
        } catch let CloudAttachmentSetupError.unsupportedFiles(files) {
            XCTAssertEqual(files.map(\.fileName), ["first.bin", "second.bin"])
        }
        let after = try await persistence.snapshot()
        XCTAssertEqual(after.activeStore.kind, .localOnly)
        XCTAssertNil(after.transition)
    }

    func testNewStoresAndTransitionsPinFullRecordProtocol() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let initial = try await persistence.snapshot()
        XCTAssertEqual(initial.activeStore.syncProtocol, .fullRecordV1)

        let transition = try await persistence.beginTransition(
            to: .iCloudSync,
            namespace: testBinding()
        )
        XCTAssertEqual(transition.syncProtocol, .fullRecordV1)
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let reopenedSnapshot = try await reopened.snapshot()
        XCTAssertEqual(reopenedSnapshot.transition?.syncProtocol, .fullRecordV1)
    }

    func testDefaultFullRecordModeUsesOneDriverAndKeepsStatusReadOnly() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
            }
        )

        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let modeBefore = try await persistence.snapshot()
        XCTAssertEqual(modeBefore.activeStore.syncProtocol, .fullRecordV1)
        let active = try await persistence.libraryForTransition(storeID: modeBefore.activeStore.id)
        let fullBefore = try await active.cloudFullStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let legacyBefore = try await active.cloudTextSyncSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertEqual(fullBefore.namespaceState.phase, .active)
        XCTAssertTrue(legacyBefore.records.isEmpty)

        let firstStatus = try await coordinator.status()
        let secondStatus = try await coordinator.status()
        let modeAfter = try await persistence.snapshot()
        let fullAfter = try await active.cloudFullStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertEqual(firstStatus.state, .on)
        XCTAssertEqual(secondStatus, firstStatus)
        XCTAssertEqual(modeAfter, modeBefore)
        XCTAssertEqual(fullAfter, fullBefore)
    }

    func testFullRecordActiveSyncHoldsOneOuterLeaseWhileStatusReads() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let initial = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let enabled = try await initial.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)

        let paused = FakeCloudRecordTransport(server: server, namespace: namespace)
        await paused.pauseNextFetch()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { paused }
        )
        let syncing = Task { try await coordinator.syncActive() }
        await paused.waitUntilFetchPauses()
        let beforeStatus = try await persistence.snapshot()
        XCTAssertTrue(beforeStatus.hasActiveMutationReservation)
        let firstStatus = try await coordinator.status()
        let secondStatus = try await coordinator.status()
        let afterStatus = try await persistence.snapshot()
        XCTAssertEqual(firstStatus.state, .syncing)
        XCTAssertEqual(secondStatus, firstStatus)
        XCTAssertEqual(afterStatus, beforeStatus)

        await paused.resumeFetch()
        let finished = try await syncing.value
        let finalStorage = try await persistence.snapshot()
        XCTAssertEqual(finished.state, .on)
        XCTAssertFalse(finalStorage.hasActiveMutationReservation)
    }

    func testFullActiveModeEnrollsNewLocalListAndSnipForAnotherClient() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let library = try await persistence.activeLibrary()
        let created = try await library.perform(
            .createList(name: "Synced later", systemImage: "arrow.triangle.2.circlepath"),
            sortedBy: .manual
        )
        guard case .listCreated(let list) = created.outcome else {
            return XCTFail("Expected a list")
        }
        _ = try await library.perform(
            .add(
                content: "new active snip",
                origin: .quickEntry,
                source: nil,
                listID: list.id,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 10)
            ),
            sortedBy: .manual
        )
        let synced = try await coordinator.syncActive()
        XCTAssertEqual(synced.state, .on)

        let secondRoot = root.appendingPathComponent("second.store")
        let secondLibrary = try SwiftDataSnipLibrary(storeURL: secondRoot)
        let secondPersistence = CloudFullSyncPersistence(
            library: secondLibrary,
            namespace: namespace,
            dataZone: textZone(namespace)
        )
        let second = CloudFullSyncCoordinator(
            store: secondPersistence,
            transport: FakeCloudRecordTransport(server: server, namespace: namespace)
        )
        try await second.fetchRemote()
        let received = await secondLibrary.snapshot(sortedBy: .manual)
        XCTAssertTrue(received.lists.contains(where: { $0.id == list.id }))
        XCTAssertEqual(
            received.snips.first(where: { $0.listID == list.id })?.content,
            "new active snip"
        )
        let activeStorage = try await persistence.snapshot()
        let active = try await persistence.libraryForTransition(
            storeID: activeStorage.activeStore.id
        )
        let full = try await active.cloudFullStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertTrue(full.enrolledEntities.contains(
            CloudEntityReference(kind: .list, domainID: list.id)
        ))
        let snipID = try XCTUnwrap(
            received.snips.first(where: { $0.listID == list.id })?.id
        )
        XCTAssertTrue(full.enrolledEntities.contains(
            CloudEntityReference(kind: .snip, domainID: snipID)
        ))
    }

    func testOneActiveSyncOpportunityAdvancesPayloadThenMetadata() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataZone = CloudZoneID(name: "data", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account",
            generation: UUID(),
            zones: [dataZone, payloadZone]
        )
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: dataZone,
            payloadZone: payloadZone,
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let source = root.appendingPathComponent("foreground.txt")
        try Data("saved offline first".utf8).write(to: source)
        let activeStorage = try await persistence.snapshot()
        let library = try await persistence.libraryForTransition(
            storeID: activeStorage.activeStore.id
        )
        _ = try await library.perform(
            .add(
                content: "foreground retry",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inbox.id,
                attachmentURLs: [source],
                requestID: UUID(),
                now: .distantPast
            ),
            sortedBy: .manual
        )

        let result = try await coordinator.syncActive()

        XCTAssertEqual(result.state, .on)
        let stored = try await library.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let publication = try XCTUnwrap(stored.publications.first)
        XCTAssertTrue(publication.payloadAccepted)
        XCTAssertTrue(publication.metadataAccepted)
        XCTAssertNil(publication.sourceURL)
    }

    func testFullActiveSyncDefersSnipUntilItsListArrives() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let list = SnipList(
            id: UUID(),
            name: "Arrives later",
            systemImage: "folder",
            position: 1
        )
        let snip = Snip(content: "waits for list", origin: .quickEntry, listID: list.id)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        _ = try await writer.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.snipDraft(snip, in: zone))
        ]))

        let first = try await coordinator.syncActive()
        XCTAssertEqual(first.state, .on)
        let activeBeforeList = try await persistence.snapshot()
        let waiting = try await persistence.libraryForTransition(
            storeID: activeBeforeList.activeStore.id
        )
        let waitingLocal = await waiting.snapshot(sortedBy: .manual)
        XCTAssertFalse(waitingLocal.snips.contains { $0.id == snip.id })
        let waitingStorage = try await waiting.cloudFullStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertEqual(waitingStorage.deferredEntities.map(\.reference.domainID), [snip.id])

        let listWriter = FakeCloudRecordTransport(server: server, namespace: namespace)
        _ = try await listWriter.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.listDraft(list, updatedAt: Date(), in: zone))
        ]))
        let second = try await coordinator.syncActive()
        XCTAssertEqual(second.state, .on)
        let active = try await persistence.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        XCTAssertTrue(final.lists.contains { $0.id == list.id })
        XCTAssertEqual(final.snips.first(where: { $0.id == snip.id })?.listID, list.id)
    }

    func testFullEnableMovesConfirmedOrphanedSnipToInboxAndRepairsServer() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let missingListID = UUID()
        let orphan = Snip(
            content: "keep orphaned snip",
            origin: .quickEntry,
            listID: missingListID
        )
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        _ = try await writer.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.snipDraft(orphan, in: zone))
        ]))
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )

        let result = try await coordinator.enableOrRetry()

        XCTAssertEqual(result.state, .on)
        let completed = try await persistence.snapshot()
        XCTAssertNil(completed.transition)
        let active = try await persistence.libraryForTransition(storeID: completed.activeStore.id)
        let local = await active.snapshot(sortedBy: .manual)
        XCTAssertEqual(local.snips.first(where: { $0.id == orphan.id })?.listID, SnipList.inbox.id)
        let storage = try await active.cloudFullStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertTrue(storage.deferredEntities.isEmpty)
        let storedValue = await server.fullSnapshot(for: .snip(orphan.id, in: zone))
        let stored = try XCTUnwrap(storedValue)
        let remote = try CloudFullSyncPersistence.snipFields(
            CloudFullRecordCodec.snip(from: stored)
        )
        XCTAssertEqual(remote.placement.listID, SnipList.inbox.id)
    }

    func testFullEnableRetryRepairsDeferredOrphanAndFinishesSetup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let orphan = Snip(content: "retry orphan", origin: .quickEntry, listID: UUID())
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        _ = try await writer.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.snipDraft(orphan, in: zone))
        ]))
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.failNextFetchedZone(zone, failure: .networkUnavailable)
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { transport }
        )

        let interrupted = try await coordinator.enableOrRetry()
        XCTAssertEqual(interrupted.state, .settingUp)
        let interruptedStorage = try await persistence.snapshot()
        let transition = try XCTUnwrap(interruptedStorage.transition)
        let candidate = try await persistence.libraryForTransition(
            storeID: transition.candidateStoreID
        )
        let waiting = try await candidate.cloudFullStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertEqual(waiting.deferredEntities.map(\.reference.domainID), [orphan.id])

        let completed = try await coordinator.enableOrRetry()

        XCTAssertEqual(completed.state, .on)
        let active = try await persistence.activeLibrary()
        let local = await active.snapshot(sortedBy: .manual)
        XCTAssertEqual(local.snips.first(where: { $0.id == orphan.id })?.listID, SnipList.inbox.id)
        let storedValue = await server.fullSnapshot(for: .snip(orphan.id, in: zone))
        let stored = try XCTUnwrap(storedValue)
        let remote = try CloudFullSyncPersistence.snipFields(
            CloudFullRecordCodec.snip(from: stored)
        )
        XCTAssertEqual(remote.placement.listID, SnipList.inbox.id)
    }

    func testFullOptOutCarriesReadyAndDeferredBasesButNoLiveSyncState() async throws {
        for choice in [
            ICloudSyncOptOutChoice.refreshThenCopy,
            .useCurrentCacheAfterStaleDataWarning,
        ] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let persistence = try SwiftDataSyncModePersistence(rootURL: root)
            let namespace = makeNamespace()
            let zone = textZone(namespace)
            let server = FakeCloudServer()
            let coordinator = ICloudSyncModeCoordinator(
                persistence: persistence,
                namespace: namespace,
                textZone: zone,
                makeTransport: {
                    FakeCloudRecordTransport(server: server, namespace: namespace)
                }
            )
            let enabled = try await coordinator.enableOrRetry()
            XCTAssertEqual(enabled.state, .on)
            let missingListID = UUID()
            let deferred = Snip(
                content: "deferred while opting out",
                origin: .quickEntry,
                listID: missingListID
            )
            let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
            let sent = try await writer.send(CloudOutboundBatch(operations: [
                .save(CloudFullRecordCodec.snipDraft(deferred, in: zone))
            ]))
            guard case .saved = try XCTUnwrap(sent.items.first) else {
                return XCTFail("Expected the remote Snip save")
            }
            let synced = try await coordinator.syncActive()
            XCTAssertEqual(synced.state, .on)
            let cloudStorage = try await persistence.snapshot()
            let cloudLibrary = try await persistence.libraryForTransition(
                storeID: cloudStorage.activeStore.id
            )
            let acceptedBefore = try await cloudLibrary.cloudFullStorageSnapshot(
                namespaceKey: namespace.namespaceKey
            )
            XCTAssertFalse(acceptedBefore.readyEntities.isEmpty)
            XCTAssertEqual(acceptedBefore.deferredEntities.map(\.reference.domainID), [deferred.id])

            let optedOut = try await coordinator.optOut(choice)
            XCTAssertEqual(optedOut.state, .off)
            let localStorage = try await persistence.snapshot()
            let local = try await persistence.libraryForTransition(
                storeID: localStorage.activeStore.id
            )
            let dormant = try await local.dormantCloudBases()
            XCTAssertEqual(
                Set(dormant.filter { $0.namespaceKey == namespace.namespaceKey.rawValue }.map(\.reference)),
                Set((acceptedBefore.readyEntities + acceptedBefore.deferredEntities).map(\.reference))
            )
            let localFull = try await local.cloudFullStorageSnapshot(
                namespaceKey: namespace.namespaceKey
            )
            let localWire = try await local.cloudTextSyncSnapshot(
                namespaceKey: namespace.namespaceKey
            )
            let localRecovery = try await local.cloudFullRecoveryEvents(
                namespaceKey: namespace.namespaceKey
            )
            XCTAssertTrue(localFull.readyEntities.isEmpty)
            XCTAssertTrue(localFull.deferredEntities.isEmpty)
            XCTAssertTrue(localFull.enrolledEntities.isEmpty)
            XCTAssertTrue(localFull.conflicts.isEmpty)
            XCTAssertNil(localWire.engineState)
            XCTAssertTrue(localWire.stagedBatches.isEmpty)
            XCTAssertTrue(localRecovery.isEmpty)
        }
    }

    func testFullSameNamespaceReenableMergesLocalAndFreshServerChanges() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let local = try await persistence.activeLibrary()
        try await add("base", to: local)
        let initial = await local.snapshot(sortedBy: .manual)
        let base = try XCTUnwrap(initial.snips.first)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let optedOut = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(optedOut.state, .off)
        let localOnly = try await persistence.activeLibrary()
        let localBefore = await localOnly.snapshot(sortedBy: .manual)
        let localBase = try XCTUnwrap(localBefore.snips.first(where: { $0.id == base.id }))
        _ = try await localOnly.perform(
            .update(
                id: base.id,
                content: "local text",
                attachmentURLs: nil,
                expectedUpdatedAt: localBase.updatedAt,
                now: Date(timeIntervalSince1970: 20)
            ),
            sortedBy: .manual
        )
        let recordID = CloudRecordID.snip(base.id, in: zone)
        let storedRemote = await server.fullSnapshot(for: recordID)
        let remoteSnapshot = try XCTUnwrap(storedRemote)
        let remoteAccepted = try CloudFullRecordCodec.snip(from: remoteSnapshot)
        let remote = Snip(
            id: base.id,
            requestID: base.requestID,
            createdAt: base.createdAt,
            updatedAt: Date(timeIntervalSince1970: 30),
            content: base.content,
            origin: base.origin,
            source: base.source,
            listID: base.listID,
            isDone: true,
            manualSortKey: base.manualSortKey
        )
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        let sent = try await writer.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.snipDraft(remote, accepted: remoteAccepted))
        ]))
        guard case .saved = try XCTUnwrap(sent.items.first) else {
            return XCTFail("Expected the server edit")
        }

        let reenabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(reenabled.state, .on)
        let active = try await persistence.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        let merged = try XCTUnwrap(final.snips.first(where: { $0.id == base.id }))
        XCTAssertEqual(merged.content, "local text")
        XCTAssertTrue(merged.isDone)
    }

    func testFullReenableSameFieldConflictKeepsServerAndAddsRecoveredSnip() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("activation.json")
        let stagedPlans = AsyncStream.makeStream(of: (SyncModeTransition, CloudFullReenableApplyPlan, Data).self)
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: { point in
                switch point {
                case .afterCandidateMergeDurability, .afterEnrollmentApproval, .afterFirstSendStarted,
                    .beforeSendAttemptManifest, .afterFirstSendComplete, .beforePointerSwap, .afterPointerSwap:
                    do {
                        let state = try JSONDecoder().decode(SwiftDataSyncModePersistence.Manifest.self,
                            from: Data(contentsOf: manifestURL))
                        print("[F5 same-field] hook=\(point) active=\(state.activeStoreID) "
                            + "source=\(String(describing: state.transition?.sourceStoreID)) "
                            + "phase=\(String(describing: state.transition?.phase))")
                    } catch {
                        print("[F5 same-field] hook=\(point) manifest unavailable: \(error)")
                    }
                default: break
                }
            },
            writeHook: { point in
                guard point == .beforeFullReenablePlanApply else { return }
                do {
                    let current = try JSONDecoder().decode(SwiftDataSyncModePersistence.Manifest.self,
                        from: Data(contentsOf: manifestURL))
                    let transition = try XCTUnwrap(current.transition)
                    let intent = try XCTUnwrap(transition.mergeIntent)
                    let candidate = try XCTUnwrap(current.stores.first { $0.id == transition.candidateStoreID })
                    let planRoot = root.appendingPathComponent(candidate.relativeRoot)
                        .appendingPathComponent("full-reenable-v1")
                        .appendingPathComponent(transition.id.uuidString.lowercased())
                    let raw = try Data(contentsOf: planRoot.appendingPathComponent("plan.json"))
                    let staged = try JSONDecoder().decode(CloudFullReenableStagedPlan.self, from: raw)
                    let restored = try staged.restore(from: planRoot)
                    XCTAssertNil(restored.acceptedLegacyDigest)
                    XCTAssertEqual(restored.plan.planDigest, intent.planDigest)
                    XCTAssertEqual(transition.phase, .sourceFrozen)
                    XCTAssertEqual(current.activeStoreID, transition.sourceStoreID)
                    XCTAssertNil(transition.sendAttempt)
                    stagedPlans.continuation.yield((transition, restored.plan, raw))
                } catch {
                    XCTFail("Could not read the actual staged plan before apply: \(error)")
                }
            }
        )
        let source = try await persistence.activeLibrary()
        try await add("base", to: source)
        let sourceSnapshot = await source.snapshot(sortedBy: .manual)
        let base = try XCTUnwrap(sourceSnapshot.snips.first)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let cloudManifest = await persistence.manifest
        let optedOut = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(optedOut.state, .off)
        let offManifest = await persistence.manifest
        let offStore = try XCTUnwrap(offManifest.stores.first { $0.id == offManifest.activeStoreID })
        XCTAssertEqual(offStore.kind, .localOnly)
        XCTAssertNil(offManifest.transition)
        let evidenceFiles = FailedEnableEvidenceFile(root: root)
        let binding = FailedEnableBinding(namespace.binding)
        let offEvidence = try evidenceFiles.read(offStore.id)
        let turnOff = offEvidence?.transfers.first { $0.kind == .turnOff && $0.namespace == binding }
        XCTAssertNotNil(turnOff, "Checked turn-off transfer unavailable")
        let local = try await persistence.activeLibrary()
        let localSnapshot = await local.snapshot(sortedBy: .manual)
        let localBase = try XCTUnwrap(localSnapshot.snips.first)
        XCTAssertEqual(localSnapshot.snips, [base])
        XCTAssertEqual(localSnapshot.lists, [SnipList.inbox])
        let snipRef = CloudEntityReference(kind: .snip, domainID: base.id)
        let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
        let offURL = root.appendingPathComponent(offStore.relativeRoot).appendingPathComponent("snips.store")
        let namespaceKey = namespace.namespaceKey.rawValue
        var dormantSnip: CloudAcceptedEntityInput?
        var dormantDigest: String?
        do {
            _ = try XCTUnwrap(FileManager.default.fileExists(atPath: offURL.path) ? offURL : nil,
                "The checked turn-off source is missing")
            let lock = try SnipStoreFileLock(url: offURL.appendingPathExtension("lock"))
            defer { withExtendedLifetime(lock) {} }
            let configuration = ModelConfiguration("SnipSnapLocal", schema: schema, url: offURL,
                allowsSave: false, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = SwiftDataSnipLibrary.makeContext(container: container)
            let metadata = try SwiftDataSnipLibrary.transferMetadata(context: context)
            dormantDigest = FailedEnableEncoding.digest(metadata.opaqueSyncStatePayload)
            let anchors = try CloudDormantAcceptedBaseBundle.decode(metadata.opaqueSyncStatePayload).entries
            let anchor = anchors.first { $0.reference == snipRef && $0.namespaceKey == namespaceKey }
            dormantSnip = try anchor.map {
                let input = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: $0.payload)
                XCTAssertEqual(input.identity, $0.identity)
                return input
            }
            XCTAssertFalse(context.hasChanges)
            try lock.check()
        } catch {
            XCTFail("Checked turn-off dormant rows unavailable: \(error)")
        }
        XCTAssertNotNil(dormantSnip, "Original dormant snip anchor unavailable")
        if let turnOff {
            XCTAssertEqual(turnOff.state, .checked)
            XCTAssertEqual(turnOff.sourceStoreID, FailedEnableEncoding.uuid(cloudManifest.activeStoreID))
            XCTAssertEqual(turnOff.destinationStoreID, FailedEnableEncoding.uuid(offStore.id))
            XCTAssertEqual(turnOff.dormantDigest, dormantDigest)
            let images: [FailedEnableImage] = [
                .snip(try FailedEnableSnipImage(base, attachmentData: [:])),
                .list(FailedEnableListImage(.inbox)),
            ]
            XCTAssertEqual(turnOff.outputs, images.sorted { $0.reference.sortKey < $1.reference.sortKey })
            XCTAssertTrue(turnOff.conflicts.isEmpty)
            XCTAssertTrue(turnOff.recoveryDescriptors.isEmpty)
        }
        _ = try await local.perform(
            .update(
                id: base.id,
                content: "local value",
                attachmentURLs: nil,
                expectedUpdatedAt: localBase.updatedAt,
                now: Date(timeIntervalSince1970: 20)
            ),
            sortedBy: .manual
        )
        let recordID = CloudRecordID.snip(base.id, in: zone)
        let storedValue = await server.fullSnapshot(for: recordID)
        let stored = try XCTUnwrap(storedValue)
        let accepted = try CloudFullRecordCodec.snip(from: stored)
        XCTAssertEqual(base.content, "base")
        XCTAssertEqual(accepted.requestID, .value(base.requestID))
        XCTAssertEqual(accepted.text, .value("base"))
        let editedSnapshot = try await local.checkedSnapshot(sortedBy: .manual)
        let localEdit = try XCTUnwrap(editedSnapshot.snips.first)
        var expectedLocal = base
        expectedLocal.content = "local value"
        expectedLocal.updatedAt = Date(timeIntervalSince1970: 20)
        XCTAssertEqual(localEdit, expectedLocal)
        if let original = dormantSnip {
            XCTAssertEqual(original.reference, snipRef)
            XCTAssertEqual(original.identity.recordName, recordID.name)
            XCTAssertEqual(original.identity.zoneName, zone.name)
            XCTAssertEqual(original.identity.ownerName, zone.ownerName)
            XCTAssertEqual(original.dependencyListID, base.listID)
            XCTAssertEqual(original.shadowData, stored.shadow.data)
            XCTAssertEqual(original.systemFields, stored.shadow.systemFields)
            XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: original.acceptedData), accepted)
            XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: original.presenceData), accepted)
        }
        let remote = Snip(
            id: base.id,
            requestID: base.requestID,
            createdAt: base.createdAt,
            updatedAt: Date(timeIntervalSince1970: 30),
            content: "server value",
            origin: base.origin,
            source: base.source,
            listID: base.listID,
            isDone: base.isDone,
            manualSortKey: base.manualSortKey
        )
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        let serverWrite = try await writer.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.snipDraft(remote, accepted: accepted))
        ]))
        guard case .saved = try XCTUnwrap(serverWrite.items.first) else {
            return XCTFail("Expected the independent server edit")
        }
        let serverAfterEdit = await server.fullSnapshot(for: recordID)
        let serverPreimage = try XCTUnwrap(serverAfterEdit)
        let serverRecord = try CloudFullRecordCodec.snip(from: serverPreimage)
        XCTAssertEqual(serverRecord.text, .value("server value"))
        XCTAssertEqual(serverRecord.requestID, .value(base.requestID))
        let originalSaveCount = await server.acceptedOperationCount(for: recordID)
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let reenable = ICloudSyncModeCoordinator(
            persistence: persistence, namespace: namespace, textZone: zone, makeTransport: { transport }
        )
        let result = try await reenable.enableOrRetry()
        do {
            let afterAttempt = await persistence.manifest
            let liveTransition = afterAttempt.transition
            print("[F5 same-field] result=\(result.state) active=\(afterAttempt.activeStoreID) "
                + "offSource=\(offStore.id) phase=\(String(describing: liveTransition?.phase)) "
                + "attention=\(String(describing: afterAttempt.attentionReason)) "
                + "intent=\(String(describing: liveTransition?.mergeIntent?.id)) "
                + "sendAttempt=\(liveTransition?.sendAttempt != nil)")
            let evidence = try evidenceFiles.read(offStore.id)
            XCTAssertNotNil(evidence)
            if let turnOff {
                XCTAssertTrue(evidence?.transfers.contains(turnOff) == true, "The checked turn-off anchor must survive")
            }
            stagedPlans.continuation.finish()
            var stagedConflictPlan: (SyncModeTransition, CloudFullReenableApplyPlan, Data)?
            for await item in stagedPlans.stream where item.0.sourceStoreID == offStore.id {
                XCTAssertNil(stagedConflictPlan, "One staged re-enable plan expected")
                stagedConflictPlan = item
            }
            XCTAssertNotNil(stagedConflictPlan, "Re-enable did not reach the staged pre-apply hook")
            let attemptedTransition = stagedConflictPlan?.0 ?? liveTransition
            let candidateID = attemptedTransition?.candidateStoreID
            let roots = afterAttempt.stores.map { store in
                let url = root.appendingPathComponent(store.relativeRoot).appendingPathComponent("snips.store")
                return "\(store.id):\(store.kind):\(store.lifecycle):file=\(FileManager.default.fileExists(atPath: url.path))"
            }
            print("[F5 same-field] candidate=\(String(describing: candidateID)) roots=\(roots)")
            if afterAttempt.activeStoreID == offStore.id {
                XCTAssertTrue(FileManager.default.fileExists(atPath: offURL.path))
            }

            let events = await transport.events()
            let sentBatches = events.compactMap { event -> [CloudRecordID]? in
                if case .sent(let ids) = event { return ids }
                return nil
            }
            let sentIDs = sentBatches.flatMap { $0 }
            let serverAfterAttempt = await server.fullSnapshot(for: recordID)
            let originalSavesAfterAttempt = await server.acceptedOperationCount(for: recordID)
            XCTAssertEqual(serverAfterAttempt, serverAfterEdit)
            XCTAssertEqual(originalSavesAfterAttempt, originalSaveCount)
            XCTAssertFalse(sentIDs.contains(recordID), "The original conflict record must be withheld")
            print("[F5 same-field] fetch=\(events.contains(.fetched)) "
                + "sendBatches=\(sentBatches.map { $0.map(\.name) })")
            if let attemptedTransition {
                XCTAssertEqual(afterAttempt.activeStoreID, attemptedTransition.candidateStoreID,
                    "The checked conflict and its recovery must reach the active collection")
                XCTAssertNil(liveTransition, "The conflict review must not leave setup in progress")
                let recoveredID = SnipLibraryTransferPlanner.derivedUUID(
                    transitionID: attemptedTransition.id, sourceID: base.id)
                let recoveredRequest = SnipLibraryTransferPlanner.derivedUUID(
                    transitionID: recoveredID, sourceID: base.requestID)
                XCTAssertNotEqual(recoveredID, base.id)
                XCTAssertNotEqual(recoveredRequest, base.requestID)
                let expectedRecovered = Snip(id: recoveredID, requestID: recoveredRequest,
                    createdAt: base.createdAt, updatedAt: expectedLocal.updatedAt, content: "local value",
                    origin: base.origin, source: base.source, listID: base.listID, isDone: base.isDone,
                    pinnedAt: base.pinnedAt, manualSortKey: base.manualSortKey, attachments: [])
                let recoveredRecordID = CloudRecordID.snip(recoveredID, in: zone)
                let recoveredRemote = await server.fullSnapshot(for: recoveredRecordID)
                if sentBatches.isEmpty {
                    XCTAssertNil(recoveredRemote)
                    print("[F5 same-field] no send, so withholding cannot be attributed to outbound filtering")
                } else {
                    XCTAssertTrue(sentIDs.contains(recoveredRecordID), "Expected the recovered record in the actual send")
                    if let recoveredRemote {
                        let record = try CloudFullRecordCodec.snip(from: recoveredRemote)
                        XCTAssertEqual(record.requestID, .value(recoveredRequest))
                        XCTAssertEqual(record.text, .value("local value"))
                    } else {
                        XCTFail("The recovered record did not reach the server")
                    }
                }

                let capture = evidence?.namespaces.first { $0.binding == binding }?.captures.last {
                    $0.transitionID == FailedEnableEncoding.uuid(attemptedTransition.id)
                        && $0.candidateStoreID == FailedEnableEncoding.uuid(attemptedTransition.candidateStoreID)
                }
                let transfer = capture.flatMap { capture in
                    evidence?.transfers.last { $0.sourceCaptureIDs == [capture.id]
                        && $0.kind == .candidate && $0.namespace == binding }
                }
                XCTAssertNotNil(capture, "Re-enable capture unavailable")
                XCTAssertNotNil(transfer, "Re-enable transfer checkpoint unavailable")
                let record = capture?.records.first { $0.reference == FailedEnableReference(snipRef) }
                XCTAssertNotNil(record, "Conflict member unavailable in the retained capture")
                if let record {
                    XCTAssertEqual(record.source.value, .snip(try FailedEnableSnipImage(expectedLocal, attachmentData: [:])))
                    XCTAssertTrue(record.originalAcceptedExists)
                    XCTAssertEqual(record.preparation.baseKind, .checkedTurnOff)
                    XCTAssertEqual(record.preparation.classification, .realConflict)
                    XCTAssertEqual(record.preparation.conflictFields, ["text"])
                    XCTAssertEqual(record.preparation.recoveryIdentities,
                        [FailedEnableReference(CloudEntityReference(kind: .snip, domainID: recoveredID))])
                    XCTAssertNil(record.observedAccepted.value, "A real conflict is not accepted-value ancestry")
                    if case .snip(let prepared)? = record.preparation.value.value?.fields {
                        XCTAssertEqual(prepared.text, remote.content)
                        XCTAssertEqual(prepared.id, FailedEnableEncoding.uuid(base.id))
                        XCTAssertEqual(prepared.requestID, FailedEnableEncoding.uuid(base.requestID))
                        XCTAssertEqual(prepared.updatedAt, try FailedEnableEncoding.date(remote.updatedAt))
                    } else {
                        XCTFail("Prepared server-original image is unavailable")
                    }
                }

                let plan = stagedConflictPlan?.1
                let conflict = plan?.conflicts.first { $0.reference == snipRef }
                let modeRecovery = plan?.recoveryInputs.first { $0.kind == .modeRecoveredSnip }
                if let plan, let stage = stagedConflictPlan {
                    print("[F5 same-field] stagedSHA=\(FailedEnableEncoding.digest(stage.2)) "
                        + "conflicts=\(plan.conflicts.count) recovery=\(plan.recoveryInputs.count) "
                        + "transfer=\(String(describing: transfer?.state)) armed=\(String(describing: capture?.armed))")
                    XCTAssertEqual(transfer?.planDigest, FailedEnableEncoding.hex(plan.planDigest))
                    XCTAssertEqual(plan.snips.count, 2)
                    XCTAssertEqual(plan.snips.first { $0.id == base.id }, remote)
                    XCTAssertEqual(plan.snips.first { $0.id == recoveredID }, expectedRecovered)
                    XCTAssertTrue(plan.attachmentData.isEmpty)
                    XCTAssertTrue(plan.result.recoveredSourceSnipIDs.contains(base.id))
                    let fetched = try XCTUnwrap(plan.acceptedCAS.first { $0.accepted.reference == snipRef })
                    XCTAssertEqual(fetched.accepted.shadowData, serverPreimage.shadow.data)
                    XCTAssertEqual(fetched.accepted.systemFields, serverPreimage.shadow.systemFields)
                    XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: fetched.accepted.acceptedData),
                        serverRecord)
                    XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: fetched.accepted.presenceData),
                        serverRecord)
                    XCTAssertNotNil(conflict, "Staged plan omitted the checked conflict")
                    XCTAssertNotNil(modeRecovery, "Staged plan omitted recovery linkage")
                }
                if let conflict {
                    XCTAssertEqual(conflict.format, .snipMergeV1)
                    let payload = try JSONDecoder().decode(CloudSnipConflictPayload.self, from: conflict.payload)
                    XCTAssertEqual(payload.fields, [.text])
                    for (fields, snip) in [(payload.local, expectedLocal), (payload.server, remote)] {
                        XCTAssertEqual(fields, CloudSnipMergeFields(id: snip.id, requestID: snip.requestID,
                            createdAt: snip.createdAt, originRaw: snip.origin.rawValue, text: snip.content,
                            source: snip.source, isDone: snip.isDone, pinnedAt: snip.pinnedAt,
                            placement: CloudSnipPlacement(listID: snip.listID, orderKey: snip.manualSortKey),
                            updatedAt: snip.updatedAt))
                    }
                    XCTAssertEqual(conflict.recovery, .snip(RecoveredSnip(id: recoveredID, currentSnipID: base.id,
                        recovered: expectedRecovered, conflictingFields: [.text])))
                    XCTAssertEqual(transfer?.conflicts, [try FailedEnableEncoding.json(conflict)])
                }
                if let modeRecovery {
                    let link = try XCTUnwrap(JSONSerialization.jsonObject(with: modeRecovery.resultData) as? [String: Any])
                    XCTAssertEqual(link["sourceID"] as? String, base.id.uuidString)
                    XCTAssertEqual(link["recoveredID"] as? String, recoveredID.uuidString)
                    XCTAssertEqual(link["storageVersion"] as? Int, 1)
                    XCTAssertTrue(modeRecovery.outboundData.isEmpty)
                    XCTAssertEqual(transfer?.recoveryDescriptors, [try FailedEnableEncoding.json(modeRecovery)])
                }

                if let candidate = afterAttempt.stores.first(where: { $0.id == attemptedTransition.candidateStoreID }) {
                    let candidateRoot = root.appendingPathComponent(candidate.relativeRoot)
                    let url = candidateRoot.appendingPathComponent("snips.store")
                    let planURL = candidateRoot.appendingPathComponent("full-reenable-v1")
                        .appendingPathComponent(attemptedTransition.id.uuidString.lowercased())
                        .appendingPathComponent("plan.json")
                    if FileManager.default.fileExists(atPath: planURL.path), let stage = stagedConflictPlan {
                        XCTAssertEqual(try Data(contentsOf: planURL), stage.2)
                    }
                    if FileManager.default.fileExists(atPath: url.path) {
                        let lock = try SnipStoreFileLock(url: url.appendingPathExtension("lock"))
                        defer { withExtendedLifetime(lock) {} }
                        let configuration = ModelConfiguration("SnipSnapLocal", schema: schema, url: url,
                            allowsSave: false, cloudKitDatabase: .none)
                        let container = try ModelContainer(for: schema, configurations: [configuration])
                        let context = SwiftDataSnipLibrary.makeContext(container: container)
                        let receipt = try SwiftDataCloudFullOperationReceipts.digest(
                            for: .reenableTransition(attemptedTransition.id), namespaceKey: namespaceKey, context: context)
                        let conflicts = try context.fetch(FetchDescriptor<StoredCloudFullConflict>())
                            .filter { $0.namespaceKey == namespaceKey && $0.domainID == base.id && $0.kind == "snip" }
                        let recovery = try context.fetch(FetchDescriptor<StoredCloudRecoveryEvent>())
                            .filter { $0.namespaceKey == namespaceKey }
                        print("[F5 same-field] candidate rows: receipt=\(receipt != nil) conflicts=\(conflicts.count) "
                            + "recoveryKeys=\(recovery.map(\.eventKey).sorted()) planStillOnDisk="
                            + "\(FileManager.default.fileExists(atPath: planURL.path))")
                        if let receipt, let plan { XCTAssertEqual(receipt, plan.planDigest) }
                        if let conflict {
                            XCTAssertEqual(conflicts.count, 1, "Staged conflict did not reach the candidate transaction")
                            if let row = conflicts.first {
                                XCTAssertEqual(row.id, StoredCloudFullConflict.key(namespaceKey: namespaceKey,
                                    conflictKey: conflict.key))
                                XCTAssertEqual(row.format, conflict.format.rawValue)
                                XCTAssertEqual(row.payload, conflict.payload)
                            }
                            let key = "review-recovery-\(recoveredID.uuidString.lowercased())"
                            let reviewRow = recovery.first { $0.eventKey == key }
                            XCTAssertNotNil(reviewRow, "No committed review row for the staged recovery identity")
                            if let reviewRow {
                                let wire = try XCTUnwrap(CloudWirePayloadEnvelope.decode(reviewRow.payload))
                                XCTAssertEqual(wire.format, .fullRecordV1)
                                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: wire.payload) as? [String: Any])
                                XCTAssertEqual(object["conflictKey"] as? String, conflict.key)
                                XCTAssertEqual(object["storageVersion"] as? Int, 1)
                                let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["recovery"]))
                                XCTAssertEqual(try JSONDecoder().decode(SnipRecoveryRecord.self, from: data), conflict.recovery)
                            }
                        }
                        if let modeRecovery {
                            let key = "full-recovery-\(modeRecovery.batchID.uuidString.lowercased())"
                            let linked = recovery.first { $0.eventKey == key }
                            XCTAssertNotNil(linked, "No committed mode recovery for the staged link")
                            if let linked {
                                let wire = try XCTUnwrap(CloudWirePayloadEnvelope.decode(linked.payload))
                                XCTAssertEqual(wire.format, .fullRecordV1)
                                XCTAssertEqual(try JSONDecoder().decode(CloudFullRecoveryInput.self, from: wire.payload),
                                    modeRecovery)
                            }
                        }
                        if let transfer, transfer.state == .checked || receipt != nil {
                            let target = try SwiftDataSnipLibrary.load(context: context, seenRequestIDs: []).state
                            XCTAssertEqual(Set(target.snips.map(\.id)), [base.id, recoveredID])
                            XCTAssertEqual(target.snips.first { $0.id == base.id }, remote)
                            XCTAssertEqual(target.snips.first { $0.id == recoveredID }, expectedRecovered)
                        }
                        XCTAssertFalse(context.hasChanges)
                        try lock.check()
                    } else {
                        print("[F5 same-field] candidate rows unavailable: manifest-bound store file absent")
                        XCTFail("The conflict candidate must remain available for recovery")
                    }
                } else {
                    print("[F5 same-field] candidate rows unavailable: no manifest-bound store")
                    XCTFail("The conflict candidate is not recorded in the manifest")
                }
            } else {
                print("[F5 same-field] recovery send and candidate rows unavailable: no transition identity")
            }
        } catch {
            XCTFail("Conflict evidence inspection stopped: \(error)")
        }
        XCTAssertEqual(result.state, .needsAttention)
        let active = try await persistence.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.first(where: { $0.id == base.id })?.content, "server value")
        XCTAssertEqual(final.snips.first(where: { $0.id != base.id })?.content, "local value")
        XCTAssertEqual(final.snips.count, 2)
        let storage = try await persistence.snapshot()
        let raw = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
        let full = try await raw.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(full.conflicts.filter { $0.reference.domainID == base.id }.count, 1)
        let recovery = try await raw.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
        let link = try XCTUnwrap(recovery.first { $0.kind == .modeRecoveredSnip })
        XCTAssertTrue(String(decoding: link.resultData, as: UTF8.self).contains(base.id.uuidString))
        let pending = try await raw.recoverySnapshot(
            in: SnipRecoveryScope(namespace.namespaceKey.rawValue)
        )
        let review = try XCTUnwrap(pending.pendingSnips.first)
        XCTAssertEqual(review.currentSnipID, base.id)
        XCTAssertEqual(review.recovered.content, "local value")
        XCTAssertEqual(review.conflictingFields, [.text])

        _ = try await raw.resolveRecovery(
            review.id,
            in: SnipRecoveryScope(namespace.namespaceKey.rawValue),
            choice: .keepBoth
        )
        let resolved = await raw.snapshot(sortedBy: .manual)
        XCTAssertEqual(resolved.snips.count, 2)
        let resolvedReview = try await raw.recoverySnapshot(
            in: SnipRecoveryScope(namespace.namespaceKey.rawValue)
        )
        XCTAssertTrue(resolvedReview.pendingSnips.isEmpty)
        XCTAssertEqual(resolvedReview.promotedSnips.first?.currentSnipID, base.id)
        XCTAssertEqual(resolvedReview.promotedSnips.first?.conflictingFields, [.text])
        let resolvedStorage = try await raw.cloudFullStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertTrue(resolvedStorage.conflicts.isEmpty)
    }

    func testFullReenableRemoteDeleteRecoversEditedSnipAndAttachmentInInbox() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        try await add("base", to: source)
        let sourceSnapshot = await source.snapshot(sortedBy: .manual)
        let base = try XCTUnwrap(sourceSnapshot.snips.first)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        _ = try await coordinator.enableOrRetry()
        _ = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        let local = try await persistence.activeLibrary()
        let localSnapshot = await local.snapshot(sortedBy: .manual)
        let localBase = try XCTUnwrap(localSnapshot.snips.first)
        let attachmentURL = root.appendingPathComponent("offline.txt")
        let bytes = Data("kept attachment".utf8)
        try bytes.write(to: attachmentURL)
        _ = try await local.perform(
            .update(
                id: base.id,
                content: "offline edit",
                attachmentURLs: [attachmentURL],
                expectedUpdatedAt: localBase.updatedAt,
                now: Date(timeIntervalSince1970: 20)
            ),
            sortedBy: .manual
        )
        let recordID = CloudRecordID.snip(base.id, in: zone)
        let storedValue = await server.fullSnapshot(for: recordID)
        let stored = try XCTUnwrap(storedValue)
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        _ = try await writer.send(CloudOutboundBatch(operations: [
            .delete(recordID, base: stored.shadow)
        ]))

        let result = try await coordinator.enableOrRetry()
        XCTAssertEqual(result.state, .needsAttention)
        let active = try await persistence.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        XCTAssertNil(final.snips.first(where: { $0.id == base.id }))
        let recovered = try XCTUnwrap(final.snips.first)
        XCTAssertEqual(recovered.content, "offline edit")
        XCTAssertEqual(recovered.listID, SnipList.inbox.id)
        let attachment = try XCTUnwrap(recovered.attachments.first)
        let copiedURL = try XCTUnwrap(final.attachmentURLs[attachment.id])
        XCTAssertEqual(try Data(contentsOf: copiedURL), bytes)
        let storage = try await persistence.snapshot()
        let raw = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
        let recovery = try await raw.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(recovery.filter { $0.kind == .modeRecoveredSnip }.count, 1)
    }

    func testFullReenableIntentReplaysWithoutReceiptAndAdvancesWithReceipt() async throws {
        let cases: [(point: SyncModeCrashPoint, rewrite: Bool)] = [
            (.beforeCandidateMergeDurability, false),
            (.afterCandidateMergeDurability, false),
            (.beforeCandidateMergeDurability, true),
        ]
        for (point, rewrite) in cases {
            let committedBeforeReopen = point == .afterCandidateMergeDurability
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let initial = try SwiftDataSyncModePersistence(rootURL: root)
            let initialLocal = try await initial.activeLibrary()
            let requestID = UUID()
            let originalDate = Date(timeIntervalSince1970: 10)
            let editedDate = Date(timeIntervalSince1970: 50)
            let addition = try await initialLocal.perform(
                .add(content: "base", origin: .quickEntry, source: nil, listID: SnipList.inboxID,
                    attachmentURLs: [], requestID: requestID, now: originalDate),
                sortedBy: .manual
            )
            guard case .add(.added(let snipID)) = addition.outcome else {
                return XCTFail("Expected the original managed add")
            }
            let pinkCreation = try await initialLocal.perform(
                .createList(name: "Synced color", systemImage: "paintpalette", color: .pink),
                sortedBy: .manual
            )
            guard case .listCreated(let pink) = pinkCreation.outcome else {
                return XCTFail("Expected the synced pink list")
            }
            let initialContents = try await initialLocal.checkedSnapshot(sortedBy: .manual)
            let base = try XCTUnwrap(initialContents.snips.first)
            XCTAssertEqual(initialContents.snips.count, 1)
            XCTAssertEqual(Set(initialContents.lists), [SnipList.inbox, pink])
            XCTAssertEqual(base.id, snipID)
            XCTAssertEqual(base.requestID, requestID)
            XCTAssertEqual(base.content, "base")
            XCTAssertEqual(base.createdAt, originalDate)
            XCTAssertEqual(base.updatedAt, originalDate)
            XCTAssertEqual(base.origin, .quickEntry)
            XCTAssertNil(base.source)
            XCTAssertFalse(base.isDone)
            XCTAssertNil(base.pinnedAt)
            XCTAssertEqual(base.listID, SnipList.inboxID)
            XCTAssertTrue(base.attachments.isEmpty)
            XCTAssertEqual(pink.desiredName, "Synced color")
            XCTAssertEqual(pink.resolvedName, "Synced color")
            XCTAssertEqual(pink.systemImage, "paintpalette")
            XCTAssertEqual(pink.color, .pink)

            let namespace = makeNamespace()
            let zone = textZone(namespace)
            let server = FakeCloudServer()
            let first = ICloudSyncModeCoordinator(
                persistence: initial, namespace: namespace, textZone: zone,
                makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
            )
            let firstOn = try await first.enableOrRetry()
            XCTAssertEqual(firstOn.state, .on)
            let checkedOff = try await first.optOut(.useCurrentCacheAfterStaleDataWarning)
            XCTAssertEqual(checkedOff.state, .off)
            let local = try await initial.activeLibrary()
            let off = try await local.checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(off.snips, [base])
            XCTAssertEqual(Set(off.lists), [SnipList.inbox, pink])
            let redCreation = try await local.perform(
                .createList(name: "Offline", systemImage: "folder", color: .red), sortedBy: .manual
            )
            guard case .listCreated(let red) = redCreation.outcome else {
                return XCTFail("Expected the offline red list")
            }
            XCTAssertEqual(red.desiredName, "Offline")
            XCTAssertEqual(red.resolvedName, "Offline")
            XCTAssertEqual(red.systemImage, "folder")
            XCTAssertEqual(red.color, .red)
            let attachmentURL = root.appendingPathComponent("large-offline.bin")
            let attachmentBytes = Data(repeating: 0xA7, count: 65_536)
            try attachmentBytes.write(to: attachmentURL)
            _ = try await local.perform(
                .update(id: snipID, content: "changed while local", attachmentURLs: [attachmentURL],
                    expectedUpdatedAt: originalDate, now: editedDate),
                sortedBy: .manual
            )
            let sourceStore = try await initial.snapshot().activeStore
            let sourceStoreURL = root.appendingPathComponent(sourceStore.relativeRoot)
                .appendingPathComponent("snips.store")
            let source = try await initial.libraryForTransition(storeID: sourceStore.id)
            let originalSource = try await source.transferSnapshot(revision: sourceStore.revision)
            let originalDormant = try await source.dormantCloudBases()
            let originalArchive = try await source.archive()
            XCTAssertEqual(originalArchive.seenRequestIDs, [requestID])
            let edited = try XCTUnwrap(originalSource.snips.first)
            let attachment = try XCTUnwrap(edited.attachments.first)
            XCTAssertEqual(edited.attachments.count, 1)
            XCTAssertEqual(attachment.fileName, "large-offline.bin")
            XCTAssertEqual(attachment.byteCount, Int64(attachmentBytes.count))
            let expectedBytes = [attachment.id: attachmentBytes]
            var expectedSource = base
            expectedSource.content = "changed while local"
            expectedSource.updatedAt = editedDate
            expectedSource.attachments = [attachment]
            XCTAssertEqual(originalSource.snips, [expectedSource])
            XCTAssertEqual(originalSource.attachmentData, expectedBytes)
            let expectedLists: Set<SnipList> = [SnipList.inbox, pink, red]
            XCTAssertEqual(Set(originalSource.lists), expectedLists)
            var expectedOutput = expectedSource
            // Full re-enable synthesis uses the accepted server date, established by the first send.
            expectedOutput.updatedAt = originalDate
            let snipRecordID = CloudRecordID.snip(snipID, in: zone)
            let firstRemote = await server.fullSnapshot(for: snipRecordID)
            let firstRecord = try CloudFullRecordCodec.snip(from: try XCTUnwrap(firstRemote))
            XCTAssertEqual(firstRecord.id, snipRecordID)
            XCTAssertEqual(firstRecord.requestID, .value(requestID))
            XCTAssertEqual(firstRecord.text, .value("base"))
            XCTAssertEqual(firstRecord.updatedAt, .value(originalDate))
            let baselineTypes = await server.storedRecordTypes(in: zone)
            XCTAssertEqual(baselineTypes, ["List", "List", "Snip"])
            let beforeSnipSaves = await server.acceptedOperationCount(for: snipRecordID)
            let beforeDeletes = await server.acceptedDeletionCount()

            let crash = CrashInjector(point: point)
            let crashingOwner = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
            let crashing = ICloudSyncModeCoordinator(
                persistence: crashingOwner, namespace: namespace, textZone: zone,
                makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
            )
            do {
                _ = try await crashing.enableOrRetry()
                return XCTFail("Expected the injected merge crash at \(point)")
            } catch CrashInjector.Failure.injected {}
            let interrupted = try await crashingOwner.snapshot()
            let transition = try XCTUnwrap(interrupted.transition)
            let intent = try XCTUnwrap(transition.mergeIntent)
            let token = try XCTUnwrap(transition.freezeToken)
            XCTAssertEqual(interrupted.activeStore, sourceStore)
            XCTAssertEqual(transition.phase, .sourceFrozen)
            XCTAssertEqual(transition.namespace, namespace.binding)
            XCTAssertEqual(intent.fullReenablePlanID, transition.id)
            XCTAssertEqual(intent.sourceRevision, sourceStore.revision)
            XCTAssertEqual(token.sourceStoreID, sourceStore.id)
            XCTAssertEqual(token.revision, sourceStore.revision)
            let manifestURL = root.appendingPathComponent("activation.json")
            let manifestData = try Data(contentsOf: manifestURL)
            let attachmentPrefix = attachmentBytes.prefix(64)
            let encodedPrefix = Data(attachmentBytes.base64EncodedString().prefix(64).utf8)
            XCTAssertLessThan(manifestData.count, 20_000)
            XCTAssertNil(manifestData.range(of: attachmentPrefix))
            XCTAssertNil(manifestData.range(of: encodedPrefix))
            let stagedFiles = try FileManager.default.subpathsOfDirectory(atPath: root.path)
                .filter { $0.contains("full-reenable-v1") }
            let planPath = try XCTUnwrap(stagedFiles.first { $0.hasSuffix("plan.json") })
            let planURL = root.appendingPathComponent(planPath)
            let modernPlan = try Data(contentsOf: planURL)
            let staged = try JSONDecoder().decode(CloudFullReenableStagedPlan.self, from: modernPlan)
            let restored = try staged.restore(from: planURL.deletingLastPathComponent())
            XCTAssertNil(restored.acceptedLegacyDigest)
            XCTAssertEqual(restored.plan.planDigest, intent.planDigest)
            XCTAssertEqual(restored.plan.snips, [expectedOutput])
            XCTAssertEqual(Set(restored.plan.lists), expectedLists)
            XCTAssertEqual(restored.plan.attachmentData, expectedBytes)
            let stagedAttachment = try XCTUnwrap(stagedFiles.first { $0.hasSuffix(".data") })
            let stagedAttachmentURL = root.appendingPathComponent(stagedAttachment)
            XCTAssertNil(modernPlan.range(of: attachmentPrefix))
            XCTAssertNil(modernPlan.range(of: encodedPrefix))
            XCTAssertEqual(try Data(contentsOf: stagedAttachmentURL), attachmentBytes)
            let crashedManifest = await crashingOwner.manifest
            let candidateStore = try XCTUnwrap(crashedManifest.stores.first {
                $0.id == transition.candidateStoreID
            })
            let candidate = try await crashingOwner.libraryForTransition(storeID: candidateStore.id)
            let targetBeforeReplay = try await candidate.transferSnapshot(revision: candidateStore.revision)
            XCTAssertEqual(targetBeforeReplay.snips, [committedBeforeReopen ? expectedOutput : base])
            XCTAssertEqual(targetBeforeReplay.attachmentData, committedBeforeReopen ? expectedBytes : [:])
            XCTAssertEqual(Set(targetBeforeReplay.lists),
                committedBeforeReopen ? expectedLists : Set([SnipList.inbox, pink]))
            let receipts = try await candidate.failedEnableReenableReceipts(
                namespaceKey: namespace.namespaceKey.rawValue, transitionID: transition.id
            )
            XCTAssertEqual(receipts.modern, committedBeforeReopen ? intent.planDigest : nil)
            XCTAssertNil(receipts.ambiguous)
            let acceptedBeforeReplay = try await candidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
            let sourceAtCrash = try await source.transferSnapshot(revision: sourceStore.revision)
            let dormantAtCrash = try await source.dormantCloudBases()
            XCTAssertEqual(sourceAtCrash, originalSource)
            XCTAssertEqual(dormantAtCrash, originalDormant)

            let files = FailedEnableEvidenceFile(root: root)
            let evidence = try XCTUnwrap(try files.read(sourceStore.id))
            let group = try XCTUnwrap(evidence.namespaces.first { $0.binding == FailedEnableBinding(namespace.binding) })
            let capture = try XCTUnwrap(group.captures.last {
                $0.transitionID == FailedEnableEncoding.uuid(transition.id)
                    && $0.candidateStoreID == FailedEnableEncoding.uuid(candidateStore.id)
            })
            XCTAssertEqual(capture.freeze.id, FailedEnableEncoding.uuid(token.id))
            XCTAssertEqual(capture.freeze.sourceRevision, String(token.revision))
            XCTAssertFalse(capture.armed)
            let reference = FailedEnableReference(CloudEntityReference(kind: .snip, domainID: snipID))
            let capturedSnip = try XCTUnwrap(capture.records.first { $0.reference == reference })
            let expectedL = try FailedEnableSnipImage(expectedSource, attachmentData: expectedBytes)
            XCTAssertEqual(capturedSnip.source.value, .snip(expectedL))
            XCTAssertEqual(capture.records.count, 1 + expectedLists.count)
            for list in expectedLists {
                let image = FailedEnableImage.list(FailedEnableListImage(list))
                let capturedList = try XCTUnwrap(capture.records.first { $0.reference == image.reference })
                XCTAssertEqual(capturedList.source.value, image)
            }
            XCTAssertEqual(capture.seenRequestIDs, [FailedEnableEncoding.uuid(requestID)])
            let attachmentHash = FailedEnableEncoding.digest(attachmentBytes)
            XCTAssertEqual(evidence.blobs[attachmentHash], attachmentBytes)
            let transfer = try XCTUnwrap(evidence.transfers.last { $0.sourceCaptureIDs == [capture.id] })
            XCTAssertEqual(transfer.state, .prepared)
            XCTAssertEqual(transfer.planDigest, FailedEnableEncoding.hex(intent.planDigest))
            let outputImage = try FailedEnableSnipImage(expectedOutput, attachmentData: expectedBytes)
            XCTAssertTrue(transfer.outputs.contains(.snip(outputImage)))

            let replayPlanDigest: Data
            if rewrite {
                let legacyDigest = try await rewriteStagedPlanAsLegacy(
                    at: planURL, target: candidate, includeListConflict: true
                )
                XCTAssertNotEqual(legacyDigest, intent.planDigest)
                try mutateManifest(at: manifestURL) { manifest in
                    var storedTransition = try XCTUnwrap(manifest["transition"] as? [String: Any])
                    var storedIntent = try XCTUnwrap(storedTransition["mergeIntent"] as? [String: Any])
                    storedIntent["planDigest"] = legacyDigest.base64EncodedString()
                    storedTransition["mergeIntent"] = storedIntent
                    manifest["transition"] = storedTransition
                }
                replayPlanDigest = legacyDigest
            } else {
                replayPlanDigest = intent.planDigest
            }
            let planBeforeReplay = try Data(contentsOf: planURL)
            XCTAssertEqual(planBeforeReplay == modernPlan, !rewrite)
            let storedPlan = try XCTUnwrap(JSONSerialization.jsonObject(with: planBeforeReplay) as? [String: Any])
            XCTAssertEqual(storedPlan["planDigest"] as? String, replayPlanDigest.base64EncodedString())

            let replayApply = (rewrite || committedBeforeReopen)
                ? nil : expectation(description: "No-receipt replay enters guarded private apply")
            let reopened = try SwiftDataSyncModePersistence(rootURL: root, writeHook: { boundary in
                guard boundary == .beforeFullReenablePlanApply else { return }
                guard let replayApply else {
                    XCTFail("The mismatched or already committed plan must not enter private apply")
                    throw CrashInjector.Failure.injected
                }
                replayApply.fulfill()
            })
            let reopenManifest = await reopened.manifest
            XCTAssertEqual(reopenManifest.activeStoreID, sourceStore.id)
            XCTAssertEqual(reopenManifest.transition?.id, transition.id)
            XCTAssertEqual(reopenManifest.transition?.candidateStoreID, candidateStore.id)
            XCTAssertEqual(reopenManifest.transition?.phase, .sourceFrozen)
            XCTAssertEqual(reopenManifest.transition?.mergeIntent?.planDigest, replayPlanDigest)
            guard FileManager.default.fileExists(atPath: sourceStoreURL.path) else {
                return XCTFail("The frozen source must still exist before replay")
            }
            let frozenSource = try await reopened.libraryForTransition(storeID: sourceStore.id)
            let frozenTransfer = try await frozenSource.transferSnapshot(revision: sourceStore.revision)
            let frozenDormant = try await frozenSource.dormantCloudBases()
            let frozenArchive = try await frozenSource.archive()
            XCTAssertEqual(frozenTransfer, originalSource)
            XCTAssertEqual(frozenDormant, originalDormant)
            XCTAssertEqual(frozenArchive.seenRequestIDs, originalArchive.seenRequestIDs)
            let replayTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
            let resumed = ICloudSyncModeCoordinator(
                persistence: reopened, namespace: namespace, textZone: zone,
                makeTransport: { replayTransport }
            )
            let result = try await resumed.enableOrRetry()
            if let replayApply {
                await fulfillment(of: [replayApply], timeout: 5)
            }
            let replayed = try await reopened.snapshot()
            let retained = try XCTUnwrap(try files.read(sourceStore.id))
            let retainedGroup = try XCTUnwrap(retained.namespaces.first { $0.binding == group.binding })
            let retainedCapture = try XCTUnwrap(retainedGroup.captures.first { $0.id == capture.id })
            let retainedTransfer = try XCTUnwrap(retained.transfers.last { $0.sourceCaptureIDs == [capture.id] })
            XCTAssertEqual(retained.blobs[attachmentHash], attachmentBytes)

            if rewrite {
                XCTAssertEqual(result.state, .needsAttention)
                XCTAssertEqual(replayed.attentionReason, .enrollmentBlocked)
                XCTAssertEqual(replayed.activeStore, sourceStore)
                guard replayed.activeStore.id == sourceStore.id,
                    FileManager.default.fileExists(atPath: sourceStoreURL.path)
                else {
                    return XCTFail("The refused replay must keep the original source active and on disk")
                }
                let refusedSource = try await reopened.libraryForTransition(storeID: sourceStore.id)
                let refusedTransfer = try await refusedSource.transferSnapshot(revision: sourceStore.revision)
                let refusedDormant = try await refusedSource.dormantCloudBases()
                let refusedArchive = try await refusedSource.archive()
                XCTAssertEqual(refusedTransfer, originalSource)
                XCTAssertEqual(refusedDormant, originalDormant)
                XCTAssertEqual(refusedArchive.seenRequestIDs, originalArchive.seenRequestIDs)
                let refused = try XCTUnwrap(replayed.transition)
                XCTAssertEqual(refused.id, transition.id)
                XCTAssertEqual(refused.candidateStoreID, candidateStore.id)
                XCTAssertEqual(refused.phase, .candidateReady)
                XCTAssertNil(refused.mergeIntent)
                XCTAssertNil(refused.sendAttempt)
                XCTAssertFalse(refused.freezesSource)
                XCTAssertEqual(retained.namespaces, evidence.namespaces)
                XCTAssertEqual(retained.transfers, evidence.transfers)
                XCTAssertEqual(retained.blobs, evidence.blobs)
                XCTAssertEqual(try Data(contentsOf: planURL), planBeforeReplay)
                XCTAssertEqual(try Data(contentsOf: stagedAttachmentURL), attachmentBytes)
                let untouched = try await reopened.libraryForTransition(storeID: candidateStore.id)
                let untouchedTarget = try await untouched.transferSnapshot(revision: candidateStore.revision)
                let untouchedAccepted = try await untouched.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
                let absentReceipt = try await untouched.failedEnableReenableReceipts(
                    namespaceKey: namespace.namespaceKey.rawValue, transitionID: transition.id
                )
                XCTAssertEqual(untouchedTarget, targetBeforeReplay)
                XCTAssertEqual(untouchedAccepted.readyEntities, acceptedBeforeReplay.readyEntities)
                XCTAssertEqual(untouchedAccepted.deferredEntities, acceptedBeforeReplay.deferredEntities)
                XCTAssertNil(absentReceipt.modern)
                XCTAssertNil(absentReceipt.ambiguous)
                let transportEvents = await replayTransport.events()
                XCTAssertTrue(transportEvents.isEmpty)
                let remoteAfterRefusal = await server.fullSnapshot(for: snipRecordID)
                let typesAfterRefusal = await server.storedRecordTypes(in: zone)
                let snipSavesAfterRefusal = await server.acceptedOperationCount(for: snipRecordID)
                let deletesAfterRefusal = await server.acceptedDeletionCount()
                XCTAssertEqual(remoteAfterRefusal, firstRemote)
                XCTAssertEqual(typesAfterRefusal, baselineTypes)
                XCTAssertEqual(snipSavesAfterRefusal, beforeSnipSaves)
                XCTAssertEqual(deletesAfterRefusal, beforeDeletes)

                let writable = try await reopened.activeLibrary()
                let writableDate = Date(timeIntervalSince1970: 60)
                _ = try await writable.perform(
                    .update(id: snipID, content: "source remains writable", attachmentURLs: nil,
                        expectedUpdatedAt: editedDate, now: writableDate), sortedBy: .manual
                )
                let afterWrite = try await writable.checkedSnapshot(sortedBy: .manual)
                var expectedWrite = expectedSource
                expectedWrite.content = "source remains writable"
                expectedWrite.updatedAt = writableDate
                XCTAssertEqual(afterWrite.snips, [expectedWrite])
                XCTAssertEqual(Set(afterWrite.lists), expectedLists)
                let sourceAttachment = try XCTUnwrap(afterWrite.attachmentURLs[attachment.id])
                XCTAssertEqual(try Data(contentsOf: sourceAttachment), attachmentBytes)
                let afterWriteState = try await reopened.snapshot()
                XCTAssertEqual(afterWriteState.activeStore.id, sourceStore.id)
                XCTAssertGreaterThan(afterWriteState.activeStore.revision, sourceStore.revision)
                XCTAssertEqual(afterWriteState.transition?.phase, .candidateReady)
                let afterWriteEvidence = try XCTUnwrap(try files.read(sourceStore.id))
                XCTAssertEqual(afterWriteEvidence.namespaces, retained.namespaces)
                XCTAssertEqual(afterWriteEvidence.transfers, retained.transfers)
                XCTAssertEqual(afterWriteEvidence.blobs, retained.blobs)
                XCTAssertEqual(try Data(contentsOf: planURL), planBeforeReplay)
                XCTAssertEqual(try Data(contentsOf: stagedAttachmentURL), attachmentBytes)
                continue
            }

            XCTAssertEqual(result.state, .on)
            XCTAssertNil(replayed.transition)
            XCTAssertEqual(replayed.activeStore.id, candidateStore.id)
            XCTAssertEqual(replayed.activeStore.namespace, namespace.binding)
            // Successful activation can retire the original root. The capture outlives it.
            XCTAssertEqual(retainedCapture.freeze, capture.freeze)
            XCTAssertEqual(retainedCapture.sourceDigest, capture.sourceDigest)
            XCTAssertEqual(retainedCapture.seenRequestIDs, [FailedEnableEncoding.uuid(requestID)])
            XCTAssertEqual(retainedCapture.records.map(\.reference), capture.records.map(\.reference))
            XCTAssertEqual(retainedCapture.records.map(\.source), capture.records.map(\.source))
            XCTAssertEqual(retainedCapture.records.map(\.preparation), capture.records.map(\.preparation))
            XCTAssertEqual(retainedTransfer.state, .checked)
            XCTAssertEqual(retainedTransfer.planDigest, transfer.planDigest)
            XCTAssertEqual(retainedTransfer.dormantDigest, transfer.dormantDigest)
            XCTAssertEqual(retainedTransfer.outputs, transfer.outputs)
            XCTAssertTrue(retainedGroup.reviews.isEmpty)
            XCTAssertTrue(retainedGroup.alternatives.isEmpty)
            for (hash, bytes) in evidence.blobs {
                XCTAssertEqual(retained.blobs[hash], bytes)
            }
            let reopenedLibrary = try await reopened.activeLibrary()
            let final = try await reopenedLibrary.checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(final.snips, [expectedOutput])
            XCTAssertEqual(Set(final.lists), expectedLists)
            XCTAssertEqual(Set(final.attachmentURLs.keys), [attachment.id])
            let finalURL = try XCTUnwrap(final.attachmentURLs[attachment.id])
            XCTAssertEqual(try Data(contentsOf: finalURL), attachmentBytes)
            let active = try await reopened.libraryForTransition(storeID: candidateStore.id)
            let activeArchive = try await active.archive()
            XCTAssertEqual(activeArchive.seenRequestIDs, originalArchive.seenRequestIDs)
            let recovery = try await active.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
            XCTAssertTrue(recovery.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: planURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedAttachmentURL.path))
            XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: root.path)
                .contains { $0.contains("full-reenable-v1") && $0.hasSuffix("plan.json") })

            let remoteValue = await server.fullSnapshot(for: snipRecordID)
            let remote = try CloudFullRecordCodec.snip(from: try XCTUnwrap(remoteValue))
            XCTAssertEqual(remote.id, snipRecordID)
            XCTAssertEqual(remote.domainID, snipID)
            XCTAssertEqual(remote.requestID, .value(requestID))
            XCTAssertEqual(remote.createdAt, .value(originalDate))
            XCTAssertEqual(remote.updatedAt, .value(originalDate))
            XCTAssertEqual(remote.origin, .value(SnipOrigin.quickEntry.rawValue))
            XCTAssertEqual(remote.text, .value("changed while local"))
            XCTAssertEqual(remote.source, .value(nil))
            XCTAssertEqual(remote.isDone, .value(false))
            XCTAssertNil(remote.pinnedAt)
            XCTAssertEqual(remote.placement, .value(CloudSnipPlacement(
                listID: SnipList.inboxID, orderKey: base.manualSortKey)))
            for list in [SnipList.inbox, pink, red] {
                let id = CloudRecordID.list(list.id, in: zone)
                let value = await server.fullSnapshot(for: id)
                let record = try CloudFullRecordCodec.list(from: try XCTUnwrap(value))
                XCTAssertEqual(record.id, id)
                XCTAssertEqual(record.domainID, list.id)
                XCTAssertEqual(record.desiredName, .value(list.desiredName))
                XCTAssertEqual(record.systemImage, .value(list.systemImage))
                XCTAssertEqual(record.color, .some(.value(list.color)))
                XCTAssertEqual(record.orderKey, .value(list.sortKey))
            }
            let remoteTexts = await server.storedTextValues()
            let remoteTypes = await server.storedRecordTypes(in: zone)
            XCTAssertEqual(remoteTexts, ["changed while local"])
            XCTAssertEqual(remoteTypes, ["List", "List", "List", "Snip"])
        }
    }

    func testFullReenableRecoveryUnfreezesSourceForStaleCASAndCorruptPlan() async throws {
        for failure in ["stale-cas", "corrupt-plan"] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let initial = try SwiftDataSyncModePersistence(rootURL: root)
            let initialLocal = try await initial.activeLibrary()
            try await add("base", to: initialLocal)
            let namespace = makeNamespace()
            let zone = textZone(namespace)
            let server = FakeCloudServer()
            let first = ICloudSyncModeCoordinator(
                persistence: initial,
                namespace: namespace,
                textZone: zone,
                makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
            )
            _ = try await first.enableOrRetry()
            _ = try await first.optOut(.useCurrentCacheAfterStaleDataWarning)
            let local = try await initial.activeLibrary()
            let localSnapshot = await local.snapshot(sortedBy: .manual)
            let base = try XCTUnwrap(localSnapshot.snips.first)
            let attachmentURL = root.appendingPathComponent("recovery-test.txt")
            try Data("expected bytes".utf8).write(to: attachmentURL)
            _ = try await local.perform(
                .update(
                    id: base.id,
                    content: "offline",
                    attachmentURLs: [attachmentURL],
                    expectedUpdatedAt: base.updatedAt,
                    now: Date(timeIntervalSince1970: 40)
                ),
                sortedBy: .manual
            )
            let crash = CrashInjector(point: .beforeCandidateMergeDurability)
            let crashing = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
            let coordinator = ICloudSyncModeCoordinator(
                persistence: crashing,
                namespace: namespace,
                textZone: zone,
                makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
            )
            do {
                _ = try await coordinator.enableOrRetry()
                XCTFail("Expected staged-plan crash")
            } catch CrashInjector.Failure.injected {}
            let crashed = try await crashing.snapshot()
            let transition = try XCTUnwrap(crashed.transition)
            let candidate = try await crashing.libraryForTransition(
                storeID: transition.candidateStoreID
            )
            if failure == "stale-cas" {
                let listID = UUID()
                let accepted = CloudAcceptedEntityInput(
                    reference: CloudEntityReference(kind: .list, domainID: listID),
                    identity: CloudTextStorageIdentity(
                        zoneName: zone.name,
                        ownerName: zone.ownerName,
                        recordName: "l-\(listID.uuidString.lowercased())"
                    ),
                    schemaVersion: 2,
                    acceptedData: Data("added".utf8),
                    presenceData: Data("presence".utf8),
                    shadowData: Data("shadow".utf8),
                    systemFields: Data("system".utf8),
                    dependencyListID: nil
                )
                let wire = try await candidate.cloudTextSyncSnapshot(
                    namespaceKey: namespace.namespaceKey
                )
                let batch = CloudFullBatchCommit(
                    namespaceKey: namespace.namespaceKey.rawValue,
                    batchID: UUID(),
                    expectedEngineState: wire.engineState,
                    nextEngineState: wire.engineState,
                    items: [CloudFullBatchItem(
                        accepted: accepted,
                        expectedLocalRevision: nil,
                        expectedSystemFields: nil,
                        localMutation: .none,
                        conflict: nil,
                        quarantine: nil
                    )]
                )
                try await candidate.stageCloudFullBatch(batch)
                _ = try await candidate.commitCloudFullBatch(batch)
            } else {
                let planPath = try XCTUnwrap(
                    FileManager.default.subpathsOfDirectory(atPath: root.path)
                        .first { $0.contains("full-reenable-v1") && $0.hasSuffix("plan.json") }
                )
                try Data("corrupt".utf8).write(to: root.appendingPathComponent(planPath))
            }

            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            let retry = ICloudSyncModeCoordinator(
                persistence: reopened,
                namespace: namespace,
                textZone: zone,
                makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
            )
            do {
                _ = try await retry.enableOrRetry()
                XCTFail("Expected staged re-enable recovery failure")
            } catch {
                if failure == "stale-cas" {
                    XCTAssertEqual(error as? CloudFullStorageError, .staleAcceptedEntity)
                } else {
                    XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
                }
            }
            let recovered = try await reopened.snapshot()
            XCTAssertEqual(recovered.transition?.phase, .candidateReady)
            XCTAssertNil(recovered.transition?.mergeIntent)
            XCTAssertEqual(
                recovered.attentionReason,
                failure == "stale-cas" ? nil : .storageFailure
            )
            XCTAssertFalse(
                try FileManager.default.subpathsOfDirectory(atPath: root.path)
                    .contains { $0.contains("full-reenable-v1") && $0.hasSuffix("plan.json") }
            )
            let source = try await reopened.activeLibrary()
            let sourceSnapshot = await source.snapshot(sortedBy: .manual)
            let sourceBase = try XCTUnwrap(sourceSnapshot.snips.first)
            _ = try await source.perform(
                .update(
                    id: sourceBase.id,
                    content: "source is writable",
                    attachmentURLs: nil,
                    expectedUpdatedAt: sourceBase.updatedAt,
                    now: Date(timeIntervalSince1970: 50)
                ),
                sortedBy: .manual
            )
        }
    }

    func testFullReenableReceiptDigestMismatchDiscardsCandidateAndCanRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try SwiftDataSyncModePersistence(rootURL: root)
        let initialLocal = try await initial.activeLibrary()
        let requestID = UUID()
        let createdAt = Date(timeIntervalSince1970: 10)
        let editedAt = Date(timeIntervalSince1970: 60)
        let added = try await initialLocal.perform(
            .add(content: "base", origin: .quickEntry, source: nil, listID: SnipList.inboxID,
                attachmentURLs: [], requestID: requestID, now: createdAt),
            sortedBy: .manual
        )
        guard case .add(.added(let snipID)) = added.outcome else {
            return XCTFail("Expected one managed snip")
        }
        let initialContents = try await initialLocal.checkedSnapshot(sortedBy: .manual)
        let base = try XCTUnwrap(initialContents.snips.first)
        XCTAssertEqual(initialContents.snips.count, 1)
        XCTAssertEqual(initialContents.lists, [SnipList.inbox])
        XCTAssertEqual(base.id, snipID)
        XCTAssertEqual(base.requestID, requestID)
        XCTAssertEqual(base.content, "base")
        XCTAssertEqual(base.createdAt, createdAt)
        XCTAssertEqual(base.updatedAt, createdAt)
        XCTAssertEqual(base.origin, .quickEntry)
        XCTAssertEqual(base.listID, SnipList.inboxID)
        XCTAssertFalse(base.isDone)
        XCTAssertNil(base.source)
        XCTAssertNil(base.pinnedAt)
        XCTAssertTrue(base.attachments.isEmpty)

        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let first = ICloudSyncModeCoordinator(
            persistence: initial, namespace: namespace, textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let enabled = try await first.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let disabled = try await first.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(disabled.state, .off)
        let local = try await initial.activeLibrary()
        let off = try await local.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(off.snips, [base])
        let inputURL = root.appendingPathComponent("receipt-boundary.txt")
        let bytes = Data("receipt mismatch attachment\n".utf8)
        try bytes.write(to: inputURL)
        _ = try await local.perform(
            .update(id: snipID, content: "offline edit", attachmentURLs: [inputURL],
                expectedUpdatedAt: createdAt, now: editedAt), sortedBy: .manual
        )
        try FileManager.default.removeItem(at: inputURL)
        let sourceStore = try await initial.snapshot().activeStore
        let source = try await initial.libraryForTransition(storeID: sourceStore.id)
        let sourceBefore = try await source.transferSnapshot(revision: sourceStore.revision)
        let dormantBefore = try await source.dormantCloudBases()
        let sourceArchive = try await source.archive()
        XCTAssertEqual(sourceArchive.seenRequestIDs, [requestID])
        let edited = try XCTUnwrap(sourceBefore.snips.first)
        let attachment = try XCTUnwrap(edited.attachments.first)
        XCTAssertEqual(edited.attachments.count, 1)
        XCTAssertEqual(attachment.fileName, "receipt-boundary.txt")
        XCTAssertEqual(attachment.byteCount, Int64(bytes.count))
        let expectedBytes = [attachment.id: bytes]
        var expectedSource = base
        expectedSource.content = "offline edit"
        expectedSource.updatedAt = editedAt
        expectedSource.attachments = [attachment]
        XCTAssertEqual(sourceBefore.snips, [expectedSource])
        XCTAssertEqual(sourceBefore.lists, [SnipList.inbox])
        XCTAssertEqual(sourceBefore.attachmentData, expectedBytes)
        var expectedOutput = expectedSource
        expectedOutput.updatedAt = createdAt
        let snipRecordID = CloudRecordID.snip(snipID, in: zone)
        let serverBefore = await server.fullSnapshot(for: snipRecordID)
        let originalRecord = try CloudFullRecordCodec.snip(from: try XCTUnwrap(serverBefore))
        XCTAssertEqual(originalRecord.text, .value("base"))
        XCTAssertEqual(originalRecord.requestID, .value(requestID))
        XCTAssertEqual(originalRecord.updatedAt, .value(createdAt))
        let serverTypesBefore = await server.storedRecordTypes(in: zone)
        let snipSavesBefore = await server.acceptedOperationCount(for: snipRecordID)
        let deletesBefore = await server.acceptedDeletionCount()

        let crash = CrashInjector(point: .afterCandidateMergeDurability)
        let crashing = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
        let interrupted = ICloudSyncModeCoordinator(
            persistence: crashing, namespace: namespace, textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        do {
            _ = try await interrupted.enableOrRetry()
            return XCTFail("Expected the crash after the private apply and typed receipt commit")
        } catch CrashInjector.Failure.injected {}
        let crashed = try await crashing.snapshot()
        let transition = try XCTUnwrap(crashed.transition)
        let intent = try XCTUnwrap(transition.mergeIntent)
        let token = try XCTUnwrap(transition.freezeToken)
        XCTAssertEqual(crashed.activeStore, sourceStore)
        XCTAssertEqual(transition.phase, .sourceFrozen)
        XCTAssertEqual(transition.namespace, namespace.binding)
        XCTAssertEqual(intent.sourceRevision, sourceStore.revision)
        XCTAssertEqual(intent.fullReenablePlanID, transition.id)
        XCTAssertNil(transition.sendAttempt)
        let manifest = await crashing.manifest
        let candidateStore = try XCTUnwrap(manifest.stores.first { $0.id == transition.candidateStoreID })
        let candidate = try await crashing.libraryForTransition(storeID: candidateStore.id)
        let candidateBefore = try await candidate.transferSnapshot(revision: candidateStore.revision)
        let acceptedBefore = try await candidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(candidateBefore.snips, [expectedOutput])
        XCTAssertEqual(candidateBefore.lists, [SnipList.inbox])
        XCTAssertEqual(candidateBefore.attachmentData, expectedBytes)

        let manifestURL = root.appendingPathComponent("activation.json")
        let manifestBefore = try Data(contentsOf: manifestURL)
        let candidateRoot = root.appendingPathComponent(candidateStore.relativeRoot, isDirectory: true)
        let candidateURL = candidateRoot.appendingPathComponent("snips.store")
        let stagedRoot = candidateRoot.appendingPathComponent("full-reenable-v1", isDirectory: true)
            .appendingPathComponent(transition.id.uuidString.lowercased(), isDirectory: true)
        let planURL = stagedRoot.appendingPathComponent("plan.json")
        let planBefore = try Data(contentsOf: planURL)
        let staged = try JSONDecoder().decode(CloudFullReenableStagedPlan.self, from: planBefore)
        let restored = try staged.restore(from: stagedRoot)
        XCTAssertNil(restored.acceptedLegacyDigest)
        XCTAssertEqual(restored.plan.planDigest, intent.planDigest)
        XCTAssertEqual(restored.plan.transitionID, transition.id)
        XCTAssertEqual(restored.plan.namespaceKey, namespace.namespaceKey.rawValue)
        XCTAssertEqual(restored.plan.targetRevision, candidateStore.revision)
        XCTAssertEqual(restored.plan.attachmentData, expectedBytes)
        let file = try XCTUnwrap(staged.attachmentFiles.first)
        XCTAssertEqual(staged.attachmentFiles.count, 1)
        XCTAssertEqual(file.id, attachment.id)
        let stagedAttachmentURL = stagedRoot.appendingPathComponent(file.relativePath)
        XCTAssertEqual(try Data(contentsOf: stagedAttachmentURL), bytes)
        let files = FailedEnableEvidenceFile(root: root)
        let evidenceURL = files.url(sourceStore.id)
        let evidenceBytes = try Data(contentsOf: evidenceURL)
        let evidence = try XCTUnwrap(try files.read(sourceStore.id))
        let preparationValue = try await crashing.failedEnablePreparedRead(
            transition: transition, digest: intent.planDigest, token: token)
        let preparation = try XCTUnwrap(preparationValue)
        XCTAssertFalse(preparation.requiresTurnOffAbsence)
        XCTAssertEqual(preparation.transfer.state, .prepared)
        XCTAssertEqual(preparation.transfer.planDigest, FailedEnableEncoding.hex(intent.planDigest))
        XCTAssertFalse(preparation.capture.armed)
        XCTAssertEqual(preparation.capture.seenRequestIDs, [FailedEnableEncoding.uuid(requestID)])
        let expectedImage = try FailedEnableSnipImage(expectedSource, attachmentData: expectedBytes)
        XCTAssertTrue(preparation.capture.records.contains { $0.source.value == .snip(expectedImage) })
        let blobHash = FailedEnableEncoding.digest(bytes)
        XCTAssertEqual(evidence.blobs[blobHash], bytes)

        let namespaceKey = namespace.namespaceKey.rawValue
        let operation = CloudFullReceiptOperation.reenableTransition(transition.id)
        let modernKey = operation.storageKey(namespaceKey: namespaceKey)
        let ambiguousKey = CloudFullReceiptOperation.committedBatch(transition.id).storageKey(namespaceKey: namespaceKey)
        let corruptedDigest = Data(repeating: 0xEE, count: 32)
        XCTAssertNotEqual(intent.planDigest, corruptedDigest)
        let originalReceipt = try await candidate.failedEnableReenableReceipts(
            namespaceKey: namespaceKey, transitionID: transition.id)
        XCTAssertEqual(originalReceipt.modern, intent.planDigest)
        XCTAssertNil(originalReceipt.ambiguous)

        let recognized = try await candidate.recognizesFailedEnablePrepared(
            preparation, digest: intent.planDigest, evidenceRoot: root)
        XCTAssertTrue(recognized)

        // Edit the existing row in the disposable current-schema store under its real file lock.
        do {
            guard FileManager.default.fileExists(atPath: candidateURL.path) else {
                return XCTFail("The committed candidate must exist before receipt injection")
            }
            let lock = try SnipStoreFileLock(url: candidateURL.appendingPathExtension("lock"))
            defer { withExtendedLifetime(lock) {} }
            let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
            let configuration = ModelConfiguration("SnipSnapLocal", schema: schema, url: candidateURL,
                cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = SwiftDataSnipLibrary.makeContext(container: container)
            let descriptor = FetchDescriptor<StoredCloudFullBatchReceipt>()
            let rows = try context.fetch(descriptor)
            XCTAssertEqual(rows.filter { $0.id == modernKey }.count, 1)
            XCTAssertFalse(rows.contains { $0.id == ambiguousKey })
            let row = try XCTUnwrap(rows.first { $0.id == modernKey })
            XCTAssertTrue(operation.matches(row, namespaceKey: namespaceKey))
            XCTAssertEqual(row.namespaceKey, namespaceKey)
            XCTAssertEqual(row.batchID, transition.id)
            guard row.digest == intent.planDigest, row.digest != corruptedDigest else {
                return XCTFail("Fault injection requires the original committed plan digest")
            }
            let identity = row.persistentModelID
            let originalCreatedAt = row.createdAt
            let digests = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.digest) })

            row.digest = corruptedDigest
            try lock.check()
            try context.save()

            let readback = try SwiftDataSnipLibrary.makeContext(container: container).fetch(descriptor)
            let persisted = try XCTUnwrap(readback.first { $0.id == modernKey })
            XCTAssertEqual(persisted.persistentModelID, identity)
            XCTAssertTrue(operation.matches(persisted, namespaceKey: namespaceKey))
            XCTAssertEqual(persisted.batchID, transition.id)
            XCTAssertEqual(persisted.createdAt, originalCreatedAt)
            XCTAssertEqual(persisted.digest, corruptedDigest)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: readback.map { ($0.id, $0.digest) }),
                digests.merging([modernKey: corruptedDigest]) { _, changed in changed })
        }

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: evidenceURL), evidenceBytes)
        XCTAssertEqual(try Data(contentsOf: planURL), planBefore)
        XCTAssertEqual(try Data(contentsOf: stagedAttachmentURL), bytes)
        let candidateAfterInjection = try await candidate.transferSnapshot(revision: candidateStore.revision)
        let acceptedAfterInjection = try await candidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(candidateAfterInjection, candidateBefore)
        XCTAssertEqual(acceptedAfterInjection, acceptedBefore)
        let mutatedReceipt = try await candidate.failedEnableReenableReceipts(
            namespaceKey: namespaceKey, transitionID: transition.id)
        XCTAssertEqual(mutatedReceipt.modern, corruptedDigest)
        XCTAssertNil(mutatedReceipt.ambiguous)
        do {
            _ = try await candidate.recognizesFailedEnablePrepared(
                preparation, digest: intent.planDigest, evidenceRoot: root)
            return XCTFail("A valid preparation with the altered typed receipt must be rejected")
        } catch CloudFullStorageError.invalidBatchReplay {}

        let reopened = try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: { point in
                if point == .beforePointerSwap {
                    XCTFail("The rejected receipt must not reach pointer swap")
                    throw CrashInjector.Failure.injected
                }
            },
            writeHook: { point in
                if point == .beforeFullReenablePlanApply {
                    XCTFail("The rejected receipt must not enter private apply")
                    throw CrashInjector.Failure.injected
                }
            }
        )
        let reopenedManifest = await reopened.manifest
        XCTAssertEqual(reopenedManifest, manifest)
        let rejectingTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let rejecting = ICloudSyncModeCoordinator(
            persistence: reopened, namespace: namespace, textZone: zone,
            makeTransport: { rejectingTransport }
        )
        do {
            _ = try await rejecting.enableOrRetry()
            return XCTFail("Expected the matching coordinator to report the receipt failure")
        } catch let error as SyncModePersistenceError {
            XCTAssertEqual(error, .storageFailure)
        }
        let refused = try await reopened.snapshot()
        XCTAssertEqual(refused.activeStore, sourceStore)
        XCTAssertFalse(refused.transition?.freezesSource ?? false)
        XCTAssertEqual(refused.attentionReason, .storageFailure)
        let events = await rejectingTransport.events()
        let serverAfter = await server.fullSnapshot(for: snipRecordID)
        let serverTypesAfter = await server.storedRecordTypes(in: zone)
        let snipSavesAfter = await server.acceptedOperationCount(for: snipRecordID)
        let deletesAfter = await server.acceptedDeletionCount()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(serverAfter, serverBefore)
        XCTAssertEqual(serverTypesAfter, serverTypesBefore)
        XCTAssertEqual(snipSavesAfter, snipSavesBefore)
        XCTAssertEqual(deletesAfter, deletesBefore)
        guard refused.activeStore.id == sourceStore.id,
            FileManager.default.fileExists(atPath: root.appendingPathComponent(sourceStore.relativeRoot)
                .appendingPathComponent("snips.store").path)
        else {
            return XCTFail("Receipt refusal must preserve the original active source on disk")
        }
        let refusedSource = try await reopened.libraryForTransition(storeID: sourceStore.id)
        let refusedTransfer = try await refusedSource.transferSnapshot(revision: sourceStore.revision)
        let refusedDormant = try await refusedSource.dormantCloudBases()
        let refusedArchive = try await refusedSource.archive()
        XCTAssertEqual(refusedTransfer, sourceBefore)
        XCTAssertEqual(refusedDormant, dormantBefore)
        XCTAssertEqual(refusedArchive.seenRequestIDs, [requestID])
        let retained = try XCTUnwrap(try files.read(sourceStore.id))
        XCTAssertEqual(retained.namespaces, evidence.namespaces)
        XCTAssertEqual(retained.transfers, evidence.transfers)
        XCTAssertEqual(retained.blobs, evidence.blobs)
        XCTAssertEqual(retained.blobs[blobHash], bytes)
        XCTAssertEqual(try Data(contentsOf: planURL), planBefore)
        XCTAssertEqual(try Data(contentsOf: stagedAttachmentURL), bytes)
        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return XCTFail("Receipt refusal lost the still-prepared candidate and its actual receipt")
        }
        // The old candidate handle permits observation even if the owner has marked the root deleting.
        let refusedCandidate = try await candidate.transferSnapshot(revision: candidateStore.revision)
        let refusedAccepted = try await candidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        let refusedReceipt = try await candidate.failedEnableReenableReceipts(
            namespaceKey: namespaceKey, transitionID: transition.id)
        XCTAssertEqual(refusedCandidate, candidateBefore)
        XCTAssertEqual(refusedAccepted, acceptedBefore)
        XCTAssertEqual(refusedReceipt.modern, corruptedDigest)
        XCTAssertNil(refusedReceipt.ambiguous)

        let reference = CloudEntityReference(kind: .snip, domainID: snipID)
        let preApplyRows = AsyncStream.makeStream(
            of: (storeID: UUID, transitionID: UUID, row: CloudAcceptedEntity, namespaceRevision: UInt64).self
        )
        let retryOwner = try SwiftDataSyncModePersistence(rootURL: root, writeHook: { point in
            guard point == .beforeFullReenablePlanApply else { return }
            // Preparation has observed this candidate, but apply and send have not changed its fetched row.
            let current = try JSONDecoder().decode(SwiftDataSyncModePersistence.Manifest.self,
                from: Data(contentsOf: manifestURL))
            let retryTransition = try XCTUnwrap(current.transition)
            XCTAssertEqual(current.activeStoreID, sourceStore.id)
            XCTAssertEqual(retryTransition.phase, .sourceFrozen)
            XCTAssertEqual(retryTransition.namespace, namespace.binding)
            XCTAssertNotNil(retryTransition.mergeIntent)
            XCTAssertNil(retryTransition.sendAttempt)
            let store = try XCTUnwrap(current.stores.first { $0.id == retryTransition.candidateStoreID })
            XCTAssertNotEqual(store.id, candidateStore.id)
            XCTAssertEqual(store.namespace, namespace.binding)
            let storeURL = root.appendingPathComponent(store.relativeRoot).appendingPathComponent("snips.store")
            _ = try XCTUnwrap(FileManager.default.fileExists(atPath: storeURL.path) ? storeURL : nil)
            let lock = try SnipStoreFileLock(url: storeURL.appendingPathExtension("lock"))
            defer { withExtendedLifetime(lock) {} }
            let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
            let configuration = ModelConfiguration("SnipSnapLocal", schema: schema, url: storeURL,
                allowsSave: false, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = SwiftDataSnipLibrary.makeContext(container: container)
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<StoredCloudEntityRecord>()).first {
                $0.namespaceKey == namespaceKey && $0.reference == reference
            })
            let row = try SwiftDataSnipLibrary.entity(from: record)
            let enrollment = try XCTUnwrap(context.fetch(FetchDescriptor<StoredCloudFullEnrollment>()).first {
                $0.namespaceKey == namespaceKey
            })
            let state = try SwiftDataSnipLibrary.fullEnrollmentState(from: enrollment.referencesData).namespaceState
            XCTAssertEqual(state.phase, .active)
            XCTAssertFalse(context.hasChanges)
            try lock.check()
            preApplyRows.continuation.yield((store.id, retryTransition.id, row, state.revision))
        })
        let retry = ICloudSyncModeCoordinator(
            persistence: retryOwner, namespace: namespace, textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let comparison = try await retry.enableOrRetry()
        XCTAssertEqual(comparison.state, .needsAttention)
        let beforeChoice = try await retryOwner.snapshot()
        XCTAssertEqual(beforeChoice.activeStore, sourceStore)
        XCTAssertNotEqual(beforeChoice.transition?.candidateStoreID, candidateStore.id)
        let review = SnipSyncModeStore(retryOwner).failedEnableReview
        let reviews = try await review.snapshot()
        XCTAssertEqual(reviews.sourceStoreID, sourceStore.id)
        XCTAssertEqual(reviews.issues.map(\.entityID), [.snip(snipID)])
        let issue = try XCTUnwrap(reviews.issues.first { $0.entityID == .snip(snipID) },
            "The retained unqualified edit must be available in a fresh comparison")
        XCTAssertEqual(issue.reason, .unknownOutcome)
        XCTAssertEqual(issue.serverState, .value)
        XCTAssertEqual(issue.allowedChoices, [.useDevice])
        XCTAssertTrue(issue.earlierLocalVersions.isEmpty)
        guard case .snip(let localVersion)? = issue.localVersionAtReview,
            case .snip(let serverVersion)? = issue.serverFieldsAtReview
        else {
            return XCTFail("Expected the actual local edit and fetched server preimage")
        }
        XCTAssertEqual(localVersion, expectedSource)
        XCTAssertEqual(serverVersion, base)
        let selected = try await review.choose(issue.id, selection: .useDevice, expecting: issue.expectation)
        XCTAssertEqual(selected.issueID, issue.id)
        XCTAssertEqual(selected.selection, .useDevice)
        XCTAssertTrue(selected.outputs.isEmpty)
        let afterChoice = try await retryOwner.snapshot()
        XCTAssertEqual(afterChoice, beforeChoice)
        let serverAfterChoice = await server.fullSnapshot(for: snipRecordID)
        XCTAssertEqual(serverAfterChoice, serverBefore)

        let result = try await retry.enableOrRetry()
        let completed = try await retryOwner.snapshot()
        XCTAssertEqual(result.state, .on, "Retry attention: \(String(describing: result.attentionReason))")
        XCTAssertNil(completed.transition)
        XCTAssertNotEqual(completed.activeStore.id, candidateStore.id)
        XCTAssertEqual(completed.activeStore.namespace, namespace.binding)
        let final = try await retryOwner.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips, [expectedSource])
        XCTAssertEqual(final.lists, [SnipList.inbox])
        XCTAssertEqual(Set(final.attachmentURLs.keys), [attachment.id])
        let finalURL = try XCTUnwrap(final.attachmentURLs[attachment.id])
        XCTAssertEqual(try Data(contentsOf: finalURL), bytes)
        let finalRemote = await server.fullSnapshot(for: snipRecordID)
        let remote = try CloudFullRecordCodec.snip(from: try XCTUnwrap(finalRemote))
        XCTAssertEqual(remote.id, snipRecordID)
        XCTAssertEqual(remote.requestID, .value(requestID))
        XCTAssertEqual(remote.text, .value("offline edit"))
        XCTAssertEqual(remote.createdAt, .value(createdAt))
        XCTAssertEqual(remote.updatedAt, .value(editedAt))
        XCTAssertEqual(remote.origin, .value(SnipOrigin.quickEntry.rawValue))
        XCTAssertEqual(remote.isDone, .value(false))
        XCTAssertEqual(remote.source, .value(nil))
        XCTAssertNil(remote.pinnedAt)
        XCTAssertEqual(remote.placement, .value(CloudSnipPlacement(
            listID: SnipList.inboxID, orderKey: base.manualSortKey)))
        let finalTexts = await server.storedTextValues()
        let finalTypes = await server.storedRecordTypes(in: zone)
        XCTAssertEqual(finalTexts, ["offline edit"])
        XCTAssertEqual(finalTypes, ["List", "Snip"])
        let afterRetry = try XCTUnwrap(try files.read(sourceStore.id))
        let retainedGroup = try XCTUnwrap(afterRetry.namespaces.first { $0.binding == preparation.transfer.namespace })
        preApplyRows.continuation.finish()
        var preApplyIterator = preApplyRows.stream.makeAsyncIterator()
        let retryPreimage = await preApplyIterator.next()
        let checked = try XCTUnwrap(retryPreimage, "Expected exactly one checked retry row before apply")
        let extraPreimage = await preApplyIterator.next()
        XCTAssertNil(extraPreimage)
        XCTAssertEqual(checked.storeID, completed.activeStore.id)
        XCTAssertTrue(retainedGroup.captures.contains {
            $0.transitionID == FailedEnableEncoding.uuid(checked.transitionID)
                && $0.candidateStoreID == FailedEnableEncoding.uuid(checked.storeID)
        })
        var retainedCapture = try XCTUnwrap(retainedGroup.captures.first { $0.id == preparation.capture.id })
        let snipReference = FailedEnableReference(reference)
        let oldRecord = try XCTUnwrap(preparation.capture.records.first { $0.reference == snipReference })
        let recordIndex = try XCTUnwrap(retainedCapture.records.firstIndex { $0.reference == snipReference })
        let oldObservation = try XCTUnwrap(oldRecord.unqualifiedObservation.value)
        let refreshedObservation = try XCTUnwrap(retainedCapture.records[recordIndex].unqualifiedObservation.value)
        let oldRow = try XCTUnwrap(acceptedBefore.readyEntities.first { $0.reference == reference })
        let identity = CloudTextStorageIdentity(zoneName: zone.name, ownerName: zone.ownerName,
            recordName: "s-\(snipID.uuidString.lowercased())")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (observation, row, storeID, revision) in [
            (oldObservation, oldRow, candidateStore.id, acceptedBefore.namespaceState.revision),
            (refreshedObservation, checked.row, checked.storeID, checked.namespaceRevision),
        ] {
            XCTAssertEqual(row.reference, reference)
            XCTAssertEqual(row.identity, identity)
            XCTAssertEqual(row.schemaVersion, CloudFullRecordCodec.schemaVersion)
            XCTAssertEqual(row.dependencyListID, SnipList.inboxID)
            XCTAssertFalse(row.isDeferred)
            XCTAssertFalse(row.hasUnresolvedLegacyAbsence)
            XCTAssertNil(row.graphRepair)
            XCTAssertNil(row.deferredLocalMutation)
            XCTAssertEqual(observation.kind, .fullRecord)
            XCTAssertEqual(observation.candidateStoreID, FailedEnableEncoding.uuid(storeID))
            XCTAssertEqual(observation.namespaceRevision, String(revision))
            XCTAssertEqual(observation.localRevision, String(row.localRevision))
            XCTAssertFalse(observation.isDeferred)
            XCTAssertFalse(observation.hasUnresolvedLegacyAbsence)
            XCTAssertEqual(observation.dependencyListID.value, FailedEnableEncoding.uuid(SnipList.inboxID))
            let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: observation.entityBase64)
            XCTAssertEqual(envelope.reference, row.reference)
            XCTAssertEqual(envelope.identity, row.identity)
            XCTAssertEqual(envelope.schemaVersion, row.schemaVersion)
            XCTAssertEqual(envelope.dependencyListID, row.dependencyListID)
            XCTAssertEqual(envelope.acceptedData, row.acceptedData)
            XCTAssertEqual(envelope.presenceData, row.presenceData)
            XCTAssertEqual(envelope.shadowData, row.shadowData)
            XCTAssertEqual(envelope.systemFields, row.systemFields)
            XCTAssertEqual(observation.entityBase64, try encoder.encode(envelope))
            XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: envelope.acceptedData),
                originalRecord)
            XCTAssertEqual(try JSONDecoder().decode(CloudTypedSnipRecord.self, from: envelope.presenceData),
                originalRecord)
        }
        // Only this verified review observation may refresh. The qualifying Inbox observation stays exact.
        retainedCapture.records[recordIndex].unqualifiedObservation = oldRecord.unqualifiedObservation
        XCTAssertEqual(retainedCapture, preparation.capture)
        XCTAssertTrue(afterRetry.transfers.contains(preparation.transfer))
        XCTAssertEqual(afterRetry.blobs[blobHash], bytes)
        XCTAssertEqual(try Data(contentsOf: planURL), planBefore)
        XCTAssertEqual(try Data(contentsOf: stagedAttachmentURL), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
    }

    func testFullReenableRemoteDeleteDropsUnchangedSnipWithoutRecovery() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        try await add("unchanged", to: source)
        let sourceSnapshot = await source.snapshot(sortedBy: .manual)
        let base = try XCTUnwrap(sourceSnapshot.snips.first)
        XCTAssertEqual(sourceSnapshot.snips.count, 1)
        XCTAssertEqual(sourceSnapshot.lists, [SnipList.inbox])
        XCTAssertEqual(base.content, "unchanged")
        XCTAssertEqual(base.origin, .quickEntry)
        XCTAssertNil(base.source)
        XCTAssertFalse(base.isDone)
        XCTAssertNil(base.pinnedAt)
        XCTAssertEqual(base.listID, SnipList.inbox.id)
        XCTAssertTrue(base.attachments.isEmpty)
        XCTAssertEqual(base.updatedAt, base.createdAt)
        let inbox = try XCTUnwrap(sourceSnapshot.lists.first)
        let initialManifest = await persistence.manifest
        let initialStore = try XCTUnwrap(initialManifest.stores.first { $0.id == initialManifest.activeStoreID })
        let initialRaw = try await persistence.libraryForTransition(storeID: initialStore.id)
        let initialSource = try await initialRaw.transferSnapshot(revision: initialStore.revision)
        let initialDormant = try await initialRaw.dormantCloudBases()
        XCTAssertEqual(initialSource.snips, [base])
        XCTAssertEqual(initialSource.lists, [inbox])
        XCTAssertTrue(initialSource.attachmentData.isEmpty)
        XCTAssertTrue(initialDormant.isEmpty)
        let snipPresence: [String: FailedEnablePresence] = [
            "createdAt": .value, "id": .value, "isDone": .value, "originRaw": .value,
            "pinnedAt": .value, "placement": .value, "requestID": .value,
            "source": .value, "text": .value, "updatedAt": .value,
        ]
        let listPresence: [String: FailedEnablePresence] = [
            "colorPreset": .value, "desiredName": .value, "id": .value,
            "orderKey": .value, "systemImage": .value, "updatedAt": .value,
        ]
        let snipReference = CloudEntityReference(kind: .snip, domainID: base.id)
        let listReference = CloudEntityReference(kind: .list, domainID: inbox.id)
        let capturedSnipReference = FailedEnableReference(snipReference)
        let capturedListReference = FailedEnableReference(listReference)
        let expectedImages: [FailedEnableReference: FailedEnableImage] = [
            capturedSnipReference: .snip(try FailedEnableSnipImage(base, attachmentData: [:])),
            capturedListReference: .list(FailedEnableListImage(inbox)),
        ]
        let expectedFirstQ: [FailedEnableReference: FailedEnablePreparedValue] = [
            capturedSnipReference: FailedEnablePreparedValue(fields: .snip(FailedEnableSnipValue(
                id: FailedEnableEncoding.uuid(base.id), requestID: FailedEnableEncoding.uuid(base.requestID),
                createdAt: try FailedEnableEncoding.date(base.createdAt), originRaw: SnipOrigin.quickEntry.rawValue,
                text: "unchanged", source: .init(nil), isDone: false, pinnedAt: .init(nil),
                placement: FailedEnablePlacement(listID: FailedEnableEncoding.uuid(inbox.id),
                    orderKey: base.manualSortKey.data),
                updatedAt: try FailedEnableEncoding.date(base.updatedAt))), presence: snipPresence),
            capturedListReference: FailedEnablePreparedValue(fields: .list(FailedEnableListValue(
                id: FailedEnableEncoding.uuid(inbox.id), desiredName: inbox.desiredName,
                systemImage: inbox.systemImage, colorPreset: .init(inbox.color?.rawValue),
                orderKey: inbox.sortKey.data, updatedAt: "0000000000000000")), presence: listPresence),
        ]
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let initialResult = try await coordinator.enableOrRetry()
        XCTAssertEqual(initialResult.state, .on)
        let onManifest = await persistence.manifest
        XCTAssertNil(onManifest.transition)
        let cloudStore = try XCTUnwrap(onManifest.stores.first { $0.id == onManifest.activeStoreID })
        XCTAssertEqual(cloudStore.kind, .iCloudSync)
        XCTAssertEqual(cloudStore.namespace, namespace.binding)
        let cloudRaw = try await persistence.libraryForTransition(storeID: cloudStore.id)
        let initialAccepted = try await cloudRaw.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(Set(initialAccepted.readyEntities.map(\.reference)), Set([snipReference, listReference]))
        XCTAssertEqual(initialAccepted.readyEntities.count, 2)
        XCTAssertTrue(initialAccepted.deferredEntities.isEmpty)
        XCTAssertTrue(initialAccepted.pendingDeletes.isEmpty)
        XCTAssertTrue(initialAccepted.conflicts.isEmpty)
        XCTAssertTrue(initialAccepted.quarantines.isEmpty)
        let files = FailedEnableEvidenceFile(root: root)
        let initialEvidence = try XCTUnwrap(try files.read(initialStore.id))
        let firstGroup = try XCTUnwrap(initialEvidence.namespaces.first {
            $0.binding == FailedEnableBinding(namespace.binding)
        })
        let firstCapture = try XCTUnwrap(firstGroup.captures.last)
        XCTAssertEqual(initialEvidence.sourceStoreID, FailedEnableEncoding.uuid(initialStore.id))
        XCTAssertEqual(initialEvidence.purpose, .installedEvidence)
        XCTAssertEqual(firstCapture.candidateStoreID, FailedEnableEncoding.uuid(cloudStore.id))
        XCTAssertEqual(firstCapture.syncProtocol, .fullRecordV1)
        XCTAssertEqual(firstCapture.freeze.sourceRevision, String(initialStore.revision))
        XCTAssertEqual(firstCapture.sourceDigest, initialEvidence.continuity.sourceDigest)
        XCTAssertEqual(firstCapture.seenRequestIDs, [FailedEnableEncoding.uuid(base.requestID)])
        XCTAssertEqual(firstCapture.normalizer, 1)
        XCTAssertTrue(firstCapture.armed)
        XCTAssertTrue(firstCapture.predecessors.isEmpty)
        XCTAssertTrue(firstCapture.candidateDeletes.isEmpty)
        XCTAssertEqual(Set(firstCapture.records.map(\.reference)), Set(expectedImages.keys))
        XCTAssertEqual(firstCapture.records.count, 2)
        XCTAssertTrue(firstGroup.alternatives.isEmpty)
        XCTAssertTrue(firstGroup.reviews.isEmpty)
        XCTAssertTrue(initialEvidence.blobs.isEmpty)
        let firstTransfer = try XCTUnwrap(initialEvidence.transfers.first {
            $0.sourceCaptureIDs == [firstCapture.id]
        })
        XCTAssertEqual(firstTransfer.kind, .candidate)
        XCTAssertEqual(firstTransfer.state, .checked)
        XCTAssertEqual(firstTransfer.sourceStoreID, initialEvidence.sourceStoreID)
        XCTAssertEqual(firstTransfer.destinationStoreID, firstCapture.candidateStoreID)
        XCTAssertEqual(firstTransfer.namespace, firstGroup.binding)
        XCTAssertEqual(firstTransfer.outputs, expectedImages.values.sorted { $0.reference.sortKey < $1.reference.sortKey })
        XCTAssertTrue(firstTransfer.conflicts.isEmpty)
        XCTAssertTrue(firstTransfer.recoveryDescriptors.isEmpty)
        for record in firstCapture.records {
            let reference = try record.reference.domain
            let actual = try XCTUnwrap(initialAccepted.readyEntities.first { $0.reference == reference })
            let observation = try XCTUnwrap(record.observedAccepted.value)
            let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: observation.entityBase64)
            XCTAssertEqual(record.sourceMembership, .present)
            XCTAssertEqual(record.source.value, expectedImages[record.reference])
            XCTAssertFalse(record.originalAcceptedExists)
            XCTAssertEqual(record.preparation.classification, .nonconflicting)
            XCTAssertEqual(record.preparation.baseKind, .noBaseEnrollment)
            XCTAssertEqual(record.preparation.normalizer, 1)
            XCTAssertEqual(record.preparation.value.value, expectedFirstQ[record.reference])
            let expectedPresence = reference.kind == .snip ? snipPresence : listPresence
            XCTAssertEqual(record.preparation.knownFields, expectedPresence.keys.sorted())
            XCTAssertEqual(record.preparation.normalizedLocal.acceptedPresence, expectedPresence)
            XCTAssertTrue(record.preparation.normalizedLocal.defaults.isEmpty)
            let expectedOverrides: FailedEnableImmutableOverrides? = reference.kind == .snip
                ? FailedEnableImmutableOverrides(requestID: FailedEnableEncoding.uuid(base.requestID),
                    createdAt: try FailedEnableEncoding.date(base.createdAt), originRaw: SnipOrigin.quickEntry.rawValue)
                : nil
            XCTAssertEqual(record.preparation.normalizedLocal.immutableOverrides.value, expectedOverrides)
            XCTAssertNil(record.preparation.baseDigest.value)
            XCTAssertNil(record.preparation.fetchedDigest.value)
            XCTAssertTrue(record.preparation.conflictFields.isEmpty)
            XCTAssertTrue(record.preparation.recoveryIdentities.isEmpty)
            XCTAssertNil(record.unqualifiedObservation.value)
            XCTAssertEqual(observation.kind, .fullRecord)
            XCTAssertEqual(observation.candidateStoreID, firstCapture.candidateStoreID)
            XCTAssertEqual(observation.localRevision, String(actual.localRevision))
            let observedRevision = try FailedEnableEncoding.revision(observation.namespaceRevision)
            XCTAssertLessThanOrEqual(observedRevision, initialAccepted.namespaceState.revision)
            XCTAssertEqual(observation.isDeferred, actual.isDeferred)
            XCTAssertEqual(observation.hasUnresolvedLegacyAbsence, actual.hasUnresolvedLegacyAbsence)
            XCTAssertEqual(observation.dependencyListID.value, actual.dependencyListID.map(FailedEnableEncoding.uuid))
            XCTAssertEqual(envelope.reference, reference)
            XCTAssertEqual(envelope.identity, record.identity.domain)
            XCTAssertEqual(envelope.identity, actual.identity)
            XCTAssertEqual(envelope.schemaVersion, 3)
            XCTAssertEqual(envelope.schemaVersion, actual.schemaVersion)
            XCTAssertEqual(envelope.acceptedData, actual.acceptedData)
            XCTAssertEqual(envelope.presenceData, actual.presenceData)
            XCTAssertEqual(envelope.shadowData, actual.shadowData)
            XCTAssertEqual(envelope.systemFields, actual.systemFields)
            XCTAssertEqual(envelope.dependencyListID, actual.dependencyListID)
            XCTAssertFalse(actual.isDeferred)
            XCTAssertFalse(actual.wasMaterializedBeforeDeferral)
            XCTAssertFalse(actual.hasUnresolvedLegacyAbsence)
            XCTAssertNil(actual.graphRepair)
            XCTAssertNil(actual.deferredLocalMutation)
        }
        let actualSnip = try XCTUnwrap(initialAccepted.readyEntities.first { $0.reference == snipReference })
        let acceptedSnip = try JSONDecoder().decode(CloudTypedSnipRecord.self, from: actualSnip.acceptedData)
        let acceptedSnipPresence = try JSONDecoder().decode(CloudTypedSnipRecord.self, from: actualSnip.presenceData)
        XCTAssertEqual(acceptedSnip, acceptedSnipPresence)
        XCTAssertEqual(acceptedSnip.storageVersion, 1)
        XCTAssertEqual(acceptedSnip.binding, .canonical)
        XCTAssertEqual(acceptedSnip.id, .snip(base.id, in: zone))
        XCTAssertEqual(acceptedSnip.domainID, base.id)
        XCTAssertEqual(acceptedSnip.schemaVersion, 3)
        XCTAssertEqual(acceptedSnip.requestID, .value(base.requestID))
        XCTAssertEqual(acceptedSnip.createdAt, .value(base.createdAt))
        XCTAssertEqual(acceptedSnip.updatedAt, .value(base.updatedAt))
        XCTAssertEqual(acceptedSnip.origin, .value(SnipOrigin.quickEntry.rawValue))
        XCTAssertEqual(acceptedSnip.text, .value("unchanged"))
        XCTAssertEqual(acceptedSnip.source, .value(nil))
        XCTAssertEqual(acceptedSnip.isDone, .value(false))
        XCTAssertNil(acceptedSnip.pinnedAt)
        XCTAssertEqual(acceptedSnip.placement, .value(CloudSnipPlacement(
            listID: inbox.id, orderKey: base.manualSortKey)))
        XCTAssertEqual(actualSnip.dependencyListID, inbox.id)
        XCTAssertEqual(acceptedSnip.shadow.data, actualSnip.shadowData)
        XCTAssertEqual(acceptedSnip.shadow.systemFields, actualSnip.systemFields)
        let actualList = try XCTUnwrap(initialAccepted.readyEntities.first { $0.reference == listReference })
        let acceptedList = try JSONDecoder().decode(CloudTypedListRecord.self, from: actualList.acceptedData)
        let acceptedListPresence = try JSONDecoder().decode(CloudTypedListRecord.self, from: actualList.presenceData)
        XCTAssertEqual(acceptedList, acceptedListPresence)
        XCTAssertEqual(acceptedList.storageVersion, 1)
        XCTAssertEqual(acceptedList.binding, .canonical)
        XCTAssertEqual(acceptedList.id, .list(inbox.id, in: zone))
        XCTAssertEqual(acceptedList.domainID, inbox.id)
        XCTAssertEqual(acceptedList.schemaVersion, 3)
        XCTAssertEqual(acceptedList.desiredName, .value(inbox.desiredName))
        XCTAssertEqual(acceptedList.systemImage, .value(inbox.systemImage))
        XCTAssertEqual(acceptedList.color, .value(inbox.color))
        XCTAssertEqual(acceptedList.orderKey, .value(inbox.sortKey))
        XCTAssertNil(actualList.dependencyListID)
        XCTAssertEqual(acceptedList.shadow.data, actualList.shadowData)
        XCTAssertEqual(acceptedList.shadow.systemFields, actualList.systemFields)
        guard case .value(let serverListDate) = acceptedList.updatedAt else {
            return XCTFail("Expected the committed server list date")
        }
        let offResult = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(offResult.state, .off)
        let offManifest = await persistence.manifest
        XCTAssertNil(offManifest.transition)
        let offStore = try XCTUnwrap(offManifest.stores.first { $0.id == offManifest.activeStoreID })
        XCTAssertEqual(offStore.kind, .localOnly)
        XCTAssertEqual(offStore.syncProtocol, .fullRecordV1)
        XCTAssertNil(offStore.namespace)
        let offRaw = try await persistence.libraryForTransition(storeID: offStore.id)
        let offStoreURL = await persistence.storeFileURL(offStore)
        let offSource = try await offRaw.transferSnapshot(revision: offStore.revision)
        let offArchive = try await offRaw.archive()
        let offDormant = try await offRaw.dormantCloudBases()
        XCTAssertEqual(offSource.snips, [base])
        XCTAssertEqual(offSource.lists, [inbox])
        XCTAssertTrue(offSource.attachmentData.isEmpty)
        XCTAssertEqual(offArchive.seenRequestIDs, Set([base.requestID]))
        XCTAssertEqual(Set(offDormant.map(\.reference)), Set([snipReference, listReference]))
        XCTAssertEqual(offDormant.count, 2)
        let dormantPayload = try CloudDormantAcceptedBaseBundle.decode(offSource.opaqueSyncStatePayload)
        XCTAssertEqual(dormantPayload.entries.count, 2)
        for entry in dormantPayload.entries {
            let actual = try XCTUnwrap(initialAccepted.readyEntities.first { $0.reference == entry.reference })
            let dormant = try XCTUnwrap(offDormant.first { $0.reference == entry.reference })
            let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: entry.payload)
            XCTAssertEqual(entry.namespaceKey, namespace.namespaceKey.rawValue)
            XCTAssertEqual(entry.identity, actual.identity)
            XCTAssertEqual(entry.payload, dormant.payload)
            XCTAssertEqual(dormant.namespaceKey, entry.namespaceKey)
            XCTAssertEqual(dormant.identity, entry.identity)
            XCTAssertEqual(envelope.reference, actual.reference)
            XCTAssertEqual(envelope.identity, actual.identity)
            XCTAssertEqual(envelope.schemaVersion, actual.schemaVersion)
            XCTAssertEqual(envelope.acceptedData, actual.acceptedData)
            XCTAssertEqual(envelope.presenceData, actual.presenceData)
            XCTAssertEqual(envelope.shadowData, actual.shadowData)
            XCTAssertEqual(envelope.systemFields, actual.systemFields)
            XCTAssertEqual(envelope.dependencyListID, actual.dependencyListID)
        }
        let offEvidence = try XCTUnwrap(try files.read(offStore.id))
        XCTAssertEqual(offEvidence.sourceStoreID, FailedEnableEncoding.uuid(offStore.id))
        XCTAssertEqual(offEvidence.continuity.state, .verified)
        XCTAssertNil(offEvidence.continuity.inFlight.value)
        XCTAssertEqual(offEvidence.continuity.sourceRevision, String(offStore.revision))
        XCTAssertTrue(offEvidence.namespaces.isEmpty)
        XCTAssertTrue(offEvidence.blobs.isEmpty)
        let turnOff = try XCTUnwrap(offEvidence.transfers.first { $0.kind == .turnOff })
        XCTAssertEqual(offEvidence.transfers.count, 1)
        XCTAssertEqual(turnOff.state, .checked)
        XCTAssertTrue(turnOff.sourceCaptureIDs.isEmpty)
        XCTAssertEqual(turnOff.sourceStoreID, FailedEnableEncoding.uuid(cloudStore.id))
        XCTAssertEqual(turnOff.destinationStoreID, FailedEnableEncoding.uuid(offStore.id))
        XCTAssertEqual(turnOff.namespace, FailedEnableBinding(namespace.binding))
        XCTAssertEqual(turnOff.outputs, expectedImages.values.sorted { $0.reference.sortKey < $1.reference.sortKey })
        XCTAssertEqual(turnOff.dormantDigest, FailedEnableEncoding.digest(offSource.opaqueSyncStatePayload))
        XCTAssertTrue(turnOff.conflicts.isEmpty)
        XCTAssertTrue(turnOff.recoveryDescriptors.isEmpty)
        let recordID = CloudRecordID.snip(base.id, in: zone)
        let storedValue = await server.fullSnapshot(for: recordID)
        let stored = try XCTUnwrap(storedValue)
        let serverBeforeDelete = try CloudFullRecordCodec.snip(from: stored)
        XCTAssertEqual(serverBeforeDelete, acceptedSnip)
        let listBeforeDeleteValue = await server.fullSnapshot(for: .list(inbox.id, in: zone))
        let listBeforeDelete = try XCTUnwrap(listBeforeDeleteValue)
        XCTAssertEqual(listBeforeDelete.shadow.data, actualList.shadowData)
        XCTAssertEqual(listBeforeDelete.shadow.systemFields, actualList.systemFields)
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        let deletion = try await writer.send(CloudOutboundBatch(operations: [
            .delete(recordID, base: stored.shadow)
        ]))
        XCTAssertEqual(deletion.items.count, 1)
        guard case .deleted(let deletedID) = try XCTUnwrap(deletion.items.first) else {
            return XCTFail("Expected the real original-record deletion")
        }
        XCTAssertEqual(deletedID, recordID)
        let deletedOriginal = await server.fullSnapshot(for: recordID)
        XCTAssertNil(deletedOriginal)
        let acceptedOperationsAfterDelete = await server.acceptedOperationCount(for: recordID)
        let acceptedDeletesAfterDelete = await server.acceptedDeletionCount()
        XCTAssertEqual(acceptedOperationsAfterDelete, 2)
        XCTAssertEqual(acceptedDeletesAfterDelete, 1)
        let sourceBeforeRetry = try await offRaw.transferSnapshot(revision: offStore.revision)
        XCTAssertEqual(sourceBeforeRetry, offSource)
        let evidenceBeforeRetry = try XCTUnwrap(try files.read(offStore.id))
        XCTAssertEqual(evidenceBeforeRetry, offEvidence)

        let result = try await coordinator.enableOrRetry()
        let afterAttemptManifest = await persistence.manifest
        let afterAttemptEvidence = try files.read(offStore.id)
        XCTAssertEqual(result.state, .on)
        let active = try await persistence.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        XCTAssertTrue(final.snips.isEmpty)
        let storage = try await persistence.snapshot()
        let raw = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
        let recovery = try await raw.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(recovery.isEmpty)
        XCTAssertNil(storage.transition)
        XCTAssertEqual(final.lists, [inbox])
        let retained = try XCTUnwrap(afterAttemptEvidence)
        XCTAssertEqual(retained.continuity.state, .verified)
        XCTAssertNil(retained.continuity.inFlight.value)
        XCTAssertEqual(retained.continuity.sourceRevision, offEvidence.continuity.sourceRevision)
        XCTAssertEqual(retained.continuity.sourceDigest, offEvidence.continuity.sourceDigest)
        XCTAssertEqual(retained.blobs, offEvidence.blobs)
        XCTAssertTrue(retained.transfers.contains(turnOff))
        let group = try XCTUnwrap(retained.namespaces.first { $0.binding == turnOff.namespace })
        XCTAssertTrue(group.reviews.isEmpty)
        XCTAssertTrue(group.alternatives.isEmpty)
        let capture = try XCTUnwrap(group.captures.last)
        XCTAssertEqual(capture.syncProtocol, .fullRecordV1)
        XCTAssertEqual(capture.normalizer, 1)
        XCTAssertEqual(capture.freeze.sourceRevision, String(offStore.revision))
        XCTAssertNotNil(UUID(uuidString: capture.freeze.id))
        XCTAssertNotNil(UUID(uuidString: capture.transitionID))
        XCTAssertEqual(capture.sourceDigest, offEvidence.continuity.sourceDigest)
        XCTAssertEqual(capture.seenRequestIDs, [FailedEnableEncoding.uuid(base.requestID)])
        XCTAssertTrue(capture.candidateDeletes.isEmpty)
        XCTAssertEqual(Set(capture.records.map(\.reference)), Set(expectedImages.keys))
        XCTAssertEqual(capture.records.count, 2)
        let transfer = try XCTUnwrap(retained.transfers.last { $0.sourceCaptureIDs == [capture.id] })
        XCTAssertEqual(transfer.kind, .candidate)
        XCTAssertEqual(transfer.state, .checked)
        XCTAssertEqual(transfer.sourceStoreID, retained.sourceStoreID)
        XCTAssertEqual(transfer.destinationStoreID, capture.candidateStoreID)
        XCTAssertEqual(transfer.namespace, group.binding)
        XCTAssertEqual(transfer.outputs, [.list(FailedEnableListImage(inbox))])
        XCTAssertTrue(transfer.conflicts.isEmpty)
        XCTAssertTrue(transfer.recoveryDescriptors.isEmpty)
        let deletedRecord = try XCTUnwrap(capture.records.first { $0.reference == capturedSnipReference })
        XCTAssertEqual(deletedRecord.sourceMembership, .present)
        XCTAssertEqual(deletedRecord.source.value, expectedImages[capturedSnipReference])
        XCTAssertEqual(deletedRecord.identity.domain, actualSnip.identity)
        XCTAssertTrue(deletedRecord.originalAcceptedExists)
        XCTAssertTrue(deletedRecord.offlineChanged.isEmpty)
        XCTAssertEqual(deletedRecord.preparation.classification, .deleteRecovery)
        XCTAssertEqual(deletedRecord.preparation.normalizer, 1)
        XCTAssertEqual(deletedRecord.preparation.baseKind, .checkedTurnOff)
        XCTAssertEqual(deletedRecord.preparation.knownFields, snipPresence.keys.sorted())
        XCTAssertEqual(deletedRecord.preparation.value.value,
            FailedEnablePreparedValue(fields: .absent, presence: [:]))
        let dormantSnip = try XCTUnwrap(offDormant.first { $0.reference == snipReference })
        XCTAssertEqual(deletedRecord.preparation.baseDigest.value, FailedEnableEncoding.digest(dormantSnip.payload))
        XCTAssertNil(deletedRecord.preparation.fetchedDigest.value)
        XCTAssertEqual(deletedRecord.preparation.normalizedLocal.acceptedPresence, snipPresence)
        XCTAssertTrue(deletedRecord.preparation.normalizedLocal.defaults.isEmpty)
        XCTAssertEqual(deletedRecord.preparation.normalizedLocal.immutableOverrides.value,
            FailedEnableImmutableOverrides(requestID: FailedEnableEncoding.uuid(base.requestID),
                createdAt: try FailedEnableEncoding.date(base.createdAt), originRaw: SnipOrigin.quickEntry.rawValue))
        XCTAssertTrue(deletedRecord.preparation.conflictFields.isEmpty)
        XCTAssertTrue(deletedRecord.preparation.recoveryIdentities.isEmpty)
        XCTAssertNil(deletedRecord.observedAccepted.value)
        XCTAssertNil(deletedRecord.unqualifiedObservation.value)
        let inboxRecord = try XCTUnwrap(capture.records.first { $0.reference == capturedListReference })
        XCTAssertEqual(inboxRecord.sourceMembership, .present)
        XCTAssertEqual(inboxRecord.source.value, expectedImages[capturedListReference])
        XCTAssertEqual(inboxRecord.preparation.value.value, FailedEnablePreparedValue(
            fields: .list(FailedEnableListValue(id: FailedEnableEncoding.uuid(inbox.id),
                desiredName: inbox.desiredName, systemImage: inbox.systemImage,
                colorPreset: .init(inbox.color?.rawValue), orderKey: inbox.sortKey.data,
                updatedAt: try FailedEnableEncoding.date(serverListDate))), presence: listPresence))
        let candidateID = try FailedEnableEncoding.uuid(capture.candidateStoreID)
        XCTAssertEqual(storage.activeStore.id, candidateID)
        XCTAssertEqual(storage.activeStore.kind, .iCloudSync)
        XCTAssertEqual(storage.activeStore.namespace, namespace.binding)
        XCTAssertNil(storage.attentionReason)
        let candidate = try await persistence.libraryForTransition(storeID: candidateID)
        let committed = try await candidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        let candidateContents = try await candidate.transferSnapshot(revision:
            try XCTUnwrap(afterAttemptManifest.stores.first { $0.id == candidateID }).revision)
        XCTAssertTrue(candidateContents.snips.isEmpty)
        XCTAssertEqual(candidateContents.lists, [inbox])
        XCTAssertTrue(candidateContents.attachmentData.isEmpty)
        XCTAssertEqual(Set(committed.readyEntities.map(\.reference)), Set([listReference]))
        XCTAssertTrue(committed.deferredEntities.isEmpty)
        XCTAssertTrue(committed.pendingDeletes.isEmpty)
        XCTAssertTrue(committed.conflicts.isEmpty)
        XCTAssertTrue(committed.quarantines.isEmpty)
        let observedInbox = try XCTUnwrap(inboxRecord.observedAccepted.value)
        let committedInbox = try XCTUnwrap(committed.readyEntities.first { $0.reference == listReference })
        let observedEnvelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: observedInbox.entityBase64)
        XCTAssertEqual(observedInbox.kind, .fullRecord)
        XCTAssertEqual(observedInbox.candidateStoreID, capture.candidateStoreID)
        let inboxObservationRevision = try FailedEnableEncoding.revision(observedInbox.namespaceRevision)
        XCTAssertLessThanOrEqual(inboxObservationRevision, committed.namespaceState.revision)
        XCTAssertEqual(observedInbox.isDeferred, committedInbox.isDeferred)
        XCTAssertEqual(observedInbox.hasUnresolvedLegacyAbsence, committedInbox.hasUnresolvedLegacyAbsence)
        XCTAssertEqual(observedInbox.dependencyListID.value, committedInbox.dependencyListID.map(FailedEnableEncoding.uuid))
        XCTAssertEqual(observedInbox.localRevision, String(committedInbox.localRevision))
        XCTAssertEqual(observedEnvelope.reference, listReference)
        XCTAssertEqual(observedEnvelope.identity, committedInbox.identity)
        XCTAssertEqual(observedEnvelope.schemaVersion, committedInbox.schemaVersion)
        XCTAssertEqual(observedEnvelope.acceptedData, committedInbox.acceptedData)
        XCTAssertEqual(observedEnvelope.presenceData, committedInbox.presenceData)
        XCTAssertEqual(observedEnvelope.shadowData, committedInbox.shadowData)
        XCTAssertEqual(observedEnvelope.systemFields, committedInbox.systemFields)
        XCTAssertEqual(observedEnvelope.dependencyListID, committedInbox.dependencyListID)
        let retainedSourceStore = try XCTUnwrap(afterAttemptManifest.stores.first { $0.id == offStore.id })
        XCTAssertEqual(retainedSourceStore.revision, offStore.revision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: offStoreURL.path))
        let sourceAfterAttempt = try await offRaw.transferSnapshot(revision: retainedSourceStore.revision)
        let dormantAfterAttempt = try await offRaw.dormantCloudBases()
        XCTAssertEqual(sourceAfterAttempt, offSource)
        XCTAssertEqual(sourceAfterAttempt.opaqueSyncStatePayload, offSource.opaqueSyncStatePayload)
        XCTAssertEqual(dormantAfterAttempt, offDormant)
        let firstRetained = try XCTUnwrap(try files.read(initialStore.id))
        let retainedFirstGroup = try XCTUnwrap(firstRetained.namespaces.first { $0.binding == firstGroup.binding })
        XCTAssertEqual(retainedFirstGroup.captures.first { $0.id == firstCapture.id }, firstCapture)
        XCTAssertTrue(firstRetained.transfers.contains(firstTransfer))
        XCTAssertEqual(firstRetained.blobs, initialEvidence.blobs)
        let finalArchive = try await raw.archive()
        XCTAssertTrue(finalArchive.seenRequestIDs.isSubset(of: Set([base.requestID])))
        let serverOriginalAfterAttempt = await server.fullSnapshot(for: recordID)
        let serverTextsAfterAttempt = await server.storedTextValues()
        let serverTypesAfterAttempt = await server.storedRecordTypes(in: zone)
        let operationCountAfterAttempt = await server.acceptedOperationCount(for: recordID)
        let deleteCountAfterAttempt = await server.acceptedDeletionCount()
        XCTAssertNil(serverOriginalAfterAttempt)
        XCTAssertEqual(serverTextsAfterAttempt, [])
        XCTAssertEqual(serverTypesAfterAttempt, ["List"])
        XCTAssertEqual(operationCountAfterAttempt, acceptedOperationsAfterDelete)
        XCTAssertEqual(deleteCountAfterAttempt, acceptedDeletesAfterDelete)
        let repeated = try await coordinator.enableOrRetry()
        XCTAssertEqual(repeated.state, .on)
        let repeatedManifest = await persistence.manifest
        XCTAssertNil(repeatedManifest.transition)
        XCTAssertEqual(repeatedManifest.activeStoreID, candidateID)
        let repeatedLibrary = try await persistence.activeLibrary()
        let repeatedContents = try await repeatedLibrary.checkedSnapshot(sortedBy: .manual)
        XCTAssertTrue(repeatedContents.snips.isEmpty)
        XCTAssertEqual(repeatedContents.lists, [inbox])
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let reopenedCoordinator = ICloudSyncModeCoordinator(
            persistence: reopened, namespace: namespace, textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) })
        let reopenedResult = try await reopenedCoordinator.enableOrRetry()
        XCTAssertEqual(reopenedResult.state, .on)
        let reopenedManifest = await reopened.manifest
        XCTAssertNil(reopenedManifest.transition)
        XCTAssertEqual(reopenedManifest.activeStoreID, candidateID)
        let reopenedLibrary = try await reopened.activeLibrary()
        let reopenedContents = try await reopenedLibrary.checkedSnapshot(sortedBy: .manual)
        XCTAssertTrue(reopenedContents.snips.isEmpty)
        XCTAssertEqual(reopenedContents.lists, [inbox])
        let reopenedRaw = try await reopened.libraryForTransition(storeID: reopenedManifest.activeStoreID)
        let reopenedArchive = try await reopenedRaw.archive()
        let reopenedRecovery = try await reopenedRaw.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(reopenedArchive.seenRequestIDs.isSubset(of: Set([base.requestID])))
        XCTAssertTrue(reopenedRecovery.isEmpty)
        let evidenceAfterReopen = try XCTUnwrap(try files.read(offStore.id))
        let groupAfterReopen = try XCTUnwrap(evidenceAfterReopen.namespaces.first { $0.binding == group.binding })
        XCTAssertTrue(groupAfterReopen.reviews.isEmpty)
        XCTAssertTrue(groupAfterReopen.alternatives.isEmpty)
        XCTAssertEqual(groupAfterReopen.captures.first { $0.id == capture.id }, capture)
        XCTAssertTrue(evidenceAfterReopen.transfers.contains(turnOff))
        XCTAssertTrue(evidenceAfterReopen.transfers.contains(transfer))
        XCTAssertEqual(evidenceAfterReopen.blobs, retained.blobs)
        let firstAfterReopen = try XCTUnwrap(try files.read(initialStore.id))
        let firstGroupAfterReopen = try XCTUnwrap(firstAfterReopen.namespaces.first { $0.binding == firstGroup.binding })
        XCTAssertEqual(firstGroupAfterReopen.captures.first { $0.id == firstCapture.id }, firstCapture)
        XCTAssertTrue(firstAfterReopen.transfers.contains(firstTransfer))
        XCTAssertEqual(firstAfterReopen.blobs, initialEvidence.blobs)
        let reopenedSourceStore = try XCTUnwrap(reopenedManifest.stores.first { $0.id == offStore.id })
        XCTAssertEqual(reopenedSourceStore.revision, offStore.revision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: offStoreURL.path))
        let sourceAfterReopen = try await offRaw.transferSnapshot(revision: reopenedSourceStore.revision)
        let dormantAfterReopen = try await offRaw.dormantCloudBases()
        XCTAssertEqual(sourceAfterReopen, offSource)
        XCTAssertEqual(dormantAfterReopen, offDormant)
        let finalServerOriginal = await server.fullSnapshot(for: recordID)
        let finalServerTexts = await server.storedTextValues()
        let finalServerTypes = await server.storedRecordTypes(in: zone)
        let finalOperationCount = await server.acceptedOperationCount(for: recordID)
        let finalDeleteCount = await server.acceptedDeletionCount()
        XCTAssertNil(finalServerOriginal)
        XCTAssertEqual(finalServerTexts, [])
        XCTAssertEqual(finalServerTypes, ["List"])
        XCTAssertEqual(finalOperationCount, acceptedOperationsAfterDelete)
        XCTAssertEqual(finalDeleteCount, acceptedDeletesAfterDelete)
    }

    func testFullReenableDeletedListMovesOfflinePlacementToInboxWithEvidence() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        let list = try await createList("Later deleted", systemImage: "folder", in: source)
        try await add("move me", to: source)
        let sourceSnapshot = await source.snapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(sourceSnapshot.snips.first)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        _ = try await coordinator.enableOrRetry()
        _ = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        let local = try await persistence.activeLibrary()
        _ = try await local.perform(
            .moveChronologically(ids: [snip.id], to: list.id),
            sortedBy: .manual
        )
        _ = try await local.perform(
            .updateList(id: list.id, name: "Offline rename", systemImage: "star"),
            sortedBy: .manual
        )
        let recordID = CloudRecordID.list(list.id, in: zone)
        let storedValue = await server.fullSnapshot(for: recordID)
        let stored = try XCTUnwrap(storedValue)
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        _ = try await writer.send(CloudOutboundBatch(operations: [
            .delete(recordID, base: stored.shadow)
        ]))

        let result = try await coordinator.enableOrRetry()
        XCTAssertEqual(result.state, .needsAttention)
        let active = try await persistence.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        XCTAssertFalse(final.lists.contains(where: { $0.id == list.id }))
        XCTAssertEqual(final.snips.first(where: { $0.id == snip.id })?.listID, SnipList.inbox.id)
        let storage = try await persistence.snapshot()
        let raw = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
        let recovery = try await raw.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(recovery.filter { $0.kind == .modeDeletedListPlacement }.count, 1)
        let recoveredList = try XCTUnwrap(recovery.first { $0.kind == .modeRecoveredList })
        let recoveredText = String(decoding: recoveredList.resultData, as: UTF8.self)
        XCTAssertTrue(recoveredText.contains("Offline rename"))
        XCTAssertTrue(recoveredText.contains(list.id.uuidString))
    }

    func testFullPartialFirstSendHardReopenUsesTypedSettlementOnRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        try await add("edit after partial full send", to: source)
        try await add("retry full item", to: source)
        let before = await source.snapshot(sortedBy: .chronological)
        let edited = try XCTUnwrap(
            before.snips.first(where: { $0.content == "edit after partial full send" })
        )
        let failed = try XCTUnwrap(
            before.snips.first(where: { $0.content == "retry full item" })
        )
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.pauseNextSend()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport }
        )
        let enabling = Task { try await coordinator.enableOrRetry() }
        await transport.waitUntilSendPauses()
        await transport.failNextSentItem(
            .snip(failed.id, in: textZone(namespace)),
            failure: .retryable
        )
        await transport.resumeSend()
        let partial = try await enabling.value
        XCTAssertEqual(partial.state, .settingUp)
        let partialStorage = try await persistence.snapshot()
        let partialTransition = try XCTUnwrap(partialStorage.transition)
        let editedProvenance = try XCTUnwrap(
            partialTransition.seedProvenance.first(where: { $0.candidateSnipID == edited.id })
        )
        let failedProvenance = try XCTUnwrap(
            partialTransition.seedProvenance.first(where: { $0.candidateSnipID == failed.id })
        )
        XCTAssertNotNil(editedProvenance.acceptedRecordIdentity)
        XCTAssertNil(failedProvenance.acceptedRecordIdentity)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let reopenedSource = try await reopened.activeLibrary()
        let reopenedSnapshot = await reopenedSource.snapshot(sortedBy: .chronological)
        let reopenedEdited = try XCTUnwrap(
            reopenedSnapshot.snips.first(where: { $0.id == edited.id })
        )
        _ = try await reopenedSource.perform(
            .update(
                id: edited.id,
                content: "edited after hard reopen",
                attachmentURLs: nil,
                expectedUpdatedAt: reopenedEdited.updatedAt,
                now: Date(timeIntervalSince1970: 20)
            ),
            sortedBy: .chronological
        )
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            }
        )
        let reviewStatus = try await retry.enableOrRetry()
        XCTAssertEqual(reviewStatus.state, .needsAttention)
        let facade = SnipSyncModeStore(reopened).failedEnableReview
        let review = try await facade.snapshot()
        XCTAssertEqual(review.issues.map(\.entityID), [.snip(failed.id)])
        let issue = try XCTUnwrap(review.issues.first)
        let chosen = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        let output = try XCTUnwrap(chosen.outputs.first)
        guard case .snip(let recoveredID) = output.output else { return XCTFail("Expected the failed member mapping") }
        XCTAssertEqual(output.original, .snip(failed.id))
        XCTAssertNotEqual(recoveredID, failed.id)
        XCTAssertNotEqual(recoveredID, edited.id)
        let recoveredRequestID = try XCTUnwrap(output.requestID)
        XCTAssertEqual(chosen.outputs.count, 1)
        XCTAssertTrue(output.attachments.isEmpty)
        XCTAssertEqual(Set([recoveredID, recoveredRequestID]).count, 2)
        XCTAssertTrue(Set([recoveredID, recoveredRequestID]).isDisjoint(with:
            Set([edited.id, edited.requestID, failed.id, failed.requestID])))
        let result = try await retry.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let active = try await reopened.activeLibrary()
        let final = await active.snapshot(sortedBy: .chronological)
        XCTAssertEqual(Set(final.snips.map(\.id)), Set([edited.id, recoveredID]))
        XCTAssertEqual(
            final.snips.map(\.content).sorted(),
            ["edited after hard reopen", "retry full item"]
        )
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(remoteTexts, ["edited after hard reopen", "retry full item"])
        XCTAssertEqual(final.snips.first(where: { $0.id == edited.id })?.content, "edited after hard reopen")
        XCTAssertEqual(final.snips.first(where: { $0.id == recoveredID })?.requestID, recoveredRequestID)
        XCTAssertEqual(final.snips.first(where: { $0.id == recoveredID })?.isDone, false)
        XCTAssertEqual(final.snips.first(where: { $0.id == edited.id })?.isDone, false)
        let remoteEditedValue = await server.fullSnapshot(for: .snip(edited.id, in: textZone(namespace)))
        let remoteEditedSnapshot = try XCTUnwrap(remoteEditedValue)
        let remoteEdited = try CloudFullRecordCodec.snip(from: remoteEditedSnapshot)
        XCTAssertEqual(remoteEdited.text, .value("edited after hard reopen"))
        XCTAssertEqual(remoteEdited.isDone, .value(false))
        let remoteRecoveredValue = await server.fullSnapshot(for: .snip(recoveredID, in: textZone(namespace)))
        let remoteRecoveredSnapshot = try XCTUnwrap(remoteRecoveredValue)
        let remoteRecovered = try CloudFullRecordCodec.snip(from: remoteRecoveredSnapshot)
        XCTAssertEqual(remoteRecovered.text, .value("retry full item"))
        XCTAssertEqual(remoteRecovered.requestID, .value(recoveredRequestID))
        XCTAssertEqual(remoteRecovered.isDone, .value(false))
        let oldOriginal = await server.fullSnapshot(for: .snip(failed.id, in: textZone(namespace)))
        XCTAssertNil(oldOriginal)
        let hardReopened = try SwiftDataSyncModePersistence(rootURL: root)
        let repeated = ICloudSyncModeCoordinator(persistence: hardReopened, namespace: namespace,
            textZone: textZone(namespace), makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) })
        let repeatedStatus = try await repeated.enableOrRetry()
        XCTAssertEqual(repeatedStatus.state, .on)
        let repeatedSnapshot = try await hardReopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(repeatedSnapshot.snips.map(\.id)), Set([edited.id, recoveredID]))
    }

    func testFullPartialFirstSendRetryThreeWayMergesListAndSnipFields() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        let list = try await createList("Partial", systemImage: "folder", in: source)
        for text in ["accepted first", "retry later"] {
            _ = try await source.perform(
                .add(
                    content: text,
                    origin: .quickEntry,
                    source: nil,
                    listID: list.id,
                    attachmentURLs: [],
                    requestID: UUID(),
                    now: Date(timeIntervalSince1970: 10)
                ),
                sortedBy: .manual
            )
        }
        let before = await source.snapshot(sortedBy: .manual)
        let acceptedSnip = try XCTUnwrap(
            before.snips.first(where: { $0.content == "accepted first" })
        )
        let failedSnip = try XCTUnwrap(
            before.snips.first(where: { $0.content == "retry later" })
        )
        let server = FakeCloudServer()
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.pauseNextSend()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { transport }
        )
        let enabling = Task { try await coordinator.enableOrRetry() }
        await transport.waitUntilSendPauses()
        await transport.failNextSentItem(.snip(failedSnip.id, in: zone), failure: .retryable)
        await transport.resumeSend()
        let partial = try await enabling.value
        XCTAssertEqual(partial.state, .settingUp)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let reopenedSource = try await reopened.activeLibrary()
        _ = try await reopenedSource.perform(
            .updateList(id: list.id, name: "Local rename", systemImage: list.systemImage),
            sortedBy: .manual
        )
        _ = try await reopenedSource.perform(
            .setDone(ids: [acceptedSnip.id], done: true),
            sortedBy: .manual
        )

        let storedListValue = await server.fullSnapshot(for: .list(list.id, in: zone))
        let storedList = try XCTUnwrap(storedListValue)
        let acceptedList = try CloudFullRecordCodec.list(from: storedList)
        let remoteList = SnipList(
            id: list.id,
            name: list.desiredName,
            systemImage: "star",
            position: list.position,
            sortKey: list.sortKey
        )
        let storedSnipValue = await server.fullSnapshot(for: .snip(acceptedSnip.id, in: zone))
        let storedSnip = try XCTUnwrap(storedSnipValue)
        let acceptedRecord = try CloudFullRecordCodec.snip(from: storedSnip)
        let remoteSnip = Snip(
            id: acceptedSnip.id,
            requestID: acceptedSnip.requestID,
            createdAt: acceptedSnip.createdAt,
            updatedAt: Date(timeIntervalSince1970: 30),
            content: "remote text",
            origin: acceptedSnip.origin,
            source: acceptedSnip.source,
            listID: acceptedSnip.listID,
            isDone: false,
            manualSortKey: acceptedSnip.manualSortKey
        )
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        let remoteEdit = try await writer.send(CloudOutboundBatch(operations: [
            .save(try CloudFullRecordCodec.listDraft(
                remoteList,
                updatedAt: Date(timeIntervalSince1970: 30),
                accepted: acceptedList
            )),
            .save(try CloudFullRecordCodec.snipDraft(remoteSnip, accepted: acceptedRecord)),
        ]))
        XCTAssertEqual(remoteEdit.items.count, 2)

        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: zone,
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            }
        )
        let firstRetry = try await retry.enableOrRetry()
        let waiting = firstRetry.state == .settingUp
            ? try await retry.enableOrRetry()
            : firstRetry
        XCTAssertEqual(waiting.state, .needsAttention)
        let facade = SnipSyncModeStore(reopened).failedEnableReview
        let reviews = try await facade.snapshot()
        XCTAssertEqual(reviews.issues.map(\.entityID), [.snip(failedSnip.id)])
        let issue = try XCTUnwrap(reviews.issues.first { $0.entityID == .snip(failedSnip.id) })
        XCTAssertEqual(issue.reason, .unknownOutcome)
        XCTAssertEqual(issue.serverState, .absent)
        XCTAssertNil(issue.serverFieldsAtReview)
        XCTAssertEqual(issue.allowedChoices, [.recoverAsNew])
        XCTAssertTrue(issue.earlierLocalVersions.isEmpty)
        guard case .snip(let localVersion)? = issue.localVersionAtReview else {
            return XCTFail("Expected the retained local snip")
        }
        XCTAssertEqual(localVersion.id, failedSnip.id)
        XCTAssertEqual(localVersion.requestID, failedSnip.requestID)
        XCTAssertEqual(localVersion.content, "retry later")
        XCTAssertFalse(localVersion.isDone)
        XCTAssertEqual(localVersion.listID, list.id)
        XCTAssertTrue(localVersion.attachments.isEmpty)
        let sourceBeforeChoice = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        let storageBeforeChoice = try await reopened.snapshot()
        let chosen = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        XCTAssertEqual(chosen.issueID, issue.id)
        XCTAssertEqual(chosen.selection, .recoverAsNew)
        XCTAssertEqual(chosen.outputs.count, 1)
        let mapping = try XCTUnwrap(chosen.outputs.first)
        XCTAssertEqual(mapping.original, .snip(failedSnip.id))
        guard case .snip(let outputID) = mapping.output else { return XCTFail("Expected a snip output") }
        let outputRequestID = try XCTUnwrap(mapping.requestID)
        XCTAssertEqual(Set([outputID, outputRequestID]).count, 2)
        let originalIDs = Set(before.snips.flatMap { [$0.id, $0.requestID] } + before.lists.map(\.id))
        XCTAssertTrue(Set([outputID, outputRequestID]).isDisjoint(with: originalIDs))
        XCTAssertTrue(mapping.attachments.isEmpty)
        let repeated = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        XCTAssertEqual(repeated, chosen)
        let storageAfterChoice = try await reopened.snapshot()
        let sourceAfterChoice = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(storageAfterChoice, storageBeforeChoice)
        XCTAssertEqual(sourceAfterChoice.snips, sourceBeforeChoice.snips)
        XCTAssertEqual(sourceAfterChoice.lists, sourceBeforeChoice.lists)

        let result = try await retry.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let active = try await reopened.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        XCTAssertEqual(final.lists.count, 2)
        XCTAssertEqual(Set(final.lists.map(\.id)), Set([SnipList.inbox.id, list.id]))
        let finalList = try XCTUnwrap(final.lists.first(where: { $0.id == list.id }))
        XCTAssertEqual(finalList.desiredName, "Local rename")
        XCTAssertEqual(finalList.systemImage, "star")
        let finalSnip = try XCTUnwrap(final.snips.first(where: { $0.id == acceptedSnip.id }))
        XCTAssertEqual(finalSnip.requestID, acceptedSnip.requestID)
        XCTAssertEqual(finalSnip.content, "remote text")
        XCTAssertTrue(finalSnip.isDone)
        XCTAssertEqual(finalSnip.listID, list.id)
        XCTAssertTrue(final.snips.contains(where: { $0.id == outputID }))
        XCTAssertEqual(final.snips.count, 2)
        XCTAssertEqual(Set(final.snips.map(\.id)), Set([acceptedSnip.id, outputID]))
        XCTAssertFalse(final.snips.contains { $0.id == failedSnip.id })
        let recovered = try XCTUnwrap(final.snips.first { $0.id == outputID })
        XCTAssertEqual(recovered.requestID, outputRequestID)
        XCTAssertEqual(recovered.content, "retry later")
        XCTAssertFalse(recovered.isDone)
        XCTAssertEqual(recovered.listID, list.id)
        let completed = try await reopened.snapshot()
        XCTAssertNil(completed.transition)
        let oldRemote = await server.fullSnapshot(for: .snip(failedSnip.id, in: zone))
        XCTAssertNil(oldRemote)
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(remoteTexts, ["remote text", "retry later"])
        let remoteTypes = await server.storedRecordTypes(in: zone)
        XCTAssertEqual(remoteTypes.filter { $0 == "Snip" }.count, 2)
        XCTAssertEqual(remoteTypes.filter { $0 == "List" }.count, 2)
        let listSnapshot = await server.fullSnapshot(for: .list(list.id, in: zone))
        let listRecord = try CloudFullRecordCodec.list(from: try XCTUnwrap(listSnapshot))
        XCTAssertEqual(listRecord.id, .list(list.id, in: zone))
        XCTAssertEqual(listRecord.desiredName, .value("Local rename"))
        XCTAssertEqual(listRecord.systemImage, .value("star"))
        for (id, requestID, text, done) in [(acceptedSnip.id, acceptedSnip.requestID, "remote text", true),
            (outputID, outputRequestID, "retry later", false)] {
            let snapshot = await server.fullSnapshot(for: .snip(id, in: zone))
            let record = try CloudFullRecordCodec.snip(from: try XCTUnwrap(snapshot))
            XCTAssertEqual(record.id, .snip(id, in: zone))
            XCTAssertEqual(record.requestID, .value(requestID))
            XCTAssertEqual(record.text, .value(text))
            XCTAssertEqual(record.isDone, .value(done))
            guard case .value(let placement) = record.placement else { return XCTFail("Expected list placement") }
            XCTAssertEqual(placement.listID, list.id)
        }
        let repeatedContinue = try await retry.enableOrRetry()
        XCTAssertEqual(repeatedContinue.state, .on)
        let repeatedFinal = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(Set(repeatedFinal.snips.map(\.id)), Set([acceptedSnip.id, outputID]))
        XCTAssertEqual(repeatedFinal.snips.count, 2)
        XCTAssertEqual(repeatedFinal.lists, final.lists)
    }

    func testFullTerminalFirstSendSettlementCrashPreservesRecoveryAfterHardReopen() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: { point in
                if point == .afterRetryBasePromotion {
                    throw CloudTransportError.sendFailed
                }
            }
        )
        let source = try await persistence.activeLibrary()
        try await add("accepted before crash", to: source)
        try await add("retry after crash", to: source)
        let before = await source.snapshot(sortedBy: .manual)
        let accepted = try XCTUnwrap(
            before.snips.first(where: { $0.content == "accepted before crash" })
        )
        let failed = try XCTUnwrap(
            before.snips.first(where: { $0.content == "retry after crash" })
        )
        let initialStorage = try await persistence.snapshot()
        let initialRawSource = try await persistence.libraryForTransition(storeID: initialStorage.activeStore.id)
        let sourceBefore = try await initialRawSource.transferSnapshot(revision: initialStorage.activeStore.revision)
        let dormantBefore = try await initialRawSource.dormantCloudBases()
        XCTAssertEqual(sourceBefore.snips, before.snips)
        XCTAssertEqual(sourceBefore.lists, before.lists)
        XCTAssertEqual(before.snips.count, 2)
        XCTAssertEqual(before.lists.count, 1)
        XCTAssertTrue(dormantBefore.isEmpty)
        let initialInbox = try XCTUnwrap(before.lists.first { $0.id == SnipList.inbox.id })
        let snipPresence: [String: FailedEnablePresence] = [
            "createdAt": .value, "id": .value, "isDone": .value, "originRaw": .value,
            "pinnedAt": .value, "placement": .value, "requestID": .value,
            "source": .value, "text": .value, "updatedAt": .value,
        ]
        let listPresence: [String: FailedEnablePresence] = [
            "colorPreset": .value, "desiredName": .value, "id": .value,
            "orderKey": .value, "systemImage": .value, "updatedAt": .value,
        ]
        var expectedImages: [FailedEnableReference: FailedEnableImage] = [:]
        var expectedQ: [FailedEnableReference: FailedEnablePreparedValue] = [:]
        var expectedOverrides: [FailedEnableReference: FailedEnableImmutableOverrides] = [:]
        for (snip, text) in [(accepted, "accepted before crash"), (failed, "retry after crash")] {
            XCTAssertEqual(snip.content, text)
            XCTAssertEqual(snip.origin, .quickEntry)
            XCTAssertNil(snip.source)
            XCTAssertFalse(snip.isDone)
            XCTAssertNil(snip.pinnedAt)
            XCTAssertEqual(snip.listID, SnipList.inbox.id)
            XCTAssertTrue(snip.attachments.isEmpty)
            let reference = FailedEnableReference(CloudEntityReference(kind: .snip, domainID: snip.id))
            let createdAt = try FailedEnableEncoding.date(snip.createdAt)
            let updatedAt = try FailedEnableEncoding.date(snip.updatedAt)
            expectedImages[reference] = .snip(try FailedEnableSnipImage(snip, attachmentData: [:]))
            expectedQ[reference] = FailedEnablePreparedValue(fields: .snip(FailedEnableSnipValue(
                id: FailedEnableEncoding.uuid(snip.id), requestID: FailedEnableEncoding.uuid(snip.requestID),
                createdAt: createdAt, originRaw: SnipOrigin.quickEntry.rawValue, text: text,
                source: .init(nil), isDone: false, pinnedAt: .init(nil),
                placement: FailedEnablePlacement(listID: FailedEnableEncoding.uuid(SnipList.inbox.id),
                    orderKey: snip.manualSortKey.data), updatedAt: updatedAt)), presence: snipPresence)
            expectedOverrides[reference] = FailedEnableImmutableOverrides(
                requestID: FailedEnableEncoding.uuid(snip.requestID), createdAt: createdAt,
                originRaw: SnipOrigin.quickEntry.rawValue)
        }
        let inboxReference = FailedEnableReference(CloudEntityReference(kind: .list, domainID: initialInbox.id))
        expectedImages[inboxReference] = .list(FailedEnableListImage(initialInbox))
        expectedQ[inboxReference] = FailedEnablePreparedValue(fields: .list(FailedEnableListValue(
            id: FailedEnableEncoding.uuid(initialInbox.id), desiredName: initialInbox.desiredName,
            systemImage: initialInbox.systemImage, colorPreset: .init(initialInbox.color?.rawValue),
            orderKey: initialInbox.sortKey.data, updatedAt: "0000000000000000")), presence: listPresence)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.pauseNextSend()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { transport }
        )
        let enabling = Task { try await coordinator.enableOrRetry() }
        await transport.waitUntilSendPauses()
        await transport.failNextSentItem(.snip(failed.id, in: zone), failure: .rejected)
        await transport.resumeSend()
        do {
            _ = try await enabling.value
            XCTFail("The rejected first send must be reported")
        } catch let error as CloudSyncIssueError {
            XCTAssertEqual(error.issue, .appDataIssue)
        }

        let interrupted = try await persistence.snapshot()
        XCTAssertEqual(interrupted.transition?.phase, .firstSendStarted)
        XCTAssertNotNil(interrupted.transition?.sendAttempt)
        let transition = try XCTUnwrap(interrupted.transition)
        let token = try XCTUnwrap(transition.freezeToken)
        XCTAssertEqual(interrupted.activeStore.id, initialStorage.activeStore.id)
        XCTAssertEqual(interrupted.activeStore.revision, initialStorage.activeStore.revision)
        XCTAssertEqual(token.sourceStoreID, initialStorage.activeStore.id)
        XCTAssertEqual(token.revision, initialStorage.activeStore.revision)
        XCTAssertEqual(transition.pendingSettlementSnipIDs, Set([accepted.id, failed.id]))
        let rawSource = try await persistence.libraryForTransition(storeID: interrupted.activeStore.id)
        let sourceAfterFailure = try await rawSource.transferSnapshot(revision: interrupted.activeStore.revision)
        let dormantAfterFailure = try await rawSource.dormantCloudBases()
        XCTAssertEqual(sourceAfterFailure, sourceBefore)
        XCTAssertEqual(sourceAfterFailure.opaqueSyncStatePayload, sourceBefore.opaqueSyncStatePayload)
        XCTAssertEqual(dormantAfterFailure, dormantBefore)
        let files = FailedEnableEvidenceFile(root: root)
        let evidence = try XCTUnwrap(try files.read(initialStorage.activeStore.id))
        XCTAssertEqual(evidence.sourceStoreID, FailedEnableEncoding.uuid(initialStorage.activeStore.id))
        XCTAssertEqual(evidence.purpose, .installedEvidence)
        let group = try XCTUnwrap(evidence.namespaces.first { $0.binding == FailedEnableBinding(namespace.binding) })
        let capture = try XCTUnwrap(group.captures.first {
            $0.transitionID == FailedEnableEncoding.uuid(transition.id)
                && $0.candidateStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
        })
        XCTAssertEqual(capture.syncProtocol, .fullRecordV1)
        XCTAssertEqual(capture.freeze.id, FailedEnableEncoding.uuid(token.id))
        XCTAssertEqual(capture.freeze.sourceRevision, String(initialStorage.activeStore.revision))
        XCTAssertEqual(capture.sourceDigest, evidence.continuity.sourceDigest)
        XCTAssertEqual(capture.seenRequestIDs, [accepted.requestID, failed.requestID].map(FailedEnableEncoding.uuid).sorted())
        XCTAssertEqual(capture.normalizer, 1)
        XCTAssertTrue(capture.armed)
        XCTAssertTrue(capture.predecessors.isEmpty)
        XCTAssertTrue(capture.candidateDeletes.isEmpty)
        XCTAssertEqual(Set(capture.records.map(\.reference)), Set(expectedImages.keys))
        XCTAssertEqual(capture.records.count, expectedImages.count)
        let transfer = try XCTUnwrap(evidence.transfers.first { $0.sourceCaptureIDs == [capture.id] })
        XCTAssertEqual(transfer.kind, .candidate)
        XCTAssertEqual(transfer.state, .checked)
        XCTAssertEqual(transfer.sourceStoreID, evidence.sourceStoreID)
        XCTAssertEqual(transfer.destinationStoreID, capture.candidateStoreID)
        XCTAssertEqual(transfer.namespace, group.binding)
        XCTAssertEqual(transfer.outputs, expectedImages.values.sorted { $0.reference.sortKey < $1.reference.sortKey })
        XCTAssertTrue(transfer.conflicts.isEmpty)
        XCTAssertTrue(transfer.recoveryDescriptors.isEmpty)
        let candidate = try await persistence.libraryForTransition(storeID: transition.candidateStoreID)
        let committed = try await candidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        let failedReference = FailedEnableReference(CloudEntityReference(kind: .snip, domainID: failed.id))
        for record in capture.records {
            let reference = try record.reference.domain
            XCTAssertEqual(record.sourceMembership, .present)
            XCTAssertEqual(record.source.value, expectedImages[record.reference])
            switch record.source.value {
            case .snip(let image)?:
                let saved = try XCTUnwrap(before.snips.first { $0.id == reference.domainID })
                XCTAssertEqual(try image.domain, saved)
            case .list(let image)?:
                XCTAssertEqual(try image.domain, initialInbox)
            case nil:
                XCTFail("Expected the actual frozen source image")
            }
            XCTAssertFalse(record.originalAcceptedExists)
            XCTAssertEqual(record.identity.domain, CloudTextStorageIdentity(zoneName: zone.name, ownerName: zone.ownerName,
                recordName: "\(reference.kind == .snip ? "s" : "l")-\(reference.domainID.uuidString.lowercased())"))
            XCTAssertEqual(record.preparation.normalizer, 1)
            XCTAssertEqual(record.preparation.classification, .nonconflicting)
            XCTAssertEqual(record.preparation.baseKind, .noBaseEnrollment)
            XCTAssertNil(record.preparation.baseDigest.value)
            XCTAssertNil(record.preparation.fetchedDigest.value)
            XCTAssertNil(record.preparation.reason.value)
            XCTAssertTrue(record.preparation.conflictFields.isEmpty)
            XCTAssertTrue(record.preparation.recoveryIdentities.isEmpty)
            let prepared = try XCTUnwrap(record.preparation.value.value)
            let expected = try XCTUnwrap(expectedQ[record.reference])
            XCTAssertEqual(prepared, expected)
            XCTAssertEqual(record.preparation.knownFields, expected.presence.keys.sorted())
            XCTAssertEqual(record.preparation.normalizedLocal.acceptedPresence, expected.presence)
            XCTAssertTrue(record.preparation.normalizedLocal.defaults.isEmpty)
            XCTAssertEqual(record.preparation.normalizedLocal.immutableOverrides.value, expectedOverrides[record.reference])
            let observation: FailedEnableObservation?
            if record.reference == failedReference {
                XCTAssertNil(record.observedAccepted.value)
                observation = record.unqualifiedObservation.value
            } else {
                observation = try XCTUnwrap(record.observedAccepted.value)
            }
            if let observation {
                let actual = try XCTUnwrap((committed.readyEntities + committed.deferredEntities).first {
                    $0.reference == reference
                })
                let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: observation.entityBase64)
                XCTAssertEqual(observation.kind, .fullRecord)
                XCTAssertEqual(observation.candidateStoreID, capture.candidateStoreID)
                let observedRevision = try FailedEnableEncoding.revision(observation.namespaceRevision)
                XCTAssertLessThanOrEqual(observedRevision, committed.namespaceState.revision)
                XCTAssertEqual(observation.localRevision, String(actual.localRevision))
                XCTAssertEqual(observation.isDeferred, actual.isDeferred)
                XCTAssertEqual(observation.hasUnresolvedLegacyAbsence, actual.hasUnresolvedLegacyAbsence)
                XCTAssertEqual(observation.dependencyListID.value, actual.dependencyListID.map(FailedEnableEncoding.uuid))
                XCTAssertEqual(envelope.reference, actual.reference)
                XCTAssertEqual(envelope.identity, actual.identity)
                XCTAssertEqual(envelope.schemaVersion, actual.schemaVersion)
                XCTAssertEqual(envelope.acceptedData, actual.acceptedData)
                XCTAssertEqual(envelope.presenceData, actual.presenceData)
                XCTAssertEqual(envelope.shadowData, actual.shadowData)
                XCTAssertEqual(envelope.systemFields, actual.systemFields)
                XCTAssertEqual(envelope.dependencyListID, actual.dependencyListID)
                if record.reference != failedReference {
                    XCTAssertFalse(actual.isDeferred)
                    XCTAssertFalse(actual.wasMaterializedBeforeDeferral)
                    XCTAssertFalse(actual.hasUnresolvedLegacyAbsence)
                    XCTAssertNil(actual.graphRepair)
                    XCTAssertNil(actual.deferredLocalMutation)
                }
            }
        }
        let actualAccepted = try XCTUnwrap(committed.readyEntities.first {
            $0.reference == CloudEntityReference(kind: .snip, domainID: accepted.id)
        })
        XCTAssertEqual(actualAccepted.schemaVersion, 3)
        XCTAssertEqual(actualAccepted.dependencyListID, SnipList.inbox.id)
        let acceptedRecord = try CloudFullSyncPersistence.snipRecord(actualAccepted)
        XCTAssertEqual(acceptedRecord, try JSONDecoder().decode(CloudTypedSnipRecord.self, from: actualAccepted.acceptedData))
        XCTAssertEqual(acceptedRecord, try JSONDecoder().decode(CloudTypedSnipRecord.self, from: actualAccepted.presenceData))
        XCTAssertEqual(acceptedRecord.storageVersion, 1)
        XCTAssertEqual(acceptedRecord.binding, .canonical)
        XCTAssertEqual(acceptedRecord.id, .snip(accepted.id, in: zone))
        XCTAssertEqual(acceptedRecord.domainID, accepted.id)
        XCTAssertEqual(acceptedRecord.schemaVersion, 3)
        XCTAssertEqual(acceptedRecord.requestID, .value(accepted.requestID))
        XCTAssertEqual(acceptedRecord.createdAt, .value(accepted.createdAt))
        XCTAssertEqual(acceptedRecord.updatedAt, .value(accepted.updatedAt))
        XCTAssertEqual(acceptedRecord.origin, .value(SnipOrigin.quickEntry.rawValue))
        XCTAssertEqual(acceptedRecord.text, .value("accepted before crash"))
        XCTAssertEqual(acceptedRecord.source, .value(nil))
        XCTAssertEqual(acceptedRecord.isDone, .value(false))
        XCTAssertNil(acceptedRecord.pinnedAt)
        XCTAssertEqual(acceptedRecord.placement, .value(CloudSnipPlacement(
            listID: SnipList.inbox.id, orderKey: accepted.manualSortKey)))
        XCTAssertEqual(acceptedRecord.shadow.data, actualAccepted.shadowData)
        XCTAssertEqual(acceptedRecord.shadow.systemFields, actualAccepted.systemFields)
        let actualInbox = try XCTUnwrap(committed.readyEntities.first {
            $0.reference == CloudEntityReference(kind: .list, domainID: SnipList.inbox.id)
        })
        let inboxRecord = try CloudFullSyncPersistence.listRecord(actualInbox)
        XCTAssertEqual(inboxRecord.binding, .canonical)
        XCTAssertEqual(inboxRecord.id, .list(SnipList.inbox.id, in: zone))
        XCTAssertEqual(inboxRecord.desiredName, .value(initialInbox.desiredName))
        XCTAssertEqual(inboxRecord.systemImage, .value(initialInbox.systemImage))
        XCTAssertEqual(inboxRecord.color, .some(.value(initialInbox.color)))
        XCTAssertEqual(inboxRecord.orderKey, .value(initialInbox.sortKey))
        let failedRemoteBeforeChoice = await server.fullSnapshot(for: .snip(failed.id, in: zone))
        XCTAssertNil(failedRemoteBeforeChoice)

        let settlementCrash = CrashInjector(point: .beforeRetryFetchSettlementCommit)
        let settling = try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: settlementCrash.hit
        )
        let interruptedRetry = ICloudSyncModeCoordinator(
            persistence: settling,
            namespace: namespace,
            textZone: zone,
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            }
        )
        let interruptedResult = try await interruptedRetry.enableOrRetry()
        XCTAssertEqual(interruptedResult.state, .needsAttention)
        let unsettled = try await settling.snapshot()
        XCTAssertEqual(unsettled.transition?.phase, .candidateReady)
        let unsettledManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("activation.json"))
            ) as? [String: Any]
        )
        let unsettledTransition = try XCTUnwrap(unsettledManifest["transition"] as? [String: Any])
        XCTAssertEqual(unsettledTransition["captureAcceptedServerProvenance"] as? Bool, true)
        XCTAssertEqual(unsettled.attentionReason, .terminalFetchFailure)
        let unsettledCandidate = try await settling.libraryForTransition(
            storeID: try XCTUnwrap(unsettled.transition?.candidateStoreID)
        )
        let recovery = try await unsettledCandidate.cloudFullRecoveryEvents(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertEqual(recovery.map(\.kind), [.terminalSend])

        let retainedAfterSettlement = try XCTUnwrap(try files.read(initialStorage.activeStore.id))
        let settledSource = try await settling.libraryForTransition(storeID: unsettled.activeStore.id)
        let sourceAfterSettlement = try await settledSource.transferSnapshot(revision: unsettled.activeStore.revision)
        let dormantAfterSettlement = try await settledSource.dormantCloudBases()
        XCTAssertEqual(sourceAfterSettlement, sourceBefore)
        XCTAssertEqual(sourceAfterSettlement.opaqueSyncStatePayload, sourceBefore.opaqueSyncStatePayload)
        XCTAssertEqual(dormantAfterSettlement, dormantBefore)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let reopenedStorage = try await reopened.snapshot()
        let retainedAfterReopen = try XCTUnwrap(try files.read(initialStorage.activeStore.id))
        for retained in [retainedAfterSettlement, retainedAfterReopen] {
            let retainedGroup = try XCTUnwrap(retained.namespaces.first { $0.binding == group.binding })
            let retainedCapture = try XCTUnwrap(retainedGroup.captures.first { $0.id == capture.id })
            XCTAssertEqual(retained.sourceStoreID, evidence.sourceStoreID)
            XCTAssertEqual(retainedCapture.transitionID, capture.transitionID)
            XCTAssertEqual(retainedCapture.candidateStoreID, capture.candidateStoreID)
            XCTAssertEqual(retainedCapture.freeze, capture.freeze)
            XCTAssertEqual(retainedCapture.sourceDigest, capture.sourceDigest)
            XCTAssertEqual(retainedCapture.preparationDigest, capture.preparationDigest)
            XCTAssertEqual(retainedCapture.seenRequestIDs, capture.seenRequestIDs)
            XCTAssertEqual(retainedCapture.armed, capture.armed)
            XCTAssertEqual(retainedCapture.records.map(\.reference), capture.records.map(\.reference))
            XCTAssertEqual(retainedCapture.records.map(\.sourceMembership), capture.records.map(\.sourceMembership))
            XCTAssertEqual(retainedCapture.records.map(\.source), capture.records.map(\.source))
            XCTAssertEqual(retainedCapture.records.map(\.preparation), capture.records.map(\.preparation))
            XCTAssertEqual(retainedCapture.records.map(\.observedAccepted), capture.records.map(\.observedAccepted))
            XCTAssertTrue(retained.transfers.contains(transfer))
        }
        let reopenedSource = try await reopened.libraryForTransition(storeID: reopenedStorage.activeStore.id)
        let sourceAfterReopen = try await reopenedSource.transferSnapshot(revision: reopenedStorage.activeStore.revision)
        let dormantAfterReopen = try await reopenedSource.dormantCloudBases()
        XCTAssertEqual(sourceAfterReopen, sourceBefore)
        XCTAssertEqual(sourceAfterReopen.opaqueSyncStatePayload, sourceBefore.opaqueSyncStatePayload)
        XCTAssertEqual(dormantAfterReopen, dormantBefore)
        let reopenedCandidate = try await reopened.libraryForTransition(storeID: transition.candidateStoreID)
        let reopenedCommitted = try await reopenedCandidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(reopenedCommitted.readyEntities.first { $0.reference == actualAccepted.reference }, actualAccepted)
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: zone,
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            }
        )
        let waiting = try await retry.enableOrRetry()
        XCTAssertEqual(waiting.state, .needsAttention)
        let facade = SnipSyncModeStore(reopened).failedEnableReview
        let reviews = try await facade.snapshot()
        XCTAssertEqual(reviews.issues.map(\.entityID), [.snip(failed.id)])
        let issue = try XCTUnwrap(reviews.issues.first { $0.entityID == .snip(failed.id) })
        XCTAssertEqual(issue.reason, .unknownOutcome)
        XCTAssertEqual(issue.serverState, .absent)
        XCTAssertNil(issue.serverFieldsAtReview)
        XCTAssertEqual(issue.allowedChoices, [.recoverAsNew])
        XCTAssertTrue(issue.earlierLocalVersions.isEmpty)
        guard case .snip(let localVersion)? = issue.localVersionAtReview else {
            return XCTFail("Expected the retained failed snip")
        }
        XCTAssertEqual(localVersion, failed)
        let choiceSourceBefore = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        let choiceStorageBefore = try await reopened.snapshot()
        let chosen = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        XCTAssertEqual(chosen.issueID, issue.id)
        XCTAssertEqual(chosen.selection, .recoverAsNew)
        XCTAssertEqual(chosen.outputs.count, 1)
        let mapping = try XCTUnwrap(chosen.outputs.first)
        XCTAssertEqual(mapping.original, .snip(failed.id))
        guard case .snip(let outputID) = mapping.output else { return XCTFail("Expected a snip output") }
        let outputRequestID = try XCTUnwrap(mapping.requestID)
        XCTAssertEqual(Set([outputID, outputRequestID]).count, 2)
        let originalIDs = Set(before.snips.flatMap { [$0.id, $0.requestID] } + before.lists.map(\.id))
        XCTAssertTrue(Set([outputID, outputRequestID]).isDisjoint(with: originalIDs))
        XCTAssertTrue(mapping.attachments.isEmpty)
        let repeated = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        XCTAssertEqual(repeated, chosen)
        let choiceStorageAfter = try await reopened.snapshot()
        let choiceSourceAfter = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(choiceStorageAfter, choiceStorageBefore)
        XCTAssertEqual(choiceSourceAfter, choiceSourceBefore)

        let result = try await retry.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let completed = try await reopened.snapshot()
        XCTAssertNil(completed.transition)
        let active = try await reopened.libraryForTransition(storeID: completed.activeStore.id)
        let final = try await active.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.count, 2)
        XCTAssertEqual(Set(final.snips.map(\.id)), Set([accepted.id, outputID]))
        let acceptedFinal = try XCTUnwrap(final.snips.first { $0.id == accepted.id })
        XCTAssertEqual(acceptedFinal, accepted)
        let recovered = try XCTUnwrap(final.snips.first { $0.id == outputID })
        XCTAssertEqual(recovered.requestID, outputRequestID)
        XCTAssertEqual(recovered.content, "retry after crash")
        XCTAssertFalse(recovered.isDone)
        XCTAssertEqual(recovered.createdAt, failed.createdAt)
        XCTAssertEqual(recovered.updatedAt, failed.updatedAt)
        XCTAssertEqual(recovered.origin, .quickEntry)
        XCTAssertNil(recovered.source)
        XCTAssertNil(recovered.pinnedAt)
        XCTAssertEqual(recovered.listID, SnipList.inbox.id)
        XCTAssertEqual(recovered.manualSortKey, failed.manualSortKey)
        XCTAssertTrue(recovered.attachments.isEmpty)
        XCTAssertFalse(final.snips.contains { $0.id == failed.id })
        let activeRecovery = try await active.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(activeRecovery.isEmpty)
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(remoteTexts, ["accepted before crash", "retry after crash"])
        let oldRemote = await server.fullSnapshot(for: .snip(failed.id, in: zone))
        XCTAssertNil(oldRemote)
        let remoteTypes = await server.storedRecordTypes(in: zone)
        XCTAssertEqual(remoteTypes.filter { $0 == "Snip" }.count, 2)
        for (id, requestID, text) in [(accepted.id, accepted.requestID, "accepted before crash"),
            (outputID, outputRequestID, "retry after crash")] {
            let snapshot = await server.fullSnapshot(for: .snip(id, in: zone))
            let record = try CloudFullRecordCodec.snip(from: try XCTUnwrap(snapshot))
            XCTAssertEqual(record.id, .snip(id, in: zone))
            XCTAssertEqual(record.requestID, .value(requestID))
            XCTAssertEqual(record.text, .value(text))
            XCTAssertEqual(record.isDone, .value(false))
            guard case .value(let placement) = record.placement else { return XCTFail("Expected Inbox placement") }
            XCTAssertEqual(placement.listID, SnipList.inbox.id)
        }
        let retained = try XCTUnwrap(try files.read(initialStorage.activeStore.id))
        let retainedGroup = try XCTUnwrap(retained.namespaces.first { $0.binding == group.binding })
        let retainedCapture = try XCTUnwrap(retainedGroup.captures.first { $0.id == capture.id })
        XCTAssertEqual(retainedCapture.freeze, capture.freeze)
        XCTAssertEqual(retainedCapture.sourceDigest, capture.sourceDigest)
        XCTAssertEqual(retainedCapture.records.map(\.source), capture.records.map(\.source))
        XCTAssertEqual(retainedCapture.records.map(\.preparation), capture.records.map(\.preparation))
        XCTAssertEqual(retainedCapture.records.map(\.observedAccepted), capture.records.map(\.observedAccepted))
        XCTAssertTrue(retained.transfers.contains(transfer))
        let finalManifest = try JSONDecoder().decode(SwiftDataSyncModePersistence.Manifest.self,
            from: Data(contentsOf: root.appendingPathComponent("activation.json")))
        for id in [initialStorage.activeStore.id, transition.candidateStoreID] {
            let protected = try XCTUnwrap(finalManifest.stores.first { $0.id == id })
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(protected.relativeRoot).path))
        }
        let repeatedContinue = try await retry.enableOrRetry()
        XCTAssertEqual(repeatedContinue.state, .on)
        let repeatedFinal = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(repeatedFinal, final)
        let retainedReview = try await facade.snapshot()
        XCTAssertEqual(retainedReview.issues.first { $0.id == issue.id }?.selection, chosen)
    }

    func testFullRetryBasePromotionIsAtomicAndReplaysTheExactAcceptedSetAfterReopen() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let publicationReached = expectation(description: "The real partial-send evidence is published before restoration")
        let publicationArrival = CrashInjector(point: .afterRetryBasePromotion)
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: { point in
                if point == .afterRetryBasePromotion {
                    do {
                        try publicationArrival.hit(point)
                    } catch CrashInjector.Failure.injected {
                        publicationReached.fulfill()
                    }
                    throw CloudTransportError.sendFailed
                }
            }
        )
        let source = try await persistence.activeLibrary()
        try await add("accepted one", to: source)
        try await add("accepted two", to: source)
        try await add("failed", to: source)
        let before = await source.snapshot(sortedBy: .manual)
        let accepted = before.snips.filter { $0.content.hasPrefix("accepted") }
        let failed = try XCTUnwrap(before.snips.first { $0.content == "failed" })
        XCTAssertEqual(accepted.count, 2)
        XCTAssertEqual(accepted.map(\.content).sorted(), ["accepted one", "accepted two"])
        XCTAssertEqual(before.snips.count, 3)
        XCTAssertEqual(Set(before.snips.map(\.id)).count, 3)
        XCTAssertEqual(Set(before.snips.map(\.requestID)).count, 3)
        XCTAssertEqual(before.lists, [SnipList.inbox])
        let inbox = try XCTUnwrap(before.lists.first)
        let initial = try await persistence.snapshot()
        let sourceID = initial.activeStore.id
        let rawSource = try await persistence.libraryForTransition(storeID: sourceID)
        let sourceBefore = try await rawSource.transferSnapshot(revision: initial.activeStore.revision)
        let dormantBefore = try await rawSource.dormantCloudBases()
        let archiveBefore = try await rawSource.archive()
        XCTAssertEqual(sourceBefore.snips, before.snips)
        XCTAssertEqual(sourceBefore.lists, before.lists)
        XCTAssertTrue(sourceBefore.attachmentData.isEmpty)
        XCTAssertTrue(dormantBefore.isEmpty)
        XCTAssertEqual(archiveBefore.seenRequestIDs, Set(before.snips.map(\.requestID)))
        let snipPresence: [String: FailedEnablePresence] = [
            "createdAt": .value, "id": .value, "isDone": .value, "originRaw": .value,
            "pinnedAt": .value, "placement": .value, "requestID": .value,
            "source": .value, "text": .value, "updatedAt": .value,
        ]
        let listPresence: [String: FailedEnablePresence] = [
            "colorPreset": .value, "desiredName": .value, "id": .value,
            "orderKey": .value, "systemImage": .value, "updatedAt": .value,
        ]
        var expectedL: [FailedEnableReference: FailedEnableImage] = [:]
        var expectedQ: [FailedEnableReference: FailedEnablePreparedValue] = [:]
        var expectedOverrides: [FailedEnableReference: FailedEnableImmutableOverrides] = [:]
        for text in ["accepted one", "accepted two", "failed"] {
            let snip = try XCTUnwrap(before.snips.first { $0.content == text })
            XCTAssertEqual(snip.origin, .quickEntry)
            XCTAssertNil(snip.source)
            XCTAssertFalse(snip.isDone)
            XCTAssertNil(snip.pinnedAt)
            XCTAssertEqual(snip.listID, SnipList.inbox.id)
            XCTAssertTrue(snip.attachments.isEmpty)
            XCTAssertEqual(snip.updatedAt, snip.createdAt)
            let reference = FailedEnableReference(CloudEntityReference(kind: .snip, domainID: snip.id))
            let createdAt = try FailedEnableEncoding.date(snip.createdAt)
            expectedL[reference] = .snip(try FailedEnableSnipImage(snip, attachmentData: [:]))
            expectedQ[reference] = FailedEnablePreparedValue(fields: .snip(FailedEnableSnipValue(
                id: FailedEnableEncoding.uuid(snip.id), requestID: FailedEnableEncoding.uuid(snip.requestID),
                createdAt: createdAt, originRaw: SnipOrigin.quickEntry.rawValue, text: text,
                source: .init(nil), isDone: false, pinnedAt: .init(nil),
                placement: FailedEnablePlacement(listID: FailedEnableEncoding.uuid(SnipList.inbox.id),
                    orderKey: snip.manualSortKey.data),
                updatedAt: try FailedEnableEncoding.date(snip.updatedAt))), presence: snipPresence)
            expectedOverrides[reference] = FailedEnableImmutableOverrides(
                requestID: FailedEnableEncoding.uuid(snip.requestID), createdAt: createdAt,
                originRaw: SnipOrigin.quickEntry.rawValue)
        }
        let inboxReference = CloudEntityReference(kind: .list, domainID: SnipList.inbox.id)
        let failedReference = CloudEntityReference(kind: .snip, domainID: failed.id)
        let acceptedReferences = Set(accepted.map { CloudEntityReference(kind: .snip, domainID: $0.id) })
            .union([inboxReference])
        expectedL[FailedEnableReference(inboxReference)] = .list(FailedEnableListImage(inbox))
        expectedQ[FailedEnableReference(inboxReference)] = FailedEnablePreparedValue(fields: .list(FailedEnableListValue(
            id: FailedEnableEncoding.uuid(inbox.id), desiredName: inbox.desiredName,
            systemImage: inbox.systemImage, colorPreset: .init(inbox.color?.rawValue),
            orderKey: inbox.sortKey.data, updatedAt: "0000000000000000")), presence: listPresence)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.pauseNextSend()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { transport }
        )
        let enabling = Task { try await coordinator.enableOrRetry() }
        await transport.waitUntilSendPauses()
        await transport.failNextSentItem(.snip(failed.id, in: zone), failure: .retryable)
        await transport.resumeSend()
        let partial = try await enabling.value
        XCTAssertEqual(partial.state, .settingUp)
        await fulfillment(of: [publicationReached], timeout: 30)

        let interrupted = try await persistence.snapshot()
        let transition = try XCTUnwrap(interrupted.transition)
        let token = try XCTUnwrap(transition.freezeToken)
        XCTAssertEqual(transition.phase, .firstSendStarted)
        XCTAssertEqual(interrupted.activeStore.id, sourceID)
        XCTAssertEqual(interrupted.activeStore.revision, initial.activeStore.revision)
        XCTAssertEqual(token.sourceStoreID, sourceID)
        XCTAssertEqual(token.revision, initial.activeStore.revision)
        XCTAssertEqual(transition.namespace, namespace.binding)
        XCTAssertEqual(transition.pendingSettlementSnipIDs, Set(before.snips.map(\.id)))
        XCTAssertNotNil(transition.sendAttempt)
        let sourceAfterSend = try await rawSource.transferSnapshot(revision: interrupted.activeStore.revision)
        let dormantAfterSend = try await rawSource.dormantCloudBases()
        XCTAssertEqual(sourceAfterSend, sourceBefore)
        XCTAssertEqual(dormantAfterSend, dormantBefore)
        let files = FailedEnableEvidenceFile(root: root)
        let evidence = try XCTUnwrap(try files.read(sourceID))
        let rawEvidenceBeforeReopen = try Data(contentsOf: files.url(sourceID))
        XCTAssertEqual(evidence.purpose, .installedEvidence)
        XCTAssertEqual(evidence.sourceStoreID, FailedEnableEncoding.uuid(sourceID))
        XCTAssertEqual(evidence.continuity.sourceRevision, String(initial.activeStore.revision))
        let group = try XCTUnwrap(evidence.namespaces.first { $0.binding == FailedEnableBinding(namespace.binding) })
        let capture = try XCTUnwrap(group.captures.first {
            $0.transitionID == FailedEnableEncoding.uuid(transition.id)
                && $0.candidateStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
        })
        XCTAssertEqual(capture.freeze.id, FailedEnableEncoding.uuid(token.id))
        XCTAssertEqual(capture.freeze.sourceRevision, String(token.revision))
        XCTAssertEqual(capture.sourceDigest, evidence.continuity.sourceDigest)
        XCTAssertEqual(capture.seenRequestIDs, before.snips.map { FailedEnableEncoding.uuid($0.requestID) }.sorted())
        XCTAssertEqual(capture.syncProtocol, .fullRecordV1)
        XCTAssertEqual(capture.normalizer, 1)
        XCTAssertTrue(capture.armed)
        XCTAssertTrue(capture.predecessors.isEmpty)
        XCTAssertTrue(capture.candidateDeletes.isEmpty)
        XCTAssertEqual(capture.records.count, 4)
        XCTAssertEqual(Set(capture.records.map(\.reference)), Set(expectedL.keys))
        let transfer = try XCTUnwrap(evidence.transfers.first { $0.sourceCaptureIDs == [capture.id] })
        XCTAssertEqual(transfer.kind, .candidate)
        XCTAssertEqual(transfer.state, .checked)
        XCTAssertEqual(transfer.sourceStoreID, evidence.sourceStoreID)
        XCTAssertEqual(transfer.destinationStoreID, capture.candidateStoreID)
        XCTAssertEqual(transfer.namespace, group.binding)
        XCTAssertEqual(transfer.outputs, expectedL.values.sorted { $0.reference.sortKey < $1.reference.sortKey })
        XCTAssertTrue(transfer.conflicts.isEmpty)
        XCTAssertTrue(transfer.recoveryDescriptors.isEmpty)
        let candidate = try await persistence.libraryForTransition(storeID: transition.candidateStoreID)
        let committed = try await candidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(Set(committed.readyEntities.map(\.reference)), acceptedReferences)
        XCTAssertEqual(committed.readyEntities.count, 3)
        XCTAssertTrue(committed.deferredEntities.isEmpty)
        XCTAssertTrue(committed.quarantines.isEmpty)
        let actualReceipts = try await candidate.failedEnableReenableReceipts(
            namespaceKey: namespace.namespaceKey.rawValue, transitionID: transition.id)
        XCTAssertEqual(actualReceipts.modern.map(FailedEnableEncoding.hex), transfer.planDigest)
        XCTAssertNotNil(actualReceipts.modern)
        XCTAssertNil(actualReceipts.ambiguous)
        let firstInboxValue = await server.fullSnapshot(for: .list(SnipList.inbox.id, in: zone))
        let firstInboxSnapshot = try XCTUnwrap(firstInboxValue)
        let firstInboxRecord = try CloudFullRecordCodec.list(from: firstInboxSnapshot)
        guard case .value(let firstServerInboxDate) = firstInboxRecord.updatedAt else {
            return XCTFail("Expected the first actual server-owned Inbox date")
        }
        var observedReferences: Set<CloudEntityReference> = []
        for record in capture.records {
            let reference = try record.reference.domain
            XCTAssertEqual(record.sourceMembership, .present)
            XCTAssertEqual(record.source.value, expectedL[record.reference])
            XCTAssertFalse(record.originalAcceptedExists)
            XCTAssertEqual(record.identity.domain, CloudTextStorageIdentity(
                zoneName: zone.name, ownerName: zone.ownerName,
                recordName: "\(reference.kind == .snip ? "s" : "l")-\(reference.domainID.uuidString.lowercased())"))
            XCTAssertEqual(record.preparation.normalizer, 1)
            XCTAssertEqual(record.preparation.classification, .nonconflicting)
            XCTAssertEqual(record.preparation.baseKind, .noBaseEnrollment)
            XCTAssertNil(record.preparation.baseDigest.value)
            XCTAssertNil(record.preparation.fetchedDigest.value)
            XCTAssertNil(record.preparation.reason.value)
            XCTAssertTrue(record.preparation.conflictFields.isEmpty)
            XCTAssertTrue(record.preparation.recoveryIdentities.isEmpty)
            let prepared = try XCTUnwrap(record.preparation.value.value)
            XCTAssertEqual(prepared, expectedQ[record.reference])
            let expectedPresence = reference.kind == .snip ? snipPresence : listPresence
            XCTAssertEqual(record.preparation.knownFields, expectedPresence.keys.sorted())
            XCTAssertEqual(record.preparation.normalizedLocal.acceptedPresence, expectedPresence)
            XCTAssertTrue(record.preparation.normalizedLocal.defaults.isEmpty)
            XCTAssertEqual(record.preparation.normalizedLocal.immutableOverrides.value, expectedOverrides[record.reference])
            if reference == failedReference {
                XCTAssertNil(record.observedAccepted.value)
                XCTAssertNil(record.unqualifiedObservation.value)
                XCTAssertFalse((committed.readyEntities + committed.deferredEntities).contains { $0.reference == reference })
                continue
            }
            let observation = try XCTUnwrap(record.observedAccepted.value)
            observedReferences.insert(reference)
            XCTAssertNil(record.unqualifiedObservation.value)
            let actual = try XCTUnwrap(committed.readyEntities.first { $0.reference == reference })
            let envelope = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: observation.entityBase64)
            XCTAssertEqual(observation.kind, .fullRecord)
            XCTAssertEqual(observation.candidateStoreID, capture.candidateStoreID)
            XCTAssertEqual(observation.localRevision, String(actual.localRevision))
            XCTAssertLessThanOrEqual(try FailedEnableEncoding.revision(observation.namespaceRevision),
                committed.namespaceState.revision)
            XCTAssertFalse(observation.isDeferred)
            XCTAssertFalse(observation.hasUnresolvedLegacyAbsence)
            XCTAssertEqual(observation.dependencyListID.value, actual.dependencyListID.map(FailedEnableEncoding.uuid))
            XCTAssertEqual(envelope.reference, actual.reference)
            XCTAssertEqual(envelope.identity, actual.identity)
            XCTAssertEqual(envelope.schemaVersion, 3)
            XCTAssertEqual(envelope.acceptedData, actual.acceptedData)
            XCTAssertEqual(envelope.presenceData, actual.presenceData)
            XCTAssertEqual(envelope.shadowData, actual.shadowData)
            XCTAssertEqual(envelope.systemFields, actual.systemFields)
            XCTAssertEqual(envelope.dependencyListID, actual.dependencyListID)
            XCTAssertFalse(actual.isDeferred)
            XCTAssertFalse(actual.wasMaterializedBeforeDeferral)
            XCTAssertFalse(actual.hasUnresolvedLegacyAbsence)
            XCTAssertNil(actual.graphRepair)
            XCTAssertNil(actual.deferredLocalMutation)
            if reference.kind == .snip {
                let input = try XCTUnwrap(accepted.first { $0.id == reference.domainID })
                let record = try CloudFullSyncPersistence.snipRecord(actual)
                XCTAssertEqual(record, try JSONDecoder().decode(CloudTypedSnipRecord.self, from: actual.acceptedData))
                XCTAssertEqual(record, try JSONDecoder().decode(CloudTypedSnipRecord.self, from: actual.presenceData))
                XCTAssertEqual(record.storageVersion, 1)
                XCTAssertEqual(record.binding, .canonical)
                XCTAssertEqual(record.schemaVersion, 3)
                XCTAssertEqual(record.id, .snip(input.id, in: zone))
                XCTAssertEqual(record.domainID, input.id)
                XCTAssertEqual(record.requestID, .value(input.requestID))
                XCTAssertEqual(record.createdAt, .value(input.createdAt))
                XCTAssertEqual(record.updatedAt, .value(input.updatedAt))
                XCTAssertEqual(record.origin, .value(SnipOrigin.quickEntry.rawValue))
                XCTAssertEqual(record.text, .value(input.content))
                XCTAssertEqual(record.source, .value(nil))
                XCTAssertEqual(record.isDone, .value(false))
                XCTAssertNil(record.pinnedAt)
                XCTAssertEqual(record.placement, .value(CloudSnipPlacement(
                    listID: SnipList.inbox.id, orderKey: input.manualSortKey)))
                let serverValue = await server.fullSnapshot(for: .snip(input.id, in: zone))
                let serverSnapshot = try XCTUnwrap(serverValue)
                XCTAssertEqual(record, try CloudFullRecordCodec.snip(from: serverSnapshot))
                XCTAssertEqual(actual.shadowData, serverSnapshot.shadow.data)
                XCTAssertEqual(actual.systemFields, serverSnapshot.shadow.systemFields)
                XCTAssertEqual(actual.dependencyListID, SnipList.inbox.id)
                XCTAssertEqual(record.shadow.data, actual.shadowData)
                XCTAssertEqual(record.shadow.systemFields, actual.systemFields)
            } else {
                let record = try CloudFullSyncPersistence.listRecord(actual)
                XCTAssertEqual(record, try JSONDecoder().decode(CloudTypedListRecord.self, from: actual.acceptedData))
                XCTAssertEqual(record, try JSONDecoder().decode(CloudTypedListRecord.self, from: actual.presenceData))
                XCTAssertEqual(record.storageVersion, 1)
                XCTAssertEqual(record.binding, .canonical)
                XCTAssertEqual(record.schemaVersion, 3)
                XCTAssertEqual(record.id, .list(SnipList.inbox.id, in: zone))
                XCTAssertEqual(record.domainID, inbox.id)
                XCTAssertEqual(record.desiredName, .value(inbox.desiredName))
                XCTAssertEqual(record.systemImage, .value(inbox.systemImage))
                XCTAssertEqual(record.color, .some(.value(inbox.color)))
                XCTAssertEqual(record.orderKey, .value(inbox.sortKey))
                XCTAssertEqual(record.updatedAt, .value(firstServerInboxDate))
                XCTAssertEqual(record, firstInboxRecord)
                XCTAssertEqual(actual.shadowData, firstInboxSnapshot.shadow.data)
                XCTAssertEqual(actual.systemFields, firstInboxSnapshot.shadow.systemFields)
                XCTAssertNil(actual.dependencyListID)
                XCTAssertEqual(record.shadow.data, actual.shadowData)
                XCTAssertEqual(record.shadow.systemFields, actual.systemFields)
            }
        }
        XCTAssertEqual(observedReferences, acceptedReferences)
        XCTAssertFalse(observedReferences.contains(failedReference))
        let firstRemoteTexts = await server.storedTextValues()
        let failedRemote = await server.fullSnapshot(for: .snip(failed.id, in: zone))
        XCTAssertEqual(firstRemoteTexts, ["accepted one", "accepted two"])
        XCTAssertNil(failedRemote)

        let settlementReached = expectation(description: "The checked retry reaches the real pre-settlement commit boundary")
        let settlementCrash = CrashInjector(point: .beforeRetryFetchSettlementCommit)
        let settling = try SwiftDataSyncModePersistence(rootURL: root, crashHook: { point in
            do {
                try settlementCrash.hit(point)
            } catch CrashInjector.Failure.injected {
                settlementReached.fulfill()
                throw CrashInjector.Failure.injected
            }
        })
        let reopened = try await settling.snapshot()
        XCTAssertEqual(reopened.activeStore.id, sourceID)
        XCTAssertEqual(reopened.transition?.id, transition.id)
        XCTAssertEqual(reopened.transition?.candidateStoreID, transition.candidateStoreID)
        XCTAssertEqual(reopened.transition?.phase, .candidateReady)
        let settlementTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let settlingCoordinator = ICloudSyncModeCoordinator(persistence: settling,
            namespace: namespace, textZone: zone, makeTransport: { settlementTransport })
        let interruptedRetry = try await settlingCoordinator.enableOrRetry()
        await fulfillment(of: [settlementReached], timeout: 30)
        XCTAssertEqual(interruptedRetry.state, .needsAttention)
        let unsettled = try await settling.snapshot()
        XCTAssertEqual(unsettled.activeStore.id, sourceID)
        XCTAssertEqual(unsettled.transition?.id, transition.id)
        XCTAssertEqual(unsettled.transition?.phase, .candidateReady)
        XCTAssertEqual(unsettled.attentionReason, .terminalFetchFailure)
        let unsettledManifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("activation.json"))) as? [String: Any])
        let unsettledTransition = try XCTUnwrap(unsettledManifest["transition"] as? [String: Any])
        XCTAssertEqual(unsettledTransition["captureAcceptedServerProvenance"] as? Bool, true)
        let settlementEvents = await settlementTransport.events()
        XCTAssertTrue(settlementEvents.isEmpty)
        let retainedAfterCrash = try XCTUnwrap(try files.read(sourceID))
        let settledSource = try await settling.libraryForTransition(storeID: sourceID)
        let afterCrashSource = try await settledSource.transferSnapshot(revision: unsettled.activeStore.revision)
        let afterCrashDormant = try await settledSource.dormantCloudBases()
        XCTAssertEqual(afterCrashSource, sourceBefore)
        XCTAssertEqual(afterCrashDormant, dormantBefore)
        let receiptsAfterCrash = try await candidate.failedEnableReenableReceipts(
            namespaceKey: namespace.namespaceKey.rawValue, transitionID: transition.id)
        XCTAssertNil(receiptsAfterCrash.modern)
        XCTAssertNil(receiptsAfterCrash.ambiguous)

        let resuming = try SwiftDataSyncModePersistence(rootURL: root)
        let resumeStorage = try await resuming.snapshot()
        XCTAssertEqual(resumeStorage.activeStore.id, sourceID)
        XCTAssertEqual(resumeStorage.transition?.id, transition.id)
        let retainedAfterReopen = try XCTUnwrap(try files.read(sourceID))
        let reopenedCandidate = try await resuming.libraryForTransition(storeID: transition.candidateStoreID)
        let reopenedCommitted = try await reopenedCandidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(reopenedCommitted.readyEntities, committed.readyEntities)
        XCTAssertEqual(Set(reopenedCommitted.readyEntities.map(\.reference)), acceptedReferences)
        XCTAssertTrue(reopenedCommitted.deferredEntities.isEmpty)
        XCTAssertTrue(reopenedCommitted.quarantines.isEmpty)
        for retained in [retainedAfterCrash, retainedAfterReopen] {
            let actualGroup = try XCTUnwrap(retained.namespaces.first { $0.binding == group.binding })
            let actualCapture = try XCTUnwrap(actualGroup.captures.first { $0.id == capture.id })
            XCTAssertEqual(actualCapture, capture)
            XCTAssertTrue(retained.transfers.contains(transfer))
            XCTAssertEqual(retained.blobs, evidence.blobs)
        }
        XCTAssertEqual(rawEvidenceBeforeReopen.prefix(6), Data("SSFE1\n".utf8))
        let retry = ICloudSyncModeCoordinator(persistence: resuming, namespace: namespace,
            textZone: zone, makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) })
        let waiting = try await retry.enableOrRetry()
        XCTAssertEqual(waiting.state, .needsAttention)
        let facade = SnipSyncModeStore(resuming).failedEnableReview
        let reviews = try await facade.snapshot()
        XCTAssertEqual(reviews.issues.map(\.entityID), [.snip(failed.id)])
        let issue = try XCTUnwrap(reviews.issues.first)
        XCTAssertEqual(issue.reason, .unknownOutcome)
        XCTAssertEqual(issue.serverState, .absent)
        XCTAssertNil(issue.serverFieldsAtReview)
        XCTAssertEqual(issue.allowedChoices, [.recoverAsNew])
        XCTAssertTrue(issue.earlierLocalVersions.isEmpty)
        guard case .snip(let failedLocal)? = issue.localVersionAtReview else {
            return XCTFail("Expected the actual frozen failed member")
        }
        XCTAssertEqual(failedLocal, failed)
        let sourceBeforeChoice = try await resuming.activeLibrary().checkedSnapshot(sortedBy: .manual)
        let storageBeforeChoice = try await resuming.snapshot()
        let chosen = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        XCTAssertEqual(chosen.selection, .recoverAsNew)
        XCTAssertEqual(chosen.issueID, issue.id)
        XCTAssertEqual(chosen.outputs.count, 1)
        let mapping = try XCTUnwrap(chosen.outputs.first)
        XCTAssertEqual(mapping.original, .snip(failed.id))
        guard case .snip(let outputID) = mapping.output else { return XCTFail("Expected one snip output") }
        let outputRequestID = try XCTUnwrap(mapping.requestID)
        XCTAssertEqual(Set([outputID, outputRequestID]).count, 2)
        let initialIDs = Set(before.snips.flatMap { [$0.id, $0.requestID] } + before.lists.map(\.id))
        XCTAssertTrue(Set([outputID, outputRequestID]).isDisjoint(with: initialIDs))
        XCTAssertTrue(mapping.attachments.isEmpty)
        let repeatedChoice = try await facade.choose(issue.id, selection: .recoverAsNew, expecting: issue.expectation)
        XCTAssertEqual(repeatedChoice, chosen)
        let storageAfterChoice = try await resuming.snapshot()
        let sourceAfterChoice = try await resuming.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(storageAfterChoice, storageBeforeChoice)
        XCTAssertEqual(sourceAfterChoice, sourceBeforeChoice)
        let chosenBundle = try XCTUnwrap(try files.read(sourceID))
        let chosenGroup = try XCTUnwrap(chosenBundle.namespaces.first { $0.binding == group.binding })
        let storedIssue = try XCTUnwrap(chosenGroup.reviews.first { $0.id == FailedEnableEncoding.uuid(issue.id) })
        let decision = try XCTUnwrap(storedIssue.decision.value)
        XCTAssertEqual(decision.choice, .recoverAsNew)
        XCTAssertEqual(decision.outputIDs.count, 1)
        XCTAssertEqual(decision.outputIDs.first?.original, FailedEnableReference(failedReference))
        XCTAssertEqual(decision.outputIDs.first?.output,
            FailedEnableReference(CloudEntityReference(kind: .snip, domainID: outputID)))
        XCTAssertEqual(decision.outputIDs.first?.requestID.value, FailedEnableEncoding.uuid(outputRequestID))

        let result = try await retry.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let completed = try await resuming.snapshot()
        XCTAssertNil(completed.transition)
        let active = try await resuming.libraryForTransition(storeID: completed.activeStore.id)
        let final = try await active.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.count, 3)
        XCTAssertEqual(Set(final.snips.map(\.id)), Set(accepted.map(\.id) + [outputID]))
        XCTAssertEqual(Set(final.snips.map(\.requestID)), Set(accepted.map(\.requestID) + [outputRequestID]))
        XCTAssertEqual(final.lists, [inbox])
        for input in accepted {
            XCTAssertEqual(final.snips.first { $0.id == input.id }, input)
        }
        let copied = try XCTUnwrap(final.snips.first { $0.id == outputID })
        XCTAssertEqual(copied.requestID, outputRequestID)
        XCTAssertEqual(copied.content, "failed")
        XCTAssertEqual(copied.createdAt, failed.createdAt)
        XCTAssertEqual(copied.updatedAt, failed.updatedAt)
        XCTAssertEqual(copied.origin, .quickEntry)
        XCTAssertNil(copied.source)
        XCTAssertFalse(copied.isDone)
        XCTAssertNil(copied.pinnedAt)
        XCTAssertEqual(copied.listID, SnipList.inbox.id)
        XCTAssertEqual(copied.manualSortKey, failed.manualSortKey)
        XCTAssertTrue(copied.attachments.isEmpty)
        XCTAssertFalse(final.snips.contains { $0.id == failed.id })
        let recovery = try await active.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
        XCTAssertTrue(recovery.isEmpty)
        let remoteTexts = await server.storedTextValues()
        let remoteTypes = await server.storedRecordTypes(in: zone)
        let originalFailed = await server.fullSnapshot(for: .snip(failed.id, in: zone))
        XCTAssertEqual(remoteTexts, ["accepted one", "accepted two", "failed"])
        XCTAssertEqual(remoteTypes.filter { $0 == "Snip" }.count, 3)
        XCTAssertEqual(remoteTypes.filter { $0 == "List" }.count, 1)
        XCTAssertNil(originalFailed)
        for text in ["accepted one", "accepted two", "failed"] {
            let input = try XCTUnwrap(before.snips.first { $0.content == text })
            let id = text == "failed" ? outputID : input.id
            let requestID = text == "failed" ? outputRequestID : input.requestID
            let value = await server.fullSnapshot(for: .snip(id, in: zone))
            let record = try CloudFullRecordCodec.snip(from: try XCTUnwrap(value))
            XCTAssertEqual(record.id, .snip(id, in: zone))
            XCTAssertEqual(record.domainID, id)
            XCTAssertEqual(record.requestID, .value(requestID))
            XCTAssertEqual(record.createdAt, .value(input.createdAt))
            XCTAssertEqual(record.updatedAt, .value(input.updatedAt))
            XCTAssertEqual(record.origin, .value(SnipOrigin.quickEntry.rawValue))
            XCTAssertEqual(record.text, .value(text))
            XCTAssertEqual(record.source, .value(nil))
            XCTAssertEqual(record.isDone, .value(false))
            XCTAssertNil(record.pinnedAt)
            XCTAssertEqual(record.placement, .value(CloudSnipPlacement(
                listID: SnipList.inbox.id, orderKey: input.manualSortKey)))
        }
        let sourceAfterOn = try await rawSource.transferSnapshot(revision: initial.activeStore.revision)
        let dormantAfterOn = try await rawSource.dormantCloudBases()
        let sourceArchiveAfterOn = try await rawSource.archive()
        XCTAssertEqual(sourceAfterOn, sourceBefore)
        XCTAssertEqual(dormantAfterOn, dormantBefore)
        XCTAssertEqual(sourceArchiveAfterOn.seenRequestIDs, archiveBefore.seenRequestIDs)
        let retainedAfterOn = try XCTUnwrap(try files.read(sourceID))
        let retainedGroup = try XCTUnwrap(retainedAfterOn.namespaces.first { $0.binding == group.binding })
        XCTAssertEqual(retainedGroup.captures.first { $0.id == capture.id }, capture)
        XCTAssertTrue(retainedAfterOn.transfers.contains(transfer))
        XCTAssertEqual(retainedAfterOn.blobs, evidence.blobs)
        XCTAssertEqual(retainedGroup.reviews.first { $0.id == storedIssue.id }?.decision.value, decision)
        let finalManifest = try JSONDecoder().decode(SwiftDataSyncModePersistence.Manifest.self,
            from: Data(contentsOf: root.appendingPathComponent("activation.json")))
        for id in [sourceID, transition.candidateStoreID, completed.activeStore.id] {
            let retainedStore = try XCTUnwrap(finalManifest.stores.first { $0.id == id })
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(retainedStore.relativeRoot)
                .appendingPathComponent("snips.store").path))
        }
        let repeatedContinue = try await retry.enableOrRetry()
        XCTAssertEqual(repeatedContinue.state, .on)
        let repeatedFinal = try await resuming.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(repeatedFinal, final)
        let finalOwner = try SwiftDataSyncModePersistence(rootURL: root)
        let finalCoordinator = ICloudSyncModeCoordinator(persistence: finalOwner, namespace: namespace,
            textZone: zone, makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) })
        let finalStatus = try await finalCoordinator.enableOrRetry()
        XCTAssertEqual(finalStatus.state, .on)
        let finalStorage = try await finalOwner.snapshot()
        XCTAssertNil(finalStorage.transition)
        XCTAssertEqual(finalStorage.activeStore.id, completed.activeStore.id)
        let finalSnapshot = try await finalOwner.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(finalSnapshot, final)
        let reopenedReview = try await SnipSyncModeStore(finalOwner).failedEnableReview.snapshot()
        XCTAssertEqual(reopenedReview.issues.first { $0.id == issue.id }?.selection, chosen)
    }

    func testTypedModeSendAttemptKeepsListAndSnipWithTheSameDomainID() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let crash = CrashInjector(point: .beforeCandidateMergeDurability)
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root, defaultSyncProtocol: .fullRecordV1, crashHook: crash.hit)
        let source = try await persistence.activeLibrary()
        let requestID = UUID()
        let now = Date(timeIntervalSince1970: 10)
        _ = try await source.perform(.add(content: "typed source snip", origin: .quickEntry, source: nil,
            listID: SnipList.inbox.id, attachmentURLs: [], requestID: requestID, now: now), sortedBy: .manual)
        let added = try await source.checkedSnapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(added.snips.first { $0.requestID == requestID })
        let domainID = snip.id
        XCTAssertNotEqual(domainID, SnipList.inbox.id)
        XCTAssertEqual(snip.requestID, requestID)
        XCTAssertEqual(snip.content, "typed source snip")
        XCTAssertEqual(snip.createdAt, now)
        XCTAssertEqual(snip.updatedAt, now)
        XCTAssertEqual(snip.origin, .quickEntry)
        XCTAssertNil(snip.source)
        XCTAssertFalse(snip.isDone)
        XCTAssertNil(snip.pinnedAt)
        XCTAssertEqual(snip.listID, SnipList.inbox.id)
        XCTAssertTrue(snip.attachments.isEmpty)
        let sharedList = SnipList(id: domainID, name: "Typed shared list", systemImage: "folder",
            position: 1, sortKey: SnipOrderKey(rawDigits: [192]))
        _ = try await source.perform(.restoreList(sharedList), sortedBy: .manual)
        let sourceBefore = try await source.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(sourceBefore.snips, [snip])
        XCTAssertEqual(sourceBefore.lists.count, 2)
        let savedList = try XCTUnwrap(sourceBefore.lists.first { $0.id == domainID })
        XCTAssertEqual(savedList, sharedList)
        XCTAssertEqual(savedList.desiredName, "Typed shared list")
        XCTAssertEqual(savedList.resolvedName, "Typed shared list")
        XCTAssertEqual(savedList.systemImage, "folder")
        XCTAssertNil(savedList.color)
        XCTAssertEqual(savedList.sortKey.data, Data([192]))
        let sourceStorage = try await persistence.snapshot()
        XCTAssertEqual(sourceStorage.activeStore.kind, .localOnly)
        XCTAssertNil(sourceStorage.transition)
        let namespace = makeNamespace()
        let zone = textZone(namespace)
        let listReference = CloudEntityReference(kind: .list, domainID: domainID)
        let snipReference = CloudEntityReference(kind: .snip, domainID: domainID)
        let inboxReference = CloudEntityReference(kind: .list, domainID: SnipList.inbox.id)
        let expectedReferences = Set([listReference, snipReference])
        let expectedCapturedReferences = Set([listReference, snipReference, inboxReference])
        let listIdentity = CloudTextStorageIdentity(zoneName: zone.name, ownerName: zone.ownerName,
            recordName: "l-\(domainID.uuidString.lowercased())")
        let snipIdentity = CloudTextStorageIdentity(zoneName: zone.name, ownerName: zone.ownerName,
            recordName: "s-\(domainID.uuidString.lowercased())")
        XCTAssertNotEqual(listIdentity, snipIdentity)
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(persistence: persistence, namespace: namespace,
            textZone: zone, makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) })
        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("Expected the durable pre-apply interruption")
        } catch CrashInjector.Failure.injected {}
        let interrupted = try await persistence.snapshot()
        let frozen = try XCTUnwrap(interrupted.transition)
        XCTAssertEqual(frozen.phase, .sourceFrozen)
        XCTAssertEqual(frozen.syncProtocol, .fullRecordV1)
        XCTAssertEqual(frozen.namespace, namespace.binding)
        XCTAssertEqual(frozen.sourceStoreID, sourceStorage.activeStore.id)
        XCTAssertEqual(interrupted.activeStore.id, sourceStorage.activeStore.id)
        let intent = try XCTUnwrap(frozen.mergeIntent)
        let token = try XCTUnwrap(frozen.freezeToken)
        XCTAssertEqual(intent.fullReenablePlanID, frozen.id)
        XCTAssertEqual(intent.sourceRevision, sourceStorage.activeStore.revision)
        XCTAssertEqual(token.sourceStoreID, frozen.sourceStoreID)
        XCTAssertEqual(token.revision, intent.sourceRevision)
        let manifest = try JSONDecoder().decode(SwiftDataSyncModePersistence.Manifest.self,
            from: Data(contentsOf: root.appendingPathComponent("activation.json")))
        let candidateStore = try XCTUnwrap(manifest.stores.first { $0.id == frozen.candidateStoreID })
        let planRoot = root.appendingPathComponent(candidateStore.relativeRoot, isDirectory: true)
            .appendingPathComponent("full-reenable-v1", isDirectory: true)
            .appendingPathComponent(frozen.id.uuidString.lowercased(), isDirectory: true)
        let staged = try JSONDecoder().decode(CloudFullReenableStagedPlan.self,
            from: Data(contentsOf: planRoot.appendingPathComponent("plan.json")))
        let restored = try staged.restore(from: planRoot)
        XCTAssertNil(restored.acceptedLegacyDigest)
        XCTAssertTrue(try restored.plan.hasValidDigest())
        XCTAssertEqual(restored.plan.transitionID, frozen.id)
        XCTAssertEqual(restored.plan.namespaceKey, namespace.namespaceKey.rawValue)
        XCTAssertEqual(restored.plan.planDigest, intent.planDigest)
        XCTAssertEqual(restored.plan.snips, [snip])
        XCTAssertEqual(restored.plan.lists.first { $0.id == domainID }, savedList)
        XCTAssertTrue(restored.plan.attachmentData.isEmpty)
        let files = FailedEnableEvidenceFile(root: root)
        let evidence = try XCTUnwrap(try files.read(frozen.sourceStoreID))
        let group = try XCTUnwrap(evidence.namespaces.first { $0.binding == FailedEnableBinding(namespace.binding) })
        let capture = try XCTUnwrap(group.captures.first {
            $0.transitionID == FailedEnableEncoding.uuid(frozen.id)
                && $0.candidateStoreID == FailedEnableEncoding.uuid(frozen.candidateStoreID)
        })
        XCTAssertEqual(evidence.sourceStoreID, FailedEnableEncoding.uuid(frozen.sourceStoreID))
        XCTAssertEqual(capture.freeze.id, FailedEnableEncoding.uuid(token.id))
        XCTAssertEqual(capture.freeze.sourceRevision, String(token.revision))
        XCTAssertEqual(capture.sourceDigest, evidence.continuity.sourceDigest)
        XCTAssertEqual(capture.seenRequestIDs, [FailedEnableEncoding.uuid(requestID)])
        XCTAssertEqual(capture.syncProtocol, .fullRecordV1)
        XCTAssertFalse(capture.armed)
        XCTAssertEqual(capture.records.count, 3)
        XCTAssertEqual(Set(capture.records.map(\.reference)),
            Set(expectedCapturedReferences.map(FailedEnableReference.init)))
        let capturedReferences = Set(try capture.records.map { try $0.reference.domain })
        let snipCapture = try XCTUnwrap(capture.records.first { $0.reference == FailedEnableReference(snipReference) })
        guard case .snip(let snipImage)? = snipCapture.source.value else { return XCTFail("Expected actual snip L") }
        XCTAssertEqual(try snipImage.domain, snip)
        let listCapture = try XCTUnwrap(capture.records.first { $0.reference == FailedEnableReference(listReference) })
        guard case .list(let listImage)? = listCapture.source.value else { return XCTFail("Expected actual list L") }
        XCTAssertEqual(try listImage.domain, savedList)
        for record in capture.records {
            XCTAssertEqual(record.sourceMembership, .present)
            XCTAssertNotNil(record.preparation.value.value)
            XCTAssertNil(record.observedAccepted.value)
            XCTAssertNil(record.unqualifiedObservation.value)
        }
        let transfer = try XCTUnwrap(evidence.transfers.first { $0.sourceCaptureIDs == [capture.id] })
        XCTAssertEqual(transfer.kind, .candidate)
        XCTAssertEqual(transfer.state, .prepared)
        XCTAssertEqual(transfer.sourceStoreID, evidence.sourceStoreID)
        XCTAssertEqual(transfer.destinationStoreID, capture.candidateStoreID)
        XCTAssertEqual(transfer.namespace, group.binding)
        XCTAssertEqual(transfer.planDigest, FailedEnableEncoding.hex(intent.planDigest))

        try await persistence.reconcileFullReenableIntent()
        let mergedStorage = try await persistence.snapshot()
        let transition = try XCTUnwrap(mergedStorage.transition)
        XCTAssertEqual(transition.phase, .recordsMerged)
        XCTAssertEqual(transition.id, frozen.id)
        XCTAssertEqual(transition.candidateStoreID, frozen.candidateStoreID)
        XCTAssertEqual(transition.sourceStoreID, frozen.sourceStoreID)
        XCTAssertEqual(mergedStorage.activeStore.id, sourceStorage.activeStore.id)
        XCTAssertNil(transition.mergeIntent)
        XCTAssertEqual(transition.approvedSnipIDs, Set([domainID]))
        let replayed = try XCTUnwrap(try files.read(frozen.sourceStoreID))
        let replayedGroup = try XCTUnwrap(replayed.namespaces.first { $0.binding == group.binding })
        XCTAssertEqual(replayedGroup.captures.first { $0.id == capture.id }, capture)
        let checkedTransfer = try XCTUnwrap(replayed.transfers.first { $0.sourceCaptureIDs == [capture.id] })
        XCTAssertEqual(checkedTransfer.state, .checked)
        XCTAssertEqual(checkedTransfer.planDigest, transfer.planDigest)
        XCTAssertEqual(checkedTransfer.sourceStoreID, transfer.sourceStoreID)
        XCTAssertEqual(checkedTransfer.destinationStoreID, transfer.destinationStoreID)
        XCTAssertEqual(checkedTransfer.namespace, transfer.namespace)
        XCTAssertEqual(checkedTransfer.outputs, transfer.outputs)
        let candidate = try await persistence.libraryForTransition(storeID: transition.candidateStoreID)
        let prepared = try await candidate.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(prepared.snips, [snip])
        XCTAssertEqual(prepared.lists.count, 2)
        let preparedSnip = try XCTUnwrap(prepared.snips.first { $0.id == domainID })
        let preparedList = try XCTUnwrap(prepared.lists.first { $0.id == domainID })
        XCTAssertEqual(preparedSnip, snip)
        XCTAssertEqual(preparedList, savedList)
        let raw = CloudFullSyncPersistence(library: candidate, namespace: namespace, dataZone: zone)
        try await raw.approveModeMerge(snipIDs: transition.approvedSnipIDs)
        let enrolled = try await candidate.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(enrolled.enrolledEntities, expectedCapturedReferences)
        XCTAssertTrue(enrolled.readyEntities.isEmpty)
        XCTAssertTrue(enrolled.deferredEntities.isEmpty)
        try await persistence.recordEnrollmentApproved(expected: transition.approvedSnipIDs)
        try await persistence.recordFirstSendStarted()
        let firstSend = try await persistence.snapshot()
        XCTAssertEqual(firstSend.transition?.phase, .firstSendStarted)
        XCTAssertEqual(firstSend.transition?.id, frozen.id)
        let listDraft = try CloudFullRecordCodec.listDraft(preparedList,
            updatedAt: Date(timeIntervalSinceReferenceDate: 0), in: zone)
        let snipDraft = try CloudFullRecordCodec.snipDraft(preparedSnip, in: zone)
        XCTAssertEqual(listDraft.id, .list(domainID, in: zone))
        XCTAssertEqual(snipDraft.id, .snip(domainID, in: zone))
        XCTAssertEqual(listDraft.recordType, "List")
        XCTAssertEqual(snipDraft.recordType, "Snip")
        XCTAssertEqual(listDraft.encryptedFields["desiredName"], .string("Typed shared list"))
        XCTAssertEqual(listDraft.encryptedFields["systemImage"], .string("folder"))
        XCTAssertEqual(snipDraft.encryptedFields["requestID"], .string(requestID.uuidString.lowercased()))
        XCTAssertEqual(snipDraft.encryptedFields["text"], .string("typed source snip"))
        XCTAssertEqual(snipDraft.encryptedFields["isDone"], .int64(0))
        XCTAssertNil(listDraft.base)
        XCTAssertNil(snipDraft.base)
        let outbound = CloudOutboundBatch(operations: [.save(listDraft), .save(snipDraft)])
        let attempt = try await raw.modeSendAttempt(for: outbound, namespace: namespace.binding)
        XCTAssertEqual(attempt.namespace, namespace.binding)
        XCTAssertEqual(attempt.operations.count, 2)
        XCTAssertEqual(Set(attempt.operations.compactMap(\.reference)), expectedReferences)
        XCTAssertEqual(Set(attempt.operations.map(\.recordIdentity)), Set([listIdentity, snipIdentity]))
        let listOperation = try XCTUnwrap(attempt.operations.first { $0.reference == listReference })
        let snipOperation = try XCTUnwrap(attempt.operations.first { $0.reference == snipReference })
        XCTAssertEqual(listOperation.recordIdentity, listIdentity)
        XCTAssertEqual(snipOperation.recordIdentity, snipIdentity)
        XCTAssertEqual(listOperation.kind, .save)
        XCTAssertEqual(snipOperation.kind, .save)
        XCTAssertTrue(Set(attempt.operations.compactMap(\.reference)).isSubset(of: capturedReferences))
        let unarmed = try XCTUnwrap(try files.read(frozen.sourceStoreID))
        let unarmedGroup = try XCTUnwrap(unarmed.namespaces.first { $0.binding == group.binding })
        XCTAssertEqual(unarmedGroup.captures.first { $0.id == capture.id }, capture)
        XCTAssertTrue(unarmed.transfers.contains(checkedTransfer))
        try await persistence.recordSendAttempt(attempt)
        let recorded = try await persistence.snapshot()
        XCTAssertEqual(recorded.transition?.sendAttempt, attempt)
        XCTAssertEqual(recorded.transition?.phase, .firstSendStarted)
        let armed = try XCTUnwrap(try files.read(frozen.sourceStoreID))
        let armedGroup = try XCTUnwrap(armed.namespaces.first { $0.binding == group.binding })
        let armedCapture = try XCTUnwrap(armedGroup.captures.first { $0.id == capture.id })
        XCTAssertTrue(armedCapture.armed)
        XCTAssertEqual(armedCapture.freeze, capture.freeze)
        XCTAssertEqual(armedCapture.sourceDigest, capture.sourceDigest)
        XCTAssertEqual(armedCapture.preparationDigest, capture.preparationDigest)
        XCTAssertEqual(armedCapture.records, capture.records)
        XCTAssertTrue(armed.transfers.contains(checkedTransfer))
        let unsentTexts = await server.storedTextValues()
        XCTAssertTrue(unsentTexts.isEmpty)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let reopenedStorage = try await reopened.snapshot()
        let stored = try XCTUnwrap(reopenedStorage.transition)
        XCTAssertEqual(stored.phase, .candidateReady)
        XCTAssertEqual(stored.id, frozen.id)
        XCTAssertEqual(stored.sourceStoreID, frozen.sourceStoreID)
        XCTAssertEqual(stored.candidateStoreID, frozen.candidateStoreID)
        XCTAssertEqual(reopenedStorage.activeStore.id, sourceStorage.activeStore.id)
        let storedAttempt = try XCTUnwrap(stored.sendAttempt)
        XCTAssertEqual(storedAttempt, attempt)
        XCTAssertEqual(storedAttempt.namespace, namespace.binding)
        XCTAssertEqual(storedAttempt.operations.count, 2)
        XCTAssertEqual(Set(storedAttempt.operations.map(\.recordIdentity)), Set([listIdentity, snipIdentity]))
        XCTAssertEqual(Set(stored.sendAttempt?.operations.compactMap(\.reference) ?? []), Set([
            CloudEntityReference(kind: .list, domainID: domainID),
            CloudEntityReference(kind: .snip, domainID: domainID),
        ]))
        XCTAssertEqual(stored.pendingSettlementSnipIDs, [domainID])
        XCTAssertFalse(stored.pendingSettlementSnipIDs.contains(SnipList.inbox.id))
        let reopenedSource = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(reopenedSource, sourceBefore)
        let reopenedCandidate = try await reopened.libraryForTransition(storeID: stored.candidateStoreID)
        let reopenedPrepared = try await reopenedCandidate.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(reopenedPrepared, prepared)
        let durable = try XCTUnwrap(try files.read(frozen.sourceStoreID))
        let durableGroup = try XCTUnwrap(durable.namespaces.first { $0.binding == group.binding })
        XCTAssertEqual(durableGroup.captures.first { $0.id == capture.id }, armedCapture)
        XCTAssertTrue(durable.transfers.contains(checkedTransfer))
    }

}

private struct LegacyStagedListColor: Encodable {
    let light: String
    let dark: String
}

private struct LegacyStagedList: Encodable {
    let id: UUID
    let name: String
    let desiredName: String
    let resolvedName: String
    let systemImage: String
    let color: LegacyStagedListColor?
    let position: Int
    let sortKey: SnipOrderKey

    init(_ list: SnipList) {
        id = list.id
        name = list.resolvedName
        desiredName = list.desiredName
        resolvedName = list.resolvedName
        systemImage = list.systemImage
        color = switch list.color {
        case .red: LegacyStagedListColor(light: "#E81345", dark: "#FF2454")
        case .orange: LegacyStagedListColor(light: "#FF7800", dark: "#FF8A00")
        case .yellow: LegacyStagedListColor(light: "#F5C400", dark: "#FFD000")
        case .green: LegacyStagedListColor(light: "#00B84F", dark: "#00DB63")
        case .teal: LegacyStagedListColor(light: "#1C807A", dark: "#82FAF3")
        case .blue: LegacyStagedListColor(light: "#007AFF", dark: "#008CFF")
        case .indigo: LegacyStagedListColor(light: "#4636E8", dark: "#604AFF")
        case .violet: LegacyStagedListColor(light: "#9822EE", dark: "#AF32FF")
        case .pink: LegacyStagedListColor(light: "#801C4C", dark: "#FA82BC")
        case .clay: LegacyStagedListColor(light: "#9A5A3C", dark: "#F0A17E")
        case .slate: LegacyStagedListColor(light: "#526678", dark: "#BBD1E5")
        case nil: nil
        }
        position = list.position
        sortKey = list.sortKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, desiredName, resolvedName, systemImage, color, position, sortKey
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(desiredName, forKey: .desiredName)
        try container.encode(resolvedName, forKey: .resolvedName)
        try container.encode(systemImage, forKey: .systemImage)
        try container.encode(color, forKey: .color)
        try container.encode(position, forKey: .position)
        try container.encode(sortKey, forKey: .sortKey)
    }
}

private struct LegacyStagedPlanDigestInput: Encodable {
    let storageVersion: Int
    let transitionID: UUID
    let namespaceKey: String
    let expectedNamespaceRevision: UInt64
    let targetRevision: UInt64
    let targetDigest: Data
    let snips: [Snip]
    let lists: [LegacyStagedList]
    let attachmentData: [UUID: Data]
    let dormantPayload: Data
    let acceptedCAS: [CloudFullReenableAcceptedCAS]
    let conflicts: [LegacyStagedJSON]
    let recoveryInputs: [CloudFullRecoveryInput]
    let approvedSnipIDs: Set<UUID>
    let recoveredSourceSnipIDs: Set<UUID>
}

private let legacyStagedListRecoveryID = UUID(
    uuidString: "00000000-0000-4000-8000-000000000123"
)!

private enum LegacyStagedJSON: Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Self].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

private func rewriteStagedPlanAsLegacy(
    at url: URL,
    target: SwiftDataSnipLibrary,
    includeListConflict: Bool
) async throws -> Data {
    let stagedData = try Data(contentsOf: url)
    let staged = try JSONDecoder().decode(CloudFullReenableStagedPlan.self, from: stagedData)
    let plan = try staged.restore(from: url.deletingLastPathComponent()).plan
    let targetSnapshot = try await target.transferSnapshot(revision: plan.targetRevision)
    let targetDigest = legacyTransferSnapshotDigest(targetSnapshot)
    let legacyLists = plan.lists.map(LegacyStagedList.init)
    var conflicts = plan.conflicts
    if includeListConflict {
        let recovered = try XCTUnwrap(plan.lists.first)
        conflicts.append(CloudConflictInput(
            key: "legacy-list-conflict",
            reference: CloudEntityReference(kind: .list, domainID: recovered.id),
            format: .listMergeV1,
            payload: Data("legacy list conflict".utf8),
            recovery: .list(RecoveredListEdit(
                id: legacyStagedListRecoveryID,
                currentListID: recovered.id,
                recovered: SnipList(
                    id: recovered.id,
                    desiredName: "Recovered legacy list",
                    resolvedName: "Recovered legacy list",
                    systemImage: "paintpalette",
                    color: .pink,
                    sortKey: recovered.sortKey
                ),
                conflictingFields: [.color]
            ))
        ))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    let encodedConflicts = try JSONSerialization.jsonObject(with: encoder.encode(conflicts))
    let legacyConflictsJSON = legacyColorJSON(encodedConflicts)
    let legacyConflictsData = try JSONSerialization.data(
        withJSONObject: legacyConflictsJSON,
        options: [.sortedKeys]
    )
    let legacyConflicts = try JSONDecoder().decode(
        [LegacyStagedJSON].self,
        from: legacyConflictsData
    )
    let digestInput = LegacyStagedPlanDigestInput(
        storageVersion: plan.storageVersion,
        transitionID: plan.transitionID,
        namespaceKey: plan.namespaceKey,
        expectedNamespaceRevision: plan.expectedNamespaceRevision,
        targetRevision: plan.targetRevision,
        targetDigest: targetDigest,
        snips: plan.snips,
        lists: legacyLists,
        attachmentData: plan.attachmentData,
        dormantPayload: plan.dormantPayload,
        acceptedCAS: plan.acceptedCAS,
        conflicts: legacyConflicts,
        recoveryInputs: plan.recoveryInputs,
        approvedSnipIDs: plan.result.approvedSnipIDs,
        recoveredSourceSnipIDs: plan.result.recoveredSourceSnipIDs
    )
    let legacyDigest = Data(SHA256.hash(data: try encoder.encode(digestInput)))
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: stagedData) as? [String: Any]
    )
    object["lists"] = try JSONSerialization.jsonObject(with: encoder.encode(legacyLists))
    object["conflicts"] = legacyConflictsJSON
    object["targetDigest"] = targetDigest.base64EncodedString()
    object["planDigest"] = legacyDigest.base64EncodedString()
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        .write(to: url, options: .atomic)
    return legacyDigest
}

private func legacyColorJSON(_ value: Any) -> Any {
    if let values = value as? [Any] {
        return values.map(legacyColorJSON)
    }
    guard var values = value as? [String: Any] else { return value }
    values = values.mapValues(legacyColorJSON)
    guard let preset = values.removeValue(forKey: "colorPreset") as? String else {
        return values
    }
    let pair: [String: String] = switch preset {
    case "red": ["light": "#E81345", "dark": "#FF2454"]
    case "orange": ["light": "#FF7800", "dark": "#FF8A00"]
    case "yellow": ["light": "#F5C400", "dark": "#FFD000"]
    case "green": ["light": "#00B84F", "dark": "#00DB63"]
    case "teal": ["light": "#1C807A", "dark": "#82FAF3"]
    case "blue": ["light": "#007AFF", "dark": "#008CFF"]
    case "indigo": ["light": "#4636E8", "dark": "#604AFF"]
    case "violet": ["light": "#9822EE", "dark": "#AF32FF"]
    case "pink": ["light": "#801C4C", "dark": "#FA82BC"]
    case "clay": ["light": "#9A5A3C", "dark": "#F0A17E"]
    case "slate": ["light": "#526678", "dark": "#BBD1E5"]
    default: [:]
    }
    values["color"] = pair
    return values
}

private func legacyTransferSnapshotDigest(_ snapshot: SnipLibraryTransferSnapshot) -> Data {
    var bytes = Data("snipsnap-transfer-snapshot-v2".utf8)
    appendLegacyDigest(snapshot.revision, to: &bytes)
    appendLegacyDigest(UInt64(snapshot.lists.count), to: &bytes)
    for list in snapshot.lists {
        appendLegacyDigest(list.id.uuidString.lowercased(), to: &bytes)
        appendLegacyDigest(list.desiredName, to: &bytes)
        appendLegacyDigest(list.resolvedName, to: &bytes)
        appendLegacyDigest(list.systemImage, to: &bytes)
        let color = LegacyStagedList(list).color
        appendLegacyDigest(color?.light ?? "", to: &bytes)
        appendLegacyDigest(color?.dark ?? "", to: &bytes)
        appendLegacyDigest(list.sortKey.data, to: &bytes)
    }
    appendLegacyDigest(UInt64(snapshot.snips.count), to: &bytes)
    for snip in snapshot.snips {
        appendLegacyDigest(
            SnipLibraryTransferPlanner.digest(
                snip: snip,
                attachmentData: snapshot.attachmentData,
                attachmentFileDigests: snapshot.attachmentFileDigests
            ),
            to: &bytes
        )
    }
    appendLegacyDigest(snapshot.opaqueSyncStateDigest, to: &bytes)
    return Data(SHA256.hash(data: bytes))
}

private func appendLegacyDigest(_ value: String, to data: inout Data) {
    appendLegacyDigest(Data(value.utf8), to: &data)
}

private func appendLegacyDigest(_ value: Data, to data: inout Data) {
    appendLegacyDigest(UInt64(value.count), to: &data)
    data.append(value)
}

private func appendLegacyDigest(_ value: UInt64, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}
