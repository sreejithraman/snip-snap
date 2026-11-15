import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

/// The coordinator's engine session: whether its engine runs, and whether that engine
/// (or the next one) must finish the first fetch before sending.
extension CloudFullSyncPersistenceTests {
  func testOutcomeBeforeTheFirstStartWaitsForTheInitialFetch() async throws {
    let samples = EngineSessionSamples(namespace: makeNamespace())
    let store = AutomaticSyncStoreProbe(engineState: samples.state(requiresInitialFetch: false))
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    let beforeStart = try await coordinator.processAutomaticChanges()

    let startsBefore = await transport.startCount()
    XCTAssertEqual(startsBefore, 0)
    XCTAssertTrue(beforeStart.blocksOutbound)
    XCTAssertFalse(beforeStart.settled)
    XCTAssertEqual(beforeStart.result, .syncScheduled)

    let started = try await coordinator.prepareAutomaticSync()
    let afterStart = try await coordinator.processAutomaticChanges()

    let states = await transport.startedEngineStates()
    XCTAssertEqual(states, [samples.state(requiresInitialFetch: false)])
    for outcome in [started, afterStart] {
      XCTAssertFalse(outcome.blocksOutbound)
      XCTAssertTrue(outcome.settled)
      XCTAssertEqual(outcome.result, .syncCompleted)
    }
  }

  func testStagedRecoveryBeforeTheFirstStartSetsTheInitialFetchRequirement() async throws {
    let samples = EngineSessionSamples(namespace: makeNamespace())
    for storedRequirement in [false, true, nil] as [Bool?] {
      let store = AutomaticSyncStoreProbe(stagedBatchID: UUID(),
        engineStateAfterApply: storedRequirement.map { samples.state(requiresInitialFetch: $0) })
      let transport = AutomaticSyncTransportProbe()
      let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

      let outcome = try await coordinator.processAutomaticChanges()

      let label = "stored requirement: \(String(describing: storedRequirement))"
      let waits = storedRequirement ?? true
      let applied = await store.appliedBatchIDs()
      let starts = await transport.startCount()
      XCTAssertEqual(applied.count, 1, label)
      XCTAssertEqual(starts, 0, label)
      XCTAssertEqual(outcome.blocksOutbound, waits, label)
      XCTAssertEqual(outcome.settled, !waits, label)
      XCTAssertEqual(outcome.result,
        waits ? SnipSnapCloudSyncResult.syncScheduled : .syncCompleted, label)
    }
  }

  func testStagedRecoveryWhileRunningTurnsTheInitialFetchRequirementOnAndOff() async throws {
    let samples = EngineSessionSamples(namespace: makeNamespace())
    let outbound = samples.pendingDelete()
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound,
      engineState: samples.state(requiresInitialFetch: false))
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.prepareAutomaticSync()

    // A batch left staged by a failed apply carries the engine state it committed.
    await store.stage(.fetched(samples.fetched(requiresInitialFetch: true)), outbound: nil)
    let waiting = try await coordinator.processAutomaticChanges()
    try await coordinator.prepareAutomaticSync()
    let whileWaiting = await transport.scheduledBatches()
    XCTAssertTrue(waiting.blocksOutbound)
    XCTAssertEqual(whileWaiting, [outbound])

