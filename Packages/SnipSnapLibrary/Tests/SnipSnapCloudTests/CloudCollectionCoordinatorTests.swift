import Foundation
import CloudKit
import SnipSnapCore
import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

final class CloudCollectionCoordinatorTests: XCTestCase {
  func testFreshDescriptorsUseRandomGenerationsAndDistinctZoneNames() {
    let first = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let second = CloudCollectionDescriptor.fresh(ownerName: "owner")

    XCTAssertNotEqual(first.generation, second.generation)
    XCTAssertTrue(first.zones.isDisjoint(with: second.zones))
    XCTAssertEqual(Set(first.zones.map(\.ownerName)), ["owner"])
  }

  func testControlRecordCodecRoundTripsGenerationAndBothActiveZones() throws {
    let value = descriptor(
      generation: "12121212-1212-1212-1212-121212121212",
      metadata: "codec-metadata",
      payload: "codec-payload"
    )
    let controlID = CloudRecordID(
      zone: CloudZoneID(name: "control", ownerName: "owner"),
      name: "active-collection"
    )

    let record = try CloudCollectionControlCodec.record(
      value,
      id: controlID,
      replacing: nil
    )
    let decoded = try CloudCollectionControlCodec.decode(record, expectedID: controlID)

    XCTAssertEqual(decoded.descriptor, value)
    XCTAssertFalse(decoded.version.isEmpty)
    XCTAssertEqual(record.recordType, "SnipSnapCollectionControl")
    XCTAssertEqual(record["schemaVersion"] as? Int64, 1)
    XCTAssertNil(record["text"])
  }

  func testResetCrashPointsConvergeWithoutSendingTheReplacedGeneration() async throws {
    for point in [
      CloudCollectionStep.freshZonesCreated,
      .controlPublished,
      .localCollectionAdopted,
      .oldZonesDeleted,
    ] {
      let old = descriptor(
        generation: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
        metadata: "crash-old-metadata-\(point)",
        payload: "crash-old-payload-\(point)"
      )
      let fresh = descriptor(
        generation: "ffffffff-ffff-ffff-ffff-ffffffffffff",
        metadata: "crash-fresh-metadata-\(point)",
        payload: "crash-fresh-payload-\(point)"
      )
      let server = FakeCloudServer()
      let transport = FakeCloudControlTransport(server: server)
      await transport.seedControl(old)
      let local = TestCloudCollectionLocalStore(
        active: namespace(old), hasSyncedBefore: true
      )
      let driver = TestCloudCollectionSyncDriver()
      let interrupted = CloudCollectionCoordinator(
        cloudScope: "private",
        accountLineage: "account-a",
        ownerName: "owner",
        localStore: local,
        transport: transport,
        syncDriver: driver,
        makeDescriptor: { fresh },
        afterStep: { step in
          if step == point { throw TestCollectionCrash.injected(point) }
        }
      )
      do {
        _ = try await interrupted.deleteSyncedContent()
        XCTFail("Expected the injected reset interruption at \(point)")
      } catch {
        XCTAssertEqual(error as? TestCollectionCrash, .injected(point))
      }

      let resumed = CloudCollectionCoordinator(
        cloudScope: "private",
        accountLineage: "account-a",
        ownerName: "owner",
        localStore: local,
        transport: transport,
        syncDriver: driver,
        makeDescriptor: { fresh }
      )
      _ = try await resumed.synchronize()

      let control = await server.controlDescriptor()
      let state = await local.state()
      let events = await driver.events()
      let hasOldMetadata = await server.hasZone(old.metadataZone)
      let hasFreshMetadata = await server.hasZone(fresh.metadataZone)
      if point == .freshZonesCreated {
        XCTAssertEqual(control, old)
        XCTAssertTrue(hasOldMetadata)
        XCTAssertFalse(hasFreshMetadata)
      } else {
        XCTAssertEqual(control, fresh)
        XCTAssertEqual(state.activeNamespace, namespace(fresh))
        XCTAssertFalse(events.contains(.sent(namespace(old))))
        XCTAssertFalse(hasOldMetadata)
        XCTAssertTrue(hasFreshMetadata)
      }
      XCTAssertTrue(state.cleanupZones.isEmpty)
    }
  }

