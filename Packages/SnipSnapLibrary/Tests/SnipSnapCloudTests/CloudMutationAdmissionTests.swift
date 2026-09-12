import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

final class CloudMutationAdmissionTests: XCTestCase {
  func testAttachmentReleaseContinuesThePendingAutomaticBatchAndCheckpoint() async throws {
    let fixture = try await AdmissionFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pause = AutomaticSyncPause()
    let completion = try await prepareAutomaticConsumer(fixture)
    let control = FakeCloudControlTransport(server: FakeCloudServer())
    await control.seedControl(fixture.descriptor)
    let handler = AppleAccountCacheCoordinatorHandler(
      persistence: { fixture.persistence }, controlTransport: control,
      accountStateSource: FixedICloudAccountStateSource(state: .available(accountLineage: "account")),
      makeSyncCoordinator: { persistence, namespace, descriptor in
        ICloudSyncModeCoordinator(persistence: persistence, namespace: namespace,
          textZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone,
          makeTransport: { FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace) })
      },
      makeAttachmentCoordinator: { _, _, _ in AdmissionAttachment(pause: pause, root: fixture.root) },
      ownerName: "owner", reservedZones: [])
    let attachment = Task { try await handler.prepareSyncedAttachment(UUID(), for: .preview) }
    await pause.waitUntilSuspended()

