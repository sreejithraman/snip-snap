import Foundation
import SnipSnapCore
import SwiftData
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

extension CloudFullSyncPersistenceTests {
  func testAwaitedRetryStopsAfterAListBatchMakesNoProgress() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudListNoProgress-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    try await persistence.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
    ])
    let listID = CloudRecordID.list(SnipList.inbox.id, in: zone)
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
    await transport.failNextSentItem(listID, failure: .retryable)
    let coordinator = CloudFullSyncCoordinator(store: persistence, transport: transport)

    let outcome = try await coordinator.sendPendingUntilSettled()

    let acceptedCount = await server.acceptedOperationCount(for: listID)
    let pending = try await persistence.pendingChanges()
    XCTAssertEqual(acceptedCount, 0)
    XCTAssertEqual(pending.operations.map(\.id), [listID])
    XCTAssertFalse(outcome.settled)
  }

  func testAwaitedRetryDoesNotResendARateLimitedPartialBatch() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudPartialRetryDelay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "Wait for CloudKit",
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
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    try await persistence.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let snipIDInCloud = CloudRecordID.snip(snipID, in: zone)
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
    await transport.failNextSentItem(snipIDInCloud, failure: .rateLimited)
    let coordinator = CloudFullSyncCoordinator(store: persistence, transport: transport)

    let outcome = try await coordinator.sendPendingUntilSettled()

    let sends = await transport.events().compactMap { event -> [CloudRecordID]? in
      guard case .sent(let ids) = event else { return nil }
      return ids
    }
    let pending = try await persistence.pendingChanges()
    XCTAssertEqual(sends.count, 1)
    XCTAssertEqual(pending.operations.map(\.id), [snipIDInCloud])
    XCTAssertEqual(outcome.issue, .retryingSoon)
    XCTAssertFalse(outcome.settled)
  }

  func testAwaitedRetrySendsANewerEditForTheSameRecordID() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudSameRecordFollowUp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "First",
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
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    try await persistence.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace)
    let coordinator = CloudFullSyncCoordinator(store: persistence, transport: transport)
    _ = try await coordinator.sendPendingUntilSettled()
    _ = try await library.perform(
      .update(
        id: snipID,
        content: "Second",
        attachmentURLs: nil,
        expectedUpdatedAt: nil,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )
    await transport.pauseNextSend()
    let sending = Task { try await coordinator.sendPendingUntilSettled() }
    await transport.waitUntilSendPauses()
    _ = try await library.perform(
      .update(
        id: snipID,
        content: "Third",
        attachmentURLs: nil,
        expectedUpdatedAt: nil,
        now: Date(timeIntervalSince1970: 3)
      ),
      sortedBy: .manual
    )
    await transport.resumeSend()

    let outcome = try await sending.value
    let recordID = CloudRecordID.snip(snipID, in: zone)
    let storedSnapshot = await server.fullSnapshot(for: recordID)
    let snapshot = try XCTUnwrap(storedSnapshot)
    let record = try CloudFullRecordCodec.snip(from: snapshot)
    let fields = try CloudFullSyncPersistence.snipFields(record)
    let acceptedCount = await server.acceptedOperationCount(for: recordID)
    let pending = try await persistence.pendingChanges()
    XCTAssertEqual(fields.text, "Third")
    XCTAssertEqual(acceptedCount, 3)
    XCTAssertTrue(pending.operations.isEmpty)
    XCTAssertTrue(outcome.settled)
  }

  func testCorruptAcceptedShadowIsQuarantinedOnceWhenRemoteRecordIsAbsent() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CorruptAcceptedShadow-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let storeURL = root.appendingPathComponent("store")
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let added = try await library.perform(
      .add(
        content: "repair this shadow",
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
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    try await persistence.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let outbound = try await persistence.pendingChanges()
    let fetchedItems = try outbound.operations.compactMap { operation -> CloudFetchItemResult? in
      guard case .save(let draft) = operation else { return nil }
      let record = try CloudKitRecordMapper.record(for: draft)
      return .record(try CloudKitRecordMapper.snapshot(record))
    }
    let fetched = CloudFetchedBatch(id: UUID(), items: fetchedItems, engineState: nil)
    try await persistence.stage(.fetched(fetched), outbound: nil)
    try await persistence.applyStaged(fetched.id)

    let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
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
    let stored = try XCTUnwrap(
      try context.fetch(FetchDescriptor<StoredCloudEntityRecord>()).first(where: {
        $0.domainID == snipID
      })
    )
    stored.shadowData = Data("broken shadow".utf8)
    try context.save()

    do {
      _ = try await persistence.pendingChanges()
      XCTFail("Expected the bad shadow to be reported")
    } catch let error as CloudSyncIssueError {
      XCTAssertEqual(error.issue, .appDataIssue)
    }

    let repaired = try await persistence.pendingChanges()
    let snapshot = try await library.cloudFullStorageSnapshot(
      namespaceKey: namespace.namespaceKey
    )
    XCTAssertEqual(snapshot.quarantines.map(\.reference.domainID), [snipID])
    XCTAssertTrue(repaired.operations.contains(where: { $0.id == .snip(snipID, in: zone) }))
  }

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
      namespaceKey: namespace.namespaceKey
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
      namespaceKey: namespace.namespaceKey
    )
    let pendingAfterAcceptance = try await reopenedStore.pendingChanges()
    let serverAfterAcceptance = await server.fullSnapshot(for: recordID)
    let acceptedDeletionCount = await server.acceptedDeletionCount()
    let automaticSendResult = try await reopened.processAutomaticChanges().result
    XCTAssertTrue(settled.pendingDeletes.isEmpty)
    XCTAssertTrue(pendingAfterAcceptance.operations.isEmpty)
    XCTAssertNil(serverAfterAcceptance)
    XCTAssertEqual(acceptedDeletionCount, 1)
    XCTAssertEqual(automaticSendResult, .syncCompleted)

    let fetchFailure = CloudFetchedBatch(id: UUID(), items: [],
      databaseEvents: [.failed(nil, .networkUnavailable)], engineState: nil)
    try await reopenedStore.stage(.fetched(fetchFailure))
    try await reopenedStore.applyStaged(fetchFailure.id)
    try await reopened.fetchRemote()
    let automaticFetchResult = try await reopened.processAutomaticChanges().result
    XCTAssertEqual(automaticFetchResult, .syncCompleted)
  }

  func testUnattemptedSendDoesNotClearEarlierSendRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudUnattemptedSend-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let outbound = CloudOutboundBatch(operations: [])
    let failed = CloudSentBatch(id: UUID(), items: [],
      databaseEvents: [.failed(zone, .networkUnavailable)], engineState: nil)
    try await store.stage(.sent(failed), outbound: outbound)
    try await store.applyStaged(failed.id)
    let deferred = CloudSentBatch(id: UUID(), items: [], engineState: nil)

    try await store.stage(.sent(deferred), outbound: outbound)
    try await store.applyStaged(deferred.id)

    let pendingIssue = try await store.unresolvedSyncIssue()
    XCTAssertEqual(pendingIssue, .waitingForConnection)
    let accepted = CloudSentBatch(id: UUID(), items: [], databaseEvents: [.zoneSaved(zone)], engineState: nil)
    try await store.stage(.sent(accepted), outbound: outbound)
    try await store.applyStaged(accepted.id)
    let recoveredIssue = try await store.unresolvedSyncIssue()
    XCTAssertNil(recoveredIssue)
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
    let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
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

  func testManualRetryClearsPastCoreQuotaEvidenceAfterTheRecordSends() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullManualQuotaRetry-\(UUID().uuidString)")
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
    let failed = CloudSentBatch(
      id: UUID(),
      items: [.failed(operation.id, .quotaExceeded)],
      engineState: nil
    )
    try await persistence.stage(.sent(failed), outbound: outbound)
    try await persistence.applyStaged(failed.id)
    let issueBeforeRetry = try await persistence.unresolvedSyncIssue()
    XCTAssertEqual(issueBeforeRetry, .iCloudStorageFull)

    try await persistence.prepareManualRetry()
    let server = FakeCloudServer()
    let coordinator = CloudFullSyncCoordinator(
      store: persistence,
      transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    let retry = try await coordinator.sendPending()

    let issueAfterRetry = try await persistence.unresolvedSyncIssue()
    let pendingAfterRetry = try await persistence.pendingChanges()
    let acceptedCount = await server.acceptedOperationCount(for: operation.id)
    XCTAssertNil(issueAfterRetry)
    XCTAssertTrue(pendingAfterRetry.operations.isEmpty)
    XCTAssertEqual(acceptedCount, 1)
    XCTAssertTrue(retry.settled)
  }

  func testManualRetryClearsMixedRetryableFailuresButKeepsBlockedFailures() async throws {
    for (secondFailure, keepsEvidence) in [
      (CloudOperationFailure.retryable, false),
      (.updateRequired, true),
      (.accessDenied, true),
    ] {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudFullMixedManualRetry-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let namespace = makeNamespace()
      let zone = try XCTUnwrap(namespace.zones.first)
      let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
      let update = try await library.perform(
        .add(
          content: "mixed terminal retry",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inbox.id,
          attachmentURLs: [],
          requestID: UUID(),
          now: .distantPast
        ),
        sortedBy: .manual
      )
      guard case .add(.added(let snipID)) = update.outcome else {
        return XCTFail("Expected a saved snip")
      }
      let persistence = CloudFullSyncPersistence(
        library: library,
        namespace: namespace,
        dataZone: zone
      )
      try await persistence.approveEnrollment(references: [
        CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
        CloudEntityReference(kind: .snip, domainID: snipID),
      ])
      let outbound = try await persistence.pendingChanges()
      XCTAssertEqual(outbound.operations.count, 2)
      let sent = CloudSentBatch(
        id: UUID(),
        items: [
          .failed(outbound.operations[0].id, .quotaExceeded),
          .failed(outbound.operations[1].id, secondFailure),
        ],
        engineState: nil
      )
      try await persistence.stage(.sent(sent), outbound: outbound)
      try await persistence.applyStaged(sent.id)

      try await persistence.prepareManualRetry()

      let recovery = try await library.cloudFullRecoveryEvents(
        namespaceKey: namespace.namespaceKey
      )
      XCTAssertEqual(recovery.map(\.kind), keepsEvidence ? [.terminalSend] : [])
    }
  }

  func testTerminalCleanupFailureWithCoreLikePayloadNameStaysRowScoped() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullPrefixedCleanupTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let namespace = CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "account",
      generation: UUID(),
      zones: [dataZone, payloadZone]
    )
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let attachmentID = UUID()
    let metadataIdentity = CloudTextStorageIdentity(
      zoneName: dataZone.name,
      ownerName: dataZone.ownerName,
      recordName: "a-\(attachmentID.uuidString.lowercased())"
    )
    let payloadIdentity = CloudTextStorageIdentity(
      zoneName: payloadZone.name,
      ownerName: payloadZone.ownerName,
      recordName: "s-valid-remote-payload"
    )
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [
        .remoteMetadataAccepted(
          metadata: CloudAttachmentMetadataValue(
            attachmentID: attachmentID,
            snipID: UUID(),
            position: 0,
            fileName: "remote.txt",
            contentType: "text/plain",
            byteCount: 1,
            sha256: Data(repeating: 1, count: 32),
            payloadIdentity: payloadIdentity
          ),
          metadataIdentity: metadataIdentity,
          shadowData: Data(),
          systemFields: Data()
        ),
      ]
    )
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [.remoteMetadataDeleted(metadataIdentity: metadataIdentity)]
    )
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    let outbound = try await persistence.pendingChanges()
    let cleanup = try XCTUnwrap(outbound.operations.first(where: {
      $0.id == CloudAttachmentRecordCodec.recordID(payloadIdentity)
    }))
    let sent = CloudSentBatch(
      id: UUID(),
      items: [.failed(cleanup.id, .rejected)],
      engineState: nil
    )

    try await persistence.stage(.sent(sent), outbound: outbound)
    try await persistence.applyStaged(sent.id)

    let evidence = try await persistence.enrollmentEvidence()
    XCTAssertFalse(evidence.needsAttention)
    let attachments = try await library.cloudAttachmentStorageSnapshot(
      namespaceKey: namespace.namespaceKey
    )
    XCTAssertEqual(attachments.cleanups.first?.lastFailure, .rejected)
    let recovery = try await library.cloudFullRecoveryEvents(
      namespaceKey: namespace.namespaceKey
    )
    XCTAssertFalse(recovery.contains(where: { $0.kind == .terminalSend }))
  }

  func testDormantAttachmentIdentityCannotCaptureCoreTerminalResults() async throws {
    for sendsConflict in [false, true] {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDormantAttachmentCollisionTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "payload", ownerName: "owner")
    let namespace = CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "account",
      generation: UUID(),
      zones: [dataZone, payloadZone]
    )
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "local with remote attachment",
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
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: payloadZone
    )
    try await persistence.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: snipID),
    ])
    let initialOutbound = try await persistence.pendingChanges()
    let listOperation = try XCTUnwrap(initialOutbound.operations.first(where: {
      if case .save(let draft) = $0 { return draft.recordType == "List" }
      return false
    }))
    let attachmentID = UUID()
    let collidingMetadataIdentity = CloudFullSyncPersistence.storageIdentity(listOperation.id)
    let payloadIdentity = CloudTextStorageIdentity(
      zoneName: payloadZone.name,
      ownerName: payloadZone.ownerName,
      recordName: "p-\(UUID().uuidString.lowercased())"
    )
    let metadata = CloudAttachmentMetadataValue(
      attachmentID: attachmentID,
      snipID: snipID,
      position: 0,
      fileName: "remote.txt",
      contentType: "text/plain",
      byteCount: 1,
      sha256: Data(repeating: 1, count: 32),
      payloadIdentity: payloadIdentity
    )
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace.namespaceKey,
      transitions: [.remoteMetadataAccepted(
        metadata: metadata,
        metadataIdentity: collidingMetadataIdentity,
        shadowData: Data(),
        systemFields: Data()
      )]
    )
    let beforeSnapshot = try await library.cloudAttachmentStorageSnapshot(
      namespaceKey: namespace.namespaceKey
    )
    let before = try XCTUnwrap(beforeSnapshot.publications.first(where: {
      $0.metadata.attachmentID == attachmentID
    }))
    let outbound = try await persistence.pendingChanges()
    XCTAssertFalse(outbound.operations.contains(where: { operation in
      guard operation.id == listOperation.id else { return false }
      if case .delete = operation { return true }
      return false
    }))
    let conflictDraft = CloudRecordDraft(
      id: listOperation.id,
      recordType: CloudAttachmentRecordCodec.metadataRecordType,
      schemaVersion: CloudAttachmentRecordCodec.schemaVersion,
      routingFields: ["schemaVersion": .int64(1)],
      encryptedFields: [
        "attachmentID": .string(attachmentID.uuidString.lowercased()),
        "snipID": .string(snipID.uuidString.lowercased()),
        "position": .int64(0),
        "fileName": .string(metadata.fileName),
        "contentType": .string("text/plain"),
        "byteCount": .int64(metadata.byteCount),
        "sha256": .data(metadata.sha256),
        "payloadZoneName": .string(payloadIdentity.zoneName),
        "payloadOwnerName": .string(payloadIdentity.ownerName),
        "payloadRecordName": .string(payloadIdentity.recordName),
      ]
    )
    let conflictSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: conflictDraft)
    )
    let sentItems = try outbound.operations.map { operation -> CloudSendItemResult in
      if operation.id == listOperation.id {
        return sendsConflict
          ? .conflict(operation.id, server: conflictSnapshot)
          : .failed(operation.id, .rejected)
      }
      guard case .save(let draft) = operation else {
        return .deleted(operation.id)
      }
      return .saved(try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft)))
    }
    let sent = CloudSentBatch(id: UUID(), items: sentItems, engineState: nil)

    try await persistence.stage(.sent(sent), outbound: outbound)
    try await persistence.applyStaged(sent.id)

    let evidence = try await persistence.enrollmentEvidence()
    XCTAssertTrue(evidence.needsAttention)
    XCTAssertFalse(evidence.blocksSending)
    let attachments = try await library.cloudAttachmentStorageSnapshot(
      namespaceKey: namespace.namespaceKey
    )
    XCTAssertEqual(attachments.publications.first(where: {
      $0.metadata.attachmentID == attachmentID
    }), before)
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
    let accepted = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertEqual(accepted.readyEntities.first(where: {
      $0.reference == CloudEntityReference(kind: .snip, domainID: snip.id)
    })?.dependencyListID, list.id)
    XCTAssertEqual(accepted.readyEntities.first(where: {
      $0.reference == CloudEntityReference(kind: .list, domainID: list.id)
    })?.identity.recordName, listDraft.id.name)
    let local = await library.snapshot(sortedBy: .manual)
    XCTAssertFalse(local.snips.contains { $0.id == snip.id })
    XCTAssertFalse(local.lists.contains { $0.id == list.id })

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
      namespaceKey: namespace.namespaceKey
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
      namespaceKey: namespace.namespaceKey
    )
    let staged = try await persistence.stagedBatches()
    let wire = try await library.cloudTextSyncSnapshot(namespaceKey: namespace.namespaceKey)
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
    var stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertFalse(stored.readyEntities.contains(where: { $0.reference.domainID == snip.id }))

    let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let review = try await reopenedLibrary.recoverySnapshot(
      in: SnipRecoveryScope(namespace.namespaceKey.rawValue)
    )
    XCTAssertEqual(review.promotedSnips.map(\.id), [recovered.id])
    XCTAssertEqual(review.promotedSnips.first?.currentSnipID, snip.id)

    _ = try await library.perform(.delete(ids: [recovered.id]), sortedBy: .manual)
    try await coordinator.sendPending()
    let pendingAfterDelete = try await persistence.pendingChanges()
    XCTAssertTrue(pendingAfterDelete.operations.isEmpty)
    stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertFalse(stored.readyEntities.contains(where: { $0.reference.domainID == snip.id }))
  }

}


