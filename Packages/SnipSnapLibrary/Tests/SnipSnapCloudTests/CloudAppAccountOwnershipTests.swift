import Foundation
import CryptoKit
import Observation
import Synchronization
import SnipSnapCore
@testable import SnipSnapPersistence
@testable import SnipSnapCloud
import XCTest

final class CloudAppAccountOwnershipTests: XCTestCase {
  func testOfflineLocalFeedbackAttachmentStatesReachSuspendedControlFetch() async throws {
    let fixture = try await Fixture.make()
    var canRemoveRoot = true
    defer { if canRemoveRoot { try? FileManager.default.removeItem(at: fixture.root) } }
    let library = try await fixture.persistence.activeLibrary()
    try await Self.add("durable content before control lookup", to: library)
    let before = try await fixture.persistence.snapshot()
    let pause = OwnerControlTransport.FetchPause()
    await fixture.control.pauseNextFetch(pause)
    let finished = XCTestExpectation(description: "attachment-state handler returned")
    let cancelled = XCTestExpectation(description: "attachment-state handler cleanup joined")
    let read = Task {
      defer { finished.fulfill(); cancelled.fulfill() }
      return try await fixture.handler.syncedAttachmentStates()
    }

    do {
      let entered = await XCTWaiter.fulfillment(of: [pause.entered], timeout: 30)
      XCTAssertEqual(entered, .completed, "The real handler must reach fetchControl")
      if entered == .completed {
        XCTAssertTrue(pause.isHeld)
        let fetches = await fixture.control.fetchCount()
        XCTAssertEqual(fetches, 1)
        let current = try await fixture.persistence.snapshot()
        XCTAssertEqual(current.activeStore, before.activeStore)
        XCTAssertNil(current.transition)
        XCTAssertNil(current.accountIsolation)
        let persisted = try await library.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(persisted.snips.map(\.content), ["durable content before control lookup"])
        XCTAssertTrue(pause.isHeld, "Managed local reads must not release the control fetch")
      }
    } catch {
      pause.release()
      read.cancel()
      let settled = await XCTWaiter.fulfillment(of: [finished], timeout: 30)
      XCTAssertEqual(settled, .completed, "Cancelled handler must settle during cleanup")
      canRemoveRoot = settled == .completed
      if settled == .completed { _ = await read.result }
      throw error
    }
    pause.release()
    let settled = await XCTWaiter.fulfillment(of: [finished], timeout: 30)
    XCTAssertEqual(settled, .completed, "Released handler must settle during cleanup")
    if settled == .completed {
      let states = try await read.value
      XCTAssertTrue(states.isEmpty)
    } else {
      read.cancel()
      let joined = await XCTWaiter.fulfillment(of: [cancelled], timeout: 30)
      XCTAssertEqual(joined, .completed, "Cancelled handler must settle during cleanup")
      canRemoveRoot = joined == .completed
      if joined == .completed { _ = await read.result }
    }
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
    let handler = lifecycle.makeAccountCacheHandler(operationGate: AsyncOperationGate())
    let notice = try await handler.refreshAppleAccountNotice()
    XCTAssertNil(notice)
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

  func testFailedIsolationSwapFinishesWhenTheNoticeRefreshes() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstLibrary = try await fixture.session.activeLibrary().library
    try await Self.add("account content", to: firstLibrary)
    await fixture.account.set(.noAccount)
    fixture.swapFault.failNextSwap()
    do {
      _ = try await fixture.handler.refreshAppleAccountNotice()
      XCTFail("The full disk must fail the isolation's pointer swap")
    } catch SyncModePersistenceError.storageFailure {}

    let notice = try await fixture.handler.refreshAppleAccountNotice()
    XCTAssertEqual(notice, .signedOut)
    let isolated = try await fixture.persistence.snapshot()
    XCTAssertEqual(isolated.activeStore.kind, .localOnly)
    let local = try await fixture.session.activeLibrary().library
    let hidden = try await local.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(hidden.snips.isEmpty, "The prior account's content must stay hidden")

    try await fixture.handler.resolveAppleAccountCache(.remove)
    let removed = try await fixture.persistence.snapshot()
    XCTAssertNil(removed.accountIsolation)
    XCTAssertEqual(removed.activeStore.kind, .localOnly)
    let resolved = try await fixture.session.activeLibrary().library
    let remaining = try await resolved.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(remaining.snips.isEmpty)
  }

  func testRepeatedSwapFailureStillShowsTheSignedOutNotice() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstLibrary = try await fixture.session.activeLibrary().library
    try await Self.add("account content", to: firstLibrary)
    await fixture.account.set(.noAccount)
    fixture.swapFault.failNextSwap()
    do {
      _ = try await fixture.handler.refreshAppleAccountNotice()
      XCTFail("The full disk must fail the isolation's pointer swap")
    } catch SyncModePersistenceError.storageFailure {}

    fixture.swapFault.failNextSwap()
    do {
      let notice = try await fixture.handler.refreshAppleAccountNotice()
      XCTAssertEqual(notice, .signedOut)
    } catch {
      XCTFail("A swap that fails again must not hide the signed-out notice: \(error)")
    }
    let declared = try await fixture.persistence.snapshot()
    XCTAssertEqual(declared.activeStore.kind, .iCloudSync)

