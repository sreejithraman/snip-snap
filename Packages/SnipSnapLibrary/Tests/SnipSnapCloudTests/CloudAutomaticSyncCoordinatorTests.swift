import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

final class CloudAutomaticSyncCoordinatorTests: XCTestCase {
  func testAutomaticApplyChecksTheActiveAccountBeforeRecoveringAStagedBatch() async throws {
    let stagedID = UUID()
    let store = AutomaticSyncStoreProbe(stagedBatchID: stagedID)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    do {
      try await transport.deliverAutomatically(
        .fetched(emptyFetchedBatch()),
        to: coordinator,
        beforeApply: { throw AutomaticSyncTestError.accountChanged }
      )
      XCTFail("Expected the account gate to stop the apply")
    } catch AutomaticSyncTestError.accountChanged {}

    let applied = await store.appliedBatchIDs()
    let confirmed = await transport.confirmedBatchIDs()
    XCTAssertEqual(applied, [])
    XCTAssertEqual(confirmed, [])
  }

  func testAutomaticApplyDoesNotRecoverItsOwnTransportPendingBatch() async throws {
    let automatic = emptyFetchedBatch()
    let store = AutomaticSyncStoreProbe()
    let transport = AutomaticSyncTransportProbe(pending: .fetched(automatic))
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await transport.deliverAutomatically(
      .fetched(automatic),
      to: coordinator,
      beforeApply: {}
    )

    let applied = await store.appliedBatchIDs()
    let confirmed = await transport.confirmedBatchIDs()
    XCTAssertEqual(applied, [automatic.id])
    XCTAssertEqual(confirmed, [automatic.id])
  }

  func testExplicitSyncRecoversAnUnstagedAutomaticBatchBeforeFetching() async throws {
    let pending = CloudSentBatch(
      id: UUID(),
      items: [],
      databaseEvents: [],
      zoneEvents: [],
      engineState: nil
    )
    let store = AutomaticSyncStoreProbe()
    let transport = AutomaticSyncTransportProbe(
      pending: .sent(pending),
      pendingOutbound: CloudOutboundBatch(operations: []),
      fetched: emptyFetchedBatch()
    )
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await coordinator.fetchRemote()

    let applied = await store.appliedBatchIDs()
    let confirmed = await transport.confirmedBatchIDs()
    let fetchCount = await transport.fetchCount()
    XCTAssertEqual(applied.first, pending.id)
    XCTAssertEqual(confirmed.first, pending.id)
    XCTAssertEqual(fetchCount, 1)
  }

  func testExplicitSyncRecoversEveryBufferedAutomaticCycleBeforeFetching() async throws {
    let first = emptyFetchedBatch()
    let second = emptyFetchedBatch()
    let store = AutomaticSyncStoreProbe()
    let transport = AutomaticSyncTransportProbe(
      pending: .fetched(first),
      pendingAfterDrain: CloudPendingBatch(batch: .fetched(second), outbound: nil),
      fetched: emptyFetchedBatch()
    )
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await coordinator.fetchRemote()

    let applied = await store.appliedBatchIDs()
    let fetchCount = await transport.fetchCount()
    XCTAssertEqual(Array(applied.prefix(2)), [first.id, second.id])
    XCTAssertEqual(fetchCount, 1)
  }

  func testPreparingAutomaticSyncWaitsForAnEngineFetchBeforeSchedulingNewStoreChanges() async throws {
    let id = CloudRecordID(
      zone: CloudZoneID(name: "snips-test", ownerName: "owner"),
      name: "record"
    )
    let outbound = CloudOutboundBatch(operations: [.delete(id, base: nil)])
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await coordinator.prepareAutomaticSync()

    let startCount = await transport.startCount()
    let scheduled = await transport.scheduledBatches()
    let fetchCount = await transport.fetchCount()
    XCTAssertEqual(startCount, 1)
    XCTAssertEqual(scheduled, [])
    XCTAssertEqual(fetchCount, 0)

    try await transport.deliverAutomatically(
      .fetched(emptyFetchedBatch()), to: coordinator, beforeApply: {}
    )
    let afterFetch = await transport.scheduledBatches()
    XCTAssertEqual(afterFetch, [outbound])
  }

