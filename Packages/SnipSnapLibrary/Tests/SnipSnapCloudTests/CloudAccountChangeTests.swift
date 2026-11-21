import Foundation
import SnipSnapCore
@testable import SnipSnapCloud
@testable import SnipSnapPersistence
import XCTest

final class CloudAccountChangeTests: XCTestCase {
  func testSignOutKeepsLocalBytesAndTheOriginalAccountCanResume() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let local = try await fixture.persistence.activeLibrary()
    let file = fixture.root.appendingPathComponent("note.txt")
    let bytes = Data("on-device attachment".utf8)
    try bytes.write(to: file)
    let added = try await add("before sign-out", to: local, files: [file])
    let attachment = try XCTUnwrap(added.snapshot.snips.first?.attachments.first)

    await fixture.account.set(.noAccount)
    let stop = try await fixture.lifecycle.synchronize()
    XCTAssertEqual(stop, .iCloudSignedOut)
    let kept = try await fixture.persistence.snapshot()
    XCTAssertEqual(kept.activeStore.kind, .localOnly)
    XCTAssertEqual(kept.activeStore.quarantinedNamespace, fixture.namespace.binding)
    XCTAssertEqual(kept.attentionReason, .accountSignedOut)
    let localEdit = try await add("edited offline", to: local)
    XCTAssertEqual(Set(localEdit.snapshot.snips.map(\.content)), ["before sign-out", "edited offline"])
    let savedFile = try XCTUnwrap(localEdit.snapshot.attachmentURLs[attachment.id])
    XCTAssertEqual(try Data(contentsOf: savedFile), bytes)

