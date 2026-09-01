import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
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
        _ = try await firstCoordinator.enableOrRetry()
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
        try await persistence.recordPreparationComplete()
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
        let transition = try XCTUnwrap(storage.transition)
        let candidate = try await persistence.libraryForTransition(
            storeID: transition.candidateStoreID
        ).snapshot(sortedBy: .chronological)
        XCTAssertFalse(candidate.snips.contains { $0.content == "foreign remote" })
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

    func testProductionAccountHandlerIsReadyBeforeFirstCloudOptIn() async throws {
        let missingRoot = temporaryDirectory()
        XCTAssertNotNil(
            AppleAccountCacheCoordinatorHandler(
                syncRootURL: missingRoot,
                containerIdentifier: "iCloud.org.example.snipsnap",
                syncWhenPossible: {}
            )
        )

        let localRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: localRoot) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: localRoot)
        XCTAssertNotNil(
            AppleAccountCacheCoordinatorHandler(
                syncRootURL: localRoot,
                containerIdentifier: "iCloud.org.example.snipsnap",
                syncWhenPossible: {}
            )
        )

        _ = try await persistence.beginTransition(
            to: .iCloudSync,
            namespace: testBinding()
        )
        XCTAssertNotNil(
            AppleAccountCacheCoordinatorHandler(
                syncRootURL: localRoot,
                containerIdentifier: "iCloud.org.example.snipsnap",
                syncWhenPossible: {}
            )
        )
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
            syncRootURL: root,
            controlTransport: control,
            makeSyncCoordinator: { persistence, resolvedNamespace, descriptor in
                makeInjectedSyncCoordinator(
                    persistence: persistence,
                    namespace: resolvedNamespace,
                    descriptor: descriptor
                )
            },
            makeAttachmentCoordinator: { _, resolvedNamespace, payloadZone in
                await probe.recordConfiguration(
                    namespace: resolvedNamespace,
                    payloadZone: payloadZone
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
            syncRootURL: root,
            controlTransport: control,
            makeSyncCoordinator: { persistence, namespace, descriptor in
                await syncProbe.record(namespace.generation)
                return makeInjectedSyncCoordinator(
                    persistence: persistence,
                    namespace: namespace,
                    descriptor: descriptor
                )
            },
            makeAttachmentCoordinator: { _, namespace, payloadZone in
                await attachmentProbe.recordConfiguration(
                    namespace: namespace,
                    payloadZone: payloadZone
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
        _ = try await coordinator.enableOrRetry()
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
        _ = try await coordinator.enableOrRetry()
        try await add("isolated work", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()
        try await add("new local work", to: persistence.activeLibrary())

        let kept = try await coordinator.resolveAccountIsolation(.keepLocalCopy)
        XCTAssertEqual(kept.state, .off)
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
        _ = try await firstCoordinator.enableOrRetry()
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

        let enabled = try await returnCoordinator.enableOrRetry()

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
        try await add("remove me", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()
        try await add("keep local", to: persistence.activeLibrary())

        let removed = try await coordinator.resolveAccountIsolation(.remove)
        XCTAssertEqual(removed.state, .off)
        let removedStorage = try await persistence.snapshot()
        XCTAssertNil(removedStorage.accountIsolation)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        let localLibrary = try await persistence.activeLibrary()
        let visible = await localLibrary.snapshot(sortedBy: .chronological)
        XCTAssertEqual(visible.snips.map(\.content), ["keep local"])
        XCTAssertEqual(try storeRootCount(in: root), 1)
    }

    func testSameAccountReturnUsesRemoteFirstEnableAfterNamespaceMatch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
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
        _ = try await coordinator.enableOrRetry()
        try await add("pending before sign-out", to: persistence.activeLibrary())
        await account.setState(.noAccount)
        _ = try await coordinator.refreshAccountState()
        try await add("made while signed out", to: persistence.activeLibrary())
        let eventsBeforeReturn = await transport.events().count
        await account.setState(.available(accountLineage: namespace.accountLineage))

        let resumed = try await coordinator.refreshAccountState()
        XCTAssertEqual(resumed.state, .on)
        let resumedStorage = try await persistence.snapshot()
        XCTAssertNil(resumedStorage.accountIsolation)
        let remote = await server.storedTextValues()
        XCTAssertEqual(Set(remote), ["pending before sign-out", "made while signed out"])
        let returnEvents = Array((await transport.events()).dropFirst(eventsBeforeReturn))
        let fetchIndex = try XCTUnwrap(returnEvents.firstIndex(of: .fetched))
        let sendIndex = try XCTUnwrap(returnEvents.firstIndex(where: {
            if case .sent = $0 { return true }
            return false
        }))
        XCTAssertLessThan(fetchIndex, sendIndex)
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
        _ = try await firstCoordinator.enableOrRetry()
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

        let enabled = try await secondCoordinator.enableOrRetry()
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
        _ = try await setup.enableOrRetry()
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
        let formerlyActiveLibrary = try await persistence.activeLibrary()
        let control = FakeCloudControlTransport(server: FakeCloudServer())
        await control.seedControl(descriptor)
        let account = InjectedICloudAccountStateSource(state: .noAccount)
        let handler = AppleAccountCacheCoordinatorHandler(
            syncRootURL: root,
            controlTransport: control,
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