    await store.stage(.fetched(samples.fetched(requiresInitialFetch: false)), outbound: nil)
    let ready = try await coordinator.processAutomaticChanges()
    try await coordinator.prepareAutomaticSync()
    let afterReady = await transport.scheduledBatches()
    let starts = await transport.startCount()
    XCTAssertFalse(ready.blocksOutbound)
    XCTAssertEqual(afterReady, [outbound, outbound])
    XCTAssertEqual(starts, 1)
  }

  func testCheckpointsTurnTheInitialFetchRequirementOffAndOnForARunningEngine() async throws {
    let samples = EngineSessionSamples(namespace: makeNamespace())
    let outbound = samples.pendingDelete()
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    let fresh = try await coordinator.prepareAutomaticSync()
    XCTAssertTrue(fresh.blocksOutbound)

    await transport.enqueue(.checkpoint(UUID(), samples.state(requiresInitialFetch: false)))
    let completed = try await coordinator.processAutomaticChanges()
    let afterCompletion = await transport.scheduledBatches()
    XCTAssertFalse(completed.blocksOutbound)
    XCTAssertEqual(afterCompletion, [outbound])

    await transport.enqueue(.checkpoint(UUID(), samples.state(requiresInitialFetch: true)))
    let required = try await coordinator.processAutomaticChanges()
    let afterRequirement = await transport.scheduledBatches()
    let starts = await transport.startCount()
    XCTAssertTrue(required.blocksOutbound)
    XCTAssertFalse(required.settled)
    XCTAssertEqual(afterRequirement, [outbound])
    XCTAssertEqual(starts, 1)
  }

  func testCheckpointRequiringTheInitialFetchMakesTheNextSendFetchFirst() async throws {
    let samples = EngineSessionSamples(namespace: makeNamespace())
    let store = AutomaticSyncStoreProbe(pendingChanges: samples.pendingDelete(),
      engineState: samples.state(requiresInitialFetch: false))
    let transport = AutomaticSyncTransportProbe(
      fetched: samples.fetched(requiresInitialFetch: false), sendSucceeds: true)
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.prepareAutomaticSync()
    await transport.enqueue(.checkpoint(UUID(), samples.state(requiresInitialFetch: true)))
    try await coordinator.processAutomaticChanges()

    let outcome = try await coordinator.sendPending()

    let fetches = await transport.fetchCount()
    let sends = await transport.sendCount()
    let starts = await transport.startCount()
    XCTAssertEqual(fetches, 1)
    XCTAssertEqual(sends, 1)
    XCTAssertEqual(starts, 1)
    XCTAssertFalse(outcome.blocksOutbound)
    XCTAssertTrue(outcome.settled)
  }

  /// The refetch after an expired token belongs to the run that saw it, even when the
  /// expired batch was drained before that run's own fetch.
  func testExpiredTokenDrainedBeforeAnExplicitFetchRefetchesOnceMoreInTheSameRun() async throws {
    let samples = EngineSessionSamples(namespace: makeNamespace())
    let store = AutomaticSyncStoreProbe(engineState: samples.state(requiresInitialFetch: false))
    let transport = AutomaticSyncTransportProbe(pending: .fetched(samples.expiredToken()),
      fetched: samples.fetched(requiresInitialFetch: false),
      fetchedAfterReset: samples.fetched(requiresInitialFetch: false))
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    let outcome = try await coordinator.fetchRemote()

    let fetches = await transport.fetchCount()
    let resets = await transport.resetCount()
    let states = await transport.startedEngineStates()
    let clears = await store.engineStateClearCount()
    XCTAssertEqual(fetches, 2)
    XCTAssertEqual(resets, 1)
    XCTAssertEqual(states, [nil])
    XCTAssertEqual(clears, 1)
    XCTAssertFalse(outcome.blocksOutbound)
    XCTAssertEqual(outcome.result, .contentUpdated)
  }

  func testExpiredTokenInAnAutomaticBatchDoesNotRefetchInTheNextExplicitRun() async throws {
    let samples = EngineSessionSamples(namespace: makeNamespace())
    let stored = samples.state(requiresInitialFetch: false)
    let store = AutomaticSyncStoreProbe(engineState: stored)
    let transport = AutomaticSyncTransportProbe(fetched: samples.fetched(requiresInitialFetch: false))
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.prepareAutomaticSync()
    await transport.enqueue(.batch(CloudPendingBatch(batch: .fetched(samples.expiredToken()), outbound: nil)))

    let reset = try await coordinator.processAutomaticChanges()
    let fetched = try await coordinator.fetchRemote()

    let fetches = await transport.fetchCount()
    let states = await transport.startedEngineStates()
    XCTAssertTrue(reset.blocksOutbound)
    XCTAssertFalse(fetched.blocksOutbound)
    XCTAssertEqual(fetches, 1)
    XCTAssertEqual(states, [stored, nil])
  }

  func testUnreadableOutboundPlanStopsTheEngineUntilTheNextStart() async throws {
    let samples = EngineSessionSamples(namespace: makeNamespace())
    let stored = samples.state(requiresInitialFetch: false)
    for failsWhileRunning in [false, true] {
      let label = "fails while running: \(failsWhileRunning)"
      let store = ScriptedSessionStore(engineState: stored)
      let transport = AutomaticSyncTransportProbe()
      let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
      if failsWhileRunning { try await coordinator.prepareAutomaticSync() }
      await store.failNextPlan()

      do {
        try await coordinator.prepareAutomaticSync()
        XCTFail("Expected the outbound plan to fail")
      } catch CloudSyncRetryableError.itemFailure {}
      let stopped = try await coordinator.processAutomaticChanges()
      let startsWhileStopped = await transport.startCount()
      try await coordinator.prepareAutomaticSync()

      let states = await transport.startedEngineStates()
      let resets = await transport.resetCount()
      let clears = await store.engineStateClearCount()
      let expectedStates: [CloudEngineStateEnvelope?] = failsWhileRunning ? [stored, nil] : [nil]
      XCTAssertTrue(stopped.blocksOutbound, label)
      XCTAssertEqual(startsWhileStopped, failsWhileRunning ? 1 : 0, label)
      XCTAssertEqual(states, expectedStates, label)
      XCTAssertEqual(resets, 1, label)
      XCTAssertEqual(clears, 1, label)
    }
  }

  func testManualRetryResetStopsTheEngineUntilTheNextRunStartsAFreshOne() async throws {
    let fixture = try EngineSessionFixture(name: "ManualRetryReset", namespace: makeNamespace())
    defer { fixture.remove() }
    try await fixture.coordinator.fetchRemote()

    // An empty remote check leaves the namespace remote-checked, so Try Again refetches.
    try await fixture.coordinator.prepareManualRetry()
    let cleared = try await fixture.store.loadEngineState()
    let stopped = try await fixture.coordinator.processAutomaticChanges()
    let beforeRestart = await fixture.startsAndFetches()
    XCTAssertNil(cleared)
    XCTAssertTrue(stopped.blocksOutbound)
    XCTAssertEqual(beforeRestart, [.started, .fetched])

    let sent = try await fixture.coordinator.sendPending()

    let events = await fixture.startsAndFetches()
    let scopes = await fixture.transport.fetchScopes()
    XCTAssertEqual(events, [.started, .fetched, .started, .fetched])
    XCTAssertEqual(scopes.last, .all)
    XCTAssertFalse(sent.blocksOutbound)
  }

  func testUnreadableForeignOrRejectedEngineStateRestartsAnEmptyEngineThatFetchesFirst() async throws {
    let namespace = makeNamespace()
    let foreign = CloudSyncNamespace(cloudScope: "private", accountLineage: "another account",
      generation: UUID(), zones: namespace.zones)
    let cases: [(String, Data, [FakeCloudTransportEvent])] = [
      ("unreadable", Data("not an engine state".utf8), [.started, .fetched]),
      ("foreign namespace", try JSONEncoder().encode(CloudEngineStateEnvelope(namespace: foreign,
        serialization: Data("{}".utf8), requiresInitialFetch: false)), [.started, .fetched]),
      // The engine logs its rejected start before the empty restart.
      ("rejected by the engine", try JSONEncoder().encode(CloudEngineStateEnvelope(namespace: namespace,
        serialization: Data("not cursors".utf8), requiresInitialFetch: false)), [.started, .started, .fetched]),
    ]
    for (label, data, expectedEvents) in cases {
      let fixture = try EngineSessionFixture(name: "EngineStateRestart", namespace: namespace)
      defer { fixture.remove() }
      try await fixture.library.saveCloudEngineState(namespaceKey: namespace.namespaceKey, envelopeData: data)

      let outcome = try await fixture.coordinator.sendPending()

      let events = await fixture.startsAndFetches()
      let stored = try await fixture.store.loadEngineState()
      XCTAssertEqual(events, expectedEvents, label)
      XCTAssertEqual(stored?.namespace, namespace, label)
      XCTAssertEqual(stored?.requiresInitialFetch, false, label)
      XCTAssertFalse(outcome.blocksOutbound, label)
    }
  }

  /// SM27-L2-C1 guard; the lead did not reproduce. Applying the staged batch replaces the
  /// stored engine state with the batch's own, here none, so the read after staged recovery
  /// finds no state and `ensureStarted` starts an empty engine.
  func testStagedBatchRecoveredOverAnUnreadableEngineStateRestartsAnEmptyEngine() async throws {
    let fixture = try EngineSessionFixture(name: "StagedOverUnreadableState", namespace: makeNamespace())
    defer { fixture.remove() }
    try await fixture.library.saveCloudEngineState(namespaceKey: fixture.namespace.namespaceKey,
      envelopeData: Data("not an engine state".utf8))
    // Stands in for a batch whose apply failed after its stage commit.
    let interrupted = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
    try await fixture.store.stage(.fetched(interrupted))

    try await fixture.coordinator.fetchRemote()

    let staged = try await fixture.store.stagedBatches()
    let events = await fixture.startsAndFetches()
    let stored = try await fixture.store.loadEngineState()
    XCTAssertTrue(staged.isEmpty)
    XCTAssertEqual(events, [.started, .fetched])
    XCTAssertEqual(stored?.namespace, fixture.namespace)
  }

  /// Base behavior, kept as a guard. If a store's state stays unreadable after staged recovery,
  /// the run fails whether the engine is stopped or running. Nothing resets or starts an engine
  /// there, so the queue behind the replayed batches stays for the next run (ADR 0028).
  func testReadErrorAfterStagedRecoveryFailsTheRunWithoutResettingOrStartingAnEngine() async throws {
    let samples = EngineSessionSamples(namespace: makeNamespace())
    let stored = samples.state(requiresInitialFetch: false)
    for wasRunning in [false, true] {
      let label = "was running: \(wasRunning)"
      let store = ScriptedSessionStore(engineState: stored)
      let transport = AutomaticSyncTransportProbe(fetched: samples.fetched(requiresInitialFetch: false))
      let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
      if wasRunning { try await coordinator.prepareAutomaticSync() }
      await store.leaveStagedBatchOverUnreadableEngineState()
      let queuedID = UUID()
      await transport.enqueue(.checkpoint(queuedID, stored))

      do {
        _ = try await coordinator.fetchRemote()
        XCTFail("Expected the engine-state read to fail the run (\(label))")
      } catch CloudTransportError.invalidEngineState {}

      let states = await transport.startedEngineStates()
      let resets = await transport.resetCount()
      let fetches = await transport.fetchCount()
      let waiting = await queuedEventID(transport)
      let clears = await store.engineStateClearCount()
      let staged = await store.stagedBatchCount()
      let expectedStates: [CloudEngineStateEnvelope?] = wasRunning ? [stored] : []
      XCTAssertEqual(states, expectedStates, label)
      XCTAssertEqual(resets, 0, label)
      XCTAssertEqual(fetches, 0, label)
      XCTAssertEqual(waiting, queuedID, label)
      XCTAssertEqual(clears, 0, label)
      XCTAssertEqual(staged, 0, label)
    }
  }

  /// SM27-L2-C1 and L2-F1 guard with the SwiftData store. Applying the replayed head replaces
  /// the unreadable state with the head's own, here none, so the run goes on. The purge queued
  /// behind the head then commits in the same run, in order, with no reset, and blocks edits
  /// and sends (ADR 0028). The probe's reset would drop that queue, as the CloudKit
  /// transport's does.
  func testReplayedBatchOverAnUnreadableStateKeepsTheQueuedPurgeInOrder() async throws {
    let samples = EngineSessionSamples(namespace: makeNamespace())
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("QueuedPurgeBehindStagedBatch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let store = CloudFullSyncPersistence(library: library, namespace: samples.namespace,
      dataZone: samples.zone)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.prepareAutomaticSync()
    try await library.saveCloudEngineState(namespaceKey: samples.namespace.namespaceKey,
      envelopeData: Data("not an engine state".utf8))
    // The head's apply failed after its stage commit; a purge waits behind it.
    let head = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
    let purge = CloudFetchedBatch(id: UUID(), items: [],
      databaseEvents: [.zoneDeleted(samples.zone, reason: .purged)], engineState: nil)
    try await store.stage(.fetched(head))
    await transport.setPending(.fetched(head))
    await transport.setPending(.fetched(purge))

    let outcome = try await coordinator.processAutomaticChanges()

    let engineState = try await library.cloudTextSyncSnapshot(
      namespaceKey: samples.namespace.namespaceKey).engineState
    let waiting = await queuedEventID(transport)
    let confirmed = await transport.confirmedBatchIDs()
    let resets = await transport.resetCount()
    let starts = await transport.startCount()
    let sends = await transport.sendCount()
    let scheduled = await transport.scheduledBatches()
    let signal = try await store.destructiveResetSignal()
    let admission = try await store.outboundAdmission()
    XCTAssertNil(engineState)
    XCTAssertNil(waiting)
    XCTAssertEqual(confirmed, [head.id, purge.id])
    XCTAssertEqual(resets, 0)
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(signal, .purged)
    XCTAssertEqual(outcome.result, .iCloudDataReset)
    XCTAssertTrue(outcome.blocksOutbound)
    XCTAssertTrue(admission.blocksAll)
    XCTAssertEqual(sends, 0)
    XCTAssertTrue(scheduled.isEmpty)
    do {
      _ = try await library.perform(.add(content: "after the purge", origin: .quickEntry, source: nil,
        listID: SnipList.inbox.id, attachmentURLs: [], requestID: UUID(), now: Date()), sortedBy: .manual)
      XCTFail("A purged source must reject content edits")
    } catch SnipLibraryError.modeTransitionInProgress {}
  }
}

