import Foundation
import CloudKit
import CryptoKit
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

final class CloudAppAccountOwnershipTests: XCTestCase {
    func testGeneratedCollectionRolesDriveEveryAttachmentActionWithoutZoneGuessing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try SwiftDataSyncModePersistence(rootURL: root)
        let ownerName = CloudCollectionAssembly.productionControlID.zone.ownerName
        let generated = CloudCollectionDescriptor.fresh(ownerName: ownerName)
        let namespace = generated.namespace(cloudScope: "private", accountLineage: "account-a")
        let binding = ICloudSyncNamespaceBinding(
            scope: namespace.cloudScope,
            accountLineage: namespace.accountLineage,
            generation: namespace.generation,
            zones: Set(namespace.zones.map {
                ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
            })
        )
        let resolved = try SnipSnapCloudSyncHandler.validatedDescriptor(
            CloudCollectionControlRecord(descriptor: generated, version: Data("1".utf8)),
            matching: binding,
            ownerName: ownerName,
            reservedZones: []
        )
        XCTAssertEqual(resolved.metadataZone, generated.metadataZone)
        XCTAssertEqual(resolved.payloadZone, generated.payloadZone)
        XCTAssertTrue(resolved.metadataZone.name.hasPrefix("snips-"))
        XCTAssertTrue(resolved.payloadZone.name.hasPrefix("payloads-"))

        let stale = CloudCollectionDescriptor.fresh(ownerName: ownerName)
        XCTAssertThrowsError(
            try SnipSnapCloudSyncHandler.validatedDescriptor(
                CloudCollectionControlRecord(descriptor: stale, version: Data("2".utf8)),
                matching: binding,
                ownerName: ownerName,
                reservedZones: []
            )
        )

        try await persistence.activateEmptyCollection(namespace: binding)
        let control = FakeCloudControlTransport(server: FakeCloudServer())
        await control.seedControl(generated)
        let preparedURL = root.appendingPathComponent("prepared.bin")
        let probe = AttachmentTransferProbe(preparedURL: preparedURL)
        let handler = SnipSnapCloudSyncHandler(
            persistence: { persistence },
            controlTransport: control,
            accountStateSource: FixedICloudAccountStateSource(state: .available(accountLineage: "account-a")),
            makeAttachmentCoordinator: { _, resolvedNamespace, descriptor in
                await probe.recordConfiguration(
                    namespace: resolvedNamespace,
                    payloadZone: descriptor.payloadZone
                )
                return probe
            }
        )
        let attachmentID = UUID()

        for use in [
            SyncedAttachmentUse.preview, .open, .copy, .export,
        ] {
            let result = try await handler.prepareSyncedAttachment(attachmentID, for: use)
            XCTAssertEqual(result, preparedURL)
        }
        try await handler.clearDownloadedFiles()

