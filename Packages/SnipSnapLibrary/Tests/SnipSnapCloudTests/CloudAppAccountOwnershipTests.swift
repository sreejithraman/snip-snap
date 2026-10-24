import Foundation
import CryptoKit
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

final class CloudAppAccountOwnershipTests: XCTestCase {
  func testAccountHandlerIsReadyBeforeOptInWithoutOpeningAnotherModeStore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudOwnerBeforeOptIn-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("source/snips.store"))
    let syncRoot = root.appendingPathComponent("mode")
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let server = FakeCloudServer()
    let lifecycle = SnipSnapICloudSyncLifecycle(rootURL: syncRoot, sourceLibrary: source,
      syncModeStore: nil, cloudScope: "private", accountLineage: "account-a",
      accountStateSource: OwnerAccountSource(), ownerName: "owner",
      controlTransport: FakeCloudControlTransport(server: server),
      makeRecordTransport: { FakeCloudRecordTransport(server: server, namespace: $0.namespace) },
      makeDescriptor: { descriptor })
    let handler = lifecycle.makeAccountCacheHandler(operationGate: AsyncOperationGate())
    let notice = try await handler.refreshAppleAccountNotice()
    let isActive = try await handler.isCloudSyncActive()
    XCTAssertNil(notice)
    XCTAssertFalse(isActive)
    XCTAssertFalse(FileManager.default.fileExists(atPath: syncRoot.appendingPathComponent("activation.json").path))
  }

  func testSameAccountReturnAndLaterLibraryWritesUseTheSameOwner() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstLibrary = try await fixture.session.activeLibrary().library
    try await Self.add("before sign out", to: firstLibrary)
    await fixture.account.set(.noAccount)
    let signedOut = try await fixture.handler.refreshAppleAccountNotice()
    XCTAssertEqual(signedOut, .signedOut)
    let local = try await fixture.session.activeLibrary().library
    try await Self.add("while signed out", to: local)
    await fixture.account.set(.available(accountLineage: "account-a"))

    let returned = try await fixture.handler.refreshAppleAccountNotice()
    XCTAssertNil(returned)
    let active = try await fixture.persistence.snapshot()
    XCTAssertEqual(active.activeStore.kind, .iCloudSync)
    XCTAssertNil(active.accountIsolation)
    let returnedLibrary = try await fixture.session.activeLibrary().library
    try await Self.add("after return", to: returnedLibrary)
    try await Self.add("through retained library", to: firstLibrary)
    let snapshot = try await returnedLibrary.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(Set(snapshot.snips.map(\.content)), [
      "before sign out", "while signed out", "after return", "through retained library",
    ])
    let final = try await fixture.persistence.snapshot()
    XCTAssertEqual(final.activeStore.id, active.activeStore.id)
    XCTAssertNil(final.accountIsolation)
    try Self.assertManifestOwner(fixture.root, activeStoreID: active.activeStore.id)
  }

  func testKeepAndRemoveUseLocalStorageWithoutAControlRequest() async throws {
    for choice in [AppleAccountCacheChoice.keepLocalCopy, .remove] {
      let fixture = try await Fixture.make()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let firstLibrary = try await fixture.session.activeLibrary().library
      try await Self.add("account content", to: firstLibrary)
      await fixture.account.set(.noAccount)
      await fixture.control.rejectFetches()
      let notice = try await fixture.handler.refreshAppleAccountNotice()
      XCTAssertEqual(notice, .signedOut)
      let isolated = try await fixture.persistence.snapshot()
      let active = try await fixture.session.activeLibrary().library
      try await Self.add("local content", to: active)

      try await fixture.handler.resolveAppleAccountCache(choice)
      let resolved = try await fixture.session.activeLibrary().library
      try await Self.add("after choice", to: resolved)
      let snapshot = try await resolved.checkedSnapshot(sortedBy: .manual)
      let expected: Set<String> = choice == .keepLocalCopy
        ? ["account content", "local content", "after choice"] : ["local content", "after choice"]
      XCTAssertEqual(Set(snapshot.snips.map(\.content)), expected)
      let final = try await fixture.persistence.snapshot()
      XCTAssertEqual(final.activeStore.id, isolated.activeStore.id)
      XCTAssertEqual(final.activeStore.kind, .localOnly)
      XCTAssertNil(final.accountIsolation)
      try Self.assertManifestOwner(fixture.root, activeStoreID: final.activeStore.id)
      let fetches = await fixture.control.fetchCount()
      XCTAssertEqual(fetches, 0)
    }
  }

  func testHandlerReadsCannotRecoverAnotherLiveRecordReservation() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try await fixture.persistence.snapshot().activeStore
    let library = try await fixture.persistence.libraryForTransition(storeID: source.id)
    let lease = try await fixture.persistence.activeCloudMutationLease(storeID: source.id)
    let pause = OwnerPause()
    let store = CloudFullSyncPersistence(library: library, namespace: fixture.namespace,
      dataZone: fixture.descriptor.metadataZone, payloadZone: fixture.descriptor.payloadZone,
      mutationLease: lease, afterCommitHook: { await pause.suspend() })
    let batch = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
    try await store.stage(.fetched(batch), outbound: nil)
    let commit = Task { try await store.applyStaged(batch.id) }
    await pause.waitUntilSuspended()
    let isActive = try await fixture.handler.isCloudSyncActive()
    XCTAssertTrue(isActive)
    _ = try await fixture.session.activeLibrary()
    await fixture.account.set(.noAccount)
    do {
      _ = try await fixture.handler.refreshAppleAccountNotice()
      XCTFail("Account isolation cannot pass the live record commit")
    } catch SyncModePersistenceError.transitionInProgress {}
    let attachmentRead = Task { try await fixture.handler.syncedAttachmentStates() }
    try await waitForQueuedMutations(fixture.persistence, count: 1)
    let unchanged = try await fixture.persistence.snapshot()
    XCTAssertEqual(unchanged.activeStore.id, source.id)
    XCTAssertNil(unchanged.accountIsolation)
    await pause.resume()
    try await commit.value
    _ = try await attachmentRead.value

    let notice = try await fixture.handler.refreshAppleAccountNotice()
    XCTAssertEqual(notice, .signedOut)
    let local = try await fixture.session.activeLibrary().library
    try await Self.add("new local content", to: local)
    let isolated = try await fixture.persistence.snapshot()
    XCTAssertNotEqual(isolated.activeStore.id, source.id)
    XCTAssertEqual(isolated.accountIsolation?.storeID, source.id)
    try Self.assertManifestOwner(fixture.root, activeStoreID: isolated.activeStore.id)
  }

  func testAttachmentUseKeepsItsSourceUntilTheFileOperationFinishes() async throws {
    let pause = OwnerPause()
    let fixture = try await Fixture.make(attachmentPause: pause)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try await fixture.persistence.snapshot().activeStore
    let prepare = Task { try await fixture.handler.prepareSyncedAttachment(UUID(), for: .preview) }
    await pause.waitUntilSuspended()
    _ = try await fixture.persistence.activeLibrary()
    do {
      _ = try await fixture.persistence.isolateActiveCloudStore(reason: .signedOut)
      XCTFail("The attachment's source cannot retire during its file operation")
    } catch SyncModePersistenceError.transitionInProgress {}
    await pause.resume()
    _ = try await prepare.value
    let unchanged = try await fixture.persistence.snapshot()
    XCTAssertEqual(unchanged.activeStore.id, source.id)
    _ = try await fixture.persistence.isolateActiveCloudStore(reason: .signedOut)
  }

  private static func add(_ content: String, to library: any SnipLibrary) async throws {
    _ = try await library.perform(.add(content: content, origin: .quickEntry, source: nil,
      listID: SnipList.inbox.id, attachmentURLs: [], requestID: UUID(), now: Date()), sortedBy: .manual)
  }

  private static func assertManifestOwner(_ root: URL, activeStoreID: UUID) throws {
    let manifest = try JSONDecoder().decode(SwiftDataSyncModePersistence.Manifest.self,
      from: Data(contentsOf: root.appendingPathComponent("activation.json")))
    XCTAssertEqual(manifest.activeStoreID, activeStoreID)
  }
}

