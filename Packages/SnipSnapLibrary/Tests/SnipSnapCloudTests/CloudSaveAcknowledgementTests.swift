import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

final class CloudSaveAcknowledgementTests: XCTestCase {
  func testSnipSaveKeepsEditsMadeWhileSendingIncludingRevert() async throws {
    for laterText in ["A", "C"] {
      let fixture = try await Fixture()
      defer { fixture.removeStore() }
      try await fixture.coordinator.sync()
      try await fixture.editSnip("B")
      await fixture.transport.pauseNextSend()
      let sending = Task { try await fixture.coordinator.sendPending() }
      await fixture.transport.waitUntilSendPauses()
      try await fixture.editSnip(laterText)
      await fixture.transport.resumeSend()
      _ = try await sending.value

      let local = await fixture.library.snapshot(sortedBy: .manual)
      XCTAssertEqual(local.snips.first?.content, laterText)
      try await fixture.assertNoConflicts()
      let pending = try await fixture.persistence.pendingChanges()
      let draft = try Self.save(in: pending, id: fixture.snipRecordID)
      let accepted = try await fixture.accepted(fixture.snipID, kind: .snip)
      let acceptedRecord = try CloudFullSyncPersistence.snipRecord(accepted)
      XCTAssertEqual(try CloudFullSyncPersistence.snipFields(acceptedRecord).text, "B")
      XCTAssertEqual(draft.base, acceptedRecord.shadow)
      XCTAssertEqual(try Self.snipFields(draft).text, laterText)

      try await fixture.coordinator.sendPending()
      let serverValue = await fixture.server.fullSnapshot(for: fixture.snipRecordID)
      let final = try XCTUnwrap(serverValue)
      XCTAssertEqual(try CloudFullSyncPersistence.snipFields(CloudFullRecordCodec.snip(from: final)).text, laterText)
      let settled = try await fixture.persistence.pendingChanges()
      XCTAssertTrue(settled.operations.isEmpty)
    }
  }

  func testListSaveKeepsLaterNameIconAndColorIncludingRevert() async throws {
    for laterName in ["A", "C"] {
      let fixture = try await Fixture()
      defer { fixture.removeStore() }
      try await fixture.coordinator.sync()
      try await fixture.editList("B", icon: "star", color: SnipListColorPreset.blue.color)
      await fixture.transport.pauseNextSend()
      let sending = Task { try await fixture.coordinator.sendPending() }
      await fixture.transport.waitUntilSendPauses()
      try await fixture.editList(laterName, icon: "folder", color: nil)
      await fixture.transport.resumeSend()
      _ = try await sending.value

      let local = await fixture.library.snapshot(sortedBy: .manual)
      let list = try XCTUnwrap(local.lists.first { $0.id == fixture.listID })
      XCTAssertEqual(list.name, laterName)
      XCTAssertEqual(list.systemImage, "folder")
      XCTAssertNil(list.color)
      try await fixture.assertNoConflicts()
      let pending = try await fixture.persistence.pendingChanges()
      let draft = try Self.save(in: pending, id: fixture.listRecordID)
      let accepted = try await fixture.accepted(fixture.listID, kind: .list)
      let acceptedRecord = try CloudFullSyncPersistence.listRecord(accepted)
      XCTAssertEqual(try CloudFullSyncPersistence.listFields(acceptedRecord).desiredName, "B")
      XCTAssertEqual(draft.base, acceptedRecord.shadow)
      XCTAssertEqual(try Self.listFields(draft).desiredName, laterName)

      try await fixture.coordinator.sendPending()
      let settled = try await fixture.persistence.pendingChanges()
      XCTAssertTrue(settled.operations.isEmpty)
    }
  }

