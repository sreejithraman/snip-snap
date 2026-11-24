import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import XCTest

@testable import SnipSnapCloud

final class CloudPendingICloudEnableTests: XCTestCase {
  private var root: URL!
  private var syncRoot: URL!
  private var marker: URL { syncRoot.appendingPathComponent("icloud-sync-enable-pending") }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PendingICloudEnable-\(UUID().uuidString)")
    syncRoot = root.appendingPathComponent("SyncMode", isDirectory: true)
  }

  override func tearDownWithError() throws {
    setMarkerLocked(false)
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: Marker removal failures

  func testImmutableMarkerBlocksRemoval() throws {
    try writeMarker("pending")
    setMarkerLocked(true)

    XCTAssertThrowsError(try FileManager.default.removeItem(at: marker)) { error in
      XCTAssertTrue(error is CocoaError, "Unexpected error: \(error)")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
  }

  func testEnableThatSwitchesToICloudReportsEnabledWhenMarkerCleanupFails() async throws {
    let (lifecycle, _, _) = try await enabledICloudSyncWithPendingMarker()

    await assertMarkerRemovalFails("A sync must not finish while the pending marker remains") {
      try await lifecycle.synchronize()
    }
    XCTAssertEqual(try Data(contentsOf: marker), Data("pending".utf8))

    setMarkerLocked(false)
    let finished = try await lifecycle.synchronize()
    XCTAssertEqual(finished, .iCloudSyncEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

    let next = try await lifecycle.synchronize()
    XCTAssertNotEqual(next, .iCloudSyncEnabled)
    if case .iCloudSyncSettingUp = next { XCTFail("Setup ran again: \(next)") }
  }

  func testRelaunchWithICloudSyncOnAndPendingMarkerFinishesCleanupOnSync() async throws {
    let (_, source, server) = try await enabledICloudSyncWithPendingMarker()
    let restarted = startupSettings()
    XCTAssertEqual(restarted.mode, .iCloudSync)
    XCTAssertEqual(restarted.state, .ready)
    let relaunched = try relaunchedLifecycle(source: source, server: server)

    await assertMarkerRemovalFails("A sync must not finish while the pending marker remains") {
      try await relaunched.synchronize()
    }
    XCTAssertEqual(try Data(contentsOf: marker), Data("pending".utf8))

    setMarkerLocked(false)
    let finished = try await relaunched.synchronize()
    XCTAssertEqual(finished, .iCloudSyncEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

    let next = try await relaunched.synchronize()
    XCTAssertNotEqual(next, .iCloudSyncEnabled)
    if case .iCloudSyncSettingUp = next { XCTFail("Setup ran again: \(next)") }
  }

  @MainActor
  func testSettingsTurnOnICloudSyncWhenEnableCleanupFails() async throws {
    let marker = self.marker
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
    _ = try await source.add(content: "stay local", origin: .quickEntry)
    let server = FakeCloudServer()
    let lifecycle = makeLifecycle(
      source: source,
      server: server,
      probe: PendingMarkerProbe(marker: marker, locksMarker: true)
    )
    let reload = EnableCompletionProbe()
    let model = SyncedContentSettingsModel(
      mode: .localOnly,
      issueMapper: SnipSnapCloudSyncIssueMapper.issue(for:),
      enableAction: { try await lifecycle.enableICloudSync() },
      disableAction: { choice in try await lifecycle.disableICloudSync(choice) },
      diagnostics: AppDiagnosticRecorder(record: { _ in })
    )
    model.setEnableCompletionAction { reload.ran = true }

    await model.enableICloudSync()

    XCTAssertEqual(model.mode, .iCloudSync)
    XCTAssertEqual(model.state, .ready)
    XCTAssertTrue(model.canDisable)
    XCTAssertTrue(reload.ran, "The app must reload into the iCloud store")
    XCTAssertEqual(try Data(contentsOf: marker), Data("pending".utf8))
  }

  func testTurningOffICloudSyncClearsAPendingEnable() async throws {
    let (lifecycle, _, _) = try await enabledICloudSyncWithPendingMarker()
    setMarkerLocked(false)

    try await lifecycle.disableICloudSync(.useCurrentCache)

    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    let next = try await lifecycle.synchronize()
    XCTAssertNotEqual(next, .iCloudSyncEnabled)
    if case .iCloudSyncSettingUp = next { XCTFail("Setup resumed after turning off iCloud sync: \(next)") }
    XCTAssertEqual(
      SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: syncRoot),
      .localOnly
    )
  }

  func testTurningOffICloudSyncFailsWhileThePendingEnableMarkerCannotBeRemoved() async throws {
    let (lifecycle, _, _) = try await enabledICloudSyncWithPendingMarker()

    await assertMarkerRemovalFails(
      "Turning off iCloud sync must not succeed while the pending marker remains"
    ) {
      try await lifecycle.disableICloudSync(.useCurrentCache)
    }
    XCTAssertNotNil(SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: syncRoot
    ))
    XCTAssertEqual(try Data(contentsOf: marker), Data("pending".utf8))

    setMarkerLocked(false)
    try await lifecycle.disableICloudSync(.useCurrentCache)

    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertEqual(
      SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: syncRoot),
      .localOnly
    )
  }

  func testTurningOffICloudSyncStaysLocalAfterRelaunch() async throws {
    let (lifecycle, source, server) = try await enabledICloudSyncWithPendingMarker()
    setMarkerLocked(false)
    try await lifecycle.disableICloudSync(.useCurrentCache)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

    let relaunched = try relaunchedLifecycle(source: source, server: server)
    let next = try await relaunched.synchronize()

    XCTAssertNotEqual(next, .iCloudSyncEnabled)
    if case .iCloudSyncSettingUp = next { XCTFail("Setup resumed after relaunch: \(next)") }
    XCTAssertEqual(
      SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: syncRoot),
      .localOnly
    )
    XCTAssertEqual(startupSettings().mode, .localOnly)
  }

  func testLeftoverMarkerDuringAnEditDoesNotReportICloudSyncSettingUp() async throws {
    let (_, source, server) = try await enabledICloudSyncWithPendingMarker()
    let persistence = try SwiftDataSyncModePersistence(rootURL: syncRoot)
    let lifecycle = makeLifecycle(
      source: source,
      server: server,
      syncModeStore: SnipSyncModeStore(persistence)
    )
    let activeStoreID = try await persistence.snapshot().activeStore.id
    let mutation = try await persistence.activeCloudMutation(storeID: activeStoreID)
    let gate = CloudApplyGate()
    let writing = Task { try await mutation.run { try await gate.pause() } }
    await gate.waitUntilPaused()

    await assertMarkerRemovalFails("A sync during an edit must not report setup") {
      try await lifecycle.synchronize()
    }
    XCTAssertEqual(try Data(contentsOf: marker), Data("pending".utf8))

    await gate.resume()
    try await writing.value
    setMarkerLocked(false)
    let finished = try await lifecycle.synchronize()
    XCTAssertEqual(finished, .iCloudSyncEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testRelaunchOfflineAfterACrashBeforeMarkerCleanupFinishesTheEnable() async throws {
    let (source, server) = try await enabledICloudSyncThenCrashBeforeMarkerCleanup()
    let control = PendingOfflineThenOnlineControlTransport(server: server)
    let relaunched = try relaunchedLifecycle(source: source, server: server, control: control)
    let restarted = startupSettings()
    XCTAssertEqual(restarted.mode, .iCloudSync)
    XCTAssertEqual(restarted.state, .ready)

    let result = try await relaunched.synchronize()

    XCTAssertEqual(result, .iCloudSyncEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertNotNil(SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: syncRoot
    ))
    await control.goOnline()
    let next = try await relaunched.synchronize()
    XCTAssertNotEqual(next, .iCloudSyncEnabled)
    if case .iCloudSyncSettingUp = next { XCTFail("Setup ran again: \(next)") }
  }

  func testRelaunchAfterACrashBeforeMarkerCleanupFinishesTheEnable() async throws {
    let (source, server) = try await enabledICloudSyncThenCrashBeforeMarkerCleanup()
    let relaunched = try relaunchedLifecycle(source: source, server: server)

    let result = try await relaunched.synchronize()

    XCTAssertEqual(result, .iCloudSyncEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertNotNil(SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: syncRoot
    ))
  }

  func testRelaunchAfterACrashRightAfterThePointerSwapFinishesTheTransition() async throws {
    let source = try await seededSource()
    let server = FakeCloudServer()
    let crash = CrashInjector(point: .afterPointerSwap)
    let crashing = try SwiftDataSyncModePersistence(rootURL: syncRoot, crashHook: crash.hit)
    let lifecycle = makeLifecycle(
      source: source,
      server: server,
      syncModeStore: SnipSyncModeStore(crashing)
    )
    do {
      _ = try await lifecycle.enableICloudSync()
      XCTFail("Expected the injected crash")
    } catch CrashInjector.Failure.injected {}
    XCTAssertNotNil(SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: syncRoot
    ))
    try writeMarker("pending")
    let relaunched = try relaunchedLifecycle(source: source, server: server)

    let result = try await relaunched.synchronize()

    XCTAssertEqual(result, .iCloudSyncEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    let reopened = try await SwiftDataSyncModePersistence(rootURL: syncRoot).snapshot()
    XCTAssertEqual(reopened.activeStore.kind, .iCloudSync)
    XCTAssertNil(reopened.transition)
  }

  func testCancelWhoseMarkerCannotBeRemovedKeepsTheEnablePending() async throws {
    let server = FakeCloudServer()
    let control = PendingOfflineThenOnlineControlTransport(server: server)
    let lifecycle = try await makeLifecycle(server: server, control: control)

    let enableOutcome = try await lifecycle.enableICloudSync()
    XCTAssertEqual(enableOutcome, .settingUp(.waitingForConnection))

    setMarkerLocked(true)
    await assertMarkerRemovalFails("A cancel whose pending marker remains must not succeed") {
      _ = try await lifecycle.cancelPendingEnable()
    }
    XCTAssertEqual(startupSettings().state, .enabling(.waitingForConnection))

    setMarkerLocked(false)
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

  func testCancelWithoutPendingEnableSucceeds() async throws {
    let server = FakeCloudServer()
    let lifecycle = try await makeLifecycle(
      server: server,
      control: FakeCloudControlTransport(server: server)
    )

    try await lifecycle.cancelPendingEnable()

    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertEqual(startupSettings().state, .ready)
  }

  @MainActor
  func testLateOrdinaryEnableReloadsButCannotOverrideAStopOrCancel() async throws {
      let settings = SyncedContentSettingsModel(mode: .localOnly, initialState: .enabling(.checkingAccount),
          cancelEnableAction: { .cancelled }, hasFailedPendingEnable: { true })
      let started = settings.recordSyncStarted()
      var reloads = 0
      try await SnipSnapCloudSyncResult.iCloudSyncEnabled.applyEnableProgress(to: settings, started: started) {
          reloads += 1
          settings.recordSyncStopped(.iCloudAccountChanged)
      }
      XCTAssertEqual(settings.state, .failed(.iCloudAccountChanged))
      XCTAssertEqual(settings.mode, .localOnly)
      let beforeCancel = settings.recordSyncStarted()
      await settings.cancelICloudSyncSetup()
      try await SnipSnapCloudSyncResult.iCloudSyncSettingUp(.checkingAccount)
          .applyEnableProgress(to: settings, started: beforeCancel) { reloads += 1 }
      XCTAssertEqual(reloads, 1)
      XCTAssertEqual(settings.state, .ready)
      XCTAssertEqual(settings.mode, .localOnly)
  }

  // MARK: Stored marker format

  func testEveryStoredMarkerFormRestartsWithTodaysSettingsState() throws {
    let cases: [(String, Data, SyncedContentSettingsState)] = [
      ("pending", Data("pending".utf8), .enabling(nil)),
      ("retry-v2 valid", Data("retry-v2:eyJyZXRyeWluZ1Nvb24iOnt9fQ==".utf8),
       .enabling(.retryingSoon)),
      ("retry-v2 with payload", Data("retry-v2:eyJzZXR1cEJsb2NrZWQiOnsiXzAiOiJCbG9ja2VkIn19".utf8),
       .enabling(.setupBlocked("Blocked"))),
      ("failure-v2 valid", Data("failure-v2:eyJzaWduSW5SZXF1aXJlZCI6e319".utf8),
       .failed(.signInRequired)),
      ("failure-v2 garbage", Data("failure-v2:garbage".utf8), .failed(.appDataIssue)),
      // Anything else never restarts setup on its own, including markers only older builds wrote.
      ("retry-v2 garbage", Data("retry-v2:garbage".utf8), .failed(.appDataIssue)),
      ("retry:unknown", Data("retry:unknown".utf8), .failed(.appDataIssue)),
      ("needs-attention", Data("needs-attention".utf8), .failed(.appDataIssue)),
      ("needs-attention with newline", Data("needs-attention\n".utf8), .failed(.appDataIssue)),
      ("pending with newline", Data("pending\n".utf8), .failed(.appDataIssue)),
      ("empty", Data(), .failed(.appDataIssue)),
      ("not UTF-8", Data([0xFF, 0xFE, 0x00]), .failed(.appDataIssue)),
    ]

    for (name, bytes, expected) in cases {
      try writeMarker(bytes)

      let local = startupSettings(.localOnly)
      XCTAssertEqual(local.mode, .localOnly, name)
      XCTAssertEqual(local.state, expected, name)

      let settingUp = startupSettings(.settingUp(Self.binding))
      XCTAssertEqual(settingUp.mode, .localOnly, name)
      XCTAssertEqual(settingUp.state, expected, "\(name) while setting up")

      let active = startupSettings(.active(Self.binding))
      XCTAssertEqual(active.mode, .iCloudSync, name)
      XCTAssertEqual(active.state, .ready, "\(name) while active")
    }
  }

  func testMissingMarkerRestartsWithTodaysSettingsState() {
    XCTAssertEqual(startupSettings(.localOnly).mode, .localOnly)
    XCTAssertEqual(startupSettings(.localOnly).state, .ready)
    XCTAssertEqual(startupSettings(.settingUp(Self.binding)).state, .enabling(nil))
    XCTAssertEqual(startupSettings(.needsAttention(Self.binding)).state, .failed(.appDataIssue))
    XCTAssertEqual(startupSettings(.active(Self.binding)).mode, .iCloudSync)
    XCTAssertEqual(startupSettings(.active(Self.binding)).state, .ready)
  }

  func testEnableWritesPendingMarkerAndRemovesItWhenEnabled() async throws {
    let server = FakeCloudServer()
    let probe = PendingMarkerProbe(marker: marker, locksMarker: false)
    let lifecycle = try await makeLifecycle(
      server: server,
      control: FakeCloudControlTransport(server: server),
      probe: probe
    )

    let outcome = try await lifecycle.enableICloudSync()

    XCTAssertEqual(outcome, .enabled)
    let seen = await probe.seenMarker
    XCTAssertEqual(seen, Data("pending".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testEnableKeepsLocalStoreIfCollectionChangesDuringCandidateFetch() async throws {
    let source = try await seededSource()
    let persistence = try SwiftDataSyncModePersistence(rootURL: syncRoot)
    let original = try await persistence.snapshot().activeStore
    let server = FakeCloudServer()
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    await server.seedControl(descriptor)
    let transport = FakeCloudRecordTransport(
      server: server,
      namespace: descriptor.namespace(cloudScope: "private", accountLineage: "account-a")
    )
    await transport.pauseNextFetch()
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: syncRoot,
      sourceLibrary: source,
      syncModeStore: SnipSyncModeStore(persistence),
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      controlTransport: FakeCloudControlTransport(server: server),
      makeRecordTransport: { _ in transport },
      makeDescriptor: { descriptor }
    )

    let enabling = Task { try await lifecycle.enableICloudSync() }
    await transport.waitUntilFetchPauses()
    await server.seedControl(.fresh(ownerName: "owner"))
    await transport.resumeFetch()
    do {
      _ = try await enabling.value
      XCTFail("Setup must stop when the collection changes before activation")
    } catch CloudCollectionError.syncNeedsAttention {}

    let after = try await persistence.snapshot()
    XCTAssertEqual(after.activeStore.id, original.id)
    XCTAssertNil(after.transition)
    let local = try await persistence.activeLibrary()
    let kept = try await local.checkedSnapshot(sortedBy: .manual)
    XCTAssertEqual(kept.snips.map(\.content), ["stay local"])
    _ = try await local.perform(
      .add(
        content: "still writable", origin: .quickEntry, source: nil, listID: SnipList.inbox.id,
        attachmentURLs: [], requestID: UUID(), now: .now
      ),
      sortedBy: .manual
    )
  }

  func testOfflineEnableWritesRetryMarkerAndCancelRemovesIt() async throws {
    let server = FakeCloudServer()
    let lifecycle = try await makeLifecycle(
      server: server,
      control: PendingOfflineThenOnlineControlTransport(server: server)
    )

    _ = try await lifecycle.enableICloudSync()
    XCTAssertEqual(
      try Data(contentsOf: marker),
      Data("retry-v2:eyJ3YWl0aW5nRm9yQ29ubmVjdGlvbiI6e319".utf8)
    )

    try await lifecycle.cancelPendingEnable()
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testTerminalEnableFailureWritesFailureMarker() async throws {
    let server = FakeCloudServer()
    let lifecycle = try await makeLifecycle(
      server: server,
      control: FakeCloudControlTransport(server: server),
      accountState: .noAccount
    )

    do {
      _ = try await lifecycle.enableICloudSync()
      XCTFail("Expected account setup failure")
    } catch {}

    XCTAssertEqual(
      try Data(contentsOf: marker),
      Data("failure-v2:eyJzaWduSW5SZXF1aXJlZCI6e319".utf8)
    )
    XCTAssertEqual(startupSettings().state, .failed(.signInRequired))
  }

  // MARK: Helpers

  private static let binding = ICloudSyncNamespaceBinding(
    scope: "private",
    accountLineage: "account-a",
    generation: UUID(uuidString: "6a1f0e4c-27e2-4d5e-9b8a-0d6c3f1b2a99")!,
    zones: []
  )

  private func makeLifecycle(
    server: FakeCloudServer,
    control: (any CloudCollectionControlTransport)? = nil,
    probe: PendingMarkerProbe? = nil,
    accountState: ICloudAccountState? = nil
  ) async throws -> SnipSnapICloudSyncLifecycle {
    let source = try await seededSource()
    return makeLifecycle(
      source: source,
      server: server,
      control: control,
      probe: probe,
      accountState: accountState
    )
  }

  private func seededSource() async throws -> JSONSnipLibrary {
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
    _ = try await source.add(content: "stay local", origin: .quickEntry)
    return source
  }

  private func makeLifecycle(
    source: any SnipLibrary,
    server: FakeCloudServer,
    control: (any CloudCollectionControlTransport)? = nil,
    syncModeStore: SnipSyncModeStore? = nil,
    probe: PendingMarkerProbe? = nil,
    accountState: ICloudAccountState? = nil
  ) -> SnipSnapICloudSyncLifecycle {
    let controlTransport: any CloudCollectionControlTransport =
      control ?? FakeCloudControlTransport(server: server)
    let accountSource: (any ICloudAccountStateSource)? = if let probe {
      probe
    } else if let accountState {
      FixedICloudAccountStateSource(state: accountState)
    } else {
      nil
    }
    return SnipSnapICloudSyncLifecycle(
      rootURL: syncRoot,
      sourceLibrary: source,
      syncModeStore: syncModeStore,
      cloudScope: "private",
      accountLineage: "account-a",
      accountStateSource: accountSource,
      ownerName: "owner",
      controlTransport: controlTransport,
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: { CloudCollectionDescriptor.fresh(ownerName: "owner") }
    )
  }

  /// Opens the sync-mode store the way the app does on a new launch.
  private func relaunchedLifecycle(
    source: any SnipLibrary,
    server: FakeCloudServer,
    control: (any CloudCollectionControlTransport)? = nil
  ) throws -> SnipSnapICloudSyncLifecycle {
    let assembly = SnipLibraryAssembly(library: source, syncModeRootURL: syncRoot)
    let syncModeStore = try XCTUnwrap(assembly.syncModeStore)
    return makeLifecycle(
      source: source,
      server: server,
      control: control,
      syncModeStore: syncModeStore
    )
  }

  /// A finished enable whose app crashed before it removed the marker.
  private func enabledICloudSyncThenCrashBeforeMarkerCleanup() async throws -> (
    source: JSONSnipLibrary,
    server: FakeCloudServer
  ) {
    let source = try await seededSource()
    let server = FakeCloudServer()
    let outcome = try await makeLifecycle(source: source, server: server).enableICloudSync()
    XCTAssertEqual(outcome, .enabled)
    try writeMarker("pending")
    return (source, server)
  }

  /// iCloud sync is on, but the enable's pending marker is locked in place.
  private func enabledICloudSyncWithPendingMarker() async throws -> (
    lifecycle: SnipSnapICloudSyncLifecycle,
    source: JSONSnipLibrary,
    server: FakeCloudServer
  ) {
    let source = try await seededSource()
    let server = FakeCloudServer()
    let lifecycle = makeLifecycle(
      source: source,
      server: server,
      probe: PendingMarkerProbe(marker: marker, locksMarker: true)
    )
    let outcome = try await lifecycle.enableICloudSync()
    XCTAssertEqual(outcome, .enabled)
    XCTAssertEqual(try Data(contentsOf: marker), Data("pending".utf8))
    XCTAssertNotNil(SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: syncRoot
    ))
    return (lifecycle, source, server)
  }

  private func assertMarkerRemovalFails<T>(
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
  ) async {
    do {
      let value = try await operation()
      XCTFail("\(message); got \(value)", file: file, line: line)
    } catch {
      XCTAssertTrue(error is CocoaError, "Unexpected error: \(error)", file: file, line: line)
    }
  }

  private func startupSettings(
    _ startupState: SyncModeActivationManifestReader.ICloudStartupState? = nil
  ) -> (mode: SyncedContentMode, state: SyncedContentSettingsState) {
    SnipSnapCloudAppAssembly.settingsStartupState(
      rootURL: syncRoot,
      startupState: startupState
        ?? SyncModeActivationManifestReader.iCloudStartupState(atSyncModeRootURL: syncRoot)
    )
  }

  private func writeMarker(_ value: String) throws {
    try writeMarker(Data(value.utf8))
  }

  private func writeMarker(_ data: Data) throws {
    try FileManager.default.createDirectory(at: syncRoot, withIntermediateDirectories: true)
    try data.write(to: marker)
  }

  private func setMarkerLocked(_ locked: Bool) {
    guard FileManager.default.fileExists(atPath: marker.path) else { return }
    try? FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: marker.path)
  }
}

@MainActor
private final class EnableCompletionProbe {
  var ran = false
}

/// Runs as the account lineage lookup, after the pending marker is written and
/// before the enable finishes. It records the marker and can lock it once.
private actor PendingMarkerProbe: ICloudAccountStateSource {
  private let marker: URL
  private var locksMarker: Bool
  private(set) var seenMarker: Data?

  init(marker: URL, locksMarker: Bool) {
    self.marker = marker
    self.locksMarker = locksMarker
  }

  func currentAccountState() -> ICloudAccountState {
    if seenMarker == nil { seenMarker = try? Data(contentsOf: marker) }
    if locksMarker {
      locksMarker = false
      try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: marker.path)
    }
    return .available(accountLineage: "account-a")
  }
}

private actor PendingOfflineThenOnlineControlTransport: CloudCollectionControlTransport {
  private let base: FakeCloudControlTransport
  private var isOffline = true

  init(server: FakeCloudServer) {
    base = FakeCloudControlTransport(server: server)
  }

  func goOnline() { isOffline = false }

  func fetchControl() async throws -> CloudCollectionControlRecord? {
    guard !isOffline else { throw CloudSyncIssueError(.waitingForConnection) }
    return await base.fetchControl()
  }

  func createZones(_ zones: Set<CloudZoneID>) async throws {
    await base.createZones(zones)
  }

  func saveControl(
    _ descriptor: CloudCollectionDescriptor,
    replacing version: Data?
  ) async throws -> CloudCollectionControlSaveResult {
    await base.saveControl(descriptor, replacing: version)
  }

  func deleteZones(_ zones: Set<CloudZoneID>) async throws {
    try await base.deleteZones(zones)
  }
}
