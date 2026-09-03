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
      try await coordinator.applyAutomatically(
        .fetched(emptyFetchedBatch()),
        outbound: nil,
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

    try await coordinator.applyAutomatically(
      .fetched(automatic),
      outbound: nil,
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
      pendingOutbound: CloudOutboundBatch(operations: [])
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
      pendingAfterDrain: CloudPendingBatch(batch: .fetched(second), outbound: nil)
    )
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await coordinator.fetchRemote()

    let applied = await store.appliedBatchIDs()
    let fetchCount = await transport.fetchCount()
    XCTAssertEqual(Array(applied.prefix(2)), [first.id, second.id])
    XCTAssertEqual(fetchCount, 1)
  }

  func testAutomaticCompletionWaitsUntilExplicitSyncReleasesItsLock() async throws {
    let store = AutomaticSyncStoreProbe()
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    let automatic = emptyFetchedBatch()
    await transport.setDrainHandler {
      try await coordinator.applyAutomatically(
        .fetched(automatic),
        outbound: nil,
        beforeApply: {}
      )
    }

    try await coordinator.fetchRemote()

    let drainError = await transport.recordedDrainError()
    let applied = await store.appliedBatchIDs()
    XCTAssertNil(drainError)
    XCTAssertEqual(applied.last, automatic.id)
  }

  func testPreparingAutomaticSyncStartsTheEngineAndSchedulesPendingChanges() async throws {
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
    XCTAssertEqual(scheduled, [outbound])
    XCTAssertEqual(fetchCount, 1)
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
    XCTAssertEqual(fetchCount, 1)
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

    try await coordinator.sync()

    let issue = await coordinator.takeSyncIssue()
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
      items: [.failed(id, .attachmentUnavailable)],
      engineState: nil
    )
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe(fetched: fetched, sendSucceeds: true)
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await coordinator.sync()

    let issue = await coordinator.takeSyncIssue()
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

    try await coordinator.sync()

    let clearCount = await store.engineStateClearCount()
    let fetchCount = await transport.fetchCount()
    let resetCount = await transport.resetCount()
    let sendCount = await transport.sendCount()
    let issue = await coordinator.takeSyncIssue()
    XCTAssertEqual(clearCount, 1)
    XCTAssertEqual(fetchCount, 2)
    XCTAssertEqual(resetCount, 1)
    XCTAssertEqual(sendCount, 1)
    XCTAssertNil(issue)
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

    try await coordinator.applyAutomatically(
      .fetched(emptyFetchedBatch()),
      outbound: nil,
      beforeApply: {}
    )

    let scheduled = await transport.scheduledBatches()
    XCTAssertEqual(scheduled, [outbound])
  }

  func testAutomaticDestructiveResetNeverSchedulesPendingChanges() async throws {
    let zone = CloudZoneID(name: "snips-test", ownerName: "owner")
    let id = CloudRecordID(zone: zone, name: "pending-record")
    let outbound = CloudOutboundBatch(operations: [.delete(id, base: nil)])
    let reset = CloudFetchedBatch(
      id: UUID(),
      items: [],
      databaseEvents: [
        .zoneDeleted(zone, reason: .encryptedDataReset),
        .failed(nil, .networkUnavailable),
      ],
      engineState: nil
    )
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await coordinator.applyAutomatically(
      .fetched(reset),
      outbound: nil,
      beforeApply: {}
    )

    let scheduled = await transport.scheduledBatches()
    let issue = await coordinator.takeSyncIssue()
    let blocked = await coordinator.isOutboundBlocked()
    XCTAssertTrue(scheduled.isEmpty)
    XCTAssertEqual(issue, .waitingForConnection)
    XCTAssertTrue(blocked)
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

    try await coordinator.persistEngineState(state)

    let saved = await store.loadEngineState()
    let fetchCount = await transport.fetchCount()
    XCTAssertEqual(saved, state)
    XCTAssertEqual(fetchCount, 0)
  }

  private func emptyFetchedBatch() -> CloudFetchedBatch {
    CloudFetchedBatch(
      id: UUID(),
      items: [],
      databaseEvents: [],
      zoneEvents: [],
      engineState: nil
    )
  }
}

private enum AutomaticSyncTestError: Error {
  case accountChanged
  case unsupported
}

