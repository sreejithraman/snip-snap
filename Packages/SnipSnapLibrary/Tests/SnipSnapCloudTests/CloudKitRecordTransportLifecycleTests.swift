import CloudKit
import Foundation
@testable import SnipSnapCloud
import SnipSnapCore
import Synchronization
import XCTest

/// Pins the real transport's engine start, cycles, explicit transfers, first-fetch
/// gating, and reset by driving it with a scripted engine instead of CloudKit.
final class CloudKitRecordTransportLifecycleTests: XCTestCase {
    // MARK: Engine start

    func testSecondStartKeepsTheFirstEngineAndIgnoresItsArguments() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let ignored = fixture.recordID("ignored")
        try await transport.startEngine(
            state: CloudEngineStateEnvelope(namespace: fixture.otherNamespace, serialization: Data()),
            initialOutbound: CloudOutboundBatch(operations: [.save(makeDraft(ignored, "ignored"))]),
            outboundAdmission: CloudRecordOutboundAdmission(blocksAll: true)
        )

        XCTAssertEqual(fixture.factory.calls.count, 1)
        let engine = try fixture.engine(0)
        XCTAssertTrue(engine.pendingRecordZoneChanges.isEmpty)
        let scheduled = fixture.recordID("scheduled")
        try await transport.scheduleAutomaticSync(
            CloudOutboundBatch(operations: [.save(makeDraft(scheduled, "still open"))])
        )
        XCTAssertEqual(
            engine.pendingRecordZoneChanges,
            [.saveRecord(CloudKitRecordMapper.recordID(for: scheduled))]
        )
    }

    func testResetThenStartMakesANewEngineAndIgnoresTheOldOne() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        await transport.reset()
        try await transport.start(state: nil)

        XCTAssertEqual(fixture.factory.calls.count, 2)
        let old = try fixture.engine(0)
        let current = try fixture.engine(1)
        XCTAssertFalse(old === current)

        await transport.emit(
            .accountChange, .willFetchChanges, fixture.zoneFetched(0), .didFetchChanges,
            from: old
        )
        let afterOldEvents = await transport.headEvent()
        XCTAssertNil(afterOldEvents, "Events from the replaced engine must not queue work")

        await transport.emit(.willFetchChanges, fixture.zoneFetched(0), .didFetchChanges, from: current)
        try await transport.confirmAllEvents()
        let id = fixture.recordID("pending")
        try await transport.scheduleAutomaticSync(
            CloudOutboundBatch(operations: [.save(makeDraft(id, "body"))])
        )
        await transport.emit(.willSendChanges, from: current)

        let fromOld = await transport.nextRecordZoneChangeBatch(scope: .all, from: old)
        XCTAssertNil(fromOld)
        let fromCurrent = await transport.nextRecordZoneChangeBatch(scope: .all, from: current)
        XCTAssertEqual(fromCurrent?.recordsToSave.map(\.recordID), [CloudKitRecordMapper.recordID(for: id)])
    }

    func testAccountChangeWithholdsRecordsUntilConfirmation() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        await transport.emit(.willFetchChanges, fixture.zoneFetched(0), .didFetchChanges, from: engine)
        try await transport.confirmAllEvents()
        let id = fixture.recordID("pending")
        try await transport.scheduleAutomaticSync(
            CloudOutboundBatch(operations: [.save(makeDraft(id, "old account record"))])
        )
        await transport.emit(.willSendChanges, .accountChange, from: engine)

        let withheld = await transport.nextRecordZoneChangeBatch(scope: .all, from: engine)
        XCTAssertNil(withheld)
        try await transport.confirmAllEvents()
        let accepted = await transport.nextRecordZoneChangeBatch(scope: .all, from: engine)
        XCTAssertEqual(accepted?.recordsToSave.map(\.recordID), [CloudKitRecordMapper.recordID(for: id)])
    }

    func testStartWithEngineStateFromAnotherNamespaceThrowsAndMakesNoEngine() async {
        let fixture = makeFixture()
        let transport = fixture.transport

        await assertTransportError(.stateNamespaceMismatch) {
            try await transport.start(
                state: CloudEngineStateEnvelope(namespace: fixture.otherNamespace, serialization: Data())
            )
        }
        XCTAssertTrue(fixture.factory.calls.isEmpty)
        await assertTransportError(.notStarted) { try await transport.fetch(scope: .all) }
    }

    func testTransfersBeforeAStartThrowNotStarted() async {
        let fixture = makeFixture()
        let transport = fixture.transport

        await assertTransportError(.notStarted) { try await transport.fetch(scope: .all) }
        await assertTransportError(.notStarted) {
            try await transport.send(CloudOutboundBatch(operations: []))
        }
        await assertTransportError(.notStarted) {
            try await transport.scheduleAutomaticSync(CloudOutboundBatch(operations: []))
        }
        XCTAssertTrue(fixture.factory.calls.isEmpty)
    }

    func testEngineSyncsAutomaticallyOnlyWhenConfiguredAndAdmissionIsOpen() async throws {
        let unconfigured = makeFixture()
        try await unconfigured.transport.start(state: nil)

        let configured = makeFixture()
        await configured.transport.configureAutomaticSync(workAvailableHandler: {}, recordSendGate: {})
        try await configured.transport.start(state: nil)

        let blocked = makeFixture()
        await blocked.transport.configureAutomaticSync(workAvailableHandler: {}, recordSendGate: {})
        try await blocked.transport.startEngine(
            state: nil,
            initialOutbound: nil,
            outboundAdmission: CloudRecordOutboundAdmission(blocksAll: true)
        )

        XCTAssertEqual(unconfigured.factory.calls.map(\.automaticallySync), [false])
        XCTAssertEqual(configured.factory.calls.map(\.automaticallySync), [true])
        XCTAssertEqual(blocked.factory.calls.map(\.automaticallySync), [false])
        XCTAssertEqual(unconfigured.factory.calls.map(\.receivedEngineState), [false])
    }

    func testProviderUsesDesiredOperationsWhenEngineStillHasStaleDeleteIDs() async throws {
        for includesPointerSave in [false, true] {
            let fixture = makeFixture()
            let transport = fixture.transport
            let pointer = fixture.recordID("pointer")
            let payload = fixture.recordID("payload")
            let unrelated = fixture.recordID("unrelated")
            var planned: [CloudOutboundOperation] = [.delete(unrelated, base: nil)]
            if includesPointerSave { planned.append(.save(makeDraft(pointer, "same pointer, new metadata"))) }
            try await transport.startEngine(state: nil, initialOutbound: .init(operations: planned),
                outboundAdmission: .init(blockedRecordIDs: [payload]))
            let engine = try fixture.engine(0)
            await transport.emit(.willFetchChanges, fixture.zoneFetched(0), .didFetchChanges, from: engine)
            try await transport.confirmAllEvents()
            let pointerID = CloudKitRecordMapper.recordID(for: pointer)
            let payloadID = CloudKitRecordMapper.recordID(for: payload)
            let unrelatedID = CloudKitRecordMapper.recordID(for: unrelated)
            if includesPointerSave { engine.remove(pendingRecordZoneChanges: [.saveRecord(pointerID)]) }
            engine.add(pendingRecordZoneChanges: [.deleteRecord(pointerID), .deleteRecord(payloadID)])
            await transport.emit(.willSendChanges, from: engine)
            XCTAssertTrue(engine.pendingRecordZoneChanges.contains(.deleteRecord(pointerID)))
            let provided = await transport.nextRecordZoneChangeBatch(scope: .all, from: engine)
            let batch = try XCTUnwrap(provided)
            XCTAssertEqual(batch.recordsToSave.map(\.recordID), includesPointerSave ? [pointerID] : [])
            XCTAssertEqual(batch.recordIDsToDelete, [unrelatedID])
        }
    }

    // MARK: Automatic cycles

    func testAutomaticFetchCycleQueuesOneBatchWithTheLatestEngineStateThenACheckpoint() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        let changedID = fixture.recordID("changed")
        let deletedID = fixture.recordID("deleted")
        let changed = try makeCKRecord(changedID, "remote edit")
        let duringCycle = Data("during-cycle".utf8)

        await transport.emit(
            .willFetchChanges,
            .fetchedRecordZoneChanges(
                modifications: [changed],
                deletions: [CloudKitRecordMapper.recordID(for: deletedID)]
            ),
            .stateUpdate(duringCycle),
            from: engine
        )
        let beforeCycleEnds = await transport.headEvent()
        XCTAssertNil(beforeCycleEnds, "A checkpoint during a cycle waits for that cycle's batch")

        await transport.emit(fixture.zoneFetched(0), .didFetchChanges, from: engine)
        let head = await transport.headEvent()
        let batch = try XCTUnwrap(head?.fetchedBatch)
        XCTAssertEqual(batch.items.map(\.id), [changedID, deletedID])
        guard case .record(let snapshot)? = batch.items.first else {
            return XCTFail("Expected the changed record first")
        }
        XCTAssertEqual(snapshotText(snapshot), "remote edit")
        XCTAssertEqual(batch.items.last, .deleted(deletedID))
        XCTAssertEqual(batch.zoneEvents, [.fetched(fixture.zones[0])])
        XCTAssertTrue(batch.isInitialFetch)
        XCTAssertEqual(
            batch.engineState,
            CloudEngineStateEnvelope(
                namespace: fixture.namespace, serialization: duringCycle, requiresInitialFetch: false
            )
        )

        let afterCycle = Data("after-cycle".utf8)
        await transport.emit(.stateUpdate(afterCycle), from: engine)
        let stillHead = await transport.headEvent()
        XCTAssertEqual(stillHead?.id, batch.id)
        try await transport.confirmApplied(batch.id)
        let next = await transport.headEvent()
        XCTAssertEqual(
            next?.checkpointState,
            CloudEngineStateEnvelope(
                namespace: fixture.namespace, serialization: afterCycle, requiresInitialFetch: false
            )
        )
    }

    func testOverlappingCyclesGiveEngineStateOnlyToTheBatchThatFinishesLast() async throws {
        let state = Data("between".utf8)

        let fetchFirst = makeFixture()
        try await fetchFirst.transport.start(state: nil)
        let fetchFirstEngine = try fetchFirst.engine(0)
        await fetchFirst.transport.emit(
            .willFetchChanges, .willSendChanges, .stateUpdate(state),
            fetchFirst.zoneFetched(0), .didFetchChanges, .didSendChanges,
            from: fetchFirstEngine
        )
        let fetchFirstEvents = try await fetchFirst.transport.confirmAllEvents()
        XCTAssertEqual(fetchFirstEvents.count, 2)
        XCTAssertNil(try XCTUnwrap(fetchFirstEvents.first?.fetchedBatch).engineState)
        XCTAssertEqual(
            try XCTUnwrap(fetchFirstEvents.last?.sentBatch).engineState,
            CloudEngineStateEnvelope(
                namespace: fetchFirst.namespace, serialization: state, requiresInitialFetch: false
            )
        )

        let sendFirst = makeFixture()
        try await sendFirst.transport.start(state: nil)
        let sendFirstEngine = try sendFirst.engine(0)
        await sendFirst.transport.emit(
            .willSendChanges, .willFetchChanges, .stateUpdate(state),
            .didSendChanges, sendFirst.zoneFetched(0), .didFetchChanges,
            from: sendFirstEngine
        )
        let sendFirstEvents = try await sendFirst.transport.confirmAllEvents()
        XCTAssertEqual(sendFirstEvents.count, 2)
        XCTAssertNil(try XCTUnwrap(sendFirstEvents.first?.sentBatch).engineState)
        XCTAssertEqual(
            try XCTUnwrap(sendFirstEvents.last?.fetchedBatch).engineState,
            CloudEngineStateEnvelope(
                namespace: sendFirst.namespace, serialization: state, requiresInitialFetch: false
            )
        )
    }

    // MARK: Explicit transfers

    func testExplicitFetchWaitsUntilEveryRunningCycleEnds() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        let zone = fixture.zoneFetched(0)
        let phase = Mutex(0)
        let startedWhileBothRan = expectation(description: "Explicit fetch started while both cycles ran")
        startedWhileBothRan.isInverted = true
        let startedWhileSendRan = expectation(description: "Explicit fetch started while the send cycle ran")
        startedWhileSendRan.isInverted = true
        let started = expectation(description: "Explicit fetch started after every cycle ended")
        engine.onFetch { engine, _ in
            switch phase.withLock({ $0 }) {
            case 0: startedWhileBothRan.fulfill()
            case 1: startedWhileSendRan.fulfill()
            default: started.fulfill()
            }
            await transport.emit(.willFetchChanges, zone, .didFetchChanges, from: engine)
        }
        await transport.emit(.willFetchChanges, .willSendChanges, from: engine)

        let explicitFetch = Task { try await transport.fetch(scope: .all) }
        await fulfillment(of: [startedWhileBothRan], timeout: 0.2)
        phase.withLock { $0 = 1 }
        await transport.emit(zone, .didFetchChanges, from: engine)
        await fulfillment(of: [startedWhileSendRan], timeout: 0.2)
        phase.withLock { $0 = 2 }
        await transport.emit(.didSendChanges, from: engine)
        await fulfillment(of: [started], timeout: 2)
        let batch = try await value(of: explicitFetch)

        let events = try await transport.confirmAllEvents()
        XCTAssertEqual(events.count, 3)
        XCTAssertNotNil(events.first?.fetchedBatch)
        XCTAssertNotNil(events.dropFirst().first?.sentBatch)
        XCTAssertEqual(events.last?.id, batch.id)
    }

    func testCancellingOneWaitingTransferKeepsTheCycleForAnotherWaiter() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        let zone = fixture.zoneFetched(0)
        let phase = Mutex(0)
        let startedDuringCycle = expectation(description: "A transfer started during the cycle")
        startedDuringCycle.isInverted = true
        let startedAfterCancel = expectation(description: "Cancelling a waiter ended the cycle")
        startedAfterCancel.isInverted = true
        let started = expectation(description: "The remaining transfer started after the cycle")
        engine.onFetch { engine, _ in
            switch phase.withLock({ $0 }) {
            case 0: startedDuringCycle.fulfill()
            case 1: startedAfterCancel.fulfill()
            default: started.fulfill()
            }
            await transport.emit(.willFetchChanges, zone, .didFetchChanges, from: engine)
        }
        await transport.emit(.willFetchChanges, from: engine)

        let cancelled = expectation(description: "Cancelled transfer stopped waiting")
        let cancelledFetch = Task {
            do {
                _ = try await transport.fetch(scope: .all)
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        let waitingFetch = Task { try await transport.fetch(scope: .all) }
        await fulfillment(of: [startedDuringCycle], timeout: 0.2)
        cancelledFetch.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        phase.withLock { $0 = 1 }
        await fulfillment(of: [startedAfterCancel], timeout: 0.2)
        phase.withLock { $0 = 2 }
        await transport.emit(.didFetchChanges, from: engine)
        await fulfillment(of: [started], timeout: 2)
        _ = try await value(of: waitingFetch)

        XCTAssertEqual(engine.fetchOptions.count, 1, "The cancelled transfer never reached CloudKit")
    }

    func testExplicitFetchAsksForTheRequestedAutomaticZonesAndReturnsItsOwnBatch() async throws {
        let fixture = makeFixture(zoneNames: ["a", "b", "c"], automaticZoneNames: ["a", "b"])
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        let (zoneA, zoneB, zoneC) = (fixture.zones[0], fixture.zones[1], fixture.zones[2])
        let fetchedID = CloudRecordID(zone: zoneA, name: "fetched")
        let fetchedRecord = try makeCKRecord(fetchedID, "from zone a")
        engine.onFetch { engine, options in
            guard case .zoneIDs(let zoneIDs) = options.scope else {
                XCTFail("Expected an explicit zone list")
                return
            }
            await transport.emit(
                .willFetchChanges,
                .fetchedRecordZoneChanges(modifications: [fetchedRecord], deletions: []),
                from: engine
            )
            for zoneID in zoneIDs {
                await transport.emit(.didFetchRecordZoneChanges(zoneID: zoneID, error: nil), from: engine)
            }
            await transport.emit(.didFetchChanges, from: engine)
        }

        let scoped = try await transport.fetch(scope: .zones([zoneA, zoneC]))
        XCTAssertEqual(engine.fetchOptions.map(\.scope), [.zoneIDs([CloudKitRecordMapper.zoneID(for: zoneA)])])
        let queued = await transport.headEvent()
        XCTAssertEqual(queued?.id, scoped.id)
        XCTAssertEqual(scoped.items.map(\.id), [fetchedID])
        XCTAssertEqual(scoped.zoneEvents, [.fetched(zoneA)])
        try await transport.confirmApplied(scoped.id)

        _ = try await transport.fetch(scope: .all)
        let allScope = try XCTUnwrap(engine.fetchOptions.last?.scope)
        XCTAssertEqual(fetchedZones(in: allScope), Set([zoneA, zoneB]))
    }

    func testExplicitFetchWithoutACloudKitCycleStillReturnsAQueuedBatch() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)

        let first = try await transport.fetch(scope: .all)
        let queued = await transport.headEvent()
        XCTAssertEqual(queued?.fetchedBatch, first)
        XCTAssertTrue(first.isInitialFetch)
        XCTAssertTrue(first.items.isEmpty)
        XCTAssertTrue(first.zoneEvents.isEmpty)
        try await transport.confirmApplied(first.id)

        let second = try await transport.fetch(scope: .all)
        XCTAssertTrue(second.isInitialFetch, "An empty answer does not complete the first fetch")
        try await transport.confirmApplied(second.id)

        await transport.emit(.willFetchChanges, fixture.zoneFetched(0), .didFetchChanges, from: engine)
        try await transport.confirmAllEvents()
        let incremental = try await transport.fetch(scope: .all)
        XCTAssertFalse(incremental.isInitialFetch)
        XCTAssertEqual(engine.fetchOptions.count, 3)
    }

    func testFailedExplicitFetchAndSendReturnBatchesWithTheMappedFailure() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        engine.onFetch { _, _ in throw ckError(.networkUnavailable) }
        engine.onSend { _, _ in throw ckError(.serviceUnavailable) }

        let fetched = try await transport.fetch(scope: .all)
        XCTAssertEqual(fetched.databaseEvents, [.failed(nil, .networkUnavailable)])
        XCTAssertTrue(fetched.isInitialFetch)
        let queuedFetch = await transport.headEvent()
        XCTAssertEqual(queuedFetch?.id, fetched.id)
        try await transport.confirmApplied(fetched.id)

        let id = fixture.recordID("unsent")
        let sent = try await transport.send(CloudOutboundBatch(operations: [.save(makeDraft(id, "body"))]))
        XCTAssertEqual(sent.databaseEvents, [.failed(nil, .iCloudUnavailable)])
        XCTAssertTrue(sent.items.isEmpty)
        let queuedSend = await transport.headEvent()
        XCTAssertEqual(queuedSend?.id, sent.id)
    }

    func testExplicitSendAccountErrorReturnsAcceptedDeletesIfTheCycleHasNotAlreadyFinished() async throws {
        for cycleAlreadyFinished in [false, true] {
            let fixture = makeFixture()
            let transport = fixture.transport
            try await transport.start(state: nil)
            let engine = try fixture.engine(0)
            await transport.emit(.willFetchChanges, fixture.zoneFetched(0), .didFetchChanges, from: engine)
            try await transport.confirmAllEvents()

            let attachmentID = UUID()
            let pointer = fixture.recordID("a-\(attachmentID.uuidString.lowercased())")
            let deferred = fixture.recordID("a-\(UUID().uuidString.lowercased())")
            let offer = CloudOutboundBatch(operations: [.delete(pointer, base: nil), .delete(deferred, base: nil)])
            let pointerID = CloudKitRecordMapper.recordID(for: pointer)
            engine.onSend { engine, options in
                await transport.emit(.willSendChanges, from: engine)
                engine.remove(pendingRecordZoneChanges: [.deleteRecord(CloudKitRecordMapper.recordID(for: deferred))])
                let offered = await transport.nextRecordZoneChangeBatch(scope: options.scope, from: engine)
                XCTAssertEqual(offered?.recordIDsToDelete, [pointerID])
                await transport.emit(.accountChange, .sentRecordZoneChanges(
                    savedRecords: [], deletedRecordIDs: [pointerID], failedRecordSaves: [], failedRecordDeletes: []
                ), from: engine)
                if cycleAlreadyFinished { await transport.emit(.didSendChanges, from: engine) }
                throw ckError(.notAuthenticated)
            }

            let returned = try await transport.send(offer)
            XCTAssertEqual(returned.databaseEvents, [.failed(nil, .authenticationRequired)])
            let earlier = await transport.headEvent()
            let account = try XCTUnwrap(earlier)
            XCTAssertTrue(account.isAccountChange)
            XCTAssertEqual(returned.items.contains(.deleted(pointer)), !cycleAlreadyFinished)

            try await transport.confirmApplied(account.id)
            let next = await transport.headEvent()
            let head = try XCTUnwrap(next)
            XCTAssertEqual(head.sentBatch?.items, [.deleted(pointer)])
            XCTAssertEqual(head.id == returned.id, !cycleAlreadyFinished)
        }
    }

    func testSecondExplicitTransferDuringAnEngineCallThrowsSyncAlreadyRunning() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        let gate = AsyncOpenGate()
        defer { gate.open() }
        let entered = expectation(description: "First fetch entered CloudKit")
        engine.onFetch { _, _ in
            entered.fulfill()
            await gate.wait()
        }

        let first = Task { try await transport.fetch(scope: .all) }
        await fulfillment(of: [entered], timeout: 2)
        await assertTransportError(.syncAlreadyRunning) { try await transport.fetch(scope: .all) }
        await assertTransportError(.syncAlreadyRunning) {
            try await transport.send(CloudOutboundBatch(operations: []))
        }
        gate.open()
        let batch = try await value(of: first)

        XCTAssertTrue(batch.isInitialFetch)
        XCTAssertEqual(engine.fetchOptions.count, 1)
        XCTAssertTrue(engine.sendOptions.isEmpty)
    }

    func testExplicitSendSuppliesOnlyTheScheduledRecordsCloudKitStillHolds() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        await transport.emit(.willFetchChanges, fixture.zoneFetched(0), .didFetchChanges, from: engine)
        try await transport.confirmAllEvents()

        let kept = fixture.recordID("kept")
        let withdrawn = fixture.recordID("withdrawn")
        let dropped = fixture.recordID("dropped")
        let keptDraft = makeDraft(kept, "keep me")
        let droppedDraft = makeDraft(dropped, "dropped by CloudKit")
        let provided = Mutex<CKSyncEngine.RecordZoneChangeBatch?>(nil)
        engine.onSend { engine, options in
            await transport.emit(.willSendChanges, from: engine)
            // A newer snapshot withdraws one record; CloudKit no longer holds another.
            try await transport.scheduleAutomaticSync(
                CloudOutboundBatch(operations: [.save(keptDraft), .save(droppedDraft)])
            )
            engine.remove(pendingRecordZoneChanges: [.saveRecord(CloudKitRecordMapper.recordID(for: dropped))])
            let batch = await transport.nextRecordZoneChangeBatch(scope: options.scope, from: engine)
            provided.withLock { $0 = batch }
            await transport.emit(sentRecords(batch?.recordsToSave ?? []), .didSendChanges, from: engine)
        }

        let sent = try await transport.send(CloudOutboundBatch(operations: [
            .save(keptDraft), .save(makeDraft(withdrawn, "undone")), .save(droppedDraft),
        ]))

        XCTAssertEqual(engine.sendOptions.map(\.scope), [.all])
        XCTAssertEqual(
            provided.withLock { $0?.recordsToSave.map(\.recordID) },
            [CloudKitRecordMapper.recordID(for: kept)]
        )
        XCTAssertEqual(sent.items.map(\.id), [kept])
        guard case .saved(let snapshot)? = sent.items.first else {
            return XCTFail("Expected the supplied record to be saved")
        }
        XCTAssertEqual(snapshotText(snapshot), "keep me")
        let queued = await transport.headEvent()
        XCTAssertEqual(queued?.sentBatch, sent)
    }

    // MARK: Fetch scope

    func testNextFetchAsksForTheAutomaticZonesOrTheRunningScopedFetchAndNoneWhileStopped() async throws {
        let fixture = makeFixture(zoneNames: ["a", "b", "c"], automaticZoneNames: ["a", "b"])
        let transport = fixture.transport
        let (zoneA, zoneB, zoneC) = (fixture.zones[0], fixture.zones[1], fixture.zones[2])
        let automatic: Set<CloudZoneID> = [zoneA, zoneB]
        let noZones: Set<CloudZoneID> = []
        let beforeStart = await transport.nextFetchZones()
        XCTAssertEqual(beforeStart, noZones)

        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        let afterStart = await transport.nextFetchZones()
        XCTAssertEqual(afterStart, automatic)

        let duringFetch = Mutex<Set<CloudZoneID>?>(nil)
        engine.onFetch { _, _ in
            let zones = await transport.nextFetchZones()
            duringFetch.withLock { $0 = zones }
        }
        _ = try await transport.fetch(scope: .zones([zoneA, zoneC]))
        XCTAssertEqual(duringFetch.withLock { $0 }, Set([zoneA]))
        let afterFetch = await transport.nextFetchZones()
        XCTAssertEqual(afterFetch, automatic)

        engine.onFetch { _, _ in throw ckError(.networkUnavailable) }
        _ = try await transport.fetch(scope: .zones([zoneA]))
        let afterFailedFetch = await transport.nextFetchZones()
        XCTAssertEqual(afterFailedFetch, automatic)

        let duringSend = Mutex<Set<CloudZoneID>?>(nil)
        engine.onSend { _, _ in
            let zones = await transport.nextFetchZones()
            duringSend.withLock { $0 = zones }
        }
        _ = try await transport.send(CloudOutboundBatch(operations: []))
        XCTAssertEqual(duringSend.withLock { $0 }, automatic)

        let gate = AsyncOpenGate()
        defer { gate.open() }
        let entered = expectation(description: "A scoped fetch entered the old engine")
        engine.onFetch { _, _ in
            entered.fulfill()
            await gate.wait()
        }
        let stale = Task { try await transport.fetch(scope: .zones([zoneA])) }
        await fulfillment(of: [entered], timeout: 2)
        await transport.reset()
        let afterReset = await transport.nextFetchZones()
        XCTAssertEqual(afterReset, noZones)

        try await transport.start(state: nil)
        let afterRestart = await transport.nextFetchZones()
        XCTAssertEqual(afterRestart, automatic)
        gate.open()
        await assertTransportError(.notStarted) { try await value(of: stale) }
        let afterStaleFetch = await transport.nextFetchZones()
        XCTAssertEqual(afterStaleFetch, automatic)
    }

    // MARK: First fetch

    func testProviderWithholdsRecordsUntilTheFirstFetchCommits() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        let before = Data("before-first-fetch".utf8)
        await transport.emit(.stateUpdate(before), from: engine)
        let early = await transport.headEvent()
        XCTAssertEqual(
            early?.checkpointState,
            CloudEngineStateEnvelope(namespace: fixture.namespace, serialization: before, requiresInitialFetch: true)
        )
        try await transport.confirmAllEvents()

        let id = fixture.recordID("waiting")
        let recordID = CloudKitRecordMapper.recordID(for: id)
        try await transport.scheduleAutomaticSync(
            CloudOutboundBatch(operations: [.save(makeDraft(id, "after the first fetch"))])
        )
        await transport.emit(.willSendChanges, from: engine)
        let beforeFetch = await transport.nextRecordZoneChangeBatch(scope: .all, from: engine)
        XCTAssertNil(beforeFetch, "The first fetch has not run")

        await transport.emit(.willFetchChanges, fixture.zoneFetched(0), .didFetchChanges, from: engine)
        let head = await transport.headEvent()
        let initial = try XCTUnwrap(head?.fetchedBatch)
        XCTAssertTrue(initial.isInitialFetch)
        XCTAssertNil(initial.engineState, "The send cycle is still running")
        let beforeConfirm = await transport.nextRecordZoneChangeBatch(scope: .all, from: engine)
        XCTAssertNil(beforeConfirm, "The first fetch has not committed")

        try await transport.confirmApplied(initial.id)
        let afterConfirm = await transport.nextRecordZoneChangeBatch(scope: .all, from: engine)
        XCTAssertEqual(afterConfirm?.recordsToSave.map(\.recordID), [recordID])

        await transport.emit(sentRecords(afterConfirm?.recordsToSave ?? []), .didSendChanges, from: engine)
        let sentHead = await transport.headEvent()
        let sent = try XCTUnwrap(sentHead?.sentBatch)
        XCTAssertEqual(sent.items.map(\.id), [id])
        XCTAssertEqual(
            sent.engineState,
            CloudEngineStateEnvelope(namespace: fixture.namespace, serialization: before, requiresInitialFetch: false)
        )
        try await transport.confirmApplied(sent.id)
        let after = Data("after-first-fetch".utf8)
        await transport.emit(.stateUpdate(after), from: engine)
        let late = await transport.headEvent()
        XCTAssertEqual(
            late?.checkpointState,
            CloudEngineStateEnvelope(namespace: fixture.namespace, serialization: after, requiresInitialFetch: false)
        )
    }

    func testPartialOrFailedFirstFetchKeepsTheNextFetchInitial() async throws {
        let partial = makeFixture(zoneNames: ["a", "b"])
        try await partial.transport.start(state: nil)
        let partialEngine = try partial.engine(0)
        await partial.transport.emit(
            .willFetchChanges, partial.zoneFetched(0), .stateUpdate(Data("partial".utf8)), .didFetchChanges,
            from: partialEngine
        )
        let partialEvents = try await partial.transport.confirmAllEvents()
        let onlyZoneA = try XCTUnwrap(partialEvents.first?.fetchedBatch)
        XCTAssertTrue(onlyZoneA.isInitialFetch)
        XCTAssertEqual(onlyZoneA.engineState?.requiresInitialFetch, true)
        await partial.transport.emit(
            .willFetchChanges, partial.zoneFetched(0), partial.zoneFetched(1), .didFetchChanges,
            from: partialEngine
        )
        let completeEvents = try await partial.transport.confirmAllEvents()
        let bothZones = try XCTUnwrap(completeEvents.first?.fetchedBatch)
        XCTAssertTrue(bothZones.isInitialFetch)
        XCTAssertEqual(bothZones.engineState?.requiresInitialFetch, false)

        let failing = makeFixture()
        try await failing.transport.start(state: nil)
        let failingEngine = try failing.engine(0)
        let zoneID = CloudKitRecordMapper.zoneID(for: failing.zones[0])
        await failing.transport.emit(
            .willFetchChanges,
            .didFetchRecordZoneChanges(zoneID: zoneID, error: ckError(.zoneBusy)),
            .stateUpdate(Data("failed".utf8)),
            .didFetchChanges,
            from: failingEngine
        )
        let failedEvents = try await failing.transport.confirmAllEvents()
        let zoneFailure = try XCTUnwrap(failedEvents.first?.fetchedBatch)
        XCTAssertEqual(zoneFailure.zoneEvents, [.failed(failing.zones[0], .rateLimited)])
        XCTAssertTrue(zoneFailure.isInitialFetch)
        XCTAssertEqual(zoneFailure.engineState?.requiresInitialFetch, true)

        // Every zone finished, but an unreadable engine state is a blocking issue.
        await failing.transport.emit(
            .willFetchChanges, failing.zoneFetched(0), .stateUpdate(nil), .didFetchChanges,
            from: failingEngine
        )
        let blockedEvents = try await failing.transport.confirmAllEvents()
        let blocked = try XCTUnwrap(blockedEvents.first?.fetchedBatch)
        XCTAssertEqual(blocked.databaseEvents, [.failed(nil, .invalidRecord)])
        XCTAssertTrue(blocked.isInitialFetch)
        XCTAssertEqual(blocked.engineState?.requiresInitialFetch, true)

        await failing.transport.emit(
            .willFetchChanges, failing.zoneFetched(0), .didFetchChanges,
            from: failingEngine
        )
        let recoveredEvents = try await failing.transport.confirmAllEvents()
        let recovered = try XCTUnwrap(recoveredEvents.first?.fetchedBatch)
        XCTAssertTrue(recovered.isInitialFetch)
        XCTAssertEqual(recovered.engineState?.requiresInitialFetch, false)
    }

    // MARK: Failure mapping

    func testProviderLeavesOutARecordThatFailsToMapAndReportsItInvalid() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        await transport.emit(.willFetchChanges, fixture.zoneFetched(0), .didFetchChanges, from: engine)
        try await transport.confirmAllEvents()
        let mapped = fixture.recordID("mapped")
        let unmappable = fixture.recordID("unmappable")
        try await transport.scheduleAutomaticSync(CloudOutboundBatch(operations: [
            .save(makeDraft(mapped, "maps")), .save(makeUnmappableDraft(unmappable)),
        ]))

        await transport.emit(.willSendChanges, from: engine)
        let provided = await transport.nextRecordZoneChangeBatch(scope: .all, from: engine)
        XCTAssertEqual(provided?.recordsToSave.map(\.recordID), [CloudKitRecordMapper.recordID(for: mapped)])
        await transport.emit(sentRecords(provided?.recordsToSave ?? []), .didSendChanges, from: engine)

        let head = await transport.headEvent()
        let sent = try XCTUnwrap(head?.sentBatch)
        XCTAssertEqual(sent.items.map(\.id), [mapped, unmappable])
        guard case .saved(let snapshot)? = sent.items.first else {
            return XCTFail("Expected the mapped record to be saved")
        }
        XCTAssertEqual(snapshotText(snapshot), "maps")
        XCTAssertEqual(sent.items.last, .failed(unmappable, .invalidRecord))
    }

    func testFetchedEncryptedDataResetDeletesTheZoneAndBlocksOutboundAtOnce() async throws {
        let fixture = makeFixture(zoneNames: ["reset", "missing"])
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        let (resetZone, missingZone) = (fixture.zones[0], fixture.zones[1])
        let queued = fixture.recordID("queued")
        try await transport.scheduleAutomaticSync(
            CloudOutboundBatch(operations: [.save(makeDraft(queued, "queued"))])
        )

        await transport.emit(
            .willFetchChanges,
            .didFetchRecordZoneChanges(
                zoneID: CloudKitRecordMapper.zoneID(for: missingZone), error: ckError(.zoneNotFound)
            ),
            from: engine
        )
        XCTAssertEqual(
            engine.pendingRecordZoneChanges,
            [.saveRecord(CloudKitRecordMapper.recordID(for: queued))],
            "A missing zone leaves outbound work queued"
        )
        await transport.emit(
            .didFetchRecordZoneChanges(
                zoneID: CloudKitRecordMapper.zoneID(for: resetZone), error: encryptedDataResetError()
            ),
            from: engine
        )
        XCTAssertTrue(engine.pendingRecordZoneChanges.isEmpty, "A reset withdraws outbound work before the cycle ends")

        await transport.emit(.didFetchChanges, from: engine)
        let head = await transport.headEvent()
        let batch = try XCTUnwrap(head?.fetchedBatch)
        XCTAssertEqual(batch.databaseEvents, [.zoneDeleted(resetZone, reason: .encryptedDataReset)])
        XCTAssertEqual(batch.zoneEvents, [.failed(missingZone, .zoneMissing)])
        XCTAssertTrue(batch.items.isEmpty)
        XCTAssertTrue(batch.isInitialFetch)
    }

    func testSentEncryptedDataResetAddsAZoneDeletionWhereOtherFailuresStayFailures() async throws {
        let fixture = makeFixture(zoneNames: ["reset", "missing"])
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        await transport.emit(
            .willFetchChanges, fixture.zoneFetched(0), fixture.zoneFetched(1), .didFetchChanges,
            from: engine
        )
        try await transport.confirmAllEvents()
        let (resetZone, missingZone) = (fixture.zones[0], fixture.zones[1])
        let inReset = CloudRecordID(zone: resetZone, name: "in-reset-zone")
        let inMissing = CloudRecordID(zone: missingZone, name: "in-missing-zone")
        try await transport.scheduleAutomaticSync(CloudOutboundBatch(operations: [
            .save(makeDraft(inReset, "reset")), .save(makeDraft(inMissing, "missing")),
        ]))
        await transport.emit(.willSendChanges, from: engine)
        let provided = await transport.nextRecordZoneChangeBatch(scope: .all, from: engine)
        XCTAssertEqual(provided?.recordsToSave.count, 2)

        await transport.emit(
            .sentDatabaseChanges(
                savedZones: [],
                failedZoneSaves: [
                    (zoneID: CloudKitRecordMapper.zoneID(for: resetZone), error: encryptedDataResetError()),
                    (zoneID: CloudKitRecordMapper.zoneID(for: missingZone), error: ckError(.zoneNotFound)),
                ],
                failedZoneDeletes: [],
                deletedZoneIDs: []
            ),
            .sentRecordZoneChanges(
                savedRecords: [],
                deletedRecordIDs: [],
                failedRecordSaves: [
                    (recordID: CloudKitRecordMapper.recordID(for: inReset), error: encryptedDataResetError()),
                    (recordID: CloudKitRecordMapper.recordID(for: inMissing), error: ckError(.zoneNotFound)),
                ],
                failedRecordDeletes: []
            ),
            .didSendChanges,
            from: engine
        )

        let head = await transport.headEvent()
        let sent = try XCTUnwrap(head?.sentBatch)
        // The failed zone save and the failed record save each report the reset.
        XCTAssertEqual(sent.databaseEvents, [
            .zoneDeleted(resetZone, reason: .encryptedDataReset),
            .failed(missingZone, .zoneMissing),
            .zoneDeleted(resetZone, reason: .encryptedDataReset),
        ])
        XCTAssertTrue(sent.zoneEvents.isEmpty)
        XCTAssertEqual(sent.items, [.failed(inReset, .zoneMissing), .failed(inMissing, .zoneMissing)])
    }

    // MARK: Reset

    func testResetReleasesTransfersWaitingForACycle() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        let reachedEngine = expectation(description: "A waiting transfer reached CloudKit")
        reachedEngine.isInverted = true
        engine.onFetch { _, _ in reachedEngine.fulfill() }
        engine.onSend { _, _ in reachedEngine.fulfill() }
        await transport.emit(.willFetchChanges, from: engine)

        let waitingFetch = Task { try await transport.fetch(scope: .all) }
        let waitingSend = Task { try await transport.send(CloudOutboundBatch(operations: [])) }
        await fulfillment(of: [reachedEngine], timeout: 0.2)
        await transport.reset()

        await assertTransportError(.notStarted) { try await value(of: waitingFetch) }
        await assertTransportError(.notStarted) { try await value(of: waitingSend) }
        XCTAssertTrue(engine.fetchOptions.isEmpty)
        XCTAssertTrue(engine.sendOptions.isEmpty)
    }

    func testResetClearsQueuedEventsAndRequiresTheFirstFetchAgain() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let engine = try fixture.engine(0)
        await transport.emit(
            .accountChange, .willFetchChanges, fixture.zoneFetched(0), .didFetchChanges,
            from: engine
        )
        let queued = await transport.headEvent()
        XCTAssertEqual(queued?.isAccountChange, true)

        await transport.reset()
        let afterReset = await transport.headEvent()
        XCTAssertNil(afterReset)

        try await transport.start(state: nil)
        let afterRestart = await transport.headEvent()
        XCTAssertNil(afterRestart)
        let fetched = try await transport.fetch(scope: .all)
        XCTAssertTrue(fetched.isInitialFetch)
    }

    func testResetDuringAnExplicitFetchFailsItWithoutBlockingTheRestartedEngine() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let old = try fixture.engine(0)
        let zone = fixture.zoneFetched(0)
        let staleGate = AsyncOpenGate()
        let freshGate = AsyncOpenGate()
        defer {
            staleGate.open()
            freshGate.open()
        }
        let staleEntered = expectation(description: "Fetch entered the old engine")
        old.onFetch { engine, _ in
            staleEntered.fulfill()
            await staleGate.wait()
            await transport.emit(.willFetchChanges, zone, .didFetchChanges, from: engine)
        }

        let stale = Task { try await transport.fetch(scope: .all) }
        await fulfillment(of: [staleEntered], timeout: 2)
        await transport.reset()
        try await transport.start(state: nil)
        let current = try fixture.engine(1)
        let freshEntered = expectation(description: "Fetch entered the restarted engine")
        current.onFetch { engine, _ in
            freshEntered.fulfill()
            await freshGate.wait()
            await transport.emit(.willFetchChanges, zone, .didFetchChanges, from: engine)
        }
        let freshFetch = Task { try await transport.fetch(scope: .all) }
        await fulfillment(of: [freshEntered], timeout: 2)

        // The stale fetch finishes while the restarted engine's fetch is still running.
        staleGate.open()
        await assertTransportError(.notStarted) { try await value(of: stale) }
        await assertTransportError(.syncAlreadyRunning) {
            try await transport.send(CloudOutboundBatch(operations: []))
        }

        freshGate.open()
        let fresh = try await value(of: freshFetch)
        XCTAssertTrue(fresh.isInitialFetch)
        let events = try await transport.confirmAllEvents()
        XCTAssertEqual(events.map(\.id), [fresh.id])
    }

    func testResetDuringAnExplicitSendFailsItWithoutBlockingTheRestartedEngine() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        try await transport.start(state: nil)
        let old = try fixture.engine(0)
        let zone = fixture.zoneFetched(0)
        let staleGate = AsyncOpenGate()
        let freshGate = AsyncOpenGate()
        defer {
            staleGate.open()
            freshGate.open()
        }
        let staleEntered = expectation(description: "Send entered the old engine")
        old.onSend { engine, _ in
            staleEntered.fulfill()
            await staleGate.wait()
            await transport.emit(.willSendChanges, .didSendChanges, from: engine)
        }

        let staleID = fixture.recordID("stale")
        let stale = Task {
            try await transport.send(CloudOutboundBatch(operations: [.save(makeDraft(staleID, "old engine"))]))
        }
        await fulfillment(of: [staleEntered], timeout: 2)
        await transport.reset()
        try await transport.start(state: nil)
        let current = try fixture.engine(1)
        current.onFetch { engine, _ in
            await transport.emit(.willFetchChanges, zone, .didFetchChanges, from: engine)
        }
        let freshEntered = expectation(description: "Send entered the restarted engine")
        current.onSend { engine, options in
            freshEntered.fulfill()
            await freshGate.wait()
            await transport.emit(.willSendChanges, from: engine)
            let batch = await transport.nextRecordZoneChangeBatch(scope: options.scope, from: engine)
            await transport.emit(sentRecords(batch?.recordsToSave ?? []), .didSendChanges, from: engine)
        }
        let initial = try await value(of: Task { try await transport.fetch(scope: .all) })
        try await transport.confirmApplied(initial.id)
        let freshID = fixture.recordID("fresh")
        let freshSend = Task {
            try await transport.send(CloudOutboundBatch(operations: [.save(makeDraft(freshID, "new engine"))]))
        }
        await fulfillment(of: [freshEntered], timeout: 2)

        // The stale send finishes while the restarted engine's send is still running.
        staleGate.open()
        await assertTransportError(.notStarted) { try await value(of: stale) }
        await assertTransportError(.syncAlreadyRunning) { try await transport.fetch(scope: .all) }

        freshGate.open()
        let fresh = try await value(of: freshSend)
        XCTAssertEqual(fresh.items.map(\.id), [freshID])
        let events = try await transport.confirmAllEvents()
        XCTAssertEqual(events.map(\.id), [fresh.id], "The old engine's late cycle queues nothing")
        let later = try await transport.fetch(scope: .all)
        XCTAssertFalse(later.isInitialFetch)
    }

    func testResetWhileTheProviderWaitsOnItsSendGateSuppliesNothingToTheNewEngine() async throws {
        let fixture = makeFixture()
        let transport = fixture.transport
        let gate = AsyncOpenGate()
        defer { gate.open() }
        let reachedGate = expectation(description: "The old engine's provider reached the send gate")
        // The gate belongs to the transport, so the new engine's provider passes it too.
        reachedGate.assertForOverFulfill = false
        await transport.configureAutomaticSync(workAvailableHandler: {}, recordSendGate: {
            reachedGate.fulfill()
            await gate.wait()
        })
        try await transport.start(state: nil)
        let old = try fixture.engine(0)
        let zone = fixture.zoneFetched(0)
        // Both engines queue the same record, so a stale supply would count in the new cycle.
        let id = fixture.recordID("shared")
        await transport.emit(.willFetchChanges, zone, .didFetchChanges, from: old)
        try await transport.confirmAllEvents()
        try await transport.scheduleAutomaticSync(
            CloudOutboundBatch(operations: [.save(makeDraft(id, "old body"))])
        )
        await transport.emit(.willSendChanges, from: old)
        let stale = Task { () async throws -> CKSyncEngine.RecordZoneChangeBatch? in
            await transport.nextRecordZoneChangeBatch(scope: .all, from: old)
        }
        await fulfillment(of: [reachedGate], timeout: 2)

        await transport.reset()
        try await transport.start(state: nil)
        let current = try fixture.engine(1)
        await transport.emit(.willFetchChanges, zone, .didFetchChanges, from: current)
        try await transport.confirmAllEvents()
        try await transport.scheduleAutomaticSync(
            CloudOutboundBatch(operations: [.save(makeDraft(id, "new body"))])
        )
        await transport.emit(.willSendChanges, from: current)
        gate.open()
        let fromOld = try await value(of: stale)
        XCTAssertNil(fromOld)

        await transport.emit(.didSendChanges, from: current)
        let unsupplied = await transport.headEvent()
        XCTAssertTrue(try XCTUnwrap(unsupplied?.sentBatch).items.isEmpty, "The stale provider supplied nothing")
        try await transport.confirmAllEvents()

        await transport.emit(.willSendChanges, from: current)
        let fromCurrent = await transport.nextRecordZoneChangeBatch(scope: .all, from: current)
        XCTAssertEqual(fromCurrent?.recordsToSave.map(\.recordID), [CloudKitRecordMapper.recordID(for: id)])
        await transport.emit(sentRecords(fromCurrent?.recordsToSave ?? []), .didSendChanges, from: current)
        let head = await transport.headEvent()
        let sent = try XCTUnwrap(head?.sentBatch)
        guard sent.items.count == 1, case .saved(let snapshot)? = sent.items.first else {
            return XCTFail("Expected the new engine to save only its own record")
        }
        XCTAssertEqual(snapshotText(snapshot), "new body")
    }

    // MARK: Helpers

    private func value<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
        let finished = expectation(description: "Transfer finished")
        let outcome = Mutex<Result<T, any Error>?>(nil)
        Task {
            let result = await task.result
            outcome.withLock { $0 = result }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        guard let result = outcome.withLock({ $0 }) else { throw TransferTimeout() }
        return try result.get()
    }

    private func assertTransportError<T>(
        _ expected: CloudTransportError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CloudTransportError, expected, file: file, line: line)
        }
    }
}

