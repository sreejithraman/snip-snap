import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnapCloud

final class CloudPendingSnapshotTests: XCTestCase {
  func testEmptySnapshotWithdrawsCapturedUnsentRecordsForTheWholeCycle() throws {
    let zone = CloudZoneID(name: "data", ownerName: "owner")
    let id = CloudRecordID(zone: zone, name: "record")
    let desired = CloudOutboundBatch(operations: [.delete(id, base: nil)])
    var queue = CloudRecordOutboundQueue()
    _ = queue.schedule(desired)
    queue.beginCycle()
    let captured = try XCTUnwrap(queue.cycle)
    // Apple's batch helper can suspend after the provider captures this cycle.
    _ = queue.schedule(CloudOutboundBatch(operations: []))
    _ = queue.schedule(desired)
    XCTAssertEqual(captured.operations(pendingIDs: [id]), desired.operations)
    XCTAssertEqual(queue.cycle?.operations(pendingIDs: [id]), [])
    let batchID = UUID()
    XCTAssertTrue(queue.finishCycle(batchID).operations.isEmpty)
    queue.confirm(CloudSentBatch(id: batchID, items: [], engineState: nil))
    queue.beginCycle()
    XCTAssertEqual(queue.cycle?.operations(pendingIDs: [id]), desired.operations)
  }

  func testActionSwitchWithdrawsCapturedRecordsButPreservesSuppliedAcknowledgements() throws {
    let zone = CloudZoneID(name: "data", ownerName: "owner")
    let saveID = CloudRecordID(zone: zone, name: "save")
    let deleteID = CloudRecordID(zone: zone, name: "delete")
    let suppliedID = CloudRecordID(zone: zone, name: "supplied")
    let original = CloudRecordDraft.text(id: saveID, snipID: UUID(), text: "original")
    let supplied = CloudRecordDraft.text(id: suppliedID, snipID: UUID(), text: "supplied")
    let newer = CloudRecordDraft.text(id: suppliedID, snipID: UUID(), text: "newer")
    let restored = CloudOutboundBatch(operations: [.save(original), .delete(deleteID, base: nil), .save(newer)])
    var queue = CloudRecordOutboundQueue()
    _ = queue.schedule(CloudOutboundBatch(operations: [.save(original), .delete(deleteID, base: nil), .save(supplied)]))
    queue.beginCycle()
    queue.recordSupplied([suppliedID])
    let captured = try XCTUnwrap(queue.cycle)
    _ = queue.schedule(CloudOutboundBatch(operations: [
      .delete(saveID, base: nil), .save(.text(id: deleteID, snipID: UUID(), text: "replacement")), .save(newer),
    ]))
    _ = queue.schedule(restored)
    XCTAssertEqual(captured.operations(pendingIDs: [saveID, deleteID]).count, 2)
    XCTAssertEqual(queue.cycle?.operations(pendingIDs: [saveID, deleteID]), [])
    XCTAssertEqual(queue.cycle?.draft(suppliedID), supplied)
    let batchID = UUID()
    XCTAssertEqual(queue.finishCycle(batchID).operations, [.save(supplied)])
    queue.confirm(CloudSentBatch(id: batchID, items: [], engineState: nil))
    queue.beginCycle()
    XCTAssertEqual(queue.cycle?.operations(pendingIDs: [saveID, deleteID, suppliedID]), restored.operations)
  }

  func testCrossRecordUndoRemovesUnsentWorkWhileAnotherRecordIsFrozen() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let x = fixture.snips[0], y = fixture.snips[1], z = fixture.snips[2]
    try await fixture.edit(x.id, content: "X edited")
    try await fixture.coordinator.prepareAutomaticSync()
    await fixture.transport.beginCycle()
    await fixture.transport.supplyCycle()

    try await fixture.edit(y.id, content: "Y edited")
    try await fixture.coordinator.prepareAutomaticSync()
    let queuedEdit = await fixture.transport.current()
    XCTAssertTrue(queuedEdit.operations.contains { $0.id == fixture.recordID(y.id) })
    try await fixture.edit(y.id, content: y.content)
    try await fixture.coordinator.prepareAutomaticSync()
    let afterUndo = await fixture.transport.current()
    XCTAssertFalse(afterUndo.operations.contains { $0.id == fixture.recordID(y.id) })