    let notice = try await fixture.handler.refreshAppleAccountNotice()
    XCTAssertEqual(notice, .signedOut)
    let isolated = try await fixture.persistence.snapshot()
    XCTAssertEqual(isolated.activeStore.kind, .localOnly)
    let local = try await fixture.session.activeLibrary().library
    let hidden = try await local.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(hidden.snips.isEmpty, "The prior account's content must stay hidden")
  }

  func testFailedKeepLeavesTheAccountChoiceOpen() async throws {
    let fixture = try await Fixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstLibrary = try await fixture.session.activeLibrary().library
    try await Self.add("account content", to: firstLibrary)
    await fixture.account.set(.noAccount)
    fixture.swapFault.failNextSwap()
    do {
      _ = try await fixture.handler.refreshAppleAccountNotice()
      XCTFail("The full disk must fail the isolation's pointer swap")
    } catch SyncModePersistenceError.storageFailure {}

    fixture.swapFault.failNextSwap()
    do {
      try await fixture.handler.resolveAppleAccountCache(.keepLocalCopy)
      XCTFail("Keep Local Copy must report the failed swap")
    } catch {
      XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
    }

    let notice = try await fixture.handler.refreshAppleAccountNotice()
    XCTAssertEqual(notice, .signedOut)
    let afterFailedKeep = try await fixture.persistence.snapshot()
    XCTAssertEqual(
      afterFailedKeep.accountIsolation?.resolution, .undecided, "A failed Keep must not be stored")

    try await fixture.handler.resolveAppleAccountCache(.remove)
    let removed = try await fixture.persistence.snapshot()
    XCTAssertNil(removed.accountIsolation)
    XCTAssertEqual(removed.activeStore.kind, .localOnly)
    let local = try await fixture.session.activeLibrary().library
    let remaining = try await local.checkedSnapshot(sortedBy: .manual)
    XCTAssertTrue(remaining.snips.isEmpty)
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
  let swapFault: AccountIsolationSwapFault
  let namespace: CloudSyncNamespace
  let descriptor: CloudCollectionDescriptor
  let account: OwnerAccountSource
  let control: OwnerControlTransport
  let handler: AppleAccountCacheCoordinatorHandler
  let session: SnipSnapCloudSyncSession

  static func make(
    attachmentPause: OwnerPause? = nil,
    makeAttachmentCoordinator: AppleAccountCacheCoordinatorHandler.AttachmentCoordinatorFactory? = nil,
    normalScheduling: OwnerNormalScheduleProbe? = nil
  ) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudAppOwner-\(UUID())")
    if normalScheduling != nil { NSLog("MacScheduleOwner allocated retained store root: %@", root.path) }
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account-a")
    let server = FakeCloudServer()
    let swapFault = AccountIsolationSwapFault()
    let persistence = try SwiftDataSyncModePersistence(rootURL: root, manifestWriter: swapFault.write,
      writeHook: swapFault.arm)
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
      makeRecordTransport: { context -> any CloudRecordTransport in
        let transport = FakeCloudRecordTransport(server: server, namespace: context.namespace)
        if let normalScheduling {
          return OwnerNormalScheduleTransport(base: transport, probe: normalScheduling)
        }
        return transport
      },
      makeDescriptor: { descriptor })
    let gate = AsyncOperationGate()
    let session = SnipSnapCloudSyncSession(synchronize: { try await lifecycle.synchronize() },
      scheduleAutomaticSync: {
        guard let normalScheduling else { return }
        normalScheduling.workerEntered.fire()
        defer { normalScheduling.workerFinished.fire() }
        do { try await lifecycle.scheduleAutomaticSync() }
        catch { normalScheduling.recordFailure(); throw error }
      },
      enable: { try await lifecycle.enableICloudSync() },
      disable: { try await lifecycle.disableICloudSync($0) },
      delete: { try await lifecycle.deleteSyncedContent() },
      activeLibrary: { try await lifecycle.activeLibrary() }, operationGate: gate)
    let schedule: AppleAccountCacheCoordinatorHandler.ScheduleAction? = normalScheduling.map { probe in
      return { @Sendable in
        await session.scheduleAutomaticSync()
        probe.submitted.fire()
      }
    }
    let handler = lifecycle.makeAccountCacheHandler(operationGate: gate,
      syncWhenPossible: { _ = try? await session.synchronize() },
      scheduleSyncAfterLocalChange: schedule,
      makeAttachmentCoordinator: { library, namespace, descriptor in
        if let makeAttachmentCoordinator {
          return await makeAttachmentCoordinator(library, namespace, descriptor)
        }
        return OwnerAttachmentCoordinator(pause: attachmentPause, root: root)
      })
    return Fixture(root: root, persistence: persistence, swapFault: swapFault, namespace: namespace,
      descriptor: descriptor, account: account, control: control, handler: handler, session: session)
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
  private var nextFetchPause: FetchPause?
  init(base: FakeCloudControlTransport) { self.base = base }
  func rejectFetches() { rejects = true }
  func pauseNextFetch(_ pause: FetchPause) { nextFetchPause = pause }
  func fetchCount() -> Int { fetches }
  func fetchControl() async throws -> CloudCollectionControlRecord? {
    fetches += 1
    if rejects { throw CloudTransportError.fetchFailed }
    let pause = nextFetchPause
    nextFetchPause = nil
    try await pause?.suspend()
    return await base.fetchControl()
  }
  func createZones(_ zones: Set<CloudZoneID>) async throws { await base.createZones(zones) }
  func saveControl(_ descriptor: CloudCollectionDescriptor, replacing version: Data?) async throws -> CloudCollectionControlSaveResult {
    await base.saveControl(descriptor, replacing: version)
  }
  func deleteZones(_ zones: Set<CloudZoneID>) async throws { try await base.deleteZones(zones) }

  final class FetchPause: @unchecked Sendable {
    let entered = XCTestExpectation(description: "fetchControl suspended")
    private let lock = NSLock()
    private var released = false
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { lock.withLock { suspended && !released } }

    func suspend() async throws {
      try Task.checkCancellation()
      await withTaskCancellationHandler {
        await withCheckedContinuation { pending in
          let resume = lock.withLock {
            suspended = true
            if released || Task.isCancelled { return true }
            continuation = pending
            return false
          }
          entered.fulfill()
          if resume { pending.resume() }
        }
      } onCancel: {
        self.release()
      }
      try Task.checkCancellation()
    }

    func release() {
      let pending = lock.withLock {
        released = true
        let pending = continuation
        continuation = nil
        return pending
      }
      pending?.resume()
    }
  }
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