// MARK: - Scripted engine

/// Stands in for CKSyncEngine: keeps pending changes like CKSyncEngine.State, records the
/// options of each call, and runs each test's script for fetch and send calls.
private final class ScriptedRecordEngine: CloudKitRecordEngine, @unchecked Sendable {
    typealias FetchScript = @Sendable (ScriptedRecordEngine, CKSyncEngine.FetchChangesOptions) async throws -> Void
    typealias SendScript = @Sendable (ScriptedRecordEngine, CKSyncEngine.SendChangesOptions) async throws -> Void

    private let lock = NSLock()
    private var recordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []
    private var databaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
    private var fetches: [CKSyncEngine.FetchChangesOptions] = []
    private var sends: [CKSyncEngine.SendChangesOptions] = []
    private var fetchScript: FetchScript?
    private var sendScript: SendScript?

    var fetchOptions: [CKSyncEngine.FetchChangesOptions] { lock.withLock { fetches } }
    var sendOptions: [CKSyncEngine.SendChangesOptions] { lock.withLock { sends } }

    func onFetch(_ script: @escaping FetchScript) {
        lock.withLock { fetchScript = script }
    }

    func onSend(_ script: @escaping SendScript) {
        lock.withLock { sendScript = script }
    }

    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {
        let script = lock.withLock { () -> FetchScript? in
            fetches.append(options)
            return fetchScript
        }
        try await script?(self, options)
    }

    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
        let script = lock.withLock { () -> SendScript? in
            sends.append(options)
            return sendScript
        }
        try await script?(self, options)
    }

    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] {
        lock.withLock { recordZoneChanges }
    }

    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] {
        lock.withLock { databaseChanges }
    }

    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        lock.withLock {
            for change in changes where !recordZoneChanges.contains(change) {
                recordZoneChanges.append(change)
            }
        }
    }

    func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        lock.withLock { recordZoneChanges.removeAll { changes.contains($0) } }
    }

    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        lock.withLock {
            for change in changes where !databaseChanges.contains(change) {
                databaseChanges.append(change)
            }
        }
    }

    func remove(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        lock.withLock { databaseChanges.removeAll { changes.contains($0) } }
    }
}

