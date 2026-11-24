import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import SwiftData
import XCTest

@testable import SnipSnapCloud

/// Device D deletes a synced snip or list while device E edits it (ADR 0014, ADR 0017).
/// Whichever order the two changes reach iCloud, both devices converge, the edit survives,
/// and sync settles without a stored conflict.
final class CloudDeleteEditConflictTests: XCTestCase {
  private let namespace = CloudSyncNamespace(
    cloudScope: "private", accountLineage: "account",
    generation: UUID(uuidString: "abababab-abab-abab-abab-abababababab")!,
    zones: [CloudZoneID(name: "SnipSnap", ownerName: "owner")]
  )
  private var zone: CloudZoneID { namespace.zones.first! }

  private struct Device {
    let url: URL
    let library: SwiftDataSnipLibrary
    let store: CloudFullSyncPersistence
    let coordinator: CloudFullSyncCoordinator
  }

  private func makeDevice(_ url: URL, server: FakeCloudServer) throws -> Device {
    let library = try SwiftDataSnipLibrary(storeURL: url)
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let coordinator = CloudFullSyncCoordinator(
      store: store, transport: FakeCloudRecordTransport(server: server, namespace: namespace)
    )
    return Device(url: url, library: library, store: store, coordinator: coordinator)
  }

  private func relaunch(_ device: Device, server: FakeCloudServer) throws -> Device {
    try makeDevice(device.url, server: server)
  }

  private func temporaryRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudDeleteEdit-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func seed(_ server: FakeCloudServer, lists: [SnipList] = [], snips: [Snip] = []) async throws {
    let writer = FakeCloudRecordTransport(server: server, namespace: namespace)
    try await writer.start(state: nil)
    let sent = try await writer.send(CloudOutboundBatch(operations:
      try ([SnipList.inbox] + lists).map {
        .save(try CloudFullRecordCodec.listDraft($0, updatedAt: .distantPast, in: zone))
      } + snips.map { .save(try CloudFullRecordCodec.snipDraft($0, in: zone)) }
    ))
    try await writer.confirmApplied(sent.id)
  }

  /// Syncs the way Try Again does and checks that nothing is left to send or report.
  private func assertSettled(
    _ device: Device, _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    try await device.coordinator.prepareManualRetry()
    try await device.coordinator.fetchRemote()
    let outcome = try await device.coordinator.sendPendingUntilSettled()
    XCTAssertNil(outcome.issue, message, file: file, line: line)
    XCTAssertTrue(outcome.settled, message, file: file, line: line)
    let issue = try await device.store.unresolvedSyncIssue()
    XCTAssertNil(issue, message, file: file, line: line)
    let stored = try await device.library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertEqual(stored.conflicts.map(\.reference), [], message, file: file, line: line)
    XCTAssertEqual(stored.pendingDeletes.map(\.reference), [], message, file: file, line: line)
  }

  private func snips(_ device: Device) async -> [Snip] {
    await device.library.snapshot(sortedBy: .manual).snips
  }

  private func firstSnip(
    _ device: Device, file: StaticString = #filePath, line: UInt = #line
  ) async throws -> Snip {
    let value = await snips(device).first
    return try XCTUnwrap(value, file: file, line: line)
  }

  private func serverSnipTexts(_ server: FakeCloudServer) async -> [String] {
    await server.storedTextValues().sorted()
  }

  // MARK: Snips

