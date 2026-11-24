import Foundation
import SnipSnapCore
import SnipSnapPersistence

#if DEBUG
/// Runs Settings against a fake control server for UI tests. The library starts on an empty
/// iCloud store for the fixture collection.
actor SimulatedCloudCollectionReset {
  private let persistence: SwiftDataSyncModePersistence
  private let old: CloudCollectionDescriptor
  private let server: FakeCloudServer
  private let transport: FakeCloudControlTransport
  private let coordinator: CloudCollectionCoordinator?
  private let simulateEncryptedDataReset: Bool
  private var prepared = false

  init(
    rootURL: URL,
    persistence: SwiftDataSyncModePersistence,
    simulateEncryptedDataReset: Bool = false
  ) {
    self.persistence = persistence
    self.simulateEncryptedDataReset = simulateEncryptedDataReset
    old = CloudCollectionDescriptor.fresh(ownerName: "ui-test-owner")
    server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    self.transport = transport
    coordinator = (try? SwiftDataCloudCollectionLocalStore(
      rootURL: rootURL,
      persistence: persistence
    )).map {
      CloudCollectionCoordinator(
        cloudScope: "private",
        accountLineage: "ui-test-account",
        ownerName: "ui-test-owner",
        localStore: $0,
        transport: transport,
        syncDriver: NoopCloudCollectionSyncDriver(),
        makeDescriptor: { CloudCollectionDescriptor.fresh(ownerName: "ui-test-owner") }
      )
    }
  }

  func synchronize() async throws -> SnipSnapCloudSyncResult {
    let coordinator = try await prepare()
    return syncResult(for: try await coordinator.synchronize())
  }

  func retrySynchronization() async throws -> SnipSnapCloudSyncResult {
    try await synchronize()
  }

  /// Turns sync back on for the fixture collection, publishing it again if a reset removed it.
  func enableSync() async throws {
    _ = try await prepare()
    if await transport.fetchControl() == nil { await transport.seedControl(old) }
    try await persistence.seedEmptyActiveStore(
      namespace: old.namespace(cloudScope: "private", accountLineage: "ui-test-account").binding
    )
  }

  func disableICloudSync(_ choice: SyncedContentDisableChoice) async throws {
    _ = try await prepare()
    let namespace = old.namespace(
      cloudScope: "private",
      accountLineage: "ui-test-account"
    )
    let mode = ICloudSyncModeCoordinator(
      persistence: persistence,
      namespace: namespace,
      textZone: old.metadataZone,
      payloadZone: old.payloadZone,
      makeTransport: { [server] in
        FakeCloudRecordTransport(server: server, namespace: namespace)
      }
    )
    let mapped: ICloudSyncOptOutChoice = choice == .refreshThenCopy
      ? .refreshThenCopy : .useCurrentCacheAfterStaleDataWarning
    let status = try await mode.optOut(mapped)
    guard status.state == .off else { throw CloudSyncRetryableError.itemFailure }
  }

  func activeLibrary() async throws -> SnipSnapCloudActiveLibrary {
    let snapshot = try await persistence.snapshot()
    return SnipSnapCloudActiveLibrary(
      library: try await persistence.activeLibrary(),
      recoveryScope: SnipRecoveryScopeFactory.scope(
        forActiveCloudNamespace: snapshot.activeStore.namespace
      )
    )
  }

  private func prepare() async throws -> CloudCollectionCoordinator {
    guard let coordinator else { throw SyncModePersistenceError.missingStore }
    guard !prepared else { return coordinator }
    try await persistence.seedEmptyActiveStore(
      namespace: old.namespace(cloudScope: "private", accountLineage: "ui-test-account").binding
    )
    await transport.seedControl(old)
    if simulateEncryptedDataReset {
      await transport.removeControl()
    }
    prepared = true
    return coordinator
  }
}
#endif