/// Makes a new scripted engine for each transport start and records what it was given.
private final class ScriptedEngineFactory: @unchecked Sendable {
    struct Call {
        let receivedEngineState: Bool
        let automaticallySync: Bool
        let engine: ScriptedRecordEngine
    }

    private let lock = NSLock()
    private var made: [Call] = []

    var calls: [Call] { lock.withLock { made } }

    func make(
        serialization: CKSyncEngine.State.Serialization?,
        automaticallySync: Bool
    ) -> ScriptedRecordEngine {
        let engine = ScriptedRecordEngine()
        let call = Call(
            receivedEngineState: serialization != nil,
            automaticallySync: automaticallySync,
            engine: engine
        )
        lock.withLock { made.append(call) }
        return engine
    }
}

private struct TransportFixture {
    let namespace: CloudSyncNamespace
    let zones: [CloudZoneID]
    let factory: ScriptedEngineFactory
    let transport: CloudKitRecordTransport

    var otherNamespace: CloudSyncNamespace {
        CloudSyncNamespace(
            cloudScope: namespace.cloudScope,
            accountLineage: "another-account",
            generation: namespace.generation,
            zones: namespace.zones
        )
    }

    func engine(_ index: Int) throws -> ScriptedRecordEngine {
        let calls = factory.calls
        return try XCTUnwrap(
            calls.indices.contains(index) ? calls[index].engine : nil,
            "The transport made no engine \(index)"
        )
    }