extension CloudFullSyncPersistenceTests {
  func testCurrentCheckpointSeesNewDurableWorkWithoutAnotherFetchOrSend() async throws {
    let fixture = try await CurrentCheckpointFixture.make(namespace: makeNamespace())
    let first = try await fixture.coordinator.checkedCurrentCheckpoint()
    XCTAssertTrue(first.settled)
    let beforeEvents = await fixture.transport.events()
    let added = try await fixture.managed.perform(.add(content: "Committed after original result",
      origin: .quickEntry, source: nil, listID: SnipList.inboxID, attachmentURLs: [],
      requestID: UUID(), now: .distantPast), sortedBy: .manual)
    let snipID = try XCTUnwrap(added.snapshot.snips.first?.id)
    try await fixture.store.approveModeMerge(snipIDs: [snipID])

    let current = try await fixture.coordinator.checkedCurrentCheckpoint()

    XCTAssertFalse(current.settled)
    let afterEvents = await fixture.transport.events()
    XCTAssertEqual(afterEvents, beforeEvents)
    let reopened = try SwiftDataSyncModePersistence(rootURL: fixture.root)
    let durable = try await (try await reopened.activeLibrary()).checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(durable.snips.map(\.content), ["Committed after original result"])
  }

  func testCurrentCheckpointIncludesCleanupFailureWhenAttachmentStatesAreEmpty() async throws {
    let base = makeNamespace()
    let dataZone = try XCTUnwrap(base.zones.first)
    let payloadZone = CloudZoneID(name: "payload", ownerName: dataZone.ownerName)
    let namespace = CloudSyncNamespace(cloudScope: base.cloudScope, accountLineage: base.accountLineage,
      generation: base.generation, zones: [dataZone, payloadZone])
    let fixture = try await CurrentCheckpointFixture.make(namespace: namespace, dataZone: dataZone, payloadZone: payloadZone)
    let attachmentID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let metadataIdentity = CloudTextStorageIdentity(zoneName: fixture.zone.name,
      ownerName: fixture.zone.ownerName, recordName: "a-11111111-1111-1111-1111-111111111111")
    let payloadIdentity = CloudTextStorageIdentity(zoneName: payloadZone.name,
      ownerName: payloadZone.ownerName, recordName: "p-original-cleanup")
    try await fixture.library.commitCloudAttachmentTransitions(namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.remoteMetadataAccepted(metadata: CloudAttachmentMetadataValue(
        attachmentID: attachmentID, snipID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        position: 0, fileName: "old.txt", contentType: "text/plain", byteCount: 4,
        sha256: Data(repeating: 1, count: 32), payloadIdentity: payloadIdentity),
        metadataIdentity: metadataIdentity, shadowData: Data(), systemFields: Data())])
    let published = try await fixture.library.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
    XCTAssertTrue(published.publications.contains {
      $0.metadata.attachmentID == attachmentID && $0.metadataIdentity == metadataIdentity
        && $0.metadata.payloadIdentity == payloadIdentity && $0.metadataAccepted
    })
    try await fixture.library.commitCloudAttachmentTransitions(namespaceKey: fixture.namespace.namespaceKey,
      transitions: [.remoteMetadataDeleted(metadataIdentity: metadataIdentity)])
    let deleted = try await fixture.library.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
    XCTAssertEqual(deleted.cleanups.map(\.identity), [payloadIdentity])
    let pending = try await fixture.store.pendingChanges()
    let cleanupID = CloudAttachmentRecordCodec.recordID(payloadIdentity)
    XCTAssertTrue(pending.operations.contains { $0.id == cleanupID })
    let cleanup = try XCTUnwrap(pending.operations.first { $0.id == cleanupID })
    let engineState = try await fixture.store.loadEngineState()
    let failed = CloudSentBatch(id: UUID(), items: [.failed(cleanup.id, .quotaExceeded)], engineState: engineState)
    try await fixture.store.stage(.sent(failed), outbound: CloudOutboundBatch(operations: [cleanup]))
    try await fixture.store.applyStaged(failed.id)
    let transfer = CloudAttachmentTransferCoordinator(library: fixture.library, namespace: fixture.namespace,
      payloadZone: payloadZone, transport: fixture.transport, maximumCacheBytes: 0)
    let states = try await transfer.transferStates()
    XCTAssertTrue(states.isEmpty)
    let stored = try await fixture.library.cloudAttachmentStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
    XCTAssertEqual(stored.cleanups.first?.lastFailure, .quotaExceeded)
    let events = await fixture.transport.events()

