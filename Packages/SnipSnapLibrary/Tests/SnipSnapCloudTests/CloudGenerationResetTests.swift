import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import SnipSnapTestSupport
import Synchronization
import XCTest

@testable import SnipSnapCloud

/// A device that finds another sync generation missed an iCloud reset. It keeps its library,
/// turns sync off, and joins the current generation only when the user turns sync on again
/// (ADR 0018, ADR 0024).
final class CloudGenerationResetTests: XCTestCase {
  func testOfflineDeviceKeepsItsEditsAfterAnotherDeviceResetsThenMergesOnEnable() async throws {
    let server = FakeCloudServer()
    let first = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let second = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let deviceA = try Device(server: server, descriptors: [first, second])
    let deviceB = try Device(server: server, descriptors: [])
    defer { deviceA.remove(); deviceB.remove() }

    _ = try await deviceA.add("shared")
    let deletedOnA = try await deviceA.add("deleted on A after the reset")
    let editedOnBoth = try await deviceA.add("edited on both")
    _ = try await deviceA.enable()
    _ = try await deviceA.lifecycle.retrySynchronization()
    _ = try await deviceB.enable()
    _ = try await deviceB.lifecycle.retrySynchronization()
    let joined = try await deviceB.contents()
    XCTAssertEqual(Set(joined), ["shared", "deleted on A after the reset", "edited on both"])

    // B goes offline with edits. Meanwhile iCloud loses the control record, A keeps its
    // library, turns sync on again into a new generation, and keeps editing.
    _ = try await deviceB.update(editedOnBoth, to: "B's offline edit")
    _ = try await deviceB.add("B's offline snip")
    await server.removeControl()
    let resetOnA = try await deviceA.lifecycle.synchronize()
    XCTAssertEqual(resetOnA, .iCloudDataReset)
    let reenabledA = try await deviceA.enable()
    XCTAssertEqual(reenabledA, .enabled)
    let controlAfterA = await server.controlDescriptor()
    XCTAssertEqual(controlAfterA, second)
    _ = try await deviceA.delete(deletedOnA)
    _ = try await deviceA.update(editedOnBoth, to: "A's edit after the reset")
    _ = try await deviceA.lifecycle.retrySynchronization()
    let oldMetadataRemains = await server.hasZone(first.metadataZone)
    let oldPayloadRemains = await server.hasZone(first.payloadZone)
    XCTAssertFalse(oldMetadataRemains, "Enable after a reset removes the reset generation's zones")
    XCTAssertFalse(oldPayloadRemains)
    let sentByA = await server.storedTextValues()
    XCTAssertEqual(Set(sentByA), ["shared", "A's edit after the reset"])

    // B returns and meets the new generation: it keeps every snip, including its edits.
    let resetOnB = try await deviceB.lifecycle.synchronize()
    XCTAssertEqual(resetOnB, .iCloudDataReset)
    let keptOnB = try await deviceB.persistence.snapshot()
    XCTAssertTrue(keptOnB.keptAfterCloudReset)
    let keptContents = try await deviceB.contents()
    XCTAssertEqual(Set(keptContents), [
      "shared", "deleted on A after the reset", "B's offline edit", "B's offline snip",
    ])
    let backgroundOnB = try await deviceB.lifecycle.synchronize()
    XCTAssertEqual(backgroundOnB, .noChange)
    let stillSent = await server.storedTextValues()
    XCTAssertEqual(stillSent, sentByA)

    // Turning sync on again merges by record ID with no shared base: the snip A deleted
    // comes back, and B's conflicting edit becomes a separate snip beside A's edit.
    let enabledB = try await deviceB.enable()
    XCTAssertEqual(enabledB, .enabled)
    let activeOnB = try await deviceB.persistence.snapshot().activeStore
    XCTAssertEqual(activeOnB.namespace, deviceB.binding(second))
    _ = try await deviceB.lifecycle.retrySynchronization()
    let merged = try await deviceB.snapshot()
    XCTAssertEqual(merged.snips.map(\.content).sorted(), [
      "A's edit after the reset", "B's offline edit", "B's offline snip",
      "deleted on A after the reset", "shared",
    ])
    XCTAssertEqual(merged.snips.first { $0.id == editedOnBoth }?.content, "A's edit after the reset")
    XCTAssertEqual(merged.snips.first { $0.id == deletedOnA }?.content, "deleted on A after the reset")
    let duplicate = try XCTUnwrap(merged.snips.first { $0.content == "B's offline edit" })
    XCTAssertNotEqual(duplicate.id, editedOnBoth)
    let sentAfterMerge = await server.storedTextValues()
    XCTAssertEqual(sentAfterMerge, merged.snips.map(\.content).sorted())

    _ = try await deviceA.lifecycle.retrySynchronization()
    let onA = try await deviceA.contents()
    XCTAssertEqual(onA.sorted(), merged.snips.map(\.content).sorted())
  }

