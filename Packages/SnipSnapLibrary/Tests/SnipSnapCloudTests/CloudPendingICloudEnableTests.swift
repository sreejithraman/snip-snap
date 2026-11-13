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

    XCTAssertThrowsError(try FileManager.default.removeItem(at: marker))
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
  }

  func testEnableWhoseMarkerCannotBeRemovedFinishesOnNextSync() async throws {
    let server = FakeCloudServer()
    let probe = PendingMarkerProbe(marker: marker, locksMarker: true)
    let lifecycle = try await makeLifecycle(
      server: server,
      control: FakeCloudControlTransport(server: server),
      probe: probe
    )

    do {
      let outcome = try await lifecycle.enableICloudSync()
      XCTFail("An enable whose pending marker remains must not report \(outcome)")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

    setMarkerLocked(false)
    let finished = try await lifecycle.synchronize()
    XCTAssertEqual(finished, .iCloudSyncEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

    let next = try await lifecycle.synchronize()
    XCTAssertNotEqual(next, .iCloudSyncEnabled)
    if case .iCloudSyncSettingUp = next { XCTFail("Setup ran again: \(next)") }
  }

  func testCancelWhoseMarkerCannotBeRemovedKeepsTheEnablePending() async throws {
    let server = FakeCloudServer()
    let control = PendingOfflineThenOnlineControlTransport(server: server)
    let lifecycle = try await makeLifecycle(server: server, control: control)

    let enableOutcome = try await lifecycle.enableICloudSync()
    XCTAssertEqual(enableOutcome, .settingUp(.waitingForConnection))

    setMarkerLocked(true)
    do {
      try await lifecycle.cancelPendingEnable()
      XCTFail("A cancel whose pending marker remains must not succeed")
    } catch {}
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

  // MARK: Stored marker format

  func testEveryStoredMarkerFormRestartsWithTodaysSettingsState() throws {
    let cases: [(String, Data, SyncedContentSettingsState)] = [
      ("pending", Data("pending".utf8), .enabling(nil)),
      ("retry:waiting-for-connection", Data("retry:waiting-for-connection".utf8),
       .enabling(.waitingForConnection)),
      ("retry:icloud-unavailable", Data("retry:icloud-unavailable".utf8),
       .enabling(.iCloudUnavailable)),
      ("retry:retrying-soon", Data("retry:retrying-soon".utf8), .enabling(.retryingSoon)),
      ("retry:checking-account", Data("retry:checking-account".utf8),
       .enabling(.checkingAccount)),
      ("retry:account-temporarily-unavailable",
       Data("retry:account-temporarily-unavailable".utf8),
       .enabling(.accountTemporarilyUnavailable)),
      ("retry:some-changes-pending", Data("retry:some-changes-pending".utf8),
       .enabling(.someChangesPending)),
      ("retry:attachment-unavailable", Data("retry:attachment-unavailable".utf8),
       .enabling(.attachmentUnavailable)),
      ("retry:unknown", Data("retry:unknown".utf8), .enabling(nil)),
      ("retry-v2 valid", Data("retry-v2:eyJyZXRyeWluZ1Nvb24iOnt9fQ==".utf8),
       .enabling(.retryingSoon)),
      ("retry-v2 with payload", Data("retry-v2:eyJzZXR1cEJsb2NrZWQiOnsiXzAiOiJCbG9ja2VkIn19".utf8),
       .enabling(.setupBlocked("Blocked"))),
      ("retry-v2 garbage", Data("retry-v2:garbage".utf8), .enabling(nil)),
      ("needs-attention", Data("needs-attention".utf8), .failed(.appDataIssue)),
      ("needs-attention with newline", Data("needs-attention\n".utf8), .enabling(nil)),
      ("failure-v2 valid", Data("failure-v2:eyJzaWduSW5SZXF1aXJlZCI6e319".utf8),
       .failed(.signInRequired)),
      ("failure-v2 garbage", Data("failure-v2:garbage".utf8), .failed(.appDataIssue)),
      ("empty", Data(), .enabling(nil)),
      ("not UTF-8", Data([0xFF, 0xFE, 0x00]), .enabling(nil)),
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
    control: any CloudCollectionControlTransport,
    probe: PendingMarkerProbe? = nil,
    accountState: ICloudAccountState? = nil
  ) async throws -> SnipSnapICloudSyncLifecycle {
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
    _ = try await source.add(content: "stay local", origin: .quickEntry)
    var lineageProvider: (@Sendable () async throws -> String)?
    if let probe {
      lineageProvider = { try await probe.accountLineage() }
    }
    var accountStateSource: (any ICloudAccountStateSource)?
    if let accountState {
      accountStateSource = FixedICloudAccountStateSource(state: accountState)
    }
    return SnipSnapICloudSyncLifecycle(
      rootURL: syncRoot,
      sourceLibrary: source,
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "account-a",
      accountLineageProvider: lineageProvider,
      accountStateSource: accountStateSource,
      ownerName: "owner",
      controlTransport: control,
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: { CloudCollectionDescriptor.fresh(ownerName: "owner") }
    )
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

/// Runs as the account lineage lookup, after the pending marker is written and
/// before the enable finishes. It records the marker and can lock it once.
private actor PendingMarkerProbe {
  private let marker: URL
  private var locksMarker: Bool
  private(set) var seenMarker: Data?

  init(marker: URL, locksMarker: Bool) {
    self.marker = marker
    self.locksMarker = locksMarker
  }

  func accountLineage() throws -> String {
    if seenMarker == nil { seenMarker = try? Data(contentsOf: marker) }
    if locksMarker {
      locksMarker = false
      try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: marker.path)
    }
    return "account-a"
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
