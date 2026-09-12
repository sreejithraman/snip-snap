import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

final class CloudAutomaticSyncResetTests: XCTestCase {
  func testStagedResetRejectsContentEditsAndImports() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudStagedReset-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "reset-source", ownerName: "owner")
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [zone])
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("snips.store"))
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let reset = CloudFetchedBatch(id: UUID(), items: [],
      databaseEvents: [.zoneDeleted(zone, reason: .purged)], engineState: nil)
    try await store.stage(.fetched(reset), outbound: nil)

    try await Self.assertResetRejectsEditsAndImports(library)
    try await store.applyStaged(reset.id)
    try await Self.assertResetRejectsEditsAndImports(library)
  }

  func testCommittedResetRejectsEditsUntilFailedDeliveryFinishesOnNextSyncAfterReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudResetDelivery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "reset-source", ownerName: "owner")
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [zone])
    let binding = ICloudSyncNamespaceBinding(scope: namespace.cloudScope,
      accountLineage: namespace.accountLineage, generation: namespace.generation,
      zones: [ICloudSyncZoneBinding(name: zone.name, ownerName: zone.ownerName)])
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.activateEmptyCollection(namespace: binding)
    let original = try await persistence.snapshot().activeStore
    let library = try await persistence.libraryForTransition(storeID: original.id)
    _ = try await library.perform(Self.resetTestEdit("before reset"), sortedBy: .manual)
    let lease = try await persistence.activeCloudMutationLease(storeID: original.id)
    let store = CloudFullSyncPersistence(library: library, namespace: namespace,
      dataZone: zone, mutationLease: lease)
    let transport = AutomaticSyncTransportProbe()
    let pause = AutomaticSyncPause()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport,
      reportResult: { result in
        guard result == .iCloudDataReset else { return }
        await pause.suspend()
        throw AutomaticSyncTestError.unsupported
      })
    try await coordinator.prepareAutomaticSync()
    let reset = CloudFetchedBatch(id: UUID(), items: [],
      databaseEvents: [.zoneDeleted(zone, reason: .encryptedDataReset)], engineState: nil)
    await transport.setPending(.fetched(reset))
    let processing = Task { try await coordinator.processAutomaticChanges() }
    await pause.waitUntilSuspended()

    let managed = try await persistence.activeLibrary()
    try await Self.assertResetRejectsEditsAndImports(managed)
    try await Self.assertResetRejectsEditsAndImports(library)
    let staged = try await store.stagedBatches()
    let confirmed = await transport.confirmedBatchIDs()
    XCTAssertTrue(staged.isEmpty)
    XCTAssertEqual(confirmed, [reset.id])
    await pause.resume()
    do { _ = try await processing.value; XCTFail("Expected failed reset delivery") }
    catch AutomaticSyncTestError.unsupported {}

    let reopened = try SwiftDataSyncModePersistence(rootURL: root)
    let reopenedManaged = try await reopened.activeLibrary()
    try await Self.assertResetRejectsEditsAndImports(reopenedManaged)
    let reopenedLibrary = try await reopened.libraryForTransition(storeID: original.id)
    let reopenedLease = try await reopened.activeCloudMutationLease(storeID: original.id)
    let recoveredStore = CloudFullSyncPersistence(library: reopenedLibrary, namespace: namespace,
      dataZone: zone, mutationLease: reopenedLease)
    let nextTransport = AutomaticSyncTransportProbe()
    let recovered = CloudFullSyncCoordinator(store: recoveredStore, transport: nextTransport,
      reportResult: { result in
        guard result == .iCloudDataReset else { return }
        _ = try await reopened.discardActiveCloudCollection(storeID: original.id, namespace: binding)
      })
    let outcome = try await recovered.prepareAutomaticSync()
    XCTAssertEqual(outcome.result, .iCloudDataReset)
    let active = try await reopened.snapshot().activeStore
    XCTAssertNotEqual(active.id, original.id)
    XCTAssertEqual(active.kind, .localOnly)
    let fresh = try await reopened.activeLibrary()
    _ = try await fresh.perform(Self.resetTestEdit("after reset"), sortedBy: .manual)
    let snapshot = try await fresh.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.snips.map(\.content), ["after reset"])
    let scheduled = await nextTransport.scheduledBatches()
    XCTAssertTrue(scheduled.isEmpty)
  }

  func testUnrelatedZoneResetCannotFreezeContentOrReportAPurge() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudResetScope-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = CloudZoneID(name: "source", ownerName: "owner")
    let namespace = CloudSyncNamespace(cloudScope: "private", accountLineage: "account",
      generation: UUID(), zones: [zone])
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("snips.store"))
    let store = CloudFullSyncPersistence(library: library, namespace: namespace, dataZone: zone)
    let transport = AutomaticSyncTransportProbe()
    let results = AutomaticSyncReports()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport,
      reportResult: { await results.append($0) })
    try await coordinator.prepareAutomaticSync()
    await transport.setPending(.fetched(CloudFetchedBatch(id: UUID(), items: [],
      databaseEvents: [.zoneDeleted(CloudZoneID(name: "unrelated", ownerName: "owner"), reason: .purged)],
      engineState: nil)))
    do { _ = try await coordinator.processAutomaticChanges(); XCTFail("Expected reset scope rejection") }
    catch CloudTransportError.stateNamespaceMismatch {}
    let staged = try await store.stagedBatches()
    let reset = try await store.destructiveResetSignal()
    let reported = await results.values()
    XCTAssertTrue(staged.isEmpty)
    XCTAssertNil(reset)
    XCTAssertFalse(reported.contains(.iCloudDataReset))
    _ = try await library.perform(Self.resetTestEdit("still writable"), sortedBy: .manual)
  }

  func testAutomaticDestructiveResetNeverSchedulesPendingChanges() async throws {
    let zone = CloudZoneID(name: "snips-test", ownerName: "owner")
    let id = CloudRecordID(zone: zone, name: "pending-record")
    let outbound = CloudOutboundBatch(operations: [.delete(id, base: nil)])
    let reset = CloudFetchedBatch(
      id: UUID(),
      items: [],
      databaseEvents: [
        .zoneDeleted(zone, reason: .encryptedDataReset),
        .failed(nil, .networkUnavailable),
      ],
      engineState: nil
    )
    let store = AutomaticSyncStoreProbe(pendingChanges: outbound)
    let transport = AutomaticSyncTransportProbe()
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)

    let outcome = try await transport.deliverAutomatically(
      .fetched(reset),
      to: coordinator,
      beforeApply: {}
    )

    let scheduled = await transport.scheduledBatches()
    XCTAssertTrue(scheduled.isEmpty)
    XCTAssertNil(outcome.issue)
    XCTAssertEqual(outcome.result, .iCloudDataReset)
    XCTAssertTrue(outcome.blocksOutbound)
  }

  private static func resetTestEdit(_ content: String) -> SnipLibraryCommand {
    .add(content: content, origin: .quickEntry, source: nil, listID: SnipList.inbox.id,
      attachmentURLs: [], requestID: UUID(), now: Date())
  }

  private static func assertResetRejectsEditsAndImports(_ library: any SnipLibrary) async throws {
    do {
      _ = try await library.perform(resetTestEdit("must not be acknowledged"), sortedBy: .manual)
      XCTFail("A reset source must reject content edits")
    } catch SnipLibraryError.modeTransitionInProgress {}
    let source = SnipLibraryTransferSnapshot(revision: 0,
      snips: [], lists: [.inbox], attachmentData: [:], legacyManualPositions: [:])
    let preview = try await library.previewImport(source, transitionID: UUID())
    do {
      _ = try await library.applyImport(preview)
      XCTFail("A reset source must reject imports")
    } catch SnipLibraryError.modeTransitionInProgress {}
  }
}