    func recordID(_ name: String) -> CloudRecordID {
        CloudRecordID(zone: zones[0], name: name)
    }

    func zoneFetched(_ index: Int) -> CloudKitRecordEngineEvent {
        .didFetchRecordZoneChanges(zoneID: CloudKitRecordMapper.zoneID(for: zones[index]), error: nil)
    }
}

private func makeFixture(
    zoneNames: [String] = ["records"],
    automaticZoneNames: [String]? = nil
) -> TransportFixture {
    let zones = zoneNames.map { CloudZoneID(name: $0, ownerName: "owner") }
    let namespace = CloudSyncNamespace(
        cloudScope: "lifecycle-test",
        accountLineage: "account-a",
        generation: UUID(),
        zones: Set(zones)
    )
    let factory = ScriptedEngineFactory()
    let transport = CloudKitRecordTransport(
        namespace: namespace,
        automaticallyFetchedZones: automaticZoneNames.map { names in
            Set(names.map { CloudZoneID(name: $0, ownerName: "owner") })
        },
        diagnostics: AppDiagnosticRecorder(record: { _ in }),
        readRecords: { _, _ in [:] },
        makeEngine: { serialization, automaticallySync, _ in
            factory.make(serialization: serialization, automaticallySync: automaticallySync)
        }
    )
    return TransportFixture(namespace: namespace, zones: zones, factory: factory, transport: transport)
}

