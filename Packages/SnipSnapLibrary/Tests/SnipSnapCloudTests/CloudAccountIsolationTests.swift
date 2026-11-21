import CryptoKit
import SnipSnapCore
import Synchronization
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testKeepLocalCopyIsolationRetainsCloudStoreWhenAttachmentBytesAreUnverified() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cacheRoot = root.appendingPathComponent("AppGroup/Library/Caches/CloudAttachments")
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            attachmentCacheRootURL: cacheRoot
        )
        let sourceURL = root.appendingPathComponent("account-a-attachment.txt")
        let bytes = Data("account A attachment".utf8)
        try bytes.write(to: sourceURL)
        let library = try await persistence.activeLibrary()
        let added = try await library.perform(
            .add(
                content: "account A cache",
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
        let dataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account-a",
            generation: UUID(),
            zones: [dataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: dataZone,
            payloadZone: payloadZone,
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            },
            accountStateSource: account
        )
        let enabled = try await coordinator.enableAndPublish()
        XCTAssertEqual(enabled.state, .on)
        let activeStore = try await persistence.snapshot().activeStore
        let activeLibrary = try await persistence.libraryForTransition(storeID: activeStore.id)
        let beforeDownload = await activeLibrary.snapshot(sortedBy: .manual)
        let durableURL = try XCTUnwrap(beforeDownload.attachmentURLs[attachmentID])
        let cloudState = try await activeLibrary.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        let publication = try XCTUnwrap(cloudState.publications.first)
        let stagingRoot = try await activeLibrary.cloudAttachmentStagingRoot(
            namespaceKey: namespace.namespaceKey
        )
        let staged = stagingRoot.appendingPathComponent("account-isolation/payload")
        try FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try bytes.write(to: staged)
        let cachedURL = try await activeLibrary.installCloudAttachmentDownload(
            namespaceKey: namespace.namespaceKey,
            attachmentID: attachmentID,
            expectedPayloadIdentity: publication.metadata.payloadIdentity,
            expectedField: CloudAttachmentRecordCodec.assetField,
            download: CloudAttachmentCacheDownload(
                payloadIdentity: publication.metadata.payloadIdentity,
                field: CloudAttachmentRecordCodec.assetField,
                fileURL: staged,
                byteCount: Int64(bytes.count),
                sha256: Data(SHA256.hash(data: bytes))
            ),
            maximumBytes: 1_024,
            now: .distantPast
        )
        try await activeLibrary.reconcileCloudAttachments(
            namespaceKey: namespace.namespaceKey,
            metadataZoneName: dataZone.name,
            metadataOwnerName: dataZone.ownerName,
            payloadZoneName: payloadZone.name,
            payloadOwnerName: payloadZone.ownerName
        )
        try FileManager.default.removeItem(at: durableURL)
        let downloads = CloudAttachmentTransferCoordinator(
            library: activeLibrary,
            namespace: namespace,
            payloadZone: payloadZone,
            transport: FakeCloudRecordTransport(server: server, namespace: namespace),
            maximumCacheBytes: 1_024
        )
        await account.setState(.available(accountLineage: "account-b"))
        let isolatedResult = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)
        XCTAssertEqual(isolatedResult.state, .needsAttention)
        let isolatedStorage = try await persistence.snapshot()
        let isolatedStoreID = try XCTUnwrap(isolatedStorage.accountIsolation?.storeID)
        try Data(repeating: 0xA5, count: bytes.count).write(to: cachedURL)
        do {
            _ = try await coordinator.resolveAccountIsolation(.keepLocalCopy)
            XCTFail("Corrupt attachment bytes must stop account-isolation copy")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .attachmentCopyFailed)
        }

        try await downloads.clearDownloads()
        let evicted = await activeLibrary.snapshot(sortedBy: .manual)
        XCTAssertNil(evicted.attachmentURLs[attachmentID])
        do {
            _ = try await coordinator.resolveAccountIsolation(.keepLocalCopy)
            XCTFail("Missing attachment bytes must stop account-isolation copy")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .attachmentCopyFailed)
        }

        let retained = try await persistence.snapshot()
        XCTAssertEqual(retained.accountIsolation?.storeID, isolatedStoreID)
        let retainedLibrary = try await persistence.libraryForTransition(storeID: isolatedStoreID)
        let retainedState = try await retainedLibrary.cloudAttachmentStorageSnapshot(
            namespaceKey: namespace.namespaceKey
        )
        XCTAssertEqual(retainedState.publications.map(\.metadata.attachmentID), [attachmentID])
        let retainedSnapshot = await retainedLibrary.snapshot(sortedBy: .manual)
        XCTAssertEqual(retainedSnapshot.snips.first?.attachments.map(\.id), [attachmentID])

        await account.setState(.available(accountLineage: namespace.accountLineage))
        let resumed = try await coordinator.refreshAccountState()
        XCTAssertEqual(resumed.state, .off)
        let resumedStorage = try await persistence.snapshot()
        XCTAssertNil(resumedStorage.accountIsolation)
        let resumedLibrary = try await persistence.activeLibrary()
        let resumedSnapshot = await resumedLibrary.snapshot(sortedBy: .manual)
        let resumedURL = try XCTUnwrap(resumedSnapshot.attachmentURLs[attachmentID])
        XCTAssertEqual(try Data(contentsOf: resumedURL), bytes)
    }

    func testAccountChangeBeforeStaleCacheOptOutQuarantinesCacheFromNewAccount() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let firstNamespace = makeNamespace()
        let firstAccount = InjectedICloudAccountStateSource(
            state: .available(accountLineage: firstNamespace.accountLineage)
        )
        let firstCoordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: firstNamespace,
            textZone: textZone(firstNamespace),
            makeTransport: {
                FakeCloudRecordTransport(
                    server: FakeCloudServer(),
                    namespace: firstNamespace
                )
            },
            accountStateSource: firstAccount
        )
        _ = try await firstCoordinator.enableAndPublish()
        try await add("account A cache", to: persistence.activeLibrary())

        let secondNamespace = CloudSyncNamespace(
            cloudScope: firstNamespace.cloudScope,
            accountLineage: "account-b",
            generation: UUID(),
            zones: firstNamespace.zones
        )
        await firstAccount.setState(
            .available(accountLineage: secondNamespace.accountLineage)
        )

        let optOut = try await firstCoordinator.optOut(
            .useCurrentCacheAfterStaleDataWarning
        )

        XCTAssertEqual(optOut.state, .needsAttention)
        XCTAssertEqual(optOut.attentionReason, .accountChanged)
        var storage = try await persistence.snapshot()
        XCTAssertEqual(storage.accountIsolation?.namespace, testBinding())
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let hidden = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertTrue(hidden.snips.isEmpty)

        _ = try await firstCoordinator.resolveAccountIsolation(.keepLocalCopy)
        storage = try await persistence.snapshot()
        XCTAssertEqual(storage.activeStore.quarantinedNamespace, testBinding())
        let kept = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertEqual(kept.snips.map(\.content), ["account A cache"])

        let secondServer = FakeCloudServer()
        let secondTransport = FakeCloudRecordTransport(
            server: secondServer,
            namespace: secondNamespace
        )
        let secondAccount = InjectedICloudAccountStateSource(
            state: .available(accountLineage: secondNamespace.accountLineage)
        )
        let secondCoordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: secondNamespace,
            textZone: textZone(secondNamespace),
            makeTransport: { secondTransport },
            accountStateSource: secondAccount
        )

        do {
            _ = try await secondCoordinator.enableOrRetry()
            XCTFail("Account A's stale cache must not enable under account B.")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .namespaceMismatch)
        }
        let secondRemote = await secondServer.storedTextValues()
        XCTAssertTrue(secondRemote.isEmpty)
        let secondEvents = await secondTransport.events()
        XCTAssertFalse(secondEvents.contains { event in
            if case .sent = event { return true }
            return false
        })
    }

    func testAccountChangeBeforeResumedStaleCacheOptOutDiscardsCandidateAndIsolatesSource() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(
                    server: FakeCloudServer(),
                    namespace: namespace
                )
            },
            accountStateSource: account
        )
        _ = try await coordinator.enableOrRetry()
        try await add("account A pending cache", to: persistence.activeLibrary())
        _ = try await persistence.beginTransition(to: .localOnly, namespace: nil)
        await account.setState(.available(accountLineage: "account-b"))

        let result = try await coordinator.optOut(.useCurrentCacheAfterStaleDataWarning)

        XCTAssertEqual(result.state, .needsAttention)
        XCTAssertEqual(result.attentionReason, .accountChanged)
        let storage = try await persistence.snapshot()
        XCTAssertNil(storage.transition)
        XCTAssertEqual(storage.accountIsolation?.namespace, testBinding())
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let visible = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertTrue(visible.snips.isEmpty)
        let isolation = try XCTUnwrap(storage.accountIsolation)
        let isolated = try await persistence.libraryForTransition(storeID: isolation.storeID)
            .snapshot(sortedBy: .chronological)
        XCTAssertEqual(isolated.snips.map(\.content), ["account A pending cache"])
    }

    func testAccountChangeDuringEnableFetchNeverAppliesForeignRowsOrSends() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        try await add("local only", to: persistence.activeLibrary())
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        try await seed(
            "foreign remote",
            id: CloudRecordID(zone: textZone(namespace), name: UUID().uuidString),
            server: server
        )
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.pauseNextFetch()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport },
            accountStateSource: account
        )

        let enable = Task { try await coordinator.enableOrRetry() }
        await transport.waitUntilFetchPauses()
        await account.setState(.available(accountLineage: "other-account"))
        await transport.resumeFetch()
        let result = try await enable.value

        XCTAssertEqual(result.state, .needsAttention)
        XCTAssertEqual(result.attentionReason, .accountChanged)
        let storage = try await persistence.snapshot()
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let active = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertEqual(active.snips.map(\.content), ["local only"])
        XCTAssertNil(storage.transition)
        XCTAssertEqual(try storeRootCount(in: root), 1)
        let sent = await transport.events().contains { event in
            if case .sent = event { return true }
            return false
        }
        XCTAssertFalse(sent)
    }

    func testAccountChangeDuringOptOutFetchNeverCopiesForeignRowsOrSends() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        try await add("first account cache", to: persistence.activeLibrary())
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport },
            accountStateSource: account
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        try await seed(
            "foreign remote",
            id: CloudRecordID(zone: textZone(namespace), name: UUID().uuidString),
            server: server
        )
        let eventCountBeforeOptOut = await transport.events().count
        await transport.pauseNextFetch()

        let optOut = Task { try await coordinator.optOut(.refreshThenCopy) }
        await transport.waitUntilFetchPauses()
        await account.setState(.available(accountLineage: "other-account"))
        await transport.resumeFetch()
        let result = try await optOut.value

        XCTAssertEqual(result.state, .needsAttention)
        XCTAssertEqual(result.attentionReason, .accountChanged)
        let storage = try await persistence.snapshot()
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        XCTAssertNil(storage.transition)
        let visible = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertTrue(visible.snips.isEmpty)
        let isolation = try XCTUnwrap(storage.accountIsolation)
        let isolated = try await persistence.libraryForTransition(storeID: isolation.storeID)
            .snapshot(sortedBy: .chronological)
        XCTAssertEqual(isolated.snips.map(\.content), ["first account cache"])
        XCTAssertFalse(isolated.snips.contains { $0.content == "foreign remote" })
        let optOutEvents = Array((await transport.events()).dropFirst(eventCountBeforeOptOut))
        XCTAssertFalse(optOutEvents.contains { event in
            if case .sent = event { return true }
            return false
        })
    }

    func testAccountHandlerRunsTheInjectedCollectionCheckedSyncAction() async throws {
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
            },
            accountStateSource: InjectedICloudAccountStateSource(
                state: .available(accountLineage: namespace.accountLineage)
            )
        )
        let calls = SyncActionCallCount()
        let handler = AppleAccountCacheCoordinatorHandler(
            coordinator: coordinator,
            syncWhenPossible: { await calls.record() }
        )

        await handler.syncWhenPossible()

        let callCount = await calls.value()
        XCTAssertEqual(callCount, 1)
    }

    /// Without an injected action, the handler syncs through the coordinator itself, so that
    /// sync waits for a mode operation holding the shared gate.
    func testAccountHandlerFallbackSyncWaitsForTheOperationGate() async throws {
        let gate = AsyncOperationGate()
        let fallbackStarts = SyncActionCallCount()
        let unusedURL = FileManager.default.temporaryDirectory
        let handler = AppleAccountCacheCoordinatorHandler(
            persistence: {
                await fallbackStarts.record()
                return nil
            },
            controlTransport: FakeCloudControlTransport(server: FakeCloudServer()),
            accountStateSource: InjectedICloudAccountStateSource(state: .noAccount),
            makeSyncCoordinator: { persistence, namespace, descriptor in
                makeInjectedSyncCoordinator(
                    persistence: persistence,
                    namespace: namespace,
                    descriptor: descriptor
                )
            },
            makeAttachmentCoordinator: { _, _, _ in
                AttachmentTransferProbe(preparedURL: unusedURL)
            },
            operationGate: gate
        )
        let lease = HeldLease()
        let modeOperation = Task { try await gate.withLease { await lease.hold() } }
        await lease.waitUntilHeld()

        let syncWaits = expectation(description: "The fallback sync waits for the lease")
        syncWaits.isInverted = true
        let sync = Task {
            await handler.syncWhenPossible()
            syncWaits.fulfill()
        }
        await fulfillment(of: [syncWaits], timeout: 0.05)
        let startsWhileHeld = await fallbackStarts.value()
        await lease.release()

        try await modeOperation.value
        await sync.value
        let startsAfterRelease = await fallbackStarts.value()
        // Before the SM23-F1 fix, the fallback runs while the lease is held.
        XCTAssertEqual(startsWhileHeld, 0)
        XCTAssertEqual(startsAfterRelease, 1)
    }

    func testGeneratedCollectionRolesDriveEveryAttachmentActionWithoutZoneGuessing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let ownerName = CloudCollectionAssembly.productionControlID.zone.ownerName
        let generated = CloudCollectionDescriptor.fresh(ownerName: ownerName)
        let namespace = generated.namespace(cloudScope: "private", accountLineage: "account-a")
        let binding = ICloudSyncNamespaceBinding(
            scope: namespace.cloudScope,
            accountLineage: namespace.accountLineage,
            generation: namespace.generation,
            zones: Set(namespace.zones.map {
                ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
            })
        )
        let resolved = try AppleAccountCacheCoordinatorHandler.validatedDescriptor(
            CloudCollectionControlRecord(descriptor: generated, version: Data("1".utf8)),
            matching: binding,
            ownerName: ownerName,
            reservedZones: []
        )
        XCTAssertEqual(resolved.metadataZone, generated.metadataZone)
        XCTAssertEqual(resolved.payloadZone, generated.payloadZone)
        XCTAssertTrue(resolved.metadataZone.name.hasPrefix("snips-"))
        XCTAssertTrue(resolved.payloadZone.name.hasPrefix("payloads-"))

        let stale = CloudCollectionDescriptor.fresh(ownerName: ownerName)
        XCTAssertThrowsError(
            try AppleAccountCacheCoordinatorHandler.validatedDescriptor(
                CloudCollectionControlRecord(descriptor: stale, version: Data("2".utf8)),
                matching: binding,
                ownerName: ownerName,
                reservedZones: []
            )
        )

        try await persistence.activateEmptyCollection(namespace: binding)
        let control = FakeCloudControlTransport(server: FakeCloudServer())
        await control.seedControl(generated)
        let preparedURL = root.appendingPathComponent("prepared.bin")
        let probe = AttachmentTransferProbe(preparedURL: preparedURL)
        let handler = AppleAccountCacheCoordinatorHandler(
            persistence: { persistence },
            controlTransport: control,
            accountStateSource: FixedICloudAccountStateSource(state: .available(accountLineage: "account-a")),
            makeSyncCoordinator: { persistence, resolvedNamespace, descriptor in
                makeInjectedSyncCoordinator(
                    persistence: persistence,
                    namespace: resolvedNamespace,
                    descriptor: descriptor
                )
            },
            makeAttachmentCoordinator: { _, resolvedNamespace, descriptor in
                await probe.recordConfiguration(
                    namespace: resolvedNamespace,
                    payloadZone: descriptor.payloadZone
                )
                return probe
            }
        )
        let attachmentID = UUID()

        for use in [
            SyncedAttachmentUse.preview, .open, .copy, .export,
        ] {
            let result = try await handler.prepareSyncedAttachment(attachmentID, for: use)
            XCTAssertEqual(result, preparedURL)
        }
        try await handler.clearDownloadedFiles()

        let uses = await probe.uses()
        let clearCount = await probe.clearCount()
        let configuration = await probe.configuration()
        XCTAssertEqual(uses, [.preview, .open, .copy, .export])
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(configuration?.namespace, namespace)
        XCTAssertEqual(configuration?.payloadZone, generated.payloadZone)
    }

    func testAttachmentGenerationRefreshDoesNotKeepOlderAccountCoordinator() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let ownerName = CloudCollectionAssembly.productionControlID.zone.ownerName
        let first = CloudCollectionDescriptor.fresh(ownerName: ownerName)
        let second = CloudCollectionDescriptor.fresh(ownerName: ownerName)
        let firstNamespace = first.namespace(cloudScope: "private", accountLineage: "account-a")
        let secondNamespace = second.namespace(cloudScope: "private", accountLineage: "account-a")
        let firstBinding = ICloudSyncNamespaceBinding(
            scope: firstNamespace.cloudScope,
            accountLineage: firstNamespace.accountLineage,
            generation: firstNamespace.generation,
            zones: Set(firstNamespace.zones.map {
                ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
            })
        )
        let secondBinding = ICloudSyncNamespaceBinding(
            scope: secondNamespace.cloudScope,
            accountLineage: secondNamespace.accountLineage,
            generation: secondNamespace.generation,
            zones: Set(secondNamespace.zones.map {
                ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
            })
        )
        try await persistence.activateEmptyCollection(namespace: firstBinding)
        let control = FakeCloudControlTransport(server: FakeCloudServer())
        await control.seedControl(first)
        let syncProbe = SyncCoordinatorConstructionProbe()
        let attachmentProbe = AttachmentTransferProbe(
            preparedURL: root.appendingPathComponent("prepared.bin")
        )
        let handler = AppleAccountCacheCoordinatorHandler(
            persistence: { persistence },
            controlTransport: control,
            accountStateSource: FixedICloudAccountStateSource(state: .available(accountLineage: "account-a")),
            makeSyncCoordinator: { persistence, namespace, descriptor in
                await syncProbe.record(namespace.generation)
                return makeInjectedSyncCoordinator(
                    persistence: persistence,
                    namespace: namespace,
                    descriptor: descriptor
                )
            },
            makeAttachmentCoordinator: { _, namespace, descriptor in
                await attachmentProbe.recordConfiguration(
                    namespace: namespace,
                    payloadZone: descriptor.payloadZone
                )
                return attachmentProbe
            }
        )

        let firstNotice = try await handler.refreshAppleAccountNotice()
        XCTAssertNil(firstNotice)
        let firstCreatedGenerations = await syncProbe.generations()
        XCTAssertEqual(firstCreatedGenerations, [first.generation])

        try await persistence.activateEmptyCollection(namespace: secondBinding)
        await control.seedControl(second)
        _ = try await handler.prepareSyncedAttachment(UUID(), for: .preview)
        let attachmentGeneration = await attachmentProbe.configuration()?.namespace.generation
        XCTAssertEqual(attachmentGeneration, second.generation)

        let secondNotice = try await handler.refreshAppleAccountNotice()
        XCTAssertNil(secondNotice)
        let finalCreatedGenerations = await syncProbe.generations()
        XCTAssertEqual(finalCreatedGenerations, [first.generation, second.generation])
    }

    func testResolvedIsolationRebuildsTheSyncCoordinatorForTheNextStore() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let ownerName = CloudCollectionAssembly.productionControlID.zone.ownerName
        let descriptor = CloudCollectionDescriptor.fresh(ownerName: ownerName)
        let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account-a")
        let binding = ICloudSyncNamespaceBinding(
            scope: namespace.cloudScope,
            accountLineage: namespace.accountLineage,
            generation: namespace.generation,
            zones: Set(namespace.zones.map {
                ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
            })
        )
        try await persistence.activateEmptyCollection(namespace: binding)
        let control = FakeCloudControlTransport(server: FakeCloudServer())
        await control.seedControl(descriptor)
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let syncProbe = SyncCoordinatorConstructionProbe()
        let handler = AppleAccountCacheCoordinatorHandler(
            persistence: { persistence },
            controlTransport: control,
            accountStateSource: account,
            makeSyncCoordinator: { persistence, resolvedNamespace, resolvedDescriptor in
                await syncProbe.record(resolvedNamespace.generation)
                return makeInjectedSyncCoordinator(
                    persistence: persistence,
                    namespace: resolvedNamespace,
                    descriptor: resolvedDescriptor
                )
            },
            makeAttachmentCoordinator: { _, _, _ in
                AttachmentTransferProbe(preparedURL: root.appendingPathComponent("unused"))
            }
        )

        let firstNotice = try await handler.refreshAppleAccountNotice()
        XCTAssertNil(firstNotice)
        await account.setState(.noAccount)
        let signedOutNotice = try await handler.refreshAppleAccountNotice()
        XCTAssertEqual(signedOutNotice, .signedOut)
        try await handler.resolveAppleAccountCache(.remove)
        let resolvedGenerations = await syncProbe.generations()
        XCTAssertEqual(resolvedGenerations, [descriptor.generation])

        await account.setState(.available(accountLineage: namespace.accountLineage))
        try await persistence.activateEmptyCollection(namespace: binding)
        let returnedNotice = try await handler.refreshAppleAccountNotice()
        XCTAssertNil(returnedNotice)
        let finalGenerations = await syncProbe.generations()
        XCTAssertEqual(
            finalGenerations,
            [descriptor.generation, descriptor.generation],
            "The next iCloud store needs its own sync coordinator."
        )
    }

    func testTemporaryAccountFailurePausesWithoutReclassifyingTheCache() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) },
            accountStateSource: account
        )
        let enabled = try await coordinator.enableOrRetry()
        XCTAssertEqual(enabled.state, .on)
        let library = try await persistence.activeLibrary()
        try await add("kept cache", to: library)
        let before = try await persistence.snapshot()

        await account.setState(.temporarilyUnavailable)
        let paused = try await coordinator.refreshAccountState()
        let after = try await persistence.snapshot()

        XCTAssertEqual(paused.state, .needsAttention)
        XCTAssertEqual(paused.attentionReason, .accountTemporarilyUnavailable)
        XCTAssertEqual(after.activeStore.id, before.activeStore.id)
        XCTAssertEqual(after.activeStore.kind, .iCloudSync)
        XCTAssertNil(after.accountIsolation)
        let activeLibrary = try await persistence.activeLibrary()
        let activeSnapshot = await activeLibrary.snapshot(sortedBy: .chronological)
        XCTAssertEqual(activeSnapshot.snips.map(\.content), ["kept cache"])

        let remoteBefore = await server.storedTextValues()
        let syncResult = try await coordinator.syncActive()
        XCTAssertEqual(syncResult.attentionReason, .accountTemporarilyUnavailable)
        let remoteAfter = await server.storedTextValues()
        XCTAssertEqual(remoteAfter, remoteBefore)
    }

    func testSignOutAtomicallyIsolatesThePriorCacheAndStopsSends() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) },
            accountStateSource: account
        )
        _ = try await coordinator.enableAndPublish()
        let cloudLibrary = try await persistence.activeLibrary()
        try await add("pending for first account", to: cloudLibrary)
        let before = try await persistence.snapshot()

        await account.setState(.noAccount)
        let signedOut = try await coordinator.refreshAccountState()
        let isolated = try await persistence.snapshot()

        XCTAssertEqual(signedOut.state, .needsAttention)
        XCTAssertEqual(signedOut.attentionReason, .accountSignedOut)
        XCTAssertEqual(isolated.activeStore.kind, .localOnly)
        XCTAssertNotEqual(isolated.activeStore.id, before.activeStore.id)
        XCTAssertEqual(isolated.accountIsolation?.storeID, before.activeStore.id)
        XCTAssertEqual(isolated.accountIsolation?.reason, .signedOut)
        let activeLibrary = try await persistence.activeLibrary()
        let visible = await activeLibrary.snapshot(sortedBy: .chronological)
        XCTAssertTrue(visible.snips.isEmpty)
        let remote = await server.storedTextValues()
        XCTAssertFalse(remote.contains("pending for first account"))

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let reopenedState = try await reopened.snapshot()
        XCTAssertEqual(reopenedState.activeStore.id, isolated.activeStore.id)
        XCTAssertEqual(reopenedState.accountIsolation, isolated.accountIsolation)
        let reopenedLibrary = try await reopened.activeLibrary()
        let reopenedVisible = await reopenedLibrary.snapshot(sortedBy: .chronological)
        XCTAssertTrue(reopenedVisible.snips.isEmpty)
    }

    func testKeepLocalCopyCombinesIsolatedAndNewLocalWorkWithoutCloudState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appendingPathComponent("AttachmentCaches", isDirectory: true)
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            attachmentCacheRootURL: cacheRoot
        )
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) },
            accountStateSource: account
        )
        _ = try await coordinator.enableAndPublish()
        try await add("isolated work", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()
        let isolatedStorage = try await persistence.snapshot()
        let isolatedStoreID = try XCTUnwrap(isolatedStorage.accountIsolation?.storeID)
        let isolatedCacheRoot = try XCTUnwrap(
            SwiftDataSyncModePersistence.cacheRootURL(
                base: cacheRoot,
                storeID: isolatedStoreID
            )
        )
        try FileManager.default.createDirectory(
            at: isolatedCacheRoot,
            withIntermediateDirectories: true
        )
        try Data("cached bytes".utf8).write(
            to: isolatedCacheRoot.appendingPathComponent("payload")
        )
        try await add("new local work", to: persistence.activeLibrary())

        let kept = try await coordinator.resolveAccountIsolation(.keepLocalCopy)
        XCTAssertEqual(kept.state, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolatedCacheRoot.path))
        let storage = try await persistence.snapshot()
        XCTAssertNil(storage.accountIsolation)
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        XCTAssertEqual(storage.activeStore.quarantinedNamespace, testBinding())
        let keptLibrary = try await persistence.activeLibrary()
        let visible = await keptLibrary.snapshot(sortedBy: .chronological)
        XCTAssertEqual(Set(visible.snips.map(\.content)), ["isolated work", "new local work"])
        let remote = await server.storedTextValues()
        XCTAssertFalse(remote.contains("isolated work"))

        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let reopenedStorage = try await reopened.snapshot()
        XCTAssertNil(reopenedStorage.accountIsolation)
        XCTAssertEqual(reopenedStorage.activeStore.quarantinedNamespace, testBinding())
        let reopenedLibrary = try await reopened.activeLibrary()
        let reopenedVisible = await reopenedLibrary.snapshot(sortedBy: .chronological)
        XCTAssertEqual(Set(reopenedVisible.snips.map(\.content)), Set(visible.snips.map(\.content)))
    }

    func testKeptAccountCacheCannotEnableUnderAnotherAccountOrGeneration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let firstNamespace = makeNamespace()
        let firstAccount = InjectedICloudAccountStateSource(
            state: .available(accountLineage: firstNamespace.accountLineage)
        )
        let firstCoordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: firstNamespace,
            textZone: textZone(firstNamespace),
            makeTransport: {
                FakeCloudRecordTransport(
                    server: FakeCloudServer(),
                    namespace: firstNamespace
                )
            },
            accountStateSource: firstAccount
        )
        _ = try await firstCoordinator.enableOrRetry()
        try await add("first account only", to: persistence.activeLibrary())
        await firstAccount.setState(.noAccount)
        _ = try await firstCoordinator.refreshAccountState()
        _ = try await firstCoordinator.resolveAccountIsolation(.keepLocalCopy)

        let changedAccountNamespace = CloudSyncNamespace(
            cloudScope: firstNamespace.cloudScope,
            accountLineage: "other-account",
            generation: UUID(),
            zones: firstNamespace.zones
        )
        let changedGenerationNamespace = CloudSyncNamespace(
            cloudScope: firstNamespace.cloudScope,
            accountLineage: firstNamespace.accountLineage,
            generation: UUID(),
            zones: firstNamespace.zones
        )
        for blockedNamespace in [changedAccountNamespace, changedGenerationNamespace] {
            let server = FakeCloudServer()
            let account = InjectedICloudAccountStateSource(
                state: .available(accountLineage: blockedNamespace.accountLineage)
            )
            let coordinator = ICloudSyncModeCoordinator(
                persistence: persistence,
                namespace: blockedNamespace,
                textZone: textZone(blockedNamespace),
                makeTransport: {
                    FakeCloudRecordTransport(server: server, namespace: blockedNamespace)
                },
                accountStateSource: account
            )

            do {
                _ = try await coordinator.enableOrRetry()
                XCTFail("A kept account cache must not cross its saved namespace.")
            } catch {
                XCTAssertEqual(error as? SyncModePersistenceError, .namespaceMismatch)
            }
            let remote = await server.storedTextValues()
            XCTAssertTrue(remote.isEmpty)
            let storage = try await persistence.snapshot()
            XCTAssertEqual(storage.activeStore.kind, .localOnly)
            XCTAssertEqual(storage.activeStore.quarantinedNamespace, testBinding())
        }
    }

    func testKeptAccountCacheCanReturnThroughRemoteFirstFlowForExactNamespace() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let firstServer = FakeCloudServer()
        let firstCoordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: firstServer, namespace: namespace)
            },
            accountStateSource: account
        )
        _ = try await firstCoordinator.enableAndPublish()
        try await add("kept for export or return", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await firstCoordinator.refreshAccountState()
        _ = try await firstCoordinator.resolveAccountIsolation(.keepLocalCopy)

        await account.setState(.available(accountLineage: namespace.accountLineage))
        let returnServer = FakeCloudServer()
        let transport = FakeCloudRecordTransport(server: returnServer, namespace: namespace)
        let returnCoordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport },
            accountStateSource: account
        )

        let enabled = try await returnCoordinator.enableAndPublish()

        XCTAssertEqual(enabled.state, .on)
        let remote = await returnServer.storedTextValues()
        XCTAssertEqual(remote, ["kept for export or return"])
        let events = await transport.events()
        let fetchIndex = try XCTUnwrap(events.firstIndex(of: .fetched))
        let sendIndex = try XCTUnwrap(events.firstIndex(where: {
            if case .sent = $0 { return true }
            return false
        }))
        XCTAssertLessThan(fetchIndex, sendIndex)
        let storage = try await persistence.snapshot()
        XCTAssertNil(storage.activeStore.quarantinedNamespace)
    }

    func testRemoveDeletesOnlyTheValidatedIsolatedRoot() async throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("mode", isDirectory: true)
        let sentinel = parent.appendingPathComponent("keep.data")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: sentinel)
        let cacheRoot = parent.appendingPathComponent("AttachmentCaches", isDirectory: true)
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            attachmentCacheRootURL: cacheRoot
        )
        let namespace = makeNamespace()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
            },
            accountStateSource: account
        )
        _ = try await coordinator.enableOrRetry()
        try await add("remove me", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()
        let isolatedStorage = try await persistence.snapshot()
        let isolatedStoreID = try XCTUnwrap(isolatedStorage.accountIsolation?.storeID)
        let isolatedCacheRoot = try XCTUnwrap(
            SwiftDataSyncModePersistence.cacheRootURL(
                base: cacheRoot,
                storeID: isolatedStoreID
            )
        )
        try FileManager.default.createDirectory(
            at: isolatedCacheRoot,
            withIntermediateDirectories: true
        )
        try Data("cached bytes".utf8).write(
            to: isolatedCacheRoot.appendingPathComponent("payload")
        )
        try await add("keep local", to: persistence.activeLibrary())

        let removed = try await coordinator.resolveAccountIsolation(.remove)
        XCTAssertEqual(removed.state, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolatedCacheRoot.path))
        let removedStorage = try await persistence.snapshot()
        XCTAssertNil(removedStorage.accountIsolation)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        let localLibrary = try await persistence.activeLibrary()
        let visible = await localLibrary.snapshot(sortedBy: .chronological)
        XCTAssertEqual(visible.snips.map(\.content), ["keep local"])
        XCTAssertEqual(try storeRootCount(in: root), 1)
    }

    func testSameAccountReturnFinishesInterruptedActivationAndSchedulesNormalSync() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let interrupt = Mutex(false)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, crashHook: { point in
            if point == .afterPointerSwap, interrupt.withLock({ armed in
                defer { armed = false }
                return armed
            }) {
                throw CrashInjector.Failure.injected
            }
        })
        let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
        let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account")
        let server = FakeCloudServer()
        await server.seedControl(descriptor)
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        let account = InjectedICloudAccountStateSource(state: .available(accountLineage: namespace.accountLineage))
        let initial = try await persistence.snapshot()
        let source = try await persistence.libraryForTransition(storeID: initial.activeStore.id)
        let lifecycle = SnipSnapICloudSyncLifecycle(
            rootURL: root, sourceLibrary: source,
            syncModeStore: SnipSyncModeStore(persistence),
            cloudScope: namespace.cloudScope, accountLineage: namespace.accountLineage,
            accountStateSource: account, ownerName: "owner",
            controlTransport: FakeCloudControlTransport(server: server),
            makeRecordTransport: { _ in transport }, makeDescriptor: { descriptor }
        )
        _ = try await lifecycle.enableICloudSync()
        _ = try await lifecycle.retrySynchronization()
        let appGate = AsyncOperationGate()
        let scheduled = expectation(description: "The normal scheduler publishes accepted account-return work")
        let session = SnipSnapCloudSyncSession(
            synchronize: { try await lifecycle.synchronize() },
            scheduleAutomaticSync: {
                let active = try await persistence.snapshot()
                XCTAssertEqual(active.activeStore.kind, .iCloudSync)
                XCTAssertNil(active.transition)
                let before = await server.storedTextValues()
                XCTAssertTrue(before.isEmpty)
                try await lifecycle.scheduleAutomaticSync()
                scheduled.fulfill()
            },
            enable: { try await lifecycle.enableICloudSync() },
            delete: { try await lifecycle.deleteSyncedContent() },
            activeLibrary: { try await lifecycle.activeLibrary() },
            operationGate: appGate
        )
        let handler = lifecycle.makeAccountCacheHandler(
            operationGate: appGate,
            scheduleSyncAfterLocalChange: { await session.scheduleAutomaticSync() }
        )
        try await add("pending before sign-out", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        let signedOut = try await handler.refreshAppleAccountNotice()
        XCTAssertEqual(signedOut, .signedOut)
        try await add("made while signed out", to: persistence.activeLibrary())
        await account.setState(.available(accountLineage: namespace.accountLineage))

        interrupt.withLock { $0 = true }
        do {
            _ = try await handler.refreshAppleAccountNotice()
            XCTFail("Expected an interruption after the account-return swap")
        } catch CrashInjector.Failure.injected {}
        let interrupted = try await persistence.snapshot()
        XCTAssertEqual(interrupted.activeStore.kind, .iCloudSync)
        XCTAssertEqual(interrupted.transition?.phase, .swapped)

        let returned = try await handler.refreshAppleAccountNotice()
        XCTAssertNil(returned)
        await fulfillment(of: [scheduled], timeout: 5)
        let active = try await persistence.snapshot()
        XCTAssertNil(active.accountIsolation)
        let remote = await server.storedTextValues()
        XCTAssertEqual(Set(remote), ["pending before sign-out", "made while signed out"])
    }

    func testSignOutCanIsolateAnInterruptedCloudActivation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let crash = CrashInjector(point: .afterPointerSwap)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence, namespace: namespace, textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }
        )
        try await add("keep after sign-out", to: persistence.activeLibrary())
        do {
            _ = try await coordinator.enableOrRetry()
            XCTFail("Expected an interruption after the swap")
        } catch CrashInjector.Failure.injected {}

        let published = try await persistence.snapshot()
        let isolation = try await persistence.isolateActiveCloudStore(reason: .signedOut)
        let isolated = try await persistence.snapshot()
        XCTAssertEqual(isolation.storeID, published.activeStore.id)
        XCTAssertEqual(isolated.activeStore.kind, .localOnly)
        XCTAssertNil(isolated.transition)
        XCTAssertEqual(isolated.accountIsolation?.id, isolation.id)
        let cache = try await persistence.libraryForTransition(storeID: isolation.storeID)
        let stored = try await cache.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(stored.snips.map(\.content), ["keep after sign-out"])
    }

    func testChangedAccountNeverDisplaysOrUploadsThePriorAccountCache() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let firstNamespace = makeNamespace()
        let firstServer = FakeCloudServer()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: firstNamespace.accountLineage)
        )
        let firstCoordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: firstNamespace,
            textZone: textZone(firstNamespace),
            makeTransport: {
                FakeCloudRecordTransport(server: firstServer, namespace: firstNamespace)
            },
            accountStateSource: account
        )
        _ = try await firstCoordinator.enableAndPublish()
        try await add("first account only", to: persistence.activeLibrary())

        let secondNamespace = CloudSyncNamespace(
            cloudScope: firstNamespace.cloudScope,
            accountLineage: "second-account",
            generation: UUID(),
            zones: firstNamespace.zones
        )
        await account.setState(.available(accountLineage: secondNamespace.accountLineage))
        let changed = try await firstCoordinator.refreshAccountState()
        XCTAssertEqual(changed.attentionReason, .accountChanged)
        let hidden = await (try persistence.activeLibrary()).snapshot(sortedBy: .chronological)
        XCTAssertTrue(hidden.snips.isEmpty)

        _ = try await firstCoordinator.resolveAccountIsolation(.remove)
        try await add("second account work", to: persistence.activeLibrary())
        let secondServer = FakeCloudServer()
        let secondCoordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: secondNamespace,
            textZone: textZone(secondNamespace),
            makeTransport: {
                FakeCloudRecordTransport(server: secondServer, namespace: secondNamespace)
            },
            accountStateSource: account
        )

        let enabled = try await secondCoordinator.enableAndPublish()
        XCTAssertEqual(enabled.state, .on)
        let secondRemote = await secondServer.storedTextValues()
        XCTAssertEqual(secondRemote, ["second account work"])
        XCTAssertFalse(secondRemote.contains("first account only"))
        let visible = await (try persistence.activeLibrary()).snapshot(sortedBy: .chronological)
        XCTAssertEqual(visible.snips.map(\.content), ["second account work"])
    }

    func testIsolationCrashPointsReplayToAHiddenDurableCache() async throws {
        let points: [SyncModeCrashPoint] = [
            .afterAccountIsolationManifest,
            .beforeAccountIsolationDurability,
            .afterAccountIsolationDurability,
            .beforeAccountIsolationPointerSwap,
            .afterAccountIsolationPointerSwap,
        ]
        for point in points {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let crash = CrashInjector(point: point)
            let persistence = try SwiftDataSyncModePersistence(
                rootURL: root,
                crashHook: crash.hit
            )
            let namespace = makeNamespace()
            let account = InjectedICloudAccountStateSource(
                state: .available(accountLineage: namespace.accountLineage)
            )
            let coordinator = ICloudSyncModeCoordinator(
                persistence: persistence,
                namespace: namespace,
                textZone: textZone(namespace),
                makeTransport: {
                    FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
                },
                accountStateSource: account
            )
            _ = try await coordinator.enableOrRetry()
            try await add("hidden after crash", to: persistence.activeLibrary())
            await account.setState(.noAccount)
            do {
                _ = try await coordinator.refreshAccountState()
                XCTFail("Expected crash at \(point)")
            } catch is CrashInjector.Failure {}

            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            let storage = try await reopened.snapshot()
            XCTAssertEqual(storage.activeStore.kind, .localOnly, "point: \(point)")
            XCTAssertNotNil(storage.accountIsolation, "point: \(point)")
            let library = try await reopened.activeLibrary()
            let visible = await library.snapshot(sortedBy: .chronological)
            XCTAssertTrue(visible.snips.isEmpty, "point: \(point)")
        }
    }

    func testFailedIsolationSwapFinishesOnTheNextAccountRefresh() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let swapFault = AccountIsolationSwapFault()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            manifestWriter: swapFault.write,
            writeHook: swapFault.arm
        )
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) },
            accountStateSource: account
        )
        _ = try await coordinator.enableOrRetry()
        try await add("prior account work", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        swapFault.failNextSwap()
        do {
            _ = try await coordinator.refreshAccountState()
            XCTFail("The full disk must fail the isolation's pointer swap")
        } catch SyncModePersistenceError.storageFailure {}

        let signedOut = try await coordinator.refreshAccountState()
        XCTAssertEqual(signedOut.state, .needsAttention)
        XCTAssertEqual(signedOut.attentionReason, .accountSignedOut)
        let isolated = try await persistence.snapshot()
        XCTAssertEqual(isolated.activeStore.kind, .localOnly)
        XCTAssertNotNil(isolated.accountIsolation)
        let hidden = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertTrue(hidden.snips.isEmpty, "The prior account's work must stay hidden")

        let kept = try await coordinator.resolveAccountIsolation(.keepLocalCopy)
        XCTAssertEqual(kept.state, .off)
        let storage = try await persistence.snapshot()
        XCTAssertNil(storage.accountIsolation)
        let visible = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertEqual(visible.snips.map(\.content), ["prior account work"])
    }

    func testStatusStillReportsAnIsolationWhoseSwapKeepsFailing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let swapFault = AccountIsolationSwapFault()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            manifestWriter: swapFault.write,
            writeHook: swapFault.arm
        )
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) },
            accountStateSource: account
        )
        _ = try await coordinator.enableOrRetry()
        try await add("prior account work", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        swapFault.failNextSwap()
        do {
            _ = try await coordinator.refreshAccountState()
            XCTFail("The full disk must fail the isolation's pointer swap")
        } catch SyncModePersistenceError.storageFailure {}

        swapFault.failNextSwap()
        do {
            let status = try await coordinator.status()
            XCTAssertEqual(status.state, .needsAttention)
            XCTAssertEqual(status.attentionReason, .accountSignedOut)
        } catch {
            XCTFail("Status must still report an isolation whose swap fails again: \(error)")
        }
        let declared = try await persistence.snapshot()
        XCTAssertEqual(declared.activeStore.kind, .iCloudSync)

        swapFault.failNextSwap()
        do {
            _ = try await coordinator.resolveAccountIsolation(.keepLocalCopy)
            XCTFail("Keep Local Copy must report the failed swap")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
        }

        let finished = try await coordinator.refreshAccountState()
        XCTAssertEqual(finished.state, .needsAttention)
        XCTAssertEqual(finished.attentionReason, .accountSignedOut)
        let isolated = try await persistence.snapshot()
        XCTAssertEqual(isolated.accountIsolation?.resolution, .undecided)
        XCTAssertEqual(isolated.activeStore.kind, .localOnly)
        let hidden = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertTrue(hidden.snips.isEmpty, "The prior account's work must stay hidden")

        let kept = try await coordinator.resolveAccountIsolation(.keepLocalCopy)
        XCTAssertEqual(kept.state, .off)
        let storage = try await persistence.snapshot()
        XCTAssertNil(storage.accountIsolation)
        let visible = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertEqual(visible.snips.map(\.content), ["prior account work"])
    }

    func testStatusStillReportsTheIsolationAfterAKeepWhoseSwapFails() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let swapFault = AccountIsolationSwapFault()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            manifestWriter: swapFault.write,
            writeHook: swapFault.arm
        )
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) },
            accountStateSource: account
        )
        _ = try await coordinator.enableOrRetry()
        try await add("prior account work", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        swapFault.failNextSwap()
        do {
            _ = try await coordinator.refreshAccountState()
            XCTFail("The full disk must fail the isolation's pointer swap")
        } catch SyncModePersistenceError.storageFailure {}

        swapFault.failNextSwap()
        do {
            _ = try await coordinator.resolveAccountIsolation(.keepLocalCopy)
            XCTFail("Keep Local Copy must report the failed swap")
        } catch {
            XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
        }

        swapFault.failNextSwap()
        do {
            let status = try await coordinator.status()
            XCTAssertEqual(status.state, .needsAttention)
            XCTAssertEqual(status.attentionReason, .accountSignedOut)
        } catch {
            XCTFail("Status must still report the isolation after a failed Keep: \(error)")
        }

        let finished = try await coordinator.status()
        XCTAssertEqual(finished.state, .needsAttention)
        XCTAssertEqual(finished.attentionReason, .accountSignedOut)
        let storage = try await persistence.snapshot()
        XCTAssertEqual(storage.accountIsolation?.resolution, .undecided)
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let hidden = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertTrue(hidden.snips.isEmpty, "The prior account's work must stay hidden")
    }

    func testInterruptedIsolationFinishesWithoutRelaunch() async throws {
        let points: [SyncModeCrashPoint] = [
            .afterAccountIsolationManifest,
            .beforeAccountIsolationDurability,
            .afterAccountIsolationDurability,
            .beforeAccountIsolationPointerSwap,
        ]
        for point in points {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let crash = CrashInjector(point: point)
            let persistence = try SwiftDataSyncModePersistence(
                rootURL: root,
                crashHook: crash.hit
            )
            let namespace = makeNamespace()
            let account = InjectedICloudAccountStateSource(
                state: .available(accountLineage: namespace.accountLineage)
            )
            let coordinator = ICloudSyncModeCoordinator(
                persistence: persistence,
                namespace: namespace,
                textZone: textZone(namespace),
                makeTransport: {
                    FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
                },
                accountStateSource: account
            )
            _ = try await coordinator.enableOrRetry()
            try await add("hidden without relaunch", to: persistence.activeLibrary())
            await account.setState(.noAccount)
            do {
                _ = try await coordinator.refreshAccountState()
                XCTFail("Expected interruption at \(point)")
            } catch is CrashInjector.Failure {}

            _ = try await coordinator.refreshAccountState()
            let storage = try await persistence.snapshot()
            XCTAssertEqual(storage.activeStore.kind, .localOnly, "point: \(point)")
            XCTAssertNotNil(storage.accountIsolation, "point: \(point)")
            let library = try await persistence.activeLibrary()
            let visible = await library.snapshot(sortedBy: .chronological)
            XCTAssertTrue(visible.snips.isEmpty, "point: \(point)")

            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            let reopenedStorage = try await reopened.snapshot()
            XCTAssertEqual(reopenedStorage.activeStore.id, storage.activeStore.id, "point: \(point)")
            XCTAssertEqual(
                reopenedStorage.accountIsolation,
                storage.accountIsolation,
                "point: \(point)"
            )
        }
    }

    func testReopenFinishesAChoiceAnOlderBuildStoredBeforeItsSwap() async throws {
        let cases: [(name: String, storedChoice: ICloudAccountIsolationResolution, visible: [String])] = [
            ("Keep", .keepingLocalCopy, ["prior account work"]),
            ("Remove", .removing, []),
        ]
        for (name, storedChoice, expectedVisible) in cases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let crash = CrashInjector(point: .beforeAccountIsolationPointerSwap)
            let persistence = try SwiftDataSyncModePersistence(
                rootURL: root,
                crashHook: crash.hit
            )
            let namespace = makeNamespace()
            let account = InjectedICloudAccountStateSource(
                state: .available(accountLineage: namespace.accountLineage)
            )
            let coordinator = ICloudSyncModeCoordinator(
                persistence: persistence,
                namespace: namespace,
                textZone: textZone(namespace),
                makeTransport: {
                    FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
                },
                accountStateSource: account
            )
            _ = try await coordinator.enableOrRetry()
            try await add("prior account work", to: persistence.activeLibrary())
            await account.setState(.noAccount)
            do {
                _ = try await coordinator.refreshAccountState()
                XCTFail("Expected interruption before the pointer swap, case: \(name)")
            } catch is CrashInjector.Failure {}

            try mutateManifest(at: root.appendingPathComponent("activation.json")) { manifest in
                var isolation = try XCTUnwrap(manifest["accountIsolation"] as? [String: Any])
                XCTAssertEqual(
                    isolation["resolution"] as? String,
                    ICloudAccountIsolationResolution.undecided.rawValue,
                    "case: \(name)"
                )
                isolation["resolution"] = storedChoice.rawValue
                manifest["accountIsolation"] = isolation
            }

            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            let resumed = ICloudSyncModeCoordinator(
                persistence: reopened,
                namespace: namespace,
                textZone: textZone(namespace),
                makeTransport: {
                    FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
                },
                accountStateSource: account
            )
            let status: ICloudSyncModeStatus
            do {
                status = try await resumed.status()
            } catch {
                XCTFail("Status must finish the stored choice, case: \(name): \(error)")
                continue
            }
            XCTAssertEqual(status.state, .off, "case: \(name)")
            let storage = try await reopened.snapshot()
            XCTAssertNil(storage.accountIsolation, "case: \(name)")
            XCTAssertEqual(storage.activeStore.kind, .localOnly, "case: \(name)")
            XCTAssertEqual(
                storage.activeStore.quarantinedNamespace,
                storedChoice == .keepingLocalCopy ? testBinding() : nil,
                "case: \(name)"
            )
            let library = try await reopened.activeLibrary()
            let visible = await library.snapshot(sortedBy: .chronological)
            XCTAssertEqual(visible.snips.map(\.content), expectedVisible, "case: \(name)")
        }
    }

    func testKeepLocalCopyCrashPointsReplayWithoutDuplicateData() async throws {
        let points: [SyncModeCrashPoint] = [
            .afterAccountResolutionIntent,
            .afterAccountLocalCopyMerge,
            .beforeAccountIsolationRemovalCommit,
            .afterAccountIsolationRemovalCommit,
            .afterAccountIsolationRootRemoval,
        ]
        for point in points {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let crash = CrashInjector(point: point)
            let persistence = try SwiftDataSyncModePersistence(
                rootURL: root,
                crashHook: crash.hit
            )
            let namespace = makeNamespace()
            let account = InjectedICloudAccountStateSource(
                state: .available(accountLineage: namespace.accountLineage)
            )
            let coordinator = ICloudSyncModeCoordinator(
                persistence: persistence,
                namespace: namespace,
                textZone: textZone(namespace),
                makeTransport: {
                    FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
                },
                accountStateSource: account
            )
            _ = try await coordinator.enableOrRetry()
            try await add("one isolated snip", to: persistence.activeLibrary())
            await account.setState(.noAccount)
            _ = try await coordinator.refreshAccountState()
            do {
                _ = try await coordinator.resolveAccountIsolation(.keepLocalCopy)
                XCTFail("Expected crash at \(point)")
            } catch is CrashInjector.Failure {}

            let reopened = try SwiftDataSyncModePersistence(rootURL: root)
            let resumed = ICloudSyncModeCoordinator(
                persistence: reopened,
                namespace: namespace,
                textZone: textZone(namespace),
                makeTransport: {
                    FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
                },
                accountStateSource: account
            )
            let status = try await resumed.status()
            XCTAssertEqual(status.state, .off, "point: \(point)")
            let reopenedStorage = try await reopened.snapshot()
            XCTAssertNil(reopenedStorage.accountIsolation, "point: \(point)")
            XCTAssertEqual(
                reopenedStorage.activeStore.quarantinedNamespace,
                testBinding(),
                "point: \(point)"
            )
            let library = try await reopened.activeLibrary()
            let visible = await library.snapshot(sortedBy: .chronological)
            XCTAssertEqual(visible.snips.map(\.content), ["one isolated snip"], "point: \(point)")
        }
    }

    func testBackgroundStatusWaitsForTheUsersKeepMerge() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mergePause = AccountLocalCopyMergePause()
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            writeHook: mergePause.hit
        )
        let namespace = makeNamespace()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
            },
            accountStateSource: account
        )
        _ = try await coordinator.enableOrRetry()
        try await add("prior account work", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()

        let keep = Task { try await coordinator.resolveAccountIsolation(.keepLocalCopy) }
        await mergePause.waitForHits(1, within: .seconds(5))
        XCTAssertEqual(mergePause.hits, 1, "The user's Keep must reach its merge")
        let background = Task { try await coordinator.status() }
        await mergePause.waitForHits(2, within: .seconds(2))
        mergePause.release()

        do {
            let kept = try await keep.value
            XCTAssertEqual(kept.state, .off)
        } catch {
            XCTFail("The user's Keep must finish its own merge: \(error)")
        }
        do {
            _ = try await background.value
        } catch {
            XCTFail("A background status must not fail beside the user's Keep: \(error)")
        }
        XCTAssertEqual(mergePause.hits, 1, "Only the user's Keep may run the merge")
        let storage = try await persistence.snapshot()
        XCTAssertNil(storage.accountIsolation)
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let visible = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertEqual(visible.snips.map(\.content), ["prior account work"])
    }

    func testUsersKeepReportsItsOwnTurnAfterABackgroundMergeFails() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let crash = CrashInjector(point: .afterAccountResolutionIntent)
        let mergePause = AccountLocalCopyMergePause(failsOnRelease: true)
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            crashHook: crash.hit,
            writeHook: mergePause.hit
        )
        let namespace = makeNamespace()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
            },
            accountStateSource: account
        )
        _ = try await coordinator.enableOrRetry()
        try await add("prior account work", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()
        do {
            _ = try await coordinator.resolveAccountIsolation(.keepLocalCopy)
            XCTFail("Expected the injected interruption after the stored choice")
        } catch is CrashInjector.Failure {}

        let background = Task { try await coordinator.status() }
        await mergePause.waitForHits(1, within: .seconds(5))
        XCTAssertEqual(mergePause.hits, 1, "The background reconcile must reach its merge")
        let keep = Task { try await coordinator.resolveAccountIsolation(.keepLocalCopy) }
        await mergePause.waitForHits(2, within: .seconds(2))
        mergePause.release()

        do {
            _ = try await background.value
            XCTFail("The background status must report its failed merge")
        } catch {
            XCTAssertTrue(error is AccountLocalCopyMergePause.Failure, "\(error)")
        }
        do {
            let kept = try await keep.value
            XCTAssertEqual(kept.state, .off)
        } catch {
            XCTFail("The user's Keep must make its own attempt after the failed one: \(error)")
        }
        let storage = try await persistence.snapshot()
        XCTAssertNil(storage.accountIsolation)
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let visible = await (try await persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertEqual(visible.snips.map(\.content), ["prior account work"])
    }

    func testInterruptedRemovalFinishesWhenTheOriginalAccountReturns() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let crash = CrashInjector(point: .afterAccountResolutionIntent)
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, crashHook: crash.hit)
        let namespace = makeNamespace()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
            },
            accountStateSource: account
        )
        _ = try await coordinator.enableOrRetry()
        try await add("remove after restart", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()
        do {
            _ = try await coordinator.resolveAccountIsolation(.remove)
            XCTFail("Expected the injected interruption")
        } catch is CrashInjector.Failure {}

        await account.setState(.available(accountLineage: namespace.accountLineage))
        let reopened = try SwiftDataSyncModePersistence(rootURL: root)
        let resumed = ICloudSyncModeCoordinator(
            persistence: reopened,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
            },
            accountStateSource: account
        )
        let status = try await resumed.refreshAccountState()
        XCTAssertEqual(status.state, .off)
        let storage = try await reopened.snapshot()
        XCTAssertNil(storage.accountIsolation)
        let visible = await (try reopened.activeLibrary()).snapshot(sortedBy: .manual)
        XCTAssertTrue(visible.snips.isEmpty)
    }

    func testUnknownAndRestrictedAccountStatesPauseWithoutIsolation() async throws {
        let cases: [(ICloudAccountState, ICloudSyncAttentionReason)] = [
            (.couldNotDetermine, .accountStatusUnknown),
            // Restricted access does not prove sign-out or an account change.
            (.restricted, .accountRestricted),
        ]
        for (accountState, expectedReason) in cases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let persistence = try SwiftDataSyncModePersistence(rootURL: root)
            let namespace = makeNamespace()
            let account = InjectedICloudAccountStateSource(
                state: .available(accountLineage: namespace.accountLineage)
            )
            let coordinator = ICloudSyncModeCoordinator(
                persistence: persistence,
                namespace: namespace,
                textZone: textZone(namespace),
                makeTransport: {
                    FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
                },
                accountStateSource: account
            )
            _ = try await coordinator.enableOrRetry()
            let before = try await persistence.snapshot()
            await account.setState(accountState)

            let paused = try await coordinator.refreshAccountState()
            let after = try await persistence.snapshot()
            XCTAssertEqual(paused.attentionReason, expectedReason)
            XCTAssertEqual(after.activeStore.id, before.activeStore.id)
            XCTAssertEqual(after.activeStore.kind, .iCloudSync)
            XCTAssertNil(after.accountIsolation)
        }
    }

    func testGenerationChangeKeepsSameAccountCacheIsolated() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let initial = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
            },
            accountStateSource: account
        )
        _ = try await initial.enableOrRetry()
        try await add("old generation", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await initial.refreshAccountState()

        let changed = CloudSyncNamespace(
            cloudScope: namespace.cloudScope,
            accountLineage: namespace.accountLineage,
            generation: UUID(),
            zones: namespace.zones
        )
        await account.setState(.available(accountLineage: namespace.accountLineage))
        let resumed = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: changed,
            textZone: textZone(changed),
            makeTransport: {
                FakeCloudRecordTransport(server: FakeCloudServer(), namespace: changed)
            },
            accountStateSource: account
        )

        let status = try await resumed.refreshAccountState()
        XCTAssertEqual(status.attentionReason, .namespaceChanged)
        let changedStorage = try await persistence.snapshot()
        XCTAssertNotNil(changedStorage.accountIsolation)
        let visibleLibrary = try await persistence.activeLibrary()
        let visible = await visibleLibrary.snapshot(sortedBy: .chronological)
        XCTAssertTrue(visible.snips.isEmpty)
    }

    func testAccountChangeDuringFetchStopsTheSendAndIsolatesTheCache() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let server = FakeCloudServer()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let setup = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: server, namespace: namespace)
            },
            accountStateSource: account
        )
        _ = try await setup.enableAndPublish()
        try await add("must not send", to: persistence.activeLibrary())
        let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
        await transport.pauseNextFetch()
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: { transport },
            accountStateSource: account
        )
        let syncing = Task { try await coordinator.syncActive() }
        await transport.waitUntilFetchPauses()
        await account.setState(.available(accountLineage: "other-account"))
        await transport.resumeFetch()

        let result = try await syncing.value
        XCTAssertEqual(result.attentionReason, .accountChanged)
        let isolatedStorage = try await persistence.snapshot()
        XCTAssertNotNil(isolatedStorage.accountIsolation)
        let remote = await server.storedTextValues()
        XCTAssertFalse(remote.contains("must not send"))
    }

    func testProductionAccountCacheHandlerCallsTheRealCoordinator() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
            },
            accountStateSource: account
        )
        _ = try await coordinator.enableOrRetry()
        try await add("handler keeps this", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()
        let handler: any AppleAccountCacheHandling = AppleAccountCacheCoordinatorHandler(
            coordinator: coordinator
        )

        let signedOutNotice = try await handler.refreshAppleAccountNotice()
        XCTAssertEqual(signedOutNotice, .signedOut)

        try await handler.resolveAppleAccountCache(.keepLocalCopy)

        let resolvedNotice = try await handler.refreshAppleAccountNotice()
        XCTAssertNil(resolvedNotice)

        let storage = try await persistence.snapshot()
        XCTAssertNil(storage.accountIsolation)
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let library = try await persistence.activeLibrary()
        let visible = await library.snapshot(sortedBy: .chronological)
        XCTAssertEqual(visible.snips.map(\.content), ["handler keeps this"])
    }

    func testLazyProductionAccountHandlerFinishesResolutionAfterSwitchingLocal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let descriptor = CloudCollectionDescriptor.fresh(
            ownerName: CloudCollectionAssembly.productionControlID.zone.ownerName
        )
        let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account-a")
        try await persistence.activateEmptyCollection(
            namespace: ICloudSyncNamespaceBinding(
                scope: namespace.cloudScope,
                accountLineage: namespace.accountLineage,
                generation: namespace.generation,
                zones: Set(namespace.zones.map {
                    ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
                })
            )
        )
        let formerlyActiveStore = try await persistence.snapshot().activeStore
        let formerlyActiveLibrary = try await persistence.libraryForTransition(storeID: formerlyActiveStore.id)
        let control = FakeCloudControlTransport(server: FakeCloudServer())
        await control.seedControl(descriptor)
        let account = InjectedICloudAccountStateSource(state: .noAccount)
        let handler = AppleAccountCacheCoordinatorHandler(
            persistence: { persistence },
            controlTransport: control,
            accountStateSource: account,
            makeSyncCoordinator: { persistence, resolvedNamespace, resolvedDescriptor in
                ICloudSyncModeCoordinator(
                    persistence: persistence,
                    namespace: resolvedNamespace,
                    textZone: resolvedDescriptor.metadataZone,
                    payloadZone: resolvedDescriptor.payloadZone,
                    makeTransport: {
                        FakeCloudRecordTransport(
                            server: FakeCloudServer(),
                            namespace: resolvedNamespace
                        )
                    },
                    accountStateSource: account
                )
            },
            makeAttachmentCoordinator: { _, _, _ in
                AttachmentTransferProbe(preparedURL: root.appendingPathComponent("unused"))
            }
        )

        let signedOutNotice = try await handler.refreshAppleAccountNotice()
        XCTAssertEqual(signedOutNotice, .signedOut)
        let isolatedStorage = try await SwiftDataSyncModePersistence(rootURL: root).snapshot()
        XCTAssertEqual(isolatedStorage.activeStore.kind, .localOnly)
        XCTAssertNotNil(isolatedStorage.accountIsolation)
        do {
            try await add("must stay isolated", to: formerlyActiveLibrary)
            XCTFail("Expected the prior account cache to reject writes")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .readOnlyRecovery)
        }
        try await handler.resolveAppleAccountCache(.keepLocalCopy)

        let resolvedNotice = try await handler.refreshAppleAccountNotice()
        XCTAssertNil(resolvedNotice)
        let storage = try await SwiftDataSyncModePersistence(rootURL: root).snapshot()
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        XCTAssertNil(storage.accountIsolation)
    }

    func testProductionAccountCacheHandlerRemovesThroughTheRealCoordinator() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let namespace = makeNamespace()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: textZone(namespace),
            makeTransport: {
                FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
            },
            accountStateSource: account
        )
        _ = try await coordinator.enableOrRetry()
        try await add("handler removes this", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()
        let handler: any AppleAccountCacheHandling = AppleAccountCacheCoordinatorHandler(
            coordinator: coordinator
        )

        try await handler.resolveAppleAccountCache(.remove)

        let storage = try await persistence.snapshot()
        XCTAssertNil(storage.accountIsolation)
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let library = try await persistence.activeLibrary()
        let visible = await library.snapshot(sortedBy: .chronological)
        XCTAssertTrue(visible.snips.isEmpty)
    }
}

