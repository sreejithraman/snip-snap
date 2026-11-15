import Foundation
import SnipSnapCore
import SwiftData
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

extension CloudFullSyncPersistenceTests {
  func testFetchOutcomesBeforeSeedingCharacterizeTheRemoteCheck() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentRemoteCheck")
    defer { store.remove() }
    let zone = store.zone

    try await store.apply(store.fetch([.failed(nil, .retryable)]))
    try await store.expect(.notEnrolled, pending: false, revision: 1, "an incomplete first fetch")
    try await store.apply(store.fetch(zones: [.fetched(zone)]))
    try await store.expect(.remoteChecked, pending: false, revision: 2, "an empty complete fetch")
    try await store.apply(store.fetch(database: [.zoneDeleted(zone, reason: .deleted)]))
    try await store.expect(.remoteCheckedMissingZone, pending: false, revision: 3, "a deleted owned zone")
    try await store.apply(store.fetch(zones: [.failed(zone, .zoneMissing)]))
    try await store.expect(.remoteCheckedMissingZone, pending: false, revision: 4, "a repeated missing zone")
    try await store.apply(store.fetch())
    try await store.expect(.remoteChecked, pending: false, revision: 5, "an empty fetch after a missing zone")
    try await store.apply(store.fetch([.record(store.inboxRecord())]))
    try await store.expect(.active, pending: false, revision: 6, "fetched records")
    try await store.apply(store.fetch([.failed(nil, .retryable)]))
    try await store.expect(.active, pending: false, revision: 7, "an incomplete fetch while active")
    try await store.approveInbox()
    try await store.expect(.active, pending: false, revision: 8, "approval while active")

