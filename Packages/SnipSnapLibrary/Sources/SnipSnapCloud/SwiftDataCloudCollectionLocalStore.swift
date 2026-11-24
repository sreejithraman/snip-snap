import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// Keeps staged zone cleanup beside the sync-mode manifest.
package actor SwiftDataCloudCollectionLocalStore: CloudCollectionLocalStore {
  /// Earlier builds also wrote `deletionState` for the Delete Synced Content action that builds
  /// before 0.6.0 beta 124 offered. Decoding ignores that key, and the next write drops it.
  private struct StoredState: Codable {
    var version = 1
    var hasSyncedBefore = false
    var cleanupZones: Set<CloudZoneID> = []
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

  package func stopAfterDataReset(in namespace: CloudSyncNamespace) async throws -> Bool {
    let store = try await persistence.snapshot().activeStore
    return try await persistence.keepCloudCacheLocally(
      storeID: store.id, namespace: namespace.binding, reason: .namespaceChanged
    ) == .keptAfterReset
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
