import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

extension CloudFullSyncPersistenceTests {
  func testDormantTransferPayloadCapturesReadyDeferredAndPriorRecoveryOnly() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullDormantTransferTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let missingListID = UUID()
    let deferred = Snip(
      content: "deferred base",
      origin: .quickEntry,
      listID: missingListID
    )
    let inbox = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)
      )
    )
    let deferredRecord = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(deferred, in: zone))
    )
    let fetch = CloudFetchedBatch(
      id: UUID(),
      items: [.record(inbox), .record(deferredRecord)],
      engineState: CloudEngineStateEnvelope(namespace: namespace, serialization: Data([7]))
    )
    try await persistence.stage(.fetched(fetch))
    try await persistence.applyStaged(fetch.id)
    let prior = CloudDormantAcceptedBaseBundle.Entry(
      namespaceKey: "other-namespace",
      reference: CloudEntityReference(kind: .list, domainID: UUID()),
      identity: CloudTextStorageIdentity(
        zoneName: zone.name,
        ownerName: zone.ownerName,
        recordName: "l-prior"
      ),
      payload: Data("prior".utf8)
    )
    try await library.storeDormantCloudBase(
      namespaceKey: prior.namespaceKey,
      reference: prior.reference,
      identity: prior.identity,
      payload: prior.payload
    )
    let before = try await library.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    let engineBefore = try await persistence.loadEngineState()

    let payload = try await persistence.dormantAcceptedBaseTransferPayload()
    let bundle = try CloudDormantAcceptedBaseBundle.decode(payload)

    XCTAssertEqual(bundle.entries.count, 3)
    XCTAssertTrue(bundle.entries.contains(prior))
    let current = bundle.entries.filter { $0.namespaceKey == namespace.canonicalKey }
    XCTAssertEqual(Set(current.map { $0.reference }), Set(
      (before.readyEntities + before.deferredEntities).map { $0.reference }
    ))
    for entry in current {
      let accepted = try JSONDecoder().decode(CloudAcceptedEntityInput.self, from: entry.payload)
      XCTAssertEqual(accepted.reference, entry.reference)
      XCTAssertEqual(accepted.identity, entry.identity)
    }
    let after = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.canonicalKey)
    let engineAfter = try await persistence.loadEngineState()
    XCTAssertEqual(after, before)
    XCTAssertEqual(engineAfter, engineBefore)
    let isReady = try await persistence.isReenableReady()
    XCTAssertFalse(isReady)
    let source = SnipLibraryTransferSnapshot(
      revision: 1,
      snips: [],
      lists: [.inbox],
      attachmentData: [:]
    ).replacingOpaqueSyncStatePayload(payload)
    do {
      _ = try await persistence.makeReenableApplyPlan(
        source: source,
        transitionID: UUID(),
        targetRevision: 0
      )
      XCTFail("Expected deferred dependencies to block re-enable")
    } catch {
      XCTAssertEqual(error as? CloudFullReenableError, .deferredDependencies)
    }
  }

  func testReenablePlanMergesIndependentFieldsWithoutMutatingFreshAcceptedRows() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullReenableMergeTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let list = SnipList(
      id: UUID(),
      name: "Base",
      systemImage: "folder",
      position: 1
    )
    let base = Snip(
      id: UUID(),
      requestID: UUID(),
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      content: "base",
      origin: .quickEntry,
      listID: list.id,
      isDone: false
    )
    let inbox = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(.inbox, updatedAt: .distantPast, in: zone)
      )
    )
    let baseSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(base, in: zone))
    )
    let baseListSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(list, updatedAt: Date(timeIntervalSince1970: 1), in: zone)
      )
    )
    let first = CloudFetchedBatch(
      id: UUID(),
      items: [.record(inbox), .record(baseListSnapshot), .record(baseSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(first))
    try await persistence.applyStaged(first.id)
    let dormantPayload = try await persistence.dormantAcceptedBaseTransferPayload()
    let acceptedBase = try CloudFullRecordCodec.snip(from: baseSnapshot)
    let server = Snip(
      id: base.id,
      requestID: base.requestID,
      createdAt: base.createdAt,
      updatedAt: Date(timeIntervalSince1970: 2),
      content: base.content,
      origin: base.origin,
      source: base.source,
      listID: base.listID,
      isDone: true,
      manualSortKey: base.manualSortKey
    )
    let serverSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.snipDraft(server, accepted: acceptedBase)
      )
    )
    let acceptedList = try CloudFullRecordCodec.list(from: baseListSnapshot)
    let serverList = SnipList(
      id: list.id,
      name: "Server",
      systemImage: "cloud",
      position: list.position,
      sortKey: list.sortKey
    )
    let serverListSnapshot = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(
        for: CloudFullRecordCodec.listDraft(
          serverList,
          updatedAt: Date(timeIntervalSince1970: 2),
          accepted: acceptedList
        )
      )
    )
    let second = CloudFetchedBatch(
      id: UUID(),
      items: [.record(serverListSnapshot), .record(serverSnapshot)],
      engineState: nil
    )
    try await persistence.stage(.fetched(second))
    try await persistence.applyStaged(second.id)
    let freshBefore = try await library.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    let local = Snip(
      id: base.id,
      requestID: base.requestID,
      createdAt: base.createdAt,
      updatedAt: Date(timeIntervalSince1970: 3),
      content: "local text",
      origin: base.origin,
      source: base.source,
      listID: base.listID,
      isDone: base.isDone,
      manualSortKey: base.manualSortKey
    )
    let source = SnipLibraryTransferSnapshot(
      revision: 4,
      snips: [local],
      lists: [
        .inbox,
        SnipList(
          id: list.id,
          name: "Recovered",
          systemImage: "star",
          position: list.position,
          sortKey: list.sortKey
        ),
      ],
      attachmentData: [:]
    ).replacingOpaqueSyncStatePayload(dormantPayload)
    let transitionID = UUID()
    let planned = try await persistence.makeReenableApplyPlan(
      source: source,
      transitionID: transitionID,
      targetRevision: 7
    )
    let plan = try XCTUnwrap(planned)

    _ = try await library.applyCloudFullReenablePlan(plan, currentRevision: 7)

    let merged = await library.snapshot(sortedBy: .manual)
    let value = try XCTUnwrap(merged.snips.first(where: { $0.id == base.id }))
    XCTAssertEqual(value.content, "local text")
    XCTAssertTrue(value.isDone)
    XCTAssertEqual(value.listID, list.id)
    XCTAssertEqual(plan.conflicts.count, 1)
    XCTAssertTrue(plan.recoveryInputs.isEmpty)
    let recovery = try await library.recoverySnapshot(
      in: SnipRecoveryScope(namespace.canonicalKey)
    )
    let recoveredList = try XCTUnwrap(recovery.pendingLists.first)
    XCTAssertEqual(recoveredList.currentListID, list.id)
    XCTAssertEqual(recoveredList.recovered.desiredName, "Recovered")
    XCTAssertEqual(recoveredList.recovered.systemImage, "star")
    XCTAssertEqual(recoveredList.conflictingFields, [.name, .icon])
    let currentList = try XCTUnwrap(merged.lists.first(where: { $0.id == list.id }))
    XCTAssertEqual(currentList.desiredName, "Server")
    XCTAssertEqual(currentList.systemImage, "cloud")
    let freshAfter = try await library.cloudFullStorageSnapshot(
      namespaceKey: namespace.canonicalKey
    )
    XCTAssertEqual(freshAfter.readyEntities, freshBefore.readyEntities)
    XCTAssertEqual(freshAfter.deferredEntities, freshBefore.deferredEntities)

    try await persistence.approveModeMerge(snipIDs: [base.id])
    let outbound = try await persistence.pendingChanges()
    let save = try XCTUnwrap(outbound.operations.compactMap { operation -> CloudRecordDraft? in
      guard case .save(let draft) = operation,
        draft.id.name == baseSnapshot.id.name
      else { return nil }
      return draft
    }.first)
    let freshSnip = try XCTUnwrap(freshAfter.readyEntities.first {
      $0.reference == CloudEntityReference(kind: .snip, domainID: base.id)
    })
    XCTAssertEqual(save.base, try CloudRecordShadow(data: freshSnip.shadowData))
  }

  func testReenableIgnoresMismatchedNamespaceAndZoneButKeepsPayload() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudFullReenableMismatchTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = makeNamespace()
    let zone = try XCTUnwrap(namespace.zones.first)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let persistence = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: zone
    )
    let reference = CloudEntityReference(kind: .snip, domainID: UUID())
    let wrongZoneIdentity = CloudTextStorageIdentity(
      zoneName: "other-zone",
      ownerName: zone.ownerName,
      recordName: "s-\(reference.domainID.uuidString.lowercased())"
    )
    let accepted = CloudAcceptedEntityInput(
      reference: reference,
      identity: wrongZoneIdentity,
      schemaVersion: 2,
      acceptedData: Data("accepted".utf8),
      presenceData: Data("presence".utf8),
      shadowData: Data("shadow".utf8),
      systemFields: Data("system".utf8),
      dependencyListID: SnipList.inbox.id
    )
    let encodedAccepted = try JSONEncoder().encode(accepted)
    let cases = [
      CloudDormantAcceptedBaseBundle.Entry(
        namespaceKey: "another-namespace",
        reference: reference,
        identity: wrongZoneIdentity,
        payload: encodedAccepted
      ),
      CloudDormantAcceptedBaseBundle.Entry(
        namespaceKey: namespace.canonicalKey,
        reference: reference,
        identity: wrongZoneIdentity,
        payload: encodedAccepted
      ),
    ]
    for entry in cases {
      let payload = try CloudDormantAcceptedBaseBundle(entries: [entry]).encoded()
      let source = SnipLibraryTransferSnapshot(
        revision: 1,
        snips: [],
        lists: [.inbox],
        attachmentData: [:]
      ).replacingOpaqueSyncStatePayload(payload)
      let plan = try await persistence.makeReenableApplyPlan(
        source: source,
        transitionID: UUID(),
        targetRevision: 0
      )
      XCTAssertNil(plan)
      XCTAssertEqual(try CloudDormantAcceptedBaseBundle.decode(payload).entries, [entry])
    }
  }

}