private struct Fixture: Sendable {
  let root: URL
  let persistence: SwiftDataSyncModePersistence
  let namespace: CloudSyncNamespace
  let descriptor: CloudCollectionDescriptor
  let account: OwnerAccountSource
  let control: OwnerControlTransport
  let handler: AppleAccountCacheCoordinatorHandler
  let session: SnipSnapCloudSyncSession

  static func make(
    attachmentPause: OwnerPause? = nil,
    makeAttachmentCoordinator: AppleAccountCacheCoordinatorHandler.AttachmentCoordinatorFactory? = nil
  ) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudAppOwner-\(UUID())")
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account-a")
    let server = FakeCloudServer()
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    let account = OwnerAccountSource()
    let initial = ICloudSyncModeCoordinator(persistence: persistence, namespace: namespace,
      textZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone,
      makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) },
      accountStateSource: account)
    _ = try await initial.enableOrRetry()
    let source = try await persistence.activeLibrary()
    let baseControl = FakeCloudControlTransport(server: server)
    await baseControl.seedControl(descriptor)
    let control = OwnerControlTransport(base: baseControl)
    let lifecycle = SnipSnapICloudSyncLifecycle(rootURL: root, sourceLibrary: source,
      syncModeStore: SnipSyncModeStore(persistence), cloudScope: "private", accountLineage: "account-a",
      accountStateSource: account, ownerName: "owner", controlTransport: control,
      makeRecordTransport: { FakeCloudRecordTransport(server: server, namespace: $0.namespace) },
      makeDescriptor: { descriptor })
    let gate = AsyncOperationGate()
    let session = SnipSnapCloudSyncSession(synchronize: { try await lifecycle.synchronize() },
      enable: { try await lifecycle.enableICloudSync() },
      disable: { try await lifecycle.disableICloudSync($0) },
      delete: { try await lifecycle.deleteSyncedContent() },
      activeLibrary: { try await lifecycle.activeLibrary() }, operationGate: gate)
    let handler = lifecycle.makeAccountCacheHandler(operationGate: gate,
      syncWhenPossible: { _ = try? await session.synchronize() },
      makeAttachmentCoordinator: { library, namespace, descriptor in
        if let makeAttachmentCoordinator {
          return await makeAttachmentCoordinator(library, namespace, descriptor)
        }
        return OwnerAttachmentCoordinator(pause: attachmentPause, root: root)
      })
    return Fixture(root: root, persistence: persistence, namespace: namespace, descriptor: descriptor,
      account: account, control: control, handler: handler, session: session)
  }
}

