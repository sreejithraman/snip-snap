import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

extension CloudFullSyncPersistenceTests {
  func testTokenlessEngineRestartDiscardsEarlierAttemptPresence() async throws {
    try await assertFreshEngineDiscardsEarlierAttemptPresence(checkpointed: false)
  }

  func testIncompleteCheckpointEngineRestartDiscardsEarlierAttemptPresence() async throws {
    try await assertFreshEngineDiscardsEarlierAttemptPresence(checkpointed: true)
  }

  func testInitialFetchInventoryStartsGrowsAndEndsAcrossReopen() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "InventoryLifecycle")
    defer { store.remove() }
    let zone = store.zone
    let inboxRecord = try store.inboxRecord()
    let snip = Snip(content: "observed by the first fetch", origin: .quickEntry)
    let snipRecord = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.snipDraft(snip, in: zone)
    ))
    let inbox = CloudFullSyncPersistence.storageIdentity(inboxRecord.id)
    let observedSnip = CloudFullSyncPersistence.storageIdentity(snipRecord.id)

    try await store.persistence.prepareInitialFetch()
    try await store.expectInventory([], canProveAbsence: true, revision: 1, "a fresh engine")
    try await store.expect(.notEnrolled, pending: false, revision: 1, "a fresh engine keeps the phase")
    try await store.apply(store.fetch([.record(inboxRecord), .record(snipRecord)], initial: true))
    try await store.expectInventory([inbox, observedSnip], canProveAbsence: true, revision: 2,
      "an initial batch")

    var reopened = try store.reopened()
    try await reopened.expectInventory([inbox, observedSnip], canProveAbsence: true, revision: 2,
      "reopen during the attempt")
    try await reopened.apply(reopened.fetch([.deleted(snipRecord.id)], initial: true))
    try await reopened.expectInventory([inbox], canProveAbsence: true, revision: 3, "an initial deletion")
    try await reopened.apply(reopened.fetch([.failed(nil, .retryable)], initial: true))
    try await reopened.expectInventory([inbox], canProveAbsence: false, revision: 4, "a failed initial batch")
    reopened = try reopened.reopened()
    try await reopened.expectInventory([inbox], canProveAbsence: false, revision: 4,
      "reopen after losing absence proof")

    try await reopened.apply(reopened.fetch())
    try await reopened.expectNoInventory(revision: 5, "an incremental fetch")
    try await reopened.persistence.saveEngineState(reopened.engineState(requiresInitialFetch: true))
    try await reopened.expectInventory([], canProveAbsence: true, revision: 6, "a first initial checkpoint")
    try await reopened.persistence.saveEngineState(reopened.engineState(requiresInitialFetch: true))
    try await reopened.expectInventory([], canProveAbsence: true, revision: 6, "a later initial checkpoint")
    try await reopened.persistence.prepareInitialFetch()
    try await reopened.expectInventory([], canProveAbsence: true, revision: 7, "a fresh engine restarts")
    try await reopened.persistence.saveEngineState(reopened.engineState(requiresInitialFetch: true))
    try await reopened.expectInventory([], canProveAbsence: true, revision: 7,
      "a checkpoint during a started attempt")
    try await reopened.apply(reopened.fetch([.record(inboxRecord)], initial: true))
    try await reopened.expectInventory([inbox], canProveAbsence: true, revision: 8,
      "an initial batch after the checkpoint")

    try await reopened.apply(reopened.fetch())
    try await reopened.expectNoInventory(revision: 9, "a second incremental fetch")
    try await reopened.persistence.saveEngineState(reopened.engineState(requiresInitialFetch: false))
    try await reopened.expectNoInventory(revision: 9, "an incremental checkpoint")
    try await reopened.apply(reopened.fetch([.record(inboxRecord)], initial: true))
    try await reopened.expectInventory([inbox], canProveAbsence: false, revision: 10,
      "an initial batch that resumes a token")
    try await reopened.expect(.active, pending: false, revision: 10, "inventory steps keep the phase")
  }

  func testTokenlessInitialFetchStartsItsOwnInventory() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "InventoryImplicitStart")
    defer { store.remove() }
    let inboxRecord = try store.inboxRecord()

    try await store.apply(store.fetch([.record(inboxRecord)], initial: true))

    try await store.expectInventory([CloudFullSyncPersistence.storageIdentity(inboxRecord.id)],
      canProveAbsence: true, revision: 1, "a tokenless initial batch")
    try await store.expect(.active, pending: false, revision: 1, "a tokenless initial batch")
  }

  private func assertFreshEngineDiscardsEarlierAttemptPresence(checkpointed: Bool) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullFetchRestart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let list = SnipList(id: UUID(), name: "Gone after restart", systemImage: "folder", position: 1)
    let earlierSnip = Snip(content: "also gone after restart", origin: .quickEntry, listID: list.id)
    let listSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
    ))
    let earlierSnipSnapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.snipDraft(earlierSnip, in: zone)
    ))
    if checkpointed {
      try await persistence.saveEngineState(CloudEngineStateEnvelope(
        namespace: namespace, serialization: Data("initial-checkpoint".utf8), requiresInitialFetch: true
      ))
    }
    let earlier = CloudFetchedBatch(
      id: UUID(), items: [.record(listSnapshot), .record(earlierSnipSnapshot)],
      engineState: nil, isInitialFetch: true
    )
    try await persistence.stage(.fetched(earlier))
    try await persistence.applyStaged(earlier.id)

    // A new engine does not resume this attempt. Its full zone now contains only
    // a different snip; the previously observed list and snip have disappeared.
    let orphan = Snip(content: "recover after restart", origin: .quickEntry, listID: list.id)
    let server = FakeCloudServer()
    _ = try await server.send(CloudOutboundBatch(operations: [
      .save(CloudFullRecordCodec.snipDraft(orphan, in: zone))
    ]), failures: [:])
    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
    let restarted = CloudFullSyncPersistence(library: reopened, namespace: namespace, dataZone: zone)
    let coordinator = CloudFullSyncCoordinator(
      store: restarted, transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await coordinator.fetchRemote()

    let local = await reopened.snapshot(sortedBy: .manual)
    XCTAssertEqual(local.snips.first { $0.id == orphan.id }?.listID, SnipList.inbox.id)
    XCTAssertFalse(local.snips.contains { $0.id == earlierSnip.id })
    let stored = try await reopened.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertFalse((stored.readyEntities + stored.deferredEntities).contains {
      $0.reference.domainID == list.id || $0.reference.domainID == earlierSnip.id
    })
    XCTAssertTrue(stored.deferredEntities.isEmpty)
    let pending = try await restarted.pendingChanges()
    XCTAssertTrue(pending.operations.contains { $0.id == .snip(orphan.id, in: zone) })
  }
}