/// The queue head as the coordinator sees it. Called on the concrete probe, whose
/// `pendingEvent()` is synchronous, an async caller gets the protocol's `async` default,
/// which always returns nil.
private func queuedEventID(_ transport: any CloudRecordTransport) async -> UUID? {
  await transport.pendingEvent()?.id
}

private struct EngineSessionSamples {
  let namespace: CloudSyncNamespace

  var zone: CloudZoneID { namespace.zones.sorted { $0.name < $1.name }[0] }

  func state(requiresInitialFetch: Bool) -> CloudEngineStateEnvelope {
    CloudEngineStateEnvelope(namespace: namespace,
      serialization: Data("engine-session-\(requiresInitialFetch)".utf8),
      requiresInitialFetch: requiresInitialFetch)
  }

  func fetched(requiresInitialFetch: Bool) -> CloudFetchedBatch {
    CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.fetched(zone)],
      engineState: state(requiresInitialFetch: requiresInitialFetch))
  }

  func expiredToken() -> CloudFetchedBatch {
    CloudFetchedBatch(id: UUID(), items: [], zoneEvents: [.failed(zone, .changeTokenExpired)],
      engineState: nil)
  }

  func pendingDelete() -> CloudOutboundBatch {
    CloudOutboundBatch(operations: [.delete(CloudRecordID(zone: zone, name: "pending"), base: nil)])
  }
}

