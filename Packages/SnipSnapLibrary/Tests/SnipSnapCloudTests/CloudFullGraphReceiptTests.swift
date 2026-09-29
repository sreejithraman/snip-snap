import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

extension CloudFullSyncPersistenceTests {
  func testIncrementalTextEditKeepsCorrectionForPreviouslyRepairedRemoteOrphan() async throws {
    let fixture = try await makeRepairedRemoteOrphan()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let edited = remoteEdit(fixture.snip, content: "edited on another device")
    let editedSnapshot = try snipSnapshot(edited, in: fixture.zone)
    let incremental = CloudFetchedBatch(
      id: UUID(), items: [.record(editedSnapshot)], engineState: nil
    )

    try await fixture.persistence.stage(.fetched(incremental))
    try await fixture.persistence.applyStaged(incremental.id)

    try await assertRepairedOrphan(
      fixture, expectedContent: "edited on another device", acceptedContent: "edited on another device"
    )
  }

  func testSaveConflictKeepsCorrectionForPreviouslyRepairedRemoteOrphan() async throws {
    let fixture = try await makeRepairedRemoteOrphan()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outbound = try await fixture.persistence.pendingChanges()
    XCTAssertTrue(outbound.operations.contains { $0.id == fixture.snapshot.id })
    let edited = remoteEdit(fixture.snip, content: "server won text race")
    let serverSnapshot = try snipSnapshot(edited, in: fixture.zone)
    let sentItems = try outbound.operations.map { operation -> CloudSendItemResult in
      if operation.id == fixture.snapshot.id {
        return .conflict(operation.id, server: serverSnapshot)
      }
      switch operation {
      case .save(let draft):
        return .saved(try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft)))
      case .delete:
        return .deleted(operation.id)
      }
    }
    let conflict = CloudSentBatch(id: UUID(), items: sentItems, engineState: nil)

    try await fixture.persistence.stage(.sent(conflict), outbound: outbound)
    try await fixture.persistence.applyStaged(conflict.id)

    try await assertRepairedOrphan(
      fixture, expectedContent: "server won text race", acceptedContent: "server won text race"
    )
  }

  func testRepairedOrphanReceiptSurvivesRestartAndLaterTextEdit() async throws {
    let fixture = try await makeRepairedRemoteOrphan()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: fixture.root.appendingPathComponent("store"))
    let reopened = CloudFullSyncPersistence(
      library: reopenedLibrary, namespace: fixture.namespace, dataZone: fixture.zone
    )
    let edited = remoteEdit(fixture.snip, content: "edited after restart")
    let incremental = CloudFetchedBatch(
      id: UUID(), items: [.record(try snipSnapshot(edited, in: fixture.zone))], engineState: nil
    )

    try await reopened.stage(.fetched(incremental))
    try await reopened.applyStaged(incremental.id)

    try await assertRepairedOrphan(
      fixture, library: reopenedLibrary, persistence: reopened,
      expectedContent: "edited after restart", acceptedContent: "edited after restart"
    )
  }

  func testEarlierRepairDoesNotAuthorizeNewMissingRemoteList() async throws {
    let fixture = try await makeRepairedRemoteOrphan()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let anotherMissingListID = UUID()
    let anotherOrphan = Snip(
      content: "wait for list B", origin: .quickEntry, listID: anotherMissingListID
    )
    let anotherSnapshot = try snipSnapshot(anotherOrphan, in: fixture.zone)
    let incremental = CloudFetchedBatch(
      id: UUID(), items: [.record(anotherSnapshot)], engineState: nil
    )

    try await fixture.persistence.stage(.fetched(incremental))
    try await fixture.persistence.applyStaged(incremental.id)

    let local = await fixture.library.snapshot(sortedBy: .manual)
    XCTAssertFalse(local.snips.contains { $0.id == anotherOrphan.id })
    XCTAssertEqual(local.snips.first { $0.id == fixture.snip.id }?.listID, SnipList.inbox.id)
    let stored = try await fixture.library.cloudFullStorageSnapshot(
      namespaceKey: fixture.namespace.namespaceKey
    )
    XCTAssertTrue(stored.deferredEntities.contains {
      $0.reference.domainID == anotherOrphan.id && $0.dependencyListID == anotherMissingListID
    })
    let pending = try await fixture.persistence.pendingChanges()
    XCTAssertFalse(pending.operations.contains { $0.id == anotherSnapshot.id })
    XCTAssertTrue(pending.operations.contains { $0.id == fixture.snapshot.id })
  }

  private typealias RepairedOrphanFixture = (
    root: URL,
    namespace: CloudSyncNamespace,
    zone: CloudZoneID,
    library: SwiftDataSnipLibrary,
    persistence: CloudFullSyncPersistence,
    snip: Snip,
    snapshot: CloudRecordSnapshot
  )

  private func makeRepairedRemoteOrphan() async throws -> RepairedOrphanFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullGraphReceipt-\(UUID().uuidString)")
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let orphan = Snip(content: "first server text", origin: .quickEntry, listID: UUID())
    let snapshot = try snipSnapshot(orphan, in: zone)
    let initial = CloudFetchedBatch(
      id: UUID(), items: [.record(snapshot)], zoneEvents: [.fetched(zone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace, serialization: Data("initial-complete".utf8),
        requiresInitialFetch: false
      ), isInitialFetch: true
    )
    try await persistence.stage(.fetched(initial))
    try await persistence.applyStaged(initial.id)
    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(local.snips.first { $0.id == orphan.id }?.listID, SnipList.inbox.id)
    let pending = try await persistence.pendingChanges()
    XCTAssertTrue(pending.operations.contains { $0.id == snapshot.id })
    return (root, namespace, zone, library, persistence, orphan, snapshot)
  }

  private func remoteEdit(_ snip: Snip, content: String) -> Snip {
    Snip(
      id: snip.id, requestID: snip.requestID, createdAt: snip.createdAt,
      updatedAt: Date(timeIntervalSince1970: 10), content: content, origin: snip.origin,
      source: snip.source, listID: snip.listID, isDone: snip.isDone,
      pinnedAt: snip.pinnedAt, manualSortKey: snip.manualSortKey
    )
  }

  private func snipSnapshot(_ snip: Snip, in zone: CloudZoneID) throws -> CloudRecordSnapshot {
    try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(snip, in: zone))
    )
  }

  private func assertRepairedOrphan(
    _ fixture: RepairedOrphanFixture,
    library: SwiftDataSnipLibrary? = nil,
    persistence: CloudFullSyncPersistence? = nil,
    expectedContent: String,
    acceptedContent: String
  ) async throws {
    let library = library ?? fixture.library
    let persistence = persistence ?? fixture.persistence
    let local = await library.snapshot(sortedBy: .manual)
    let repaired = try XCTUnwrap(local.snips.first { $0.id == fixture.snip.id })
    XCTAssertEqual(repaired.listID, SnipList.inbox.id)
    XCTAssertEqual(repaired.content, expectedContent)
    let stored = try await library.cloudFullStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
    let accepted = try XCTUnwrap(stored.readyEntities.first { $0.reference.domainID == fixture.snip.id })
    let acceptedFields = try CloudFullSyncPersistence.snipFields(
      CloudFullSyncPersistence.snipRecord(accepted)
    )
    XCTAssertEqual(acceptedFields.text, acceptedContent)
    XCTAssertEqual(acceptedFields.placement.listID, fixture.snip.listID)
    XCTAssertFalse(stored.deferredEntities.contains { $0.reference.domainID == fixture.snip.id })
    let pending = try await persistence.pendingChanges()
    let correction = try XCTUnwrap(pending.operations.first { $0.id == fixture.snapshot.id })
    guard case .save(let draft) = correction else {
      return XCTFail("Expected a placement correction")
    }
    let queued = try CloudFullRecordCodec.snip(from: CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: draft)
    ))
    let queuedFields = try CloudFullSyncPersistence.snipFields(queued)
    XCTAssertEqual(queuedFields.text, expectedContent)
    XCTAssertEqual(queuedFields.placement.listID, SnipList.inbox.id)
  }
}
