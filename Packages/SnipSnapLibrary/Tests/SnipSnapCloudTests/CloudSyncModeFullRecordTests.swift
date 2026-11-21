import CryptoKit
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
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
        let writerResult = try await writer.enableAndPublish()
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
        let enabled = try await coordinator.enableAndPublish()
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

    func testEnableWithExistingAttachmentPublishesPayloadThenMetadataAfterPointerSwap() async throws {
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

        let result = try await coordinator.enableAndPublish()

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
        let enabled = try await coordinator.enableAndPublish()
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
        let enabled = try await coordinator.enableAndPublish()
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
            _ = try await coordinator.enableAndPublish()
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
        XCTAssertNil(reopenedSnapshot.transition)
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
        XCTAssertEqual(fullBefore.namespaceState.phase, .seeding)

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
        let enabled = try await initial.enableAndPublish()
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

        let firstStatus = try await coordinator.status()
        let secondStatus = try await coordinator.status()
        let afterStatus = try await persistence.snapshot()
        XCTAssertEqual(firstStatus.state, .syncing)
        XCTAssertEqual(secondStatus, firstStatus)
        XCTAssertEqual(afterStatus, beforeStatus)

        await paused.resumeFetch()
        let finished = try await syncing.value
        XCTAssertEqual(finished.state, .on)
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
        let enabled = try await coordinator.enableAndPublish()
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
        let enabled = try await coordinator.enableAndPublish()
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
        let enabled = try await coordinator.enableAndPublish()
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

        let result = try await coordinator.enableAndPublish()

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
        XCTAssertNil(interruptedStorage.transition)

        let completed = try await coordinator.enableAndPublish()

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
            let enabled = try await coordinator.enableAndPublish()
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
        let enabled = try await coordinator.enableAndPublish()
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
        let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
        let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account")
        let zone = descriptor.metadataZone
        let server = FakeCloudServer()
        await server.seedControl(descriptor)
        let sourceID = try await persistence.snapshot().activeStore.id
        let rawSource = try await persistence.libraryForTransition(storeID: sourceID)
        let lifecycle = SnipSnapICloudSyncLifecycle(
            rootURL: root,
            sourceLibrary: rawSource,
            syncModeStore: SnipSyncModeStore(persistence),
            cloudScope: namespace.cloudScope,
            accountLineage: namespace.accountLineage,
            ownerName: "owner",
            controlTransport: FakeCloudControlTransport(server: server),
            makeRecordTransport: { FakeCloudRecordTransport(server: server, namespace: $0.namespace) },
            makeDescriptor: { descriptor }
        )
        _ = try await lifecycle.enableICloudSync()
        _ = try await lifecycle.retrySynchronization()
        try await lifecycle.disableICloudSync(.useCurrentCache)
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

        let enabled = try await lifecycle.enableICloudSync()
        XCTAssertEqual(enabled, .enabled)
        let active = try await lifecycle.activeLibrary()
        let final = try await active.library.checkedSnapshot(sortedBy: .manual)
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
        _ = try await coordinator.enableAndPublish()
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
        _ = try await coordinator.enableAndPublish()
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
        let recovery = try await raw.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
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
        _ = try await coordinator.enableAndPublish()
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

}