extension CloudAppAccountOwnershipTests {
  @MainActor
  func testNormalSchedulingReturnsBehindHeldHandlerControlFetchWhileManagedWritesCommit() async throws {
    let scheduling = OwnerNormalScheduleProbe()
    let fixture = try await Fixture.make(normalScheduling: scheduling)
    defer { NSLog("MacScheduleOwner retained store root: %@", fixture.root.path) }
    let managed = try await fixture.persistence.activeLibrary()
    let before = try await fixture.persistence.snapshot()
    let storeURL = await fixture.persistence.storeFileURL(before.activeStore)
    let pause = OwnerControlTransport.FetchPause()
    await fixture.control.pauseNextFetch(pause)
    let readFinished = OwnerNormalScheduleSignal()
    let read = Task {
      defer { readFinished.fire() }
      _ = try await fixture.handler.syncedAttachmentStates()
    }
    var work: [(Task<Void, any Error>, OwnerNormalScheduleSignal)] = [(read, readFinished)]

    func exercise() async throws {
      let ready = await XCTWaiter.fulfillment(of: [pause.entered], timeout: 30)
      XCTAssertEqual(ready, .completed, "The real account handler must hold fetchControl and its shared app gate")
      guard ready == .completed else { return }
      XCTAssertTrue(pause.isHeld)
      let localFinished = OwnerNormalScheduleSignal()
      let local = Task {
        defer { localFinished.fire() }
        try await Self.add("Mac normal scheduling durable local write", to: managed)
        await fixture.handler.scheduleSyncAfterLocalChange()
      }
      work.append((local, localFinished))
      let completed = await localFinished.wait(for: .seconds(2))
      XCTAssertTrue(pause.isHeld)
      XCTAssertTrue(completed, "Managed local commit and real schedule submission must finish before control release")
      guard completed else { return }
      try await local.value
      XCTAssertTrue(scheduling.submitted.isSet, "The injected production-equivalent action must enqueue on the real session")
      let enteredTooSoon = await scheduling.workerEntered.wait(for: .milliseconds(100))
      XCTAssertFalse(enteredTooSoon, "Normal session work must respect the handler's shared gate")
      let reader = try SwiftDataSnipLibrary(storeURL: storeURL)
      let durable = try await reader.checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(durable.snips.map(\.content), ["Mac normal scheduling durable local write"])
      XCTAssertEqual(durable.snips.map(\.isDone), [false])
      let current = try await fixture.persistence.snapshot()
      var expectedStore = before.activeStore
      expectedStore.revision = current.activeStore.revision
      XCTAssertEqual(current.activeStore, expectedStore)
      XCTAssertGreaterThan(current.activeStore.revision, before.activeStore.revision)
      XCTAssertNil(current.transition)
      XCTAssertNil(current.accountIsolation)
      let fetches = await fixture.control.fetchCount()
      XCTAssertEqual(fetches, 1)
      XCTAssertTrue(pause.isHeld, "Durability and enqueue assertions must precede any release")

      pause.release()
      let returned = await readFinished.wait(for: .seconds(30))
      XCTAssertTrue(returned)
      guard returned else { return }
      try await read.value
      let entered = await scheduling.workerEntered.wait(for: .seconds(30))
      let finished = await scheduling.workerFinished.wait(for: .seconds(30))
      XCTAssertTrue(entered, "The queued normal schedule action must actually run after gate release")
      XCTAssertTrue(finished, "The actual lifecycle scheduler must finish")
      XCTAssertFalse(scheduling.failed)
      XCTAssertTrue(scheduling.transportScheduled.isSet, "The actual record coordinator must submit automatic work")
      XCTAssertEqual(scheduling.explicitTransfers, 0, "The automatic provider capability must prevent explicit fetch/send fallback")
      let finalFetches = await fixture.control.fetchCount()
      XCTAssertEqual(finalFetches, 1, "Normal scheduling must not turn into an explicit control fetch")
    }

    func cleanUp() async {
      let cleanup = Task { @MainActor in
        pause.release()
        work.forEach { $0.0.cancel() }
        let deadline = ContinuousClock.now + .seconds(30)
        var settled = true
        for (task, finished) in work {
          let joined = await finished.wait(for: deadline - ContinuousClock.now)
          XCTAssertTrue(joined, "Normal scheduling proof cleanup could not join an owned caller")
          if joined { _ = await task.result } else { settled = false }
        }
        if scheduling.submitted.isSet {
          let joined = await scheduling.workerFinished.wait(for: deadline - ContinuousClock.now)
          XCTAssertTrue(joined, "Normal scheduling proof cleanup left the session worker active")
          settled = settled && joined
          if joined {
            let drained = OwnerNormalScheduleSignal()
            let drain = Task {
              defer { drained.fire() }
              _ = try await fixture.session.activeLibrary()
            }
            work.append((drain, drained))
            let released = await drained.wait(for: deadline - ContinuousClock.now)
            XCTAssertTrue(released, "Normal scheduling proof cleanup could not reacquire the shared gate")
            if released {
              do { try await drain.value }
              catch { XCTFail("Normal scheduling cleanup gate drain failed: \(error)"); settled = false }
            } else { drain.cancel(); settled = false }
          }
        }
        if !settled { NSLog("MacScheduleOwner retained active ownership and store root: %@", fixture.root.path) }
      }
      await cleanup.value
    }

    do {
      try await exercise()
      await cleanUp()
    } catch {
      await cleanUp()
      throw error
    }
  }
}

private final class OwnerNormalScheduleProbe: @unchecked Sendable {
  let submitted = OwnerNormalScheduleSignal()
  let workerEntered = OwnerNormalScheduleSignal()
  let workerFinished = OwnerNormalScheduleSignal()
  let transportScheduled = OwnerNormalScheduleSignal()
  private let lock = NSLock()
  private var failure = false
  private var transfers = 0
  var failed: Bool { lock.withLock { failure } }
  var explicitTransfers: Int { lock.withLock { transfers } }
  func recordFailure() { lock.withLock { failure = true } }
  func recordExplicitTransfer() { lock.withLock { transfers += 1 } }
}

// The controlled provider accepts scheduling, while every existing transport operation is forwarded.
private actor OwnerNormalScheduleTransport: CloudRecordTransport, CloudAutomaticSyncScheduling {
  let base: FakeCloudRecordTransport
  let probe: OwnerNormalScheduleProbe
  private var scheduled: [CloudOutboundBatch] = []
  init(base: FakeCloudRecordTransport, probe: OwnerNormalScheduleProbe) { self.base = base; self.probe = probe }
  func start(state: CloudEngineStateEnvelope?) async throws { try await base.start(state: state) }
  func start(state: CloudEngineStateEnvelope?, initialOutbound: CloudOutboundBatch?) async throws {
    try await base.start(state: state, initialOutbound: initialOutbound)
  }
  func start(state: CloudEngineStateEnvelope?, initialOutbound: CloudOutboundBatch?,
             outboundAdmission: CloudRecordOutboundAdmission) async throws {
    try await base.start(state: state, initialOutbound: initialOutbound, outboundAdmission: outboundAdmission)
  }
  func reset() async { await base.reset() }
  func scheduleAutomaticSync(_ batch: CloudOutboundBatch) {
    scheduled.append(batch)
    probe.transportScheduled.fire()
  }
  func fetch(scope: CloudFetchScope) async throws -> CloudFetchedBatch {
    probe.recordExplicitTransfer()
    return try await base.fetch(scope: scope)
  }
  func send(_ batch: CloudOutboundBatch) async throws -> CloudSentBatch {
    probe.recordExplicitTransfer()
    return try await base.send(batch)
  }
  func confirmApplied(_ batchID: UUID) async throws { try await base.confirmApplied(batchID) }
  func confirmApplied(_ batchID: UUID, outboundAdmission: CloudRecordOutboundAdmission) async throws {
    try await base.confirmApplied(batchID, outboundAdmission: outboundAdmission)
  }
  func pendingEvent() async -> CloudRecordTransportEvent? { await base.pendingEvent() }
  func finishCurrentSyncCycle() async throws { try await base.finishCurrentSyncCycle() }
  func fetchRecord(_ id: CloudRecordID, fields: Set<String>) async throws -> CloudRecordSnapshot? {
    try await base.fetchRecord(id, fields: fields)
  }
  func fetchAsset(_ id: CloudRecordID, field: String, destination: CloudAssetDestination) async throws -> CloudAssetReceipt? {
    try await base.fetchAsset(id, field: field, destination: destination)
  }
}

