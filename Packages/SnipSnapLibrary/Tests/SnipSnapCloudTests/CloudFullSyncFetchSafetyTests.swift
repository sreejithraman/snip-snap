import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnapCloud

extension CloudFullSyncPersistenceTests {
  func testUnreadableFetchedRecordsBlockMatchingSavesAndDeletesAcrossRestart() async throws {
    try await checkFailedFetchSafety(.invalidRecord)
  }

  func testRetryableFetchedRecordsKeepTheirBlocksUntilThoseRecordsRefetch() async throws {
    try await checkFailedFetchSafety(.networkUnavailable)
  }

  func testSuccessfulRefetchCommitsRecoveryResolutionBeforePostSaveFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FetchRecoveryCrash-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("store")
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let snip = Snip(content: "read after failure", origin: .quickEntry)
    let id = CloudRecordID.snip(snip.id, in: zone)
    let library = try SwiftDataSnipLibrary(storeURL: url)
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let failure = CloudFetchedBatch(id: UUID(), items: [.failed(id, .invalidRecord)], engineState: nil)
    try await store.stage(.fetched(failure))
    try await store.applyStaged(failure.id)
    let drafts = [try CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone),
      try CloudFullRecordCodec.snipDraft(snip, in: zone)]
    let fetched = CloudFetchedBatch(id: UUID(), items: try drafts.map {
      .record(try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: $0)))
    }, engineState: nil)
    let crash = OneShotFullApplyCrash()
    let failingStore = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone,
      afterCommitHook: { try await crash.hit() })
    try await failingStore.stage(.fetched(fetched))
    await XCTAssertThrowsErrorAsync { try await failingStore.applyStaged(fetched.id) }

    let reopened = try SwiftDataSnipLibrary(storeURL: url)
    let local = await reopened.snapshot(sortedBy: .manual)
    let recovery = try await reopened.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
    XCTAssertEqual(local.snips.map(\.content), [snip.content])
    XCTAssertTrue(try CloudFullSyncPersistence.failedFetchRecordIDs(recovery).isEmpty)
  }

  private func checkFailedFetchSafety(_ failure: CloudOperationFailure) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FetchSafety-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("store")
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let saved = Snip(content: "base save", origin: .quickEntry)
    let deleted = Snip(content: "base delete", origin: .quickEntry)
    let unrelated = Snip(content: "base unrelated", origin: .quickEntry)
    let saveID = CloudRecordID.snip(saved.id, in: zone)
    let deleteID = CloudRecordID.snip(deleted.id, in: zone)
    let unrelatedID = CloudRecordID.snip(unrelated.id, in: zone)
    let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
    try await writer.start(state: nil)
    let savedDraft = try CloudFullRecordCodec.snipDraft(saved, in: zone)
    var fields = savedDraft.encryptedFields
    fields["futureField"] = .string("keep me")
    let seed = try await writer.send(CloudOutboundBatch(operations: [
      .save(try CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)),
      .save(CloudRecordDraft(id: savedDraft.id, recordType: savedDraft.recordType,
        schemaVersion: savedDraft.schemaVersion, routingFields: savedDraft.routingFields, encryptedFields: fields)),
      .save(try CloudFullRecordCodec.snipDraft(deleted, in: zone)),
      .save(try CloudFullRecordCodec.snipDraft(unrelated, in: zone)),
    ]))
    try await writer.confirmApplied(seed.id)
    let library = try SwiftDataSnipLibrary(storeURL: url)
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.fetchRemote()
    let local = await library.snapshot(sortedBy: .manual)
    for snip in local.snips where snip.id != deleted.id {
      _ = try await library.perform(.update(id: snip.id, content: "edited \(snip.content)",
        attachmentURLs: nil, expectedUpdatedAt: snip.updatedAt,
        now: snip.updatedAt.addingTimeInterval(10)), sortedBy: .manual)
    }
    _ = try await library.perform(.delete(ids: [deleted.id]), sortedBy: .manual)
    await transport.failNextFetchedItem(saveID, failure: failure)
    await transport.failNextFetchedItem(deleteID, failure: failure)
    try await coordinator.sync()
    let saveCount = await server.acceptedOperationCount(for: saveID)
    let unrelatedCount = await server.acceptedOperationCount(for: unrelatedID)
    let remoteDeleted = await server.fullSnapshot(for: deleteID)
    XCTAssertEqual(saveCount, 1)
    XCTAssertEqual(unrelatedCount, 2)
    XCTAssertNotNil(remoteDeleted)

    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: url)
    let reopenedStore = CloudFullSyncPersistence(library: reopenedLibrary, namespace: namespace, dataZone: zone)
    let reopenedTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
    let reopened = CloudFullSyncCoordinator(store: reopenedStore, transport: reopenedTransport)
    // A successful incremental fetch with no matching records cannot clear their evidence.
    try await reopened.sync()
    let blocked = try await reopenedStore.pendingChanges()
    XCTAssertFalse(blocked.operations.contains { $0.id == saveID || $0.id == deleteID })
    let durable = try await reopenedLibrary.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
    XCTAssertEqual(try CloudFullSyncPersistence.failedFetchRecordIDs(durable), [saveID, deleteID])

    // Try Again must refetch unchanged records; one success clears only its own block.
    try await reopened.prepareManualRetry()
    await reopenedTransport.failNextFetchedItem(deleteID, failure: failure)
    try await reopened.sync()
    let partiallyRecovered = try await reopenedLibrary.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
    XCTAssertEqual(try CloudFullSyncPersistence.failedFetchRecordIDs(partiallyRecovered), [deleteID])
    let updated = await server.fullSnapshot(for: saveID)
    XCTAssertEqual(updated?.encryptedFields["futureField"], .string("keep me"))
    let updatedSaveCount = await server.acceptedOperationCount(for: saveID)
    XCTAssertEqual(updatedSaveCount, 2)
    let stillPresent = await server.fullSnapshot(for: deleteID)
    XCTAssertNotNil(stillPresent)

    try await reopened.prepareManualRetry()
    try await reopened.sync()
    let removed = await server.fullSnapshot(for: deleteID)
    XCTAssertNil(removed)
    let recovered = try await reopenedLibrary.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
    XCTAssertTrue(try CloudFullSyncPersistence.failedFetchRecordIDs(recovered).isEmpty)
  }

  func testDirectReturnedFetchCommitsAfterAnEarlierQueuedCheckpoint() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DirectFetch-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let snip = Snip(content: "returned directly", origin: .quickEntry)
    let drafts = [try CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone),
      try CloudFullRecordCodec.snipDraft(snip, in: zone)]
    let finalState = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("final".utf8),
      requiresInitialFetch: false)
    let fetched = CloudFetchedBatch(id: UUID(), items: try drafts.map {
      .record(try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: $0)))
    }, engineState: finalState)
    let checkpoint = CloudEngineStateEnvelope(namespace: namespace, serialization: Data("earlier".utf8))
    let transport = DirectCheckpointFetchTransport(batch: fetched, checkpoint: checkpoint)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    try await coordinator.fetchRemote()

    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(local.snips.map(\.content), [snip.content])
    let storedState = try await store.loadEngineState()
    XCTAssertEqual(storedState, finalState)
    let confirmations = await transport.confirmed()
    XCTAssertEqual(confirmations.last, fetched.id)
    XCTAssertEqual(confirmations.count, 2)
  }
}

