import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

private struct AccountGuardedCollectionTransport: CloudCollectionControlTransport {
  let base: any CloudCollectionControlTransport
  let accountGuard: @Sendable () async throws -> Void

  func fetchControl() async throws -> CloudCollectionControlRecord? {
    try await accountGuard()
    let value = try await base.fetchControl()
    try await accountGuard()
    return value
  }

  func createZones(_ zones: Set<CloudZoneID>) async throws {
    try await accountGuard()
    try await base.createZones(zones)
    try await accountGuard()
  }

  func saveControl(
    _ descriptor: CloudCollectionDescriptor,
    replacing version: Data?
  ) async throws -> CloudCollectionControlSaveResult {
    try await accountGuard()
    let value = try await base.saveControl(descriptor, replacing: version)
    try await accountGuard()
    return value
  }

  func deleteZones(_ zones: Set<CloudZoneID>) async throws {
    try await accountGuard()
    try await base.deleteZones(zones)
    try await accountGuard()
  }
}

private struct AccountGuardedCollectionLocalStore: CloudCollectionLocalStore {
  let base: any CloudCollectionLocalStore
  let accountGuard: @Sendable () async throws -> Void

  func state() async throws -> CloudCollectionLocalState { try await checked { try await base.state() } }
  func stageCleanup(_ zones: Set<CloudZoneID>) async throws { try await checked { try await base.stageCleanup(zones) } }
  func finishCleanup(_ zones: Set<CloudZoneID>) async throws { try await checked { try await base.finishCleanup(zones) } }
  func adopt(_ namespace: CloudSyncNamespace) async throws { try await checked { try await base.adopt(namespace) } }
  func markPurged() async throws { try await checked { try await base.markPurged() } }
  func markDeletionPending() async throws { try await checked { try await base.markDeletionPending() } }
  func markDeletionCompleted() async throws { try await checked { try await base.markDeletionCompleted() } }
  func beginEncryptedDataReset(from namespace: CloudSyncNamespace) async throws { try await checked { try await base.beginEncryptedDataReset(from: namespace) } }
  func restartEncryptedDataReset(from namespace: CloudSyncNamespace) async throws { try await checked { try await base.restartEncryptedDataReset(from: namespace) } }
  func prepareEncryptedDataResetEnable() async throws { try await checked { try await base.prepareEncryptedDataResetEnable() } }
  func chooseEncryptedDataReset(_ choice: EncryptedDataResetChoice, proposal: CloudCollectionDescriptor?) async throws { try await checked { try await base.chooseEncryptedDataReset(choice, proposal: proposal) } }
  func activateResetCollection(_ namespace: CloudSyncNamespace, recoveryStoreID: UUID?, seedRecovery: Bool, resetID: UUID) async throws { try await checked { try await base.activateResetCollection(namespace, recoveryStoreID: recoveryStoreID, seedRecovery: seedRecovery, resetID: resetID) } }
  func finishEncryptedDataReset() async throws { try await checked { try await base.finishEncryptedDataReset() } }

  private func checked<T: Sendable>(
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await accountGuard()
    let value = try await operation()
    try await accountGuard()
    return value
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
  private var needsAnotherSync = false

  public init(syncWhenPossible: @escaping SyncAction) {
    syncAction = syncWhenPossible
  }

  public func launch() async { await run() }
  public func foreground() async { await run() }

  private func run() async {
    if isSyncing {
      needsAnotherSync = true
      return
    }
    isSyncing = true
    repeat {
      needsAnotherSync = false
      await syncAction()
    } while needsAnotherSync
    isSyncing = false
  }
}

public enum SnipSnapCloudSyncResult: Equatable, Sendable {
  case noChange
  case contentUpdated
  case libraryReplaced
  case iCloudSyncSettingUp
  case iCloudSyncEnabled
  case oldSyncedContentRemovalPending
  case oldSyncedContentRemovalCompleted
  case encryptedDataResetRequiresChoice
  case syncKeptOff
}

enum PendingICloudSyncEnable {
  private static let fileName = "icloud-sync-enable-pending"
  private static let failedValue = Data("needs-attention".utf8)

  static func exists(at rootURL: URL) -> Bool {
    guard let data = try? Data(contentsOf: url(at: rootURL)) else { return false }
    return data != failedValue
  }