    let reopened = try store.reopened()
    try await reopened.expect(.active, pending: false, revision: 8, "reopen while active")
    let pending = try await reopened.persistence.pendingChanges()
    XCTAssertTrue(pending.zonesToSave.isEmpty)
  }

  func testSeedingFetchOutcomesKeepPendingZoneCreationAcrossReopen() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentSeedingFetch")
    defer { store.remove() }
    let zone = store.zone

    try await store.apply(store.fetch(zones: [.failed(zone, .zoneMissing)]))
    try await store.approveInbox()
    try await store.expect(.seeding, pending: true, revision: 2, "approval after a missing zone")
    try await store.apply(store.fetch(database: [.failed(nil, .retryable)]))
    try await store.expect(.seeding, pending: true, revision: 3, "an incomplete fetch while seeding")
    try await store.apply(store.fetch([.record(store.inboxRecord())]))
    try await store.expect(.seeding, pending: true, revision: 4, "fetched records while seeding")

    var reopened = try store.reopened()
    try await reopened.expect(.seeding, pending: true, revision: 4, "reopen while seeding")
    var pending = try await reopened.persistence.pendingChanges()
    XCTAssertEqual(pending.zonesToSave, [zone])

    try await reopened.apply(reopened.fetch(database: [.zoneDeleted(zone, reason: .deleted)]))
    try await reopened.expect(.remoteCheckedMissingZone, pending: true, revision: 5,
      "a deleted owned zone while seeding")
    pending = try await reopened.persistence.pendingChanges()
    XCTAssertEqual(pending.zonesToSave, [zone])
    try await reopened.apply(reopened.fetch())
    try await reopened.expect(.remoteChecked, pending: true, revision: 6, "an empty fetch after the missing zone")

    reopened = try reopened.reopened()
    try await reopened.expect(.remoteChecked, pending: true, revision: 6, "reopen after the remote check")
    pending = try await reopened.persistence.pendingChanges()
    XCTAssertEqual(pending.zonesToSave, [zone])
    try await reopened.approveInbox()
    try await reopened.expect(.seeding, pending: true, revision: 7, "approval after the remote check")
  }

  func testSeedingSendOutcomesCharacterizeActivationAndBlocking() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentSeedingSend")
    defer { store.remove() }
    let zone = store.zone
    let inboxID = CloudRecordID.list(SnipList.inbox.id, in: zone)

    try await store.apply(store.fetch(zones: [.fetched(zone)]))
    try await store.approveInbox()
    try await store.expect(.seeding, pending: false, revision: 2, "approval after an empty remote check")
    var outbound = try await store.persistence.pendingChanges()
    XCTAssertEqual(outbound.operations.map(\.id), [inboxID])
    XCTAssertTrue(outbound.zonesToSave.isEmpty)
    try await store.send(outbound, items: [.failed(inboxID, .retryable)])
    try await store.expect(.seeding, pending: false, revision: 3, "a retryable seed failure")
    outbound = try await store.persistence.pendingChanges()
    try await store.send(outbound, items: [.failed(inboxID, .zoneMissing)])
    try await store.expect(.seeding, pending: true, revision: 4, "a missing zone during the seed send")

    let reopened = try store.reopened()
    try await reopened.expect(.seeding, pending: true, revision: 4, "reopen with zone creation pending")
    outbound = try await reopened.persistence.pendingChanges()
    XCTAssertEqual(outbound.operations.map(\.id), [inboxID])
    XCTAssertEqual(outbound.zonesToSave, [zone])
    try await reopened.send(outbound, items: outbound.operations.map(CloudEnrollmentTestStore.saved))
    try await reopened.expect(.seeding, pending: true, revision: 5, "a saved seed without a zone save")
    outbound = try await reopened.persistence.pendingChanges()
    XCTAssertEqual(outbound, CloudOutboundBatch(operations: [], zonesToSave: [zone]))
    try await reopened.send(outbound, database: [.zoneSaved(zone)])
    try await reopened.expect(.active, pending: false, revision: 6, "the zone save")
    outbound = try await reopened.persistence.pendingChanges()
    XCTAssertEqual(outbound, CloudOutboundBatch(operations: []))
    try await reopened.send(outbound, zones: [.failed(zone, .zoneMissing)])
    try await reopened.expect(.blocked, pending: false, revision: 7, "a missing zone after activation")

    let blocked = try store.reopened()
    try await blocked.expect(.blocked, pending: false, revision: 7, "reopen while blocked")
    let evidence = try await blocked.persistence.enrollmentEvidence()
    let blockedPending = try await blocked.persistence.pendingChanges()
    XCTAssertTrue(evidence.blocksSending)
    XCTAssertEqual(blockedPending, CloudOutboundBatch(operations: []))
  }

  // SM27-F1 H1: only recovery clears a block, so approval must leave a blocked namespace
  // blocked and unable to send.
  func testResetsBlockEnrollmentAndApprovalLeavesItBlocked() async throws {
    let fetchReset = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentFetchReset")
    defer { fetchReset.remove() }
    let zone = fetchReset.zone
    try await fetchReset.apply(fetchReset.fetch(zones: [.failed(zone, .zoneMissing)]))
    try await fetchReset.approveInbox()
    try await fetchReset.apply(fetchReset.fetch(database: [.zoneDeleted(zone, reason: .purged)]))
    try await fetchReset.expect(.blocked, pending: false, revision: 3, "a purge while seeding")
    try await fetchReset.apply(fetchReset.fetch(zones: [.fetched(zone)]))
    try await fetchReset.expect(.blocked, pending: false, revision: 4, "a clean fetch after a purge")
    let reopened = try fetchReset.reopened()
    try await reopened.expect(.blocked, pending: false, revision: 4, "reopen after a purge")
    try await reopened.approveInbox()
    try await reopened.expect(.blocked, pending: false, revision: 5, "approval after a purge")

    let sendReset = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentSendReset")
    defer { sendReset.remove() }
    try await sendReset.approveInbox()
    try await sendReset.expect(.seeding, pending: false, revision: 1, "approval before any fetch")
    try await sendReset.send(CloudOutboundBatch(operations: []),
      database: [.zoneDeleted(zone, reason: .encryptedDataReset)])
    try await sendReset.expect(.blocked, pending: false, revision: 2, "an encrypted data reset during a send")

    let carried = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentBlockedFlag")
    defer { carried.remove() }
    try await carried.apply(carried.fetch(zones: [.failed(zone, .zoneMissing)]))
    try await carried.approveInbox()
    try await carried.apply(carried.fetch(database: [.zoneDeleted(zone, reason: .deleted)]))
    try await carried.send(CloudOutboundBatch(operations: [], zonesToSave: [zone]),
      zones: [.failed(zone, .zoneMissing)])
    try await carried.expect(.blocked, pending: true, revision: 4, "a missing zone during a send outside seeding")
    let carriedReopened = try carried.reopened()
    try await carriedReopened.expect(.blocked, pending: true, revision: 4, "reopen with the blocked flag")
    try await carriedReopened.approveInbox()
    try await carriedReopened.expect(.blocked, pending: true, revision: 5, "approval with the blocked flag")

    for (blocked, label) in [
      (reopened, "approval after a purge"), (carriedReopened, "approval with the blocked flag"),
    ] {
      let evidence = try await blocked.persistence.enrollmentEvidence()
      let pending = try await blocked.persistence.pendingChanges()
      XCTAssertTrue(evidence.blocksSending, label)
      XCTAssertEqual(pending, CloudOutboundBatch(operations: []), label)
    }
  }

  // SM27-F1 R8: while zone creation is pending, only a data-zone record proves the data zone
  // exists, so a fetch with only payload-zone records must keep the zone creation.
  func testPayloadZoneRecordsAfterAMissingDataZoneKeepPendingZoneCreation() async throws {
    let dataZone = CloudZoneID(name: "SnipSnap", ownerName: "owner")
    let payloadZone = CloudZoneID(name: "SnipSnapPayloads", ownerName: "owner")
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [dataZone, payloadZone])
    let store = try CloudEnrollmentTestStore(namespace: namespace, name: "EnrollmentPayloadOnly",
      payloadZone: payloadZone)
    defer { store.remove() }
    try await store.apply(store.fetch(zones: [.failed(dataZone, .zoneMissing)]))
    try await store.approveInbox()
    try await store.apply(store.fetch(database: [.zoneDeleted(dataZone, reason: .deleted)]))
    try await store.expect(.remoteCheckedMissingZone, pending: true, revision: 3, "a missing zone while seeding")

    let payload = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: CloudRecordDraft(
      id: CloudRecordID(zone: payloadZone, name: "unclaimed-payload"),
      recordType: CloudAttachmentRecordCodec.payloadRecordType,
      schemaVersion: CloudAttachmentRecordCodec.schemaVersion,
      routingFields: [:],
      encryptedFields: [:]
    )))
    try await store.apply(store.fetch([.record(payload)]))

    try await store.expect(.remoteChecked, pending: true, revision: 4, "a fetch with only payload-zone records")
    let reopened = try store.reopened()
    try await reopened.expect(.remoteChecked, pending: true, revision: 4, "reopen after the payload-zone fetch")
    try await reopened.approveInbox()
    try await reopened.expect(.seeding, pending: true, revision: 5, "approval after the payload-zone fetch")
    let outbound = try await reopened.persistence.pendingChanges()
    XCTAssertEqual(outbound.zonesToSave, [dataZone])
    try await reopened.send(outbound, items: outbound.operations.map(CloudEnrollmentTestStore.saved),
      database: [.zoneSaved(dataZone)])
    try await reopened.expect(.active, pending: false, revision: 6, "the seed send that saved the data zone")
  }

  // SM27-L1: an active namespace must not keep asking to create its zone.
  func testRecordsFetchedAfterARepeatedMissingZoneActivateWithoutZoneCreation() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentActiveZone")
    defer { store.remove() }
    let zone = store.zone
    try await store.apply(store.fetch(zones: [.failed(zone, .zoneMissing)]))
    try await store.approveInbox()
    try await store.apply(store.fetch(database: [.zoneDeleted(zone, reason: .deleted)]))
    try await store.expect(.remoteCheckedMissingZone, pending: true, revision: 3, "a missing zone while seeding")

    // Another device recreated the zone and its records before this device sent.
    try await store.apply(store.fetch([.record(store.inboxRecord())], zones: [.fetched(zone)]))

    let reopened = try store.reopened()
    for current in [store, reopened] {
      let state = try await current.namespaceState()
      let pending = try await current.persistence.pendingChanges()
      let settled = try await current.persistence.isSyncSettled()
      XCTAssertEqual(state.phase, .active)
      XCTAssertFalse(state.zoneCreationPending)
      XCTAssertEqual(pending, CloudOutboundBatch(operations: []))
      XCTAssertTrue(settled)
    }
  }

  // SM27-L1: a drained send loop must stop once an active namespace has nothing to send.
  func testDrainedSendStopsAfterRecordsReplaceAMissingZone() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentZoneResend")
    defer { store.remove() }
    let zone = store.zone
    try await store.apply(store.fetch(zones: [.failed(zone, .zoneMissing)]))
    try await store.approveInbox()
    try await store.apply(store.fetch(database: [.zoneDeleted(zone, reason: .deleted)]))
    let server = FakeCloudServer()
    _ = try await server.send(CloudOutboundBatch(operations: [
      .save(CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)),
    ]), failures: [:])
    let transport = FakeCloudRecordTransport(server: server, namespace: store.namespace)
    let coordinator = CloudFullSyncCoordinator(store: store.persistence, transport: transport)

    let outcome = try await coordinator.sendPendingUntilSettled()

    let sends = await transport.events().filter { event in
      if case .sent = event { true } else { false }
    }
    let state = try await store.namespaceState()
    XCTAssertEqual(state.phase, .active)
    XCTAssertEqual(sends.count, 0)
    XCTAssertTrue(outcome.settled)
  }

  // SM27-H4: a saved data zone ends pending zone creation outside seeding too.
  func testSavedDataZoneEndsPendingZoneCreationAfterTheRemoteCheck() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentZoneSaveChecked")
    defer { store.remove() }
    let zone = store.zone
    try await store.apply(store.fetch(zones: [.failed(zone, .zoneMissing)]))
    try await store.approveInbox()
    try await store.apply(store.fetch(database: [.zoneDeleted(zone, reason: .deleted)]))
    try await store.apply(store.fetch())
    try await store.expect(.remoteChecked, pending: true, revision: 4, "an empty fetch after a missing zone")
    let outbound = try await store.persistence.pendingChanges()
    XCTAssertEqual(outbound.zonesToSave, [zone])

    try await store.send(outbound, items: outbound.operations.map(CloudEnrollmentTestStore.saved),
      database: [.zoneSaved(zone)])

    let reopened = try store.reopened()
    try await reopened.expect(.remoteChecked, pending: false, revision: 5, "a data zone save after the check")
    let pending = try await reopened.persistence.pendingChanges()
    XCTAssertEqual(pending, CloudOutboundBatch(operations: []))
  }

  // SM27-H4: the zone save ends pending creation even when a seed item must retry.
  func testSavedDataZoneEndsPendingZoneCreationWhenASeedItemRetries() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentZoneSaveRetry")
    defer { store.remove() }
    let zone = store.zone
    let inboxID = CloudRecordID.list(SnipList.inbox.id, in: zone)
    try await store.apply(store.fetch(zones: [.failed(zone, .zoneMissing)]))
    try await store.approveInbox()
    let outbound = try await store.persistence.pendingChanges()
    XCTAssertEqual(outbound.operations.map(\.id), [inboxID])
    XCTAssertEqual(outbound.zonesToSave, [zone])

    try await store.send(outbound, items: [.failed(inboxID, .retryable)], database: [.zoneSaved(zone)])

    try await store.expect(.seeding, pending: false, revision: 3, "a zone save with a retryable seed item")
    let retry = try await store.persistence.pendingChanges()
    XCTAssertEqual(retry.operations.map(\.id), [inboxID])
    XCTAssertTrue(retry.zonesToSave.isEmpty)
    try await store.send(retry, items: retry.operations.map(CloudEnrollmentTestStore.saved))
    try await store.expect(.active, pending: false, revision: 4, "the retried seed")
  }

  // SM27-H4: a drained send must stop resending a zone that CloudKit already saved.
  func testDrainedSendStopsResendingASavedZoneOutsideSeeding() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentZoneSaveLoop")
    defer { store.remove() }
    let zone = store.zone
    try await store.apply(store.fetch(zones: [.failed(zone, .zoneMissing)]))
    try await store.approveInbox()
    try await store.apply(store.fetch(database: [.zoneDeleted(zone, reason: .deleted)]))
    // A committed incremental checkpoint lets the coordinator send without a first fetch.
    try await store.persistence.saveEngineState(CloudEngineStateEnvelope(
      namespace: store.namespace,
      serialization: JSONEncoder().encode([CloudZoneID: Int]()),
      requiresInitialFetch: false
    ))
    let transport = FakeCloudRecordTransport(server: FakeCloudServer(), namespace: store.namespace)
    let coordinator = CloudFullSyncCoordinator(store: store.persistence, transport: transport)

    _ = try await coordinator.sendPendingUntilSettled()

    let sends = await transport.events().filter { event in
      if case .sent = event { true } else { false }
    }
    XCTAssertEqual(sends.count, 1)
    try await store.expect(.remoteCheckedMissingZone, pending: false, revision: 4,
      "one send that saved the data zone")
  }

  // SM27-L1: rows written by older builds in this state recover when read.
  func testStoredActiveNamespaceWithPendingZoneCreationHealsOnRead() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentStoredActiveZone")
    defer { store.remove() }
    let namespaceKey = store.namespace.namespaceKey.rawValue
    let listID = SnipList.inbox.id.uuidString
    let olderRow = #"{"storageVersion":1,"namespaceState":{"storageVersion":1,"revision":4,"#
      + #""phase":"active","zoneCreationPending":true},"#
      + #""references":[{"kind":"list","domainID":"\#(listID)"}]}"#
    try await store.library.insertFullEnrollmentRow(namespaceKey: namespaceKey, data: Data(olderRow.utf8))

    let state = try await store.namespaceState()
    let pending = try await store.persistence.pendingChanges()
    XCTAssertEqual(state.phase, .active)
    XCTAssertEqual(state.revision, 4)
    XCTAssertFalse(state.zoneCreationPending)
    XCTAssertTrue(pending.zonesToSave.isEmpty)

    try await store.approveInbox()
    let rewrittenRow = try await store.library.fullEnrollmentRowData(namespaceKey: namespaceKey)
    let rewritten = try XCTUnwrap(rewrittenRow)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
    let namespaceState = try XCTUnwrap(root["namespaceState"] as? [String: Any])
    XCTAssertEqual(namespaceState["revision"] as? Int, 5)
    XCTAssertEqual(namespaceState["phase"] as? String, "active")
    XCTAssertEqual(namespaceState["zoneCreationPending"] as? Bool, false)
  }

  // SM27-Q1: no event leaves a namespace that has never fetched waiting to create its zone.
  func testStoredNotEnrolledNamespaceWithPendingZoneCreationHealsOnRead() async throws {
    let store = try CloudEnrollmentTestStore(namespace: makeNamespace(), name: "EnrollmentStoredUnenrolledZone")
    defer { store.remove() }
    let olderRow = #"{"storageVersion":1,"namespaceState":{"storageVersion":1,"revision":2,"#
      + #""phase":"notEnrolled","zoneCreationPending":true},"references":[]}"#
    try await store.library.insertFullEnrollmentRow(namespaceKey: store.namespace.namespaceKey.rawValue,
      data: Data(olderRow.utf8))

    try await store.expect(.notEnrolled, pending: false, revision: 2, "a stored unenrolled row")
    let pending = try await store.persistence.pendingChanges()
    XCTAssertEqual(pending, CloudOutboundBatch(operations: []))
    try await store.apply(store.fetch(zones: [.fetched(store.zone)]))
    try await store.expect(.remoteChecked, pending: false, revision: 3, "the first complete fetch")
  }
}

