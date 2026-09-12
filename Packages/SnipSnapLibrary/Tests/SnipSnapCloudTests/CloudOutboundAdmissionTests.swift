import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnapCloud

final class CloudOutboundAdmissionTests: XCTestCase {
  func testStalePlanningCannotRestoreFailedSaveOrDeleteAndRecoveryWaitsForDurableAdmission() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let wrapped = AdmissionStore(fixture.store)
    let transport = AdmissionTransport(zones: fixture.namespace.zones)
    let coordinator = CloudFullSyncCoordinator(store: wrapped, transport: transport)
    try await coordinator.prepareAutomaticSync()
    await transport.beginCycle()
    let stale = try await fixture.store.pendingChanges()
    let pause = AutomaticSyncPause()
    await wrapped.pauseNextPlan(pause)
    let planning = Task { try await coordinator.prepareAutomaticSync() }
    await pause.waitUntilSuspended()
    let failed = CloudFetchedBatch(id: UUID(), items: fixture.ids.map { .failed($0, .invalidRecord) }, engineState: fixture.state)
    await transport.enqueue(.fetched(failed))
    await pause.resume()
    _ = try await planning.value
    await wrapped.failNextApply()
    await XCTAssertThrowsErrorAsync { try await coordinator.processAutomaticChanges() }
    await transport.scheduleAutomaticSync(stale)
    let beforeCommit = await transport.current()
    XCTAssertTrue(beforeCommit.operations.isEmpty)
    try await coordinator.processAutomaticChanges()

    await transport.scheduleAutomaticSync(stale)
    let blocked = await transport.current()
    let frozen = await transport.cycleOperations()
    XCTAssertTrue(blocked.operations.isEmpty)
    XCTAssertTrue(frozen.isEmpty)
    let afterFailure = await transport.admission()
    XCTAssertEqual(afterFailure.blockedRecordIDs, fixture.ids)

    let refreshed = try fixture.refetched()
    await transport.enqueue(.fetched(refreshed))
    await wrapped.failNextAdmissionRead()
    await XCTAssertThrowsErrorAsync { try await coordinator.processAutomaticChanges() }
    // The records committed, but no acknowledgement may loosen admission after a failed read.
    let durable = try await fixture.store.outboundAdmission()
    XCTAssertTrue(durable.blockedRecordIDs.isEmpty)
    await transport.scheduleAutomaticSync(stale)
    let afterReadFailure = await transport.current()
    XCTAssertTrue(afterReadFailure.operations.isEmpty)
    let pendingEvent = await transport.pendingEvent()
    XCTAssertEqual(pendingEvent?.id, refreshed.id)