private actor InjectedICloudAccountStateSource: ICloudAccountStateSource {
    private var state: ICloudAccountState

    init(state: ICloudAccountState) {
        self.state = state
    }

    func currentAccountState() -> ICloudAccountState {
        state
    }

    func setState(_ state: ICloudAccountState) {
        self.state = state
    }
}

private actor SyncActionCallCount {
    private var count = 0

    func record() { count += 1 }
    func value() -> Int { count }
}

/// Keeps a gate's lease from inside `withLease` until `release()`.
private actor HeldLease {
    private var isHeld = false
    private var isReleased = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        isHeld = true
        heldWaiters.forEach { $0.resume() }
        heldWaiters = []
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilHeld() async {
        if isHeld { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor AttachmentTransferProbe: CloudAttachmentTransferring {
    struct Configuration: Equatable, Sendable {
        let namespace: CloudSyncNamespace
        let payloadZone: CloudZoneID
    }

    private let preparedURL: URL
    private var recordedUses: [SyncedAttachmentUse] = []
    private var recordedClearCount = 0
    private var recordedConfiguration: Configuration?

    init(preparedURL: URL) {
        self.preparedURL = preparedURL
    }

    func prepare(attachmentID: UUID, for use: SyncedAttachmentUse) -> URL {
        _ = attachmentID
        recordedUses.append(use)
        return preparedURL
    }

    func clearDownloads() {
        recordedClearCount += 1
    }

    func transferStates() -> [UUID: CloudAttachmentTransferState] { [:] }
    func recordConfiguration(namespace: CloudSyncNamespace, payloadZone: CloudZoneID) {
        recordedConfiguration = Configuration(namespace: namespace, payloadZone: payloadZone)
    }
    func uses() -> [SyncedAttachmentUse] { recordedUses }
    func clearCount() -> Int { recordedClearCount }
    func configuration() -> Configuration? { recordedConfiguration }
}

private actor SyncCoordinatorConstructionProbe {
    private var recordedGenerations: [UUID] = []

    func record(_ generation: UUID) { recordedGenerations.append(generation) }
    func generations() -> [UUID] { recordedGenerations }
}

private func makeInjectedSyncCoordinator(
    persistence: SwiftDataSyncModePersistence,
    namespace: CloudSyncNamespace,
    descriptor: CloudCollectionDescriptor
) -> ICloudSyncModeCoordinator {
    ICloudSyncModeCoordinator(
        persistence: persistence,
        namespace: namespace,
        textZone: descriptor.metadataZone,
        payloadZone: descriptor.payloadZone,
        makeTransport: {
            FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
        },
        accountStateSource: InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
    )
}

extension ICloudSyncModeCoordinatorTests {
    func testSameAccountReturnFinishesItsDownloadBeforeAUsersRemove() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await startSameAccountReturnPausedInItsDownload(root: root)
        let coordinator = fixture.coordinator
        let removeEnded = TaskEndMark()
        let remove = Task {
            defer { removeEnded.set() }
            return try await coordinator.resolveAccountIsolation(.remove)
        }
        // Bounded: the Remove must be stored, then still be waiting at the turn after 2 s.
        let persistence = fixture.persistence
        let removeStored = await poll(within: .seconds(5)) {
            guard let storage = try? await persistence.snapshot() else { return false }
            return storage.accountIsolation == nil
                || storage.accountIsolation?.resolution == .removing
        }
        if !removeStored { XCTFail("The user's Remove must be stored during the download") }
        let removeEndedEarly = await removeEnded.wait(within: .seconds(2))
        XCTAssertFalse(removeEndedEarly, "The user's Remove must wait for the download's turn")
        fixture.fetchPause.release()

        do {
            let returned = try await fixture.returning.value
            XCTAssertEqual(returned.state, .off)
        } catch {
            XCTFail("The same-account return must finish beside the user's Remove: \(error)")
        }
        do {
            _ = try await remove.value
        } catch {
            XCTFail("The user's Remove must finish after the download: \(error)")
        }
        let storage = try await fixture.persistence.snapshot()
        XCTAssertNil(storage.accountIsolation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.isolatedRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.isolatedCacheRoot.path))
        let visible = await (try await fixture.persistence.activeLibrary())
            .snapshot(sortedBy: .chronological)
        XCTAssertFalse(visible.snips.map(\.content).contains("prior account work"))
    }

    func testUsersKeepWaitsForTheSameAccountReturnsDownload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await startSameAccountReturnPausedInItsDownload(root: root)
        let coordinator = fixture.coordinator
        let keepEnded = TaskEndMark()
        let keep = Task {
            defer { keepEnded.set() }
            return try await coordinator.resolveAccountIsolation(.keepLocalCopy)
        }
        // Bounded: the Keep must be stored, then still be waiting at the turn after 2 s.
        let persistence = fixture.persistence
        let keepStored = await poll(within: .seconds(5)) {
            guard let storage = try? await persistence.snapshot() else { return false }
            return storage.accountIsolation == nil
                || storage.accountIsolation?.resolution == .keepingLocalCopy
        }
        if !keepStored { XCTFail("The user's Keep must be stored during the download") }
        let keepEndedEarly = await keepEnded.wait(within: .seconds(2))
        XCTAssertFalse(keepEndedEarly, "The user's Keep must wait for the download's turn")
        fixture.fetchPause.release()

        do {
            let kept = try await keep.value
            XCTAssertEqual(kept.state, .off)
        } catch {
            XCTFail("The user's Keep must wait for the download, then finish: \(error)")
        }
        do {
            let returned = try await fixture.returning.value
            XCTAssertEqual(returned.state, .off)
        } catch {
            XCTFail("The same-account return must finish its Keep: \(error)")
        }
        let storage = try await fixture.persistence.snapshot()
        XCTAssertNil(storage.accountIsolation)
        XCTAssertEqual(storage.activeStore.kind, .localOnly)
        let visible = await (try await fixture.persistence.activeLibrary())
            .snapshot(sortedBy: .manual)
        XCTAssertEqual(visible.snips.map(\.content), ["prior account work"])
        let keptURL = try XCTUnwrap(visible.attachmentURLs[fixture.attachmentID])
        XCTAssertEqual(try Data(contentsOf: keptURL), fixture.bytes)
    }

    /// Isolates an iCloud cache whose only attachment's bytes now exist only in CloudKit, then
    /// brings the same account back. Returns with that refresh held in its download.
    private func startSameAccountReturnPausedInItsDownload(
        root: URL
    ) async throws -> SameAccountReturn {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cacheRoot = root.appendingPathComponent("AppGroup/Library/Caches/CloudAttachments")
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            attachmentCacheRootURL: cacheRoot
        )
        let sourceURL = root.appendingPathComponent("prior-account-attachment.txt")
        let bytes = Data("prior account attachment".utf8)
        try bytes.write(to: sourceURL)
        let library = try await persistence.activeLibrary()
        let added = try await library.perform(
            .add(
                content: "prior account work",
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
        let dataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account-a",
            generation: UUID(),
            zones: [dataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let fetchPause = AssetFetchPause()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: dataZone,
            payloadZone: payloadZone,
            makeTransport: {
                PausingAssetFetchTransport(
                    inner: FakeCloudRecordTransport(server: server, namespace: namespace),
                    pause: fetchPause
                )
            },
            accountStateSource: account
        )
        let enabled = try await coordinator.enableAndPublish()
        XCTAssertEqual(enabled.state, .on)
        let cloudStore = try await persistence.snapshot().activeStore
        let uploaded = await (try await persistence.activeLibrary()).snapshot(sortedBy: .manual)
        try FileManager.default.removeItem(at: XCTUnwrap(uploaded.attachmentURLs[attachmentID]))

        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()
        let isolated = try await persistence.snapshot()
        XCTAssertEqual(isolated.accountIsolation?.storeID, cloudStore.id)
        XCTAssertEqual(isolated.activeStore.kind, .localOnly)
        let isolatedRoot = root.appendingPathComponent(cloudStore.relativeRoot, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolatedRoot.path))
        let isolatedCacheRoot = try XCTUnwrap(
            SwiftDataSyncModePersistence.cacheRootURL(base: cacheRoot, storeID: cloudStore.id)
        )

        fetchPause.arm()
        await account.setState(.available(accountLineage: namespace.accountLineage))
        let returning = Task { try await coordinator.refreshAccountState() }
        let paused = await fetchPause.waitUntilPaused(within: .seconds(5))
        if !paused { XCTFail("The same-account return must reach its attachment download") }
        return SameAccountReturn(
            persistence: persistence,
            coordinator: coordinator,
            fetchPause: fetchPause,
            returning: returning,
            attachmentID: attachmentID,
            bytes: bytes,
            isolatedRoot: isolatedRoot,
            isolatedCacheRoot: isolatedCacheRoot
        )
    }
}

