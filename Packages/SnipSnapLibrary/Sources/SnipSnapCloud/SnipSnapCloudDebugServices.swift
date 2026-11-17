import Foundation
import SnipSnapCore
import SnipSnapPersistence

#if DEBUG
actor SimulatedCloudCollectionReset {
  private let persistence: SwiftDataSyncModePersistence
  private let old: CloudCollectionDescriptor
  private let server: FakeCloudServer
  private let transport: FakeCloudControlTransport
  private let local: SwiftDataCloudCollectionLocalStore?
  private let coordinator: CloudCollectionCoordinator?
  private let simulateEncryptedDataReset: Bool
  private let simulateRemovalPending: Bool
  /// Fails each sync's cleanup of the old zones until a retry.
  private var keepsRemovalPending: Bool
  private var prepared = false

  init(
    rootURL: URL,
    persistence: SwiftDataSyncModePersistence,
    simulateEncryptedDataReset: Bool = false,
    simulateRemovalPending: Bool = false
  ) {
    self.persistence = persistence
    self.simulateEncryptedDataReset = simulateEncryptedDataReset
    self.simulateRemovalPending = simulateRemovalPending
    keepsRemovalPending = simulateRemovalPending
    old = CloudCollectionDescriptor.fresh(ownerName: "ui-test-owner")
    server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    self.transport = transport
    let local = try? SwiftDataCloudCollectionLocalStore(
      rootURL: rootURL,
      persistence: persistence
    )
    self.local = local
    coordinator = local.map {
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
    try await synchronizeWithTarget().result
  }

  func synchronizeWithTarget() async throws -> SnipSnapCloudSyncDelivery {
    let coordinator = try await prepare()
    if keepsRemovalPending { await transport.failNextZoneDelete() }
    let delivery = try await coordinator.synchronizeWithTarget()
    if delivery.status == .purged {
      let purged = try await local?.markPurgedWithTarget()
      return SnipSnapCloudSyncDelivery(result: .iCloudDataReset, target: purged ?? delivery.target)
    }
    return SnipSnapCloudSyncDelivery(result: syncResult(for: delivery.status), target: delivery.target)
  }

  func retrySynchronization() async throws -> SnipSnapCloudSyncResult {
    try await retrySynchronizationWithTarget().result
  }

  func retrySynchronizationWithTarget() async throws -> SnipSnapCloudSyncDelivery {
    keepsRemovalPending = false
    return try await synchronizeWithTarget()
  }

  func enableSync() async throws { _ = try await enableSyncWithTarget() }

  func enableSyncWithTarget() async throws -> SnipSnapCloudEnableDelivery {
    let coordinator = try await prepare()
    let delivery = try await coordinator.enableSyncWithTarget()
    return SnipSnapCloudEnableDelivery(outcome: .enabled, target: delivery.target)
  }

  func currentApplicationTarget() async throws -> SnipSnapCloudApplicationTarget {
    let snapshot = try await persistence.snapshot()
    return SnipSnapCloudApplicationTarget(persistence: persistence, store: snapshot.activeStore)
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

  func deleteSyncedContent() async throws -> SyncedContentDeleteOutcome {
    let coordinator = try await prepare()
    return deleteOutcome(for: try await coordinator.deleteSyncedContent())
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
    guard let local, let coordinator else { throw SyncModePersistenceError.missingStore }
    guard !prepared else { return coordinator }
    try await local.adopt(
      old.namespace(cloudScope: "private", accountLineage: "ui-test-account")
    )
    await transport.seedControl(old)
    if simulateEncryptedDataReset {
      await transport.removeControl()
    }
    if simulateRemovalPending {
      // The real delete publishes a fresh collection and stages the old zones, whose
      // deletion then fails.
      await transport.failNextZoneDelete()
      _ = try await coordinator.deleteSyncedContent()
    }
    prepared = true
    return coordinator
  }
}
#endif