    let current = try await fixture.coordinator.checkedCurrentCheckpoint()

    XCTAssertEqual(current.issue, .iCloudStorageFull)
    XCTAssertFalse(current.settled)
    let after = await fixture.transport.events()
    XCTAssertEqual(after, events)
  }

  func testCurrentCheckpointCannotInventAnOwnerRunOrFinishTheInitialFetch() async throws {
    let fixture = try await CurrentCheckpointFixture.make(namespace: makeNamespace(), finishInitialFetch: false)
    let coordinator = fixture.coordinator
    let transport = fixture.transport
    do {
      _ = try await coordinator.checkedCurrentCheckpoint()
      XCTFail("A checkpoint must not create an earlier completed run.")
    } catch SnipLibraryError.transferUnsupported {}
    _ = try await coordinator.processAutomaticChanges()
    let events = await transport.events()

    let current = try await coordinator.checkedCurrentCheckpoint()

    XCTAssertNil(current.issue)
    XCTAssertFalse(current.settled)
    let after = await transport.events()
    XCTAssertEqual(after, events)
  }
}

private func currentCheckpointRoot() -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("CurrentCheckpoint-\(UUID())")
  print("OFFLINE-CHECKED-APPLICATION retained unique root: \(root.path)")
  return root
}

private struct CurrentCheckpointFixture {
  let root: URL
  let namespace: CloudSyncNamespace
  let zone: CloudZoneID
  let persistence: SwiftDataSyncModePersistence
  let managed: any SnipLibrary
  let library: SwiftDataSnipLibrary
  let store: CloudFullSyncPersistence
  let transport: FakeCloudRecordTransport
  let coordinator: CloudFullSyncCoordinator