private actor OwnerAccountSource: ICloudAccountStateSource {
  var state: ICloudAccountState = .available(accountLineage: "account-a")
  func currentAccountState() -> ICloudAccountState { state }
  func set(_ state: ICloudAccountState) { self.state = state }
}

private actor OwnerControlTransport: CloudCollectionControlTransport {
  let base: FakeCloudControlTransport
  var rejects = false
  var fetches = 0
  init(base: FakeCloudControlTransport) { self.base = base }
  func rejectFetches() { rejects = true }
  func fetchCount() -> Int { fetches }
  func fetchControl() async throws -> CloudCollectionControlRecord? {
    fetches += 1
    if rejects { throw CloudTransportError.fetchFailed }
    return await base.fetchControl()
  }
  func createZones(_ zones: Set<CloudZoneID>) async throws { await base.createZones(zones) }
  func saveControl(_ descriptor: CloudCollectionDescriptor, replacing version: Data?) async throws -> CloudCollectionControlSaveResult {
    await base.saveControl(descriptor, replacing: version)
  }
  func deleteZones(_ zones: Set<CloudZoneID>) async throws { try await base.deleteZones(zones) }
}

private actor OwnerAttachmentCoordinator: CloudAttachmentTransferring {
  let pause: OwnerPause?
  let root: URL
  init(pause: OwnerPause?, root: URL) { self.pause = pause; self.root = root }
  func prepare(attachmentID: UUID, for use: SyncedAttachmentUse) async throws -> URL {
    await pause?.suspend()
    return root.appendingPathComponent("prepared")
  }
  func clearDownloads() {}
  func transferStates() -> [UUID: CloudAttachmentTransferState] { [:] }
}

