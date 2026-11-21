import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// Keeps reset bookkeeping beside the sync-mode manifest and preserves replaced stores.
package actor SwiftDataCloudCollectionLocalStore: CloudCollectionLocalStore {
  private struct StoredState: Codable {
    var version = 1
    var hasSyncedBefore = false
    var cleanupZones: Set<CloudZoneID> = []
    var deletionState: CloudCollectionDeletionState? = CloudCollectionDeletionState.none
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
      stored = StoredState()
      try Self.write(stored, to: stateURL)
    }
  }

  package func state() async throws -> CloudCollectionLocalState {
    let snapshot = try await persistence.snapshot()
    let namespace = snapshot.activeStore.namespace.map(Self.namespace)
    return CloudCollectionLocalState(
      hasSyncedBefore: stored.hasSyncedBefore || namespace != nil || snapshot.keptAfterCloudReset,
      activeNamespace: namespace,
      cleanupZones: stored.cleanupZones,
      deletionState: stored.deletionState ?? .none,
      keptAfterReset: snapshot.keptAfterCloudReset
    )
  }

  package func stageCleanup(_ zones: Set<CloudZoneID>) throws {
    guard !zones.isEmpty else { return }
    try update { $0.cleanupZones.formUnion(zones) }
  }

  package func finishCleanup(_ zones: Set<CloudZoneID>) throws {
    guard !zones.isEmpty else { return }
    try update { $0.cleanupZones.subtract(zones) }
  }

  package func adopt(_ namespace: CloudSyncNamespace) async throws {
    try update { $0.hasSyncedBefore = true }
    try await persistence.activateEmptyCollection(namespace: namespace.binding)
  }

  package func stopAfterDataReset(in namespace: CloudSyncNamespace) async throws -> Bool {
    let store = try await persistence.snapshot().activeStore
    return try await persistence.keepCloudCacheLocally(
      storeID: store.id, namespace: namespace.binding, reason: .namespaceChanged
    ) == .keptAfterReset
  }

  package func markDeletionPending() throws {
    try update { $0.deletionState = .pending }
  }

  package func markDeletionCompleted() throws {
    try update { $0.deletionState = .completed }
  }

  private func update(_ transition: (inout StoredState) -> Void) throws {
    var next = stored
    transition(&next)
    try Self.write(next, to: stateURL)
    stored = next
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