  func testEditThatReachedICloudFirstWinsOverAnOfflineSnipDelete() async throws {
    let root = temporaryRoot()
    let server = FakeCloudServer()
    let base = Snip(content: "base", origin: .quickEntry)
    try await seed(server, snips: [base])
    let d = try makeDevice(root.appendingPathComponent("d.store"), server: server)
    let e = try makeDevice(root.appendingPathComponent("e.store"), server: server)
    try await d.coordinator.fetchRemote()
    try await e.coordinator.fetchRemote()

    _ = try await d.library.perform(.delete(ids: [base.id]), sortedBy: .manual)
    let received = try await firstSnip(e)
    _ = try await e.library.perform(
      .update(id: base.id, content: "edited on E", attachmentURLs: nil,
        expectedUpdatedAt: received.updatedAt, now: Date()),
      sortedBy: .manual
    )
    try await e.coordinator.sendPendingUntilSettled()

    try await d.coordinator.fetchRemote()
    let restored = await snips(d)
    XCTAssertEqual(restored.map(\.id), [base.id], "the edited snip returns under its own identity")
    XCTAssertEqual(restored.map(\.content), ["edited on E"])
    let stored = try await d.library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertEqual(stored.conflicts.map(\.reference), [], "the fetch leaves no conflict to resolve")
    let pending = try await d.store.pendingChanges()
    XCTAssertEqual(pending.operations.map(\.id), [], "the unsent delete is dropped")

    try await assertSettled(d, "deleter")
    try await assertSettled(e, "editor")
    let serverTexts = await serverSnipTexts(server)
    XCTAssertEqual(serverTexts, ["edited on E"])
    let editor = await snips(e)
    XCTAssertEqual(editor.map(\.content), ["edited on E"])

    let relaunched = try relaunch(d, server: server)
    let afterRelaunch = await snips(relaunched)
    XCTAssertEqual(afterRelaunch.map(\.content), ["edited on E"])
    try await assertSettled(relaunched, "deleter after relaunch")
  }

  func testOfflineEditOfASnipDeletedFirstBecomesARecoveredSnipForFetchFirstAndSendFirst() async throws {
    for editorFetchesFirst in [true, false] {
      let root = temporaryRoot()
      let server = FakeCloudServer()
      let base = Snip(content: "base", origin: .quickEntry)
      try await seed(server, snips: [base])
      let d = try makeDevice(root.appendingPathComponent("d.store"), server: server)
      let e = try makeDevice(root.appendingPathComponent("e.store"), server: server)
      try await d.coordinator.fetchRemote()
      try await e.coordinator.fetchRemote()

      let received = try await firstSnip(e)
      _ = try await e.library.perform(
        .update(id: base.id, content: "edited offline", attachmentURLs: nil,
          expectedUpdatedAt: received.updatedAt, now: Date()),
        sortedBy: .manual
      )
      _ = try await d.library.perform(.delete(ids: [base.id]), sortedBy: .manual)
      try await d.coordinator.sendPendingUntilSettled()

      if editorFetchesFirst {
        try await e.coordinator.fetchRemote()
      } else {
        try await e.coordinator.sendPendingUntilSettled()
      }
      let recovered = await snips(e)
      XCTAssertEqual(recovered.map(\.content), ["edited offline"], "fetchFirst=\(editorFetchesFirst)")
      XCTAssertFalse(recovered.contains { $0.id == base.id }, "the original stays deleted")

      try await assertSettled(e, "editor fetchFirst=\(editorFetchesFirst)")
      try await assertSettled(d, "deleter fetchFirst=\(editorFetchesFirst)")
      let deleter = await snips(d)
      XCTAssertEqual(deleter.map(\.id), recovered.map(\.id))
      let serverTexts = await serverSnipTexts(server)
      XCTAssertEqual(serverTexts, ["edited offline"])
    }
  }

  // MARK: Lists