  func testInitialFetchWithoutACheckpointCannotUnlockOutboundWork() async throws {
    let zone = CloudZoneID(name: "snips-test", ownerName: "owner")
    let outbound = CloudOutboundBatch(operations: [.delete(CloudRecordID(zone: zone, name: "pending"), base: nil)])
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.prepareAutomaticSync()
    let fetched = CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.fetched(zone)], engineState: nil)

    try await transport.deliverAutomatically(.fetched(fetched), to: coordinator, beforeApply: {})
    let beforeCheckpoint = await transport.scheduledBatches()
    XCTAssertTrue(beforeCheckpoint.isEmpty)

    let completed = completedFetchState()
    await transport.enqueue(.checkpoint(UUID(), completed))
    try await coordinator.processAutomaticChanges()
    let scheduled = await transport.scheduledBatches()
    let saved = await store.loadEngineState()
    XCTAssertEqual(scheduled, [outbound])
    XCTAssertEqual(saved, completed)
  }

  func testPreparingAutomaticSyncRecoversStagedEngineStateBeforeStarting() async throws {
    let stagedID = UUID()
    let nextState = CloudEngineStateEnvelope(
      namespace: CloudSyncNamespace(
        cloudScope: "private",
        accountLineage: "account",
        generation: UUID(),
        zones: []
      ),
      serialization: Data("next".utf8)
    )
    let store = AutomaticSyncStoreProbe(
      stagedBatchID: stagedID,
      engineStateAfterApply: nextState
    )
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await coordinator.prepareAutomaticSync()

    let startedStates = await transport.startedEngineStates()
    XCTAssertEqual(startedStates, [nextState])
  }

  func testRestoredEngineStartsWithDurableOutboundWorkReadyForItsProvider() async throws {
    let namespace = CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "account",
      generation: UUID(),
      zones: []
    )
    let state = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("state".utf8))
    let id = CloudRecordID(zone: CloudZoneID(name: "zone", ownerName: "owner"), name: "item")
    let outbound = CloudOutboundBatch(operations: [.delete(id, base: nil)])
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound, engineState: state)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await coordinator.prepareAutomaticSync()

    let initialOutbounds = await transport.initialOutboundBatches()
    let fetchCount = await transport.fetchCount()
    XCTAssertEqual(initialOutbounds, [outbound])
    XCTAssertEqual(fetchCount, 0)
  }

  func testCorruptEngineStateIsClearedAndBootstrappedBeforeScheduling() async throws {
    let namespace = CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "account",
      generation: UUID(),
      zones: []
    )
    let state = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("bad".utf8))
    let store = AutomaticSyncStoreProbe(engineState: state)
    let transport = AutomaticSyncTransportProbe(rejectsStoredState: true)
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await coordinator.prepareAutomaticSync()

    let clearCount = await store.engineStateClearCount()
    let fetchCount = await transport.fetchCount()
    let states = await transport.startedEngineStates()
    XCTAssertEqual(clearCount, 1)
    XCTAssertEqual(fetchCount, 0)
    XCTAssertEqual(states, [state, nil])
  }

  func testFetchFailureBecomesAUserIssueAndStopsTheSameRunSend() async throws {
    let id = CloudRecordID(
      zone: CloudZoneID(name: "snips-test", ownerName: "owner"),
      name: "record"
    )
    let outbound = CloudOutboundBatch(operations: [.delete(id, base: nil)])
    let fetched = CloudFetchedBatch(
      id: UUID(),
      items: [],
      databaseEvents: [.failed(nil, .networkUnavailable)],
      engineState: nil
    )
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe(fetched: fetched)
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    let outcome = try await coordinator.sync()

    let issue = outcome.issue
    let sendCount = await transport.sendCount()
    XCTAssertEqual(issue, .waitingForConnection)
    XCTAssertEqual(sendCount, 0)
  }

  func testFailedAttachmentDoesNotStopAnUnrelatedSend() async throws {
    let id = CloudRecordID(
      zone: CloudZoneID(name: "snips-test", ownerName: "owner"),
      name: "record"
    )
    let outbound = CloudOutboundBatch(operations: [.delete(id, base: nil)])
    let fetched = CloudFetchedBatch(
      id: UUID(),
      items: [.failed(CloudRecordID(zone: id.zone, name: "failed-attachment"), .attachmentUnavailable)],
      zoneEvents: [.fetched(id.zone)],
      engineState: completedFetchState()
    )
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe(fetched: fetched, sendSucceeds: true)
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    let outcome = try await coordinator.sync()

    let issue = outcome.issue
    let sendCount = await transport.sendCount()
    XCTAssertEqual(issue, .attachmentUnavailable)
    XCTAssertEqual(sendCount, 1)
  }

  func testExpiredChangeTokenClearsStateAndRefetchesBeforeSending() async throws {
    let zone = CloudZoneID(name: "snips-test", ownerName: "owner")
    let id = CloudRecordID(zone: zone, name: "record")
    let outbound = CloudOutboundBatch(operations: [.delete(id, base: nil)])
    let expired = CloudFetchedBatch(
      id: UUID(),
      items: [],
      zoneEvents: [.failed(zone, .changeTokenExpired)],
      engineState: nil
    )
    let clean = emptyFetchedBatch()
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe(
      fetched: expired,
      fetchedAfterReset: clean,
      sendSucceeds: true
    )
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    let outcome = try await coordinator.sync()

    let clearCount = await store.engineStateClearCount()
    let fetchCount = await transport.fetchCount()
    let resetCount = await transport.resetCount()
    let sendCount = await transport.sendCount()
    let issue = outcome.issue
    XCTAssertEqual(clearCount, 1)
    XCTAssertEqual(fetchCount, 2)
    XCTAssertEqual(resetCount, 1)
    XCTAssertEqual(sendCount, 1)
    XCTAssertNil(issue)
  }

  func testAutomaticExpiredTokenRestartsTheEngineWithoutFetchingInsideItsCallback() async throws {
    let zone = CloudZoneID(name: "snips-test", ownerName: "owner")
    let outbound = CloudOutboundBatch(operations: [.delete(
      CloudRecordID(zone: zone, name: "pending"), base: nil
    )])
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.prepareAutomaticSync()
    let expired = CloudFetchedBatch(
      id: UUID(), items: [], zoneEvents: [.failed(zone, .changeTokenExpired)], engineState: nil
    )

    try await transport.deliverAutomatically(.fetched(expired), to: coordinator, beforeApply: {})

    let fetches = await transport.fetchCount()
    let resets = await transport.resetCount()
    let scheduledBeforeFreshFetch = await transport.scheduledBatches()
    XCTAssertEqual(fetches, 0)
    XCTAssertEqual(resets, 1)
    XCTAssertTrue(scheduledBeforeFreshFetch.isEmpty)

    try await transport.deliverAutomatically(
      .fetched(emptyFetchedBatch()), to: coordinator, beforeApply: {}
    )
    let scheduled = await transport.scheduledBatches()
    XCTAssertEqual(scheduled, [outbound])
  }

  func testAutomaticMergeReschedulesChangesCreatedByTheCommit() async throws {
    let id = CloudRecordID(
      zone: CloudZoneID(name: "snips-test", ownerName: "owner"),
      name: "conflicted-record"
    )
    let outbound = CloudOutboundBatch(operations: [.delete(id, base: nil)])
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await transport.deliverAutomatically(
      .fetched(emptyFetchedBatch()),
      to: coordinator,
      beforeApply: {}
    )

    let scheduled = await transport.scheduledBatches()
    XCTAssertEqual(scheduled, [outbound])
  }

  func testSchedulingRecoversTheFirstFetchAndStartsPendingUploadsWithoutAnotherFetch() async throws {
    let zone = CloudZoneID(name: "snips-test", ownerName: "owner")
    let outbound = CloudOutboundBatch(operations: [.delete(
      CloudRecordID(zone: zone, name: "pending"), base: nil
    )])
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.prepareAutomaticSync()
    let fetched = emptyFetchedBatch()
    await transport.setPending(.fetched(fetched))

    try await coordinator.prepareAutomaticSync()
    _ = try await coordinator.processAutomaticChanges()

    let scheduled = await transport.scheduledBatches()
    let applied = await store.appliedBatchIDs()
    let fetches = await transport.fetchCount()
    XCTAssertEqual(scheduled, [outbound])
    XCTAssertEqual(applied, [fetched.id])
    XCTAssertEqual(fetches, 0)
  }

  func testSchedulingWaitsForAnAutomaticBatchToCommitInsteadOfReportingBusy() async throws {
    let pause = AutomaticSyncPause()
    let batch = emptyFetchedBatch()
    let store = AutomaticSyncStoreProbe()
    let transport = AutomaticSyncTransportProbe(pending: .fetched(batch))
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    let applying = Task {
      try await transport.deliverAutomatically(
        .fetched(batch), to: coordinator, beforeApply: { await pause.suspend() }
      )
    }
    await pause.waitUntilSuspended()
    let finished = expectation(description: "Scheduling waits for the batch commit")
    finished.isInverted = true
    let scheduling = Task {
      defer { finished.fulfill() }
      try await coordinator.prepareAutomaticSync()
    }
    await fulfillment(of: [finished], timeout: 0.02)
    await pause.resume()
    _ = try await applying.value
    try await scheduling.value

    let applied = await store.appliedBatchIDs()
    let confirmed = await transport.confirmedBatchIDs()
    XCTAssertEqual(applied, [batch.id])
    XCTAssertEqual(confirmed, [batch.id])
  }

  func testQueuedAutomaticCallbackDoesNotReapplyABatchRecoveredByScheduling() async throws {
    let pause = AutomaticSyncPause()
    let batch = emptyFetchedBatch()
    let store = AutomaticSyncStoreProbe(beforeLoad: { await pause.suspend() })
    let transport = AutomaticSyncTransportProbe(pending: .fetched(batch))
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    let preparing = Task { try await coordinator.prepareAutomaticSync() }
    await pause.waitUntilSuspended()
    let finished = expectation(description: "The callback waits for scheduling")
    finished.isInverted = true
    let applying = Task {
      defer { finished.fulfill() }
      return try await coordinator.processAutomaticChanges()
    }
    await fulfillment(of: [finished], timeout: 0.02)
    await pause.resume()
    _ = try await preparing.value
    _ = try await applying.value

    let applied = await store.appliedBatchIDs()
    let confirmed = await transport.confirmedBatchIDs()
    XCTAssertEqual(applied, [batch.id])
    XCTAssertEqual(confirmed, [batch.id])
  }

  func testRestartBeforeInitialFetchCommitsDoesNotScheduleDurableOutboundChanges() async throws {
    let zone = CloudZoneID(name: "snips-test", ownerName: "owner")
    let namespace = CloudSyncNamespace(
      cloudScope: "private", accountLineage: "account", generation: UUID(), zones: [zone]
    )
    let earlyState = CloudEngineStateEnvelope(
      namespace: namespace, serialization: Data("early-state".utf8), requiresInitialFetch: true
    )
    let outbound = CloudOutboundBatch(operations: [.delete(
      CloudRecordID(zone: zone, name: "pending"), base: nil
    )])
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let originalTransport = AutomaticSyncTransportProbe()
    let original = CloudFullSyncCoordinator(store: store, transport: originalTransport)
    try await original.prepareAutomaticSync()
    await originalTransport.enqueue(.checkpoint(UUID(), earlyState))
    try await original.processAutomaticChanges()
    let saved = await store.loadEngineState()
    let persisted = try JSONDecoder().decode(
      CloudEngineStateEnvelope.self, from: JSONEncoder().encode(try XCTUnwrap(saved))
    )
    XCTAssertTrue(persisted.requiresInitialFetch)
    let resumedTransport = AutomaticSyncTransportProbe()
    let resumed = CloudFullSyncCoordinator(store: store, transport: resumedTransport)

    try await resumed.prepareAutomaticSync()
    try await resumed.prepareAutomaticSync()

    let initial = await resumedTransport.initialOutboundBatches()
    let scheduled = await resumedTransport.scheduledBatches()
    let fetches = await resumedTransport.fetchCount()
    XCTAssertEqual(initial, [nil])
    XCTAssertTrue(scheduled.isEmpty)
    XCTAssertEqual(fetches, 0)

    try await resumedTransport.deliverAutomatically(.fetched(emptyFetchedBatch()), to: resumed, beforeApply: {})
    let afterFetch = await resumedTransport.scheduledBatches()
    XCTAssertEqual(afterFetch, [outbound])
  }

  func testDelayedStateFromReplacedEngineCannotOverwriteTheFreshFetchState() async throws {
    let zone = CloudZoneID(name: "snips-test", ownerName: "owner")
    let namespace = CloudSyncNamespace(
      cloudScope: "private", accountLineage: "account", generation: UUID(), zones: [zone]
    )
    let oldState = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("old".utf8))
    let freshState = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("fresh".utf8))
    let store = AutomaticSyncStoreProbe(engineState: oldState)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.prepareAutomaticSync()
    let deliverOldState = { try await coordinator.processAutomaticChanges() }
    let expired = CloudFetchedBatch(
      id: UUID(), items: [], zoneEvents: [.failed(zone, .changeTokenExpired)], engineState: oldState
    )
    try await transport.deliverAutomatically(.fetched(expired), to: coordinator, beforeApply: {})
    let fresh = CloudFetchedBatch(
      id: UUID(), items: [], zoneEvents: [.fetched(zone)], engineState: freshState
    )
    try await transport.deliverAutomatically(.fetched(fresh), to: coordinator, beforeApply: {})

    _ = try await deliverOldState()

    let saved = await store.loadEngineState()
    XCTAssertEqual(saved, freshState)
  }

  func testEngineStateSavesLocallyWithoutStartingANetworkCycle() async throws {
    let namespace = CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "account",
      generation: UUID(),
      zones: []
    )
    let state = CloudEngineStateEnvelope(
      namespace: namespace,
      serialization: Data("state".utf8)
    )
    let store = AutomaticSyncStoreProbe()
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    await transport.enqueue(.checkpoint(UUID(), state))
    try await coordinator.processAutomaticChanges()

    let saved = await store.loadEngineState()
    let fetchCount = await transport.fetchCount()
    XCTAssertEqual(saved, state)
    XCTAssertEqual(fetchCount, 0)
  }

  func testMailboxKeepsLaterFetchedRecordsAheadOfTheirCheckpointWhileApplyWaits() async throws {
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [])
    let old = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("old".utf8))
    let newest = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("newest".utf8))
    let store = AutomaticSyncStoreProbe(engineState: old)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.prepareAutomaticSync()
    let pause = AutomaticSyncPause()
    let finished = expectation(description: "The ordered mailbox drains")
    await transport.setWorkAvailable {
      _ = try? await coordinator.processAutomaticChanges(beforeApply: { await pause.suspend() })
      finished.fulfill()
    }
    let first = emptyFetchedBatch()
    let later = emptyFetchedBatch()
    let checkpointID = UUID()
    await transport.enqueue(.batch(CloudPendingBatch(batch: .fetched(first), outbound: nil)))
    await pause.waitUntilSuspended()

    // These return while the consumer waits. This is the same mailbox used by the CK delegate.
    await transport.enqueue(.batch(CloudPendingBatch(batch: .fetched(later), outbound: nil)))
    await transport.enqueue(.checkpoint(checkpointID, newest))
    let beforeCommit = await store.loadEngineState()
    XCTAssertEqual(beforeCommit, old)
    await pause.resume()
    await fulfillment(of: [finished], timeout: 2)

    let applied = await store.appliedBatchIDs()
    let confirmed = await transport.confirmedBatchIDs()
    let saved = await store.loadEngineState()
    XCTAssertEqual(applied, [first.id, later.id])
    XCTAssertEqual(confirmed, [first.id, later.id, checkpointID])
    XCTAssertEqual(saved, newest)
  }

  func testExplicitRefreshDrainsAnActiveAutomaticCycleWithoutBlockingItsCheckpointProducer() async throws {
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [])
    let checkpoint = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("during-fetch".utf8))
    let store = AutomaticSyncStoreProbe(engineState: checkpoint)
    let transport = AutomaticSyncTransportProbe(fetched: emptyFetchedBatch())
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.prepareAutomaticSync()
    await transport.setWorkAvailable { _ = try? await coordinator.processAutomaticChanges() }
    await transport.setFetchCheckpoint(checkpoint)
    let activeCycle = AutomaticSyncPause()
    await transport.pauseCurrentCycle(activeCycle)
    let finished = expectation(description: "Explicit refresh completes")
    let failures = AutomaticSyncFailureRecorder()
    Task {
      do { try await coordinator.fetchRemote() }
      catch { await failures.record(error) }
      finished.fulfill()
    }
    await activeCycle.waitUntilSuspended()
    let automatic = emptyFetchedBatch()
    await transport.enqueue(.batch(CloudPendingBatch(batch: .fetched(automatic), outbound: nil)))
    await activeCycle.resume()
    await fulfillment(of: [finished], timeout: 2)

    let errors = await failures.messages()
    let applied = await store.appliedBatchIDs()
    let fetchCount = await transport.fetchCount()
    XCTAssertTrue(errors.isEmpty)
    XCTAssertEqual(applied.first, automatic.id)
    XCTAssertEqual(applied.count, 2)
    XCTAssertEqual(fetchCount, 1)
  }

  func testOlderSuccessCannotClearOrPublishAfterANewerFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrderedCloudOutcome-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [zone])
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let transport = AutomaticSyncTransportProbe()
    let pause = AutomaticSyncPause()
    let reports = AutomaticSyncReports()
    let failureReported = expectation(description: "Newer failure reaches the user")
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport) { result in
      await reports.append(result)
      if await reports.takePause() { await pause.suspend() }
      if result == .syncIssue(.waitingForConnection) { failureReported.fulfill() }
    }
    try await coordinator.prepareAutomaticSync()
    await reports.pauseNext()
    await transport.setWorkAvailable { _ = try? await coordinator.processAutomaticChanges() }
    let success = emptyFetchedBatch(namespace: namespace)
    await transport.enqueue(.batch(CloudPendingBatch(batch: .fetched(success), outbound: nil)))
    await pause.waitUntilSuspended()
    let failure = CloudFetchedBatch(id: UUID(), items: [],
      databaseEvents: [.failed(nil, .networkUnavailable)], engineState: nil)
    await transport.enqueue(.batch(CloudPendingBatch(batch: .fetched(failure), outbound: nil)))
    await pause.resume()
    await fulfillment(of: [failureReported], timeout: 2)

    let issue = try await store.unresolvedSyncIssue()
    let results = await reports.values()
    XCTAssertEqual(issue, .waitingForConnection)
    XCTAssertEqual(results.last, .syncIssue(.waitingForConnection))
  }

  func testLegacyEnvelopeDropsItsAdvancedTokenBeforeAnyOutboundWork() async throws {
    let zone = CloudZoneID(name: "metadata", ownerName: "owner")
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [zone])
    let old = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("advanced-old-token".utf8))
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    json.removeValue(forKey: "requiresInitialFetch")
    let legacy = try JSONDecoder().decode(CloudEngineStateEnvelope.self,
      from: JSONSerialization.data(withJSONObject: json))
    let outbound = CloudOutboundBatch(operations: [.delete(CloudRecordID(zone: zone, name: "local-delete"), base: nil)])
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound, engineState: legacy)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await coordinator.prepareAutomaticSync()

    let starts = await transport.startedEngineStates()
    let initial = await transport.initialOutboundBatches()
    let scheduled = await transport.scheduledBatches()
    let durablePending = await store.pendingChanges()
    XCTAssertTrue(legacy.requiresInitialFetch)
    XCTAssertEqual(starts, [nil])
    XCTAssertEqual(initial, [nil])
    XCTAssertTrue(scheduled.isEmpty)
    XCTAssertEqual(durablePending, outbound)
  }

  private func completedFetchState(namespace: CloudSyncNamespace? = nil) -> CloudEngineStateEnvelope {
    let zone = CloudZoneID(name: "snips-test", ownerName: "owner")
    return CloudEngineStateEnvelope(
      namespace: namespace ?? CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
        generation: UUID(), zones: [zone]),
      serialization: Data("completed-fetch".utf8), requiresInitialFetch: false
    )
  }

  private func emptyFetchedBatch(namespace: CloudSyncNamespace? = nil) -> CloudFetchedBatch {
    let state = completedFetchState(namespace: namespace)
    return CloudFetchedBatch(
      id: UUID(), items: [], zoneEvents: state.namespace.zones.map { .fetched($0) }, engineState: state
    )
  }
}

