import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// Keeps reset bookkeeping beside the sync-mode manifest and preserves replaced stores.
package actor SwiftDataCloudCollectionLocalStore: CloudCollectionLocalStore {
  private enum SyncHistory: Equatable {
    case neverSynced
    case synced
    /// An iCloud data reset that a build before #122 began and never finished. Only a device
    /// that synced could begin one; the next state read finishes it.
    case unfinishedReset(CloudEncryptedDataReset)

    var hasSynced: Bool { self != .neverSynced }

    var encryptedDataReset: CloudEncryptedDataReset? {
      guard case .unfinishedReset(let reset) = self else { return nil }
      return reset
    }
  }

  private struct Bookkeeping {
    private(set) var history: SyncHistory
    /// Zone cleanup overlaps enable, bootstrap conflicts, and Delete Synced Content, so it stays
    /// apart from the deletion phase.
    private(set) var cleanupZones: Set<CloudZoneID>
    private(set) var deletion: CloudCollectionDeletionState

    init(
      history: SyncHistory,
      cleanupZones: Set<CloudZoneID>,
      deletion: CloudCollectionDeletionState
    ) {
      self.history = history
      self.cleanupZones = cleanupZones
      self.deletion = deletion
    }

    mutating func stageCleanup(_ zones: Set<CloudZoneID>) {
      cleanupZones.formUnion(zones)
    }

    mutating func finishCleanup(_ zones: Set<CloudZoneID>) {
      cleanupZones.subtract(zones)
    }

    mutating func recordAdoption() {
      if history == .neverSynced { history = .synced }
    }

    mutating func recordPurge() {
      history = .synced
    }

    /// A record-work purge finishes only the unfinished reset of the collection it purged.
    mutating func recordPurge(of namespace: CloudSyncNamespace) {
      if let reset = history.encryptedDataReset, reset.priorNamespace != namespace { return }
      history = .synced
    }

    mutating func recordUnfinishedReset(_ reset: CloudEncryptedDataReset) {
      history = .unfinishedReset(reset)
    }

    mutating func recordDeletion(_ phase: CloudCollectionDeletionState) {
      deletion = phase
    }
  }

  /// The file form of `Bookkeeping`, readable by every earlier build. Older files may omit
  /// `deletionState`; `encryptedDataReset` is present only for an unfinished reset.
  private struct StoredState: Codable {
    let version: Int
    let hasSyncedBefore: Bool
    let cleanupZones: Set<CloudZoneID>
    let deletionState: CloudCollectionDeletionState?
    let encryptedDataReset: CloudEncryptedDataReset?

    init(_ bookkeeping: Bookkeeping) {
      version = 1
      hasSyncedBefore = bookkeeping.history.hasSynced
      cleanupZones = bookkeeping.cleanupZones
      deletionState = bookkeeping.deletion
      encryptedDataReset = bookkeeping.history.encryptedDataReset
    }

    var bookkeeping: Bookkeeping {
      let history: SyncHistory
      if let encryptedDataReset {
        history = .unfinishedReset(encryptedDataReset)
      } else {
        history = hasSyncedBefore ? .synced : .neverSynced
      }
      return Bookkeeping(
        history: history,
        cleanupZones: cleanupZones,
        deletion: deletionState ?? .none
      )
    }
  }

  private let persistence: SwiftDataSyncModePersistence
  private let stateURL: URL
  private var bookkeeping: Bookkeeping

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
        bookkeeping = value.bookkeeping
      } catch {
        throw CloudCollectionLocalStoreError.invalidState
      }
    } else {
      bookkeeping = Bookkeeping(history: .neverSynced, cleanupZones: [], deletion: .none)
      try Self.write(StoredState(bookkeeping), to: stateURL)
    }
  }

  package func state() async throws -> CloudCollectionLocalState {
    let unfinishedReset = bookkeeping.history.encryptedDataReset
    if unfinishedReset != nil {
      try await markPurged()
    }
    let snapshot = try await persistence.snapshot()
    let namespace = snapshot.activeStore.namespace.map(Self.namespace)
    return CloudCollectionLocalState(
      hasSyncedBefore: bookkeeping.history.hasSynced || namespace != nil,
      activeNamespace: namespace,
      cleanupZones: bookkeeping.cleanupZones,
      deletionState: bookkeeping.deletion,
      encryptedDataReset: unfinishedReset
    )
  }

  package func stageCleanup(_ zones: Set<CloudZoneID>) throws {
    guard !zones.isEmpty else { return }
    try update { $0.stageCleanup(zones) }
  }

  package func finishCleanup(_ zones: Set<CloudZoneID>) throws {
    guard !zones.isEmpty else { return }
    try update { $0.finishCleanup(zones) }
  }

  package func adopt(_ namespace: CloudSyncNamespace) async throws {
    try update { $0.recordAdoption() }
    try await persistence.activateEmptyCollection(namespace: namespace.binding)
  }

  package func markPurged() async throws {
    if let recoveryStoreID = bookkeeping.history.encryptedDataReset?.recoveryStoreID {
      try await persistence.discardInactiveCloudCollection(storeID: recoveryStoreID)
    }
    try await persistence.discardActiveCloudCollection()
    try update { $0.recordPurge() }
  }

  package func markPurged(ifMatching context: CloudRecordWorkContext) async throws -> UUID? {
    guard let replacementID = try await persistence.discardActiveCloudCollection(
      storeID: context.storeID, namespace: context.binding
    ) else { return nil }
    try update { $0.recordPurge(of: context.collection.namespace) }
    return replacementID
  }

  package func markDeletionPending() throws {
    try update { $0.recordDeletion(.pending) }
  }

  package func markDeletionCompleted() throws {
    try update { $0.recordDeletion(.completed) }
  }

  package func beginEncryptedDataReset(from namespace: CloudSyncNamespace) async throws {
    if let current = bookkeeping.history.encryptedDataReset {
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
    let reset = CloudEncryptedDataReset(
      priorNamespace: namespace,
      recoveryStoreID: snapshot.activeStore.id
    )
    try update { $0.recordUnfinishedReset(reset) }
    try await finishResetQuarantineIfNeeded()
  }

  private func finishResetQuarantineIfNeeded() async throws {
    guard let reset = bookkeeping.history.encryptedDataReset else { return }
    let snapshot = try await persistence.snapshot()
    if snapshot.activeStore.id == reset.recoveryStoreID {
      let library = try await persistence.libraryForTransition(storeID: snapshot.activeStore.id)
      try await library.quarantineCloudNamespaceState(
        namespaceKey: reset.priorNamespace.namespaceKey
      )
      try await persistence.activateEmptyCollection(namespace: nil)
    }
  }

  /// Writes the next bookkeeping before keeping it, so memory never runs ahead of the file.
  private func update(_ transition: (inout Bookkeeping) -> Void) throws {
    var next = bookkeeping
    transition(&next)
    try Self.write(StoredState(next), to: stateURL)
    bookkeeping = next
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