  func testRenameThatReachedICloudFirstWinsOverAnOfflineListDelete() async throws {
    let root = temporaryRoot()
    let server = FakeCloudServer()
    let work = SnipList(id: UUID(), name: "Work", systemImage: "briefcase", position: 1)
    let inWork = Snip(content: "in work", origin: .quickEntry, listID: work.id)
    try await seed(server, lists: [work], snips: [inWork])
    let d = try makeDevice(root.appendingPathComponent("d.store"), server: server)
    let e = try makeDevice(root.appendingPathComponent("e.store"), server: server)
    try await d.coordinator.fetchRemote()
    try await e.coordinator.fetchRemote()

    _ = try await d.library.perform(.deleteList(id: work.id), sortedBy: .manual)
    _ = try await e.library.perform(
      .updateList(id: work.id, name: "Work E", systemImage: "briefcase"), sortedBy: .manual)
    try await e.coordinator.sendPendingUntilSettled()

    try await d.coordinator.fetchRemote()
    let restored = await d.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(restored.lists.first { $0.id == work.id }?.name, "Work E")
    let stored = try await d.library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertEqual(stored.conflicts.map(\.reference), [])

    try await assertSettled(d, "deleter")
    try await assertSettled(e, "editor")
    for device in [d, e, try relaunch(d, server: server)] {
      let snapshot = await device.library.snapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.lists.first { $0.id == work.id }?.name, "Work E")
      // D's delete had already moved the snip to Inbox; that move syncs like any other.
      XCTAssertEqual(snapshot.snips.map(\.listID), [SnipList.inbox.id])
    }
  }

  func testOfflineRenameOfAListDeletedFirstLeavesTheListDeleted() async throws {
    for editorFetchesFirst in [true, false] {
      let root = temporaryRoot()
      let server = FakeCloudServer()
      let work = SnipList(id: UUID(), name: "Work", systemImage: "briefcase", position: 1)
      let inWork = Snip(content: "in work", origin: .quickEntry, listID: work.id)
      try await seed(server, lists: [work], snips: [inWork])
      let d = try makeDevice(root.appendingPathComponent("d.store"), server: server)
      let e = try makeDevice(root.appendingPathComponent("e.store"), server: server)
      try await d.coordinator.fetchRemote()
      try await e.coordinator.fetchRemote()

      _ = try await e.library.perform(
        .updateList(id: work.id, name: "Work E", systemImage: "briefcase"), sortedBy: .manual)
      _ = try await d.library.perform(.deleteList(id: work.id), sortedBy: .manual)
      try await d.coordinator.sendPendingUntilSettled()
      if editorFetchesFirst {
        try await e.coordinator.fetchRemote()
      } else {
        try await e.coordinator.sendPendingUntilSettled()
      }

      try await assertSettled(e, "editor fetchFirst=\(editorFetchesFirst)")
      try await assertSettled(d, "deleter fetchFirst=\(editorFetchesFirst)")
      for device in [d, e] {
        let snapshot = await device.library.snapshot(sortedBy: .manual)
        XCTAssertFalse(snapshot.lists.contains { $0.id == work.id }, "fetchFirst=\(editorFetchesFirst)")
        XCTAssertEqual(snapshot.snips.map(\.content), ["in work"], "fetchFirst=\(editorFetchesFirst)")
        XCTAssertEqual(snapshot.snips.map(\.listID), [SnipList.inbox.id], "fetchFirst=\(editorFetchesFirst)")
      }
    }
  }

  // MARK: Deletions already queued for sending

  /// When D's queued deletion and E's edit reach iCloud.
  private enum QueuedDeleteOrder: CaseIterable {
    /// E's edit arrives first and D fetches it before sending.
    case editFetchedFirst
    /// E's edit arrives first and D sends without fetching. The fake server rejects the stale
    /// delete with the newer record; real CloudKit deletes do not check for newer edits.
    case staleDeleteRejected
    /// CloudKit accepts D's deletion before E sends its edit.
    case deleteAcceptedFirst
  }

  /// Scheduling sync offline queues the deletion in the outbound ledger before D learns of
  /// E's edit. A newer server version still wins; a deletion CloudKit already accepted stands.
  private func runQueuedDelete(_ kind: CloudEntityKind, order: QueuedDeleteOrder) async throws {
    let label = "\(kind) \(order)"
    let root = temporaryRoot()
    let server = FakeCloudServer()
    let work = SnipList(id: UUID(), name: "Work", systemImage: "briefcase", position: 1)
    let base = Snip(content: "base", origin: .quickEntry, listID: work.id)
    try await seed(server, lists: [work], snips: [base])
    let d = try makeDevice(root.appendingPathComponent("d.store"), server: server)
    let e = try makeDevice(root.appendingPathComponent("e.store"), server: server)
    try await d.coordinator.fetchRemote()
    try await e.coordinator.fetchRemote()
    let recordID: CloudRecordID = kind == .snip ? .snip(base.id, in: zone) : .list(work.id, in: zone)

    let command: SnipLibraryCommand = kind == .snip ? .delete(ids: [base.id]) : .deleteList(id: work.id)
    _ = try await d.library.perform(command, sortedBy: .manual)
    let queued = try await d.store.pendingChanges()
    XCTAssertTrue(queued.operations.contains { if case .delete(recordID, _) = $0 { true } else { false } }, label)
    let ledger = try await d.library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    XCTAssertEqual(ledger.pendingDeletes.map(\.reference.domainID), [kind == .snip ? base.id : work.id], label)
    switch kind {
    case .snip:
      let received = try await firstSnip(e)
      _ = try await e.library.perform(
        .update(id: base.id, content: "edited on E", attachmentURLs: nil,
          expectedUpdatedAt: received.updatedAt, now: Date()),
        sortedBy: .manual
      )
    case .list:
      _ = try await e.library.perform(
        .updateList(id: work.id, name: "Work E", systemImage: "briefcase"), sortedBy: .manual)
    }

    switch order {
    case .editFetchedFirst:
      try await e.coordinator.sendPendingUntilSettled()
      try await d.coordinator.fetchRemote()
      let restored = try await d.library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
      XCTAssertEqual(restored.pendingDeletes.map(\.reference), [], "\(label): the fetch withdraws the queued delete")
      try await d.coordinator.sendPendingUntilSettled()
    case .staleDeleteRejected:
      try await e.coordinator.sendPendingUntilSettled()
      try await d.coordinator.sendPendingUntilSettled()
    case .deleteAcceptedFirst:
      try await d.coordinator.sendPendingUntilSettled()
      try await e.coordinator.fetchRemote()
      try await e.coordinator.sendPendingUntilSettled()
    }
    try await assertSettled(d, "deleter \(label)")
    try await assertSettled(e, "editor \(label)")

    let serverRecord = await server.fullSnapshot(for: recordID)
    for device in [d, e, try relaunch(d, server: server)] {
      let snapshot = await device.library.snapshot(sortedBy: .manual)
      switch (kind, order) {
      case (.snip, .deleteAcceptedFirst):
        XCTAssertNil(serverRecord, label)
        XCTAssertFalse(snapshot.snips.contains { $0.id == base.id }, label)
        XCTAssertEqual(snapshot.snips.map(\.content), ["edited on E"], "\(label): the edit survives as a recovered snip")
      case (.snip, _):
        XCTAssertNotNil(serverRecord, label)
        XCTAssertEqual(snapshot.snips.map(\.id), [base.id], label)
        XCTAssertEqual(snapshot.snips.map(\.content), ["edited on E"], label)
      case (.list, .deleteAcceptedFirst):
        XCTAssertNil(serverRecord, label)
        XCTAssertFalse(snapshot.lists.contains { $0.id == work.id }, label)
        XCTAssertEqual(snapshot.snips.map(\.listID), [SnipList.inbox.id], label)
      case (.list, _):
        XCTAssertNotNil(serverRecord, label)
        XCTAssertEqual(snapshot.lists.first { $0.id == work.id }?.name, "Work E", label)
      }
    }
  }

  func testQueuedOfflineSnipDeleteYieldsOnlyToAnEditICloudHeldFirst() async throws {
    for order in QueuedDeleteOrder.allCases { try await runQueuedDelete(.snip, order: order) }
  }

  func testQueuedOfflineListDeleteYieldsOnlyToARenameICloudHeldFirst() async throws {
    for order in QueuedDeleteOrder.allCases { try await runQueuedDelete(.list, order: order) }
  }

  /// The half of the queued-delete rule that protects deletions: with an unchanged server
  /// record, the queued delete survives reopening with lost engine state and is sent.
  func testQueuedDeleteSurvivesLostEngineStateWhenTheServerRecordIsUnchanged() async throws {
    let root = temporaryRoot()
    let server = FakeCloudServer()
    let base = Snip(content: "base", origin: .quickEntry)
    try await seed(server, snips: [base])
    let d = try makeDevice(root.appendingPathComponent("d.store"), server: server)
    try await d.coordinator.fetchRemote()
    _ = try await d.library.perform(.delete(ids: [base.id]), sortedBy: .manual)
    _ = try await d.store.pendingChanges()
    let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
    let configuration = ModelConfiguration(
      "SnipSnapLocal", schema: schema, url: d.url, cloudKitDatabase: .none)
    let context = ModelContext(try ModelContainer(
      for: schema, migrationPlan: SnipSnapSchemaMigrationPlan.self, configurations: [configuration]))
    for state in try context.fetch(FetchDescriptor<StoredCloudEngineState>())
    where state.namespaceKey == namespace.namespaceKey.rawValue {
      context.delete(state)
    }
    try context.save()

    let reopened = try relaunch(d, server: server)
    try await assertSettled(reopened, "unchanged server record")
    let local = await snips(reopened)
    XCTAssertEqual(local.map(\.id), [])
    let serverValue = await server.fullSnapshot(for: .snip(base.id, in: zone))
    XCTAssertNil(serverValue)
    let deletions = await server.acceptedDeletionCount()
    XCTAssertEqual(deletions, 1)
  }

  // MARK: Conflict rows stored by earlier 0.6.1 betas

  private enum LaterServerChange { case none, edited, deleted }

  /// Rebuilds the state earlier betas stored after D fetched E's edit of a snip or list that D
  /// had deleted offline: the accepted base already holds E's version, D has no local row,
  /// and a delete-conflict row with no review withholds D's delete.
  private func makeStoredDeleteConflict(
    _ kind: CloudEntityKind, root: URL, server: FakeCloudServer
  ) async throws -> (d: Device, e: Device, reference: CloudEntityReference) {
    let work = SnipList(id: UUID(), name: "Work", systemImage: "briefcase", position: 1)
    let base = Snip(content: "base", origin: .quickEntry)
    try await seed(server, lists: [work], snips: [base])
    let d = try makeDevice(root.appendingPathComponent("d.store"), server: server)
    let e = try makeDevice(root.appendingPathComponent("e.store"), server: server)
    try await d.coordinator.fetchRemote()
    try await e.coordinator.fetchRemote()
    let reference = CloudEntityReference(kind: kind, domainID: kind == .snip ? base.id : work.id)
    switch kind {
    case .snip:
      let received = try await firstSnip(e)
      _ = try await e.library.perform(
        .update(id: base.id, content: "edited on E", attachmentURLs: nil,
          expectedUpdatedAt: received.updatedAt, now: Date()),
        sortedBy: .manual
      )
    case .list:
      _ = try await e.library.perform(
        .updateList(id: work.id, name: "Work E", systemImage: "briefcase"), sortedBy: .manual)
    }
    try await e.coordinator.sendPendingUntilSettled()
    try await d.coordinator.fetchRemote()
    let command: SnipLibraryCommand = kind == .snip
      ? .delete(ids: [base.id]) : .deleteList(id: work.id)
    _ = try await d.library.perform(command, sortedBy: .manual)

    let stored = try await d.library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
    let accepted = try XCTUnwrap(stored.readyEntities.first { $0.reference == reference })
    let payload: Data
    let format: CloudConflictFormat
    switch kind {
    case .snip:
      format = .snipMergeV1
      payload = try JSONEncoder().encode(CloudSnipDeleteConflictPayload(
        server: CloudFullSyncPersistence.snipFields(CloudFullSyncPersistence.snipRecord(accepted))))
    case .list:
      format = .listMergeV1
      payload = try JSONEncoder().encode(CloudListDeleteConflictPayload(
        server: CloudFullSyncPersistence.listFields(CloudFullSyncPersistence.listRecord(accepted))))
    }
    try insertStoredDeleteConflict(
      in: d, reference: reference, recordID: CloudFullSyncPersistence.recordID(accepted.identity),
      format: format, payload: payload)
    return (try relaunch(d, server: server), e, reference)
  }

  /// Writes a delete-conflict row the way earlier 0.6.1 betas stored it.
  private func insertStoredDeleteConflict(
    in device: Device, reference: CloudEntityReference, recordID: CloudRecordID,
    format: CloudConflictFormat, payload: Data
  ) throws {
    let schema = Schema(versionedSchema: SnipSnapSchemaV9.self)
    let configuration = ModelConfiguration(
      "SnipSnapLocal", schema: schema, url: device.url, cloudKitDatabase: .none)
    let context = ModelContext(try ModelContainer(
      for: schema, migrationPlan: SnipSnapSchemaMigrationPlan.self, configurations: [configuration]))
    context.insert(StoredCloudFullConflict(
      namespaceKey: namespace.namespaceKey.rawValue,
      key: CloudConflictKey.make(
        namespaceKey: namespace.namespaceKey, recordID: recordID,
        ancestorSystemFields: Data("earlier base".utf8), serverSystemFields: Data("server".utf8)
      ),
      reference: reference, format: format, payload: payload
    ))
    try context.save()
  }

  /// An older build stored the row, then applied E's deletion of the record, leaving the row with
  /// neither a server copy nor an accepted shadow. The next fetch drops it.
  func testOrphanedDeleteConflictFromAnEarlierBetaIsDroppedOnTheNextFetch() async throws {
    for kind: CloudEntityKind in [.snip, .list] {
      let root = temporaryRoot()
      let server = FakeCloudServer()
      let work = SnipList(id: UUID(), name: "Work", systemImage: "briefcase", position: 1)
      let base = Snip(content: "base", origin: .quickEntry)
      try await seed(server, lists: [work], snips: [base])
      let d = try makeDevice(root.appendingPathComponent("d.store"), server: server)
      let e = try makeDevice(root.appendingPathComponent("e.store"), server: server)
      try await d.coordinator.fetchRemote()
      try await e.coordinator.fetchRemote()
      let stored = try await d.library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
      let reference = CloudEntityReference(kind: kind, domainID: kind == .snip ? base.id : work.id)
      let accepted = try XCTUnwrap(stored.readyEntities.first { $0.reference == reference })
      let payload: Data = kind == .snip
        ? try JSONEncoder().encode(CloudSnipDeleteConflictPayload(
          server: CloudFullSyncPersistence.snipFields(CloudFullSyncPersistence.snipRecord(accepted))))
        : try JSONEncoder().encode(CloudListDeleteConflictPayload(
          server: CloudFullSyncPersistence.listFields(CloudFullSyncPersistence.listRecord(accepted))))
      let command: SnipLibraryCommand = kind == .snip
        ? .delete(ids: [base.id]) : .deleteList(id: work.id)
      _ = try await e.library.perform(command, sortedBy: .manual)
      try await e.coordinator.sendPendingUntilSettled()
      try await d.coordinator.fetchRemote()
      let gone = try await d.library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
      XCTAssertFalse(gone.readyEntities.contains { $0.reference == reference }, "\(kind)")
      try insertStoredDeleteConflict(
        in: d, reference: reference, recordID: CloudFullSyncPersistence.recordID(accepted.identity),
        format: kind == .snip ? .snipMergeV1 : .listMergeV1, payload: payload)
      let relaunched = try relaunch(d, server: server)
      let stuck = try await relaunched.store.unresolvedSyncIssue()
      XCTAssertEqual(stuck, .appDataIssue, "\(kind): the orphaned row is stuck before the fix")

      try await relaunched.coordinator.fetchRemote()
      let after = try await relaunched.library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
      XCTAssertEqual(after.conflicts.map(\.reference), [], "\(kind)")
      try await assertSettled(relaunched, "\(kind) orphan")
      try await assertSettled(e, "\(kind) editor")
      let local = await relaunched.library.snapshot(sortedBy: .manual)
      if kind == .snip {
        XCTAssertFalse(local.snips.contains { $0.id == base.id })
      } else {
        XCTAssertFalse(local.lists.contains { $0.id == work.id })
      }
    }
  }

  func testDeleteConflictStoredByAnEarlierBetaResolvesOnTheNextFetch() async throws {
    for kind: CloudEntityKind in [.snip, .list] {
      for later: LaterServerChange in [.none, .edited, .deleted] {
        let label = "\(kind) later=\(later)"
        let server = FakeCloudServer()
        let (d, e, reference) = try await makeStoredDeleteConflict(kind, root: temporaryRoot(), server: server)
        let stuck = try await d.store.unresolvedSyncIssue()
        XCTAssertEqual(stuck, .appDataIssue, "\(label): the earlier beta's state is stuck")

        switch (later, kind) {
        case (.none, _):
          break
        case (.edited, .snip):
          let current = try await firstSnip(e)
          _ = try await e.library.perform(
            .update(id: current.id, content: "edited again", attachmentURLs: nil,
              expectedUpdatedAt: current.updatedAt, now: Date()),
            sortedBy: .manual
          )
          try await e.coordinator.sendPendingUntilSettled()
        case (.edited, .list):
          _ = try await e.library.perform(
            .updateList(id: reference.domainID, name: "Work again", systemImage: "briefcase"),
            sortedBy: .manual)
          try await e.coordinator.sendPendingUntilSettled()
        case (.deleted, .snip):
          _ = try await e.library.perform(.delete(ids: [reference.domainID]), sortedBy: .manual)
          try await e.coordinator.sendPendingUntilSettled()
        case (.deleted, .list):
          _ = try await e.library.perform(.deleteList(id: reference.domainID), sortedBy: .manual)
          try await e.coordinator.sendPendingUntilSettled()
        }

        try await d.coordinator.fetchRemote()
        let stored = try await d.library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
        XCTAssertEqual(stored.conflicts.map(\.reference), [], "\(label): an ordinary fetch resolves the row")
        try await assertSettled(d, label)
        try await assertSettled(e, label)

        let deleter = await d.library.snapshot(sortedBy: .manual)
        let editor = await e.library.snapshot(sortedBy: .manual)
        switch kind {
        case .snip:
          let expected: [String] = switch later {
          case .none: ["edited on E"]
          case .edited: ["edited again"]
          case .deleted: []
          }
          XCTAssertEqual(deleter.snips.map(\.content), expected, label)
          XCTAssertEqual(editor.snips.map(\.content), expected, label)
          let serverTexts = await serverSnipTexts(server)
          XCTAssertEqual(serverTexts, expected, label)
        case .list:
          let expected: String? = switch later {
          case .none: "Work E"
          case .edited: "Work again"
          case .deleted: nil
          }
          XCTAssertEqual(deleter.lists.first { $0.id == reference.domainID }?.name, expected, label)
          XCTAssertEqual(editor.lists.first { $0.id == reference.domainID }?.name, expected, label)
        }
        let relaunched = try relaunch(d, server: server)
        try await assertSettled(relaunched, "\(label) after relaunch")
      }
    }
  }
}
