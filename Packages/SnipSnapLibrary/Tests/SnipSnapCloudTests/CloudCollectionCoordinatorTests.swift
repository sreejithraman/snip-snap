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

  func testProductionAssemblyUsesOneFixedControlRecord() {
    XCTAssertEqual(
      CloudCollectionAssembly.productionControlID,
      CloudRecordID(
        zone: CloudZoneID(name: "SnipSnapControl", ownerName: CKCurrentUserDefaultName),
        name: "active-collection"
      )
    )
  }

  func testMissingControlRecordOrZoneMeansSyncHasNotBeenEnabled() {
    XCTAssertTrue(CloudKitCollectionControlTransport.isMissingControl(.unknownItem))
    XCTAssertTrue(CloudKitCollectionControlTransport.isMissingControl(.zoneNotFound))
    XCTAssertFalse(CloudKitCollectionControlTransport.isMissingControl(.networkFailure))
  }

  @MainActor
  func testSettingsModelRunsARealFakeServerReset() async throws {
    let old = descriptor(
      generation: "13131313-1313-1313-1313-131313131313",
      metadata: "settings-old-metadata",
      payload: "settings-old-payload"
    )
    let fresh = descriptor(
      generation: "14141414-1414-1414-1414-141414141414",
      metadata: "settings-fresh-metadata",
      payload: "settings-fresh-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    let local = TestCloudCollectionLocalStore(active: namespace(old), hasSyncedBefore: true)
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { fresh }
    )
    let model = CloudCollectionAssembly.settingsModel(for: coordinator)

    await model.deleteSyncedContent()

    let control = await server.controlDescriptor()
    let oldMetadataRemains = await server.hasZone(old.metadataZone)
    XCTAssertEqual(model.state, .deleted)
    XCTAssertEqual(control, fresh)
    XCTAssertFalse(oldMetadataRemains)
  }

  @MainActor
  func testSettingsResetKeepsAppAssemblyOnTheFreshWritableStore() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudCollectionSharedAssembly-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try SwiftDataSnipLibrary(
      storeURL: root.appendingPathComponent("original.store", isDirectory: false)
    )
    let assembly = SnipLibraryAssembly(
      library: original,
      syncModeRootURL: root,
      initializeSyncModeStore: true
    )
    let handle = try XCTUnwrap(assembly.syncModeStore)
    let old = descriptor(
      generation: "17171717-1717-1717-1717-171717171717",
      metadata: "shared-old-metadata",
      payload: "shared-old-payload"
    )
    let fresh = descriptor(
      generation: "18181818-1818-1818-1818-181818181818",
      metadata: "shared-fresh-metadata",
      payload: "shared-fresh-payload"
    )
    try await handle.persistence.activateEmptyCollection(namespace: binding(old))
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    let local = try SwiftDataCloudCollectionLocalStore(
      rootURL: root,
      persistence: handle.persistence
    )
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { fresh }
    )
    let model = CloudCollectionAssembly.settingsModel(for: coordinator)

    await model.deleteSyncedContent()
    _ = try await assembly.library.perform(
      .add(
        content: "written after reset",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 5)
      ),
      sortedBy: .manual
    )

    let appSnapshot = await assembly.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(model.state, .deleted)
    XCTAssertEqual(appSnapshot.snips.map(\.content), ["written after reset"])
  }

  func testCollectionErrorsHaveUserFacingMessages() {
    XCTAssertEqual(
      CloudCollectionError.noActiveCollection.errorDescription,
      "iCloud Sync does not have an active collection."
    )
    XCTAssertEqual(
      CloudCollectionError.invalidDescriptor.errorDescription,
      "The iCloud Sync collection is not valid."
    )
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
    let oldCloudPersistence = CloudFullSyncPersistence(
      library: oldLibrary,
      namespace: namespace(old),
      dataZone: old.metadataZone
    )
    let engineBatch = CloudFetchedBatch(
      id: UUID(),
      items: [],
      zoneEvents: [.fetched(old.metadataZone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace(old),
        serialization: Data([1, 2, 3])
      )
    )
    try await oldCloudPersistence.stage(.fetched(engineBatch))
    try await oldCloudPersistence.applyStaged(engineBatch.id)
    let pendingBatch = CloudFetchedBatch(
      id: UUID(),
      items: [],
      zoneEvents: [.fetched(old.metadataZone)],
      engineState: nil
    )
    try await oldCloudPersistence.stage(.fetched(pendingBatch))
    let seededEngine = try await oldCloudPersistence.loadEngineState()
    let seededBatches = try await oldCloudPersistence.stagedBatches()
    XCTAssertNotNil(seededEngine)
    XCTAssertEqual(seededBatches.count, 1)
    let local = try SwiftDataCloudCollectionLocalStore(rootURL: root, persistence: mode)

    try await local.adopt(namespace(fresh))
    try await local.stageCleanup(old.zones)

    do {
      _ = try await oldLibrary.perform(
        .add(
          content: "must not enter recovery",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inbox.id,
          attachmentURLs: [],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 2)
        ),
        sortedBy: .manual
      )
      XCTFail("Expected the captured old store to reject writes")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .readOnlyRecovery)
    }
    let clearedEngine = try await oldCloudPersistence.loadEngineState()
    let clearedBatches = try await oldCloudPersistence.stagedBatches()
    XCTAssertNil(clearedEngine)
    XCTAssertTrue(clearedBatches.isEmpty)

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
    do {
      _ = try await recoveryLibrary.perform(
        .add(
          content: "must not enter reopened recovery",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inbox.id,
          attachmentURLs: [],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 3)
        ),
        sortedBy: .manual
      )
      XCTFail("Expected the reopened recovery store to reject writes")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .readOnlyRecovery)
    }
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

  func testFailedCollectionActivationKeepsActiveCloudStateAndWritesIntact() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudCollectionFailedActivation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = FailNthArmedManifestWriter()
    let mode = try SwiftDataSyncModePersistence(
      rootURL: root,
      manifestWriter: writer.write
    )
    let old = descriptor(
      generation: "15151515-1515-1515-1515-151515151515",
      metadata: "failed-activation-old-metadata",
      payload: "failed-activation-old-payload"
    )
    let fresh = descriptor(
      generation: "16161616-1616-1616-1616-161616161616",
      metadata: "failed-activation-fresh-metadata",
      payload: "failed-activation-fresh-payload"
    )
    try await mode.activateEmptyCollection(namespace: binding(old))
    let oldStore = try await mode.snapshot().activeStore
    let oldLibrary = try await mode.libraryForTransition(storeID: oldStore.id)
    let oldPersistence = CloudFullSyncPersistence(
      library: oldLibrary,
      namespace: namespace(old),
      dataZone: old.metadataZone
    )
    let batch = CloudFetchedBatch(
      id: UUID(),
      items: [],
      zoneEvents: [.fetched(old.metadataZone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace(old),
        serialization: Data([4, 5, 6])
      )
    )
    try await oldPersistence.stage(.fetched(batch))
    try await oldPersistence.applyStaged(batch.id)
    writer.fail(afterSuccessfulWrites: 1)

    do {
      try await mode.activateEmptyCollection(namespace: binding(fresh))
      XCTFail("Expected the active-pointer manifest write to fail")
    } catch {
      XCTAssertEqual(error as? SyncModePersistenceError, .storageFailure)
    }

    let failedSnapshot = try await mode.snapshot()
    let retainedEngineState = try await oldPersistence.loadEngineState()
    XCTAssertEqual(failedSnapshot.activeStore.namespace, binding(old))
    XCTAssertNotNil(retainedEngineState)
    _ = try await oldLibrary.perform(
      .add(
        content: "active store remains writable",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 4)
      ),
      sortedBy: .manual
    )
  }

  func testReopenFinishesInterruptedRecoveryQuarantine() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudCollectionQuarantineRetry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let failure = RecoveryQuarantineFailure()
    let mode = try SwiftDataSyncModePersistence(
      rootURL: root,
      recoveryQuarantineHook: failure.hit
    )
    let old = descriptor(
      generation: "21212121-2121-2121-2121-212121212121",
      metadata: "quarantine-old-metadata",
      payload: "quarantine-old-payload"
    )
    let fresh = descriptor(
      generation: "22222222-2222-2222-2222-222222222223",
      metadata: "quarantine-fresh-metadata",
      payload: "quarantine-fresh-payload"
    )
    try await mode.activateEmptyCollection(namespace: binding(old))
    let oldStore = try await mode.snapshot().activeStore
    let oldLibrary = try await mode.libraryForTransition(storeID: oldStore.id)
    let oldPersistence = CloudFullSyncPersistence(
      library: oldLibrary,
      namespace: namespace(old),
      dataZone: old.metadataZone
    )
    let batch = CloudFetchedBatch(
      id: UUID(),
      items: [],
      zoneEvents: [.fetched(old.metadataZone)],
      engineState: CloudEngineStateEnvelope(
        namespace: namespace(old),
        serialization: Data([7, 8, 9])
      )
    )
    try await oldPersistence.stage(.fetched(batch))
    try await oldPersistence.applyStaged(batch.id)
    failure.arm()

    try await mode.activateEmptyCollection(namespace: binding(fresh))
    let interruptedEngineState = try await oldPersistence.loadEngineState()
    XCTAssertNotNil(interruptedEngineState)
    do {
      _ = try await oldLibrary.perform(
        .add(
          content: "blocked recovery write",
          origin: .quickEntry,
          source: nil,
          listID: SnipList.inbox.id,
          attachmentURLs: [],
          requestID: UUID(),
          now: Date(timeIntervalSince1970: 6)
        ),
        sortedBy: .manual
      )
      XCTFail("Expected interrupted recovery to stay read-only")
    } catch {
      XCTAssertEqual(error as? SnipLibraryError, .readOnlyRecovery)
    }

    failure.arm()
    let activeLibrary = try await mode.activeLibrary()
    _ = try await activeLibrary.perform(
      .add(
        content: "active writes stay available",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 7)
      ),
      sortedBy: .manual
    )
    let activeSnapshot = await activeLibrary.snapshot(sortedBy: .manual)
    XCTAssertEqual(activeSnapshot.snips.map(\.content), ["active writes stay available"])

    let reopened = try SwiftDataSyncModePersistence(rootURL: root)
    let reopenedLibrary = try await reopened.activeLibrary()
    _ = await reopenedLibrary.snapshot(sortedBy: .manual)

    let reopenedEngineState = try await oldPersistence.loadEngineState()
    XCTAssertNil(reopenedEngineState)
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

  func testResetConflictCleansOldZonesWhenWinnerStopsAfterPublishingControl() async throws {
    let old = descriptor(
      generation: "91919191-9191-9191-9191-919191919191",
      metadata: "interleaved-old-metadata",
      payload: "interleaved-old-payload"
    )
    let losingFresh = descriptor(
      generation: "92929292-9292-9292-9292-929292929292",
      metadata: "interleaved-loser-metadata",
      payload: "interleaved-loser-payload"
    )
    let winningFresh = descriptor(
      generation: "93939393-9393-9393-9393-939393939393",
      metadata: "interleaved-winner-metadata",
      payload: "interleaved-winner-payload"
    )
    let server = FakeCloudServer()
    let losingTransport = FakeCloudControlTransport(server: server)
    let winningTransport = FakeCloudControlTransport(server: server)
    await losingTransport.seedControl(old)
    await losingTransport.pauseNextControlSave()
    let losingLocal = TestCloudCollectionLocalStore(
      active: namespace(old), hasSyncedBefore: true
    )
    let winnerLocal = TestCloudCollectionLocalStore(
      active: namespace(old), hasSyncedBefore: true
    )
    let loser = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: losingLocal,
      transport: losingTransport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { losingFresh }
    )
    let winner = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: winnerLocal,
      transport: winningTransport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { winningFresh },
      afterStep: { step in
        if step == .controlPublished { throw TestCollectionCrash.injected(step) }
      }
    )

    let losingReset = Task { try await loser.deleteSyncedContent() }
    await losingTransport.waitUntilControlSavePauses()
    do {
      _ = try await winner.deleteSyncedContent()
      XCTFail("Expected the winner to stop after publishing control")
    } catch {
      XCTAssertEqual(error as? TestCollectionCrash, .injected(.controlPublished))
    }
    let oldZoneExistsBeforeLoserResumes = await server.hasZone(old.metadataZone)
    XCTAssertTrue(oldZoneExistsBeforeLoserResumes)
    await losingTransport.resumeControlSave()

    let status = try await losingReset.value
    let cleanup = await losingLocal.state().cleanupZones
    let oldMetadataRemains = await server.hasZone(old.metadataZone)
    let oldPayloadRemains = await server.hasZone(old.payloadZone)
    let loserMetadataRemains = await server.hasZone(losingFresh.metadataZone)
    let loserPayloadRemains = await server.hasZone(losingFresh.payloadZone)
    let winnerMetadataRemains = await server.hasZone(winningFresh.metadataZone)
    let winnerPayloadRemains = await server.hasZone(winningFresh.payloadZone)

    XCTAssertEqual(status, .adoptedRemoteCollection(namespace(winningFresh)))
    XCTAssertFalse(oldMetadataRemains)
    XCTAssertFalse(oldPayloadRemains)
    XCTAssertFalse(loserMetadataRemains)
    XCTAssertFalse(loserPayloadRemains)
    XCTAssertTrue(winnerMetadataRemains)
    XCTAssertTrue(winnerPayloadRemains)
    XCTAssertTrue(cleanup.isEmpty)
  }

  func testSynchronizeCannotDeleteFreshZonesWhileResetIsPublishingControl() async throws {
    let old = descriptor(
      generation: "19191919-1919-1919-1919-191919191919",
      metadata: "exclusive-old-metadata",
      payload: "exclusive-old-payload"
    )
    let fresh = descriptor(
      generation: "20202020-2020-2020-2020-202020202020",
      metadata: "exclusive-fresh-metadata",
      payload: "exclusive-fresh-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    await transport.pauseNextControlSave()
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
    let session = SnipSnapCloudSyncSession(
      synchronize: {
        _ = try await coordinator.synchronize()
        return .contentUpdated
      },
      enable: { _ = try await coordinator.enableSync() },
      delete: { _ = try await coordinator.deleteSyncedContent() },
      activeLibrary: { throw SyncModePersistenceError.missingStore }
    )
    let reset = Task { try await session.deleteSyncedContent() }
    await transport.waitUntilControlSavePauses()

    do {
      _ = try await session.synchronize()
      XCTFail("Expected concurrent collection work to be rejected")
    } catch {
      XCTAssertEqual(error as? CloudCollectionError, .operationInProgress)
    }
    let freshMetadataStillExists = await server.hasZone(fresh.metadataZone)
    let freshPayloadStillExists = await server.hasZone(fresh.payloadZone)
    XCTAssertTrue(freshMetadataStillExists)
    XCTAssertTrue(freshPayloadStillExists)
    let eventsDuringReset = await driver.events()
    XCTAssertFalse(eventsDuringReset.contains(.sent(namespace(old))))

    await transport.resumeControlSave()
    _ = try await reset.value
  }

  func testLongLivedSyncSessionUsesTheGenerationGatedNormalSendPath() async throws {
    let active = descriptor(
      generation: "23232323-2323-2323-2323-232323232323",
      metadata: "session-active-metadata",
      payload: "session-active-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(active)
    let local = TestCloudCollectionLocalStore(
      active: namespace(active), hasSyncedBefore: true
    )
    let driver = TestCloudCollectionSyncDriver()
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: driver,
      makeDescriptor: { active }
    )
    let session = SnipSnapCloudSyncSession(
      synchronize: {
        _ = try await coordinator.synchronize()
        return .contentUpdated
      },
      enable: { _ = try await coordinator.enableSync() },
      delete: { _ = try await coordinator.deleteSyncedContent() },
      activeLibrary: { throw SyncModePersistenceError.missingStore }
    )

    let result = try await session.synchronize()

    XCTAssertEqual(result, .contentUpdated)
    let driverEvents = await driver.events()
    let transportEvents = await transport.events()
    XCTAssertEqual(
      driverEvents,
      [.fetched(namespace(active)), .sent(namespace(active))]
    )
    XCTAssertEqual(
      transportEvents.filter { $0 == .fetchedControl }.count,
      2
    )
  }

  func testExplicitEnableThenForegroundSyncUsesTheSameGenerationGatedSession() async throws {
    let active = descriptor(
      generation: "34343434-3434-3434-3434-343434343434",
      metadata: "enabled-session-metadata",
      payload: "enabled-session-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    let local = TestCloudCollectionLocalStore(active: nil, hasSyncedBefore: false)
    let driver = TestCloudCollectionSyncDriver()
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: driver,
      makeDescriptor: { active }
    )
    let session = SnipSnapCloudSyncSession(
      synchronize: {
        _ = try await coordinator.synchronize()
        return .contentUpdated
      },
      enable: { _ = try await coordinator.enableSync() },
      delete: { _ = try await coordinator.deleteSyncedContent() },
      activeLibrary: { throw SyncModePersistenceError.missingStore }
    )

    try await session.enableSync()
    let foregroundResult = try await session.synchronize()

    let driverEvents = await driver.events()
    let transportEvents = await transport.events()
    XCTAssertEqual(foregroundResult, .contentUpdated)
    XCTAssertEqual(
      driverEvents,
      [
        .fetched(namespace(active)),
        .fetched(namespace(active)),
        .sent(namespace(active)),
      ]
    )
    XCTAssertEqual(
      transportEvents.filter { $0 == .fetchedControl }.count,
      3
    )
    XCTAssertTrue(transportEvents.contains(.savedControl(active.generation)))
  }

  func testConflictCleanupFailureStaysPendingAndLaterSyncFinishesIt() async throws {
    let old = descriptor(
      generation: "24242424-2424-2424-2424-242424242424",
      metadata: "retry-old-metadata",
      payload: "retry-old-payload"
    )
    let unused = descriptor(
      generation: "25252525-2525-2525-2525-252525252525",
      metadata: "retry-unused-metadata",
      payload: "retry-unused-payload"
    )
    let winning = descriptor(
      generation: "26262626-2626-2626-2626-262626262626",
      metadata: "retry-winning-metadata",
      payload: "retry-winning-payload"
    )
    let server = FakeCloudServer()
    let losingTransport = FakeCloudControlTransport(server: server)
    let winningTransport = FakeCloudControlTransport(server: server)
    await losingTransport.seedControl(old)
    await losingTransport.pauseNextControlSave()
    let losingLocal = TestCloudCollectionLocalStore(
      active: namespace(old), hasSyncedBefore: true
    )
    let winnerLocal = TestCloudCollectionLocalStore(
      active: namespace(old), hasSyncedBefore: true
    )
    let loser = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: losingLocal,
      transport: losingTransport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { unused }
    )
    let winner = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: winnerLocal,
      transport: winningTransport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { winning }
    )

    let losingReset = Task { try await loser.deleteSyncedContent() }
    await losingTransport.waitUntilControlSavePauses()
    _ = try await winner.deleteSyncedContent()
    await losingTransport.failNextZoneDelete()
    await losingTransport.resumeControlSave()
    let status = try await losingReset.value
    let pendingAfterFailure = await losingLocal.state().cleanupZones
    XCTAssertEqual(status, .adoptedRemoteCollection(namespace(winning)))
    XCTAssertFalse(pendingAfterFailure.isEmpty)

    _ = try await loser.synchronize()

    let pendingAfterRetry = await losingLocal.state().cleanupZones
    let unusedMetadataExists = await server.hasZone(unused.metadataZone)
    let unusedPayloadExists = await server.hasZone(unused.payloadZone)
    let winningMetadataExists = await server.hasZone(winning.metadataZone)
    let winningPayloadExists = await server.hasZone(winning.payloadZone)
    XCTAssertTrue(pendingAfterRetry.isEmpty)
    XCTAssertFalse(unusedMetadataExists)
    XCTAssertFalse(unusedPayloadExists)
    XCTAssertTrue(winningMetadataExists)
    XCTAssertTrue(winningPayloadExists)
  }

  func testAcceptedResetReturnsFreshCollectionWhenOldZoneCleanupMustRetry() async throws {
    let old = descriptor(
      generation: "30303030-3030-3030-3030-303030303030",
      metadata: "post-adopt-old-metadata",
      payload: "post-adopt-old-payload"
    )
    let fresh = descriptor(
      generation: "31313131-3131-3131-3131-313131313131",
      metadata: "post-adopt-fresh-metadata",
      payload: "post-adopt-fresh-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    await transport.failNextZoneDelete()
    let local = TestCloudCollectionLocalStore(
      active: namespace(old), hasSyncedBefore: true
    )
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { fresh }
    )

    let status = try await coordinator.deleteSyncedContent()
    let activeNamespace = await local.activeNamespace()
    let pendingAfterReset = await local.state().cleanupZones
    let oldMetadataExists = await server.hasZone(old.metadataZone)

    XCTAssertEqual(status, .deletedSyncedContent(namespace(fresh)))
    XCTAssertEqual(activeNamespace, namespace(fresh))
    XCTAssertEqual(pendingAfterReset, old.zones)
    XCTAssertTrue(oldMetadataExists)

    _ = try await coordinator.synchronize()
    let pendingAfterSync = await local.state().cleanupZones
    let oldMetadataRemains = await server.hasZone(old.metadataZone)
    let oldPayloadRemains = await server.hasZone(old.payloadZone)

    XCTAssertTrue(pendingAfterSync.isEmpty)
    XCTAssertFalse(oldMetadataRemains)
    XCTAssertFalse(oldPayloadRemains)
  }

  func testEnableSyncCleansZonesLeftByAnEarlierAttempt() async throws {
    let unused = descriptor(
      generation: "32323232-3232-3232-3232-323232323232",
      metadata: "enable-unused-metadata",
      payload: "enable-unused-payload"
    )
    let active = descriptor(
      generation: "33333333-3333-3333-3333-333333333334",
      metadata: "enable-active-metadata",
      payload: "enable-active-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    let local = TestCloudCollectionLocalStore(active: nil, hasSyncedBefore: false)
    await local.stageCleanup(unused.zones)
    await server.createZones(unused.zones)
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { active }
    )

    let status = try await coordinator.enableSync()
    let cleanup = await local.state().cleanupZones
    let unusedMetadataRemains = await server.hasZone(unused.metadataZone)
    let unusedPayloadRemains = await server.hasZone(unused.payloadZone)
    let activeMetadataExists = await server.hasZone(active.metadataZone)
    let activePayloadExists = await server.hasZone(active.payloadZone)

    XCTAssertEqual(status, .enabled(namespace(active)))
    XCTAssertTrue(cleanup.isEmpty)
    XCTAssertFalse(unusedMetadataRemains)
    XCTAssertFalse(unusedPayloadRemains)
    XCTAssertTrue(activeMetadataExists)
    XCTAssertTrue(activePayloadExists)
  }

  func testReservedControlZoneIsRejectedAndNeverDeleted() async throws {
    let controlZone = CloudZoneID(name: "control", ownerName: "owner")
    let invalid = CloudCollectionDescriptor(
      generation: UUID(),
      metadataZone: controlZone,
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner")
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(invalid)
    let local = TestCloudCollectionLocalStore(active: nil, hasSyncedBefore: true)
    await local.stageCleanup([controlZone])
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { invalid },
      reservedZones: [controlZone]
    )

    do {
      _ = try await coordinator.synchronize()
      XCTFail("Expected a control-zone descriptor to be rejected")
    } catch {
      XCTAssertEqual(error as? CloudCollectionError, .invalidDescriptor)
    }

    let controlZoneExists = await server.hasZone(controlZone)
    let events = await transport.events()
    XCTAssertTrue(controlZoneExists)
    XCTAssertFalse(events.contains(.deletedZones([controlZone])))
  }

  func testConflictWinnerIsValidatedBeforeAdoptionOrCleanup() async throws {
    let controlZone = CloudZoneID(name: "control", ownerName: "owner")
    let old = descriptor(
      generation: "27272727-2727-2727-2727-272727272727",
      metadata: "validated-old-metadata",
      payload: "validated-old-payload"
    )
    let fresh = descriptor(
      generation: "28282828-2828-2828-2828-282828282828",
      metadata: "validated-fresh-metadata",
      payload: "validated-fresh-payload"
    )
    let invalidWinner = CloudCollectionDescriptor(
      generation: UUID(),
      metadataZone: controlZone,
      payloadZone: CloudZoneID(name: "invalid-payload", ownerName: "owner")
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    await transport.pauseNextControlSave()
    let local = TestCloudCollectionLocalStore(
      active: namespace(old), hasSyncedBefore: true
    )
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { fresh },
      reservedZones: [controlZone]
    )

    let reset = Task { try await coordinator.deleteSyncedContent() }
    await transport.waitUntilControlSavePauses()
    await transport.seedControl(invalidWinner)
    await transport.resumeControlSave()
    do {
      _ = try await reset.value
      XCTFail("Expected the conflict winner to be rejected")
    } catch {
      XCTAssertEqual(error as? CloudCollectionError, .invalidDescriptor)
    }

    let active = await local.activeNamespace()
    let events = await transport.events()
    XCTAssertEqual(active, namespace(old))
    XCTAssertFalse(events.contains { event in
      if case .deletedZones = event { return true }
      return false
    })
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

private final class FailNthArmedManifestWriter: @unchecked Sendable {
  enum Failure: Error, Equatable { case injected }

  private let lock = NSLock()
  private var successfulWritesBeforeFailure: Int?

  func fail(afterSuccessfulWrites count: Int) {
    lock.withLock { successfulWritesBeforeFailure = count }
  }

  func write(_ data: Data, to url: URL) throws {
    let shouldFail = lock.withLock {
      guard let remaining = successfulWritesBeforeFailure else { return false }
      if remaining == 0 {
        successfulWritesBeforeFailure = nil
        return true
      }
      successfulWritesBeforeFailure = remaining - 1
      return false
    }
    if shouldFail { throw Failure.injected }
    try data.write(to: url, options: .atomic)
  }
}

private final class RecoveryQuarantineFailure: @unchecked Sendable {
  enum Failure: Error, Equatable { case injected }

  private let lock = NSLock()
  private var armed = false

  func arm() {
    lock.withLock { armed = true }
  }

  func hit() throws {
    let shouldFail = lock.withLock {
      defer { armed = false }
      return armed
    }
    if shouldFail { throw Failure.injected }
  }
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
