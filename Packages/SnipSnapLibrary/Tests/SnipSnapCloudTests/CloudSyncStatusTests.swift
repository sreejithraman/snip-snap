import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

/// What sync status reports after merges that keep both sides or move snips (ADR 0014).
final class CloudSyncStatusTests: XCTestCase {
  private let namespace = CloudSyncNamespace(
    cloudScope: "private", accountLineage: "account",
    generation: UUID(uuidString: "abababab-abab-abab-abab-abababababab")!,
    zones: [CloudZoneID(name: "SnipSnap", ownerName: "owner")]
  )
  private var zone: CloudZoneID { namespace.zones.first! }
  private var scope: SnipRecoveryScope { SnipRecoveryScope(namespace.namespaceKey.rawValue) }

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

  private func temporaryRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudSyncStatus-\(UUID().uuidString)")
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

  /// Syncs the way Try Again does and returns the final outcome.
  @discardableResult
  private func retry(_ device: Device) async throws -> CloudFullSyncOutcome {
    try await device.coordinator.prepareManualRetry()
    try await device.coordinator.fetchRemote()
    return try await device.coordinator.sendPendingUntilSettled()
  }

  private func assertSettled(
    _ device: Device, _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let outcome = try await retry(device)
    XCTAssertNil(outcome.issue, message, file: file, line: line)
    XCTAssertTrue(outcome.settled, message, file: file, line: line)
    let issue = try await device.store.unresolvedSyncIssue()
    XCTAssertNil(issue, message, file: file, line: line)
  }

  /// Device A sends "A text"; device B edits the same snip to "B text" while offline.
  private func makeFieldConflict(_ root: URL) async throws -> (server: FakeCloudServer, b: Device) {
    let server = FakeCloudServer()
    try await seed(server, snips: [Snip(content: "base", origin: .quickEntry)])
    let a = try makeDevice(root.appendingPathComponent("a.store"), server: server)
    let b = try makeDevice(root.appendingPathComponent("b.store"), server: server)
    try await a.coordinator.fetchRemote()
    try await b.coordinator.fetchRemote()
    for (device, text) in [(a, "A text"), (b, "B text")] {
      let snapshot = await device.library.snapshot(sortedBy: .manual)
      let base = try XCTUnwrap(snapshot.snips.first)
      _ = try await device.library.perform(
        .update(id: base.id, content: text, attachmentURLs: nil,
          expectedUpdatedAt: base.updatedAt, now: Date()),
        sortedBy: .manual
      )
      if device.url == a.url { try await a.coordinator.sendPendingUntilSettled() }
    }
    try await b.coordinator.fetchRemote()
    return (server, b)
  }

  func testPendingSnipReviewIsNotASyncIssue() async throws {
    let (_, b) = try await makeFieldConflict(temporaryRoot())
    let review = try await b.library.recoverySnapshot(in: scope)
    XCTAssertEqual(review.pendingSnips.map(\.recovered.content), ["B text"])

    try await assertSettled(b, "a review waits in Needs Attention, not as a sync failure")
    let relaunched = try makeDevice(b.url, server: FakeCloudServer())
    let issueAfterRelaunch = try await relaunched.store.unresolvedSyncIssue()
    XCTAssertNil(issueAfterRelaunch)
  }

  func testEveryReviewChoiceLeavesSyncSettled() async throws {
    let choices: [(RecoveredSnip) -> SnipRecoveryChoice] = [
      { _ in .keepCurrent }, { _ in .useRecovered }, { _ in .keepBoth },
      { var snip = $0.recovered; snip.content = "merged"; return .editSnip(snip) },
    ]
    for choose in choices {
      let (_, b) = try await makeFieldConflict(temporaryRoot())
      let pending = try await b.library.recoverySnapshot(in: scope).pendingSnips
      let review = try XCTUnwrap(pending.first)
      _ = try await b.library.resolveRecovery(review.id, in: scope, choice: choose(review))
      let remaining = try await b.library.recoverySnapshot(in: scope).needsAttentionCount
      XCTAssertEqual(remaining, 0)
      try await assertSettled(b, "resolved with \(choose(review))")
    }
  }

  func testPendingListReviewIsNotASyncIssue() async throws {
    let root = temporaryRoot()
    let server = FakeCloudServer()
    let work = SnipList(id: UUID(), name: "Work", systemImage: "briefcase", position: 1)
    try await seed(server, lists: [work])
    let a = try makeDevice(root.appendingPathComponent("a.store"), server: server)
    let b = try makeDevice(root.appendingPathComponent("b.store"), server: server)
    try await a.coordinator.fetchRemote()
    try await b.coordinator.fetchRemote()
    _ = try await a.library.perform(
      .updateList(id: work.id, name: "Work A", systemImage: "briefcase"), sortedBy: .manual)
    try await a.coordinator.sendPendingUntilSettled()
    _ = try await b.library.perform(
      .updateList(id: work.id, name: "Work B", systemImage: "briefcase"), sortedBy: .manual)
    try await b.coordinator.fetchRemote()
    try await b.coordinator.sendPendingUntilSettled()

    let review = try await b.library.recoverySnapshot(in: scope)
    XCTAssertEqual(review.pendingLists.count, 1)
    try await assertSettled(b, "a list review waits in Needs Attention")
  }