enum AutomaticSyncTestError: Error {
  case accountChanged
  case unsupported
}

actor AutomaticSyncStoreProbe: CloudFullSyncStore {
  private var staged: [CloudFullBatchCommit]
  private var applied: [UUID] = []
  private var outbound: CloudOutboundBatch
  private var batches: [UUID: CloudPendingBatch] = [:]
  private var fetchIssue: SyncedContentSyncIssue?
  private var sendIssue: SyncedContentSyncIssue?
  private var resetSignal: CloudZoneDeletionReason?
  private var engineState: CloudEngineStateEnvelope?
  private let engineStateAfterApply: CloudEngineStateEnvelope?
  private var clearCount = 0
  private let beforeLoad: @Sendable () async -> Void

  init(
    stagedBatchID: UUID? = nil,
    pendingChanges: CloudOutboundBatch = CloudOutboundBatch(operations: []),
    engineStateAfterApply: CloudEngineStateEnvelope? = nil,
    engineState: CloudEngineStateEnvelope? = nil,
    beforeLoad: @escaping @Sendable () async -> Void = {}
  ) {
    staged = stagedBatchID.map { [Self.commit(id: $0)] } ?? []
    outbound = pendingChanges
    self.engineState = engineState
    self.engineStateAfterApply = engineStateAfterApply
    self.beforeLoad = beforeLoad
  }

  func loadEngineState() async -> CloudEngineStateEnvelope? {
    await beforeLoad()
    return engineState
  }
  func saveEngineState(_ state: CloudEngineStateEnvelope) { engineState = state }
  func clearEngineState() {
    engineState = nil
    clearCount += 1
  }
  func stagedBatches() -> [CloudFullBatchCommit] { staged }

  func stage(_ batch: CloudSyncBatch, outbound: CloudOutboundBatch?) {
    staged.append(Self.commit(id: batch.id))
    batches[batch.id] = CloudPendingBatch(batch: batch, outbound: outbound)
  }

  func applyStaged(_ id: UUID) {
    applied.append(id)
    staged.removeAll { $0.batchID == id }
    guard let pending = batches.removeValue(forKey: id) else {
      engineState = engineStateAfterApply
      return
    }
    if let state = pending.batch.engineState { engineState = state }
    let events: [CloudDatabaseEvent]
    switch pending.batch {
    case .fetched(let fetched):
      fetchIssue = CloudSyncIssueError.issue(in: pending.batch)
      events = fetched.databaseEvents
    case .sent(let sent):
      if sent.hasResults { sendIssue = CloudSyncIssueError.issue(in: pending.batch) }
      events = sent.databaseEvents
      let acknowledged = Set(sent.items.compactMap { item -> CloudRecordID? in
        switch item {
        case .saved(let record): record.id
        case .deleted(let id): id
        default: nil
        }
      })
      outbound = CloudOutboundBatch(operations: outbound.operations.filter { !acknowledged.contains($0.id) })
    }
    for event in events {
      if case .zoneDeleted(_, let reason) = event, reason != .deleted { resetSignal = reason }
    }
  }

  func syncStatus() -> CloudFullSyncStatus {
    if resetSignal != nil { return .purged }
    if let issue = CloudSyncIssueError.preferredIssue(from: [fetchIssue, sendIssue].compactMap { $0 }) {
      return .issue(issue)
    }
    return outbound.operations.isEmpty && outbound.zonesToSave.isEmpty ? .settled : .pending
  }

  func destructiveResetSignal() -> CloudZoneDeletionReason? { resetSignal }
  func prepareManualRetry() -> Bool { false }

  func pendingChanges() -> CloudOutboundBatch {
    outbound
  }

  func appliedBatchIDs() -> [UUID] { applied }
  func engineStateClearCount() -> Int { clearCount }

  private nonisolated static func commit(id: UUID) -> CloudFullBatchCommit {
    CloudFullBatchCommit(
      namespaceKey: "test",
      batchID: id,
      expectedEngineState: nil,
      nextEngineState: nil,
      items: []
    )
  }
}