  func testRecoveryCopyFromAnEarlierAdoptionSurvivesReopenCleanupResetAndEnable() async throws {
    let server = FakeCloudServer()
    let hidden = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let adopted = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let fresh = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let device = try Device(server: server, descriptors: [fresh])
    defer { device.remove() }
    // An earlier build adopted another generation: it kept the prior library as a read-only
    // recovery copy and made an empty store active for the adopted collection.
    let recoveryID: UUID
    do {
      let earlier = try SwiftDataSyncModePersistence(rootURL: device.root)
      try await earlier.seedEmptyActiveStore(namespace: device.binding(hidden))
      recoveryID = try await earlier.snapshot().activeStore.id
      _ = try await earlier.activeLibrary().perform(Device.addCommand("only in the recovery copy"),
        sortedBy: .manual)
      try await earlier.seedEmptyActiveStore(namespace: device.binding(adopted))
      try Data("1".utf8).write(to: earlier.initialImportMarkerURL)
    }
    try LegacySyncModeFixture.makeRecoveryCopy(storeID: recoveryID, inSyncModeRoot: device.root)
    let recoveryFile = try LegacySyncModeFixture.storeDirectory(
      storeID: recoveryID, inSyncModeRoot: device.root
    ).appendingPathComponent("snips.store")
    await server.seedControl(adopted)

    func assertRecoveryCopyKept(_ step: String) async throws {
      let reopened = try SwiftDataSyncModePersistence(rootURL: device.root)
      let store = await reopened.store(id: recoveryID)
      XCTAssertEqual(store?.lifecycle, .recovery, step)
      XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryFile.path), step)
      let copy = try SwiftDataSnipLibrary(storeURL: recoveryFile)
      let snapshot = try await copy.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(snapshot.snips.map(\.content), ["only in the recovery copy"], step)
      do {
        _ = try await copy.perform(Device.addCommand("must stay read-only"), sortedBy: .manual)
        XCTFail("The recovery copy must stay read-only (\(step))")
      } catch SnipLibraryError.readOnlyRecovery {}
    }

    try await device.open()
    try await assertRecoveryCopyKept("reopen")
    try await device.persistence.cleanupRetiredStores(limit: 10)
    try await assertRecoveryCopyKept("cleanup")
    let synced = try await device.lifecycle.synchronize()
    XCTAssertEqual(synced, .syncScheduled)
    try await assertRecoveryCopyKept("sync")

    await server.removeControl()
    let reset = try await device.lifecycle.synchronize()
    XCTAssertEqual(reset, .iCloudDataReset)
    try await assertRecoveryCopyKept("reset")
    let enabled = try await device.enable()
    XCTAssertEqual(enabled, .enabled)
    try await device.persistence.cleanupRetiredStores(limit: 10)
    try await assertRecoveryCopyKept("enable")
    let active = try await device.persistence.snapshot().activeStore
    XCTAssertEqual(active.namespace, device.binding(fresh))
    let library = try await device.contents()
    XCTAssertTrue(library.isEmpty)
  }
}