private actor AutomaticSyncStoreProbe: CloudFullSyncStore {
  private var staged: [CloudFullBatchCommit]
  private var applied: [UUID] = []
  private let outbound: CloudOutboundBatch
  private var engineState: CloudEngineStateEnvelope?
  private let engineStateAfterApply: CloudEngineStateEnvelope?
  private var clearCount = 0

  init(
    stagedBatchID: UUID? = nil,
    pendingChanges: CloudOutboundBatch = CloudOutboundBatch(operations: []),
    engineStateAfterApply: CloudEngineStateEnvelope? = nil,
    engineState: CloudEngineStateEnvelope? = nil
  ) {
    staged = stagedBatchID.map { [Self.commit(id: $0)] } ?? []
    outbound = pendingChanges
    self.engineState = engineState
    self.engineStateAfterApply = engineStateAfterApply
  }

  func loadEngineState() -> CloudEngineStateEnvelope? { engineState }
  func saveEngineState(_ state: CloudEngineStateEnvelope) { engineState = state }
  func clearEngineState() {
    engineState = nil
    clearCount += 1
  }
  func stagedBatches() -> [CloudFullBatchCommit] { staged }

  func stage(_ batch: CloudSyncBatch, outbound: CloudOutboundBatch?) {
    staged.append(Self.commit(id: batch.id))
  }

  func applyStaged(_ id: UUID) {
    applied.append(id)
    staged.removeAll { $0.batchID == id }
    engineState = engineStateAfterApply
  }

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

private actor AutomaticSyncTransportProbe: CloudRecordTransport, CloudAutomaticSyncScheduling {
  private var pending: CloudSyncBatch?
  private var pendingOutbound: CloudOutboundBatch?
  private var confirmations: [UUID] = []
  private var fetches = 0
  private var starts = 0
  private var startStates: [CloudEngineStateEnvelope?] = []
  private var scheduled: [CloudOutboundBatch] = []
  private var drainHandler: (@Sendable () async throws -> Void)?
  private var drainError: Error?
  private var pendingAfterDrain: CloudPendingBatch?
  private var initialOutbounds: [CloudOutboundBatch?] = []
  private let rejectsStoredState: Bool
  private var fetchedBatches: [CloudFetchedBatch]
  private var sends = 0
  private var resets = 0
  private let sendSucceeds: Bool

  init(
    pending: CloudSyncBatch? = nil,
    pendingOutbound: CloudOutboundBatch? = nil,
    pendingAfterDrain: CloudPendingBatch? = nil,
    rejectsStoredState: Bool = false,
    fetched: CloudFetchedBatch? = nil,
    fetchedAfterReset: CloudFetchedBatch? = nil,
    sendSucceeds: Bool = false
  ) {
    self.pending = pending
    self.pendingOutbound = pendingOutbound
    self.pendingAfterDrain = pendingAfterDrain
    self.rejectsStoredState = rejectsStoredState
    fetchedBatches = [fetched, fetchedAfterReset].compactMap { $0 }
    self.sendSucceeds = sendSucceeds
  }

  func start(state: CloudEngineStateEnvelope?) {
    starts += 1
    startStates.append(state)
  }

  func start(
    state: CloudEngineStateEnvelope?,
    initialOutbound: CloudOutboundBatch?
  ) throws {
    starts += 1
    startStates.append(state)
    initialOutbounds.append(initialOutbound)
    if rejectsStoredState, state != nil {
      throw CloudTransportError.invalidEngineState
    }
  }

  func scheduleAutomaticSync(_ batch: CloudOutboundBatch) {
    scheduled.append(batch)
  }

  func fetch(scope: CloudFetchScope) -> CloudFetchedBatch {
    fetches += 1
    if !fetchedBatches.isEmpty { return fetchedBatches.removeFirst() }
    return CloudFetchedBatch(
      id: UUID(),
      items: [],
      databaseEvents: [],
      zoneEvents: [],
      engineState: nil
    )
  }

  func send(_ batch: CloudOutboundBatch) throws -> CloudSentBatch {
    sends += 1
    if sendSucceeds {
      return CloudSentBatch(id: UUID(), items: [], engineState: nil)
    }
    throw AutomaticSyncTestError.unsupported
  }

  func reset() { resets += 1 }

  func confirmApplied(_ batchID: UUID) {
    confirmations.append(batchID)
    if pending?.id == batchID { pending = nil }
  }

  func pendingBatch() -> CloudPendingBatch? {
    pending.map { CloudPendingBatch(batch: $0, outbound: pendingOutbound) }
  }

  func drainAutomaticSyncEvents() async {
    if pending == nil, let next = pendingAfterDrain {
      pending = next.batch
      pendingOutbound = next.outbound
      pendingAfterDrain = nil
    }
    let handler = drainHandler
    drainHandler = nil
    do {
      try await handler?()
    } catch {
      drainError = error
    }
  }

  func setDrainHandler(_ handler: @escaping @Sendable () async throws -> Void) {
    drainHandler = handler
  }

  func recordedDrainError() -> Error? { drainError }

  func fetchRecord(
    _ id: CloudRecordID,
    fields: Set<String>
  ) throws -> CloudRecordSnapshot? {
    throw AutomaticSyncTestError.unsupported
  }

  func fetchAsset(
    _ id: CloudRecordID,
    field: String,
    destination: CloudAssetDestination
  ) throws -> CloudAssetReceipt? {
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