// Timeout cancels only a waiter, never the held transport or session work.
private final class OwnerNormalScheduleSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
  var isSet: Bool { lock.withLock { fired } }
  func fire() {
    let pending = lock.withLock {
      fired = true
      let pending = Array(waiters.values)
      waiters.removeAll()
      return pending
    }
    pending.forEach { $0.resume(returning: true) }
  }
  func wait(for timeout: Duration) async -> Bool {
    if isSet { return true }
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        let id = UUID()
        return await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            let immediate: Bool? = self.lock.withLock {
              if self.fired { return true }
              if Task.isCancelled { return false }
              self.waiters[id] = continuation
              return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
          }
        } onCancel: {
          self.lock.withLock { self.waiters.removeValue(forKey: id) }?.resume(returning: false)
        }
      }
      group.addTask {
        do { try await Task.sleep(for: timeout) } catch {}
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }
}


extension CloudAppAccountOwnershipTests {
  func testCheckedAttachmentReadPairsRealPublicationStatesWithItsManagedSource() async throws {
    let server = FakeCloudServer()
    let fixture = try await Fixture.make(makeAttachmentCoordinator: { library, namespace, descriptor in
      CloudAttachmentTransferCoordinator(library: library, namespace: namespace,
        payloadZone: descriptor.payloadZone,
        transport: FakeCloudRecordTransport(server: server, namespace: namespace), maximumCacheBytes: 0)
    }, normalScheduling: OwnerNormalScheduleProbe())
    let storage = try await fixture.persistence.snapshot()
    let binding = try XCTUnwrap(storage.activeStore.namespace)
    let sourceFile = fixture.root.appendingPathComponent("waiting.txt")
    try Data("literal pending attachment".utf8).write(to: sourceFile)
    let managed = try await fixture.persistence.activeLibrary()
    let added = try await managed.perform(.add(content: "Pending attachment", origin: .quickEntry,
      source: nil, listID: SnipList.inboxID, attachmentURLs: [sourceFile], requestID: UUID(), now: .distantPast),
      sortedBy: .manual)
    let attachmentID = try XCTUnwrap(added.snapshot.snips.first?.attachments.first?.id)
    let raw = try await fixture.persistence.libraryForTransition(storeID: storage.activeStore.id)
    try await raw.reconcileCloudAttachments(namespaceKey: binding.namespaceKey,
      metadataZoneName: fixture.descriptor.metadataZone.name, metadataOwnerName: "owner",
      payloadZoneName: fixture.descriptor.payloadZone.name, payloadOwnerName: "owner")

    let content = try await SavedSnipsSession(library: managed).checkedRead(sortedBy: .manual)
    let observed = try await fixture.handler.checkedAttachmentStates()

    XCTAssertTrue(observed.continuesApplication(content.publication))
    XCTAssertTrue(observed.matchesApplicationTarget(content.target))
    XCTAssertEqual(observed.source.storeID, storage.activeStore.id)
    XCTAssertEqual(observed.source.storageMode, .iCloudSync)
    XCTAssertEqual(observed.source.namespaceKey, fixture.namespace.namespaceKey.rawValue)
    XCTAssertEqual(observed.states, [attachmentID: .waiting])
    let publications = try await raw.cloudAttachmentStorageSnapshot(namespaceKey: binding.namespaceKey)
    let publication = try XCTUnwrap(publications.publications.first)
    try await raw.commitCloudAttachmentTransitions(namespaceKey: binding.namespaceKey,
      transitions: [.operationFailed(attachmentID: attachmentID,
        expectedRevision: publication.revision, failure: .quotaExceeded)])
    let failed = try await fixture.handler.checkedAttachmentStates()
    XCTAssertEqual(failed.source, observed.source)
    XCTAssertEqual(failed.states, [attachmentID: .failed], "A failed VALUE still completes the checked read")
    try await raw.commitCloudAttachmentTransitions(namespaceKey: binding.namespaceKey,
      transitions: [.remoteMetadataAccepted(metadata: publication.metadata,
        metadataIdentity: publication.metadataIdentity, shadowData: Data(), systemFields: Data())])
    let available = try await fixture.handler.checkedAttachmentStates()
    XCTAssertEqual(available.source, observed.source)
    XCTAssertEqual(available.states, [attachmentID: .available])
    let reopened = try SwiftDataSyncModePersistence(rootURL: fixture.root)
    let durable = try await (try await reopened.activeLibrary()).checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(durable.snips.map(\.content), ["Pending attachment"])
    XCTAssertEqual(durable.snips.first?.attachments.first?.id, attachmentID)
  }

  func testCheckedLocalAttachmentReadUsesTheActualLocalSourceWithoutCloudLookup() async throws {
    let fixture = try await Fixture.make(normalScheduling: OwnerNormalScheduleProbe())
    try await fixture.persistence.activateEmptyCollection(namespace: nil)
    let managed = try await fixture.persistence.activeLibrary()
    try await Self.add("Local checked content", to: managed)
    let local = try await fixture.persistence.snapshot().activeStore
    let accountCalls = await fixture.account.lookupCount()
    let controlCalls = await fixture.control.fetchCount()

    let observed = try await fixture.handler.checkedAttachmentStates()

    XCTAssertEqual(observed.source.storeID, local.id)
    XCTAssertEqual(observed.source.storageMode, .localOnly)
    XCTAssertNil(observed.source.namespaceKey)
    XCTAssertTrue(observed.states.isEmpty)
    let afterAccountCalls = await fixture.account.lookupCount()
    let afterControlCalls = await fixture.control.fetchCount()
    XCTAssertEqual(afterAccountCalls, accountCalls)
    XCTAssertEqual(afterControlCalls, controlCalls)
    let durable = try await managed.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(durable.snips.map(\.content), ["Local checked content"])
  }

  func testCheckedAttachmentReadPropagatesTheActualControlError() async throws {
    let fixture = try await Fixture.make(normalScheduling: OwnerNormalScheduleProbe())
    await fixture.control.rejectFetches()
    do {
      _ = try await fixture.handler.checkedAttachmentStates()
      XCTFail("A failed source resolution is not an empty checked read.")
    } catch { XCTAssertEqual(error as? CloudTransportError, .fetchFailed) }
  }