    try await enqueueAutomaticWork(fixture)
    try await waitForQueuedMutations(fixture.persistence, count: 1)
    let beforeRelease = try await fixture.store.loadEngineState()
    XCTAssertNil(beforeRelease)
    await pause.resume()
    _ = try await attachment.value
    await fulfillment(of: [completion], timeout: 2)
    try await assertAutomaticWorkCommitted(fixture)
  }

  func testManagedEditAndImportReleaseContinueAutomaticWorkWithoutAnotherEvent() async throws {
    for importing in [false, true] {
      let pause = AutomaticSyncPause()
      let fixture = try await AdmissionFixture.make(writeHook: { point in
        if point == .afterRevisionReserved { await pause.suspend() }
      })
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let completion = try await prepareAutomaticConsumer(fixture)
      let managed = try await fixture.persistence.activeLibrary()
      let preview = try await managed.previewImport(SnipLibraryTransferSnapshot(revision: 0,
        snips: [], lists: [.inbox], attachmentData: [:], legacyManualPositions: [:]), transitionID: UUID())
      let writing = Task {
        if importing { _ = try await managed.applyImport(preview) }
        else {
          _ = try await managed.perform(.add(content: "local edit", origin: .quickEntry,
            source: nil, listID: SnipList.inbox.id, attachmentURLs: [], requestID: UUID(), now: Date()),
            sortedBy: .manual)
        }
      }
      await pause.waitUntilSuspended()
      try await enqueueAutomaticWork(fixture)
      try await waitForQueuedMutations(fixture.persistence, count: 1)
      await pause.resume()
      try await writing.value
      await fulfillment(of: [completion], timeout: 2)
      try await assertAutomaticWorkCommitted(fixture)
    }
  }

  func testCheckpointContinuesAfterAWriteWithoutAnotherTransportEvent() async throws {
    let pause = AutomaticSyncPause()
    let fixture = try await AdmissionFixture.make(writeHook: { point in
      if point == .afterRevisionReserved { await pause.suspend() }
    })
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let completion = try await prepareAutomaticConsumer(fixture)
    let managed = try await fixture.persistence.activeLibrary()
    let preview = try await managed.previewImport(SnipLibraryTransferSnapshot(revision: 0,
      snips: [], lists: [.inbox], attachmentData: [:], legacyManualPositions: [:]), transitionID: UUID())
    let importing = Task { _ = try await managed.applyImport(preview) }
    await pause.waitUntilSuspended()
    await fixture.transport.enqueue(.checkpoint(fixture.checkpointID, fixture.checkpoint))
    try await waitForQueuedMutations(fixture.persistence, count: 1)
    await pause.resume()
    try await importing.value
    await fulfillment(of: [completion], timeout: 2)
    let state = try await fixture.store.loadEngineState()
    let confirmed = await fixture.transport.confirmedBatchIDs()
    let results = await fixture.results.values()
    XCTAssertEqual(state, fixture.checkpoint)
    XCTAssertEqual(confirmed, [fixture.checkpointID])
    XCTAssertFalse(results.contains { if case .syncIssue = $0 { true } else { false } })
  }

  func testCancelledWaiterDoesNotRunOrReorderRemainingReservations() async throws {
    let fixture = try await AdmissionFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lease = try await fixture.persistence.activeCloudMutationLease(storeID: fixture.storeID)
    let pause = AutomaticSyncPause()
    let order = AdmissionOrder()
    let held = Task { try await lease.run { await pause.suspend() } }
    await pause.waitUntilSuspended()
    let first = Task { try await lease.run { await order.append("first") } }
    try await waitForQueuedMutations(fixture.persistence, count: 1)
    let cancelled = Task { try await lease.run { await order.append("cancelled") } }
    try await waitForQueuedMutations(fixture.persistence, count: 2)
    let next = Task { try await lease.run { await order.append("next") } }
    try await waitForQueuedMutations(fixture.persistence, count: 3)
    cancelled.cancel()
    do { try await cancelled.value; XCTFail("Expected cancellation while waiting") }
    catch is CancellationError {}
    await pause.resume()
    try await held.value
    try await first.value
    try await next.value
    let ran = await order.values()
    let snapshot = try await fixture.persistence.snapshot()
    XCTAssertEqual(ran, ["first", "next"])
    XCTAssertFalse(snapshot.hasActiveMutationReservation)
  }

  func testQueuedReservationRejectsItsSourceAfterAStoreReplacement() async throws {
    let pause = AutomaticSyncPause()
    let point = AdmissionRetirementPause(pause: pause)
    let fixture = try await AdmissionFixture.make(writeHook: { await point.hit($0) })
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lease = try await fixture.persistence.activeCloudMutationLease(storeID: fixture.storeID)
    let order = AdmissionOrder()
    let replacement = CloudCollectionDescriptor.fresh(ownerName: "owner")
    await point.arm()
    let changing = Task { try await fixture.persistence.activateEmptyCollection(namespace: replacement.binding) }
    await pause.waitUntilSuspended()
    let stale = Task { try await lease.run { await order.append("stale") } }
    try await waitForQueuedMutations(fixture.persistence, count: 1)
    await pause.resume()
    try await changing.value
    do { try await stale.value; XCTFail("A queued mutation must recheck its source") }
    catch SyncModePersistenceError.namespaceMismatch {}
    let ran = await order.values()
    let active = try await fixture.persistence.snapshot()
    XCTAssertTrue(ran.isEmpty)
    XCTAssertEqual(active.activeStore.namespace, replacement.binding)
    XCTAssertFalse(active.hasActiveMutationReservation)
  }

  private func prepareAutomaticConsumer(_ fixture: AdmissionFixture) async throws -> XCTestExpectation {
    let completion = expectation(description: "Automatic work completes when admission releases")
    let coordinator = CloudFullSyncCoordinator(store: fixture.store, transport: fixture.transport,
      reportResult: { result in
        await fixture.results.append(result)
        if result != .syncScheduled { completion.fulfill() }
      })
    try await coordinator.prepareAutomaticSync()
    await fixture.transport.setWorkAvailable { _ = try? await coordinator.processAutomaticChanges() }
    return completion
  }

  private func enqueueAutomaticWork(_ fixture: AdmissionFixture) async throws {
    let snipID = UUID()
    let server = FakeCloudServer()
    let sent = try await server.send(CloudOutboundBatch(operations: [.save(.text(
      id: .snip(snipID, in: fixture.descriptor.metadataZone), snipID: snipID, text: "remote record"))],
      zonesToSave: fixture.descriptor.zones), failures: [:])
    let items = sent.items.compactMap { item -> CloudFetchItemResult? in
      if case .saved(let record) = item { return .record(record) }
      return nil
    }
    let fetched = CloudFetchedBatch(id: fixture.batchID, items: items,
      zoneEvents: [.fetched(fixture.descriptor.metadataZone)], engineState: nil)
    await fixture.transport.setPending(.fetched(fetched))
    await fixture.transport.enqueue(.checkpoint(fixture.checkpointID, fixture.checkpoint))
  }

  private func assertAutomaticWorkCommitted(_ fixture: AdmissionFixture) async throws {
    let confirmed = await fixture.transport.confirmedBatchIDs()
    let state = try await fixture.store.loadEngineState()
    let content = try await fixture.library.checkedSnapshot(sortedBy: .manual)
    let results = await fixture.results.values()
    let pending = await fixture.transport.pendingEvent()
    XCTAssertEqual(confirmed, [fixture.batchID, fixture.checkpointID])
    XCTAssertEqual(state, fixture.checkpoint)
    XCTAssertTrue(content.snips.contains { $0.content == "remote record" })
    XCTAssertFalse(results.contains { if case .syncIssue = $0 { true } else { false } })
    XCTAssertNil(pending)
  }
}