  func testRepeatedRecoveryAfterLateResetCrashIsIdempotent() async throws {
    let old = descriptor(
      generation: "abababab-abab-abab-abab-abababababab",
      metadata: "repeat-old-metadata",
      payload: "repeat-old-payload"
    )
    let fresh = descriptor(
      generation: "cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd",
      metadata: "repeat-fresh-metadata",
      payload: "repeat-fresh-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    let local = TestCloudCollectionLocalStore(
      active: namespace(old), hasSyncedBefore: true
    )
    let driver = TestCloudCollectionSyncDriver()
    let interrupted = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: driver,
      makeDescriptor: { fresh },
      afterStep: { step in
        if step == .oldZonesDeleted { throw TestCollectionCrash.injected(step) }
      }
    )
    do {
      _ = try await interrupted.deleteSyncedContent()
      XCTFail("Expected the injected reset interruption")
    } catch {
      XCTAssertEqual(error as? TestCollectionCrash, .injected(.oldZonesDeleted))
    }
    let resumed = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: driver,
      makeDescriptor: { fresh }
    )

    _ = try await resumed.synchronize()
    _ = try await resumed.synchronize()

    let state = await local.state()
    let events = await driver.events()
    let control = await server.controlDescriptor()
    let hasOldMetadata = await server.hasZone(old.metadataZone)
    let hasOldPayload = await server.hasZone(old.payloadZone)
    XCTAssertEqual(control, fresh)
    XCTAssertTrue(state.cleanupZones.isEmpty)
    XCTAssertFalse(hasOldMetadata)
    XCTAssertFalse(hasOldPayload)
    XCTAssertFalse(events.contains(.sent(namespace(old))))
  }

  func testDurableLocalAdapterKeepsOldDataAndReopensOnFreshEmptyCollection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudCollectionLocalStore-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = descriptor(
      generation: "cccccccc-cccc-cccc-cccc-cccccccccccc",
      metadata: "durable-old-metadata",
      payload: "durable-old-payload"
    )
    let fresh = descriptor(
      generation: "dddddddd-dddd-dddd-dddd-dddddddddddd",
      metadata: "durable-fresh-metadata",
      payload: "durable-fresh-payload"
    )
    let mode = try SwiftDataSyncModePersistence(rootURL: root)
    try await mode.activateEmptyCollection(namespace: binding(old))
    let oldStore = try await mode.snapshot().activeStore
    let oldLibrary = try await mode.libraryForTransition(storeID: oldStore.id)
    let attachmentSource = root.appendingPathComponent("recovery-note.txt")
    let attachmentBytes = Data("keep this attachment".utf8)
    try attachmentBytes.write(to: attachmentSource)
    _ = try await oldLibrary.perform(
      .add(
        content: "preserved local copy",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [attachmentSource],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    let local = try SwiftDataCloudCollectionLocalStore(rootURL: root, persistence: mode)

    try await local.adopt(namespace(fresh))
    try await local.stageCleanup(old.zones)

    let freshStore = try await mode.snapshot().activeStore
    let freshLibrary = try await mode.libraryForTransition(storeID: freshStore.id)
    let freshSnapshot = await freshLibrary.snapshot(sortedBy: .manual)
    let preservedSnapshot = await oldLibrary.snapshot(sortedBy: .manual)
    try await mode.cleanupRetiredStores()
    let recoveryStoreURL = root
      .appendingPathComponent(oldStore.relativeRoot, isDirectory: true)
      .appendingPathComponent("snips.store", isDirectory: false)
    let recoveryLibrary = try SwiftDataSnipLibrary(storeURL: recoveryStoreURL)
    let recoveredSnapshot = await recoveryLibrary.snapshot(sortedBy: .manual)
    let recoveredAttachmentID = try XCTUnwrap(
      recoveredSnapshot.snips.first?.attachments.first?.id
    )
    let recoveredAttachmentURL = try XCTUnwrap(
      recoveredSnapshot.attachmentURLs[recoveredAttachmentID]
    )
    let reopenedMode = try SwiftDataSyncModePersistence(rootURL: root)
    let reopened = try SwiftDataCloudCollectionLocalStore(
      rootURL: root,
      persistence: reopenedMode
    )
    let reopenedState = try await reopened.state()

    XCTAssertNotEqual(freshStore.id, oldStore.id)
    XCTAssertTrue(freshSnapshot.snips.isEmpty)
    XCTAssertEqual(preservedSnapshot.snips.map(\.content), ["preserved local copy"])
    XCTAssertEqual(recoveredSnapshot.snips.map(\.content), ["preserved local copy"])
    XCTAssertEqual(try Data(contentsOf: recoveredAttachmentURL), attachmentBytes)
    XCTAssertEqual(reopenedState.activeNamespace, namespace(fresh))
    XCTAssertEqual(reopenedState.cleanupZones, old.zones)
    XCTAssertTrue(reopenedState.hasSyncedBefore)
  }

  func testConcurrentResetsUseControlVersionAndLoserCleansItsUnusedZones() async throws {
    let old = descriptor(
      generation: "99999999-9999-9999-9999-999999999999",
      metadata: "concurrent-old-metadata",
      payload: "concurrent-old-payload"
    )
    let firstFresh = descriptor(
      generation: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      metadata: "concurrent-first-metadata",
      payload: "concurrent-first-payload"
    )
    let winningFresh = descriptor(
      generation: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      metadata: "concurrent-winner-metadata",
      payload: "concurrent-winner-payload"
    )
    let server = FakeCloudServer()
    let firstTransport = FakeCloudControlTransport(server: server)
    let secondTransport = FakeCloudControlTransport(server: server)
    await firstTransport.seedControl(old)
    await firstTransport.pauseNextControlSave()
    let firstLocal = TestCloudCollectionLocalStore(
      active: namespace(old), hasSyncedBefore: true
    )
    let secondLocal = TestCloudCollectionLocalStore(
      active: namespace(old), hasSyncedBefore: true
    )
    let first = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: firstLocal,
      transport: firstTransport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { firstFresh }
    )
    let second = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: secondLocal,
      transport: secondTransport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { winningFresh }
    )

    let firstReset = Task { try await first.deleteSyncedContent() }
    await firstTransport.waitUntilControlSavePauses()
    let winningStatus = try await second.deleteSyncedContent()
    await firstTransport.resumeControlSave()
    let losingStatus = try await firstReset.value

    let serverControl = await server.controlDescriptor()
    let loserMetadataRemains = await server.hasZone(firstFresh.metadataZone)
    let loserPayloadRemains = await server.hasZone(firstFresh.payloadZone)
    let winnerMetadataRemains = await server.hasZone(winningFresh.metadataZone)
    let winnerPayloadRemains = await server.hasZone(winningFresh.payloadZone)
    XCTAssertEqual(winningStatus, .deletedSyncedContent(namespace(winningFresh)))
    XCTAssertEqual(losingStatus, .adoptedRemoteCollection(namespace(winningFresh)))
    XCTAssertEqual(serverControl, winningFresh)
    XCTAssertFalse(loserMetadataRemains)
    XCTAssertFalse(loserPayloadRemains)
    XCTAssertTrue(winnerMetadataRemains)
    XCTAssertTrue(winnerPayloadRemains)
  }

  func testPurgedClientRequiresExplicitEnableBeforeItCreatesAnEmptyGeneration() async throws {
    let fresh = descriptor(
      generation: "88888888-8888-8888-8888-888888888888",
      metadata: "enabled-metadata",
      payload: "enabled-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    let local = TestCloudCollectionLocalStore(active: nil, hasSyncedBefore: true)
    let driver = TestCloudCollectionSyncDriver()
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: driver,
      makeDescriptor: { fresh }
    )

    let purged = try await coordinator.synchronize()
    let beforeEnable = await server.controlDescriptor()
    let enabled = try await coordinator.enableSync()

    let events = await driver.events()
    let afterEnable = await server.controlDescriptor()
    XCTAssertEqual(purged, .purged)
    XCTAssertNil(beforeEnable)
    XCTAssertEqual(enabled, .enabled(namespace(fresh)))
    XCTAssertEqual(events, [.fetched(namespace(fresh))])
    XCTAssertEqual(afterEnable, fresh)
  }

  func testKnownClientTreatsMissingControlAsPurgeAndNeverSendsOldCache() async throws {
    let old = descriptor(
      generation: "77777777-7777-7777-7777-777777777777",
      metadata: "purged-metadata",
      payload: "purged-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    await transport.removeControl()
    let local = TestCloudCollectionLocalStore(active: namespace(old), hasSyncedBefore: true)
    let driver = TestCloudCollectionSyncDriver()
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: driver,
      makeDescriptor: { old }
    )

    let status = try await coordinator.synchronize()

    let state = await local.state()
    let events = await driver.events()
    XCTAssertEqual(status, .purged)
    XCTAssertTrue(state.hasSyncedBefore)
    XCTAssertNil(state.activeNamespace)
    XCTAssertTrue(events.isEmpty)
  }

  func testResetBetweenFetchAndSendStopsTheOldGenerationSend() async throws {
    let old = descriptor(
      generation: "55555555-5555-5555-5555-555555555555",
      metadata: "old-race-metadata",
      payload: "old-race-payload"
    )
    let current = descriptor(
      generation: "66666666-6666-6666-6666-666666666666",
      metadata: "current-race-metadata",
      payload: "current-race-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    let local = TestCloudCollectionLocalStore(active: namespace(old), hasSyncedBefore: true)
    let driver = TestCloudCollectionSyncDriver()
    await driver.pauseNextFetch()
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: driver,
      makeDescriptor: { current }
    )

    let syncing = Task { try await coordinator.synchronize() }
    await driver.waitUntilFetchPauses()
    await transport.seedControl(current)
    await driver.resumeFetch()
    let status = try await syncing.value

    let events = await driver.events()
    XCTAssertEqual(status, .adoptedRemoteCollection(namespace(current)))
    XCTAssertEqual(
      events,
      [.fetched(namespace(old)), .fetched(namespace(current))]
    )
    XCTAssertFalse(events.contains(.sent(namespace(old))))
  }

  func testStaleClientAdoptsRemoteGenerationAndBootstrapsWithoutSending() async throws {
    let stale = descriptor(
      generation: "33333333-3333-3333-3333-333333333333",
      metadata: "stale-metadata",
      payload: "stale-payload"
    )
    let current = descriptor(
      generation: "44444444-4444-4444-4444-444444444444",
      metadata: "current-metadata",
      payload: "current-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(current)
    let local = TestCloudCollectionLocalStore(active: namespace(stale), hasSyncedBefore: true)
    let driver = TestCloudCollectionSyncDriver()
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: driver,
      makeDescriptor: { current }
    )

    let status = try await coordinator.synchronize()

    let active = await local.activeNamespace()
    let events = await driver.events()
    XCTAssertEqual(status, .adoptedRemoteCollection(namespace(current)))
    XCTAssertEqual(active, namespace(current))
    XCTAssertEqual(events, [.fetched(namespace(current))])
  }

  func testDeleteSyncedContentPublishesFreshCollectionBeforeRemovingOldZones() async throws {
    let old = descriptor(
      generation: "11111111-1111-1111-1111-111111111111",
      metadata: "old-metadata",
      payload: "old-payload"
    )
    let fresh = descriptor(
      generation: "22222222-2222-2222-2222-222222222222",
      metadata: "fresh-metadata",
      payload: "fresh-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    let local = TestCloudCollectionLocalStore(active: namespace(old), hasSyncedBefore: true)
    let driver = TestCloudCollectionSyncDriver()
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: driver,
      makeDescriptor: { fresh }
    )

    let status = try await coordinator.deleteSyncedContent()

    let activeNamespace = await local.activeNamespace()
    let localEvents = await local.events()
    let driverEvents = await driver.events()
    let transportEvents = await transport.events()
    let storedControl = await server.controlDescriptor()
    let hasOldMetadata = await server.hasZone(old.metadataZone)
    let hasOldPayload = await server.hasZone(old.payloadZone)
    let hasFreshMetadata = await server.hasZone(fresh.metadataZone)
    let hasFreshPayload = await server.hasZone(fresh.payloadZone)

    XCTAssertEqual(status, .deletedSyncedContent(namespace(fresh)))
    XCTAssertEqual(activeNamespace, namespace(fresh))
    XCTAssertEqual(
      localEvents,
      [
        .stagedCleanup(fresh.zones),
        .stagedCleanup(old.zones),
        .adopted(fresh.generation),
        .finishedCleanup(fresh.zones),
        .finishedCleanup(old.zones),
      ]
    )
    XCTAssertEqual(driverEvents, [.fetched(namespace(fresh))])
    XCTAssertEqual(
      transportEvents,
      [
        .fetchedControl,
        .createdZones(fresh.zones),
        .savedControl(fresh.generation),
        .deletedZones(old.zones),
      ]
    )
    XCTAssertEqual(storedControl, fresh)
    XCTAssertFalse(hasOldMetadata)
    XCTAssertFalse(hasOldPayload)
    XCTAssertTrue(hasFreshMetadata)
    XCTAssertTrue(hasFreshPayload)
  }

  private func descriptor(
    generation: String,
    metadata: String,
    payload: String
  ) -> CloudCollectionDescriptor {
    CloudCollectionDescriptor(
      generation: UUID(uuidString: generation)!,
      metadataZone: CloudZoneID(name: metadata, ownerName: "owner"),
      payloadZone: CloudZoneID(name: payload, ownerName: "owner")
    )
  }

  private func namespace(_ descriptor: CloudCollectionDescriptor) -> CloudSyncNamespace {
    descriptor.namespace(cloudScope: "private", accountLineage: "account-a")
  }

  private func binding(_ descriptor: CloudCollectionDescriptor) -> ICloudSyncNamespaceBinding {
    ICloudSyncNamespaceBinding(
      scope: "private",
      accountLineage: "account-a",
      generation: descriptor.generation,
      zones: Set(descriptor.zones.map {
        ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
      })
    )
  }
}