  @MainActor
  func testCurrentCheckpointUsesTheExistingNormalOwnerAndRejectsItsReplacement() async throws {
    let fixture = try await CheckedOwnerReadFixture.make()
    let source = try await fixture.handler.checkedAttachmentStates().source
    do {
      _ = try await fixture.handler.checkedCurrentSyncStatus(for: source)
      XCTFail("A checkpoint must not create a normal owner.")
    } catch CloudRecordWorkError.replaced {}
    _ = try await fixture.lifecycle.retrySynchronization()
    let transfers = await fixture.recordTransport.events()

    let current = try await fixture.handler.checkedCurrentSyncStatus(for: source)

    XCTAssertEqual(current.source, source)
    XCTAssertNil(current.issue)
    XCTAssertTrue(current.settled)
    let after = await fixture.recordTransport.events()
    XCTAssertEqual(after, transfers, "A checkpoint must not fetch or send another batch")
    try await fixture.persistence.activateEmptyCollection(namespace: nil)
    do {
      _ = try await fixture.handler.checkedCurrentSyncStatus(for: source)
      XCTFail("A retired normal owner must not confirm the new local store.")
    } catch CloudRecordWorkError.replaced {}
    let final = await fixture.recordTransport.events()
    XCTAssertEqual(final, transfers)
  }

  @MainActor
  func testInstalledCurrentStatusNotifiesWithoutReplayingOverAReentrantStop() async throws {
    let fixture = try await CheckedOwnerReadFixture.make()
    _ = try await fixture.lifecycle.retrySynchronization()
    let source = try await fixture.handler.checkedAttachmentStates().source
    let settings = SyncedContentSettingsModel(mode: .iCloudSync)
    let start = settings.recordSyncStarted()
    let current = try await fixture.handler.checkedCurrentSyncStatus(for: source)
    let prepared = try XCTUnwrap(settings.prepareCurrentState(current, for: start))
    let changes = Mutex(0)
    let stopInProgress = Mutex(false)
    withObservationTracking {
      _ = settings.state
      _ = settings.detail
      _ = settings.canSyncNow
    } onChange: {
      let entered = stopInProgress.withLock { active in
        guard !active else { return false }
        active = true
        return true
      }
      guard entered else { return }
      defer { stopInProgress.withLock { $0 = false } }
      let shouldStop = changes.withLock { count in
        count += 1
        return count == 1
      }
      guard shouldStop else { return }
      MainActor.assumeIsolated { settings.recordSyncStopped(.iCloudAccountChanged) }
    }

    let closing = try XCTUnwrap(current.publication).beginApplication()
    let installed = settings.installPreparedCurrentState(prepared, within: closing)
    closing.finish()

    XCTAssertTrue(installed)
    XCTAssertEqual(settings.state, .ready, "Public getters read the silent authoritative install")
    XCTAssertEqual(changes.withLock { $0 }, 0, "Installing under ownership cannot notify observers")
    settings.notifyInstalledCurrentState(prepared)
    XCTAssertEqual(changes.withLock { $0 }, 1)
    XCTAssertEqual(settings.mode, .localOnly)
    XCTAssertEqual(settings.state, .failed(.iCloudAccountChanged))
    XCTAssertEqual(settings.detail,
      "Your previous account’s snips stay separate. Choose whether to keep them before syncing again.")
  }

  @MainActor
  func testPreparedCurrentStatusCannotOverwriteAStopOrANewerOperation() async throws {
    let fixture = try await CheckedOwnerReadFixture.make()
    _ = try await fixture.lifecycle.retrySynchronization()
    let source = try await fixture.handler.checkedAttachmentStates().source
    let settings = SyncedContentSettingsModel(mode: .iCloudSync)
    let start = settings.recordSyncStarted()
    let current = try await fixture.handler.checkedCurrentSyncStatus(for: source)
    let prepared = try XCTUnwrap(settings.prepareCurrentState(current, for: start))
    _ = settings.recordSyncStarted()
    let closing = try XCTUnwrap(current.publication).beginApplication()
    let installed = settings.installPreparedCurrentState(prepared, within: closing)
    closing.finish()
    XCTAssertFalse(installed, "A newer operation invalidates preparation even with the same visible state")
    XCTAssertEqual(settings.state, .syncing)
    settings.recordSyncStopped(.signInRequired)
    XCTAssertNil(settings.prepareCurrentState(current, for: start))
    XCTAssertEqual(settings.mode, .localOnly)
    XCTAssertEqual(settings.state, .failed(.signInRequired))
  }

  @MainActor
  func testPreparedCurrentStatusCannotCompleteANewerRemoval() async throws {
    let fixture = try await CheckedOwnerReadFixture.make()
    _ = try await fixture.lifecycle.retrySynchronization()
    let source = try await fixture.handler.checkedAttachmentStates().source
    let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
    let start = settings.recordSyncStarted()
    let current = try await fixture.handler.checkedCurrentSyncStatus(for: source)
    let prepared = try XCTUnwrap(settings.prepareCurrentState(current, for: start))
    settings.recordRemovalCompleted(start)
    XCTAssertEqual(settings.state, .deleted)
    settings.recordRemovalPending()
    let closing = try XCTUnwrap(current.publication).beginApplication()
    let installed = settings.installPreparedCurrentState(prepared, within: closing)
    closing.finish()
    XCTAssertFalse(installed)
    XCTAssertEqual(settings.state, .removalPending)
    XCTAssertTrue(settings.canFinishDeleting)
    XCTAssertNil(settings.finishDeletingIssue)
  }
}

extension CloudAppAccountOwnershipTests {
  @MainActor
  func testCheckedAttachmentReadPublishesItsActualResultOnlyAfterSuccessfulRelease() async throws {
    let fixture = try await CheckedOwnerReadFixture.make()
    let library = try await fixture.persistence.activeLibrary()
    let session = SavedSnipsSession(library: library)
    let before = try await session.checkedRead(sortedBy: .manual)
    let observed = try await fixture.handler.checkedAttachmentStates()
    XCTAssertEqual(observed.source, before.source)
    XCTAssertEqual(observed.states, [:])
    XCTAssertTrue(observed.continuesApplication(before.publication))
    let closing = try XCTUnwrap(observed.publication).beginApplication()
    closing.finish()
    let storage = try await fixture.persistence.snapshot()
    XCTAssertFalse(storage.hasActiveMutationReservation)
    try await Self.add("available after checked release", to: library)
    let durable = try await session.checkedRead(sortedBy: .manual)
    XCTAssertEqual(durable.snapshot.snips.map(\.content), ["available after checked release"])
    await fixture.cleanUp()
  }