private struct AdmissionFixture: Sendable {
  let root: URL
  let descriptor: CloudCollectionDescriptor
  let persistence: SwiftDataSyncModePersistence
  let library: SwiftDataSnipLibrary
  let storeID: UUID
  let store: CloudFullSyncPersistence
  let transport = AutomaticSyncTransportProbe()
  let results = AutomaticSyncReports()
  let batchID = UUID()
  let checkpointID = UUID()
  let checkpoint: CloudEngineStateEnvelope

  static func make(writeHook: @escaping SwiftDataSyncModePersistence.WriteHook = { _ in }) async throws -> AdmissionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudAdmission-\(UUID())")
    let persistence = try SwiftDataSyncModePersistence(rootURL: root, writeHook: writeHook)
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account")
    try await persistence.activateEmptyCollection(namespace: descriptor.binding)
    let active = try await persistence.snapshot().activeStore
    let library = try await persistence.libraryForTransition(storeID: active.id)
    let lease = try await persistence.activeCloudMutationLease(storeID: active.id)
    let store = CloudFullSyncPersistence(library: library, namespace: namespace,
      dataZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone, mutationLease: lease)
    return AdmissionFixture(root: root, descriptor: descriptor, persistence: persistence,
      library: library, storeID: active.id, store: store,
      checkpoint: CloudEngineStateEnvelope(namespace: namespace,
        serialization: Data("after remote record".utf8), requiresInitialFetch: false))
  }
}

private extension CloudCollectionDescriptor {
  var binding: ICloudSyncNamespaceBinding {
    ICloudSyncNamespaceBinding(scope: "private", accountLineage: "account", generation: generation,
      zones: Set(zones.map { ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName) }))
  }
}

private actor AdmissionAttachment: CloudAttachmentTransferring {
  let pause: AutomaticSyncPause
  let root: URL
  init(pause: AutomaticSyncPause, root: URL) { self.pause = pause; self.root = root }
  func prepare(attachmentID: UUID, for use: SyncedAttachmentUse) async throws -> URL {
    await pause.suspend()
    return root.appendingPathComponent("prepared")
  }
  func clearDownloads() {}
  func transferStates() -> [UUID: CloudAttachmentTransferState] { [:] }
}

private actor AdmissionOrder {
  var recorded: [String] = []
  func append(_ value: String) { recorded.append(value) }
  func values() -> [String] { recorded }
}

func waitForQueuedMutations(_ persistence: SwiftDataSyncModePersistence, count: Int) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while await persistence.activeMutationWaiters.count != count {
    guard ContinuousClock.now < deadline else { throw AdmissionTestError.timedOut }
    try await Task.sleep(for: .milliseconds(1))
  }
}

private actor AdmissionRetirementPause {
  let pause: AutomaticSyncPause
  var armed = false
  init(pause: AutomaticSyncPause) { self.pause = pause }
  func arm() { armed = true }
  func hit(_ point: SyncModeWritePoint) async {
    if armed, point == .beforeStoreRetirement { await pause.suspend() }
  }
}

private enum AdmissionTestError: Error { case timedOut }
