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
      },
      reservedZones: [controlID.zone]
    )
  }
}

public struct SnipSnapCloudActiveLibrary: Sendable {
  public let library: any SnipLibrary
  public let recoveryScope: SnipRecoveryScope?

  package init(library: any SnipLibrary, recoveryScope: SnipRecoveryScope?) {
    self.library = library
    self.recoveryScope = recoveryScope
  }
}

public enum SnipSnapCloudSyncResult: Equatable, Sendable {
  case noChange
  case contentUpdated
  case libraryReplaced
}

/// One app-owned lane for normal sync, enabling sync, and deleting synced content.
public actor SnipSnapCloudSyncSession {
  package typealias Action = @Sendable () async throws -> Void
  package typealias SynchronizeAction = @Sendable () async throws -> SnipSnapCloudSyncResult
  package typealias LibraryAction = @Sendable () async throws -> SnipSnapCloudActiveLibrary

  private let synchronizeAction: SynchronizeAction
  private let enableAction: Action
  private let deleteAction: Action
  private let libraryAction: LibraryAction

  package init(
    coordinator: CloudCollectionCoordinator,
    persistence: SwiftDataSyncModePersistence
  ) {
    synchronizeAction = {
      syncResult(for: try await coordinator.synchronize())
    }
    enableAction = { _ = try await coordinator.enableSync() }
    deleteAction = { _ = try await coordinator.deleteSyncedContent() }
    libraryAction = {
      let snapshot = try await persistence.snapshot()
      return SnipSnapCloudActiveLibrary(
        library: try await persistence.activeLibrary(),
        recoveryScope: SnipRecoveryScopeFactory.scope(
          forActiveCloudNamespace: snapshot.activeStore.namespace
        )
      )
    }
  }

  package init(
    synchronize: @escaping SynchronizeAction,
    enable: @escaping Action,
    delete: @escaping Action,
    activeLibrary: @escaping LibraryAction
  ) {
    synchronizeAction = synchronize
    enableAction = enable
    deleteAction = delete
    libraryAction = activeLibrary
  }

  public func synchronize() async throws -> SnipSnapCloudSyncResult {
    try await synchronizeAction()
  }
  public func enableSync() async throws { try await enableAction() }
  public func deleteSyncedContent() async throws { try await deleteAction() }
  public func activeLibrary() async throws -> SnipSnapCloudActiveLibrary {
    try await libraryAction()
  }
}

@MainActor
public struct SnipSnapCloudAppServices {
  public let syncedContentSettings: SyncedContentSettingsModel
  public let syncSession: SnipSnapCloudSyncSession?

  package init(
    syncedContentSettings: SyncedContentSettingsModel,
    syncSession: SnipSnapCloudSyncSession?
  ) {
    self.syncedContentSettings = syncedContentSettings
    self.syncSession = syncSession
  }
}

/// Main-app sync wiring. A blank container keeps a contributor build local-only.
public enum SnipSnapCloudAppAssembly {
  @MainActor
  public static func services(
    rootURL: URL,
    syncModeStore: SnipSyncModeStore?,
    containerIdentifier: String?
  ) -> SnipSnapCloudAppServices {
    let identifier = containerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !identifier.isEmpty,
      let syncModeStore,
      let namespace = SyncModeActivationManifestReader.activeCloudNamespace(
        atSyncModeRootURL: rootURL
      )
    else {
      return SnipSnapCloudAppServices(
        syncedContentSettings: SyncedContentSettingsModel(mode: .localOnly),
        syncSession: nil
      )
    }
    do {
      let coordinator = try CloudCollectionAssembly.cloudKitCoordinator(
        rootURL: rootURL,
        persistence: syncModeStore.persistence,
        database: CKContainer(identifier: identifier).privateCloudDatabase,
        cloudScope: namespace.scope,
        accountLineage: namespace.accountLineage,
        ownerName: CKCurrentUserDefaultName,
        controlID: CloudCollectionAssembly.productionControlID
      )
      let session = SnipSnapCloudSyncSession(
        coordinator: coordinator,
        persistence: syncModeStore.persistence
      )
      return SnipSnapCloudAppServices(
        syncedContentSettings: SyncedContentSettingsModel(mode: .iCloudSync) {
          try await session.deleteSyncedContent()
        },
        syncSession: session
      )
    } catch {
      return SnipSnapCloudAppServices(
        syncedContentSettings: SyncedContentSettingsModel(mode: .localOnly),
        syncSession: nil
      )
    }
  }

  /// Runs the same UI action through a fake control server in UI tests.
  @MainActor
  public static func simulatedServices(
    rootURL: URL,
    syncModeStore: SnipSyncModeStore?
  ) -> SnipSnapCloudAppServices {
    guard let syncModeStore else {
      return SnipSnapCloudAppServices(
        syncedContentSettings: SyncedContentSettingsModel(mode: .localOnly),
        syncSession: nil
      )
    }
    let reset = SimulatedCloudCollectionReset(
      rootURL: rootURL,
      persistence: syncModeStore.persistence
    )
    let session = SnipSnapCloudSyncSession(
      synchronize: { try await reset.synchronize() },
      enable: { try await reset.enableSync() },
      delete: { try await reset.deleteSyncedContent() },
      activeLibrary: { try await reset.activeLibrary() }
    )
    return SnipSnapCloudAppServices(
      syncedContentSettings: SyncedContentSettingsModel(mode: .iCloudSync) {
        try await session.deleteSyncedContent()
      },
      syncSession: session
    )
  }
}

private actor SimulatedCloudCollectionReset {
  private let persistence: SwiftDataSyncModePersistence
  private let old: CloudCollectionDescriptor
  private let server: FakeCloudServer
  private let transport: FakeCloudControlTransport
  private let local: SwiftDataCloudCollectionLocalStore?
  private let coordinator: CloudCollectionCoordinator?
  private var prepared = false

  init(rootURL: URL, persistence: SwiftDataSyncModePersistence) {
    self.persistence = persistence
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
    let coordinator = try await prepare()
    return syncResult(for: try await coordinator.synchronize())
  }

  func enableSync() async throws {
    let coordinator = try await prepare()
    _ = try await coordinator.enableSync()
  }

  func deleteSyncedContent() async throws {
    let coordinator = try await prepare()
    _ = try await coordinator.deleteSyncedContent()
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
    prepared = true
    return coordinator
  }
}

private func syncResult(for status: CloudCollectionStatus) -> SnipSnapCloudSyncResult {
  switch status {
  case .on:
    .contentUpdated
  case .requiresEnable:
    .noChange
  case .enabled, .adoptedRemoteCollection, .deletedSyncedContent, .purged:
    .libraryReplaced
  }
}

private struct NoopCloudCollectionSyncDriver: CloudCollectionSyncDriver {
  func fetch(_ context: CloudCollectionSyncContext) async throws {}
  func send(_ context: CloudCollectionSyncContext) async throws {}
}