  @MainActor
  func testQueuedManagedWriterRevokesTheSameAttachmentResultBeforeItsContentWrite() async throws {
    let fixture = try await CheckedOwnerReadFixture.make(holdRead: true)
    let library = try await fixture.persistence.activeLibrary()
    var response: Result<SyncedAttachmentReadObservation, any Error>?
    let read = fixture.start {
      do { response = .success(try await fixture.handler.checkedAttachmentStates()) }
      catch { response = .failure(error) }
    }
    if await fixture.ready(fixture.readPause.entered, "actual transfer-state read") {
      fixture.fault.holdWriter = true
      let writer = fixture.start {
        do { try await Self.add("winning queued content", to: library) }
        catch { XCTFail("Queued durable write failed: \(error)") }
      }
      if await fixture.ready(fixture.queued, "managed write admission behind the actual read") {
        fixture.readPause.release()
        if await fixture.ready(fixture.writerPause.entered, "winning writer before its content operation"),
           await fixture.complete(read, "same read result returned after FIFO grant") {
          do {
            let observed = try XCTUnwrap(response).get()
            XCTAssertEqual(observed.states, [:])
            do {
              let closing = try XCTUnwrap(observed.publication).beginApplication()
              closing.finish()
              XCTFail("The winning FIFO writer must already have revoked this exact read result")
            } catch SnipLibraryReadPublicationError.revoked {}
            let stillBeforeWrite = try await library.checkedSnapshot(sortedBy: .manual)
            XCTAssertTrue(stillBeforeWrite.snips.isEmpty)
          } catch { XCTFail("The completed read must preserve its successful value: \(error)") }
        }
        fixture.writerPause.release()
        if await fixture.complete(writer, "queued writer commits after test release") {
          do {
            let reopened = try SwiftDataSyncModePersistence(rootURL: fixture.root)
            let durable = try await (try await reopened.activeLibrary()).checkedSnapshot(sortedBy: .manual)
            XCTAssertEqual(durable.snips.map(\.content), ["winning queued content"])
          } catch { XCTFail("Independent durable read failed: \(error)") }
        }
      }
    }
    await fixture.cleanUp()
  }

  @MainActor
  func testAttachmentOperationErrorWinsOverItsReservationClearFault() async throws {
    let fixture = try await CheckedOwnerReadFixture.make()
    let original = CheckedOwnerReadFailure()
    fixture.fault.operationError = original
    fixture.fault.armClearFailure = true
    do {
      _ = try await fixture.handler.checkedAttachmentStates()
      XCTFail("An operation error cannot return a checked value")
    } catch { XCTAssertTrue((error as AnyObject) === original) }
    XCTAssertEqual(fixture.fault.clearAttempts, 1)
    let library = try await fixture.persistence.activeLibrary()
    try await Self.add("local recovery after operation failure", to: library)
    let durable = try await library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(durable.snips.map(\.content), ["local recovery after operation failure"])
    await fixture.cleanUp()
  }

  @MainActor
  func testSuccessfulAttachmentReadRetainsItsFirstClearErrorWhenCleanupRetrySucceeds() async throws {
    let fixture = try await CheckedOwnerReadFixture.make()
    fixture.fault.armClearFailure = true
    do {
      _ = try await fixture.handler.checkedAttachmentStates()
      XCTFail("A successful cleanup retry cannot grant an unreturned read result")
    } catch { XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure) }
    XCTAssertEqual(fixture.fault.clearAttempts, 2)
    let storage = try await fixture.persistence.snapshot()
    XCTAssertFalse(storage.hasActiveMutationReservation)
    let actual = try await fixture.handler.checkedAttachmentStates()
    XCTAssertEqual(actual.states, [:])
    let closing = try XCTUnwrap(actual.publication).beginApplication()
    closing.finish()
    await fixture.cleanUp()
  }

  @MainActor
  func testAttachmentReadPublishedBeforeClearErrorReturnsNoResultAndKeepsLocalWorkWritable() async throws {
    let fixture = try await CheckedOwnerReadFixture.make()
    fixture.fault.armClearFailure = true
    fixture.fault.writeThenFail = true
    do {
      _ = try await fixture.handler.checkedAttachmentStates()
      XCTFail("A manifest published before its error is still a failed checked read")
    } catch { XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure) }
    XCTAssertEqual(fixture.fault.clearAttempts, 2)
    let reopened = try SwiftDataSyncModePersistence(rootURL: fixture.root)
    let storage = try await reopened.snapshot()
    XCTAssertFalse(storage.hasActiveMutationReservation)
    let local = try await reopened.activeLibrary()
    try await Self.add("writable after uncertain release", to: local)
    let durable = try await local.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(durable.snips.map(\.content), ["writable after uncertain release"])
    await fixture.cleanUp()
  }
}

private final class CheckedOwnerReadFailure: Error, @unchecked Sendable {}

private final class CheckedOwnerReadFault: @unchecked Sendable {
  private let lock = NSLock()
  private var error: CheckedOwnerReadFailure?
  private var arm = false
  private var armed = false
  private var attempts = 0
  private var failAfterWrite = false
  private var writerHeld = false
  private var stateReads = 0
  var stateReadCount: Int { lock.withLock { stateReads } }
  func enteredStateRead() { lock.withLock { stateReads += 1 } }
  var operationError: CheckedOwnerReadFailure? {
    get { lock.withLock { error } }
    set { lock.withLock { error = newValue } }
  }
  var armClearFailure: Bool {
    get { lock.withLock { arm } }
    set { lock.withLock { arm = newValue } }
  }
  var writeThenFail: Bool {
    get { lock.withLock { failAfterWrite } }
    set { lock.withLock { failAfterWrite = newValue } }
  }
  var holdWriter: Bool {
    get { lock.withLock { writerHeld } }
    set { lock.withLock { writerHeld = newValue } }
  }
  var clearAttempts: Int { lock.withLock { attempts } }
  func returnedActualStates() throws {
    let failure = lock.withLock { armed = arm; return error }
    if let failure { throw failure }
  }
  func write(_ data: Data, _ url: URL) throws {
    let action = lock.withLock { () -> (fail: Bool, after: Bool) in
      guard armed else { return (false, false) }
      attempts += 1
      return (attempts == 1, failAfterWrite)
    }
    if action.fail && !action.after { throw CheckedOwnerReadFailure() }
    try DurableFile.write(data, to: url)
    if action.fail { throw CheckedOwnerReadFailure() }
  }
}