    let firstSend = try await fixture.transport.completeCycle(on: fixture.server, state: fixture.state)
    XCTAssertEqual(firstSend.operations.map(\.id), [fixture.recordID(x.id)])
    try await fixture.coordinator.processAutomaticChanges()
    try await fixture.edit(z.id, content: "Z edited")
    try await fixture.coordinator.prepareAutomaticSync()
    await fixture.transport.beginCycle()
    let nextSend = try await fixture.transport.completeCycle(on: fixture.server, state: fixture.state)
    XCTAssertEqual(nextSend.operations.map(\.id), [fixture.recordID(z.id)])
    try await fixture.coordinator.processAutomaticChanges()
    let remoteY = await fixture.server.fullSnapshot(for: fixture.recordID(y.id))
    XCTAssertEqual(remoteY?.encryptedFields["text"], .string(y.content))
  }

  func testEmptySnapshotRemovesCreatedThenDeletedRecordWithoutLosingFrozenAcknowledgement() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let x = fixture.snips[0], z = fixture.snips[2]
    try await fixture.edit(x.id, content: "X edited")
    try await fixture.coordinator.prepareAutomaticSync()
    await fixture.transport.beginCycle()
    await fixture.transport.supplyCycle()
    let added = try await fixture.library.perform(.add(content: "temporary Y", origin: .quickEntry,
      source: nil, listID: SnipList.inbox.id, attachmentURLs: [], requestID: UUID(), now: Date()), sortedBy: .manual)
    guard case .add(.added(let y)) = added.outcome else { return XCTFail("Expected a saved snip") }
    try await fixture.coordinator.prepareAutomaticSync()
    _ = try await fixture.library.perform(.delete(ids: [y]), sortedBy: .manual)
    try await fixture.edit(x.id, content: x.content)
    let desired = try await fixture.store.pendingChanges()
    XCTAssertTrue(desired.operations.isEmpty)
    try await fixture.coordinator.prepareAutomaticSync()
    let emptied = await fixture.transport.current()
    XCTAssertTrue(emptied.operations.isEmpty)

    // X was already frozen. Its returned body must still commit before the undo sends.
    let firstSend = try await fixture.transport.completeCycle(on: fixture.server, state: fixture.state)
    XCTAssertEqual(firstSend.operations.map(\.id), [fixture.recordID(x.id)])
    try await fixture.coordinator.processAutomaticChanges()
    try await fixture.edit(z.id, content: "Z edited")
    try await fixture.coordinator.prepareAutomaticSync()
    await fixture.transport.beginCycle()
    let nextSend = try await fixture.transport.completeCycle(on: fixture.server, state: fixture.state)
    XCTAssertEqual(Set(nextSend.operations.map(\.id)), [fixture.recordID(x.id), fixture.recordID(z.id)])
    try await fixture.coordinator.processAutomaticChanges()
    let remoteY = await fixture.server.fullSnapshot(for: fixture.recordID(y))
    let remoteX = await fixture.server.fullSnapshot(for: fixture.recordID(x.id))
    XCTAssertNil(remoteY)
    XCTAssertEqual(remoteX?.encryptedFields["text"], .string(x.content))
  }

  func testFullSnapshotsDropObsoleteZonesAndKeepOnlyStillDesiredRetries() {
    let zone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let x = CloudRecordID(zone: zone, name: "x")
    let y = CloudRecordID(zone: zone, name: "y")
    var queue = CloudRecordOutboundQueue()
    _ = queue.schedule(CloudOutboundBatch(operations: [.delete(x, base: nil), .delete(y, base: nil)],
      zonesToSave: [zone, payloadZone]))
    queue.beginCycle()
    queue.recordSupplied([x, y])
    _ = queue.schedule(CloudOutboundBatch(operations: [.delete(x, base: nil)], zonesToSave: [zone]))
    let batchID = UUID()
    let sent = queue.finishCycle(batchID)
    XCTAssertEqual(Set(sent.operations.map(\.id)), [x, y])
    XCTAssertEqual(sent.zonesToSave, [zone, payloadZone])
    queue.confirm(CloudSentBatch(id: batchID, items: [.failed(x, .retryable), .failed(y, .retryable)], engineState: nil))
    XCTAssertEqual(queue.current.operations.map(\.id), [x])
    XCTAssertEqual(queue.current.zonesToSave, [zone])
    _ = queue.schedule(CloudOutboundBatch(operations: []))
    XCTAssertTrue(queue.current.operations.isEmpty)
    XCTAssertTrue(queue.current.zonesToSave.isEmpty)
  }

  private struct Fixture {
    let root: URL
    let zone: CloudZoneID
    let state: CloudEngineStateEnvelope
    let snips: [Snip]
    let library: SwiftDataSnipLibrary
    let store: CloudFullSyncPersistence
    let server: FakeCloudServer
    let transport: AdmissionTransport
    let coordinator: CloudFullSyncCoordinator
    func recordID(_ id: UUID) -> CloudRecordID { .snip(id, in: zone) }
    func edit(_ id: UUID, content: String) async throws {
      let snapshot = try await library.checkedSnapshot(sortedBy: .manual)
      let snip = try XCTUnwrap(snapshot.snips.first { $0.id == id })
      _ = try await library.perform(.update(id: id, content: content, attachmentURLs: nil,
        expectedUpdatedAt: snip.updatedAt, now: snip.updatedAt.addingTimeInterval(10)), sortedBy: .manual)
    }
    static func make() async throws -> Self {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("PendingSnapshot-\(UUID())")
      let zone = CloudZoneID(name: "data", ownerName: "owner")
      let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account", generation: UUID(), zones: [zone])
      let state = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("state".utf8), requiresInitialFetch: false)
      let snips = ["X base", "Y base", "Z base"].map { Snip(content: $0, origin: .quickEntry) }
      let server = FakeCloudServer()
      let drafts = [try CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)]
        + (try snips.map { try CloudFullRecordCodec.snipDraft($0, in: zone) })
      let seeded = try await server.send(CloudOutboundBatch(operations: drafts.map(CloudOutboundOperation.save)), failures: [:])
      let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
      let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
      let fetched = CloudFetchedBatch(id: UUID(), items: seeded.items.compactMap {
        if case .saved(let record) = $0 { CloudFetchItemResult.record(record) } else { nil }
      }, engineState: state)
      try await store.stage(.fetched(fetched))
      try await store.applyStaged(fetched.id)
      let transport = AdmissionTransport(zones: namespace.zones)
      return Self(root: root, zone: zone, state: state, snips: snips, library: library, store: store,
        server: server, transport: transport, coordinator: CloudFullSyncCoordinator(store: store, transport: transport))
    }
  }
}