private actor OwnerPause {
  var paused = false
  var waiters: [CheckedContinuation<Void, Never>] = []
  var continuation: CheckedContinuation<Void, Never>?
  func suspend() async {
    paused = true
    waiters.forEach { $0.resume() }
    waiters = []
    await withCheckedContinuation { continuation = $0 }
  }
  func waitUntilSuspended() async {
    if paused { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func resume() { continuation?.resume(); continuation = nil }
}


extension CloudAppAccountOwnershipTests {
  func testGuardedCacheClearRejectsDownloadQueuedAfterStatus() async throws {
    let fixture = try await Fixture.make(makeAttachmentCoordinator: { library, namespace, _ in
      CacheInstallingAttachment(library: library, namespaceKey: namespace.namespaceKey)
    })
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let storage = try await fixture.persistence.snapshot()
    let binding = try XCTUnwrap(storage.activeStore.namespace)
    let scope = try XCTUnwrap(SnipRecoveryScopeFactory.scope(forActiveCloudNamespace: binding))
    let library = try await fixture.persistence.libraryForTransition(storeID: storage.activeStore.id)
    let bytes = Data("queued downloaded bytes".utf8)
    let source = fixture.root.appendingPathComponent("download.txt")
    try bytes.write(to: source)
    let active = try await fixture.persistence.activeLibrary()
    let added = try await active.perform(.add(content: "attachment", origin: .quickEntry, source: nil,
      listID: SnipList.inbox.id, attachmentURLs: [source], requestID: UUID(), now: .distantPast),
      sortedBy: .manual)
    let attachmentID = try XCTUnwrap(added.snapshot.snips.first?.attachments.first?.id)
    try await library.reconcileCloudAttachments(namespaceKey: binding.namespaceKey,
      metadataZoneName: fixture.descriptor.metadataZone.name,
      metadataOwnerName: fixture.descriptor.metadataZone.ownerName,
      payloadZoneName: fixture.descriptor.payloadZone.name,
      payloadOwnerName: fixture.descriptor.payloadZone.ownerName)
    let publications = try await library.cloudAttachmentStorageSnapshot(namespaceKey: binding.namespaceKey)
    let publication = try XCTUnwrap(publications.publications.first)
    try await library.commitCloudAttachmentTransitions(namespaceKey: binding.namespaceKey,
      transitions: [.remoteMetadataAccepted(metadata: publication.metadata,
        metadataIdentity: publication.metadataIdentity, shadowData: Data(), systemFields: Data())])
    let before = try await fixture.handler.downloadedAttachmentCache(in: scope)
    XCTAssertEqual(before.states[attachmentID], .available)

    let pause = OwnerPause()
    let lease = try await fixture.persistence.activeCloudMutationLease(storeID: storage.activeStore.id)
    let holding = Task { try await lease.run { await pause.suspend() } }
    await pause.waitUntilSuspended()
    let download = Task { try await fixture.handler.prepareSyncedAttachment(attachmentID, for: .open) }
    try await waitForQueuedMutations(fixture.persistence, count: 1)
    let clear = Task {
      try await fixture.handler.clearDownloadedFiles(ifRevision: before.revision, in: scope)
    }
    await pause.resume()
    try await holding.value
    let downloadedURL = try await download.value
    let cleared = try await clear.value

    XCTAssertFalse(cleared, "A queued download must invalidate the status revision before clear")
    XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedURL.path))
    if FileManager.default.fileExists(atPath: downloadedURL.path) {
      XCTAssertEqual(try Data(contentsOf: downloadedURL), bytes)
    }
    let after = try await fixture.handler.downloadedAttachmentCache(in: scope)
    XCTAssertEqual(after.states, before.states, "Transfer availability alone cannot detect a cache download")
    XCTAssertNotEqual(after.revision, before.revision)

    do {
      _ = try await fixture.handler.clearDownloadedFiles(ifRevision: after.revision,
        in: SnipRecoveryScope("another-namespace"))
      XCTFail("A different source namespace cannot clear this cache")
    } catch SyncModePersistenceError.namespaceMismatch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedURL.path))
    let rejectedEmpty = try await fixture.handler.clearDownloadedFiles(ifRevision: "", in: scope)
    XCTAssertFalse(rejectedEmpty)
    let clearedCurrent = try await fixture.handler.clearDownloadedFiles(ifRevision: after.revision, in: scope)
    XCTAssertTrue(clearedCurrent)
    XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedURL.path))
    let emptyCache = try await library.cloudAttachmentStorageSnapshot(namespaceKey: binding.namespaceKey)
    XCTAssertTrue(emptyCache.cacheEntries.isEmpty)
  }

  func testGuardedCacheRevisionRejectsReplacementStoreInTheSameNamespace() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try await fixture.persistence.snapshot().activeStore
    let binding = try XCTUnwrap(first.namespace)
    let scope = try XCTUnwrap(SnipRecoveryScopeFactory.scope(forActiveCloudNamespace: binding))
    let before = try await fixture.handler.downloadedAttachmentCache(in: scope)

    try await fixture.persistence.activateEmptyCollection(namespace: nil)
    do {
      _ = try await fixture.handler.clearDownloadedFiles(ifRevision: before.revision, in: scope)
      XCTFail("A local-only store cannot admit an iCloud cache clear")
    } catch SnipLibraryError.transferUnsupported {}
    try await fixture.persistence.activateEmptyCollection(namespace: binding)
    let replacement = try await fixture.persistence.snapshot().activeStore
    let after = try await fixture.handler.downloadedAttachmentCache(in: scope)

    XCTAssertNotEqual(replacement.id, first.id)
    XCTAssertEqual(before.states, after.states)
    XCTAssertNotEqual(before.revision, after.revision,
      "Identical cache contents in the same namespace still belong to different stores")
    let cleared = try await fixture.handler.clearDownloadedFiles(ifRevision: before.revision, in: scope)
    XCTAssertFalse(cleared)
  }
}