    try await coordinator.processAutomaticChanges()
    let recovered = await transport.current()
    XCTAssertEqual(Set(recovered.operations.map(\.id)), fixture.ids)
    for operation in recovered.operations {
      let snapshot = try XCTUnwrap(refreshed.items.compactMap { item -> CloudRecordSnapshot? in
        if case .record(let record) = item, record.id == operation.id { record } else { nil }
      }.first)
      switch operation {
      case .save(let draft):
        XCTAssertEqual(draft.base, snapshot.shadow)
      case .delete(_, let base):
        XCTAssertEqual(base, snapshot.shadow)
      }
    }
    let stillFrozen = await transport.cycleOperations()
    XCTAssertTrue(stillFrozen.isEmpty, "Fresh bodies wait for the next send cycle")
  }

  func testOlderSuccessfulConfirmationCannotReleaseANewerObservedFailure() {
    let zone = CloudZoneID(name: "zone", ownerName: "owner")
    let id = CloudRecordID(zone: zone, name: "record")
    let successID = UUID()
    let failureID = UUID()
    var queue = CloudRecordOutboundQueue()
    queue.restoreAdmission(CloudRecordOutboundAdmission(blockedRecordIDs: [id]))
    queue.observe(.fetched(CloudFetchedBatch(id: failureID, items: [.failed(id, .invalidRecord)], engineState: nil)), zones: [zone])
    queue.confirmAdmission(successID, durable: .open)
    _ = queue.schedule(CloudOutboundBatch(operations: [.delete(id, base: nil)]))
    XCTAssertEqual(queue.admission.blockedRecordIDs, [id])
    XCTAssertTrue(queue.current.operations.isEmpty)
    queue.confirmAdmission(failureID, durable: CloudRecordOutboundAdmission(blockedRecordIDs: [id]))
    _ = queue.schedule(CloudOutboundBatch(operations: [.delete(id, base: nil)]))
    XCTAssertTrue(queue.current.operations.isEmpty)
  }

  func testLegacyCommittedDeletionReleasesOnlyItsIDAndKeepsNewerFailures() {
    let zone = CloudZoneID(name: "zone", ownerName: "owner")
    let first = CloudRecordID(zone: zone, name: "first")
    let second = CloudRecordID(zone: zone, name: "second")
    var queue = CloudRecordOutboundQueue()
    let failed = CloudSyncBatch.fetched(CloudFetchedBatch(id: UUID(),
      items: [.failed(first, .invalidRecord), .failed(second, .retryable)], engineState: nil))
    queue.observe(failed, zones: [zone])
    queue.confirmLegacyAdmission(failed)
    let success = CloudSyncBatch.fetched(CloudFetchedBatch(id: UUID(), items: [.deleted(first)], engineState: nil))
    let laterFailure = CloudSyncBatch.fetched(CloudFetchedBatch(id: UUID(), items: [.failed(first, .invalidRecord)], engineState: nil))
    queue.observe(laterFailure, zones: [zone])
    queue.confirmLegacyAdmission(success)
    XCTAssertEqual(queue.admission.blockedRecordIDs, [first, second])
    queue.confirmLegacyAdmission(laterFailure)
    queue.confirmLegacyAdmission(.fetched(CloudFetchedBatch(id: UUID(), items: [.deleted(first)], engineState: nil)))
    XCTAssertEqual(queue.admission.blockedRecordIDs, [second])
  }

  func testFailedPurgeDeliveryLeavesQueuedFrozenAndRestoredOutboundStopped() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let transport = AdmissionTransport(zones: fixture.namespace.zones)
    let coordinator = CloudFullSyncCoordinator(store: fixture.store, transport: transport) { result in
      if result == .iCloudDataReset { throw AutomaticSyncTestError.unsupported }
    }
    try await coordinator.prepareAutomaticSync()
    let stale = try await fixture.store.pendingChanges()
    await transport.scheduleAutomaticSync(CloudOutboundBatch(operations: stale.operations, zonesToSave: fixture.namespace.zones))
    await transport.beginCycle()
    let reset = CloudFetchedBatch(id: UUID(), items: [],
      databaseEvents: [.zoneDeleted(fixture.zone, reason: .purged)], engineState: fixture.state)
    await transport.enqueue(.fetched(reset))
    await XCTAssertThrowsErrorAsync { try await coordinator.processAutomaticChanges() }
    let event = await transport.pendingEvent()
    XCTAssertNil(event, "The reset committed before result delivery failed")
    await transport.scheduleAutomaticSync(CloudOutboundBatch(operations: stale.operations, zonesToSave: fixture.namespace.zones))
    let blocked = await transport.current()
    let frozen = await transport.cycleOperations()
    XCTAssertTrue(blocked.operations.isEmpty)
    XCTAssertTrue(blocked.zonesToSave.isEmpty)
    XCTAssertTrue(frozen.isEmpty)
    let stopped = await transport.admission()
    XCTAssertTrue(stopped.blocksAll)

    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: fixture.url)
    let reopenedStore = CloudFullSyncPersistence(library: reopenedLibrary, namespace: fixture.namespace, dataZone: fixture.zone)
    let nextTransport = AdmissionTransport(zones: fixture.namespace.zones)
    let next = CloudFullSyncCoordinator(store: reopenedStore, transport: nextTransport)
    try await next.prepareAutomaticSync()
    await nextTransport.scheduleAutomaticSync(CloudOutboundBatch(operations: stale.operations, zonesToSave: fixture.namespace.zones))
    let restored = await nextTransport.admission()
    let restoredWork = await nextTransport.current()
    XCTAssertTrue(restored.blocksAll)
    XCTAssertTrue(restoredWork.operations.isEmpty)
    XCTAssertTrue(restoredWork.zonesToSave.isEmpty)
  }

  func testUnrelatedZoneResetDoesNotStopAdmissionAndConfirmedResetCannotReopen() {
    let zone = CloudZoneID(name: "zone", ownerName: "owner")
    let other = CloudZoneID(name: "other", ownerName: "owner")
    let id = CloudRecordID(zone: zone, name: "record")
    let outbound = CloudOutboundBatch(operations: [.delete(id, base: nil)], zonesToSave: [zone])
    var queue = CloudRecordOutboundQueue()
    _ = queue.schedule(outbound)
    queue.observe(.fetched(CloudFetchedBatch(id: UUID(), items: [],
      databaseEvents: [.zoneDeleted(other, reason: .purged)], engineState: nil)), zones: [zone])
    XCTAssertEqual(queue.current, outbound)
    XCTAssertFalse(queue.admission.blocksAll)
    let resetID = UUID()
    queue.observe(.sent(CloudSentBatch(id: resetID, items: [],
      databaseEvents: [.zoneDeleted(zone, reason: .encryptedDataReset)], engineState: nil)), zones: [zone])
    queue.confirmAdmission(resetID, durable: .open)
    XCTAssertNil(queue.schedule(outbound))
    XCTAssertTrue(queue.admission.blocksAll)
  }

  private struct Fixture {
    let root: URL
    let url: URL
    let namespace: CloudSyncNamespace
    let zone: CloudZoneID
    let state: CloudEngineStateEnvelope
    let store: CloudFullSyncPersistence
    let drafts: [CloudRecordDraft]
    var ids: Set<CloudRecordID> { Set(drafts.map(\.id)) }

    static func make() async throws -> Self {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("OutboundAdmission-\(UUID())")
      let url = root.appendingPathComponent("store")
      let zone = CloudZoneID(name: "zone", ownerName: "owner")
      let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account", generation: UUID(), zones: [zone])
      let state = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("state".utf8), requiresInitialFetch: false)
      let library = try SwiftDataSnipLibrary(storeURL: url)
      let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
      let snips = [Snip(content: "edit", origin: .quickEntry), Snip(content: "delete", origin: .quickEntry)]
      let drafts = try snips.map { try CloudFullRecordCodec.snipDraft($0, in: zone) }
      let all = [try CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)] + drafts
      let fetched = CloudFetchedBatch(id: UUID(), items: try all.map {
        .record(try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: $0)))
      }, engineState: state)
      try await store.stage(.fetched(fetched))
      try await store.applyStaged(fetched.id)
      _ = try await library.perform(.update(id: snips[0].id, content: "local edit", attachmentURLs: nil,
        expectedUpdatedAt: snips[0].updatedAt, now: snips[0].updatedAt.addingTimeInterval(10)), sortedBy: .manual)
      _ = try await library.perform(.delete(ids: [snips[1].id]), sortedBy: .manual)
      return Self(root: root, url: url, namespace: namespace, zone: zone, state: state, store: store, drafts: drafts)
    }

    func refetched() throws -> CloudFetchedBatch {
      CloudFetchedBatch(id: UUID(), items: try drafts.map { draft in
        var fields = draft.encryptedFields
        fields["futureField"] = .string("new server field")
        let fresh = CloudRecordDraft(id: draft.id, recordType: draft.recordType, schemaVersion: draft.schemaVersion,
          routingFields: draft.routingFields, encryptedFields: fields)
        return .record(try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: fresh)))
      }, engineState: state)
    }
  }
}

