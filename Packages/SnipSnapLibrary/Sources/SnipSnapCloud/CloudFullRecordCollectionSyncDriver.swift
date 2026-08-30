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

  package func fetch(
    _ context: CloudCollectionSyncContext
  ) async throws -> CloudCollectionFetchResult {
    let (coordinator, store) = try await recordCoordinator(context)
    try await coordinator.fetchRemote()
    return await store.takeEncryptedDataResetSignal() ? .encryptedDataReset : .fetched
  }

  package func send(
    _ context: CloudCollectionSyncContext
  ) async throws -> CloudCollectionSendResult {
    let (coordinator, store) = try await recordCoordinator(context)
    try await coordinator.sendPending()
    return await store.takeEncryptedDataResetSignal() ? .encryptedDataReset : .sent
  }

  private func recordCoordinator(
    _ context: CloudCollectionSyncContext
  ) async throws -> (CloudFullSyncCoordinator, CloudFullSyncPersistence) {
    let storage = try await persistence.snapshot()
    guard storage.activeStore.namespace == binding(context.namespace),
      storage.activeStore.kind == .iCloudSync
    else { throw SyncModePersistenceError.namespaceMismatch }
    let library = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: context.namespace,
      dataZone: context.metadataZone,
      payloadZone: context.payloadZone
    )
    return (
      CloudFullSyncCoordinator(store: store, transport: makeTransport(context)),
      store
    )
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
  package static let productionOperationGate = CloudCollectionOperationGate()
  package static let productionControlID = CloudRecordID(
    zone: CloudZoneID(name: "SnipSnapControl", ownerName: CKCurrentUserDefaultName),
    name: "active-collection"
  )

  @MainActor
  package static func settingsModel(
    for coordinator: CloudCollectionCoordinator
  ) -> SyncedContentSettingsModel {
    SyncedContentSettingsModel(
      mode: .iCloudSync,
      enableAction: { _ = try await coordinator.enableSync() },
      deleteAction: {
        deleteOutcome(for: try await coordinator.deleteSyncedContent())
      },
      encryptedDataResetAction: { choice in
        resolutionOutcome(for: try await coordinator.resolveEncryptedDataReset(choice))
      }
    )
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
      reservedZones: [controlID.zone],
      operationGate: productionOperationGate
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

@MainActor
public final class SnipSnapCloudLifecycleHooks {
  public typealias SyncAction = @MainActor @Sendable () async -> Void
  private let syncAction: SyncAction
  private var isSyncing = false

  public init(syncWhenPossible: @escaping SyncAction) {
    syncAction = syncWhenPossible
  }

  public func launch() async { await run() }
  public func foreground() async { await run() }

  private func run() async {
    guard !isSyncing else { return }
    isSyncing = true
    defer { isSyncing = false }
    await syncAction()
  }
}

public enum SnipSnapCloudSyncResult: Equatable, Sendable {
  case noChange
  case contentUpdated
  case libraryReplaced
  case oldSyncedContentRemovalPending
  case oldSyncedContentRemovalCompleted
  case encryptedDataResetRequiresChoice
  case syncKeptOff
}

package actor SnipSnapCloudModeLifecycle {
  package typealias RecordTransportFactory = @Sendable (
    CloudCollectionSyncContext
  ) -> any CloudRecordTransport

  private static let importID = UUID(
    uuidString: "7b4f8730-42bd-4b56-9117-cc7db03ec46e"
  )!
  private let rootURL: URL
  private let sourceLibrary: any SnipLibrary
  private let cloudScope: String
  private let accountLineage: String
  private let ownerName: String
  private let controlTransport: any CloudCollectionControlTransport
  private let makeRecordTransport: RecordTransportFactory
  private let makeDescriptor: CloudCollectionCoordinator.DescriptorFactory
  private let reservedZones: Set<CloudZoneID>
  private let operationGate: CloudCollectionOperationGate
  private var persistence: SwiftDataSyncModePersistence?
  private var collectionCoordinator: CloudCollectionCoordinator?

  package init(
    rootURL: URL,
    sourceLibrary: any SnipLibrary,
    syncModeStore: SnipSyncModeStore?,
    cloudScope: String,
    accountLineage: String,
    ownerName: String,
    controlTransport: any CloudCollectionControlTransport,
    makeRecordTransport: @escaping RecordTransportFactory,
    makeDescriptor: @escaping CloudCollectionCoordinator.DescriptorFactory,
    reservedZones: Set<CloudZoneID> = [],
    operationGate: CloudCollectionOperationGate = CloudCollectionOperationGate()
  ) {
    self.rootURL = rootURL
    self.sourceLibrary = sourceLibrary
    persistence = syncModeStore?.persistence
    self.cloudScope = cloudScope
    self.accountLineage = accountLineage
    self.ownerName = ownerName
    self.controlTransport = controlTransport
    self.makeRecordTransport = makeRecordTransport
    self.makeDescriptor = makeDescriptor
    self.reservedZones = reservedZones
    self.operationGate = operationGate
  }

  package func enableICloudSync() async throws {
    let modePersistence = try await modePersistenceAndImportedSource()
    let collectionLocal = try SwiftDataCloudCollectionLocalStore(
      rootURL: rootURL,
      persistence: modePersistence
    )
    let reset = try await collectionLocal.state().encryptedDataReset
    if reset?.choice == .keepSyncOff {
      let coordinator = try makeCollectionCoordinator(modePersistence)
      _ = try await coordinator.enableSync()
      collectionCoordinator = coordinator
      return
    }
    if reset != nil {
      throw CloudCollectionError.encryptedDataResetRequiresChoice
    }
    let bootstrap = CloudCollectionBootstrapper(
      ownerName: ownerName,
      localStore: collectionLocal,
      transport: controlTransport,
      makeDescriptor: makeDescriptor,
      reservedZones: reservedZones
    )
    let descriptor = try await bootstrap.activeOrCreate()
    let namespace = descriptor.namespace(
      cloudScope: cloudScope,
      accountLineage: accountLineage
    )
    let mode = ICloudSyncModeCoordinator(
      persistence: modePersistence,
      namespace: namespace,
      textZone: descriptor.metadataZone,
      payloadZone: descriptor.payloadZone,
      makeTransport: { [makeRecordTransport] in
        makeRecordTransport(
          CloudCollectionSyncContext(
            namespace: namespace,
            metadataZone: descriptor.metadataZone,
            payloadZone: descriptor.payloadZone
          )
        )
      }
    )
    let status = try await mode.enableOrRetry()
    guard status.state == .on else { throw CloudSyncRetryableError.itemFailure }
    collectionCoordinator = try makeCollectionCoordinator(modePersistence)
  }

  package func synchronize() async throws -> SnipSnapCloudSyncResult {
    guard let coordinator = try await activeCollectionCoordinator() else { return .noChange }
    return syncResult(for: try await coordinator.synchronize())
  }

  package func disableICloudSync(_ choice: SyncedContentDisableChoice) async throws {
    guard let persistence else { return }
    if choice == .refreshThenCopy {
      let result = try await synchronize()
      if result == .encryptedDataResetRequiresChoice {
        throw CloudCollectionError.encryptedDataResetRequiresChoice
      }
    }
    let snapshot = try await persistence.snapshot()
    guard snapshot.activeStore.kind == .iCloudSync,
      let activeBinding = snapshot.activeStore.namespace
    else { return }
    let descriptor = try await descriptor(
      for: activeBinding,
      allowsCachedRoles: choice == .useCurrentCache
    )
    let namespace = descriptor.namespace(
      cloudScope: activeBinding.scope,
      accountLineage: activeBinding.accountLineage
    )
    let mode = ICloudSyncModeCoordinator(
      persistence: persistence,
      namespace: namespace,
      textZone: descriptor.metadataZone,
      payloadZone: descriptor.payloadZone,
      makeTransport: { [makeRecordTransport] in
        makeRecordTransport(
          CloudCollectionSyncContext(
            namespace: namespace,
            metadataZone: descriptor.metadataZone,
            payloadZone: descriptor.payloadZone
          )
        )
      }
    )
    let optOutChoice: ICloudSyncOptOutChoice = choice == .refreshThenCopy
      ? .refreshThenCopy : .useCurrentCacheAfterStaleDataWarning
    let status = try await mode.optOut(optOutChoice)
    guard status.state == .off else { throw CloudSyncRetryableError.itemFailure }
    collectionCoordinator = nil
  }

  package func deleteSyncedContent() async throws -> SyncedContentDeleteOutcome {
    guard let coordinator = try await activeCollectionCoordinator() else {
      throw CloudCollectionError.noActiveCollection
    }
    return deleteOutcome(for: try await coordinator.deleteSyncedContent())
  }

  package func resolveEncryptedDataReset(
    _ choice: EncryptedDataResetChoice
  ) async throws -> SnipSnapCloudSyncResult {
    guard let coordinator = try await activeCollectionCoordinator() else {
      throw CloudCollectionError.noActiveCollection
    }
    return syncResult(for: try await coordinator.resolveEncryptedDataReset(choice))
  }

  package func activeLibrary() async throws -> SnipSnapCloudActiveLibrary {
    guard let persistence else {
      return SnipSnapCloudActiveLibrary(library: sourceLibrary, recoveryScope: nil)
    }
    let snapshot = try await persistence.snapshot()
    return SnipSnapCloudActiveLibrary(
      library: try await persistence.activeLibrary(),
      recoveryScope: SnipRecoveryScopeFactory.scope(
        forActiveCloudNamespace: snapshot.activeStore.namespace
      )
    )
  }

  private func modePersistenceAndImportedSource() async throws -> SwiftDataSyncModePersistence {
    let value: SwiftDataSyncModePersistence
    if let persistence {
      value = persistence
    } else {
      value = try SwiftDataSyncModePersistence(rootURL: rootURL)
      persistence = value
    }
    let marker = rootURL.appendingPathComponent("local-source-imported", isDirectory: false)
    guard !FileManager.default.fileExists(atPath: marker.path) else { return value }
    let snapshot = try await sourceLibrary.transferSnapshot(revision: 0)
    let active = try await value.snapshot().activeStore
    let target = try await value.libraryForTransition(storeID: active.id)
    _ = try await target.mergeTransferSnapshot(snapshot, transitionID: Self.importID)
    try DurableFile.write(Data("1".utf8), to: marker)
    return value
  }

  private func activeCollectionCoordinator() async throws -> CloudCollectionCoordinator? {
    if let collectionCoordinator { return collectionCoordinator }
    guard let persistence else { return nil }
    let snapshot = try await persistence.snapshot()
    if snapshot.activeStore.namespace == nil {
      let local = try SwiftDataCloudCollectionLocalStore(
        rootURL: rootURL,
        persistence: persistence
      )
      guard try await local.state().encryptedDataReset != nil else { return nil }
    }
    let coordinator = try makeCollectionCoordinator(persistence)
    collectionCoordinator = coordinator
    return coordinator
  }

  private func makeCollectionCoordinator(
    _ persistence: SwiftDataSyncModePersistence
  ) throws -> CloudCollectionCoordinator {
    let local = try SwiftDataCloudCollectionLocalStore(
      rootURL: rootURL,
      persistence: persistence
    )
    let driver = CloudFullRecordCollectionSyncDriver(
      persistence: persistence,
      makeTransport: makeRecordTransport
    )
    return CloudCollectionCoordinator(
      cloudScope: cloudScope,
      accountLineage: accountLineage,
      ownerName: ownerName,
      localStore: local,
      transport: controlTransport,
      syncDriver: driver,
      makeDescriptor: makeDescriptor,
      reservedZones: reservedZones,
      operationGate: operationGate
    )
  }

  private func descriptor(
    for binding: ICloudSyncNamespaceBinding,
    allowsCachedRoles: Bool
  ) async throws -> CloudCollectionDescriptor {
    do {
      if let remote = try await controlTransport.fetchControl() {
        try remote.descriptor.validate(ownerName: ownerName, reservedZones: reservedZones)
        guard namespaceBinding(for: remote.descriptor) == binding else {
          throw CloudCollectionError.invalidDescriptor
        }
        return remote.descriptor
      }
    } catch where allowsCachedRoles {
      return try cachedDescriptor(for: binding)
    }
    guard allowsCachedRoles else { throw CloudCollectionError.noActiveCollection }
    return try cachedDescriptor(for: binding)
  }

  private func cachedDescriptor(
    for binding: ICloudSyncNamespaceBinding
  ) throws -> CloudCollectionDescriptor {
    let zones = binding.zones.map { CloudZoneID(name: $0.name, ownerName: $0.ownerName) }
    guard let metadata = zones.first(where: { $0.name.hasPrefix("snips-") }),
      let payload = zones.first(where: { $0.name.hasPrefix("payloads-") })
    else { throw CloudCollectionError.invalidDescriptor }
    let descriptor = CloudCollectionDescriptor(
      generation: binding.generation,
      metadataZone: metadata,
      payloadZone: payload
    )
    try descriptor.validate(ownerName: ownerName, reservedZones: reservedZones)
    return descriptor
  }

  private func namespaceBinding(
    for descriptor: CloudCollectionDescriptor
  ) -> ICloudSyncNamespaceBinding {
    ICloudSyncNamespaceBinding(
      scope: cloudScope,
      accountLineage: accountLineage,
      generation: descriptor.generation,
      zones: Set(descriptor.zones.map {
        ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
      })
    )
  }
}

/// One app-owned lane for normal sync, enabling sync, and deleting synced content.
public actor SnipSnapCloudSyncSession {
  package typealias Action = @Sendable () async throws -> Void
  package typealias DeleteAction = @Sendable () async throws -> SyncedContentDeleteOutcome
  package typealias SynchronizeAction = @Sendable () async throws -> SnipSnapCloudSyncResult
  package typealias LibraryAction = @Sendable () async throws -> SnipSnapCloudActiveLibrary
  package typealias EncryptedDataResetAction = @Sendable (
    EncryptedDataResetChoice
  ) async throws -> SnipSnapCloudSyncResult

  private let synchronizeAction: SynchronizeAction
  private let enableAction: Action
  private let disableAction: SyncedContentSettingsModel.DisableAction
  private let deleteAction: DeleteAction
  private let libraryAction: LibraryAction
  private let encryptedDataResetAction: EncryptedDataResetAction

  package init(
    coordinator: CloudCollectionCoordinator,
    persistence: SwiftDataSyncModePersistence
  ) {
    synchronizeAction = {
      syncResult(for: try await coordinator.synchronize())
    }
    enableAction = { _ = try await coordinator.enableSync() }
    disableAction = { _ in throw CloudCollectionError.noActiveCollection }
    deleteAction = { deleteOutcome(for: try await coordinator.deleteSyncedContent()) }
    encryptedDataResetAction = { choice in
      syncResult(for: try await coordinator.resolveEncryptedDataReset(choice))
    }
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
    disable: @escaping SyncedContentSettingsModel.DisableAction = { _ in
      throw CloudCollectionError.noActiveCollection
    },
    delete: @escaping DeleteAction,
    activeLibrary: @escaping LibraryAction,
    resolveEncryptedDataReset: @escaping EncryptedDataResetAction = { _ in
      throw CloudCollectionError.noActiveCollection
    }
  ) {
    synchronizeAction = synchronize
    enableAction = enable
    disableAction = disable
    deleteAction = delete
    libraryAction = activeLibrary
    encryptedDataResetAction = resolveEncryptedDataReset
  }

  public func synchronize() async throws -> SnipSnapCloudSyncResult {
    try await synchronizeAction()
  }
  public func enableICloudSync() async throws { try await enableAction() }
  public func disableICloudSync(_ choice: SyncedContentDisableChoice) async throws {
    try await disableAction(choice)
  }
  package func enableCollectionIfNeeded() async throws { try await enableAction() }
  public func deleteSyncedContent() async throws -> SyncedContentDeleteOutcome {
    try await deleteAction()
  }
  public func activeLibrary() async throws -> SnipSnapCloudActiveLibrary {
    try await libraryAction()
  }
  public func resolveEncryptedDataReset(
    _ choice: EncryptedDataResetChoice
  ) async throws -> SnipSnapCloudSyncResult {
    try await encryptedDataResetAction(choice)
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
    sourceLibrary: (any SnipLibrary)? = nil,
    syncModeStore: SnipSyncModeStore?,
    containerIdentifier: String?
  ) -> SnipSnapCloudAppServices {
    let identifier = containerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !identifier.isEmpty, let sourceLibrary else {
      return SnipSnapCloudAppServices(
        syncedContentSettings: SyncedContentSettingsModel(mode: .localOnly),
        syncSession: nil
      )
    }
    let namespace = SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: rootURL
    )
    let database = CKContainer(identifier: identifier).privateCloudDatabase
    let lifecycle = SnipSnapCloudModeLifecycle(
      rootURL: rootURL,
      sourceLibrary: sourceLibrary,
      syncModeStore: syncModeStore,
      cloudScope: namespace?.scope ?? "private",
      accountLineage: namespace?.accountLineage ?? identifier,
      ownerName: CKCurrentUserDefaultName,
      controlTransport: CloudKitCollectionControlTransport(
        database: database,
        controlID: CloudCollectionAssembly.productionControlID
      ),
      makeRecordTransport: { context in
        CloudKitRecordTransport(
          database: database,
          namespace: context.namespace,
          automaticallyFetchedZones: [context.metadataZone]
        )
      },
      makeDescriptor: {
        CloudCollectionDescriptor.fresh(ownerName: CKCurrentUserDefaultName)
      },
      reservedZones: [CloudCollectionAssembly.productionControlID.zone],
      operationGate: CloudCollectionAssembly.productionOperationGate
    )
    let session = SnipSnapCloudSyncSession(
      synchronize: { try await lifecycle.synchronize() },
      enable: { try await lifecycle.enableICloudSync() },
      disable: { choice in try await lifecycle.disableICloudSync(choice) },
      delete: { try await lifecycle.deleteSyncedContent() },
      activeLibrary: { try await lifecycle.activeLibrary() },
      resolveEncryptedDataReset: { choice in
        try await lifecycle.resolveEncryptedDataReset(choice)
      }
    )
    if namespace == nil {
      return SnipSnapCloudAppServices(
        syncedContentSettings: SyncedContentSettingsModel(
          mode: .localOnly,
          enableAction: { try await session.enableICloudSync() },
          disableAction: { choice in try await session.disableICloudSync(choice) },
          encryptedDataResetAction: { choice in
            resolutionOutcome(for: try await session.resolveEncryptedDataReset(choice))
          }
        ),
        syncSession: session
      )
    }
    return SnipSnapCloudAppServices(
      syncedContentSettings: SyncedContentSettingsModel(
        mode: .iCloudSync,
        enableAction: { try await session.enableICloudSync() },
        disableAction: { choice in try await session.disableICloudSync(choice) },
        deleteAction: { try await session.deleteSyncedContent() },
        encryptedDataResetAction: { choice in
          resolutionOutcome(for: try await session.resolveEncryptedDataReset(choice))
        }
      ),
      syncSession: session
    )
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
      persistence: syncModeStore.persistence,
      simulateEncryptedDataReset: ProcessInfo.processInfo.environment[
        "SNIP_SNAP_UI_TEST_ENCRYPTED_RESET"
      ] == "1"
    )
    let session = SnipSnapCloudSyncSession(
      synchronize: { try await reset.synchronize() },
      enable: { try await reset.enableSync() },
      disable: { choice in try await reset.disableICloudSync(choice) },
      delete: { try await reset.deleteSyncedContent() },
      activeLibrary: { try await reset.activeLibrary() },
      resolveEncryptedDataReset: { choice in
        try await reset.resolveEncryptedDataReset(choice)
      }
    )
    return SnipSnapCloudAppServices(
      syncedContentSettings: SyncedContentSettingsModel(
        mode: .iCloudSync,
        enableAction: { try await session.enableICloudSync() },
        disableAction: { choice in try await session.disableICloudSync(choice) },
        deleteAction: { try await session.deleteSyncedContent() },
        encryptedDataResetAction: { choice in
          resolutionOutcome(for: try await session.resolveEncryptedDataReset(choice))
        }
      ),
      syncSession: session
    )
  }

  /// Starts local-only and runs explicit enable against the fake cloud in UI tests.
  @MainActor
  public static func simulatedLocalOnlyServices(
    rootURL: URL,
    sourceLibrary: any SnipLibrary
  ) -> SnipSnapCloudAppServices {
    let server = FakeCloudServer()
    let lifecycle = SnipSnapCloudModeLifecycle(
      rootURL: rootURL,
      sourceLibrary: sourceLibrary,
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "ui-test-account",
      ownerName: "ui-test-owner",
      controlTransport: FakeCloudControlTransport(server: server),
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: server, namespace: context.namespace)
      },
      makeDescriptor: {
        CloudCollectionDescriptor.fresh(ownerName: "ui-test-owner")
      }
    )
    let session = SnipSnapCloudSyncSession(
      synchronize: { try await lifecycle.synchronize() },
      enable: { try await lifecycle.enableICloudSync() },
      disable: { choice in try await lifecycle.disableICloudSync(choice) },
      delete: { try await lifecycle.deleteSyncedContent() },
      activeLibrary: { try await lifecycle.activeLibrary() },
      resolveEncryptedDataReset: { choice in
        try await lifecycle.resolveEncryptedDataReset(choice)
      }
    )
    return SnipSnapCloudAppServices(
      syncedContentSettings: SyncedContentSettingsModel(
        mode: .localOnly,
        enableAction: { try await session.enableICloudSync() },
        disableAction: { choice in try await session.disableICloudSync(choice) }
      ),
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

  func resolveEncryptedDataReset(
    _ choice: EncryptedDataResetChoice
  ) async throws -> SnipSnapCloudSyncResult {
    let coordinator = try await prepare()
    return syncResult(for: try await coordinator.resolveEncryptedDataReset(choice))
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
  case .oldSyncedContentRemovalPending:
    .oldSyncedContentRemovalPending
  case .deletedSyncedContent:
    .oldSyncedContentRemovalCompleted
  case .enabled, .adoptedRemoteCollection, .purged:
    .libraryReplaced
  case .encryptedDataResetRequiresChoice:
    .encryptedDataResetRequiresChoice
  case .syncKeptOff:
    .syncKeptOff
  }
}

private func resolutionOutcome(
  for result: SnipSnapCloudSyncResult
) -> EncryptedDataResetResolutionOutcome {
  result == .encryptedDataResetRequiresChoice ? .requiresChoice : .resolved
}

private func resolutionOutcome(
  for status: CloudCollectionStatus
) -> EncryptedDataResetResolutionOutcome {
  status == .encryptedDataResetRequiresChoice ? .requiresChoice : .resolved
}

private func deleteOutcome(for status: CloudCollectionStatus) -> SyncedContentDeleteOutcome {
  if case .oldSyncedContentRemovalPending = status { return .removalPending }
  return .completed
}

private struct NoopCloudCollectionSyncDriver: CloudCollectionSyncDriver {
  func fetch(_ context: CloudCollectionSyncContext) async throws -> CloudCollectionFetchResult {
    .fetched
  }
  func send(_ context: CloudCollectionSyncContext) async throws -> CloudCollectionSendResult {
    .sent
  }
}