private struct SameAccountReturn: Sendable {
    let persistence: SwiftDataSyncModePersistence
    let coordinator: ICloudSyncModeCoordinator
    let fetchPause: AssetFetchPause
    let returning: Task<ICloudSyncModeStatus, any Error>
    let attachmentID: UUID
    let bytes: Data
    let isolatedRoot: URL
    let isolatedCacheRoot: URL
}

extension ICloudSyncModeCoordinatorTests {
    func testStalledReturningDownloadReleasesTheGateForTheUsersRemove() async throws {
        try await assertStalledReturningDownloadReleasesTheGate(for: .remove)
    }

    func testStalledReturningDownloadReleasesTheGateForTheUsersKeep() async throws {
        try await assertStalledReturningDownloadReleasesTheGate(for: .keepLocalCopy)
    }

    /// Holds the returning account's download in a CloudKit read that never answers, inside the
    /// account handler's gate, and queues the user's choice behind it.
    private func assertStalledReturningDownloadReleasesTheGate(
        for choice: AppleAccountCacheChoice
    ) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stall = CloudKitCallStall()
        addTeardownBlock { stall.release() }
        let cache = try await isolateCacheWhoseAttachmentIsOnlyInCloudKit(root: root)
        let downloads = makeDownloadTransport(bound: .shortForTests) { _, _ in
            await stall.enter()
            throw CloudKitCallStall.Released()
        }
        let returning = ICloudSyncModeCoordinator(
            persistence: cache.persistence,
            namespace: cache.namespace,
            textZone: cache.dataZone,
            payloadZone: cache.payloadZone,
            makeTransport: { downloads },
            accountStateSource: cache.account
        )
        let handler = AppleAccountCacheCoordinatorHandler(coordinator: returning)
        await cache.account.setState(.available(accountLineage: cache.namespace.accountLineage))

