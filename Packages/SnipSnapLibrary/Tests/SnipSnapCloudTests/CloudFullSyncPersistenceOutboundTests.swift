import Foundation
import SnipSnapCore
import SwiftData
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

extension CloudFullSyncPersistenceTests {
  func testDeleteLedgerRetriesAfterItemFailureAndSettlesOnlyAfterAcceptance() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudDeleteLedgerRetry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "delete me",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a Snip")
    }
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    try await store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    try await coordinator.sync()
    _ = try await library.perform(.delete(ids: [snipID]), sortedBy: .manual)
    let recordID = CloudRecordID.snip(snipID, in: zone)
    await transport.failNextSentItem(recordID, failure: .retryable)

    try await coordinator.sendPending()

    let afterFailure = try await library.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    let pendingAfterFailure = try await store.pendingChanges()
    let serverAfterFailure = await server.fullSnapshot(for: recordID)
    XCTAssertEqual(afterFailure.pendingDeletes.map(\.reference.domainID), [snipID])
    XCTAssertEqual(pendingAfterFailure.operations.map(\.id), [recordID])
    XCTAssertNotNil(serverAfterFailure)

    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let reopenedStore = CloudFullSyncPersistence(
      library: reopenedLibrary,
      namespace: namespace,
      dataZone: zone
    )
    let reopened = CloudFullSyncCoordinator(
      store: reopenedStore,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await reopened.sendPending()

    let settled = try await reopenedLibrary.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    let pendingAfterAcceptance = try await reopenedStore.pendingChanges()
    let serverAfterAcceptance = await server.fullSnapshot(for: recordID)
    let acceptedDeletionCount = await server.acceptedDeletionCount()
    XCTAssertTrue(settled.pendingDeletes.isEmpty)
    XCTAssertTrue(pendingAfterAcceptance.operations.isEmpty)
    XCTAssertNil(serverAfterAcceptance)
    XCTAssertEqual(acceptedDeletionCount, 1)
  }

  func testDomainReadFailureStopsBeforeAnyCloudSend() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullReadFailureTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let added = try await library.perform(
      .add(
        content: "must not send stale cache",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let schema = Schema(versionedSchema: SnipSnapSchemaV4.self)
    let configuration = ModelConfiguration(
      "SnipSnapLocal",
      schema: schema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(
      for: schema,
      migrationPlan: SnipSnapSchemaMigrationPlan.self,
      configurations: [configuration]
    )
    let context = ModelContext(container)
    let record = try XCTUnwrap(
      try context.fetch(FetchDescriptor<StoredSnipRecord>()).first(where: { $0.id == snipID })
    )
    record.origin = "not-a-snip-origin"
    try context.save()

    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let coordinator = CloudFullSyncCoordinator(store: persistence, transport: transport)

    await XCTAssertThrowsErrorAsync {
      try await coordinator.sync()
    }

    let acceptedCount = await server.acceptedOperationCount(for: .snip(snipID, in: zone))
    XCTAssertEqual(acceptedCount, 0)
  }

  func testSentFailuresProduceTypedRetryAndTerminalEvidence() async throws {
    for (failure, retryable, needsAttention) in [
      (CloudOperationFailure.retryable, true, false),
      (.quotaExceeded, false, true),
      (.rejected, false, true),
      (.invalidRecord, false, true),
    ] {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudFullSentEvidenceTests-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let namespace = makeNamespace()
      let zone = try XCTUnwrap(namespace.zones.first)
      let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
      let persistence = CloudFullSyncPersistence(
        library: library,
        namespace: namespace,
        dataZone: zone
      )
      try await persistence.approveEnrollment(
        references: [CloudEntityReference(kind: .list, domainID: SnipList.inbox.id)]
      )
      let outbound = try await persistence.pendingChanges()
      let operation = try XCTUnwrap(outbound.operations.first)
      let sent = CloudSentBatch(
        id: UUID(),
        items: [.failed(operation.id, failure)],
        engineState: nil
      )
      try await persistence.stage(.sent(sent), outbound: outbound)
      try await persistence.applyStaged(sent.id)

      let evidence = try await persistence.enrollmentEvidence()
      XCTAssertEqual(evidence.hasRetryableRecordFailures, retryable)
      XCTAssertEqual(evidence.needsAttention, needsAttention)
      XCTAssertEqual(evidence.retryableEventKeys.isEmpty, !retryable)
    }
  }

  func testSentResultsBindByIdentityNotArrayOrderAndRejectMalformedBatches() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullSentBindingTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let list = SnipList(id: UUID(), name: "Bound", systemImage: "link", position: 1)
    let snip = Snip(content: "bound", origin: .quickEntry, listID: list.id)
    let listDraft = try CloudFullRecordCodec.listDraft(list, updatedAt: .distantPast, in: zone)
    let snipDraft = try CloudFullRecordCodec.snipDraft(snip, in: zone)
    let outbound = CloudOutboundBatch(operations: [.save(listDraft), .save(snipDraft)])
    let listSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: listDraft)
    )
    let snipSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: snipDraft)
    )
    let valid = CloudSentBatch(
      id: UUID(),
      items: [.saved(snipSnapshot), .saved(listSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.sent(valid), outbound: outbound)
    let staged = try await persistence.stagedBatches()
    XCTAssertEqual(staged.first?.outboundBindings.map(\.identity.recordName), [
      listDraft.id.name,
      snipDraft.id.name,
    ].sorted())
    try await persistence.applyStaged(valid.id)
    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertEqual(local.snips.first(where: { $0.id == snip.id })?.listID, list.id)

    let malformed: [[CloudSendItemResult]] = [
      [.saved(listSnapshot)],
      [.saved(listSnapshot), .saved(listSnapshot)],
      [.saved(listSnapshot), .saved(snipSnapshot), .unknownItem(CloudRecordID.list(UUID(), in: zone))],
    ]
    for items in malformed {
      let batch = CloudSentBatch(id: UUID(), items: items, engineState: nil)
      await XCTAssertThrowsErrorAsync {
        try await persistence.stage(.sent(batch), outbound: outbound)
      }
    }
    let remainingStaged = try await persistence.stagedBatches()
    XCTAssertTrue(remainingStaged.isEmpty)
    let recoveries = try await library.cloudFullRecoveryEvents(
      namespaceKey: namespace.canonicalKey
    )
    XCTAssertEqual(recoveries.count, malformed.count)
    XCTAssertTrue(recoveries.allSatisfy { $0.kind == .malformedSentBatch })
  }

  func testDuplicateOutboundIdentityIsRejectedBeforeFakeTransportCallsServer() async throws {
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
    try await transport.start(state: nil)
    let draft = try CloudFullRecordCodec.snipDraft(
      Snip(content: "duplicate", origin: .quickEntry),
      in: zone
    )
    let outbound = CloudOutboundBatch(operations: [.save(draft), .save(draft)])
    await XCTAssertThrowsErrorAsync {
      _ = try await transport.send(outbound)
    }
    let acceptedCount = await server.acceptedOperationCount(for: draft.id)
    let events = await transport.events()
    XCTAssertEqual(acceptedCount, 0)
    XCTAssertEqual(events, [.started])
  }

  func testMalformedTransportResultStaysPendingAndNeverAdvancesOrConfirms() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullMalformedTransportTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
      .add(
        content: "pending malformed result",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    let local = await library.snapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first)
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    try await persistence.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snip.id),
    ])
    await transport.omitNextSentResult(CloudRecordID.snip(snip.id, in: zone))
    let coordinator = CloudFullSyncCoordinator(store: persistence, transport: transport)
    await XCTAssertThrowsErrorAsync { try await coordinator.sendPending() }
    await XCTAssertThrowsErrorAsync { try await coordinator.sendPending() }

    let recoveries = try await library.cloudFullRecoveryEvents(
      namespaceKey: namespace.canonicalKey
    )
    let staged = try await persistence.stagedBatches()
    let wire = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.canonicalKey)
    let events = await transport.events()
    XCTAssertEqual(recoveries.count, 1)
    XCTAssertTrue(staged.isEmpty)
    XCTAssertNotNil(wire.engineState)
    XCTAssertEqual(
      events.filter { event in
        if case .confirmed = event { return true }
        return false
      }.count,
      1,
      "only the required bootstrap fetch may be confirmed"
    )
  }

  func testUnknownSaveRecoversLocalEditUnderNewIdentityAndUnknownDeleteCompletes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullUnknownItemTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let server = FakeCloudServer()
    let snip = Snip(content: "base", origin: .quickEntry)
    let inboxDraft = try CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)
    let snipDraft = try CloudFullRecordCodec.snipDraft(snip, in: zone)
    let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
    try await writer.start(state: nil)
    let seed = try await writer.send(
      CloudOutboundBatch(operations: [.save(inboxDraft), .save(snipDraft)])
    )
    try await writer.confirmApplied(seed.id)

    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let coordinator = CloudFullSyncCoordinator(
      store: persistence,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    try await coordinator.fetchRemote()
    let local = await library.snapshot(sortedBy: .manual)
    let received = try XCTUnwrap(local.snips.first(where: { $0.id == snip.id }))

    let currentServerSnapshot = await server.fullSnapshot(for: snipDraft.id)
    let currentServer = try XCTUnwrap(currentServerSnapshot)
    let deletingWriter = FakeCloudRecordTransport(server: server, namespace: namespace)
    try await deletingWriter.start(state: nil)
    let remoteDelete = try await deletingWriter.send(
      CloudOutboundBatch(operations: [.delete(snipDraft.id, base: currentServer.shadow)])
    )
    try await deletingWriter.confirmApplied(remoteDelete.id)

    _ = try await library.perform(
      .update(
        id: snip.id,
        content: "local edit",
        attachmentURLs: nil,
        expectedUpdatedAt: received.updatedAt,
        now: Date(timeIntervalSince1970: 10)
      ),
      sortedBy: .manual
    )
    try await coordinator.sendPending()
    let afterUnknownSave = await library.snapshot(sortedBy: .manual)
    XCTAssertFalse(afterUnknownSave.snips.contains(where: { $0.id == snip.id }))
    let recovered = try XCTUnwrap(afterUnknownSave.snips.first)
    XCTAssertNotEqual(recovered.id, snip.id)
    XCTAssertEqual(recovered.content, "local edit")
    XCTAssertEqual(recovered.listID, SnipList.inbox.id)
    let pendingAfterSave = try await persistence.pendingChanges()
    XCTAssertEqual(pendingAfterSave.operations.count, 1)
    XCTAssertEqual(pendingAfterSave.operations.first?.id, .snip(recovered.id, in: zone))
    XCTAssertFalse(pendingAfterSave.operations.contains(where: { $0.id == snipDraft.id }))
    let unknownSaveEvidence = try await persistence.enrollmentEvidence()
    XCTAssertFalse(unknownSaveEvidence.needsAttention)
    XCTAssertTrue(unknownSaveEvidence.retryableEventKeys.isEmpty)
    var stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    XCTAssertFalse(stored.readyEntities.contains(where: { $0.reference.domainID == snip.id }))

    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let review = try await reopenedLibrary.recoverySnapshot(
      in: SnipRecoveryScope(namespace.canonicalKey)
    )
    XCTAssertEqual(review.promotedSnips.map(\.id), [recovered.id])
    XCTAssertEqual(review.promotedSnips.first?.currentSnipID, snip.id)

    _ = try await library.perform(.delete(ids: [recovered.id]), sortedBy: .manual)
    try await coordinator.sendPending()
    let pendingAfterDelete = try await persistence.pendingChanges()
    XCTAssertTrue(pendingAfterDelete.operations.isEmpty)
    stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    XCTAssertFalse(stored.readyEntities.contains(where: { $0.reference.domainID == snip.id }))
  }

}