private actor CheckedOwnerAttachmentReader: CloudAttachmentTransferring {
  let base: CloudAttachmentTransferCoordinator
  let fault: CheckedOwnerReadFault
  let pause: OwnerControlTransport.FetchPause?
  init(base: CloudAttachmentTransferCoordinator, fault: CheckedOwnerReadFault,
       pause: OwnerControlTransport.FetchPause?) { self.base = base; self.fault = fault; self.pause = pause }
  func prepare(attachmentID: UUID, for use: SyncedAttachmentUse) async throws -> URL {
    try await base.prepare(attachmentID: attachmentID, for: use)
  }
  func clearDownloads() async throws { try await base.clearDownloads() }
  func transferStates() async throws -> [UUID: CloudAttachmentTransferState] {
    fault.enteredStateRead()
    let actual = try await base.transferStates()
    try fault.returnedActualStates()
    try await pause?.suspend()
    return actual
  }
}

@MainActor
private final class CheckedOwnerReadFixture {
  struct Work {
    let task: Task<Void, Never>
    let finished: OwnerNormalScheduleSignal
  }
  let root: URL
  let persistence: SwiftDataSyncModePersistence
  let handler: AppleAccountCacheCoordinatorHandler
  let lifecycle: SnipSnapICloudSyncLifecycle
  let recordTransport: FakeCloudRecordTransport
  let fault: CheckedOwnerReadFault
  let readPause: OwnerControlTransport.FetchPause
  let writerPause: OwnerControlTransport.FetchPause
  let queued: OwnerNormalScheduleSignal
  private var work: [Work] = []
  private var retainedAfterFailedJoin: CheckedOwnerReadFixture?

  init(root: URL, persistence: SwiftDataSyncModePersistence, handler: AppleAccountCacheCoordinatorHandler,
       lifecycle: SnipSnapICloudSyncLifecycle, recordTransport: FakeCloudRecordTransport,
       fault: CheckedOwnerReadFault, readPause: OwnerControlTransport.FetchPause,
       writerPause: OwnerControlTransport.FetchPause, queued: OwnerNormalScheduleSignal) {
    self.root = root; self.persistence = persistence; self.handler = handler; self.fault = fault
    self.lifecycle = lifecycle; self.recordTransport = recordTransport
    self.readPause = readPause; self.writerPause = writerPause; self.queued = queued
  }
  static func make(holdRead: Bool = false) async throws -> CheckedOwnerReadFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CheckedOwnerRead-\(UUID())")
    NSLog("CheckedOwnerRead retained store root: %@", root.path)
    let fault = CheckedOwnerReadFault()
    let readPause = OwnerControlTransport.FetchPause()
    let writerPause = OwnerControlTransport.FetchPause()
    let queued = OwnerNormalScheduleSignal()
    let persistence = try SwiftDataSyncModePersistence(rootURL: root, manifestWriter: fault.write,
      writeHook: { point in
        if point == .afterRevisionReserved, fault.holdWriter { try await writerPause.suspend() }
      }, diagnostics: AppDiagnosticRecorder { event in
        if event.operation == "library.write_admission", event.outcome == .started,
           event.writeReason == .syncBusy { queued.fire() }
      })
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account-a")
    let account = OwnerAccountSource()
    let server = FakeCloudServer()
    let coordinator = ICloudSyncModeCoordinator(persistence: persistence, namespace: namespace,
      textZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone,
      makeTransport: { FakeCloudRecordTransport(server: server, namespace: namespace) }, accountStateSource: account)
    _ = try await coordinator.enableOrRetry()
    let control = FakeCloudControlTransport(server: server)
    await control.seedControl(descriptor)
    let recordTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
    let lifecycle = SnipSnapICloudSyncLifecycle(rootURL: root, sourceLibrary: try await persistence.activeLibrary(),
      syncModeStore: SnipSyncModeStore(persistence), cloudScope: "private", accountLineage: "account-a",
      accountStateSource: account, ownerName: "owner", controlTransport: control,
      makeRecordTransport: { _ in recordTransport },
      makeDescriptor: { descriptor })
    let handler = lifecycle.makeAccountCacheHandler(operationGate: AsyncOperationGate(),
      makeAttachmentCoordinator: { library, namespace, descriptor in
        CheckedOwnerAttachmentReader(base: CloudAttachmentTransferCoordinator(library: library, namespace: namespace,
          payloadZone: descriptor.payloadZone, transport: FakeCloudRecordTransport(server: server, namespace: namespace),
          maximumCacheBytes: 0), fault: fault, pause: holdRead ? readPause : nil)
      })
    return CheckedOwnerReadFixture(root: root, persistence: persistence, handler: handler,
      lifecycle: lifecycle, recordTransport: recordTransport, fault: fault,
      readPause: readPause, writerPause: writerPause, queued: queued)
  }
  func start(_ operation: @escaping @MainActor () async -> Void) -> Work {
    let finished = OwnerNormalScheduleSignal()
    let task = Task { await operation(); finished.fire() }
    let owned = Work(task: task, finished: finished)
    work.append(owned)
    return owned
  }
  func ready(_ expectation: XCTestExpectation, _ stage: String) async -> Bool {
    let ready = await XCTWaiter.fulfillment(of: [expectation], timeout: 30) == .completed
    XCTAssertTrue(ready, "Checked read setup failed: \(stage)")
    return ready
  }
  func ready(_ signal: OwnerNormalScheduleSignal, _ stage: String) async -> Bool {
    let ready = await signal.wait(for: .seconds(30))
    XCTAssertTrue(ready, "Checked read setup failed: \(stage)")
    return ready
  }
  func complete(_ owned: Work, _ stage: String) async -> Bool {
    let completed = await owned.finished.wait(for: .seconds(2))
    XCTAssertTrue(completed, "Checked read prompt completion failed: \(stage)")
    return completed
  }
  func cleanUp() async {
    readPause.release(); writerPause.release()
    work.forEach { $0.task.cancel() }
    let deadline = ContinuousClock.now + .seconds(30)
    var joined = true
    for owned in work {
      let settled = await owned.finished.wait(for: ContinuousClock.now.duration(to: deadline))
      XCTAssertTrue(settled, "Checked read cleanup failed to join its caller")
      joined = joined && settled
      if settled { await owned.task.value }
    }
    if joined { work.removeAll() }
    else { retainedAfterFailedJoin = self; NSLog("CheckedOwnerRead retained live work/root: %@", root.path) }
  }
}