  func testInitialSavesKeepEditsMadeBeforeAcknowledgement() async throws {
    let fixture = try await Fixture()
    defer { fixture.removeStore() }
    await fixture.transport.pauseNextSend()
    let sending = Task { try await fixture.coordinator.sendPending() }
    await fixture.transport.waitUntilSendPauses()
    try await fixture.editSnip("new Snip")
    try await fixture.editList("new List", icon: "star", color: SnipListColorPreset.violet.color)
    await fixture.transport.resumeSend()
    _ = try await sending.value

    let local = await fixture.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(local.snips.first?.content, "new Snip")
    XCTAssertEqual(local.lists.first { $0.id == fixture.listID }?.name, "new List")
    try await fixture.assertNoConflicts()
    let pending = try await fixture.persistence.pendingChanges()
    XCTAssertEqual(Set(pending.operations.map(\.id)), [fixture.snipRecordID, fixture.listRecordID])
    for operation in pending.operations {
      guard case .save(let draft) = operation else { return XCTFail("Expected a save") }
      let serverValue = await fixture.server.fullSnapshot(for: operation.id)
      let remote = try XCTUnwrap(serverValue)
      XCTAssertEqual(draft.base, remote.shadow)
    }
  }

  func testInitialSavesKeepDeletesAndSendThemWithAcceptedShadows() async throws {
    let fixture = try await Fixture()
    defer { fixture.removeStore() }
    await fixture.transport.pauseNextSend()
    let sending = Task { try await fixture.coordinator.sendPending() }
    await fixture.transport.waitUntilSendPauses()
    try await fixture.deleteLocalRecords()
    await fixture.transport.resumeSend()
    _ = try await sending.value

    try await fixture.assertLocalRecordsMissing()
    try await fixture.assertNoConflicts()
    try await fixture.assertPendingDeletesUseServerShadows()
    try await fixture.coordinator.sendPending()
    try await fixture.assertDeletesSettled()
  }

  func testSaveAcknowledgementsKeepExistingPendingDeletes() async throws {
    let fixture = try await Fixture()
    defer { fixture.removeStore() }
    try await fixture.coordinator.sync()
    try await fixture.editSnip("B")
    try await fixture.editList("B", icon: "star", color: nil)
    await fixture.transport.pauseNextSend()
    let sending = Task { try await fixture.coordinator.sendPending() }
    await fixture.transport.waitUntilSendPauses()
    try await fixture.deleteLocalRecords()
    _ = try await fixture.persistence.pendingChanges()
    let stagedDeletes = try await fixture.library.cloudFullStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
    XCTAssertEqual(stagedDeletes.pendingDeletes.count, 2)
    await fixture.transport.resumeSend()
    _ = try await sending.value

    try await fixture.assertLocalRecordsMissing()
    try await fixture.assertNoConflicts()
    try await fixture.assertPendingDeletesUseServerShadows()
    try await fixture.coordinator.sendPending()
    try await fixture.assertDeletesSettled()
  }

  func testSnipSaveKeepsLaterDonePinAndPlacementChanges() async throws {
    let fixture = try await Fixture()
    defer { fixture.removeStore() }
    try await fixture.coordinator.sync()
    _ = try await fixture.library.perform(.batch([
      .setDone(ids: [fixture.snipID], done: true),
      .place(ids: [fixture.snipID], in: SnipList.inbox.id, before: nil, basedOn: .manual),
    ]), sortedBy: .manual)
    await fixture.transport.pauseNextSend()
    let sending = Task { try await fixture.coordinator.sendPending() }
    await fixture.transport.waitUntilSendPauses()
    _ = try await fixture.library.perform(.batch([
      .setDone(ids: [fixture.snipID], done: false),
      .setPinned(ids: [fixture.snipID], pinned: true),
      .place(ids: [fixture.snipID], in: fixture.listID, before: nil, basedOn: .manual),
    ]), sortedBy: .manual)
    let expected = await fixture.library.snapshot(sortedBy: .manual).snips
    await fixture.transport.resumeSend()
    _ = try await sending.value

    let actual = await fixture.library.snapshot(sortedBy: .manual).snips
    XCTAssertEqual(actual, expected)
    try await fixture.assertNoConflicts()
    let pending = try await fixture.persistence.pendingChanges()
    let fields = try Self.snipFields(Self.save(in: pending, id: fixture.snipRecordID))
    XCTAssertFalse(fields.isDone)
    XCTAssertEqual(fields.placement.listID, fixture.listID)
  }