actor AutomaticSyncTransportProbe: CloudRecordTransport, CloudAutomaticSyncScheduling {
  private let mailbox = CloudRecordTransportMailbox()
  private var confirmations: [UUID] = []
  private var fetches = 0
  private var starts = 0
  private var startStates: [CloudEngineStateEnvelope?] = []
  private var scheduled: [CloudOutboundBatch] = []
  private var initialOutbounds: [CloudOutboundBatch?] = []
  private let rejectsStoredState: Bool
  private var fetchedBatches: [CloudFetchedBatch]
  private var sends = 0
  private var resets = 0
  private let sendSucceeds: Bool
  private var cyclePause: AutomaticSyncPause?
  private var fetchCheckpoint: CloudEngineStateEnvelope?

  init(
    pending: CloudSyncBatch? = nil,
    pendingOutbound: CloudOutboundBatch? = nil,
    pendingAfterDrain: CloudPendingBatch? = nil,
    rejectsStoredState: Bool = false,
    fetched: CloudFetchedBatch? = nil,
    fetchedAfterReset: CloudFetchedBatch? = nil,
    sendSucceeds: Bool = false
  ) {
    if let pending { mailbox.append(.batch(CloudPendingBatch(batch: pending, outbound: pendingOutbound))) }
    if let pendingAfterDrain { mailbox.append(.batch(pendingAfterDrain)) }
    self.rejectsStoredState = rejectsStoredState
    fetchedBatches = [fetched, fetchedAfterReset].compactMap { $0 }
    self.sendSucceeds = sendSucceeds
  }

  func start(state: CloudEngineStateEnvelope?) { starts += 1; startStates.append(state) }
  func start(state: CloudEngineStateEnvelope?, initialOutbound: CloudOutboundBatch?) throws {
    starts += 1
    startStates.append(state)
    initialOutbounds.append(initialOutbound)
    if rejectsStoredState, state != nil { throw CloudTransportError.invalidEngineState }
  }
  func scheduleAutomaticSync(_ batch: CloudOutboundBatch) { scheduled.append(batch) }
  func fetch(scope: CloudFetchScope) throws -> CloudFetchedBatch {
    fetches += 1
    if let fetchCheckpoint { enqueue(.checkpoint(UUID(), fetchCheckpoint)) }
    guard !fetchedBatches.isEmpty else { throw AutomaticSyncTestError.unsupported }
    let batch = fetchedBatches.removeFirst()
    enqueue(.batch(CloudPendingBatch(batch: .fetched(batch), outbound: nil)))
    return batch
  }
  func send(_ batch: CloudOutboundBatch) throws -> CloudSentBatch {
    sends += 1
    guard sendSucceeds else { throw AutomaticSyncTestError.unsupported }
    let items = try batch.operations.map { operation -> CloudSendItemResult in
      guard case .delete(let id, _) = operation else { throw AutomaticSyncTestError.unsupported }
      return .deleted(id)
    }
    let result = CloudSentBatch(id: UUID(), items: items, engineState: nil)
    enqueue(.batch(CloudPendingBatch(batch: .sent(result), outbound: batch)))
    return result
  }
  func reset() { resets += 1; mailbox.reset() }
  func confirmApplied(_ batchID: UUID) throws {
    _ = try mailbox.confirm(batchID)
    confirmations.append(batchID)
  }
  func pendingEvent() -> CloudRecordTransportEvent? { mailbox.first }
  func setPending(_ batch: CloudSyncBatch) { enqueue(.batch(CloudPendingBatch(batch: batch, outbound: nil))) }
  func enqueue(_ event: CloudRecordTransportEvent) { mailbox.append(event) }
  func setWorkAvailable(_ action: @escaping @Sendable () async -> Void) { mailbox.configure(workAvailable: action) }
  func setFetchCheckpoint(_ state: CloudEngineStateEnvelope) { fetchCheckpoint = state }
  func pauseCurrentCycle(_ pause: AutomaticSyncPause) { cyclePause = pause }
  func finishCurrentSyncCycle() async { await cyclePause?.suspend() }
  @discardableResult
  func deliverAutomatically(
    _ batch: CloudSyncBatch,
    to coordinator: CloudFullSyncCoordinator,
    beforeApply: @escaping @Sendable () async throws -> Void
  ) async throws -> CloudFullSyncOutcome {
    let alreadyPending = mailbox.first?.id == batch.id
    if starts == 0 { try await coordinator.prepareAutomaticSync(beforeApply: beforeApply) }
    if !alreadyPending { enqueue(.batch(CloudPendingBatch(batch: batch, outbound: nil))) }
    return try await coordinator.processAutomaticChanges(beforeApply: beforeApply)
  }
  func fetchRecord(_ id: CloudRecordID, fields: Set<String>) throws -> CloudRecordSnapshot? {
    throw AutomaticSyncTestError.unsupported
  }
  func fetchAsset(_ id: CloudRecordID, field: String, destination: CloudAssetDestination) throws -> CloudAssetReceipt? {
    throw AutomaticSyncTestError.unsupported
  }
  func confirmedBatchIDs() -> [UUID] { confirmations }
  func fetchCount() -> Int { fetches }
  func initialOutboundBatches() -> [CloudOutboundBatch?] { initialOutbounds }
  func startCount() -> Int { starts }
  func startedEngineStates() -> [CloudEngineStateEnvelope?] { startStates }
  func scheduledBatches() -> [CloudOutboundBatch] { scheduled }
  func sendCount() -> Int { sends }
  func resetCount() -> Int { resets }
}

actor AutomaticSyncPause {
  private var suspended = false
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?

  func suspend() async {
    if released { return }
    suspended = true
    waiters.forEach { $0.resume() }
    waiters = []
    await withCheckedContinuation { release = $0 }
  }
  func waitUntilSuspended() async {
    if suspended { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func resume() {
    released = true
    release?.resume()
    release = nil
  }
}

private actor AutomaticSyncFailureRecorder {
  private var values: [String] = []
  func record(_ error: any Error) { values.append(String(describing: error)) }
  func messages() -> [String] { values }
}

actor AutomaticSyncReports {
  private var results: [SnipSnapCloudSyncResult] = []
  private var shouldPause = false
  func append(_ result: SnipSnapCloudSyncResult) { results.append(result) }
  func values() -> [SnipSnapCloudSyncResult] { results }
  func pauseNext() { shouldPause = true }
  func takePause() -> Bool { defer { shouldPause = false }; return shouldPause }
}
