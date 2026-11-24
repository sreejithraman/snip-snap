import Foundation
import CloudKit
import SnipSnapCore
import SnipSnapTestSupport
@testable import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

final class CloudCollectionCoordinatorTests: XCTestCase {
  @MainActor
  func testLaunchAndForegroundHooksUseTheSameSyncPath() async {
    let calls = LifecycleCallCounter()
    let hooks = SnipSnapCloudLifecycleHooks {
      await calls.record()
    }

    await hooks.run()
    await hooks.run()

    let count = await calls.value()
    XCTAssertEqual(count, 2)
  }

  @MainActor
  func testLifecycleHooksRunOneTrailingSyncWhenTriggeredDuringSync() async {
    let calls = PausingLifecycleCallCounter()
    let hooks = SnipSnapCloudLifecycleHooks {
      await calls.run()
    }

    let first = Task { await hooks.run() }
    await calls.waitUntilFirstCallStarts()
    await hooks.run()
    await calls.releaseFirstCall()
    await first.value

    let count = await calls.value()
    XCTAssertEqual(count, 2)
  }

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

  func testControlUpdatesKeepUnknownOrdinaryFieldsWithoutDowngradingFutureVersion() throws {
    let original = descriptor(
      generation: "24242424-2424-2424-2424-242424242424",
      metadata: "control-metadata",
      payload: "control-payload"
    )
    let replacement = descriptor(
      generation: "25252525-2525-2525-2525-252525252525",
      metadata: "next-metadata",
      payload: "next-payload"
    )
    let controlID = CloudRecordID(
      zone: CloudZoneID(name: "control", ownerName: "owner"),
      name: "active-collection"
    )
    let future = try CloudCollectionControlCodec.record(
      original,
      id: controlID,
      replacing: nil
    )
    future["schemaVersion"] = Int64(7)
    future["futureRouting"] = "keep ordinary"

    let decoded = try CloudCollectionControlCodec.decode(future, expectedID: controlID)
    let edited = try CloudCollectionControlCodec.record(
      replacement,
      id: controlID,
      replacing: decoded.version
    )

    XCTAssertEqual(edited["generation"] as? String, replacement.generation.uuidString.lowercased())
    XCTAssertEqual(edited["futureRouting"] as? String, "keep ordinary")
    XCTAssertEqual(edited["schemaVersion"] as? Int64, 7)
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

  @MainActor
  func testExplicitModeEnableImportsLocalLibraryThenUsesGenerationGatedForegroundSync() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ICloudSyncLifecycle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = try JSONSnipLibrary(
      fileURL: root.appendingPathComponent("legacy.json", isDirectory: false)
    )
    let attachmentURL = root.appendingPathComponent("seed-attachment.txt")
    try Data("attachment bytes".utf8).write(to: attachmentURL)
    _ = try await source.perform(
      .add(
        content: "keep this local snip",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [attachmentURL],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    let active = descriptor(
      generation: "15151515-1515-1515-1515-151515151515",
      metadata: "mode-enable-metadata",
      payload: "mode-enable-payload"
    )
    let server = FakeCloudServer()
    let control = FakeCloudControlTransport(server: server)
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root.appendingPathComponent("SyncMode", isDirectory: true),
      sourceLibrary: source,
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      controlTransport: control,
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: { active }
    )
    let session = SnipSnapCloudSyncSession(
      synchronize: { try await lifecycle.synchronize() },
      enable: { try await lifecycle.enableICloudSync() },
      activeLibrary: { try await lifecycle.activeLibrary() }
    )
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      enableAction: { try await session.enableICloudSync() }
    )
    model.setEnableCompletionAction {
      _ = try await session.activeLibrary()
    }

    await model.enableICloudSync()
    let foreground = try await session.synchronize()
    _ = try await session.synchronize()
    let library = try await session.activeLibrary()
    let snapshot = try await library.library.checkedSnapshot(sortedBy: .manual)
    let storedControl = await server.controlDescriptor()
    let metadataRecordTypes = await server.storedRecordTypes(in: active.metadataZone)
    let payloadRecordTypes = await server.storedRecordTypes(in: active.payloadZone)

    XCTAssertEqual(model.mode, .iCloudSync)
    XCTAssertEqual(model.state, .ready)
    XCTAssertEqual(snapshot.snips.map(\.content), ["keep this local snip"])
    XCTAssertEqual(storedControl, active)
    XCTAssertTrue(metadataRecordTypes.contains("AttachmentMetadata"))
    XCTAssertTrue(payloadRecordTypes.contains("AttachmentPayload"))
    XCTAssertEqual(foreground, .syncScheduled)
  }