private actor AdmissionStore: CloudFullSyncStore {
  let base: CloudFullSyncPersistence
  var pause: AutomaticSyncPause?
  var failAdmission = false
  var failApply = false
  init(_ base: CloudFullSyncPersistence) { self.base = base }
  func pauseNextPlan(_ value: AutomaticSyncPause) { pause = value }
  func failNextAdmissionRead() { failAdmission = true }
  func failNextApply() { failApply = true }
  func pendingChanges() async throws -> CloudOutboundBatch {
    let snapshot = try await base.pendingChanges()
    if let pause { self.pause = nil; await pause.suspend() }
    return snapshot
  }
  func outboundAdmission() async throws -> CloudRecordOutboundAdmission {
    if failAdmission { failAdmission = false; throw AutomaticSyncTestError.unsupported }
    return try await base.outboundAdmission()
  }
  func loadEngineState() async throws -> CloudEngineStateEnvelope? { try await base.loadEngineState() }
  func saveEngineState(_ state: CloudEngineStateEnvelope) async throws { try await base.saveEngineState(state) }
  func clearEngineState() async throws { try await base.clearEngineState() }
  func stagedBatches() async throws -> [CloudFullBatchCommit] { try await base.stagedBatches() }
  func stage(_ batch: CloudSyncBatch, outbound: CloudOutboundBatch?) async throws { try await base.stage(batch, outbound: outbound) }
  func applyStaged(_ id: UUID) async throws {
    if failApply { failApply = false; throw AutomaticSyncTestError.unsupported }
    try await base.applyStaged(id)
  }
  func syncStatus() async throws -> CloudFullSyncStatus { try await base.syncStatus() }
  func destructiveResetSignal() async throws -> CloudZoneDeletionReason? { try await base.destructiveResetSignal() }
  func prepareManualRetry() async throws -> Bool { try await base.prepareManualRetry() }
}