private actor DirectCheckpointFetchTransport: CloudRecordTransport {
  let batch: CloudFetchedBatch
  let checkpoint: CloudEngineStateEnvelope
  let mailbox = CloudRecordTransportMailbox()
  var confirmations: [UUID] = []
  init(batch: CloudFetchedBatch, checkpoint: CloudEngineStateEnvelope) {
    self.batch = batch
    self.checkpoint = checkpoint
  }
  func start(state: CloudEngineStateEnvelope?) {}
  func fetch(scope: CloudFetchScope) -> CloudFetchedBatch {
    mailbox.append(.checkpoint(UUID(), checkpoint))
    return batch
  }
  func pendingEvent() -> CloudRecordTransportEvent? { mailbox.first }
  func confirmApplied(_ id: UUID) throws {
    _ = try mailbox.confirm(id)
    confirmations.append(id)
  }
  func confirmed() -> [UUID] { confirmations }
  func send(_ batch: CloudOutboundBatch) throws -> CloudSentBatch { throw CloudTransportError.invalidRecord }
  func fetchRecord(_ id: CloudRecordID, fields: Set<String>) -> CloudRecordSnapshot? { nil }
  func fetchAsset(_ id: CloudRecordID, field: String, destination: CloudAssetDestination) -> CloudAssetReceipt? { nil }
}