private enum TestCollectionCrash: Error, Equatable {
  case injected(CloudCollectionStep)
}

private actor TestCloudCollectionLocalStore: CloudCollectionLocalStore {
  enum Event: Equatable {
    case stagedCleanup(Set<CloudZoneID>)
    case finishedCleanup(Set<CloudZoneID>)
    case adopted(UUID)
    case purged
  }
  private var active: CloudSyncNamespace?
  private var known: Bool
  private var cleanup: Set<CloudZoneID> = []
  private var log: [Event] = []

  init(active: CloudSyncNamespace?, hasSyncedBefore: Bool) {
    self.active = active
    known = hasSyncedBefore
  }

  func state() -> CloudCollectionLocalState {
    CloudCollectionLocalState(
      hasSyncedBefore: known,
      activeNamespace: active,
      cleanupZones: cleanup
    )
  }

  func stageCleanup(_ zones: Set<CloudZoneID>) {
    cleanup.formUnion(zones)
    log.append(.stagedCleanup(zones))
  }

  func finishCleanup(_ zones: Set<CloudZoneID>) {
    cleanup.subtract(zones)
    log.append(.finishedCleanup(zones))
  }

  func adopt(_ namespace: CloudSyncNamespace) {
    active = namespace
    known = true
    log.append(.adopted(namespace.generation))
  }

  func markPurged() {
    active = nil
    known = true
    log.append(.purged)
  }

  func activeNamespace() -> CloudSyncNamespace? { active }
  func events() -> [Event] { log }
}

private actor TestCloudCollectionSyncDriver: CloudCollectionSyncDriver {
  enum Event: Equatable { case fetched(CloudSyncNamespace), sent(CloudSyncNamespace) }
  private var values: [Event] = []
  private var shouldPauseNextFetch = false
  private var pausedFetch = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var fetchRelease: CheckedContinuation<Void, Never>?

  func fetch(_ context: CloudCollectionSyncContext) async {
    let namespace = context.namespace
    values.append(.fetched(namespace))
    if shouldPauseNextFetch {
      shouldPauseNextFetch = false
      pausedFetch = true
      pauseWaiters.forEach { $0.resume() }
      pauseWaiters = []
      await withCheckedContinuation { fetchRelease = $0 }
    }
  }
  func send(_ context: CloudCollectionSyncContext) {
    values.append(.sent(context.namespace))
  }
  func events() -> [Event] { values }

  func pauseNextFetch() { shouldPauseNextFetch = true }

  func waitUntilFetchPauses() async {
    if pausedFetch { return }
    await withCheckedContinuation { pauseWaiters.append($0) }
  }

  func resumeFetch() {
    fetchRelease?.resume()
    fetchRelease = nil
    pausedFetch = false
  }
}