private extension CloudKitRecordTransport {
    /// Reaches the transport's own method; async callers bind to CloudRecordTransport's nil default.
    func headEvent() -> CloudRecordTransportEvent? {
        pendingEvent()
    }

    /// Reaches the transport's own method; async callers bind to a default that drops the admission.
    func startEngine(
        state: CloudEngineStateEnvelope?,
        initialOutbound: CloudOutboundBatch?,
        outboundAdmission: CloudRecordOutboundAdmission
    ) throws {
        try start(state: state, initialOutbound: initialOutbound, outboundAdmission: outboundAdmission)
    }

    /// The zones the delegate gives CloudKit's next automatic fetch.
    func nextFetchZones() -> Set<CloudZoneID>? {
        fetchedZones(in: nextFetchChangesOptions().scope)
    }

    func emit(_ events: CloudKitRecordEngineEvent..., from engine: any CloudKitRecordEngine) {
        for event in events {
            handle(event, from: engine)
        }
    }

    /// Confirms queued events in order, the way the record module applies them.
    @discardableResult
    func confirmAllEvents() async throws -> [CloudRecordTransportEvent] {
        var confirmed: [CloudRecordTransportEvent] = []
        while let event = headEvent(), confirmed.count < 32 {
            try await confirmApplied(event.id)
            confirmed.append(event)
        }
        return confirmed
    }
}

