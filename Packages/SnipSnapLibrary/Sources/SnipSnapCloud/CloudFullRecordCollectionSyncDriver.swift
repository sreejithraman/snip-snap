import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// Builds a namespace-bound record driver only after the control coordinator authorizes it.
package actor CloudFullRecordCollectionSyncDriver: CloudCollectionSyncDriver {
  package typealias TransportFactory = @Sendable (
    CloudCollectionSyncContext
  ) -> any CloudRecordTransport

  private let persistence: SwiftDataSyncModePersistence
  private let makeTransport: TransportFactory

  package init(
    persistence: SwiftDataSyncModePersistence,
    makeTransport: @escaping TransportFactory
  ) {
    self.persistence = persistence
    self.makeTransport = makeTransport
  }

  package func fetch(_ context: CloudCollectionSyncContext) async throws {
    let coordinator = try await recordCoordinator(context)
    try await coordinator.fetchRemote()
  }

  package func send(_ context: CloudCollectionSyncContext) async throws {
    let coordinator = try await recordCoordinator(context)
    try await coordinator.sendPending()
  }

  private func recordCoordinator(
    _ context: CloudCollectionSyncContext
  ) async throws -> CloudFullSyncCoordinator {
    let storage = try await persistence.snapshot()
    guard storage.activeStore.namespace == binding(context.namespace),
      storage.activeStore.kind == .iCloudSync
    else { throw SyncModePersistenceError.namespaceMismatch }
    let library = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: context.namespace,
      dataZone: context.metadataZone
    )
    return CloudFullSyncCoordinator(store: store, transport: makeTransport(context))
  }

  private func binding(_ namespace: CloudSyncNamespace) -> ICloudSyncNamespaceBinding {
    ICloudSyncNamespaceBinding(
      scope: namespace.cloudScope,
      accountLineage: namespace.accountLineage,
      generation: namespace.generation,
      zones: Set(namespace.zones.map {
        ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
      })
    )
  }
}

package enum CloudCollectionAssembly {
  package static let productionControlID = CloudRecordID(
    zone: CloudZoneID(name: "SnipSnapControl", ownerName: CKCurrentUserDefaultName),
    name: "active-collection"
  )

  @MainActor
  package static func settingsModel(
    for coordinator: CloudCollectionCoordinator
  ) -> SyncedContentSettingsModel {
    SyncedContentSettingsModel(mode: .iCloudSync) {
      _ = try await coordinator.deleteSyncedContent()
    }
  }

  /// The signed main-app lane uses this one path; local-only apps never construct it.
  package static func cloudKitCoordinator(
    rootURL: URL,
    persistence: SwiftDataSyncModePersistence,
    database: CKDatabase,
    cloudScope: String,
    accountLineage: String,
    ownerName: String,
    controlID: CloudRecordID,
    makeDescriptor: CloudCollectionCoordinator.DescriptorFactory? = nil
  ) throws -> CloudCollectionCoordinator {
    let local = try SwiftDataCloudCollectionLocalStore(
      rootURL: rootURL,
      persistence: persistence
    )
    let driver = CloudFullRecordCollectionSyncDriver(
      persistence: persistence,
      makeTransport: { context in
        CloudKitRecordTransport(
          database: database,
          namespace: context.namespace,
          automaticallyFetchedZones: [context.metadataZone]
        )
      }
    )
    return CloudCollectionCoordinator(
      cloudScope: cloudScope,
      accountLineage: accountLineage,
      ownerName: ownerName,
      localStore: local,
      transport: CloudKitCollectionControlTransport(
        database: database,
        controlID: controlID
      ),
      syncDriver: driver,
      makeDescriptor: makeDescriptor ?? {
        CloudCollectionDescriptor.fresh(ownerName: ownerName)
      }
    )
  }
}

/// Main-app sync wiring. A blank container keeps a contributor build local-only.
public enum SnipSnapCloudAppAssembly {
  @MainActor
  public static func syncedContentSettings(
    rootURL: URL,
    syncModeStore: SnipSyncModeStore?,
    containerIdentifier: String?
  ) -> SyncedContentSettingsModel {
    let identifier = containerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !identifier.isEmpty,
      let syncModeStore,
      let namespace = SyncModeActivationManifestReader.activeCloudNamespace(
        atSyncModeRootURL: rootURL
      )
    else { return SyncedContentSettingsModel(mode: .localOnly) }
    return SyncedContentSettingsModel(mode: .iCloudSync) {
      let coordinator = try CloudCollectionAssembly.cloudKitCoordinator(
        rootURL: rootURL,
        persistence: syncModeStore.persistence,
        database: CKContainer(identifier: identifier).privateCloudDatabase,
        cloudScope: namespace.scope,
        accountLineage: namespace.accountLineage,
        ownerName: CKCurrentUserDefaultName,
        controlID: CloudCollectionAssembly.productionControlID
      )
      _ = try await coordinator.deleteSyncedContent()
    }
  }

  /// Runs the same UI action through a fake control server in UI tests.
  @MainActor
  public static func simulatedSyncedContentSettings(
    rootURL: URL,
    syncModeStore: SnipSyncModeStore?
  ) -> SyncedContentSettingsModel {
    guard let syncModeStore else { return SyncedContentSettingsModel(mode: .localOnly) }
    let reset = SimulatedCloudCollectionReset(
      rootURL: rootURL,
      persistence: syncModeStore.persistence
    )
    return SyncedContentSettingsModel(mode: .iCloudSync) {
      try await reset.deleteSyncedContent()
    }
  }
}

private actor SimulatedCloudCollectionReset {
  private let rootURL: URL
  private let persistence: SwiftDataSyncModePersistence

  init(rootURL: URL, persistence: SwiftDataSyncModePersistence) {
    self.rootURL = rootURL
    self.persistence = persistence
  }

  func deleteSyncedContent() async throws {
    let local = try SwiftDataCloudCollectionLocalStore(
      rootURL: rootURL,
      persistence: persistence
    )
    let old = CloudCollectionDescriptor.fresh(ownerName: "ui-test-owner")
    try await local.adopt(
      old.namespace(cloudScope: "private", accountLineage: "ui-test-account")
    )
    let server = FakeCloudServer()
    let transport = FakeCloudControlTransport(server: server)
    await transport.seedControl(old)
    let coordinator = CloudCollectionCoordinator(
      cloudScope: "private",
      accountLineage: "ui-test-account",
      ownerName: "ui-test-owner",
      localStore: local,
      transport: transport,
      syncDriver: NoopCloudCollectionSyncDriver(),
      makeDescriptor: { CloudCollectionDescriptor.fresh(ownerName: "ui-test-owner") }
    )
    _ = try await coordinator.deleteSyncedContent()
  }
}

private struct NoopCloudCollectionSyncDriver: CloudCollectionSyncDriver {
  func fetch(_ context: CloudCollectionSyncContext) async throws {}
  func send(_ context: CloudCollectionSyncContext) async throws {}
}
