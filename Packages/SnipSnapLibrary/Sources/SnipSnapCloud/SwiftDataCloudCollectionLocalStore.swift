import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// Keeps reset bookkeeping beside the sync-mode manifest and preserves replaced stores.
package actor SwiftDataCloudCollectionLocalStore: CloudCollectionLocalStore {
  private struct StoredState: Codable, Equatable {
    let version: Int
    var hasSyncedBefore: Bool
    var cleanupZones: Set<CloudZoneID>
    var deletionState: CloudCollectionDeletionState?
    var encryptedDataReset: CloudEncryptedDataReset?

    static let empty = StoredState(
      version: 1,
      hasSyncedBefore: false,
      cleanupZones: [],
      deletionState: CloudCollectionDeletionState.none,
      encryptedDataReset: nil
    )
  }

  private let persistence: SwiftDataSyncModePersistence
  private let stateURL: URL
  private var stored: StoredState

  package init(
    rootURL: URL,
    persistence: SwiftDataSyncModePersistence? = nil
  ) throws {
    self.persistence = try persistence ?? SwiftDataSyncModePersistence(rootURL: rootURL)
    stateURL = rootURL.appendingPathComponent("cloud-collection-state.json", isDirectory: false)
    if FileManager.default.fileExists(atPath: stateURL.path) {
      do {
        let values = try stateURL.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          throw CloudCollectionLocalStoreError.invalidState
        }
        let value = try JSONDecoder().decode(
          StoredState.self,
          from: Data(contentsOf: stateURL)
        )
        guard value.version == 1 else { throw CloudCollectionLocalStoreError.invalidState }
        stored = value
      } catch {
        throw CloudCollectionLocalStoreError.invalidState
      }
    } else {
      stored = .empty
      try Self.write(stored, to: stateURL)
    }
  }

  package func state() async throws -> CloudCollectionLocalState {
    let encryptedDataReset = stored.encryptedDataReset
    if encryptedDataReset != nil {
      try await markPurged()
    }
    let snapshot = try await persistence.snapshot()
    let namespace = snapshot.activeStore.namespace.map(Self.namespace)
    return CloudCollectionLocalState(
      hasSyncedBefore: stored.hasSyncedBefore || namespace != nil,
      activeNamespace: namespace,
      cleanupZones: stored.cleanupZones,
      deletionState: stored.deletionState ?? .none,
      encryptedDataReset: encryptedDataReset
    )
  }

  package func stageCleanup(_ zones: Set<CloudZoneID>) throws {
    guard !zones.isEmpty else { return }
    var next = stored
    next.cleanupZones.formUnion(zones)
    try save(next)
  }

  package func finishCleanup(_ zones: Set<CloudZoneID>) throws {
    guard !zones.isEmpty else { return }
    var next = stored
    next.cleanupZones.subtract(zones)
    try save(next)
  }

  package func adopt(_ namespace: CloudSyncNamespace) async throws {
    var next = stored
    next.hasSyncedBefore = true
    try save(next)
    try await persistence.activateEmptyCollection(namespace: namespace.binding)
  }

  package func markPurged() async throws {
    if let recoveryStoreID = stored.encryptedDataReset?.recoveryStoreID {
      try await persistence.discardInactiveCloudCollection(storeID: recoveryStoreID)
    }
    try await persistence.discardActiveCloudCollection()
    var next = stored
    next.hasSyncedBefore = true
    next.encryptedDataReset = nil
    try save(next)
  }

  package func markDeletionPending() throws {
    var next = stored
    next.deletionState = .pending
    try save(next)
  }

  package func markDeletionCompleted() throws {
    var next = stored
    next.deletionState = .completed
    try save(next)
  }

  package func beginEncryptedDataReset(from namespace: CloudSyncNamespace) async throws {
    if let current = stored.encryptedDataReset {
      guard current.priorNamespace == namespace else {
        throw CloudCollectionLocalStoreError.invalidState
      }
      try await finishResetQuarantineIfNeeded()
      return
    }
    let snapshot = try await persistence.snapshot()
    guard snapshot.activeStore.namespace.map(Self.namespace) == namespace else {
      throw CloudCollectionLocalStoreError.invalidState
    }
    var next = stored
    next.hasSyncedBefore = true
    next.encryptedDataReset = CloudEncryptedDataReset(
      priorNamespace: namespace,
      recoveryStoreID: snapshot.activeStore.id
    )
    try save(next)
    try await finishResetQuarantineIfNeeded()
  }

  private func finishResetQuarantineIfNeeded() async throws {
    guard let reset = stored.encryptedDataReset else { return }
    let snapshot = try await persistence.snapshot()
    if snapshot.activeStore.id == reset.recoveryStoreID {
      let library = try await persistence.libraryForTransition(storeID: snapshot.activeStore.id)
      try await library.quarantineCloudNamespaceState(
        namespaceKey: reset.priorNamespace.namespaceKey
      )
      try await persistence.activateEmptyCollection(namespace: nil)
    }
  }

  private func save(_ value: StoredState) throws {
    try Self.write(value, to: stateURL)
    stored = value
  }

  private static func write(_ value: StoredState, to url: URL) throws {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try DurableFile.write(encoder.encode(value), to: url)
    } catch {
      throw CloudCollectionLocalStoreError.storageFailure
    }
  }

  private static func namespace(_ value: ICloudSyncNamespaceBinding) -> CloudSyncNamespace {
    CloudSyncNamespace(
      cloudScope: value.scope,
      accountLineage: value.accountLineage,
      generation: value.generation,
      zones: Set(value.zones.map { CloudZoneID(name: $0.name, ownerName: $0.ownerName) })
    )
  }
}

package enum CloudCollectionLocalStoreError: Error, Equatable, Sendable {
  case invalidState
  case storageFailure
}

private extension CloudSyncNamespace {
  var binding: ICloudSyncNamespaceBinding {
    ICloudSyncNamespaceBinding(
      scope: cloudScope,
      accountLineage: accountLineage,
      generation: generation,
      zones: Set(zones.map { ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName) })
    )
  }
}