extension CloudAppAccountOwnershipTests {
  @MainActor
  func testCancelledQueuedWriterCannotRevokeTheReleasedReadOrBlockLaterLocalWork() async throws {
    let fixture = try await CheckedOwnerReadFixture.make(holdRead: true)
    let library = try await fixture.persistence.activeLibrary()
    var response: Result<SyncedAttachmentReadObservation, any Error>?
    var cancelled = false
    let read = fixture.start {
      do { response = .success(try await fixture.handler.checkedAttachmentStates()) }
      catch { response = .failure(error) }
    }
    if await fixture.ready(fixture.readPause.entered, "actual checked attachment owner") {
      let writer = fixture.start {
        do { try await Self.add("cancelled queued text", to: library); XCTFail("Cancelled writer committed") }
        catch is CancellationError { cancelled = true }
        catch { XCTFail("Queued cancellation changed error identity: \(error)") }
      }
      if await fixture.ready(fixture.queued, "actual queued write") {
        writer.task.cancel()
        if await fixture.complete(writer, "cancelled queued caller before read release") {
          XCTAssertTrue(cancelled)
          XCTAssertTrue(fixture.readPause.isHeld)
          XCTAssertFalse(read.finished.isSet)
          fixture.readPause.release()
          if await fixture.complete(read, "read release after queue cancellation") {
            do {
              let observed = try XCTUnwrap(response).get()
              XCTAssertEqual(observed.states, [:])
              let closing = try XCTUnwrap(observed.publication).beginApplication()
              closing.finish()
              try await Self.add("local text after cancelled queue", to: library)
              let durable = try await library.checkedSnapshot(sortedBy: .manual)
              XCTAssertEqual(durable.snips.map(\.content), ["local text after cancelled queue"])
            } catch { XCTFail("Cancelled queue must preserve the real read and local availability: \(error)") }
          }
        }
      }
    }
    await fixture.cleanUp()
  }

  @MainActor
  func testCancellationBeforeCheckedHandlerAdmissionRunsNoAttachmentRead() async throws {
    let fixture = try await CheckedOwnerReadFixture.make()
    var cancelled = false
    let caller = fixture.start {
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        _ = try await fixture.handler.checkedAttachmentStates()
        XCTFail("A cancelled caller cannot enter the checked read")
      } catch is CancellationError { cancelled = true }
      catch { XCTFail("Admission cancellation changed error identity: \(error)") }
    }
    if await fixture.complete(caller, "cancellation before actual admission") {
      XCTAssertTrue(cancelled)
      XCTAssertEqual(fixture.fault.stateReadCount, 0)
      do {
        let library = try await fixture.persistence.activeLibrary()
        try await Self.add("available after pre-admission cancellation", to: library)
        let durable = try await library.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(durable.snips.map(\.content), ["available after pre-admission cancellation"])
      } catch { XCTFail("Pre-admission cancellation cannot reserve local content: \(error)") }
    }
    await fixture.cleanUp()
  }
}

extension CloudAppAccountOwnershipTests {
  @MainActor
  func testRetiringTheActualSourceRejectsPreparedCurrentStatusBeforeInstallation() async throws {
    let fixture = try await CheckedOwnerReadFixture.make()
    _ = try await fixture.lifecycle.retrySynchronization()
    let source = try await fixture.handler.checkedAttachmentStates().source
    let settings = SyncedContentSettingsModel(mode: .iCloudSync)
    let start = settings.recordSyncStarted()
    let current = try await fixture.handler.checkedCurrentSyncStatus(for: source)
    let prepared = try XCTUnwrap(settings.prepareCurrentState(current, for: start))
    try await fixture.persistence.activateEmptyCollection(namespace: nil)
    let actualReplacement = try await fixture.persistence.snapshot().activeStore
    XCTAssertNotEqual(actualReplacement.id, source.storeID)
    var installed = false
    do {
      let closing = try XCTUnwrap(current.publication).beginApplication()
      installed = settings.installPreparedCurrentState(prepared, within: closing)
      closing.finish()
      XCTFail("The actual source replacement must retire this publication before its Settings install")
    } catch SnipLibraryReadPublicationError.revoked {}
    XCTAssertFalse(installed)
    XCTAssertEqual(settings.mode, .iCloudSync)
    XCTAssertEqual(settings.state, .syncing)
    XCTAssertEqual(settings.detail, "Checking for changes…")
    let managed = try await fixture.persistence.activeLibrary()
    try await Self.add("replacement remains writable", to: managed)
    let durable = try await managed.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(durable.snips.map(\.content), ["replacement remains writable"])
  }
}

extension CloudAppAccountOwnershipTests {
  @MainActor
  func testEnableTargetDoesNotTurnActualModeAttentionIntoSuccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("EnableTargetAttention-\(UUID())")
    NSLog("EnableTargetAttention retained store root: %@", root.path)
    let source = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("source/snips.store"))
    let syncRoot = root.appendingPathComponent("mode")
    let persistence = try SwiftDataSyncModePersistence(rootURL: syncRoot)
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let server = FakeCloudServer()
    let lifecycle = SnipSnapICloudSyncLifecycle(rootURL: syncRoot, sourceLibrary: source,
      syncModeStore: SnipSyncModeStore(persistence), cloudScope: "private", accountLineage: "account-a",
      accountStateSource: OwnerAccountSource(), ownerName: "owner",
      controlTransport: FakeCloudControlTransport(server: server),
      makeRecordTransport: { FakeCloudRecordTransport(server: server, namespace: $0.namespace) },
      makeDescriptor: { descriptor })
    let bootstrap = try await lifecycle.enableICloudSync()
    XCTAssertEqual(bootstrap, .enabled)

    let original = try await persistence.snapshot().activeStore
    let originalNamespace = try XCTUnwrap(original.namespace)
    let initial = try await lifecycle.enableICloudSyncWithTarget()
    XCTAssertEqual(initial.outcome, .enabled)
    XCTAssertEqual(initial.target?.application.source.storeID, original.id)
    XCTAssertEqual(initial.target?.namespace, originalNamespace)
    try await persistence.recordAttention(.terminalFetchFailure)

    do {
      _ = try await lifecycle.enableICloudSyncWithTarget()
      XCTFail("An actual original target cannot suppress a live needs-attention result")
    } catch CloudCollectionError.syncNeedsAttention {}

    XCTAssertTrue(PendingICloudSyncEnable.needsAttention(at: syncRoot))
    let after = try await persistence.snapshot()
    XCTAssertEqual(after.activeStore.id, original.id)
    XCTAssertEqual(after.activeStore.namespace, originalNamespace)
    XCTAssertEqual(after.attentionReason, .terminalFetchFailure)
  }
}