private extension CloudRecordTransportEvent {
    var fetchedBatch: CloudFetchedBatch? {
        guard case .batch(let pending) = self, case .fetched(let batch) = pending.batch else { return nil }
        return batch
    }

    var sentBatch: CloudSentBatch? {
        guard case .batch(let pending) = self, case .sent(let batch) = pending.batch else { return nil }
        return batch
    }

    var checkpointState: CloudEngineStateEnvelope? {
        guard case .checkpoint(_, let state) = self else { return nil }
        return state
    }

    var isAccountChange: Bool {
        guard case .accountChange = self else { return false }
        return true
    }
}

/// Holds a scripted CloudKit call open until the test opens the gate.
private final class AsyncOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            let pending = waiters
            waiters = []
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

private struct TransferTimeout: Error {}

private func makeDraft(_ id: CloudRecordID, _ text: String) -> CloudRecordDraft {
    .text(id: id, snipID: UUID(), text: text)
}

/// The mapper rejects a draft that removes routing fields.
private func makeUnmappableDraft(_ id: CloudRecordID) -> CloudRecordDraft {
    let draft = makeDraft(id, "unmappable")
    return CloudRecordDraft(
        id: draft.id,
        recordType: draft.recordType,
        schemaVersion: draft.schemaVersion,
        routingFields: draft.routingFields,
        encryptedFields: draft.encryptedFields,
        removedRoutingFields: ["snipID"]
    )
}

private func makeCKRecord(_ id: CloudRecordID, _ text: String) throws -> CKRecord {
    try CloudKitRecordMapper.record(for: makeDraft(id, text))
}

private func snapshotText(_ snapshot: CloudRecordSnapshot) -> String? {
    guard case .string(let text)? = snapshot.encryptedFields["text"] else { return nil }
    return text
}

private func sentRecords(_ records: [CKRecord]) -> CloudKitRecordEngineEvent {
    .sentRecordZoneChanges(
        savedRecords: records, deletedRecordIDs: [], failedRecordSaves: [], failedRecordDeletes: []
    )
}

private func ckError(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> CKError {
    CKError(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo))
}

private func encryptedDataResetError() -> CKError {
    ckError(.zoneNotFound, userInfo: [CKErrorUserDidResetEncryptedDataKey: true])
}

private func fetchedZones(in scope: CKSyncEngine.FetchChangesOptions.Scope) -> Set<CloudZoneID>? {
    guard case .zoneIDs(let zoneIDs) = scope else { return nil }
    return Set(zoneIDs.map { CloudKitRecordMapper.id(for: $0) })
}