        let uses = await probe.uses()
        let clearCount = await probe.clearCount()
        let configuration = await probe.configuration()
        XCTAssertEqual(uses, [.preview, .open, .copy, .export])
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(configuration?.namespace, namespace)
        XCTAssertEqual(configuration?.payloadZone, generated.payloadZone)
    }

  func testAttachmentStatusUsesPersistedPublicationsWhenControlFails() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let storage = try await fixture.persistence.snapshot()
    let binding = try XCTUnwrap(storage.activeStore.namespace)
    let library = try await fixture.persistence.libraryForTransition(storeID: storage.activeStore.id)
    let files = (0..<3).map { fixture.root.appendingPathComponent("status-\($0).txt") }
    for file in files { try Data("Local file".utf8).write(to: file) }
    let active = try await fixture.persistence.activeLibrary()
    let added = try await active.perform(.add(content: "Publications", origin: .quickEntry, source: nil,
      listID: SnipList.inboxID, attachmentURLs: files, requestID: UUID(), now: .distantPast), sortedBy: .manual)
    let attachments = try XCTUnwrap(added.snapshot.snips.first).attachments
    XCTAssertEqual(attachments.count, 3)
    try await library.reconcileCloudAttachments(namespaceKey: binding.namespaceKey,
      metadataZoneName: fixture.descriptor.metadataZone.name,
      metadataOwnerName: fixture.descriptor.metadataZone.ownerName,
      payloadZoneName: fixture.descriptor.payloadZone.name,
      payloadOwnerName: fixture.descriptor.payloadZone.ownerName)
    let initial = try await library.cloudAttachmentStorageSnapshot(namespaceKey: binding.namespaceKey)
    let failed = try XCTUnwrap(initial.publications.first { $0.metadata.attachmentID == attachments[1].id })
    let available = try XCTUnwrap(initial.publications.first { $0.metadata.attachmentID == attachments[2].id })
    try await library.commitCloudAttachmentTransitions(namespaceKey: binding.namespaceKey, transitions: [
      .operationFailed(attachmentID: attachments[1].id, expectedRevision: failed.revision, failure: .quotaExceeded),
      .payloadAccepted(attachmentID: attachments[2].id, expectedRevision: available.revision,
        shadowData: Data(), systemFields: Data()),
    ])
    let uploaded = try await library.cloudAttachmentStorageSnapshot(namespaceKey: binding.namespaceKey)
    let metadata = try XCTUnwrap(uploaded.publications.first { $0.metadata.attachmentID == attachments[2].id })
    try await library.commitCloudAttachmentTransitions(namespaceKey: binding.namespaceKey, transitions: [
      .metadataAccepted(attachmentID: attachments[2].id, expectedRevision: metadata.revision,
        shadowData: Data(), systemFields: Data())
    ])
    await fixture.control.rejectFetches()
    let states = try await fixture.handler.syncedAttachmentStates()
    XCTAssertEqual(states, [attachments[0].id: .waiting, attachments[1].id: .failed, attachments[2].id: .available])
    let fetches = await fixture.control.fetchCount()
    XCTAssertEqual(fetches, 0)

    try await fixture.persistence.activateEmptyCollection(namespace: nil)
    try await fixture.persistence.activateEmptyCollection(namespace: binding)
    let replacementStore = try await fixture.persistence.snapshot().activeStore
    XCTAssertNotEqual(replacementStore.id, storage.activeStore.id)
    let replaced = try await fixture.handler.syncedAttachmentStates()
    XCTAssertTrue(replaced.isEmpty, "The prior store's publications must not appear in its replacement")
    try await fixture.persistence.keepCloudCacheLocally(storeID: replacementStore.id, reason: .accountSignedOut)
    do {
      _ = try await fixture.handler.syncedAttachmentStates()
      XCTFail("A local-only source cannot report retired iCloud publications")
    } catch SnipLibraryError.transferUnsupported {}
  }

  func testAttachmentStatusDoesNotEnterProductionControlRetryGate() async throws {
    let pause = OwnerPause()
    let probe = HeldControlDatabase(pause: pause)
    let control = CloudKitCollectionControlTransport(
      controlID: CloudRecordID(zone: CloudZoneID(name: "test-control", ownerName: "owner"), name: "control"),
      bound: .standard,
      calls: CloudKitDatabaseCalls(
        record: { _, _ in try await probe.record() },
        modifyRecords: { _, _, _, _, _ in throw CloudTransportError.sendFailed },
        modifyRecordZones: { _, _, _ in throw CloudTransportError.sendFailed },
        saveZone: { _, _ in throw CloudTransportError.sendFailed },
        deleteZone: { _, _ in throw CloudTransportError.sendFailed }),
      retry: CloudKitOperationRetry(diagnostics: AppDiagnosticRecorder(record: { _ in })))
    let fixture = try await Fixture.make(controlTransport: control)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let fetching = Task { try await fixture.handler.prepareSyncedAttachment(UUID(), for: .copy) }
    await pause.waitUntilSuspended()
    let finished = expectation(description: "Persisted status finishes while the production retry gate is held")
    let reading = Task {
      do {
        let states = try await fixture.handler.syncedAttachmentStates()
        XCTAssertTrue(states.isEmpty)
      } catch { XCTFail("Local status must not inherit control failure: \(error)") }
      finished.fulfill()
    }
    await fulfillment(of: [finished], timeout: 2)
    let callsWhileHeld = await probe.callCount()
    XCTAssertEqual(callsWhileHeld, 1)
    await pause.resume()
    _ = await fetching.result
    await reading.value
    let calls = await probe.callCount()
    XCTAssertEqual(calls, 1, "Status must never submit a second control request")
  }

  func testUnboundLocalStoreDoesNotWaitForCloudAccountLookup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalReadiness-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    let source = try await persistence.activeLibrary()
    let account = OwnerAccountSource()
    let server = FakeCloudServer()
    let lifecycle = SnipSnapICloudSyncLifecycle(rootURL: root, sourceLibrary: source,
      syncModeStore: SnipSyncModeStore(persistence), cloudScope: "private", accountLineage: "account-a",
      accountStateSource: account, ownerName: "owner",
      controlTransport: FakeCloudControlTransport(server: server),
      makeRecordTransport: { FakeCloudRecordTransport(server: server, namespace: $0.namespace) },
      makeDescriptor: { CloudCollectionDescriptor.fresh(ownerName: "owner") })
    let result = try await lifecycle.synchronize()
    XCTAssertEqual(result, .noChange)
    let lookups = await account.lookupCount()
    XCTAssertEqual(lookups, 0, "An unbound local library does not require a remote account check.")
  }

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
    let handler = lifecycle.makeCloudSyncHandler(operationGate: AsyncOperationGate())
    let isActive = try await handler.isCloudSyncActive()
    XCTAssertFalse(isActive)
    XCTAssertFalse(FileManager.default.fileExists(atPath: syncRoot.appendingPathComponent("activation.json").path))
  }

  func testAttachmentUseKeepsItsSourceUntilTheFileOperationFinishes() async throws {
    let pause = OwnerPause()
    let fixture = try await Fixture.make(attachmentPause: pause)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = try await fixture.persistence.snapshot().activeStore
    let prepare = Task { try await fixture.handler.prepareSyncedAttachment(UUID(), for: .preview) }
    await pause.waitUntilSuspended()
    _ = try await fixture.persistence.activeLibrary()
    let change = Task {
      try await fixture.persistence.keepCloudCacheLocally(storeID: source.id, reason: .accountSignedOut)
    }
    try await waitForQueuedMutations(fixture.persistence, count: 1)
    let unchanged = try await fixture.persistence.snapshot()
    XCTAssertEqual(unchanged.activeStore.kind, .iCloudSync)
    await pause.resume()
    _ = try await prepare.value
    try await change.value
    let kept = try await fixture.persistence.snapshot()
    XCTAssertEqual(kept.activeStore.id, source.id)
    XCTAssertEqual(kept.activeStore.kind, .localOnly)
  }

}