private actor CacheInstallingAttachment: CloudAttachmentTransferring {
  let library: SwiftDataSnipLibrary
  let namespaceKey: CloudSyncNamespaceKey
  init(library: SwiftDataSnipLibrary, namespaceKey: CloudSyncNamespaceKey) {
    self.library = library
    self.namespaceKey = namespaceKey
  }
  func prepare(attachmentID: UUID, for use: SyncedAttachmentUse) async throws -> URL {
    let snapshot = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
    let publication = try XCTUnwrap(snapshot.publications.first { $0.metadata.attachmentID == attachmentID })
    let source = try XCTUnwrap(publication.localSourceURL)
    let bytes = try Data(contentsOf: source)
    let root = try await library.cloudAttachmentStagingRoot(namespaceKey: namespaceKey)
    let staged = root.appendingPathComponent("queued-download/payload")
    try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: staged)
    return try await library.installCloudAttachmentDownload(namespaceKey: namespaceKey,
      attachmentID: attachmentID, expectedPayloadIdentity: publication.metadata.payloadIdentity,
      expectedField: CloudAttachmentRecordCodec.assetField,
      download: CloudAttachmentCacheDownload(payloadIdentity: publication.metadata.payloadIdentity,
        field: CloudAttachmentRecordCodec.assetField, fileURL: staged, byteCount: Int64(bytes.count),
        sha256: Data(SHA256.hash(data: bytes))), maximumBytes: 1_024, now: .distantPast)
  }
  func clearDownloads() async throws {
    try await library.clearCloudAttachmentCache(namespaceKey: namespaceKey)
  }
  func transferStates() async throws -> [UUID: CloudAttachmentTransferState] {
    let snapshot = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
    return Dictionary(uniqueKeysWithValues: snapshot.publications.map { ($0.metadata.attachmentID, $0.transferState) })
  }
}