  func testStagedInitialAcknowledgementsSurviveReopenAndLaterEditsOrDeletes() async throws {
    for deletes in [false, true] {
      let fixture = try await Fixture()
      defer { fixture.removeStore() }
      let outbound = try await fixture.persistence.pendingChanges()
      let sent = try await fixture.server.send(outbound, failures: [:])
      try await fixture.persistence.stage(.sent(sent), outbound: outbound)
      if deletes {
        try await fixture.deleteLocalRecords()
      } else {
        try await fixture.editSnip("after staging")
        try await fixture.editList("after staging", icon: "star", color: nil)
      }
      let reopenedLibrary = try SwiftDataSnipLibrary(storeURL: fixture.storeURL)
      let reopened = CloudFullSyncPersistence(library: reopenedLibrary, namespace: fixture.namespace, dataZone: fixture.zone)
      try await reopened.applyStaged(sent.id)
      try await reopened.applyStaged(sent.id)

      let local = await reopenedLibrary.snapshot(sortedBy: .manual)
      let pending = try await reopened.pendingChanges()
      if deletes {
        XCTAssertTrue(local.snips.isEmpty)
        XCTAssertFalse(local.lists.contains { $0.id == fixture.listID })
        XCTAssertEqual(pending.operations.filter { if case .delete = $0 { true } else { false } }.count, 2)
      } else {
        XCTAssertEqual(local.snips.first?.content, "after staging")
        XCTAssertEqual(local.lists.first { $0.id == fixture.listID }?.name, "after staging")
        XCTAssertEqual(pending.operations.count, 2)
      }
      let stored = try await reopenedLibrary.cloudFullStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
      let staged = try await reopened.stagedBatches()
      XCTAssertTrue(stored.conflicts.isEmpty)
      XCTAssertTrue(staged.isEmpty)
    }
  }