private struct Fixture: Sendable {
  let root: URL
  let persistence: SwiftDataSyncModePersistence
  let descriptor: CloudCollectionDescriptor
  let control: OwnerControlTransport
  let handler: SnipSnapCloudSyncHandler

  static func make(
    attachmentPause: OwnerPause? = nil,
    controlTransport: (any CloudCollectionControlTransport)? = nil,
    makeAttachmentCoordinator: SnipSnapCloudSyncHandler.AttachmentCoordinatorFactory? = nil
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
      accountStateSource: account, ownerName: "owner", controlTransport: controlTransport ?? control,
      makeRecordTransport: { FakeCloudRecordTransport(server: server, namespace: $0.namespace) },
      makeDescriptor: { descriptor })
    let gate = AsyncOperationGate()
    let session = SnipSnapCloudSyncSession(synchronize: { try await lifecycle.synchronize() },
      enable: { try await lifecycle.enableICloudSync() },
      disable: { try await lifecycle.disableICloudSync($0) },
      delete: { try await lifecycle.deleteSyncedContent() },
      activeLibrary: { try await lifecycle.activeLibrary() }, operationGate: gate)
    let handler = lifecycle.makeCloudSyncHandler(operationGate: gate,
      syncWhenPossible: { _ = try? await session.synchronize() },
      makeAttachmentCoordinator: { library, namespace, descriptor in
        if let makeAttachmentCoordinator {
          return await makeAttachmentCoordinator(library, namespace, descriptor)
        }
        return OwnerAttachmentCoordinator(pause: attachmentPause, root: root)
      })
    return Fixture(root: root, persistence: persistence,
      descriptor: descriptor, control: control, handler: handler)
  }
}

private actor OwnerAccountSource: ICloudAccountStateSource {
  var state: ICloudAccountState = .available(accountLineage: "account-a")
  private var lookups = 0
  func currentAccountState() -> ICloudAccountState { lookups += 1; return state }
  func lookupCount() -> Int { lookups }
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
    let lease = try await fixture.persistence.activeCloudMutation(storeID: storage.activeStore.id)
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

private actor HeldControlDatabase {
  let pause: OwnerPause
  private var calls = 0
  init(pause: OwnerPause) { self.pause = pause }
  func record() async throws -> CKRecord {
    calls += 1
    if calls == 1 { await pause.suspend() }
    throw CKError(.permissionFailure)
  }
  func callCount() -> Int { calls }
}

private actor AttachmentTransferProbe: CloudAttachmentTransferring {
    struct Configuration: Equatable, Sendable {
        let namespace: CloudSyncNamespace
        let payloadZone: CloudZoneID
    }

    private let preparedURL: URL
    private var recordedUses: [SyncedAttachmentUse] = []
    private var recordedClearCount = 0
    private var recordedConfiguration: Configuration?

    init(preparedURL: URL) {
        self.preparedURL = preparedURL
    }

    func prepare(attachmentID: UUID, for use: SyncedAttachmentUse) -> URL {
        _ = attachmentID
        recordedUses.append(use)
        return preparedURL
    }

    func clearDownloads() {
        recordedClearCount += 1
    }

    func transferStates() -> [UUID: CloudAttachmentTransferState] { [:] }
    func recordConfiguration(namespace: CloudSyncNamespace, payloadZone: CloudZoneID) {
        recordedConfiguration = Configuration(namespace: namespace, payloadZone: payloadZone)
    }
    func uses() -> [SyncedAttachmentUse] { recordedUses }
    func clearCount() -> Int { recordedClearCount }
    func configuration() -> Configuration? { recordedConfiguration }
}
