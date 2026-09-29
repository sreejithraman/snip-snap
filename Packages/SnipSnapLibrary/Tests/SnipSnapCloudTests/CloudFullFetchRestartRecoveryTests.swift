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