  static func needsAttention(at rootURL: URL) -> Bool {
    (try? Data(contentsOf: url(at: rootURL))) == failedValue
  }

  static func mark(at rootURL: URL) throws {
    try DurableFile.write(Data("pending".utf8), to: url(at: rootURL))
  }

  static func markNeedsAttention(at rootURL: URL) {
    try? DurableFile.write(failedValue, to: url(at: rootURL))
  }

  static func clear(at rootURL: URL) {
    try? FileManager.default.removeItem(at: url(at: rootURL))
  }

  private static func url(at rootURL: URL) -> URL {
    rootURL.appendingPathComponent(fileName, isDirectory: false)
  }
}

package actor SnipSnapICloudSyncLifecycle {
  package typealias RecordTransportFactory = @Sendable (
    CloudCollectionSyncContext
  ) -> any CloudRecordTransport

  private static let importID = UUID(
    uuidString: "7b4f8730-42bd-4b56-9117-cc7db03ec46e"
  )!
  private let rootURL: URL
  private let sourceLibrary: any SnipLibrary
  private let cloudScope: String
  private var accountLineage: String
  private let accountLineageProvider: (@Sendable () async throws -> String)?
  private let accountStateSource: (any ICloudAccountStateSource)?
  private let ownerName: String
  private let controlTransport: any CloudCollectionControlTransport
  private let makeRecordTransport: RecordTransportFactory
  private let makeDescriptor: CloudCollectionCoordinator.DescriptorFactory
  private let reservedZones: Set<CloudZoneID>
  private let operationGate: CloudCollectionOperationGate
  private let automaticResultHandler: @Sendable (SnipSnapCloudSyncResult) async -> Void
  private var persistence: SwiftDataSyncModePersistence?
  private var collectionCoordinator: CloudCollectionCoordinator?

  package init(
    rootURL: URL,
    sourceLibrary: any SnipLibrary,
    syncModeStore: SnipSyncModeStore?,
    cloudScope: String,
    accountLineage: String,
    accountLineageProvider: (@Sendable () async throws -> String)? = nil,
    accountStateSource: (any ICloudAccountStateSource)? = nil,
    ownerName: String,
    controlTransport: any CloudCollectionControlTransport,
    makeRecordTransport: @escaping RecordTransportFactory,
    makeDescriptor: @escaping CloudCollectionCoordinator.DescriptorFactory,
    reservedZones: Set<CloudZoneID> = [],
    operationGate: CloudCollectionOperationGate = CloudCollectionOperationGate(),
    automaticResultHandler: @escaping @Sendable (SnipSnapCloudSyncResult) async -> Void = { _ in }
  ) {
    self.rootURL = rootURL
    self.sourceLibrary = sourceLibrary
    persistence = syncModeStore?.persistence
    self.cloudScope = cloudScope
    self.accountLineage = accountLineage
    self.accountLineageProvider = accountLineageProvider
    self.accountStateSource = accountStateSource
    self.ownerName = ownerName
    self.controlTransport = controlTransport
    self.makeRecordTransport = makeRecordTransport
    self.makeDescriptor = makeDescriptor
    self.reservedZones = reservedZones
    self.operationGate = operationGate
    self.automaticResultHandler = automaticResultHandler
  }

  package func enableICloudSync() async throws -> SyncedContentEnableOutcome {
    try PendingICloudSyncEnable.mark(at: rootURL)
    return try await resumePendingEnable()
  }

  private func resumePendingEnable() async throws -> SyncedContentEnableOutcome {
    do {
      return try await finishPendingEnable()
    } catch where Self.isRetryableSetupError(error) {
      return .settingUp
    } catch {
      PendingICloudSyncEnable.markNeedsAttention(at: rootURL)
      throw error
    }
  }

  package func cancelPendingEnable() async throws {
    PendingICloudSyncEnable.clear(at: rootURL)
    let activePersistence: SwiftDataSyncModePersistence?
    if let persistence {
      activePersistence = persistence
    } else {
      let manifest = rootURL.appendingPathComponent("activation.json", isDirectory: false)
      activePersistence = FileManager.default.fileExists(atPath: manifest.path)
        ? try SwiftDataSyncModePersistence(rootURL: rootURL) : nil
    }
    try await activePersistence?.cancelPendingICloudEnable()
    persistence = activePersistence
    collectionCoordinator = nil
  }

  private func finishPendingEnable() async throws -> SyncedContentEnableOutcome {
    if let accountLineageProvider {
      accountLineage = try await accountLineageProvider()
    }
    try await requireAccountLineage(accountLineage)
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
      PendingICloudSyncEnable.clear(at: rootURL)
      return .enabled
    }
    if reset != nil {
      throw CloudCollectionError.encryptedDataResetRequiresChoice
    }
    let enableLineage = accountLineage
    let enableGuard: @Sendable () async throws -> Void = { [weak self] in
      guard let self else { return }
      try await self.requireAccountLineage(enableLineage)
    }
    let bootstrap = CloudCollectionBootstrapper(
      ownerName: ownerName,
      localStore: AccountGuardedCollectionLocalStore(
        base: collectionLocal,
        accountGuard: enableGuard
      ),
      transport: AccountGuardedCollectionTransport(
        base: controlTransport,
        accountGuard: enableGuard
      ),
      makeDescriptor: makeDescriptor,
      reservedZones: reservedZones
    )
    let descriptor = try await bootstrap.activeOrCreate()
    try await requireAccountLineage(accountLineage)
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
      },
      accountStateSource: accountStateSource
    )
    let status = try await mode.enableOrRetry()
    switch status.state {
    case .on:
      break
    case .settingUp, .syncing:
      return .settingUp
    case .needsAttention, .off:
      throw CloudCollectionError.syncNeedsAttention
    }
    collectionCoordinator = try makeCollectionCoordinator(modePersistence)
    PendingICloudSyncEnable.clear(at: rootURL)
    return .enabled
  }

  package func synchronize() async throws -> SnipSnapCloudSyncResult {
    if PendingICloudSyncEnable.exists(at: rootURL) {
      return switch try await resumePendingEnable() {
      case .settingUp: .iCloudSyncSettingUp
      case .enabled: .iCloudSyncEnabled
      }
    }
    guard let coordinator = try await activeCollectionCoordinator() else { return .noChange }
    if let persistence,
      let binding = try await persistence.snapshot().activeStore.namespace,
      let cached = try? cachedDescriptor(for: binding)
    {
      try await coordinator.prepareAutomaticSync(cached)
    }
    return syncResult(for: try await coordinator.synchronize())
  }

  package func scheduleAutomaticSync() async throws {
    guard let coordinator = try await locallyActiveCollectionCoordinator(),
      let persistence,
      let binding = try await persistence.snapshot().activeStore.namespace,
      let cached = try? cachedDescriptor(for: binding)
    else { return }
    try await coordinator.prepareAutomaticSync(cached)
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
      },
      accountStateSource: accountStateSource
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
    guard persistence != nil else {
      return SnipSnapCloudActiveLibrary(library: sourceLibrary, recoveryScope: nil)
    }
    let refreshed = try SwiftDataSyncModePersistence(rootURL: rootURL)
    persistence = refreshed
    collectionCoordinator = nil
    let snapshot = try await refreshed.snapshot()
    return SnipSnapCloudActiveLibrary(
      library: try await refreshed.activeLibrary(),
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

  private nonisolated static func isRetryableSetupError(_ error: Error) -> Bool {
    if CloudKitRetryPolicy.isTransient(error) { return true }
    if let error = error as? CloudTransportError {
      return error == .fetchFailed || error == .sendFailed
    }
    if error is CloudSyncRetryableError { return true }
    return false
  }

  private func activeCollectionCoordinator() async throws -> CloudCollectionCoordinator? {
    try await requireMatchingAccountForActiveStore()
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

  private func locallyActiveCollectionCoordinator() async throws
    -> CloudCollectionCoordinator?
  {
    if let collectionCoordinator { return collectionCoordinator }
    guard let persistence else { return nil }
    let snapshot = try await persistence.snapshot()
    guard snapshot.activeStore.kind == .iCloudSync,
      snapshot.accountIsolation == nil,
      snapshot.activeStore.namespace != nil
    else { return nil }
    let coordinator = try makeCollectionCoordinator(persistence)
    collectionCoordinator = coordinator
    return coordinator
  }

  private func requireMatchingAccountForActiveStore() async throws {
    guard let persistence, let accountStateSource else { return }
    let snapshot = try await persistence.snapshot()
    guard snapshot.activeStore.kind == .iCloudSync else { return }
    guard snapshot.accountIsolation == nil else {
      collectionCoordinator = nil
      throw CloudCollectionError.syncNeedsAttention
    }
    guard let binding = snapshot.activeStore.namespace else {
      collectionCoordinator = nil
      throw CloudCollectionError.syncNeedsAttention
    }
    switch await accountStateSource.currentAccountState() {
    case .available(let currentLineage) where currentLineage == binding.accountLineage:
      return
    case .available:
      _ = try await persistence.isolateActiveCloudStore(reason: .accountChanged)
    case .noAccount:
      _ = try await persistence.isolateActiveCloudStore(reason: .signedOut)
    case .restricted, .temporarilyUnavailable, .couldNotDetermine:
      throw CloudSyncRetryableError.itemFailure
    }
    collectionCoordinator = nil
    throw CloudCollectionError.syncNeedsAttention
  }

  private func requireAccountLineage(_ expected: String) async throws {
    guard let accountStateSource else { return }
    switch await accountStateSource.currentAccountState() {
    case .available(let current) where current == expected:
      return
    case .available, .noAccount:
      throw CloudCollectionError.syncNeedsAttention
    case .restricted, .temporarilyUnavailable, .couldNotDetermine:
      throw CloudSyncRetryableError.itemFailure
    }
  }

  private func requireCurrentCollectionForRecordWork() async throws {
    try await requireMatchingAccountForActiveStore()
    guard let persistence else { throw CloudCollectionError.noActiveCollection }
    let snapshot = try await persistence.snapshot()
    guard snapshot.activeStore.kind == .iCloudSync,
      let binding = snapshot.activeStore.namespace,
      let remote = try await controlTransport.fetchControl()
    else {
      collectionCoordinator = nil
      throw CloudCollectionError.syncNeedsAttention
    }
    try remote.descriptor.validate(ownerName: ownerName, reservedZones: reservedZones)
    guard namespaceBinding(for: remote.descriptor) == binding else {
      collectionCoordinator = nil
      throw CloudCollectionError.syncNeedsAttention
    }
  }

  private func makeCollectionCoordinator(
    _ persistence: SwiftDataSyncModePersistence
  ) throws -> CloudCollectionCoordinator {
    let local = try SwiftDataCloudCollectionLocalStore(
      rootURL: rootURL,
      persistence: persistence
    )
    let expectedLineage = accountLineage
    let accountGuard: @Sendable () async throws -> Void = { [weak self] in
      guard let self else { return }
      try await self.requireAccountLineage(expectedLineage)
    }
    let guardedLocal = AccountGuardedCollectionLocalStore(
      base: local,
      accountGuard: accountGuard
    )
    let guardedTransport = AccountGuardedCollectionTransport(
      base: controlTransport,
      accountGuard: accountGuard
    )
    let driver = CloudFullRecordCollectionSyncDriver(
      persistence: persistence,
      makeTransport: makeRecordTransport,
      beforeAutomaticApply: { [weak self] in
        guard let self else { return }
        try await self.requireCurrentCollectionForRecordWork()
      },
      beforeAutomaticSchedule: { [weak self] context in
        guard let self else { return }
        try await self.requireLocalRecordContext(context)
      },
      beforeEngineStateSave: { [weak self] context in
        guard let self else { return }
        try await self.requireLocalRecordContext(context)
      },
      automaticResultHandler: { [automaticResultHandler] result in
        await automaticResultHandler(
          result == .encryptedDataReset ? .encryptedDataResetRequiresChoice : .contentUpdated
        )
      }
    )
    return CloudCollectionCoordinator(
      cloudScope: cloudScope,
      accountLineage: accountLineage,
      ownerName: ownerName,
      localStore: guardedLocal,
      transport: guardedTransport,
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

  private func requireLocalRecordContext(
    _ context: CloudCollectionSyncContext
  ) async throws {
    guard let persistence,
      try await persistence.snapshot().activeStore.namespace == namespaceBinding(
        for: CloudCollectionDescriptor(
          generation: context.namespace.generation,
          metadataZone: context.metadataZone,
          payloadZone: context.payloadZone
        )
      )
    else { throw CloudCollectionError.syncNeedsAttention }
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