/// One managed store with its full-record persistence, reopened on demand. The namespace holds
/// the data zone and, when given, the payload zone.
struct CloudEnrollmentTestStore: Sendable {
  let root: URL
  let namespace: CloudSyncNamespace
  let zone: CloudZoneID
  let payloadZone: CloudZoneID?
  let library: SwiftDataSnipLibrary
  let persistence: CloudFullSyncPersistence

  init(namespace: CloudSyncNamespace, name: String, payloadZone: CloudZoneID? = nil) throws {
    try self.init(
      namespace: namespace,
      payloadZone: payloadZone,
      root: FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    )
  }

  private init(namespace: CloudSyncNamespace, payloadZone: CloudZoneID?, root: URL) throws {
    self.root = root
    self.namespace = namespace
    self.payloadZone = payloadZone
    zone = try XCTUnwrap(namespace.zones.first { $0 != payloadZone })
    library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    persistence = CloudFullSyncPersistence(
      library: library, namespace: namespace, dataZone: zone, payloadZone: payloadZone
    )
  }

  func reopened() throws -> CloudEnrollmentTestStore {
    try CloudEnrollmentTestStore(namespace: namespace, payloadZone: payloadZone, root: root)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  func fetch(
    _ items: [CloudFetchItemResult] = [],
    database: [CloudDatabaseEvent] = [],
    zones: [CloudZoneEvent] = [],
    initial: Bool = false
  ) -> CloudSyncBatch {
    .fetched(CloudFetchedBatch(id: UUID(), items: items, databaseEvents: database,
      zoneEvents: zones, engineState: nil, isInitialFetch: initial))
  }

  func apply(_ batch: CloudSyncBatch, outbound: CloudOutboundBatch? = nil) async throws {
    try await persistence.stage(batch, outbound: outbound)
    try await persistence.applyStaged(batch.id)
  }

  func send(
    _ outbound: CloudOutboundBatch,
    items: [CloudSendItemResult] = [],
    database: [CloudDatabaseEvent] = [],
    zones: [CloudZoneEvent] = []
  ) async throws {
    let sent = CloudSentBatch(id: UUID(), items: items, databaseEvents: database,
      zoneEvents: zones, engineState: nil)
    try await apply(.sent(sent), outbound: outbound)
  }

  func approveInbox() async throws {
    try await persistence.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
    ])
  }

  func inboxRecord() throws -> CloudRecordSnapshot {
    try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(
      for: CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)
    ))
  }

  func engineState(requiresInitialFetch: Bool) -> CloudEngineStateEnvelope {
    CloudEngineStateEnvelope(namespace: namespace, serialization: Data("checkpoint".utf8),
      requiresInitialFetch: requiresInitialFetch)
  }

  func namespaceState() async throws -> CloudFullNamespaceState {
    try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey).namespaceState
  }

  func expect(
    _ phase: CloudNamespaceBootstrapPhase,
    pending: Bool,
    revision: UInt64,
    _ label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let current = try await namespaceState()
    XCTAssertEqual(current.phase, phase, label, file: file, line: line)
    XCTAssertEqual(current.zoneCreationPending, pending, label, file: file, line: line)
    XCTAssertEqual(current.revision, revision, label, file: file, line: line)
  }

  func expectInventory(
    _ observed: Set<CloudTextStorageIdentity>,
    canProveAbsence: Bool,
    revision: UInt64,
    _ label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let current = try await namespaceState()
    XCTAssertEqual(current.initialFetchInventory?.observed, observed, label, file: file, line: line)
    XCTAssertEqual(current.initialFetchInventory?.canProveAbsence, canProveAbsence, label,
      file: file, line: line)
    XCTAssertEqual(current.revision, revision, label, file: file, line: line)
  }

  func expectNoInventory(
    revision: UInt64,
    _ label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let current = try await namespaceState()
    XCTAssertNil(current.initialFetchInventory, label, file: file, line: line)
    XCTAssertEqual(current.revision, revision, label, file: file, line: line)
  }

  static func saved(_ operation: CloudOutboundOperation) throws -> CloudSendItemResult {
    guard case .save(let draft) = operation else { throw CloudTransportError.invalidRecord }
    return .saved(try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft)))
  }
}

extension SwiftDataSnipLibrary {
  func insertFullEnrollmentRow(namespaceKey: String, data: Data) throws {
    let context = Self.makeContext(container: try XCTUnwrap(container))
    context.insert(StoredCloudFullEnrollment(namespaceKey: namespaceKey, referencesData: data))
    try context.save()
  }

  func fullEnrollmentRowData(namespaceKey: String) throws -> Data? {
    let context = Self.makeContext(container: try XCTUnwrap(container))
    return try context.fetch(FetchDescriptor<StoredCloudFullEnrollment>())
      .first { $0.namespaceKey == namespaceKey }?.referencesData
  }
}
