import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  static func recover(
    _ value: inout Manifest,
    rootURL: URL,
    attachmentCacheRootURL: URL? = nil
  ) throws {
    let storeRoots = try validatedStoreRoots(value.stores, rootURL: rootURL)
    // The revision advances before the store write starts. A leftover reservation means the
    // write may or may not have reached SwiftData, so keep that revision and reopen writes.
    value.writeReservation = nil
    value.migrateSetupRetryHistory()
    if case .declared(let isolation) = try value.accountIsolationPhase() {
      guard let replacementRoot = storeRoots[isolation.replacementStoreID] else {
        throw SyncModePersistenceError.invalidManifest
      }
      _ = try SwiftDataSnipLibrary(
        storeURL: replacementRoot.appendingPathComponent("snips.store"),
        attachmentCacheRootURL: cacheRootURL(
          base: attachmentCacheRootURL,
          storeID: isolation.replacementStoreID
        )
      )
      try value.swapToIsolationReplacement()
    }
    if let activeIndex = value.stores.firstIndex(where: { $0.id == value.activeStoreID }),
      value.stores[activeIndex].lifecycle == .creating
    {
      guard let root = storeRoots[value.stores[activeIndex].id] else {
        throw SyncModePersistenceError.invalidManifest
      }
      _ = try SwiftDataSnipLibrary(
        storeURL: root.appendingPathComponent("snips.store"),
        attachmentCacheRootURL: cacheRootURL(
          base: attachmentCacheRootURL,
          storeID: value.stores[activeIndex].id
        )
      )
      value.stores[activeIndex].lifecycle = .ready
    }
    if let active = value.stores.first(where: { $0.id == value.activeStoreID }),
      let root = storeRoots[active.id]
    {
      try SwiftDataSnipLibrary.StoreRetirementMarkers(
        storeURL: root.appendingPathComponent("snips.store", isDirectory: false)
      ).restore()
    }
    let removable = value.stores.filter {
      $0.id != value.activeStoreID && ($0.lifecycle == .creating || $0.lifecycle == .deleting)
    }.prefix(2)
    for store in removable {
      guard let storeRoot = storeRoots[store.id] else {
        throw SyncModePersistenceError.invalidManifest
      }
      do {
        if let cacheRoot = cacheRootURL(base: attachmentCacheRootURL, storeID: store.id),
          FileManager.default.fileExists(atPath: cacheRoot.path)
        {
          try CloudAttachmentCacheFiles.removeCacheContainer(cacheRoot)
        }
        if FileManager.default.fileExists(atPath: storeRoot.path) {
          try FileManager.default.removeItem(at: storeRoot)
        }
        value.stores.removeAll { $0.id == store.id }
        if value.transition?.candidateStoreID == store.id {
          value.stopTrackingSetupRetryCandidate()
          value.transition = nil
        }
      } catch {
        value.attentionReason = .storageFailure
      }
    }
    value.transition?.interruptByReopen()
  }

  static func validatedStoreRoots(
    _ stores: [SyncModeStore],
    rootURL: URL
  ) throws -> [UUID: URL] {
    guard rootURL.isFileURL, Set(stores.map(\.id)).count == stores.count else {
      throw SyncModePersistenceError.invalidManifest
    }
    let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let rootComponents = resolvedRoot.pathComponents
    var roots: [UUID: URL] = [:]
    for store in stores {
      guard store.relativeRoot == canonicalRelativeRoot(for: store) else {
        throw SyncModePersistenceError.invalidManifest
      }
      let resolvedStore = rootURL
        .appendingPathComponent(store.relativeRoot, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
      let storeComponents = resolvedStore.pathComponents
      guard storeComponents.count > rootComponents.count,
        Array(storeComponents.prefix(rootComponents.count)) == rootComponents
      else { throw SyncModePersistenceError.invalidManifest }
      roots[store.id] = resolvedStore
    }
    return roots
  }

  static func canonicalRelativeRoot(for store: SyncModeStore) -> String {
    canonicalRelativeRoot(kind: store.kind, id: store.id)
  }

  static func canonicalRelativeRoot(kind: SyncModeStoreKind, id: UUID) -> String {
    "stores/\(kind.rawValue)-\(id.uuidString.lowercased())"
  }

  static func validate(_ value: Manifest) throws {
    guard value.version == 2,
      let active = value.stores.first(where: { $0.id == value.activeStoreID }),
      active.lifecycle == .ready || active.lifecycle == .retired,
      Set(value.stores.map(\.id)).count == value.stores.count
    else { throw SyncModePersistenceError.invalidManifest }
    for store in value.stores {
      guard (store.kind == .iCloudSync) == (store.namespace != nil),
        (store.kind == .localOnly || store.quarantinedNamespace == nil),
        store.relativeRoot == canonicalRelativeRoot(for: store)
      else { throw SyncModePersistenceError.invalidManifest }
    }
    if let reservation = value.writeReservation {
      guard let store = value.stores.first(where: { $0.id == reservation.storeID }),
        store.id == value.activeStoreID,
        store.revision == reservation.reservedRevision
      else { throw SyncModePersistenceError.invalidManifest }
    }
    if let transition = value.transition {
      guard let source = value.stores.first(where: { $0.id == transition.sourceStoreID }),
        let candidate = value.stores.first(where: { $0.id == transition.candidateStoreID }),
        candidate.kind == transition.targetKind,
        candidate.namespace == transition.namespace,
        transition.syncProtocol == candidate.syncProtocol,
        (transition.targetKind == .iCloudSync) == (transition.namespace != nil)
      else { throw SyncModePersistenceError.invalidManifest }
      if transition.targetKind == .localOnly {
        guard source.kind == .iCloudSync,
          source.syncProtocol == transition.syncProtocol,
          candidate.syncProtocol == source.syncProtocol
        else { throw SyncModePersistenceError.invalidManifest }
      }
      let provenance = transition.seedProvenance + (transition.mergeIntent?.seedProvenance ?? [])
      guard provenance.allSatisfy({ (1...3).contains($0.digestVersion) }) else {
        throw SyncModePersistenceError.invalidManifest
      }
      if let intent = transition.mergeIntent {
        guard transition.freezeToken?.revision == intent.sourceRevision,
          intent.planDigest.count == 32,
          intent.approvedSnipIDs.isSubset(of: Set(intent.seedProvenance.map(\.candidateSnipID))),
          (intent.fullReenablePlanID.map { $0 == transition.id } ?? true)
        else { throw SyncModePersistenceError.invalidManifest }
      }
      if let attempt = transition.sendAttempt {
        let operationIdentities = Set(attempt.operations.map(\.recordIdentity))
        guard attempt.namespace == transition.namespace,
          operationIdentities.count == attempt.operations.count,
          attempt.operations.allSatisfy({ operation in
            attempt.namespace.zones.contains(
              ICloudSyncZoneBinding(
                name: operation.recordIdentity.zoneName,
                ownerName: operation.recordIdentity.ownerName
              )
            )
          })
        else { throw SyncModePersistenceError.invalidManifest }
      }
    }
    _ = try value.accountIsolationPhase()
  }

  static func write(
    _ manifest: Manifest,
    to url: URL,
    using writer: ManifestWriter
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try writer(encoder.encode(manifest), url)
  }
}
