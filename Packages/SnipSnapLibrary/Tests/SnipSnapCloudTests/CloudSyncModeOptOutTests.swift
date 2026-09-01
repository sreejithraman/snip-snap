import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

extension ICloudSyncModeCoordinatorTests {
    func testOfflineOptOutCopiesCurrentCacheOnlyAfterExplicitStaleChoiceAndNeverDeletesCloud() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1, crashHook: injector.hit)
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

        let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
            rootURL: secondRoot, defaultSyncProtocol: .legacyTextV1,
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1, crashHook: injector.hit)
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

        let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1, crashHook: crash.hit)
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

        let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
                position: list.position,
                sortKey: list.sortKey
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
            let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1, crashHook: injector.hit)
            let activeID = try await persistence.snapshot().activeStore.id
            do {
                _ = try await persistence.beginTransition(to: .iCloudSync, namespace: testBinding())
                XCTFail("Expected the injected crash.")
            } catch CrashInjector.Failure.injected {}
            let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
            let snapshot = try await reopened.snapshot()
            XCTAssertEqual(snapshot.activeStore.id, activeID)
            XCTAssertNil(snapshot.transition)
            XCTAssertEqual(try storeRootCount(in: root), 1)
        }
    }

    func testFreezeIncludesPriorWritesRejectsLaterWritesAndSurvivesReopen() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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

        let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
                let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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

                let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
        let source = try await persistence.activeLibrary()
        let renamedID = try await createList("Before", systemImage: "circle", in: source).id
        let deletedID = try await createList("Remove", systemImage: "xmark", in: source).id
        _ = try await persistence.beginTransition(to: .iCloudSync, namespace: testBinding())
        try await persistence.recordPreparationComplete()
        let token = try await persistence.freezeSource()
        let frozen = try await persistence.finalSnapshot(using: token)
        _ = try await persistence.mergeFinalSnapshot(frozen, using: token)

        let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1, manifestWriter: writer.write)
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
            rootURL: root, defaultSyncProtocol: .legacyTextV1,
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1, crashHook: injector.hit)
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

        let reopened = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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
        let persistence = try SwiftDataSyncModePersistence(rootURL: root, defaultSyncProtocol: .legacyTextV1)
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

}