  func testModeLifecycleTurnsSyncOffWithoutDeletingCloudContent() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ICloudSyncDisable-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = try JSONSnipLibrary(
      fileURL: root.appendingPathComponent("source.json", isDirectory: false)
    )
    _ = try await source.perform(
      .add(
        content: "keep this after turning sync off",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    let active = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let server = FakeCloudServer()
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root.appendingPathComponent("SyncMode", isDirectory: true),
      sourceLibrary: source,
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      controlTransport: FakeCloudControlTransport(server: server),
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: { active }
    )

    try await lifecycle.enableICloudSync()
    _ = try await lifecycle.retrySynchronization()
    try await lifecycle.disableICloudSync(.refreshThenCopy)

    let local = try await lifecycle.activeLibrary().library.checkedSnapshot(sortedBy: .manual)
    let manifest = SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: root.appendingPathComponent("SyncMode", isDirectory: true)
    )
    let cloudControl = await server.controlDescriptor()
    let cloudSnips = await server.storedTextValues()
    XCTAssertEqual(cloudSnips, ["keep this after turning sync off"])
    XCTAssertEqual(local.snips.map(\.content), ["keep this after turning sync off"])
    XCTAssertNil(manifest)
    XCTAssertEqual(cloudControl, active)
  }

  func testStartupReaderDoesNotTreatPendingOrFailedEnableAsActiveCloud() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ICloudStartupState-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    let namespace = ICloudSyncNamespaceBinding(
      scope: "private",
      accountLineage: "account-a",
      generation: UUID(),
      zones: [ICloudSyncZoneBinding(name: "snips-test", ownerName: "owner")]
    )
    _ = try await persistence.beginTransition(to: .iCloudSync, namespace: namespace)

    XCTAssertNil(SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: root
    ))
    XCTAssertEqual(
      SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: root),
      .settingUp(namespace)
    )

    try await persistence.recordAttention(.terminalFetchFailure)

    XCTAssertNil(SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: root
    ))
    XCTAssertEqual(
      SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: root),
      .needsAttention(namespace)
    )
  }

  func testCancelPendingEnableRemovesCandidateAndLeavesLocalStoreActive() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CancelPendingICloudEnable-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    let namespace = ICloudSyncNamespaceBinding(
      scope: "private",
      accountLineage: "account-a",
      generation: UUID(),
      zones: [ICloudSyncZoneBinding(name: "snips-test", ownerName: "owner")]
    )
    _ = try await persistence.beginTransition(to: .iCloudSync, namespace: namespace)

    try await persistence.cancelPendingICloudEnable()

    let snapshot = try await persistence.snapshot()
    XCTAssertEqual(snapshot.activeStore.kind, .localOnly)
    XCTAssertNil(snapshot.transition)
    XCTAssertNil(snapshot.attentionReason)
    XCTAssertEqual(
      SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: root),
      .localOnly
    )
  }

  func testBackgroundExpiryKeepsEnablePendingAndResumesOnLaterSync() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ICloudSyncPendingEnable-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try JSONSnipLibrary(
      fileURL: root.appendingPathComponent("source.json", isDirectory: false)
    )
    _ = try await source.add(content: "keep local", origin: .quickEntry)
    let server = FakeCloudServer()
    let control = FakeCloudControlTransport(server: server)
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let syncRoot = root.appendingPathComponent("SyncMode", isDirectory: true)
    func lifecycle() -> SnipSnapICloudSyncLifecycle {
      SnipSnapICloudSyncLifecycle(
        rootURL: syncRoot,
        sourceLibrary: source,
        syncModeStore: nil,
        cloudScope: "private",
        accountLineage: "account-a",
        ownerName: "owner",
        controlTransport: control,
        makeRecordTransport: { context in
          FakeCloudRecordTransport(server: server, namespace: context.namespace)
        },
        makeDescriptor: { descriptor }
      )
    }

    let first = try await SnipStoreBackgroundActivity.$runner.withValue({ expire in
      expire()
      return {}
    }) {
      try await lifecycle().enableICloudSync()
    }
    XCTAssertEqual(first, .settingUp(.someChangesPending))
    XCTAssertNil(SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: syncRoot
    ))

    let resumed = try await lifecycle().synchronize()

    XCTAssertEqual(resumed, .iCloudSyncEnabled)
    XCTAssertNotNil(SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: syncRoot
    ))
  }

  func testOfflineEnableStaysPendingAndResumesOnLaterSync() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ICloudSyncPendingEnable-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try JSONSnipLibrary(
      fileURL: root.appendingPathComponent("source.json", isDirectory: false)
    )
    _ = try await source.add(content: "keep local", origin: .quickEntry)
    let server = FakeCloudServer()
    let control = OfflineThenOnlineControlTransport(server: server)
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let syncRoot = root.appendingPathComponent("SyncMode", isDirectory: true)
    func lifecycle() -> SnipSnapICloudSyncLifecycle {
      SnipSnapICloudSyncLifecycle(
        rootURL: syncRoot,
        sourceLibrary: source,
        syncModeStore: nil,
        cloudScope: "private",
        accountLineage: "account-a",
        ownerName: "owner",
        controlTransport: control,
        makeRecordTransport: { context in
          FakeCloudRecordTransport(server: server, namespace: context.namespace)
        },
        makeDescriptor: { descriptor }
      )
    }

    let first = try await lifecycle().enableICloudSync()
    XCTAssertEqual(first, .settingUp(.waitingForConnection))
    XCTAssertNil(SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: syncRoot
    ))

    await control.goOnline()
    let resumed = try await lifecycle().synchronize()

    XCTAssertEqual(resumed, .iCloudSyncEnabled)
    XCTAssertNotNil(SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: syncRoot
    ))
  }

  func testTemporaryAndUnknownAccountFailuresKeepTypedEnableStateAfterRelaunch() async throws {
    let cases: [(ICloudAccountState, SyncedContentSyncIssue)] = [
      (.temporarilyUnavailable, .accountTemporarilyUnavailable),
      (.couldNotDetermine, .checkingAccount),
    ]
    for (accountState, expectedIssue) in cases {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AccountEnable-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
      let syncRoot = root.appendingPathComponent("SyncMode", isDirectory: true)
      let lifecycle = SnipSnapICloudSyncLifecycle(
        rootURL: syncRoot,
        sourceLibrary: source,
        syncModeStore: nil,
        cloudScope: "private",
        accountLineage: "account-a",
        accountStateSource: FixedICloudAccountStateSource(state: accountState),
        ownerName: "owner",
        controlTransport: FakeCloudControlTransport(server: FakeCloudServer()),
        makeRecordTransport: { context in
          FakeCloudRecordTransport(server: FakeCloudServer(), namespace: context.namespace)
        },
        makeDescriptor: { CloudCollectionDescriptor.fresh(ownerName: "owner") }
      )

      let outcome = try await lifecycle.enableICloudSync()
      let restarted = SnipSnapCloudAppAssembly.settingsStartupState(
        rootURL: syncRoot,
        startupState: SyncModeActivationManifestReader.iCloudStartupState(
          atSyncModeRootURL: syncRoot
        )
      )

      XCTAssertEqual(outcome, .settingUp(expectedIssue))
      XCTAssertEqual(restarted.state, .enabling(expectedIssue))
    }
  }

  func testPendingOfflineEnableCanBeCanceledBeforeConnectivityReturns() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CancelOfflineICloudEnable-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
    _ = try await source.add(content: "stay local", origin: .quickEntry)
    let server = FakeCloudServer()
    let control = OfflineThenOnlineControlTransport(server: server)
    let syncRoot = root.appendingPathComponent("SyncMode", isDirectory: true)
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: syncRoot,
      sourceLibrary: source,
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      controlTransport: control,
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: { CloudCollectionDescriptor.fresh(ownerName: "owner") }
    )

    let enableOutcome = try await lifecycle.enableICloudSync()
    XCTAssertEqual(enableOutcome, .settingUp(.waitingForConnection))
    try await lifecycle.cancelPendingEnable()
    await control.goOnline()

    let syncOutcome = try await lifecycle.synchronize()
    XCTAssertEqual(syncOutcome, .noChange)
    XCTAssertEqual(
      SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: syncRoot),
      .localOnly
    )
    let snapshot = try await lifecycle.activeLibrary().library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.snips.map(\.content), ["stay local"])
  }

  @MainActor
  func testTerminalEnableFailureRestartsAsLocalNeedsAttention() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("TerminalICloudEnable-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
    let syncRoot = root.appendingPathComponent("SyncMode", isDirectory: true)
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: syncRoot,
      sourceLibrary: source,
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      controlTransport: TerminalSetupControlTransport(),
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: FakeCloudServer(), namespace: context.namespace)
      },
      makeDescriptor: { CloudCollectionDescriptor.fresh(ownerName: "owner") }
    )

    do {
      _ = try await lifecycle.enableICloudSync()
      XCTFail("Expected terminal setup failure")
    } catch {}

    let restarted = SnipSnapCloudAppAssembly.settingsStartupState(
      rootURL: syncRoot,
      startupState: SyncModeActivationManifestReader.iCloudStartupState(
        atSyncModeRootURL: syncRoot
      )
    )
    XCTAssertEqual(restarted.mode, .localOnly)
    XCTAssertEqual(restarted.state, .failed(.appDataIssue))
  }

  func testAccountSetupFailureKeepsItsExactMessageAfterRestart() async throws {
    let cases: [(ICloudAccountState, SyncedContentSyncIssue)] = [
      (.noAccount, .signInRequired),
      (.restricted, .accountRestricted),
    ]
    for (accountState, expectedIssue) in cases {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AccountSetupFailure-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
      let syncRoot = root.appendingPathComponent("SyncMode", isDirectory: true)
      let lifecycle = SnipSnapICloudSyncLifecycle(
        rootURL: syncRoot,
        sourceLibrary: source,
        syncModeStore: nil,
        cloudScope: "private",
        accountLineage: "account-a",
        accountStateSource: FixedICloudAccountStateSource(state: accountState),
        ownerName: "owner",
        controlTransport: FakeCloudControlTransport(server: FakeCloudServer()),
        makeRecordTransport: { context in
          FakeCloudRecordTransport(server: FakeCloudServer(), namespace: context.namespace)
        },
        makeDescriptor: { CloudCollectionDescriptor.fresh(ownerName: "owner") }
      )

      do {
        _ = try await lifecycle.enableICloudSync()
        XCTFail("Expected account setup failure")
      } catch {}

      let restarted = SnipSnapCloudAppAssembly.settingsStartupState(
        rootURL: syncRoot,
        startupState: SyncModeActivationManifestReader.iCloudStartupState(
          atSyncModeRootURL: syncRoot
        )
      )
      XCTAssertEqual(restarted.state, .failed(expectedIssue))
    }
  }

  func testFullRecordFetchRetryKeepsItsExactMessageAfterRestart() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("FullRecordFetchRetry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "account-a")
    let server = FakeCloudServer()
    let writerSource = try JSONSnipLibrary(fileURL: root.appendingPathComponent("writer.json"))
    let added = try await writerSource.add(content: "remote fetch", origin: .quickEntry)
    let remoteSnip = try XCTUnwrap(added)
    let writer = SnipSnapICloudSyncLifecycle(
      rootURL: root.appendingPathComponent("Writer", isDirectory: true),
      sourceLibrary: writerSource,
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      controlTransport: FakeCloudControlTransport(server: server),
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: { descriptor }
    )
    let writerOutcome = try await writer.enableICloudSync()
    XCTAssertEqual(writerOutcome, .enabled)
    _ = try await writer.retrySynchronization()

    let readerRoot = root.appendingPathComponent("Reader", isDirectory: true)
    let readerTransport = FakeCloudRecordTransport(server: server, namespace: namespace)
    await readerTransport.failNextFetchedItem(
      .snip(remoteSnip.id, in: descriptor.metadataZone),
      failure: .networkUnavailable
    )
    let reader = SnipSnapICloudSyncLifecycle(
      rootURL: readerRoot,
      sourceLibrary: try JSONSnipLibrary(fileURL: root.appendingPathComponent("reader.json")),
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      controlTransport: FakeCloudControlTransport(server: server),
      makeRecordTransport: { _ in readerTransport },
      makeDescriptor: { descriptor }
    )

    let outcome = try await reader.enableICloudSync()
    let restarted = SnipSnapCloudAppAssembly.settingsStartupState(
      rootURL: readerRoot,
      startupState: SyncModeActivationManifestReader.iCloudStartupState(
        atSyncModeRootURL: readerRoot
      )
    )

    XCTAssertEqual(outcome, .settingUp(.waitingForConnection))
    XCTAssertEqual(restarted.state, .enabling(.waitingForConnection))

    let retryResult = try await reader.synchronize()
    let active = try await reader.activeLibrary().library.snapshot(sortedBy: .manual)
    XCTAssertEqual(retryResult, .iCloudSyncEnabled)
    XCTAssertTrue(active.snips.contains(where: { $0.id == remoteSnip.id }))
  }

  func testExplicitEnableStagesConflictZonesBeforeCleanupAndRetriesOnForeground() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ICloudSyncConflict-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let losing = descriptor(
      generation: "45454545-4545-4545-4545-454545454545",
      metadata: "enable-losing-metadata",
      payload: "enable-losing-payload"
    )
    let winning = descriptor(
      generation: "46464646-4646-4646-4646-464646464646",
      metadata: "enable-winning-metadata",
      payload: "enable-winning-payload"
    )
    let server = FakeCloudServer()
    let losingTransport = FakeCloudControlTransport(server: server)
    let winningTransport = FakeCloudControlTransport(server: server)
    await losingTransport.pauseNextControlSave()
    let losingLifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root.appendingPathComponent("losing", isDirectory: true),
      sourceLibrary: try JSONSnipLibrary(
        fileURL: root.appendingPathComponent("losing.json", isDirectory: false)
      ),
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      controlTransport: losingTransport,
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: { losing }
    )
    let winningLifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root.appendingPathComponent("winning", isDirectory: true),
      sourceLibrary: try JSONSnipLibrary(
        fileURL: root.appendingPathComponent("winning.json", isDirectory: false)
      ),
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      controlTransport: winningTransport,
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: { winning }
    )

    let losingEnable = Task { try await losingLifecycle.enableICloudSync() }
    await losingTransport.waitUntilControlSavePauses()
    try await winningLifecycle.enableICloudSync()
    await losingTransport.failNextZoneDelete()
    await losingTransport.resumeControlSave()
    try await losingEnable.value

    let losingMetadataExists = await server.hasZone(losing.metadataZone)
    let losingPayloadExists = await server.hasZone(losing.payloadZone)
    XCTAssertTrue(losingMetadataExists)
    XCTAssertTrue(losingPayloadExists)

    _ = try await losingLifecycle.synchronize()

    let losingMetadataRemains = await server.hasZone(losing.metadataZone)
    let losingPayloadRemains = await server.hasZone(losing.payloadZone)
    let winningMetadataExists = await server.hasZone(winning.metadataZone)
    let winningPayloadExists = await server.hasZone(winning.payloadZone)
    XCTAssertFalse(losingMetadataRemains)
    XCTAssertFalse(losingPayloadRemains)
    XCTAssertTrue(winningMetadataExists)
    XCTAssertTrue(winningPayloadExists)
  }

  func testMissingControlRecordOrZoneMeansSyncHasNotBeenEnabled() {
    XCTAssertTrue(CloudKitCollectionControlTransport.isMissingControl(.unknownItem))
    XCTAssertTrue(CloudKitCollectionControlTransport.isMissingControl(.zoneNotFound))
    XCTAssertFalse(CloudKitCollectionControlTransport.isMissingControl(.networkFailure))
  }

  func testCloudKitRetryPolicySeparatesTransientAndPermanentSetupFailures() {
    XCTAssertTrue(CloudKitRetryPolicy.isTransient(.networkUnavailable))
    XCTAssertTrue(CloudKitRetryPolicy.isTransient(.serviceUnavailable))
    XCTAssertTrue(CloudKitRetryPolicy.isTransient(.serverResponseLost))
    XCTAssertFalse(CloudKitRetryPolicy.isTransient(.accountTemporarilyUnavailable))
    XCTAssertFalse(CloudKitRetryPolicy.isTransient(.operationCancelled))
    XCTAssertFalse(CloudKitRetryPolicy.isTransient(.notAuthenticated))
    XCTAssertFalse(CloudKitRetryPolicy.isTransient(.permissionFailure))
    XCTAssertFalse(CloudKitRetryPolicy.isTransient(.quotaExceeded))
  }

  func testCloudKitRetryPolicyHonorsServerRetryDelay() {
    let error = CKError(
      .requestRateLimited,
      userInfo: [CKErrorRetryAfterKey: NSNumber(value: 7.5)]
    )

    XCTAssertEqual(CloudKitRetryPolicy.delay(after: error, attempt: 1), .milliseconds(7_500))
    XCTAssertEqual(CloudKitRetryPolicy.delay(after: error, attempt: 3), .milliseconds(7_500))
  }

  @MainActor
  func testSimulatedAutomaticSyncPublishesResultAndActivatesWritableCloudLibrary() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimulatedAutomaticSync-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try SwiftDataSnipLibrary(
      storeURL: root.appendingPathComponent("original.store", isDirectory: false)
    )
    let assembly = SnipLibraryAssembly(
      library: original,
      syncModeRootURL: root,
      initializeSyncModeStore: true
    )
    let services = SnipSnapCloudAppAssembly.simulatedServices(
      rootURL: root,
      syncModeStore: try XCTUnwrap(assembly.syncModeStore)
    )
    let session = try XCTUnwrap(services.syncSession)
    let receivedResult = expectation(description: "Scheduled fake sync publishes its result")
    var result: SnipSnapCloudSyncResult?
    let observer = Task {
      var iterator = session.automaticSyncResults.makeAsyncIterator()
      result = await iterator.next()
      receivedResult.fulfill()
    }
    defer { observer.cancel() }

    await session.scheduleAutomaticSync()
    await fulfillment(of: [receivedResult], timeout: 5)
    observer.cancel()
    await observer.value

    XCTAssertEqual(result, .contentUpdated)
    let active = try await session.activeLibrary()
    XCTAssertNotNil(active.recoveryScope)
    _ = try await active.library.perform(
      .add(
        content: "written after scheduled sync",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 5)
      ),
      sortedBy: .manual
    )
    let snapshot = await active.library.snapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.snips.map(\.content), ["written after scheduled sync"])
  }

  func testCollectionErrorsHaveUserFacingMessages() {
    XCTAssertEqual(
      CloudCollectionError.noActiveCollection.errorDescription,
      "iCloud sync has no active library."
    )
    XCTAssertEqual(
      CloudCollectionError.invalidDescriptor.errorDescription,
      "This iCloud library can’t be used for sync."
    )
  }

  func testDurableLocalAdapterKeepsTheLibraryWhenAnotherGenerationAppears() async throws {
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
    try await mode.seedEmptyActiveStore(namespace: binding(old))
    let oldStore = try await mode.snapshot().activeStore
    let oldLibrary = try await mode.libraryForTransition(storeID: oldStore.id)
    let attachmentSource = root.appendingPathComponent("kept-note.txt")
    let attachmentBytes = Data("keep this attachment".utf8)
    try attachmentBytes.write(to: attachmentSource)
    _ = try await oldLibrary.perform(
      .add(
        content: "unsynced local edit",
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
    let seededEngine = try await oldCloudPersistence.loadEngineState()
    XCTAssertNotNil(seededEngine)
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(fresh)
    let driver = TestCloudCollectionSyncDriver()
    let coordinator = makeCollectionCoordinator(
      local: try SwiftDataCloudCollectionLocalStore(rootURL: root, persistence: mode),
      transport: transport,
      driver: driver,
      makeDescriptor: { fresh }
    )

    let status = try await coordinator.synchronize()

    XCTAssertEqual(status, .purged)
    XCTAssertEqual(syncResult(for: status), .iCloudDataReset)
    let driverEvents = await driver.events()
    XCTAssertTrue(driverEvents.isEmpty)
    let clearedEngine = try await oldCloudPersistence.loadEngineState()
    XCTAssertNil(clearedEngine)
    let kept = try await mode.snapshot()
    XCTAssertEqual(kept.activeStore.id, oldStore.id)
    XCTAssertEqual(kept.activeStore.kind, .localOnly)
    XCTAssertEqual(kept.activeStore.quarantinedNamespace, binding(old))
    XCTAssertTrue(kept.keptAfterCloudReset)
    let manifest = try Data(contentsOf: root.appendingPathComponent("activation.json"))
    XCTAssertFalse(String(decoding: manifest, as: UTF8.self).contains(#""recovery""#))
    let library = try await mode.activeLibrary()
    let edited = try await library.perform(
      .add(
        content: "written after the stop",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )
    XCTAssertEqual(
      Set(edited.snapshot.snips.map(\.content)), ["unsynced local edit", "written after the stop"]
    )
    let keptSnip = try XCTUnwrap(edited.snapshot.snips.first { $0.content == "unsynced local edit" })
    let attachmentURL = try XCTUnwrap(
      edited.snapshot.attachmentURLs[try XCTUnwrap(keptSnip.attachments.first?.id)]
    )
    XCTAssertEqual(try Data(contentsOf: attachmentURL), attachmentBytes)

    let reopened = try reopenedCollectionStore(at: root)
    let reopenedState = try await reopened.state()
    XCTAssertTrue(reopenedState.keptAfterReset)
    XCTAssertNil(reopenedState.activeNamespace)
    let later = try await makeCollectionCoordinator(
      local: reopened, transport: transport, driver: driver, makeDescriptor: { fresh }
    ).synchronize()
    XCTAssertEqual(later, .requiresEnable)
  }

  func testAutomaticAccountChangeReachesTheResultStream() async {
    let results = AsyncStream.makeStream(of: SnipSnapCloudSyncResult.self)
    let session = SnipSnapCloudSyncSession(
      synchronize: { .noChange },
      scheduleAutomaticSync: { throw ICloudAccountGateError.accountChanged },
      enable: { .enabled },
      activeLibrary: { throw SyncModePersistenceError.missingStore },
      automaticSyncResults: results.stream,
      automaticErrorHandler: { error in
        results.continuation.yield(automaticSyncResult(for: error))
      }
    )
    var iterator = results.stream.makeAsyncIterator()

    await session.scheduleAutomaticSync()
    let result = await iterator.next()

    XCTAssertEqual(result, .iCloudAccountChanged)
    results.continuation.finish()
  }

  func testNormalSchedulingLeavesRecordFetchesAndSendsToTheEngine() async throws {
    let active = descriptor(
      generation: "22222222-3333-4444-5555-666666666666",
      metadata: "automatic-metadata", payload: "automatic-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(active)
    let driver = TestCloudCollectionSyncDriver()
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private", accountLineage: "account-a", ownerName: "owner",
      localStore: TestCloudCollectionLocalStore(active: namespace(active), hasSyncedBefore: true),
      transport: transport, syncDriver: driver, makeDescriptor: { active }
    )

    let normal = try await coordinator.scheduleSynchronization()
    let events = await driver.events()

    XCTAssertEqual(normal, .scheduled(namespace(active)))
    XCTAssertEqual(events, [.scheduled(namespace(active))])
  }

  func testDifferentGenerationStopsWithKeepLocalOnEveryRequest() async throws {
    let stale = descriptor(
      generation: "88888888-8888-8888-8888-888888888888",
      metadata: "stale-request-metadata", payload: "stale-request-payload"
    )
    let current = descriptor(
      generation: "99999999-9999-9999-9999-999999999999",
      metadata: "current-request-metadata", payload: "current-request-payload"
    )
    let requests: [(String, @Sendable (CloudCollectionCoordinator) async throws -> CloudCollectionStatus)] = [
      ("schedule", { try await $0.scheduleSynchronization() }),
      ("transfer", { try await $0.synchronize() }),
      ("retry", { try await $0.retrySynchronization() }),
    ]
    for (name, request) in requests {
      let server = FakeCloudServer()
      let transport = FakeCloudControlTransport(server: server)
      await transport.seedControl(current)
      let local = TestCloudCollectionLocalStore(active: namespace(stale), hasSyncedBefore: true)
      let driver = TestCloudCollectionSyncDriver()
      let accountChecks = LifecycleCallCounter()
      let coordinator = CloudCollectionCoordinator(
        cloudScope: "private", accountLineage: "account-a", ownerName: "owner",
        localStore: local, transport: transport, syncDriver: driver,
        makeDescriptor: {
          XCTFail("A stale device must not create a collection")
          return current
        },
        beforeReplacingCollection: { await accountChecks.record() }
      )

      let status = try await request(coordinator)

      let state = await local.state()
      let localEvents = await local.events()
      let driverEvents = await driver.events()
      let checks = await accountChecks.value()
      let control = await server.controlDescriptor()
      XCTAssertEqual(status, .purged, name)
      XCTAssertEqual(syncResult(for: status), .iCloudDataReset, name)
      XCTAssertEqual(checks, 1, name)
      XCTAssertNil(state.activeNamespace, name)
      XCTAssertTrue(state.keptAfterReset, name)
      XCTAssertEqual(localEvents, [.purged], name)
      XCTAssertTrue(driverEvents.isEmpty, name)
      XCTAssertEqual(control, current, name)
      let later = try await request(coordinator)
      XCTAssertEqual(later, .requiresEnable, name)
    }
  }

  func testWithoutAnActiveCollectionSyncRequiresEnableEvenWhenAControlRecordExists() async throws {
    let remote = descriptor(
      generation: "87878787-8787-8787-8787-878787878787",
      metadata: "no-active-metadata", payload: "no-active-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(remote)
    let local = TestCloudCollectionLocalStore(active: nil, hasSyncedBefore: true)
    let driver = TestCloudCollectionSyncDriver()
    let coordinator = makeCollectionCoordinator(
      local: local, transport: transport, driver: driver, makeDescriptor: { remote }
    )

    let scheduled = try await coordinator.scheduleSynchronization()
    let transferred = try await coordinator.synchronize()
    let retried = try await coordinator.retrySynchronization()

    XCTAssertEqual([scheduled, transferred, retried], [.requiresEnable, .requiresEnable, .requiresEnable])
    let localEvents = await local.events()
    let driverEvents = await driver.events()
    let activeNamespace = await local.activeNamespace()
    XCTAssertTrue(localEvents.isEmpty)
    XCTAssertTrue(driverEvents.isEmpty)
    XCTAssertNil(activeNamespace)
  }

  func testNormalSchedulingUsesCachedDescriptorButTryAgainWaitsForFetch() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudEngineFirstLifecycle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let active = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(active))
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
    let server = FakeCloudServer()
    let control = FakeCloudControlTransport(server: server)
    await control.seedControl(active)
    let records = LifecycleAutomaticTransportProbe(namespace: namespace(active))
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root, sourceLibrary: source, syncModeStore: SnipSyncModeStore(persistence),
      cloudScope: "private", accountLineage: "account-a", ownerName: "owner",
      controlTransport: control, makeRecordTransport: { _ in records }, makeDescriptor: { active }
    )

    try await lifecycle.scheduleAutomaticSync()
    try await lifecycle.scheduleAutomaticSync()
    let automaticControlEvents = await control.events()
    let retried = try await lifecycle.retrySynchronization()
    let events = await records.events()

    XCTAssertEqual(automaticControlEvents, [])
    // The probe returns no records, so the retry reports an unsettled fetch.
    XCTAssertEqual(retried, .contentUpdated)
    XCTAssertEqual(events, ["started", "fetched"])
  }

  func testTryAgainStopsWhenAnotherGenerationAppearsBeforeItsSend() async throws {
    let old = descriptor(
      generation: "30303030-1111-2222-3333-444444444444",
      metadata: "retry-change-old-metadata", payload: "retry-change-old-payload"
    )
    let current = descriptor(
      generation: "40404040-1111-2222-3333-444444444444",
      metadata: "retry-change-new-metadata", payload: "retry-change-new-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    let driver = TestCloudCollectionSyncDriver()
    await driver.pauseNextFetch()
    let local = TestCloudCollectionLocalStore(active: namespace(old), hasSyncedBefore: true)
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private", accountLineage: "account-a", ownerName: "owner",
      localStore: local, transport: transport, syncDriver: driver, makeDescriptor: { current }
    )

    let retry = Task { try await coordinator.retrySynchronization() }
    await driver.waitUntilFetchPauses()
    await transport.seedControl(current)
    await driver.resumeFetch()
    let status = try await retry.value

    XCTAssertEqual(status, .purged)
    let events = await driver.events()
    XCTAssertEqual(events, [
      .preparedManualRetry(namespace(old)),
      .fetched(namespace(old)),
    ])
    let state = await local.state()
    XCTAssertTrue(state.keptAfterReset)
  }

  func testReadingTheLibraryKeepsItsEngineAliveUntilTheDelayedFetchCommits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudLibraryOwner-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let current = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(current))
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
    let server = FakeCloudServer()
    let control = FakeCloudControlTransport(server: server)
    await control.seedControl(current)
    let snipID = UUID()
    let remoteID = CloudRecordID.snip(snipID, in: current.metadataZone)
    _ = try await server.send(CloudOutboundBatch(
      operations: [.save(.text(id: remoteID, snipID: snipID, text: "arrived after the read"))],
      zonesToSave: current.zones
    ), failures: [:])
    let fetcher = FakeCloudRecordTransport(server: server, namespace: namespace(current))
    let fetched = try await fetcher.fetch(scope: .all)
    let records = LifecycleAutomaticTransportProbe()
    let delivered = expectation(description: "The engine delivers its fetch")
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root, sourceLibrary: source, syncModeStore: SnipSyncModeStore(persistence),
      cloudScope: "private", accountLineage: "account-a", ownerName: "owner",
      controlTransport: control, makeRecordTransport: { _ in records }, makeDescriptor: { current },
      automaticResultHandler: { result in
        if result == .contentUpdated || result == .syncCompleted { delivered.fulfill() }
      }
    )

    let result = try await lifecycle.synchronize()
    let active = try await lifecycle.activeLibrary()
    XCTAssertEqual(result, .syncScheduled)
    await records.enqueue(.fetched(fetched))
    await fulfillment(of: [delivered], timeout: 2)

    let snapshot = try await active.library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.snips.map(\.content), ["arrived after the read"])
    let events = await records.events()
    XCTAssertEqual(events.filter { $0 == "started" }.count, 1)
  }

  func testQueuedOldPurgeCannotPublishAResultAfterTheDeviceKeepsItsLibrary() async throws {
    try await verifyReplacedRecordWork(purge: true)
  }

  func testOldRecordSendIsDeniedAfterTheDeviceKeepsItsLibrary() async throws {
    try await verifyReplacedRecordWork(purge: false)
  }

  private func verifyReplacedRecordWork(purge: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudOldOwner-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let fresh = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(old))
    let original = try await persistence.snapshot().activeStore
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
    let server = FakeCloudServer()
    let control = FakeCloudControlTransport(server: server)
    await control.seedControl(old)
    let checkedControl = PausingCollectionControlTransport(base: control)
    let oldRecords = LifecycleAutomaticTransportProbe()
    let freshRecords = LifecycleAutomaticTransportProbe()
    let results = CollectionResultRecorder()
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root, sourceLibrary: source, syncModeStore: SnipSyncModeStore(persistence),
      cloudScope: "private", accountLineage: "account-a", ownerName: "owner",
      controlTransport: checkedControl,
      makeRecordTransport: { $0.namespace.generation == old.generation ? oldRecords : freshRecords },
      makeDescriptor: { fresh }, automaticResultHandler: results.append
    )
    _ = try await lifecycle.synchronize()
    let pause = CollectionWorkPause()
    defer { Task { await pause.resume() } }
    let paused = expectation(description: "Old record work reached the control fetch")
    await checkedControl.pauseNextFetch(pause) { paused.fulfill() }
    let finished = expectation(description: "Old record work returns after replacement")
    let sendTask: Task<Bool, Never>?
    if purge {
      await oldRecords.onNextWorkCompletion { finished.fulfill() }
      await oldRecords.enqueue(.fetched(CloudFetchedBatch(id: UUID(), items: [],
        databaseEvents: [.zoneDeleted(old.metadataZone, reason: .purged)], engineState: nil)))
      sendTask = nil
    } else {
      sendTask = Task {
        defer { finished.fulfill() }
        do { try await oldRecords.authorizeSend(); return true }
        catch { return false }
      }
    }
    guard await XCTWaiter.fulfillment(of: [paused], timeout: 2) == .completed else {
      XCTFail("Old record work did not reach the control fetch")
      return
    }

    await control.seedControl(fresh)
    let stopped = try await lifecycle.synchronize()
    XCTAssertEqual(stopped, .iCloudDataReset)
    let active = try await lifecycle.activeLibrary()
    _ = try await active.library.perform(.add(content: "kept library edit", origin: .quickEntry,
      source: nil, listID: SnipList.inbox.id, attachmentURLs: [], requestID: UUID(), now: Date()), sortedBy: .manual)
    let beforeRelease = try await persistence.snapshot().activeStore
    XCTAssertEqual(beforeRelease.id, original.id)
    await pause.resume()
    guard await XCTWaiter.fulfillment(of: [finished], timeout: 2) == .completed else {
      XCTFail("Old record work did not finish after the control fetch resumed")
      return
    }
    if let sendTask {
      let allowed = await sendTask.value
      XCTAssertFalse(allowed)
    }

    let after = try await persistence.snapshot()
    let snapshot = try await active.library.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(after.activeStore.id, original.id)
    XCTAssertTrue(after.keptAfterCloudReset)
    XCTAssertEqual(after.activeStore.quarantinedNamespace, binding(old))
    XCTAssertEqual(snapshot.snips.map(\.content), ["kept library edit"])
    XCTAssertFalse(results.values().contains(.iCloudDataReset))
    XCTAssertFalse(results.values().contains { if case .syncIssue = $0 { true } else { false } })
    let oldEvents = await oldRecords.events()
    let freshEvents = await freshRecords.events()
    XCTAssertTrue(oldEvents.contains("reset"))
    XCTAssertFalse(oldEvents.contains("sent"))
    XCTAssertTrue(freshEvents.isEmpty)
  }

  func testEngineRecordWorkThatFindsAnotherGenerationKeepsTheLibraryAndReportsTheReset() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudEngineReset-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let next = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(old))
    let original = try await persistence.snapshot().activeStore
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
    let library = try await persistence.activeLibrary()
    _ = try await library.perform(.add(content: "unsynced before the reset", origin: .quickEntry,
      source: nil, listID: SnipList.inbox.id, attachmentURLs: [], requestID: UUID(), now: Date()),
      sortedBy: .manual)
    let control = FakeCloudControlTransport(server: FakeCloudServer())
    await control.seedControl(old)
    let records = LifecycleAutomaticTransportProbe()
    let results = CollectionResultRecorder()
    let reported = expectation(description: "The engine path reports the reset")
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root, sourceLibrary: source, syncModeStore: SnipSyncModeStore(persistence),
      cloudScope: "private", accountLineage: "account-a", ownerName: "owner",
      controlTransport: control, makeRecordTransport: { _ in records },
      makeDescriptor: {
        XCTFail("Engine work must not create a collection")
        return next
      },
      automaticResultHandler: { result in
        results.append(result)
        if result == .iCloudDataReset { reported.fulfill() }
      }
    )
    let scheduled = try await lifecycle.synchronize()
    XCTAssertEqual(scheduled, .syncScheduled)

    // Another device reset iCloud and turned sync on again before this engine fetched.
    await control.seedControl(next)
    await records.enqueue(.fetched(CloudFetchedBatch(id: UUID(), items: [], engineState: nil)))
    await fulfillment(of: [reported], timeout: 2)

    let storage = try await persistence.snapshot()
    XCTAssertEqual(storage.activeStore.id, original.id)
    XCTAssertTrue(storage.keptAfterCloudReset)
    XCTAssertEqual(storage.activeStore.quarantinedNamespace, binding(old))
    XCTAssertEqual(results.values().filter { $0 == .iCloudDataReset }.count, 1)
    let edited = try await library.perform(.add(content: "written after the reset",
      origin: .quickEntry, source: nil, listID: SnipList.inbox.id, attachmentURLs: [],
      requestID: UUID(), now: Date()), sortedBy: .manual)
    XCTAssertEqual(Set(edited.snapshot.snips.map(\.content)),
      ["unsynced before the reset", "written after the reset"])
    let events = await records.events()
    XCTAssertFalse(events.contains("sent"))
    let later = try await lifecycle.synchronize()
    XCTAssertEqual(later, .noChange)
  }

  func testSourceBoundPurgeAndRecordMutationsRejectAReplacedStore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudBoundMutation-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let fresh = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(old))
    let original = try await persistence.snapshot().activeStore
    let oldLibrary = try await persistence.libraryForTransition(storeID: original.id)
    let lease = try await persistence.activeCloudMutation(storeID: original.id)
    let store = CloudFullSyncPersistence(library: oldLibrary, namespace: namespace(old),
      dataZone: old.metadataZone, payloadZone: old.payloadZone, activeMutation: lease)
    let batch = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
    try await store.stage(.fetched(batch), outbound: nil)
    try await persistence.seedEmptyActiveStore(namespace: binding(fresh))
    let activeBefore = try await persistence.snapshot().activeStore

    do { try await store.applyStaged(batch.id); XCTFail("Old apply must fail admission") }
    catch SyncModePersistenceError.namespaceMismatch {}
    do { try await store.stage(.fetched(batch), outbound: nil); XCTFail("Old stage must fail admission") }
    catch SyncModePersistenceError.namespaceMismatch {}
    let stopped = try await persistence.keepCloudCacheLocally(
      storeID: original.id, namespace: binding(old), reason: .namespaceChanged)
    XCTAssertEqual(stopped, .sourceReplaced)
    let activeAfter = try await persistence.snapshot().activeStore
    XCTAssertEqual(activeAfter, activeBefore)
  }

  func testLibraryReadCannotReleaseAnActiveRecordCommitBeforeStoreReplacement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudMutationAdmission-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let fresh = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(old))
    let original = try await persistence.snapshot().activeStore
    let library = try await persistence.libraryForTransition(storeID: original.id)
    let lease = try await persistence.activeCloudMutation(storeID: original.id)
    let pause = CollectionWorkPause()
    let store = CloudFullSyncPersistence(library: library, namespace: namespace(old),
      dataZone: old.metadataZone, activeMutation: lease, afterCommitHook: { await pause.suspend() })
    let batch = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
    try await store.stage(.fetched(batch), outbound: nil)
    let applying = Task { try await store.applyStaged(batch.id) }
    await pause.waitUntilSuspended()

    let activeLibrary = try await persistence.activeLibrary()
    _ = try await activeLibrary.checkedSnapshot(sortedBy: .manual)
    do { try await persistence.seedEmptyActiveStore(namespace: binding(fresh)); XCTFail("Store replacement must wait for mutation admission") }
    catch SyncModePersistenceError.transitionInProgress {}
    await pause.resume()
    try await applying.value
    try await persistence.seedEmptyActiveStore(namespace: binding(fresh))
    let active = try await persistence.snapshot().activeStore
    XCTAssertEqual(active.namespace, binding(fresh))
  }

  func testExplicitDriverReportsItsFetchIssueAfterSendingUnrelatedWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudExplicitFetchIssue-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let active = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(active))
    let storage = try await persistence.snapshot()
    let library = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
    _ = try await library.perform(.add(
      content: "unrelated local edit", origin: .quickEntry, source: nil,
      listID: SnipList.inbox.id, attachmentURLs: [], requestID: UUID(), now: Date()
    ), sortedBy: .manual)
    let localSnapshot = try await library.checkedSnapshot(sortedBy: .manual)
    let local = try XCTUnwrap(localSnapshot.snips.first)
    let remoteSnipID = UUID()
    let remoteID = CloudRecordID.snip(remoteSnipID, in: active.metadataZone)
    let server = FakeCloudServer()
    let transport = FakeCloudRecordTransport(server: server, namespace: namespace(active))
    let driver = CloudFullRecordCollectionSyncDriver(persistence: persistence, makeTransport: { _ in transport })
    _ = try await server.send(CloudOutboundBatch(
      operations: [.save(.text(id: remoteID, snipID: remoteSnipID, text: "unavailable remote item"))],
      zonesToSave: active.zones
    ), failures: [:])
    _ = try await driver.fetch(CloudCollectionSyncContext(
      namespace: namespace(active), metadataZone: active.metadataZone, payloadZone: active.payloadZone
    ))
    await transport.failNextFetchedItem(remoteID, failure: .attachmentUnavailable)
    let control = FakeCloudControlTransport(server: server)
    await control.seedControl(active)
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private", accountLineage: "account-a", ownerName: "owner",
      localStore: TestCloudCollectionLocalStore(active: namespace(active), hasSyncedBefore: true),
      transport: control, syncDriver: driver, makeDescriptor: { active }
    )

    do {
      _ = try await coordinator.synchronize()
      XCTFail("The current fetch issue must survive the successful send")
    } catch let error as CloudSyncIssueError {
      XCTAssertEqual(error.issue, .attachmentUnavailable)
    }
    let uploaded = try await server.snapshot(for: .snip(local.id, in: active.metadataZone), fields: [])
    let events = await transport.events()
    XCTAssertNotNil(uploaded, "Transport events: \(events)")
  }

  func testOnlyExplicitRetryPreparesUserRecoverableFailures() async throws {
    let active = descriptor(
      generation: "22222222-3333-4444-5555-666666666666",
      metadata: "manual-retry-metadata",
      payload: "manual-retry-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(active)
    let driver = TestCloudCollectionSyncDriver()
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: TestCloudCollectionLocalStore(
        active: namespace(active), hasSyncedBefore: true
      ),
      transport: transport,
      syncDriver: driver,
      makeDescriptor: { active }
    )

    _ = try await coordinator.synchronize()
    _ = try await coordinator.retrySynchronization()
    let events = await driver.events()

    XCTAssertEqual(
      events,
      [
        .fetched(namespace(active)),
        .sent(namespace(active)),
        .preparedManualRetry(namespace(active)),
        .fetched(namespace(active)),
        .sent(namespace(active)),
      ]
    )
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
      enable: { .enabled },
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

  func testSyncDeletesZonesThatAnEarlierAttemptStaged() async throws {
    let unused = descriptor(
      generation: "32323232-3232-3232-3232-323232323232",
      metadata: "staged-unused-metadata",
      payload: "staged-unused-payload"
    )
    let active = descriptor(
      generation: "33333333-3333-3333-3333-333333333334",
      metadata: "staged-active-metadata",
      payload: "staged-active-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(active)
    let local = TestCloudCollectionLocalStore(active: namespace(active), hasSyncedBefore: true)
    await local.stageCleanup(unused.zones.union(active.zones))
    await server.createZones(unused.zones.union(active.zones))
    let coordinator = makeCollectionCoordinator(
      local: local, transport: transport, driver: TestCloudCollectionSyncDriver(),
      makeDescriptor: { active }
    )

    let status = try await coordinator.scheduleSynchronization()
    let cleanup = await local.state().cleanupZones
    let unusedMetadataRemains = await server.hasZone(unused.metadataZone)
    let unusedPayloadRemains = await server.hasZone(unused.payloadZone)
    let activeMetadataExists = await server.hasZone(active.metadataZone)
    let activePayloadExists = await server.hasZone(active.payloadZone)

    XCTAssertEqual(status, .scheduled(namespace(active)))
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
    let local = TestCloudCollectionLocalStore(active: namespace(invalid), hasSyncedBefore: true)
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

  func testKnownClientWithoutAnActiveStoreRequiresExplicitEnableBeforeCreatingAGeneration() async throws {
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
      makeDescriptor: {
        XCTFail("Only an explicit enable may create a collection")
        return CloudCollectionDescriptor.fresh(ownerName: "owner")
      }
    )

    let needsChoice = try await coordinator.synchronize()

    let events = await driver.events()
    let control = await server.controlDescriptor()
    XCTAssertEqual(needsChoice, .requiresEnable)
    XCTAssertNil(control)
    XCTAssertTrue(events.isEmpty)
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
    let localEvents = await local.events()
    XCTAssertEqual(status, .purged)
    XCTAssertTrue(state.hasSyncedBefore)
    XCTAssertNil(state.activeNamespace)
    XCTAssertTrue(state.keptAfterReset)
    XCTAssertEqual(localEvents, [.purged])
    XCTAssertTrue(events.isEmpty)
  }

  func testEncryptedDataResetReportedBySendPurgesTheCollection() async throws {
    let old = descriptor(
      generation: "90909090-9090-9090-9090-909090909090",
      metadata: "send-reset-metadata",
      payload: "send-reset-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    let local = TestCloudCollectionLocalStore(active: namespace(old), hasSyncedBefore: true)
    let driver = TestCloudCollectionSyncDriver()
    await driver.resetNextSend(.purged)
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: driver,
      makeDescriptor: { old }
    )

    let resetResult = try await coordinator.synchronize()

    let state = await local.state()
    let events = await driver.events()
    XCTAssertEqual(resetResult, .purged)
    XCTAssertNil(state.activeNamespace)
    XCTAssertTrue(state.keptAfterReset)
    XCTAssertEqual(events.filter { if case .sent = $0 { true } else { false } }.count, 1)
  }

  func testEncryptedDataResetPurgesEachDeviceWithoutSeedingFreshContent() async throws {
    let old = descriptor(
      generation: "91919191-9191-9191-9191-919191919191",
      metadata: "encrypted-old-metadata",
      payload: "encrypted-old-payload"
    )
    let server = FakeCloudServer()
    let firstTransport = FakeCloudControlTransport(server: server)
    let secondTransport = FakeCloudControlTransport(server: server)
    await firstTransport.seedControl(old)
    let firstLocal = TestCloudCollectionLocalStore(active: namespace(old), hasSyncedBefore: true)
    let secondLocal = TestCloudCollectionLocalStore(active: namespace(old), hasSyncedBefore: true)
    let firstDriver = TestCloudCollectionSyncDriver()
    let secondDriver = TestCloudCollectionSyncDriver()
    await firstDriver.resetNextFetch(.purged)
    await secondDriver.resetNextFetch(.purged)
    let first = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: firstLocal,
      transport: firstTransport,
      syncDriver: firstDriver,
      makeDescriptor: {
        XCTFail("A reset must not seed a new collection")
        return old
      }
    )
    let second = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: secondLocal,
      transport: secondTransport,
      syncDriver: secondDriver,
      makeDescriptor: {
        XCTFail("A reset must not seed a new collection")
        return old
      }
    )

    let firstResetResult = try await first.synchronize()
    let secondResetResult = try await second.synchronize()
    let firstState = await firstLocal.state()
    let secondState = await secondLocal.state()
    let firstDriverEvents = await firstDriver.events()
    let secondDriverEvents = await secondDriver.events()
    XCTAssertEqual(firstResetResult, .purged)
    XCTAssertEqual(secondResetResult, .purged)
    XCTAssertNil(firstState.activeNamespace)
    XCTAssertNil(secondState.activeNamespace)
    XCTAssertTrue(firstState.keptAfterReset)
    XCTAssertTrue(secondState.keptAfterReset)
    XCTAssertFalse(firstDriverEvents.contains { if case .sent = $0 { true } else { false } })
    XCTAssertFalse(secondDriverEvents.contains { if case .sent = $0 { true } else { false } })
  }

  func testPurgeKeepsSyncOffEvenAfterAnotherCollectionAppears() async throws {
    let old = descriptor(
      generation: "94949494-9494-9494-9494-949494949494",
      metadata: "off-old-metadata",
      payload: "off-old-payload"
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
      makeDescriptor: {
        XCTFail("Keeping sync off must not make a collection")
        return old
      }
    )

    let resetResult = try await coordinator.synchronize()
    let replacement = descriptor(
      generation: "94949494-9494-9494-9494-949494949496",
      metadata: "off-replacement-metadata",
      payload: "off-replacement-payload"
    )
    await transport.seedControl(replacement)
    let laterResult = try await coordinator.synchronize()
    let control = await server.controlDescriptor()
    let localState = await local.state()
    let driverEvents = await driver.events()
    XCTAssertEqual(resetResult, .purged)
    XCTAssertEqual(laterResult, .requiresEnable)

    XCTAssertEqual(control, replacement)
    XCTAssertNil(localState.activeNamespace)
    XCTAssertTrue(localState.keptAfterReset)
    XCTAssertTrue(driverEvents.isEmpty)
  }

  func testLegacyEncryptedResetMarkerKeepsBothStoresOnReopen() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("EncryptedResetRecovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = descriptor(
      generation: "94949494-9494-9494-9494-949494949495",
      metadata: "reopen-old-metadata",
      payload: "reopen-old-payload"
    )
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(old))
    let oldStoreID = try await persistence.snapshot().activeStore.id
    let oldLibrary = try await persistence.libraryForTransition(storeID: oldStoreID)
    let source = root.appendingPathComponent("reset-attachment.txt")
    let bytes = Data("attachment kept through reset".utf8)
    try bytes.write(to: source)
    let added = try await oldLibrary.perform(
      .add(
        content: "keep through encrypted reset",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    try await oldLibrary.reconcileCloudAttachments(
      namespaceKey: namespace(old).namespaceKey,
      metadataZoneName: old.metadataZone.name,
      metadataOwnerName: old.metadataZone.ownerName,
      payloadZoneName: old.payloadZone.name,
      payloadOwnerName: old.payloadZone.ownerName
    )
    let unavailableAttachmentID = UUID()
    try await oldLibrary.commitCloudAttachmentTransitions(
      namespaceKey: namespace(old).namespaceKey,
      transitions: [.remoteMetadataAccepted(
        metadata: CloudAttachmentMetadataValue(
          attachmentID: unavailableAttachmentID,
          snipID: snipID,
          position: 1,
          fileName: "not-downloaded.txt",
          contentType: "text/plain",
          byteCount: 10,
          sha256: Data(repeating: 1, count: 32),
          payloadIdentity: CloudTextStorageIdentity(
            zoneName: old.payloadZone.name,
            ownerName: old.payloadZone.ownerName,
            recordName: UUID().uuidString.lowercased()
          )
        ),
        metadataIdentity: CloudTextStorageIdentity(
          zoneName: old.metadataZone.name,
          ownerName: old.metadataZone.ownerName,
          recordName: "a-\(unavailableAttachmentID.uuidString.lowercased())"
        ),
        shadowData: Data("shadow".utf8),
        systemFields: Data("fields".utf8)
      )]
    )
    // A pre-#122 build already swapped to an empty local store and kept the old one as a
    // read-only recovery copy before it quit.
    try await persistence.seedEmptyActiveStore(namespace: nil)
    try LegacySyncModeFixture.makeRecoveryCopy(storeID: oldStoreID, inSyncModeRoot: root)
    let replacement = try await persistence.activeLibrary()
    _ = try await replacement.perform(.add(
      content: "edit in the replacement", origin: .quickEntry, source: nil,
      listID: SnipList.inbox.id, attachmentURLs: [], requestID: UUID(), now: Date()
    ), sortedBy: .manual)
    try JSONEncoder().encode(CollectionStateFile(version: 1, hasSyncedBefore: true,
      cleanupZones: [], deletionState: nil,
      encryptedDataReset: .init(id: UUID(), priorNamespace: namespace(old), recoveryStoreID: oldStoreID)
    )).write(to: collectionStateURL(at: root))

    let reopened = try SwiftDataSyncModePersistence(rootURL: root)
    let local = try SwiftDataCloudCollectionLocalStore(rootURL: root, persistence: reopened)
    let state = try await local.state()
    let library = try await reopened.activeLibrary()
    let active = try await library.checkedSnapshot(sortedBy: .manual)

    XCTAssertTrue(state.keptAfterReset)
    XCTAssertNil(state.activeNamespace)
    XCTAssertEqual(Set(active.snips.map(\.content)),
      ["keep through encrypted reset", "edit in the replacement"])
    let kept = try XCTUnwrap(active.snips.first { $0.id == snipID })
    XCTAssertEqual(kept.attachments.count, 2)
    let path = try XCTUnwrap(active.attachmentURLs[kept.attachments[0].id])
    XCTAssertEqual(try Data(contentsOf: path), bytes)
    _ = try await library.perform(.update(id: snipID, content: "updated after reopen",
      attachmentURLs: nil, expectedUpdatedAt: nil, now: Date()), sortedBy: .manual)
  }

  func testInterruptedMissingControlPurgeKeepsTheRetiredSourceOnReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudLegacyPurge-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(descriptor))
    let source = try await persistence.snapshot().activeStore
    let library = try await persistence.libraryForTransition(storeID: source.id)
    _ = try await library.perform(.add(content: "before the purge", origin: .quickEntry,
      source: nil, listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: Date()),
      sortedBy: .manual)
    // The previous purge swap marked its source read-only before selecting an empty local store.
    try await persistence.seedEmptyActiveStore(namespace: nil)
    let sourceDirectory = try LegacySyncModeFixture.storeDirectory(storeID: source.id, inSyncModeRoot: root) {
      $0["lifecycle"] = "deleting"
    }
    try LegacySyncModeFixture.markReadOnly(storeDirectory: sourceDirectory, quarantined: true)

    let reopened = try SwiftDataSyncModePersistence(rootURL: root)
    let storage = try await reopened.snapshot()
    XCTAssertEqual(storage.activeStore.id, source.id)
    XCTAssertTrue(storage.keptAfterCloudReset)
    let writable = try await reopened.activeLibrary()
    let snapshot = try await writable.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(snapshot.snips.first)
    XCTAssertEqual(snip.content, "before the purge")
    _ = try await writable.perform(.update(id: snip.id, content: "edited after reopen",
      attachmentURLs: nil, expectedUpdatedAt: nil, now: Date()), sortedBy: .manual)
  }

  func testModeLifecycleReopensAfterPurgeAndRequiresExplicitEnable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("EncryptedResetLifecycleReopen-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = descriptor(
      generation: "96969696-9696-9696-9696-969696969696",
      metadata: "lifecycle-old-metadata",
      payload: "lifecycle-old-payload"
    )
    let fresh = descriptor(
      generation: "97979797-9797-9797-9797-979797979797",
      metadata: "lifecycle-fresh-metadata",
      payload: "lifecycle-fresh-payload"
    )
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(old))
    let modeStore = SnipSyncModeStore(persistence)
    let source = try JSONSnipLibrary(
      fileURL: root.appendingPathComponent("source.json", isDirectory: false)
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    await transport.removeControl()
    func lifecycle() -> SnipSnapICloudSyncLifecycle {
      SnipSnapICloudSyncLifecycle(
        rootURL: root,
        sourceLibrary: source,
        syncModeStore: modeStore,
        cloudScope: "private",
        accountLineage: "account-a",
        ownerName: "owner",
        controlTransport: transport,
        makeRecordTransport: { context in
          FakeCloudRecordTransport(server: server, namespace: context.namespace)
        },
        makeDescriptor: { fresh }
      )
    }

    let firstResult = try await lifecycle().synchronize()
    let reopened = lifecycle()
    let controlBeforeChoice = await server.controlDescriptor()
    let reopenedResult = try await reopened.synchronize()
    let enableResult = try await reopened.enableICloudSync()

    XCTAssertEqual(firstResult, .iCloudDataReset)
    XCTAssertNil(controlBeforeChoice)
    XCTAssertEqual(reopenedResult, .noChange)
    XCTAssertEqual(enableResult, .enabled)
  }

  func testModeLifecycleKeepsCloudStoreLocallyBeforeSyncWhenAppleAccountChanges() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudAccountLifecycleGate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let active = descriptor(
      generation: "91919191-9191-9191-9191-919191919191",
      metadata: "account-gate-metadata",
      payload: "account-gate-payload"
    )
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(active))
    let source = try JSONSnipLibrary(
      fileURL: root.appendingPathComponent("source.json", isDirectory: false)
    )
    let server = FakeCloudServer()
    let control = FakeCloudControlTransport(server: server)
    await control.seedControl(active)
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root,
      sourceLibrary: source,
      syncModeStore: SnipSyncModeStore(persistence),
      cloudScope: "private",
      accountLineage: "account-a",
      accountStateSource: FixedICloudAccountStateSource(
        state: .available(accountLineage: "account-b")
      ),
      ownerName: "owner",
      controlTransport: control,
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: { active }
    )

    let result = try await lifecycle.synchronize()
    XCTAssertEqual(result, .iCloudAccountChanged)

    let storage = try await persistence.snapshot()
    XCTAssertEqual(storage.activeStore.kind, .localOnly)
    XCTAssertEqual(storage.attentionReason, .accountChanged)
    XCTAssertEqual(storage.activeStore.quarantinedNamespace?.accountLineage, "account-a")
  }

  func testMailboxAccountChangeStopsTheActiveEngineAndKeepsItsLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let previous = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(previous))
    let source = try await persistence.activeLibrary()
    _ = try await source.perform(.add(content: "keep from the old account", origin: .quickEntry,
      source: nil, listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(),
      now: .distantPast), sortedBy: .manual)
    let control = FakeCloudControlTransport(server: FakeCloudServer())
    await control.seedControl(previous)
    let account = MutableCollectionAccountStateSource("account-a")
    let records = LifecycleAutomaticTransportProbe()
    let stopped = expectation(description: "Engine account event stops sync")
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root, sourceLibrary: source, syncModeStore: SnipSyncModeStore(persistence),
      cloudScope: "private", accountLineage: "account-a", accountStateSource: account,
      ownerName: "owner", controlTransport: control, makeRecordTransport: { _ in records },
      makeDescriptor: { previous }, automaticResultHandler: {
        if $0 == .iCloudAccountChanged { stopped.fulfill() }
      }
    )
    _ = try await lifecycle.synchronize()
    await account.setLineage("account-b")
    await control.removeControl()
    let earlierBatch = CloudFetchedBatch(id: UUID(), items: [], engineState: nil)
    await records.enqueueAccountChange(after: .fetched(earlierBatch))
    await fulfillment(of: [stopped], timeout: 5)
    let snapshot = try await source.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(snapshot.snips.map(\.content), ["keep from the old account"])
    let storage = try await persistence.snapshot()
    XCTAssertEqual(storage.activeStore.kind, .localOnly)
    let events = await records.events()
    XCTAssertTrue(events.contains("reset"))
    XCTAssertFalse(events.contains("sent"))
  }

  func testAutomaticSchedulingDoesNoCloudWorkWhileAccountIsTemporarilyUnavailable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudAutomaticAccountPause-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let active = descriptor(
      generation: "92929292-9292-9292-9292-929292929292",
      metadata: "account-pause-metadata",
      payload: "account-pause-payload"
    )
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(active))
    let source = try JSONSnipLibrary(
      fileURL: root.appendingPathComponent("source.json", isDirectory: false)
    )
    let server = FakeCloudServer()
    let control = FakeCloudControlTransport(server: server)
    let records = FakeCloudRecordTransport(server: server, namespace: namespace(active))
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root,
      sourceLibrary: source,
      syncModeStore: SnipSyncModeStore(persistence),
      cloudScope: "private",
      accountLineage: "account-a",
      accountStateSource: FixedICloudAccountStateSource(state: .temporarilyUnavailable),
      ownerName: "owner",
      controlTransport: control,
      makeRecordTransport: { _ in records },
      makeDescriptor: { active }
    )

    do {
      try await lifecycle.scheduleAutomaticSync()
      XCTFail("Automatic sync must pause while the Apple Account is unavailable")
    } catch {
      XCTAssertEqual(error as? ICloudAccountGateError, .temporarilyUnavailable)
    }
    let recordEvents = await records.events()
    XCTAssertEqual(recordEvents, [])
    XCTAssertEqual(
      automaticSyncResult(for:
        ICloudAccountGateError.noAccount
      ),
      .iCloudSignedOut
    )
    XCTAssertEqual(
      automaticSyncResult(for:
        ICloudAccountGateError.accountChanged
      ),
      .iCloudAccountChanged
    )
  }

  func testEnableDoesNotBindACollectionAfterTheAppleAccountChangesDuringBootstrap() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudEnableAccountRace-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let fresh = descriptor(
      generation: "92929292-9292-9292-9292-929292929292",
      metadata: "enable-account-race-metadata",
      payload: "enable-account-race-payload"
    )
    let source = try JSONSnipLibrary(
      fileURL: root.appendingPathComponent("source.json", isDirectory: false)
    )
    let account = MutableCollectionAccountStateSource("account-a")
    let server = FakeCloudServer()
    let control = FakeCloudControlTransport(server: server)
    await control.pauseNextControlSave()
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root,
      sourceLibrary: source,
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "account-a",
      accountStateSource: account,
      ownerName: "owner",
      controlTransport: control,
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: { fresh }
    )

    let enable = Task { try await lifecycle.enableICloudSync() }
    await control.waitUntilControlSavePauses()
    await account.setLineage("account-b")
    await control.resumeControlSave()

    do {
      _ = try await enable.value
      XCTFail("Enable must stop when the Apple Account changes")
    } catch {
      XCTAssertEqual(error as? ICloudAccountGateError, .accountChanged)
    }
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    let storage = try await persistence.snapshot()
    XCTAssertEqual(storage.activeStore.kind, .localOnly)
    XCTAssertNil(storage.activeStore.namespace)
  }

  func testExplicitEnableAfterPurgeMergesTheKeptLibraryIntoAFreshGeneration() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("EncryptedResetLifecycleEnable-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = descriptor(
      generation: "98989898-9898-9898-9898-989898989898",
      metadata: "enable-again-old-metadata",
      payload: "enable-again-old-payload"
    )
    let fresh = descriptor(
      generation: "99999999-9999-9999-9999-999999999999",
      metadata: "enable-again-fresh-metadata",
      payload: "enable-again-fresh-payload"
    )
    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    try await persistence.seedEmptyActiveStore(namespace: binding(old))
    let oldLibrary = try await persistence.activeLibrary()
    let added = try await oldLibrary.perform(
      .add(
        content: "unresolved local draft",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    let keptSnip = try XCTUnwrap(added.snapshot.snips.first)
    let oldStoreID = try await persistence.snapshot().activeStore.id
    let oldStore = try await persistence.libraryForTransition(storeID: oldStoreID)
    var remoteSnip = keptSnip
    remoteSnip.content = "kept local snip"
    let serverRecord = try CloudKitRecordMapper.snapshot(
      CloudKitRecordMapper.record(for: CloudFullRecordCodec.snipDraft(remoteSnip, in: old.metadataZone))
    )
    let cloud = CloudFullSyncPersistence(library: oldStore, namespace: namespace(old),
      dataZone: old.metadataZone, payloadZone: old.payloadZone)
    let change = CloudFetchedBatch(id: UUID(), items: [.record(serverRecord)], engineState: nil)
    try await cloud.stage(.fetched(change))
    try await cloud.applyStaged(change.id)
    let missingID = UUID()
    try await oldStore.commitCloudAttachmentTransitions(
      namespaceKey: namespace(old).namespaceKey,
      transitions: [.remoteMetadataAccepted(
        metadata: CloudAttachmentMetadataValue(
          attachmentID: missingID, snipID: keptSnip.id, position: 0, fileName: "evicted.txt",
          contentType: "text/plain", byteCount: 3, sha256: Data(repeating: 1, count: 32),
          payloadIdentity: CloudTextStorageIdentity(zoneName: old.payloadZone.name,
            ownerName: old.payloadZone.ownerName, recordName: UUID().uuidString.lowercased())),
        metadataIdentity: CloudTextStorageIdentity(zoneName: old.metadataZone.name,
          ownerName: old.metadataZone.ownerName, recordName: "a-\(missingID.uuidString.lowercased())"),
        shadowData: Data(), systemFields: Data()
      )]
    )
    try Data("1".utf8).write(to: persistence.initialImportMarkerURL)
    let modeStore = SnipSyncModeStore(persistence)
    let source = try JSONSnipLibrary(
      fileURL: root.appendingPathComponent("source.json", isDirectory: false)
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    func lifecycle() -> SnipSnapICloudSyncLifecycle {
      SnipSnapICloudSyncLifecycle(
        rootURL: root,
        sourceLibrary: source,
        syncModeStore: modeStore,
        cloudScope: "private",
        accountLineage: "account-a",
        ownerName: "owner",
        controlTransport: transport,
        makeRecordTransport: { context in
          FakeCloudRecordTransport(server: server, namespace: context.namespace)
        },
        makeDescriptor: { fresh }
      )
    }
    await transport.seedControl(old)
    await transport.removeControl()
    let first = lifecycle()
    let purgeResult = try await first.synchronize()
    let localLibrary = try await persistence.activeLibrary()
    _ = try await localLibrary.perform(
      .add(
        content: "new local work",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )

    await transport.seedControl(old)
    let reopened = lifecycle()
    let enable = try await reopened.enableICloudSync()
    XCTAssertEqual(enable, .enabled)
    _ = try await reopened.retrySynchronization()
    let activeSnapshot = try await persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
    let cloudText = await server.storedTextValues()
    let oldRecords = await server.storedRecordTypes(in: old.metadataZone)
    XCTAssertTrue(oldRecords.isEmpty)

    let state = try await SwiftDataCloudCollectionLocalStore(
      rootURL: root,
      persistence: persistence
    ).state()
    XCTAssertEqual(purgeResult, .iCloudDataReset)
    XCTAssertEqual(state.activeNamespace, namespace(fresh))
    XCTAssertFalse(state.keptAfterReset)
    XCTAssertEqual(Set(activeSnapshot.snips.map(\.content)), ["kept local snip", "new local work"])
    XCTAssertEqual(cloudText, ["new local work"], "The unresolved snip stays off the wire")
    let keptAfterEnable = try XCTUnwrap(activeSnapshot.snips.first { $0.id == keptSnip.id })
    XCTAssertEqual(keptAfterEnable.attachments.map(\.id), [missingID])
    XCTAssertNil(activeSnapshot.attachmentURLs[missingID])
    let active = try await reopened.activeLibrary()
    let scope = try XCTUnwrap(active.recoveryScope)
    let recovery = try await active.library.recoverySnapshot(in: scope)
    let choice = try XCTUnwrap(recovery.pendingSnips.first)
    XCTAssertEqual(choice.recovered.content, "unresolved local draft")
    let resolved = try await active.library.resolveRecovery(choice.id, in: scope, choice: .useRecovered)
    XCTAssertEqual(resolved.snips.first { $0.id == keptSnip.id }?.content, "unresolved local draft")

    _ = try await reopened.retrySynchronization()
    let syncedAfterReview = await server.storedTextValues()
    XCTAssertEqual(Set(syncedAfterReview), ["unresolved local draft", "new local work"])
    try await reopened.disableICloudSync(.useCurrentCache)
    let local = try await reopened.activeLibrary().library.checkedSnapshot(sortedBy: .manual)
    let localSnip = try XCTUnwrap(local.snips.first { $0.id == keptSnip.id })
    XCTAssertEqual(localSnip.attachments.map(\.id), [missingID])
    XCTAssertNil(local.attachmentURLs[missingID])
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
    XCTAssertEqual(status, .purged)
    XCTAssertEqual(events, [.fetched(namespace(old))])
    let state = await local.state()
    XCTAssertTrue(state.keptAfterReset)
  }

  func testCollectionStateFileStaysReadableAcrossBuilds() async throws {
    let newRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudCollectionStateNew-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: newRoot) }
    _ = try SwiftDataCloudCollectionLocalStore(rootURL: newRoot)
    let newFile = try String(contentsOf: collectionStateURL(at: newRoot), encoding: .utf8)
    XCTAssertEqual(newFile, #"{"cleanupZones":[],"hasSyncedBefore":false,"version":1}"#)

    let zone = CloudZoneID(name: "legacy-cleanup", ownerName: "owner")
    // Builds before this one wrote no deletion state, `none`, or the `pending` and `completed`
    // marks of an unfinished Delete Synced Content.
    let legacyFiles = [
      #"{"cleanupZones":[{"name":"legacy-cleanup","ownerName":"owner"}],"hasSyncedBefore":true,"version":1}"#,
      #"{"cleanupZones":[{"name":"legacy-cleanup","ownerName":"owner"}],"deletionState":"none","hasSyncedBefore":true,"version":1}"#,
      #"{"cleanupZones":[{"name":"legacy-cleanup","ownerName":"owner"}],"deletionState":"pending","hasSyncedBefore":true,"version":1}"#,
      #"{"cleanupZones":[{"name":"legacy-cleanup","ownerName":"owner"}],"deletionState":"completed","hasSyncedBefore":true,"version":1}"#,
    ]
    for legacyFile in legacyFiles {
      let legacyRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudCollectionStateLegacy-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: legacyRoot) }
      try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
      try Data(legacyFile.utf8).write(to: collectionStateURL(at: legacyRoot))
      let legacy = try SwiftDataCloudCollectionLocalStore(rootURL: legacyRoot)
      let opened = try await legacy.state()
      XCTAssertEqual(opened.cleanupZones, [zone], legacyFile)
      XCTAssertTrue(opened.hasSyncedBefore, legacyFile)
      try await legacy.finishCleanup([zone])
      let rewritten = try Data(contentsOf: collectionStateURL(at: legacyRoot))
      let decoded = try JSONDecoder().decode(CollectionStateFile.self, from: rewritten)
      let object = try JSONSerialization.jsonObject(with: rewritten)
      let keys = try XCTUnwrap(object as? [String: Any]).keys
      XCTAssertEqual(decoded.version, 1, legacyFile)
      XCTAssertTrue(decoded.hasSyncedBefore, legacyFile)
      XCTAssertTrue(decoded.cleanupZones.isEmpty, legacyFile)
      XCTAssertNil(decoded.encryptedDataReset, legacyFile)
      XCTAssertNil(decoded.deletionState, legacyFile)
      XCTAssertTrue(Set(keys).isSubset(of: CollectionStateFile.keys), legacyFile)
    }
  }

  func testSyncHistorySurvivesPurgeAndReopen() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudSyncHistory-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let active = descriptor(
      generation: "61616161-6161-6161-6161-616161616161",
      metadata: "history-metadata",
      payload: "history-payload"
    )
    let cleanup = CloudZoneID(name: "history-cleanup", ownerName: "owner")
    let first = try SwiftDataCloudCollectionLocalStore(rootURL: root)
    let initial = try await first.state()
    XCTAssertFalse(initial.hasSyncedBefore)
    try await first.stageCleanup([cleanup])

    let persistence = try SwiftDataSyncModePersistence(rootURL: root)
    let staged = try SwiftDataCloudCollectionLocalStore(rootURL: root, persistence: persistence)
    let stagedState = try await staged.state()
    XCTAssertFalse(stagedState.hasSyncedBefore)
    XCTAssertEqual(stagedState.cleanupZones, [cleanup])

    try await persistence.seedEmptyActiveStore(namespace: binding(active))
    let activeState = try await staged.state()
    XCTAssertTrue(activeState.hasSyncedBefore)
    XCTAssertEqual(activeState.activeNamespace, namespace(active))

    let stopped = try await staged.stopAfterDataReset(in: namespace(active))
    XCTAssertTrue(stopped)
    let purgedState = try await staged.state()
    XCTAssertTrue(purgedState.hasSyncedBefore)
    XCTAssertNil(purgedState.activeNamespace)

    let reopened = try reopenedCollectionStore(at: root)
    let reopenedState = try await reopened.state()
    XCTAssertTrue(reopenedState.hasSyncedBefore)
    XCTAssertNil(reopenedState.activeNamespace)
    XCTAssertEqual(reopenedState.cleanupZones, [cleanup])
  }

  func testZoneCleanupFailureFailsTheSyncAndRetriesLater() async throws {
    let active = descriptor(
      generation: "64646464-6464-6464-6464-646464646464",
      metadata: "cleanup-failure-active-metadata",
      payload: "cleanup-failure-active-payload"
    )
    let leftover = descriptor(
      generation: "65656565-6565-6565-6565-656565656565",
      metadata: "cleanup-failure-leftover-metadata",
      payload: "cleanup-failure-leftover-payload"
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(active)
    await server.createZones(leftover.zones)
    let local = TestCloudCollectionLocalStore(active: namespace(active), hasSyncedBefore: true)
    await local.stageCleanup(leftover.zones)
    let driver = TestCloudCollectionSyncDriver()
    let coordinator = makeCollectionCoordinator(
      local: local,
      transport: transport,
      driver: driver,
      makeDescriptor: { active }
    )

    await transport.failNextZoneDelete()
    do {
      let status = try await coordinator.synchronize()
      XCTFail("Expected the failed zone cleanup to fail the sync, got \(status)")
    } catch {
      XCTAssertEqual(error as? CloudTransportError, .sendFailed)
    }
    let failedState = await local.state()
    let failedDriverEvents = await driver.events()
    let failedTransportEvents = await transport.events()
    let leftoverKeptMetadata = await server.hasZone(leftover.metadataZone)
    XCTAssertEqual(failedState.cleanupZones, leftover.zones)
    XCTAssertEqual(failedState.activeNamespace, namespace(active))
    XCTAssertTrue(failedDriverEvents.isEmpty)
    XCTAssertFalse(failedTransportEvents.contains(.deletedZones(leftover.zones)))
    XCTAssertTrue(leftoverKeptMetadata)

    let status = try await coordinator.synchronize()
    let cleanedState = await local.state()
    let transportEvents = await transport.events()
    let leftoverMetadataRemains = await server.hasZone(leftover.metadataZone)
    let leftoverPayloadRemains = await server.hasZone(leftover.payloadZone)
    let activeMetadataExists = await server.hasZone(active.metadataZone)
    let activePayloadExists = await server.hasZone(active.payloadZone)
    XCTAssertEqual(status, .on(namespace(active)))
    XCTAssertTrue(cleanedState.cleanupZones.isEmpty)
    XCTAssertTrue(transportEvents.contains(.deletedZones(leftover.zones)))
    XCTAssertFalse(leftoverMetadataRemains)
    XCTAssertFalse(leftoverPayloadRemains)
    XCTAssertTrue(activeMetadataExists)
    XCTAssertTrue(activePayloadExists)
  }

  private func makeCollectionCoordinator(
    local: any CloudCollectionLocalStore,
    transport: FakeCloudControlTransport,
    driver: TestCloudCollectionSyncDriver,
    makeDescriptor: @escaping CloudCollectionCoordinator.DescriptorFactory
  ) -> CloudCollectionCoordinator {
    CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      localStore: local,
      transport: transport,
      syncDriver: driver,
      makeDescriptor: makeDescriptor
    )
  }

  private func reopenedCollectionStore(at root: URL) throws -> SwiftDataCloudCollectionLocalStore {
    try SwiftDataCloudCollectionLocalStore(
      rootURL: root,
      persistence: SwiftDataSyncModePersistence(rootURL: root)
    )
  }

  private func collectionStateURL(at root: URL) -> URL {
    root.appendingPathComponent("cloud-collection-state.json", isDirectory: false)
  }

  private func decodedCollectionStateFile(at root: URL) throws -> CollectionStateFile {
    try JSONDecoder().decode(
      CollectionStateFile.self,
      from: Data(contentsOf: collectionStateURL(at: root))
    )
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

/// Mirrors the `cloud-collection-state.json` keys that any build wrote. Older builds decode it.
private struct CollectionStateFile: Codable {
  struct LegacyReset: Codable {
    let id: UUID
    let priorNamespace: CloudSyncNamespace
    let recoveryStoreID: UUID?
  }

  static let keys: Set<String> = [
    "version", "hasSyncedBefore", "cleanupZones", "deletionState", "encryptedDataReset",
  ]

  let version: Int
  let hasSyncedBefore: Bool
  let cleanupZones: Set<CloudZoneID>
  let deletionState: String?
  let encryptedDataReset: LegacyReset?
}

private actor MutableCollectionAccountStateSource: ICloudAccountStateSource {
  private var lineage: String

  init(_ lineage: String) { self.lineage = lineage }

  func currentAccountState() -> ICloudAccountState {
    .available(accountLineage: lineage)
  }

  func setLineage(_ lineage: String) { self.lineage = lineage }
}

private actor LifecycleCallCounter {
  private var count = 0
  func record() { count += 1 }
  func value() -> Int { count }
}

private actor PausingLifecycleCallCounter {
  private var count = 0
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstRelease: CheckedContinuation<Void, Never>?

  func run() async {
    count += 1
    if count == 1 {
      for waiter in startWaiters { waiter.resume() }
      startWaiters = []
      await withCheckedContinuation { firstRelease = $0 }
    }
  }

  func waitUntilFirstCallStarts() async {
    if count > 0 { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func releaseFirstCall() { firstRelease?.resume() }
  func value() -> Int { count }
}

private actor TestCloudCollectionLocalStore: CloudCollectionLocalStore {
  enum Event: Equatable {
    case stagedCleanup(Set<CloudZoneID>)
    case finishedCleanup(Set<CloudZoneID>)
    case purged
    case seededRecovery(CloudSyncNamespace)
  }
  private var active: CloudSyncNamespace?
  private var known: Bool
  private var cleanup: Set<CloudZoneID> = []
  private var keptAfterReset = false
  private var log: [Event] = []

  init(active: CloudSyncNamespace?, hasSyncedBefore: Bool) {
    self.active = active
    known = hasSyncedBefore
  }

  func state() -> CloudCollectionLocalState {
    CloudCollectionLocalState(
      hasSyncedBefore: known,
      activeNamespace: active,
      cleanupZones: cleanup,
      keptAfterReset: keptAfterReset
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

  func stopAfterDataReset(in namespace: CloudSyncNamespace) -> Bool {
    guard active == namespace else { return false }
    active = nil
    keptAfterReset = true
    known = true
    log.append(.purged)
    return true
  }


  func activeNamespace() -> CloudSyncNamespace? { active }
  func events() -> [Event] { log }
}

private actor TerminalSetupControlTransport: CloudCollectionControlTransport {
  func fetchControl() async throws -> CloudCollectionControlRecord? {
    throw CloudCollectionError.invalidDescriptor
  }

  func createZones(_ zones: Set<CloudZoneID>) async throws {}

  func saveControl(
    _ descriptor: CloudCollectionDescriptor,
    replacing version: Data?
  ) async throws -> CloudCollectionControlSaveResult {
    throw CloudCollectionError.invalidDescriptor
  }

  func deleteZones(_ zones: Set<CloudZoneID>) async throws {}
}

private actor OfflineThenOnlineControlTransport: CloudCollectionControlTransport {
  private let base: FakeCloudControlTransport
  private var isOffline = true

  init(server: FakeCloudServer) {
    base = FakeCloudControlTransport(server: server)
  }

  func goOnline() { isOffline = false }

  func fetchControl() async throws -> CloudCollectionControlRecord? {
    guard !isOffline else { throw CloudSyncIssueError(.waitingForConnection) }
    return try await base.fetchControl()
  }

  func createZones(_ zones: Set<CloudZoneID>) async throws {
    try await base.createZones(zones)
  }

  func saveControl(
    _ descriptor: CloudCollectionDescriptor,
    replacing version: Data?
  ) async throws -> CloudCollectionControlSaveResult {
    try await base.saveControl(descriptor, replacing: version)
  }

  func deleteZones(_ zones: Set<CloudZoneID>) async throws {
    try await base.deleteZones(zones)
  }
}

private actor TestCloudCollectionSyncDriver: CloudCollectionSyncDriver {
  enum Event: Equatable {
    case scheduled(CloudSyncNamespace)
    case preparedManualRetry(CloudSyncNamespace)
    case fetched(CloudSyncNamespace)
    case sent(CloudSyncNamespace)
  }
  private var values: [Event] = []
  private var nextFetchResult: CloudCollectionFetchResult = .fetched(nil)
  private var nextSendResult: CloudCollectionSendResult = .sent
  private var nextFetchIssue: SyncedContentSyncIssue?
  private var nextSendIssue: SyncedContentSyncIssue?
  private var nextFetchIsolation: ICloudAccountGateError?
  private var shouldPauseNextFetch = false
  private var pausedFetch = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var fetchRelease: CheckedContinuation<Void, Never>?

  func fetch(_ context: CloudCollectionSyncContext) async throws -> CloudCollectionFetchResult {
    let namespace = context.namespace
    values.append(.fetched(namespace))
    if shouldPauseNextFetch {
      shouldPauseNextFetch = false
      pausedFetch = true
      pauseWaiters.forEach { $0.resume() }
      pauseWaiters = []
      await withCheckedContinuation { fetchRelease = $0 }
    }
    if let nextFetchIssue {
      self.nextFetchIssue = nil
      throw CloudSyncIssueError(nextFetchIssue)
    }
    if let nextFetchIsolation {
      self.nextFetchIsolation = nil
      throw nextFetchIsolation
    }
    defer { nextFetchResult = .fetched(nil) }
    return nextFetchResult
  }
  func prepareAutomaticSync(_ context: CloudCollectionSyncContext) {
    values.append(.scheduled(context.namespace))
  }
  func prepareManualRetry(_ context: CloudCollectionSyncContext) {
    values.append(.preparedManualRetry(context.namespace))
  }
  func send(_ context: CloudCollectionSyncContext) throws -> CloudCollectionSendResult {
    values.append(.sent(context.namespace))
    if let nextSendIssue {
      self.nextSendIssue = nil
      throw CloudSyncIssueError(nextSendIssue)
    }
    defer { nextSendResult = .sent }
    return nextSendResult
  }
  func events() -> [Event] { values }
  func resetNextFetch(_ result: CloudCollectionFetchResult) { nextFetchResult = result }
  func resetNextSend(_ result: CloudCollectionSendResult) { nextSendResult = result }
  func failNextFetch(_ issue: SyncedContentSyncIssue) { nextFetchIssue = issue }
  func failNextSend(_ issue: SyncedContentSyncIssue) { nextSendIssue = issue }
  func isolateNextFetch(_ error: ICloudAccountGateError) { nextFetchIsolation = error }

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

private actor LifecycleAutomaticTransportProbe: CloudRecordTransport,
  CloudAutomaticSyncConfiguring, CloudAutomaticSyncScheduling {
  private let namespace: CloudSyncNamespace?
  private var recorded: [String] = []
  private let mailbox = CloudRecordTransportMailbox()
  private var sendGate: RecordSendGate?
  private var workCompleted: (@Sendable () -> Void)?

  init(namespace: CloudSyncNamespace? = nil) {
    self.namespace = namespace
  }

  func onNextWorkCompletion(_ action: @escaping @Sendable () -> Void) { workCompleted = action }
  func authorizeSend() async throws { try await sendGate?() }
  func reset() { recorded.append("reset"); mailbox.reset() }
  private func didCompleteWork() { workCompleted?(); workCompleted = nil }
  func enqueue(_ batch: CloudSyncBatch) {
    mailbox.append(.batch(CloudPendingBatch(batch: batch, outbound: nil)))
  }
  func enqueueAccountChange(after batch: CloudSyncBatch) {
    enqueue(batch)
    mailbox.append(.accountChange(UUID()))
  }
  func pendingEvent() -> CloudRecordTransportEvent? { mailbox.first }
  func events() -> [String] { recorded }
  func start(state: CloudEngineStateEnvelope?) { recorded.append("started") }
  func configureAutomaticSync(
    workAvailableHandler: @escaping WorkAvailableHandler,
    recordSendGate: @escaping RecordSendGate
  ) {
    sendGate = recordSendGate
    mailbox.configure { [weak self] in
      await workAvailableHandler()
      await self?.didCompleteWork()
    }
  }
  func scheduleAutomaticSync(_ batch: CloudOutboundBatch) { recorded.append("scheduled") }
  func fetch(scope: CloudFetchScope) throws -> CloudFetchedBatch {
    recorded.append("fetched")
    guard let namespace else { throw CloudTransportError.syncAlreadyRunning }
    return CloudFetchedBatch(
      id: UUID(),
      items: [],
      zoneEvents: namespace.zones.map(CloudZoneEvent.fetched),
      engineState: CloudEngineStateEnvelope(
        namespace: namespace,
        serialization: Data("completed-fetch".utf8),
        requiresInitialFetch: false
      )
    )
  }
  func send(_ batch: CloudOutboundBatch) throws -> CloudSentBatch {
    recorded.append("sent")
    throw CloudTransportError.syncAlreadyRunning
  }
  func confirmApplied(_ batchID: UUID) throws { _ = try mailbox.confirm(batchID) }
  func fetchRecord(_ id: CloudRecordID, fields: Set<String>) -> CloudRecordSnapshot? { nil }
  func fetchAsset(
    _ id: CloudRecordID, field: String, destination: CloudAssetDestination
  ) -> CloudAssetReceipt? { nil }
}

private actor CollectionWorkPause {
  private var suspended = false
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?
  func suspend(onEntry: @Sendable () -> Void = {}) async {
    if released { return }
    suspended = true
    waiters.forEach { $0.resume() }
    waiters = []
    await withCheckedContinuation {
      release = $0
      onEntry()
    }
  }
  func waitUntilSuspended() async {
    if suspended { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func resume() { released = true; release?.resume(); release = nil }
}

private actor PausingCollectionControlTransport: CloudCollectionControlTransport {
  private let base: FakeCloudControlTransport
  private var pause: (CollectionWorkPause, @Sendable () -> Void)?

  init(base: FakeCloudControlTransport) { self.base = base }

  func pauseNextFetch(_ value: CollectionWorkPause, onEntry: @escaping @Sendable () -> Void) {
    pause = (value, onEntry)
  }

  func fetchControl() async -> CloudCollectionControlRecord? {
    let next = pause
    pause = nil
    let record = await base.fetchControl()
    if let (pause, onEntry) = next { await pause.suspend(onEntry: onEntry) }
    return record
  }

  func createZones(_ zones: Set<CloudZoneID>) async { await base.createZones(zones) }

  func saveControl(
    _ descriptor: CloudCollectionDescriptor, replacing version: Data?
  ) async -> CloudCollectionControlSaveResult {
    await base.saveControl(descriptor, replacing: version)
  }

  func deleteZones(_ zones: Set<CloudZoneID>) async throws { try await base.deleteZones(zones) }
}

private final class CollectionResultRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [SnipSnapCloudSyncResult] = []
  func append(_ value: SnipSnapCloudSyncResult) { lock.withLock { results.append(value) } }
  func values() -> [SnipSnapCloudSyncResult] { lock.withLock { results } }
}