/// One device's sync-mode root and lifecycle against a shared fake iCloud.
private final class Device: @unchecked Sendable {
  let root: URL
  let server: FakeCloudServer
  private let descriptors: DescriptorQueue
  private let source: JSONSnipLibrary
  private(set) var persistence: SwiftDataSyncModePersistence
  private(set) var lifecycle: SnipSnapICloudSyncLifecycle

  init(server: FakeCloudServer, descriptors: [CloudCollectionDescriptor]) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudGenerationReset-\(UUID().uuidString)", isDirectory: true)
    self.server = server
    self.descriptors = DescriptorQueue(descriptors)
    persistence = try SwiftDataSyncModePersistence(rootURL: root)
    source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
    lifecycle = Self.makeLifecycle(root: root, source: source, persistence: persistence,
      server: server, descriptors: self.descriptors)
  }

  /// Opens the device's state again, as a relaunch does.
  func open() async throws {
    persistence = try SwiftDataSyncModePersistence(rootURL: root)
    lifecycle = Self.makeLifecycle(root: root, source: source, persistence: persistence,
      server: server, descriptors: descriptors)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func binding(_ descriptor: CloudCollectionDescriptor) -> ICloudSyncNamespaceBinding {
    descriptor.namespace(cloudScope: "private", accountLineage: "account-a").binding
  }

  func enable() async throws -> SyncedContentEnableOutcome {
    do {
      return try await lifecycle.enableICloudSync()
    } catch {
      XCTFail("Enable failed: \(error)")
      throw error
    }
  }

  func snapshot() async throws -> SnipLibrarySnapshot {
    try await lifecycle.activeLibrary().library.checkedSnapshot(sortedBy: .manual)
  }

  func contents() async throws -> [String] {
    try await snapshot().snips.map(\.content)
  }

  @discardableResult
  func add(_ content: String) async throws -> UUID {
    let update = try await lifecycle.activeLibrary().library.perform(
      Self.addCommand(content), sortedBy: .manual
    )
    guard case .add(.added(let id)) = update.outcome else { throw CocoaError(.featureUnsupported) }
    return id
  }

  func update(_ id: UUID, to content: String) async throws -> SnipLibrarySnapshot {
    try await lifecycle.activeLibrary().library.perform(.update(id: id, content: content,
      attachmentURLs: nil, expectedUpdatedAt: nil, now: Date()), sortedBy: .manual).snapshot
  }

  func delete(_ id: UUID) async throws -> SnipLibrarySnapshot {
    try await lifecycle.activeLibrary().library.perform(.delete(ids: [id]), sortedBy: .manual).snapshot
  }

  static func addCommand(_ content: String) -> SnipLibraryCommand {
    .add(content: content, origin: .quickEntry, source: nil, listID: SnipList.inbox.id,
      attachmentURLs: [], requestID: UUID(), now: Date())
  }

  private static func makeLifecycle(
    root: URL,
    source: JSONSnipLibrary,
    persistence: SwiftDataSyncModePersistence,
    server: FakeCloudServer,
    descriptors: DescriptorQueue
  ) -> SnipSnapICloudSyncLifecycle {
    SnipSnapICloudSyncLifecycle(
      rootURL: root,
      sourceLibrary: source,
      syncModeStore: SnipSyncModeStore(persistence),
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      controlTransport: FakeCloudControlTransport(server: server),
      makeRecordTransport: { FakeCloudRecordTransport(server: server, namespace: $0.namespace) },
      makeDescriptor: { descriptors.next() }
    )
  }
}

/// The generations a device creates, in order. A device with none left must join instead.
private final class DescriptorQueue: Sendable {
  private let values: Mutex<[CloudCollectionDescriptor]>

  init(_ values: [CloudCollectionDescriptor]) { self.values = Mutex(values) }

  func next() -> CloudCollectionDescriptor {
    values.withLock { values in
      guard !values.isEmpty else {
        XCTFail("This device must join the current generation, not create one")
        return CloudCollectionDescriptor.fresh(ownerName: "owner")
      }
      return values.removeFirst()
    }
  }
}