  static func make(
    namespace: CloudSyncNamespace, finishInitialFetch: Bool = true,
    dataZone: CloudZoneID? = nil, payloadZone: CloudZoneID? = nil
  ) async throws -> Self {
    let root = currentCheckpointRoot()
    let zone = try XCTUnwrap(dataZone ?? namespace.zones.first)
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.activateEmptyCollection(namespace: namespace.binding)
    let active = try await persistence.snapshot().activeStore
    let managed = try await persistence.activeLibrary()
    let library = try await persistence.libraryForTransition(storeID: active.id)
    let lease = try await persistence.activeCloudMutationLease(storeID: active.id)
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone,
      payloadZone: payloadZone, mutationLease: lease)
    try await store.approveEnrollment(references: [CloudEntityReference(kind: .list, domainID: SnipList.inboxID)])
    let transport = FakeCloudRecordTransport(server: FakeCloudServer(), namespace: namespace)
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    if finishInitialFetch {
      _ = try await coordinator.fetchRemote()
      _ = try await coordinator.sendPendingUntilSettled()
    }
    return Self(root: root, namespace: namespace, zone: zone, persistence: persistence, managed: managed, library: library,
      store: store, transport: transport, coordinator: coordinator)
  }
}


extension CloudFullSyncPersistenceTests {
  func testCurrentCheckpointCannotConfirmEqualRowsAfterTheAppliedFilesChanged() async throws {
    let fixture = try await CurrentCheckpointFixture.make(namespace: makeNamespace())
    let sourceFile = fixture.root.appendingPathComponent("original.txt")
    try Data("original bytes".utf8).write(to: sourceFile)
    let added = try await fixture.managed.perform(.add(content: "Same content and file URL", origin: .quickEntry,
      source: nil, listID: SnipList.inboxID, attachmentURLs: [sourceFile], requestID: UUID(), now: .distantPast), sortedBy: .manual)
    let id = try XCTUnwrap(added.snapshot.snips.first?.id)
    try await fixture.store.approveModeMerge(snipIDs: [id])
    _ = try await fixture.coordinator.sendPendingUntilSettled()
    let scope = SnipRecoveryScope(fixture.namespace.namespaceKey.rawValue)
    let session = SavedSnipsSession(library: fixture.managed, recoveryScope: scope)
    let applied = try await session.checkedRead(sortedBy: .manual)
    let recovery = try await session.checkedRecovery()
    let attachment = try XCTUnwrap(applied.snapshot.snips.first?.attachments.first)
    let url = try XCTUnwrap(applied.snapshot.attachmentURLs[attachment.id])
    let originalFiles = try XCTUnwrap(applied.files).get()
    let originalTime = try XCTUnwrap(originalFiles[attachment.id]?.modifiedAt)
    try FileManager.default.setAttributes([.modificationDate: originalTime.addingTimeInterval(120)], ofItemAtPath: url.path)

    let current = try await fixture.coordinator.checkedCurrentCheckpoint()

    XCTAssertTrue(current.settled, "A file metadata change with identical bytes does not invent outbound work")
    let matches = current.matchesApplication(applied.snapshot, after: applied.publication, target: applied.target,
      recovery: recovery, files: applied.files)
    let closing = try XCTUnwrap(current.publication).beginApplication()
    closing.finish()
    XCTAssertFalse(matches, "Equal rows and URLs cannot confirm the older applied file observation")
    XCTAssertEqual(try Data(contentsOf: url), Data("original bytes".utf8))
    let fresh = try await session.checkedRead(sortedBy: .manual)
    let freshRecovery = try await session.checkedRecovery()
    XCTAssertEqual(fresh.snapshot, applied.snapshot)
    let freshFiles = try XCTUnwrap(fresh.files).get()
    XCTAssertNotEqual(freshFiles, originalFiles)
    let confirmed = try await fixture.coordinator.checkedCurrentCheckpoint()
    let freshMatches = confirmed.matchesApplication(fresh.snapshot, after: fresh.publication, target: fresh.target,
      recovery: freshRecovery, files: fresh.files)
    let confirmedClosing = try XCTUnwrap(confirmed.publication).beginApplication()
    confirmedClosing.finish()
    XCTAssertTrue(freshMatches, "The next real application may establish the current file observation")
  }