    let reopened = try SwiftDataSyncModePersistence(rootURL: fixture.root)
    let persisted = try await reopened.activeLibrary().checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(Set(persisted.snips.map(\.content)), ["before sign-out", "edited offline"])
    await fixture.account.set(.available(accountLineage: "account-a"))
    let resumed = try await fixture.lifecycle.enableICloudSync()
    XCTAssertEqual(resumed, .enabled)
    let active = try await fixture.persistence.snapshot()
    XCTAssertEqual(active.activeStore.namespace, fixture.namespace.binding)
    _ = try await fixture.lifecycle.retrySynchronization()
    let events = await fixture.records.events()
    XCTAssertTrue(events.contains { if case .sent = $0 { return true }; return false })
  }

  func testNewAccountCannotUploadTheKeptLibraryEvenAfterExplicitEnable() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let previous = try await fixture.persistence.activeLibrary()
    _ = try await add("account A data", to: previous)
    await fixture.account.set(.available(accountLineage: "account-b"))

    let result = try await fixture.lifecycle.retrySynchronization()
    XCTAssertEqual(result, .iCloudAccountChanged)
    let active = try await fixture.lifecycle.activeLibrary()
    XCTAssertEqual(active.recoveryScope,
      SnipRecoveryScopeFactory.scope(forActiveCloudNamespace: fixture.namespace.binding))
    XCTAssertNil(SyncModeActivationManifestReader.activeCloudNamespace(atSyncModeRootURL: fixture.root))
    let edit = try await add("local edit", to: active.library)
    XCTAssertEqual(Set(edit.snapshot.snips.map(\.content)), ["account A data", "local edit"])
    do {
      _ = try await fixture.lifecycle.enableICloudSync()
      XCTFail("A kept library cannot join a different Apple Account")
    } catch ICloudAccountGateError.accountChanged {}
    let controlEvents = await fixture.control.events()
    let recordEvents = await fixture.records.events()
    XCTAssertTrue(controlEvents.isEmpty)
    XCTAssertTrue(recordEvents.isEmpty)
  }

  func testTemporaryAccountAndCloudKitErrorsPreserveTheActiveCache() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let library = try await fixture.persistence.activeLibrary()
    _ = try await add("keep me", to: library)
    let original = try await fixture.persistence.snapshot().activeStore
    await fixture.account.set(.temporarilyUnavailable)
    do {
      _ = try await fixture.lifecycle.synchronize()
      XCTFail("Sync must report the temporary failure")
    } catch ICloudAccountGateError.temporarilyUnavailable {}
    await fixture.account.set(.available(accountLineage: "account-a"))
    await fixture.records.failNextFetch()
    do {
      _ = try await fixture.lifecycle.retrySynchronization()
      XCTFail("Sync must report the fetch failure")
    } catch CloudTransportError.fetchFailed {}
    let current = try await fixture.persistence.snapshot().activeStore
    XCTAssertEqual(current, original)
    let updated = try await add("still writable", to: library)
    XCTAssertEqual(Set(updated.snapshot.snips.map(\.content)), ["keep me", "still writable"])
    let lookups = await fixture.account.lookups
    XCTAssertEqual(lookups, 2)
  }

  func testRecordedPurgeStillDiscardsTheCacheWhenTheAccountSignsOut() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let library = try await fixture.persistence.activeLibrary()
    _ = try await add("purged data", to: library)
    let storeID = try await fixture.persistence.snapshot().activeStore.id
    let store = try await fixture.persistence.libraryForTransition(storeID: storeID)
    let cloud = CloudFullSyncPersistence(library: store, namespace: fixture.namespace,
      dataZone: fixture.descriptor.metadataZone, payloadZone: fixture.descriptor.payloadZone)
    let purge = CloudFetchedBatch(id: UUID(), items: [],
      databaseEvents: [.zoneDeleted(fixture.descriptor.metadataZone, reason: .purged)],
      engineState: nil)
    try await cloud.stage(.fetched(purge), outbound: nil)

    await fixture.account.set(.noAccount)
    let result = try await fixture.lifecycle.synchronize()
    XCTAssertEqual(result, .iCloudDataReset)
    let writable = try await add("after reset", to: library)
    XCTAssertEqual(writable.snapshot.snips.map(\.content), ["after reset"])
  }

  func testLegacyManifestKeepsBothStoresAndIgnoresRetiredFields() async throws {
    for swapped in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let persistence = try SwiftDataSyncModePersistence(rootURL: root)
      let replacement = try await persistence.snapshot().activeStore
      let replacementLibrary = try await persistence.activeLibrary()
      if swapped { _ = try await add("edited after isolation", to: replacementLibrary) }
      let binding = CloudCollectionDescriptor.fresh(ownerName: "owner")
        .namespace(cloudScope: "private", accountLineage: "account-a").binding
      try await persistence.activateEmptyCollection(namespace: binding)
      let cache = try await persistence.snapshot().activeStore
      let cacheLibrary = try await persistence.libraryForTransition(storeID: cache.id)
      _ = try await add("old account cache", to: cacheLibrary)
      if swapped { try await cacheLibrary.markReadOnlyRecovery() }

      let activation = root.appendingPathComponent("activation.json")
      let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: activation))
      var manifest = try XCTUnwrap(raw as? [String: Any])
      var stores = try XCTUnwrap(manifest["stores"] as? [[String: Any]])
      for index in stores.indices {
        let id = stores[index]["id"] as? String
        if id == replacement.id.uuidString { stores[index]["lifecycle"] = swapped ? "ready" : "creating" }
        if id == cache.id.uuidString { stores[index]["lifecycle"] = swapped ? "isolated" : "ready" }
      }
      manifest["stores"] = stores
      manifest["activeStoreID"] = (swapped ? replacement : cache).id.uuidString
      manifest["accountIsolation"] = [
        "id": UUID().uuidString, "storeID": cache.id.uuidString,
        "replacementStoreID": replacement.id.uuidString,
        "resolution": "keepingLocalCopy", "retiredKey": true,
      ]
      manifest["attentionReason"] = "accountSignedOut"
      manifest["writeReservation"] = ["retired": true]
      try JSONSerialization.data(withJSONObject: manifest).write(to: activation)

      let reopened = try SwiftDataSyncModePersistence(rootURL: root)
      let active = try await reopened.snapshot().activeStore
      XCTAssertEqual(active.kind, .localOnly)
      XCTAssertEqual(active.quarantinedNamespace, binding)
      let library = try await reopened.activeLibrary()
      let edited = try await add("new local edit", to: library)
      var expected: Set<String> = ["old account cache", "new local edit"]
      if swapped { expected.insert("edited after isolation") }
      XCTAssertEqual(Set(edited.snapshot.snips.map(\.content)), expected)
      let upgradedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: activation))
      XCTAssertNil((upgradedJSON as? [String: Any])?["accountIsolation"])
    }
  }

  private func add(_ text: String, to library: any SnipLibrary, files: [URL] = []) async throws
    -> SnipLibraryUpdate
  {
    try await library.perform(.add(content: text, origin: .quickEntry, source: nil,
      listID: SnipList.inboxID, attachmentURLs: files, requestID: UUID(), now: Date()), sortedBy: .manual)
  }

  private struct Fixture {
    let root: URL
    let persistence: SwiftDataSyncModePersistence
    let namespace: CloudSyncNamespace
    let descriptor: CloudCollectionDescriptor
    let control: FakeCloudControlTransport
    let records: FakeCloudRecordTransport
    let account: Account
    let lifecycle: SnipSnapICloudSyncLifecycle

    static func make() async throws -> Fixture {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let persistence = try SwiftDataSyncModePersistence(rootURL: root)
      let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
      let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account-a")
      let server = FakeCloudServer()
      let control = FakeCloudControlTransport(server: server)
      await control.seedControl(descriptor)
      try await persistence.activateEmptyCollection(namespace: namespace.binding)
      let source = try await persistence.activeLibrary()
      try Data("1".utf8).write(to: persistence.initialImportMarkerURL)
      let records = FakeCloudRecordTransport(server: server, namespace: namespace)
      let account = Account()
      let lifecycle = SnipSnapICloudSyncLifecycle(
        rootURL: root, sourceLibrary: source, syncModeStore: SnipSyncModeStore(persistence),
        cloudScope: "private", accountLineage: "account-a", accountStateSource: account,
        ownerName: "owner", controlTransport: control,
        makeRecordTransport: { _ in records }, makeDescriptor: { descriptor }
      )
      return Fixture(root: root, persistence: persistence, namespace: namespace,
        descriptor: descriptor, control: control,
        records: records, account: account, lifecycle: lifecycle)
    }
  }

  private actor Account: ICloudAccountStateSource {
    private var state: ICloudAccountState = .available(accountLineage: "account-a")
    private(set) var lookups = 0
    func currentAccountState() -> ICloudAccountState {
      lookups += 1
      return state
    }
    func set(_ state: ICloudAccountState) { self.state = state }
  }
}