        let refreshEnded = TaskEndMark()
        let refresh = Task {
            defer { refreshEnded.set() }
            return try await handler.refreshAppleAccountNotice()
        }
        let stalled = await stall.waitUntilEntered(within: .seconds(5))
        XCTAssertTrue(stalled, "The returning account's download must reach CloudKit")
        let choiceEnded = TaskEndMark()
        let resolve = Task {
            defer { choiceEnded.set() }
            try await handler.resolveAppleAccountCache(choice)
        }
        // Bounded: the stalled read must end the refresh, and then the queued choice must run.
        let refreshStopped = await refreshEnded.wait(within: .seconds(5))
        XCTAssertTrue(refreshStopped, "A stalled download must not hold the account gate")
        let choiceRan = await choiceEnded.wait(within: .seconds(5))
        XCTAssertTrue(choiceRan, "The user's choice must run once the stalled download stops")
        stall.release()

        do {
            _ = try await refresh.value
            XCTFail("The stalled download must fail the account refresh")
        } catch {
            XCTAssertTrue(isCloudKitNetworkFailure(error), "\(error)")
        }
        switch choice {
        case .remove:
            do {
                try await resolve.value
            } catch {
                XCTFail("The user's Remove must finish after the stalled download: \(error)")
            }
            let storage = try await cache.persistence.snapshot()
            XCTAssertNil(storage.accountIsolation)
        case .keepLocalCopy:
            do {
                try await resolve.value
                XCTFail("Keep must fail while the attachment's bytes are missing")
            } catch {
                XCTAssertEqual(error as? SnipLibraryError, .attachmentCopyFailed, "\(error)")
            }
            let storage = try await cache.persistence.snapshot()
            XCTAssertEqual(storage.accountIsolation?.resolution, .keepingLocalCopy)
        }
    }

    /// Isolates an iCloud cache whose only attachment's bytes now exist only in CloudKit.
    private func isolateCacheWhoseAttachmentIsOnlyInCloudKit(
        root: URL
    ) async throws -> CloudOnlyAttachmentCache {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: root,
            attachmentCacheRootURL: root.appendingPathComponent(
                "AppGroup/Library/Caches/CloudAttachments"
            )
        )
        let sourceURL = root.appendingPathComponent("prior-account-attachment.txt")
        try Data("prior account attachment".utf8).write(to: sourceURL)
        let library = try await persistence.activeLibrary()
        let added = try await library.perform(
            .add(
                content: "prior account work",
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
        let dataZone = CloudZoneID(name: "metadata", ownerName: "owner")
        let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
        let namespace = CloudSyncNamespace(
            cloudScope: "private",
            accountLineage: "account-a",
            generation: UUID(),
            zones: [dataZone, payloadZone]
        )
        let server = FakeCloudServer()
        let account = InjectedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        let coordinator = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: dataZone,
            payloadZone: payloadZone,
            makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) },
            accountStateSource: account
        )
        let enabled = try await coordinator.enableAndPublish()
        XCTAssertEqual(enabled.state, .on)
        let uploaded = await (try await persistence.activeLibrary()).snapshot(sortedBy: .manual)
        try FileManager.default.removeItem(at: XCTUnwrap(uploaded.attachmentURLs[attachmentID]))

        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()
        let isolated = try await persistence.snapshot()
        XCTAssertNotNil(isolated.accountIsolation)
        XCTAssertEqual(isolated.activeStore.kind, .localOnly)
        return CloudOnlyAttachmentCache(
            persistence: persistence,
            namespace: namespace,
            dataZone: dataZone,
            payloadZone: payloadZone,
            account: account
        )
    }
}

private struct CloudOnlyAttachmentCache {
    let persistence: SwiftDataSyncModePersistence
    let namespace: CloudSyncNamespace
    let dataZone: CloudZoneID
    let payloadZone: CloudZoneID
    let account: InjectedICloudAccountStateSource
}