  func testCurrentCheckpointCannotConfirmEqualRowsAfterRecoveryWasResolved() async throws {
    let fixture = try await CurrentCheckpointFixture.make(namespace: makeNamespace())
    let current = Snip(id: UUID(uuidString: "11111111-AAAA-BBBB-CCCC-111111111111")!, content: "Current durable value", origin: .quickEntry)
    _ = try await fixture.managed.perform(.restore(snips: [current]), sortedBy: .manual)
    try await fixture.store.approveModeMerge(snipIDs: [current.id])
    _ = try await fixture.coordinator.sendPendingUntilSettled()
    let alternate = Snip(id: UUID(uuidString: "22222222-AAAA-BBBB-CCCC-222222222222")!, content: "Recovered alternate", origin: .quickEntry)
    let recovered = RecoveredSnip(id: alternate.id, currentSnipID: current.id, recovered: alternate, conflictingFields: [.text])
    let namespaceKey = fixture.namespace.namespaceKey
    let reference = CloudEntityReference(kind: .snip, domainID: current.id)
    let stored = try await fixture.library.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let accepted = try XCTUnwrap(stored.readyEntities.first { $0.reference == reference })
    let engineState = try await fixture.library.cloudTextSyncSnapshot(namespaceKey: namespaceKey).engineState
    let conflict = CloudConflictInput(key: "original-application-recovery", reference: reference,
      format: .snipMergeV1, payload: Data("retained original conflict".utf8), recovery: .snip(recovered))
    let batch = CloudFullBatchCommit(
      namespaceKey: namespaceKey.rawValue,
      batchID: UUID(),
      expectedEngineState: engineState,
      nextEngineState: engineState,
      recoveryReviews: [CloudRecoveryReviewInput(conflictKey: conflict.key, recovery: .snip(recovered))],
      items: [CloudFullBatchItem(
        accepted: CloudAcceptedEntityInput(
          reference: accepted.reference,
          identity: accepted.identity,
          schemaVersion: accepted.schemaVersion,
          acceptedData: accepted.acceptedData,
          presenceData: accepted.presenceData,
          shadowData: accepted.shadowData,
          systemFields: accepted.systemFields,
          dependencyListID: accepted.dependencyListID
        ),
        expectedLocalRevision: accepted.localRevision,
        expectedSystemFields: accepted.systemFields,
        localMutation: .none,
        conflict: conflict,
        quarantine: nil
      )]
    )
    try await fixture.library.stageCloudFullBatch(batch)
    _ = try await fixture.library.commitCloudFullBatch(batch)
    let scope = SnipRecoveryScope(fixture.namespace.namespaceKey.rawValue)
    let session = SavedSnipsSession(library: fixture.managed, recoveryScope: scope)
    let applied = try await session.checkedRead(sortedBy: .manual)
    let recovery = try await session.checkedRecovery()
    XCTAssertEqual(recovery.pendingSnips.map(\.id), [alternate.id])
    _ = try await fixture.managed.resolveRecovery(alternate.id, in: scope, choice: .keepCurrent)
    let fresh = try await session.checkedRead(sortedBy: .manual)
    let freshRecovery = try await session.checkedRecovery()
    XCTAssertEqual(fresh.snapshot.snips.map(\.content), ["Current durable value"])
    XCTAssertEqual(fresh.snapshot, applied.snapshot)
    XCTAssertTrue(freshRecovery.pendingSnips.isEmpty)

    let observed = try await fixture.coordinator.checkedCurrentCheckpoint()

    XCTAssertTrue(observed.settled)
    let oldMatches = observed.matchesApplication(applied.snapshot, after: applied.publication, target: applied.target,
      recovery: recovery, files: applied.files)
    let freshMatches = observed.matchesApplication(fresh.snapshot, after: fresh.publication, target: fresh.target,
      recovery: freshRecovery, files: fresh.files)
    let closing = try XCTUnwrap(observed.publication).beginApplication()
    closing.finish()
    XCTAssertFalse(oldMatches, "Equal rows cannot confirm an application still showing the resolved recovery")
    XCTAssertTrue(freshMatches)
  }
}