  /// Device A deletes a list with snips. `bMovesSnipIn` adds the race where B, offline, moves a
  /// snip into that list first. `fetchFirst` decides whether B fetches before it sends.
  private func runListDeletion(bMovesSnipIn: Bool, fetchFirst: Bool) async throws {
    let root = temporaryRoot()
    let server = FakeCloudServer()
    let doomed = SnipList(id: UUID(), name: "Soon Deleted", systemImage: "trash", position: 1)
    let inDoomed = Snip(content: "in list", origin: .quickEntry, listID: doomed.id)
    let inInbox = Snip(content: "in inbox", origin: .quickEntry)
    try await seed(server, lists: [doomed], snips: [inDoomed, inInbox])
    let a = try makeDevice(root.appendingPathComponent("a.store"), server: server)
    let b = try makeDevice(root.appendingPathComponent("b.store"), server: server)
    try await a.coordinator.fetchRemote()
    try await b.coordinator.fetchRemote()

    if bMovesSnipIn {
      _ = try await b.library.perform(
        .place(ids: [inInbox.id], in: doomed.id, before: nil, basedOn: .manual), sortedBy: .manual)
    }
    _ = try await a.library.perform(.deleteList(id: doomed.id), sortedBy: .manual)
    try await a.coordinator.sendPendingUntilSettled()
    if !fetchFirst { try await b.coordinator.sendPendingUntilSettled() }
    try await b.coordinator.fetchRemote()

    let local = await b.library.snapshot(sortedBy: .manual)
    XCTAssertFalse(local.lists.contains { $0.id == doomed.id })
    XCTAssertEqual(
      Set(local.snips.filter { $0.listID == SnipList.inbox.id }.map(\.id)),
      [inDoomed.id, inInbox.id]
    )
    let attention = try await b.library.recoverySnapshot(in: scope).needsAttentionCount
    XCTAssertEqual(attention, 0)
    try await assertSettled(b, "moving snips to Inbox after a list deletion is not a sync failure")
  }

  func testRemoteListDeletionMovesSnipsToInboxWithoutASyncIssue() async throws {
    try await runListDeletion(bMovesSnipIn: false, fetchFirst: true)
  }

  func testMoveIntoARemotelyDeletedListEndsInInboxWithoutASyncIssue() async throws {
    try await runListDeletion(bMovesSnipIn: true, fetchFirst: true)
    try await runListDeletion(bMovesSnipIn: true, fetchFirst: false)
  }

  func testOneFetchCanDeleteSeveralListsThatHoldSnips() async throws {
    let root = temporaryRoot()
    let server = FakeCloudServer()
    let one = SnipList(id: UUID(), name: "One", systemImage: "cart", position: 1)
    let two = SnipList(id: UUID(), name: "Two", systemImage: "cart", position: 2)
    let first = Snip(content: "one", origin: .quickEntry, listID: one.id)
    let second = Snip(content: "two", origin: .quickEntry, listID: two.id)
    try await seed(server, lists: [one, two], snips: [first, second])
    let a = try makeDevice(root.appendingPathComponent("a.store"), server: server)
    let b = try makeDevice(root.appendingPathComponent("b.store"), server: server)
    try await a.coordinator.fetchRemote()
    try await b.coordinator.fetchRemote()
    _ = try await a.library.perform(.deleteList(id: one.id), sortedBy: .manual)
    _ = try await a.library.perform(.deleteList(id: two.id), sortedBy: .manual)
    try await a.coordinator.sendPendingUntilSettled()

    try await b.coordinator.fetchRemote()

    let local = await b.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(local.lists.map(\.id), [SnipList.inbox.id])
    XCTAssertEqual(Set(local.snips.map(\.listID)), [SnipList.inbox.id])
    let events = try await b.library.cloudFullRecoveryEvents(namespaceKey: namespace.namespaceKey)
      .filter { $0.kind == .deletedListPlacement }
    XCTAssertEqual(events.count, 1)
    let placements = try CloudFullSyncPersistence.deletedListPlacements(in: try XCTUnwrap(events.first))
    XCTAssertEqual(placements, [one.id: [first.id], two.id: [second.id]])
    try await assertSettled(b, "a batch that deletes two lists applies once")
  }

  func testDeletedListPlacementReadsTheSingleListShapeFromEarlierBetas() throws {
    let encoder = JSONEncoder()
    let list = UUID()
    let snips = [UUID(), UUID()]
    let input = CloudFullRecoveryInput(
      namespaceKey: namespace.namespaceKey.rawValue, batchID: UUID(), kind: .deletedListPlacement,
      outboundData: try encoder.encode(list), resultData: try encoder.encode(snips)
    )
    XCTAssertEqual(try CloudFullSyncPersistence.deletedListPlacements(in: input), [list: snips])
  }
}