private struct EngineSessionFixture {
  let root: URL
  let namespace: CloudSyncNamespace
  let library: SwiftDataSnipLibrary
  let store: CloudFullSyncPersistence
  let transport: FakeCloudRecordTransport
  let coordinator: CloudFullSyncCoordinator

  init(name: String, namespace: CloudSyncNamespace) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    self.namespace = namespace
    let zone = try XCTUnwrap(namespace.zones.first)
    library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    transport = FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
    coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func startsAndFetches() async -> [FakeCloudTransportEvent] {
    await transport.events().filter { $0 == .started || $0 == .fetched }
  }
}

/// A store whose outbound plan, engine-state read, and staged batches a test scripts.
private actor ScriptedSessionStore: CloudFullSyncStore {
  private var engineState: CloudEngineStateEnvelope?
  private var staged: [CloudFullBatchCommit] = []
  private var failsNextPlan = false
  private var engineStateIsUnreadable = false
  private var clears = 0

  init(engineState: CloudEngineStateEnvelope?) {
    self.engineState = engineState
  }

  func failNextPlan() { failsNextPlan = true }

  /// A batch whose apply failed after its stage commit, over a stored state no engine reads.
  /// Unlike the SwiftData store, applying it leaves that state in place.
  func leaveStagedBatchOverUnreadableEngineState() {
    staged.append(CloudFullBatchCommit(namespaceKey: "test", batchID: UUID(),
      expectedEngineState: nil, nextEngineState: nil, items: []))
    engineStateIsUnreadable = true
  }

  func engineStateClearCount() -> Int { clears }
  func stagedBatchCount() -> Int { staged.count }

  func loadEngineState() throws -> CloudEngineStateEnvelope? {
    if engineStateIsUnreadable { throw CloudTransportError.invalidEngineState }
    return engineState
  }
  func saveEngineState(_ state: CloudEngineStateEnvelope) {
    engineState = state
    engineStateIsUnreadable = false
  }
  func clearEngineState() {
    engineState = nil
    engineStateIsUnreadable = false
    clears += 1
  }
  func prepareInitialFetch() {}
  func stagedBatches() -> [CloudFullBatchCommit] { staged }
  func stage(_ batch: CloudSyncBatch, outbound: CloudOutboundBatch?) {}
  func applyStaged(_ id: UUID) { staged.removeAll { $0.batchID == id } }
  func pendingChanges() throws -> CloudOutboundBatch {
    if failsNextPlan {
      failsNextPlan = false
      throw CloudRecordError.invalidShadow
    }
    return CloudOutboundBatch(operations: [])
  }
  func syncStatus() -> CloudFullSyncStatus { .settled }
  func destructiveResetSignal() -> CloudZoneDeletionReason? { nil }
  func prepareManualRetry() -> Bool { false }
}
