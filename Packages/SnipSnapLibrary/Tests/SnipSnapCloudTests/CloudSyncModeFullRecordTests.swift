import SnipSnapCore
import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
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
            namespaceKey: namespace.canonicalKey
        )
        let replacement = try XCTUnwrap(attachmentStorage.publications.first(where: {
            !$0.payloadAccepted
        }))
        let failedPayloadID = CloudAttachmentRecordCodec.recordID(
            replacement.metadata.payloadIdentity
        )
        await transport.failNextSentItem(failedPayloadID, failure: failure)
        await transport.resumeSend()

        let failedResult = try await failingSync.value
        XCTAssertEqual(failedResult.state, .on)
        try await add("unrelated after attachment failure", to: active)
        let laterResult = try await coordinator.syncActive()
        XCTAssertEqual(laterResult.state, .on)

        let after = try await activeLibrary.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.canonicalKey
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
            namespaceKey: namespace.canonicalKey
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
            namespaceKey: namespace.canonicalKey
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
        await transport.failNextSentItem(.snip(snip.id, in: dataZone), failure: .retryable)
        await transport.resumeSend()
        let partial = try await enabling.value

        XCTAssertEqual(partial.state, .settingUp)
        let partialStorage = try await persistence.snapshot()
        XCTAssertEqual(partialStorage.activeStore.kind, .localOnly)
        let transition = try XCTUnwrap(partialStorage.transition)
        let candidate = try await persistence.libraryForTransition(
            storeID: transition.candidateStoreID
        )
        let partialAttachments = try await candidate.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.canonicalKey
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
        let completed = try await retry.enableOrRetry()

        XCTAssertEqual(completed.state, .on)
        let completedStorage = try await reopened.snapshot()
        let active = try await reopened.libraryForTransition(
            storeID: completedStorage.activeStore.id
        )
        let settled = try await active.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.canonicalKey
        )
        let publication = try XCTUnwrap(settled.publications.first)
        XCTAssertTrue(publication.payloadAccepted)
        XCTAssertTrue(publication.metadataAccepted)
        XCTAssertEqual(publication.metadata.attachmentID, attachmentID)
        let remoteMetadata = await server.fullSnapshot(
            for: CloudAttachmentRecordCodec.recordID(publication.metadataIdentity)
        )
        XCTAssertNotNil(remoteMetadata)
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
            namespaceKey: namespace.canonicalKey
        )
        let legacyBefore = try await active.cloudTextSyncSnapshot(
            namespaceKey: namespace.canonicalKey
        )
        XCTAssertEqual(fullBefore.namespaceState.phase, .active)
        XCTAssertTrue(legacyBefore.records.isEmpty)

        let firstStatus = try await coordinator.status()
        let secondStatus = try await coordinator.status()
        let modeAfter = try await persistence.snapshot()
        let fullAfter = try await active.cloudFullStorageSnapshot(
            namespaceKey: namespace.canonicalKey
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
            namespaceKey: namespace.canonicalKey
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
            namespaceKey: namespace.canonicalKey
        )
        let publication = try XCTUnwrap(stored.publications.first)
        XCTAssertTrue(publication.payloadAccepted)
        XCTAssertTrue(publication.metadataAccepted)
        XCTAssertNil(publication.sourceURL)
    }

    func testFullEnableRefetchesDeferredSnipAfterItsListArrives() async throws {
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
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        _ = try await writer.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.snipDraft(snip, in: zone))
        ]))
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )

        let first = try await coordinator.enableOrRetry()
        XCTAssertEqual(first.state, .settingUp)
        let waiting = try await persistence.snapshot()
        XCTAssertEqual(waiting.transition?.phase, .candidateReady)
        XCTAssertNil(waiting.attentionReason)

        let listWriter = FakeCloudRecordTransport(server: server, namespace: namespace)
        _ = try await listWriter.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.listDraft(list, updatedAt: Date(), in: zone))
        ]))
        let second = try await coordinator.enableOrRetry()
        XCTAssertEqual(second.state, .on)
        let active = try await persistence.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        XCTAssertTrue(final.lists.contains { $0.id == list.id })
        XCTAssertEqual(final.snips.first(where: { $0.id == snip.id })?.listID, list.id)
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
                namespaceKey: namespace.canonicalKey
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
                Set(dormant.filter { $0.namespaceKey == namespace.canonicalKey }.map(\.reference)),
                Set((acceptedBefore.readyEntities + acceptedBefore.deferredEntities).map(\.reference))
            )
            let localFull = try await local.cloudFullStorageSnapshot(
                namespaceKey: namespace.canonicalKey
            )
            let localWire = try await local.cloudTextSyncSnapshot(
                namespaceKey: namespace.canonicalKey
            )
            let localRecovery = try await local.cloudFullRecoveryEvents(
                namespaceKey: namespace.canonicalKey
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
        _ = try await writer.send(CloudOutboundBatch(operations: [
            .save(CloudFullRecordCodec.snipDraft(remote, accepted: accepted))
        ]))

        let result = try await coordinator.enableOrRetry()
        XCTAssertEqual(result.state, .needsAttention)
        let active = try await persistence.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.first(where: { $0.id == base.id })?.content, "server value")
        XCTAssertEqual(final.snips.first(where: { $0.id != base.id })?.content, "local value")
        XCTAssertEqual(final.snips.count, 2)
        let storage = try await persistence.snapshot()
        let raw = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
        let full = try await raw.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
        XCTAssertEqual(full.conflicts.filter { $0.reference.domainID == base.id }.count, 1)
        let recovery = try await raw.cloudFullRecoveryEvents(namespaceKey: namespace.canonicalKey)
        let link = try XCTUnwrap(recovery.first { $0.kind == .modeRecoveredSnip })
        XCTAssertTrue(String(decoding: link.resultData, as: UTF8.self).contains(base.id.uuidString))
        let pending = try await raw.recoverySnapshot(
            in: SnipRecoveryScope(namespace.canonicalKey)
        )
        let review = try XCTUnwrap(pending.pendingSnips.first)
        XCTAssertEqual(review.currentSnipID, base.id)
        XCTAssertEqual(review.recovered.content, "local value")
        XCTAssertEqual(review.conflictingFields, [.text])

        _ = try await raw.resolveRecovery(
            review.id,
            in: SnipRecoveryScope(namespace.canonicalKey),
            choice: .keepBoth
        )
        let resolved = await raw.snapshot(sortedBy: .manual)
        XCTAssertEqual(resolved.snips.count, 2)
        let resolvedReview = try await raw.recoverySnapshot(
            in: SnipRecoveryScope(namespace.canonicalKey)
        )
        XCTAssertTrue(resolvedReview.pendingSnips.isEmpty)
        XCTAssertEqual(resolvedReview.promotedSnips.first?.currentSnipID, base.id)
        XCTAssertEqual(resolvedReview.promotedSnips.first?.conflictingFields, [.text])
        let resolvedStorage = try await raw.cloudFullStorageSnapshot(
            namespaceKey: namespace.canonicalKey
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
        let recovery = try await raw.cloudFullRecoveryEvents(namespaceKey: namespace.canonicalKey)
        XCTAssertEqual(recovery.filter { $0.kind == .modeRecoveredSnip }.count, 1)
    }

    func testFullReenableIntentReplaysWithoutReceiptAndAdvancesWithReceipt() async throws {
        for point in [
            SyncModeCrashPoint.beforeCandidateMergeDurability,
            .afterCandidateMergeDurability,
        ] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let initialPersistence = try SwiftDataSyncModePersistence(rootURL: root)
            let initialLocal = try await initialPersistence.activeLibrary()
            try await add("base", to: initialLocal)
            let baseSnapshot = await initialLocal.snapshot(sortedBy: .manual)
            let base = try XCTUnwrap(baseSnapshot.snips.first)
            let namespace = makeNamespace()
            let server = FakeCloudServer()
            let first = ICloudSyncModeCoordinator(
                persistence: initialPersistence,
                namespace: namespace,
                textZone: textZone(namespace),
                makeTransport: {
                    FakeCloudRecordTransport(server: server, namespace: namespace)
                }
            )
            _ = try await first.enableOrRetry()
            _ = try await first.optOut(.useCurrentCacheAfterStaleDataWarning)
            let local = try await initialPersistence.activeLibrary()
            let localSnapshot = await local.snapshot(sortedBy: .manual)
            let current = try XCTUnwrap(localSnapshot.snips.first)
            let attachmentURL = root.appendingPathComponent("large-offline.bin")
            let attachmentBytes = Data(repeating: 0xA7, count: 65_536)
            try attachmentBytes.write(to: attachmentURL)
            _ = try await local.perform(
                .update(
                    id: base.id,
                    content: "changed while local",
                    attachmentURLs: [attachmentURL],
                    expectedUpdatedAt: current.updatedAt,
                    now: Date(timeIntervalSince1970: 50)
                ),
                sortedBy: .manual
            )

            let crash = CrashInjector(point: point)
            let crashingPersistence = try SwiftDataSyncModePersistence(
                rootURL: root,
                crashHook: crash.hit
            )
            let crashing = ICloudSyncModeCoordinator(
                persistence: crashingPersistence,
                namespace: namespace,
                textZone: textZone(namespace),
                makeTransport: {
                    FakeCloudRecordTransport(server: server, namespace: namespace)
                }
            )
            do {
                _ = try await crashing.enableOrRetry()
                XCTFail("Expected the merge crash")
            } catch CrashInjector.Failure.injected {}
            let crashed = try await crashingPersistence.snapshot()
            let transition = try XCTUnwrap(crashed.transition)
            XCTAssertEqual(transition.phase, .sourceFrozen)
            let intent = try XCTUnwrap(transition.mergeIntent)
            XCTAssertEqual(intent.fullReenablePlanID, transition.id)
            let manifestData = try Data(contentsOf: root.appendingPathComponent("activation.json"))
            XCTAssertLessThan(manifestData.count, 20_000)
            XCTAssertNil(manifestData.range(of: attachmentBytes.prefix(64)))
            let stagedFiles = try FileManager.default.subpathsOfDirectory(atPath: root.path)
              .filter { $0.contains("full-reenable-v1") }
            XCTAssertTrue(stagedFiles.contains { $0.hasSuffix("plan.json") })
            let stagedAttachment = try XCTUnwrap(stagedFiles.first { $0.hasSuffix(".data") })
            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent(stagedAttachment)),
                attachmentBytes
            )
            let candidate = try await crashingPersistence.libraryForTransition(
                storeID: transition.candidateStoreID
            )
            let receipt = try await candidate.cloudFullReenableReceipt(
                namespaceKey: namespace.canonicalKey,
                transitionID: transition.id
            )
            XCTAssertEqual(receipt == nil, point == .beforeCandidateMergeDurability)
            if let receipt { XCTAssertEqual(receipt, intent.planDigest) }

            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            let resumed = ICloudSyncModeCoordinator(
                persistence: reopened,
                namespace: namespace,
                textZone: textZone(namespace),
                makeTransport: {
                    FakeCloudRecordTransport(server: server, namespace: namespace)
                }
            )
            let result = try await resumed.enableOrRetry()
            XCTAssertEqual(result.state, .on)
            let reopenedLibrary = try await reopened.activeLibrary()
            let final = await reopenedLibrary.snapshot(sortedBy: .manual)
            XCTAssertEqual(final.snips.first(where: { $0.id == base.id })?.content, "changed while local")
            let finalAttachment = try XCTUnwrap(final.snips.first?.attachments.first)
            let finalURL = try XCTUnwrap(final.attachmentURLs[finalAttachment.id])
            XCTAssertEqual(try Data(contentsOf: finalURL), attachmentBytes)
            let finalStorage = try await reopened.snapshot()
            XCTAssertNil(finalStorage.transition)
            XCTAssertFalse(
                try FileManager.default.subpathsOfDirectory(atPath: root.path)
                  .contains { $0.contains("full-reenable-v1") && $0.hasSuffix("plan.json") }
            )
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
                _ = try await candidate.acceptCloudEntity(
                    namespaceKey: namespace.canonicalKey,
                    value: CloudAcceptedEntityInput(
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
                )
            } else {
                let planPath = try XCTUnwrap(
                    FileManager.default.subpathsOfDirectory(atPath: root.path)
                        .first { $0.contains("full-reenable-v1") && $0.hasSuffix("plan.json") }
                )
                try Data("corrupt".utf8).write(to: root.appendingPathComponent(planPath))
            }

            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            do {
                try await reopened.reconcileFullReenableIntent()
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
        let before = await local.snapshot(sortedBy: .manual)
        let base = try XCTUnwrap(before.snips.first)
        _ = try await local.perform(
            .update(
                id: base.id,
                content: "offline edit",
                attachmentURLs: nil,
                expectedUpdatedAt: base.updatedAt,
                now: Date(timeIntervalSince1970: 60)
            ),
            sortedBy: .manual
        )
        let crash = CrashInjector(point: .afterCandidateMergeDurability)
        let crashing = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
        let interrupted = ICloudSyncModeCoordinator(
            persistence: crashing,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        do {
            _ = try await interrupted.enableOrRetry()
            XCTFail("Expected post-apply crash")
        } catch CrashInjector.Failure.injected {}
        let crashed = try await crashing.snapshot()
        let oldCandidateID = try XCTUnwrap(crashed.transition?.candidateStoreID)

        let manifestURL = root.appendingPathComponent("activation.json")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        var transition = try XCTUnwrap(manifest["transition"] as? [String: Any])
        var intent = try XCTUnwrap(transition["mergeIntent"] as? [String: Any])
        intent["planDigest"] = Data(repeating: 0xEE, count: 32).base64EncodedString()
        transition["mergeIntent"] = intent
        manifest["transition"] = transition
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        do {
            try await reopened.reconcileFullReenableIntent()
            XCTFail("Expected receipt digest mismatch")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
        }
        let reset = try await reopened.snapshot()
        XCTAssertNil(reset.transition)
        XCTAssertEqual(reset.attentionReason, .storageFailure)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "stores/iCloudSync-\(oldCandidateID.uuidString.lowercased())"
            ).path
        ))

        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: zone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        let result = try await retry.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let final = try await reopened.activeLibrary().snapshot(sortedBy: .manual)
        XCTAssertEqual(final.snips.first?.content, "offline edit")
    }

    func testFullReenableRemoteDeleteDropsUnchangedSnipWithoutRecovery() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let source = try await persistence.activeLibrary()
        try await add("unchanged", to: source)
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
        let recordID = CloudRecordID.snip(base.id, in: zone)
        let storedValue = await server.fullSnapshot(for: recordID)
        let stored = try XCTUnwrap(storedValue)
        let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
        _ = try await writer.send(CloudOutboundBatch(operations: [
            .delete(recordID, base: stored.shadow)
        ]))

        let result = try await coordinator.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let active = try await persistence.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        XCTAssertTrue(final.snips.isEmpty)
        let storage = try await persistence.snapshot()
        let raw = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
        let recovery = try await raw.cloudFullRecoveryEvents(namespaceKey: namespace.canonicalKey)
        XCTAssertTrue(recovery.isEmpty)
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
        let recovery = try await raw.cloudFullRecoveryEvents(namespaceKey: namespace.canonicalKey)
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
        let result = try await retry.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let active = try await reopened.activeLibrary()
        let final = await active.snapshot(sortedBy: .chronological)
        XCTAssertEqual(Set(final.snips.map(\.id)), Set([edited.id, failed.id]))
        XCTAssertEqual(
            final.snips.map(\.content).sorted(),
            ["edited after hard reopen", "retry full item"]
        )
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(remoteTexts, ["edited after hard reopen", "retry full item"])
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
        let result = firstRetry.state == .settingUp
            ? try await retry.enableOrRetry()
            : firstRetry
        XCTAssertEqual(result.state, .on)
        let active = try await reopened.activeLibrary()
        let final = await active.snapshot(sortedBy: .manual)
        let finalList = try XCTUnwrap(final.lists.first(where: { $0.id == list.id }))
        XCTAssertEqual(finalList.desiredName, "Local rename")
        XCTAssertEqual(finalList.systemImage, "star")
        let finalSnip = try XCTUnwrap(final.snips.first(where: { $0.id == acceptedSnip.id }))
        XCTAssertEqual(finalSnip.content, "remote text")
        XCTAssertTrue(finalSnip.isDone)
        XCTAssertTrue(final.snips.contains(where: { $0.id == failedSnip.id }))
    }

    func testFullPartialFirstSendPromotionCrashReplaysAfterHardReopen() async throws {
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

        let interrupted = try await persistence.snapshot()
        XCTAssertEqual(interrupted.transition?.phase, .firstSendStarted)
        XCTAssertNotNil(interrupted.transition?.sendAttempt)
        let rawSource = try await persistence.libraryForTransition(
            storeID: interrupted.activeStore.id
        )
        let promoted = try await rawSource.dormantCloudBases()
            .filter { $0.namespaceKey == namespace.canonicalKey }
        XCTAssertTrue(promoted.contains(where: {
            $0.reference == CloudEntityReference(kind: .snip, domainID: accepted.id)
        }))
        XCTAssertFalse(promoted.contains(where: {
            $0.reference == CloudEntityReference(kind: .snip, domainID: failed.id)
        }))

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let retry = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: zone,
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            }
        )
        let result = try await retry.enableOrRetry()
        XCTAssertEqual(result.state, .on)
        let completed = try await reopened.snapshot()
        XCTAssertNil(completed.transition)
        let remoteTexts = await server.storedTextValues()
        XCTAssertEqual(remoteTexts, ["accepted before crash", "retry after crash"])
    }

    func testFullRetryBasePromotionIsAtomicAndReplaysTheExactAcceptedSetAfterReopen() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: { point in
                if point == .duringRetryBasePromotionStaging {
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
        let failed = try XCTUnwrap(before.snips.first(where: { $0.content == "failed" }))
        XCTAssertEqual(accepted.count, 2)

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

        let interrupted = try await persistence.snapshot()
        let interruptedSource = try await persistence.libraryForTransition(
            storeID: interrupted.activeStore.id
        )
        let interruptedBases = try await interruptedSource.dormantCloudBases()
            .filter { $0.namespaceKey == namespace.canonicalKey }
        XCTAssertTrue(interruptedBases.isEmpty)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let recovered = try await reopened.snapshot()
        XCTAssertEqual(recovered.transition?.phase, .candidateReady)
        let recoveredSource = try await reopened.libraryForTransition(
            storeID: recovered.activeStore.id
        )
        try await reopened.prepareRetryFetch(
            settlement: SyncModeSeedSettlementProof(
                namespace: ICloudSyncNamespaceBinding(
                    scope: namespace.cloudScope,
                    accountLineage: namespace.accountLineage,
                    generation: namespace.generation,
                    zones: Set(namespace.zones.map {
                        ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
                    })
                ),
                values: [:]
            )
        )
        let promoted = try await recoveredSource.dormantCloudBases()
            .filter { $0.namespaceKey == namespace.canonicalKey }
        let promotedReferences = Set(promoted.map(\.reference))
        XCTAssertEqual(
            promotedReferences,
            Set([
                CloudEntityReference(kind: .list, domainID: SnipList.inboxID),
                CloudEntityReference(kind: .snip, domainID: accepted[0].id),
                CloudEntityReference(kind: .snip, domainID: accepted[1].id),
            ])
        )
        XCTAssertFalse(promotedReferences.contains(.init(kind: .snip, domainID: failed.id)))
    }

    func testTypedModeSendAttemptKeepsListAndSnipWithTheSameDomainID() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        var transition = try await persistence.beginTransition(
            to: .iCloudSync,
            namespace: testBinding()
        )
        try await persistence.recordPreparationComplete()
        let token = try await persistence.freezeSource()
        let source = try await persistence.finalSnapshot(using: token)
        _ = try await persistence.mergeFinalSnapshot(source, using: token)
        let mergedStorage = try await persistence.snapshot()
        transition = try XCTUnwrap(mergedStorage.transition)
        try await persistence.recordEnrollmentApproved(expected: transition.approvedSnipIDs)
        try await persistence.recordFirstSendStarted()
        let domainID = UUID()
        let zone = try XCTUnwrap(testBinding().zones.first)
        let attempt = SyncModeSendAttempt(
            namespace: testBinding(),
            operations: [
                SyncModeSendOperation(
                    reference: CloudEntityReference(kind: .list, domainID: domainID),
                    recordIdentity: CloudTextStorageIdentity(
                        zoneName: zone.name,
                        ownerName: zone.ownerName,
                        recordName: "l-\(domainID.uuidString.lowercased())"
                    ),
                    kind: .save
                ),
                SyncModeSendOperation(
                    reference: CloudEntityReference(kind: .snip, domainID: domainID),
                    recordIdentity: CloudTextStorageIdentity(
                        zoneName: zone.name,
                        ownerName: zone.ownerName,
                        recordName: "s-\(domainID.uuidString.lowercased())"
                    ),
                    kind: .save
                ),
            ]
        )
        try await persistence.recordSendAttempt(attempt)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let reopenedStorage = try await reopened.snapshot()
        let stored = try XCTUnwrap(reopenedStorage.transition)
        XCTAssertEqual(Set(stored.sendAttempt?.operations.compactMap(\.reference) ?? []), Set([
            CloudEntityReference(kind: .list, domainID: domainID),
            CloudEntityReference(kind: .snip, domainID: domainID),
        ]))
        XCTAssertEqual(stored.pendingSettlementSnipIDs, [domainID])
    }

}