/// The test adapter drives the production queue and mailbox without CloudKit network work.
actor AdmissionTransport: CloudRecordTransport, CloudAutomaticSyncScheduling {
  let zones: Set<CloudZoneID>
  let mailbox = CloudRecordTransportMailbox()
  var queue = CloudRecordOutboundQueue()
  init(zones: Set<CloudZoneID>) { self.zones = zones }
  func start(state: CloudEngineStateEnvelope?) {}
  func start(state: CloudEngineStateEnvelope?, initialOutbound: CloudOutboundBatch?, outboundAdmission: CloudRecordOutboundAdmission) {
    queue.restoreAdmission(outboundAdmission)
    if let initialOutbound { _ = queue.schedule(initialOutbound) }
  }
  func enqueue(_ batch: CloudSyncBatch) {
    queue.observe(batch, zones: zones)
    mailbox.append(.batch(CloudPendingBatch(batch: batch, outbound: nil)))
  }
  func beginCycle() { queue.beginCycle() }
  func supplyCycle() { queue.recordSupplied(Set(cycleOperations().map(\.id))) }
  func completeCycle(on server: FakeCloudServer, state: CloudEngineStateEnvelope) async throws -> CloudOutboundBatch {
    let ids = Set(cycleOperations().map(\.id))
    queue.recordSupplied(ids)
    let batchID = UUID()
    let outbound = queue.finishCycle(batchID)
    let response = try await server.send(outbound, failures: [:])
    let sent = CloudSentBatch(id: batchID, items: response.items,
      databaseEvents: response.databaseEvents, engineState: state)
    mailbox.append(.batch(CloudPendingBatch(batch: .sent(sent), outbound: outbound)))
    return outbound
  }
  func current() -> CloudOutboundBatch { queue.current }
  func cycleOperations() -> [CloudOutboundOperation] {
    queue.cycle?.operations(pendingIDs: Set(queue.cycle?.outbound.operations.map(\.id) ?? [])) ?? []
  }
  func admission() -> CloudRecordOutboundAdmission { queue.admission }
  func scheduleAutomaticSync(_ batch: CloudOutboundBatch) { _ = queue.schedule(batch) }
  func pendingEvent() async -> CloudRecordTransportEvent? { mailbox.first }
  func confirmApplied(_ id: UUID) throws { _ = try mailbox.confirm(id) }
  func confirmApplied(_ id: UUID, outboundAdmission: CloudRecordOutboundAdmission) throws {
    guard let event = try mailbox.confirm(id) else { return }
    queue.confirmAdmission(id, durable: outboundAdmission)
    if case .batch(let pending) = event, case .sent(let sent) = pending.batch { queue.confirm(sent) }
  }
  func fetch(scope: CloudFetchScope) throws -> CloudFetchedBatch { throw AutomaticSyncTestError.unsupported }
  func send(_ batch: CloudOutboundBatch) throws -> CloudSentBatch { throw AutomaticSyncTestError.unsupported }
  func fetchRecord(_ id: CloudRecordID, fields: Set<String>) -> CloudRecordSnapshot? { nil }
  func fetchAsset(_ id: CloudRecordID, field: String, destination: CloudAssetDestination) -> CloudAssetReceipt? { nil }
}