  func testAcknowledgedShadowKeepsUnknownFieldsForTheNextSave() async throws {
    let fixture = try await Fixture()
    defer { fixture.removeStore() }
    let initial = try await fixture.persistence.pendingChanges()
    let withUnknownFields = CloudOutboundBatch(operations: initial.operations.map { operation in
      guard case .save(let draft) = operation else { return operation }
      return .save(CloudRecordDraft(
        id: draft.id,
        recordType: draft.recordType,
        schemaVersion: draft.schemaVersion,
        routingFields: draft.routingFields.merging(["futureRoute": .int64(7)]) { _, new in new },
        encryptedFields: draft.encryptedFields.merging(["futureBody": .string("keep")]) { _, new in new },
        base: draft.base
      ))
    }, zonesToSave: initial.zonesToSave)
    let seed = try await fixture.server.send(withUnknownFields, failures: [:])
    try await fixture.persistence.stage(.sent(seed), outbound: withUnknownFields)
    try await fixture.persistence.applyStaged(seed.id)
    try await fixture.editSnip("B")
    try await fixture.editList("B", icon: "star", color: nil)
    let submitted = try await fixture.persistence.pendingChanges()
    let saved = try await fixture.server.send(submitted, failures: [:])
    try await fixture.editSnip("A")
    try await fixture.editList("A", icon: "folder", color: nil)
    try await fixture.persistence.stage(.sent(saved), outbound: submitted)
    try await fixture.persistence.applyStaged(saved.id)

    let pending = try await fixture.persistence.pendingChanges()
    XCTAssertEqual(pending.operations.count, 2)
    for operation in pending.operations {
      guard case .save(let draft) = operation else { return XCTFail("Expected a save") }
      let snapshot = try CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))
      XCTAssertEqual(snapshot.routingFields["futureRoute"], .int64(7))
      XCTAssertEqual(snapshot.encryptedFields["futureBody"], .string("keep"))
      let remote = await fixture.server.fullSnapshot(for: operation.id)
      XCTAssertEqual(draft.base, remote?.shadow)
    }
    try await fixture.assertNoConflicts()
  }

  func testFetchedChangesAndSendConflictsStillPreserveBothVersions() async throws {
    for useSendConflict in [false, true] {
      let fixture = try await Fixture()
      defer { fixture.removeStore() }
      try await fixture.coordinator.sync()
      try await fixture.editSnip("local")
      try await fixture.editList("local", icon: "folder", color: nil)
      let submitted = try await fixture.persistence.pendingChanges()
      let remoteWrites = CloudOutboundBatch(operations: submitted.operations.map { operation in
        guard case .save(let draft) = operation else { return operation }
        let textField = draft.recordType == "Snip" ? "text" : "desiredName"
        return .save(CloudRecordDraft(
          id: draft.id,
          recordType: draft.recordType,
          schemaVersion: draft.schemaVersion,
          routingFields: draft.routingFields,
          encryptedFields: draft.encryptedFields.merging([textField: .string("remote")]) { _, new in new },
          base: draft.base
        ))
      })
      let remote = try await fixture.server.send(remoteWrites, failures: [:])
      let batch: CloudSyncBatch
      if useSendConflict {
        batch = .sent(try await fixture.server.send(submitted, failures: [:]))
      } else {
        batch = .fetched(CloudFetchedBatch(id: UUID(), items: remote.items.compactMap {
          if case .saved(let snapshot) = $0 { .record(snapshot) } else { nil }
        }, engineState: nil))
      }
      try await fixture.persistence.stage(batch, outbound: useSendConflict ? submitted : nil)
      try await fixture.persistence.applyStaged(batch.id)

      let local = await fixture.library.snapshot(sortedBy: .manual)
      XCTAssertEqual(local.snips.first?.content, "remote")
      XCTAssertEqual(local.lists.first { $0.id == fixture.listID }?.name, "remote")
      let stored = try await fixture.library.cloudFullStorageSnapshot(namespaceKey: fixture.namespace.namespaceKey)
      XCTAssertEqual(stored.conflicts.count, 2)
      let recovery = try await fixture.library.recoverySnapshot(in: SnipRecoveryScope(fixture.namespace.namespaceKey.rawValue))
      XCTAssertEqual(recovery.pendingSnips.first?.recovered.content, "local")
      XCTAssertEqual(recovery.pendingLists.count, 1)
    }
  }

  private static func save(in batch: CloudOutboundBatch, id: CloudRecordID) throws -> CloudRecordDraft {
    let operation = try XCTUnwrap(batch.operations.first { $0.id == id })
    guard case .save(let draft) = operation else { throw CloudTransportError.invalidRecord }
    return draft
  }

  private static func snipFields(_ draft: CloudRecordDraft) throws -> CloudSnipMergeFields {
    try CloudFullSyncPersistence.snipFields(CloudFullRecordCodec.snip(from:
      CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))))
  }

  private static func listFields(_ draft: CloudRecordDraft) throws -> CloudListMergeFields {
    try CloudFullSyncPersistence.listFields(CloudFullRecordCodec.list(from:
      CloudKitRecordMapper.snapshot(CloudKitRecordMapper.record(for: draft))))
  }

  private struct Fixture {
    let root: URL
    let storeURL: URL
    let namespace: CloudSyncNamespace
    let zone: CloudZoneID
    let library: SwiftDataSnipLibrary
    let persistence: CloudFullSyncPersistence
    let server: FakeCloudServer
    let transport: FakeCloudRecordTransport
    let coordinator: CloudFullSyncCoordinator
    let snipID: UUID
    let listID: UUID
    var snipRecordID: CloudRecordID { .snip(snipID, in: zone) }
    var listRecordID: CloudRecordID { .list(listID, in: zone) }

    init() async throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSaveAcknowledgement-\(UUID())")
      storeURL = root.appendingPathComponent("store")
      zone = CloudZoneID(name: "SnipSnap", ownerName: "owner")
      namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account", generation: UUID(), zones: [zone])
      library = try SwiftDataSnipLibrary(storeURL: storeURL)
      let created = try await library.perform(.createList(name: "A", systemImage: "folder"), sortedBy: .manual)
      guard case .listCreated(let list) = created.outcome else { throw CloudTransportError.invalidRecord }
      listID = list.id
      let added = try await library.perform(.add(content: "A", origin: .quickEntry, source: nil,
        listID: listID, attachmentURLs: [], requestID: UUID(), now: Date(timeIntervalSince1970: 1)), sortedBy: .manual)
      guard case .add(.added(let id)) = added.outcome else { throw CloudTransportError.invalidRecord }
      snipID = id
      persistence = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
      try await persistence.approveEnrollment(references: [
        CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
        CloudEntityReference(kind: .list, domainID: listID),
        CloudEntityReference(kind: .snip, domainID: snipID),
      ])
      server = FakeCloudServer()
      transport = FakeCloudRecordTransport(server: server, namespace: namespace)
      coordinator = CloudFullSyncCoordinator(store: persistence, transport: transport)
    }

    func removeStore() { try? FileManager.default.removeItem(at: root) }

    func editSnip(_ text: String) async throws {
      _ = try await library.perform(.update(id: snipID, content: text, attachmentURLs: nil,
        expectedUpdatedAt: nil, now: Date()), sortedBy: .manual)
    }

    func editList(_ name: String, icon: String, color: SnipListColor?) async throws {
      _ = try await library.perform(.updateList(id: listID, name: name, systemImage: icon, color: .set(color)), sortedBy: .manual)
    }

    func deleteLocalRecords() async throws {
      _ = try await library.perform(.batch([.delete(ids: [snipID]), .deleteList(id: listID)]), sortedBy: .manual)
    }

    func accepted(_ id: UUID, kind: CloudEntityKind) async throws -> CloudAcceptedEntity {
      let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
      return try XCTUnwrap((stored.readyEntities + stored.deferredEntities).first {
        $0.reference == CloudEntityReference(kind: kind, domainID: id)
      })
    }

    func assertNoConflicts() async throws {
      let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
      let recovery = try await library.recoverySnapshot(in: SnipRecoveryScope(namespace.namespaceKey.rawValue))
      XCTAssertTrue(stored.conflicts.isEmpty)
      XCTAssertTrue(stored.quarantines.isEmpty)
      XCTAssertEqual(recovery, .empty)
    }

    func assertLocalRecordsMissing() async throws {
      let local = await library.snapshot(sortedBy: .manual)
      XCTAssertFalse(local.snips.contains { $0.id == snipID })
      XCTAssertFalse(local.lists.contains { $0.id == listID })
    }

    func assertPendingDeletesUseServerShadows() async throws {
      let pending = try await persistence.pendingChanges()
      XCTAssertEqual(Set(pending.operations.map(\.id)), [snipRecordID, listRecordID])
      for operation in pending.operations {
        guard case .delete(let id, let base) = operation else { return XCTFail("Expected a delete") }
        let serverValue = await server.fullSnapshot(for: id)
        let remote = try XCTUnwrap(serverValue)
        XCTAssertEqual(base, remote.shadow)
      }
    }

    func assertDeletesSettled() async throws {
      let pending = try await persistence.pendingChanges()
      let stored = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
      let remoteSnip = await server.fullSnapshot(for: snipRecordID)
      let remoteList = await server.fullSnapshot(for: listRecordID)
      XCTAssertTrue(pending.operations.isEmpty)
      XCTAssertTrue(stored.pendingDeletes.isEmpty)
      XCTAssertNil(remoteSnip)
      XCTAssertNil(remoteList)
    }
  }
}
