import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

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
    accountLineageProvider: (@Sendable () async throws -> String)? = nil,
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
    self.accountLineageProvider = accountLineageProvider
    self.ownerName = ownerName
    self.controlTransport = controlTransport
    self.makeRecordTransport = makeRecordTransport
    self.makeDescriptor = makeDescriptor
    self.reservedZones = reservedZones
    self.operationGate = operationGate
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
