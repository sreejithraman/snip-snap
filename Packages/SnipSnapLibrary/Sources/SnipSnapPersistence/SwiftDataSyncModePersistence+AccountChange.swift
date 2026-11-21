import Foundation
import SnipSnapCore

extension SyncModeStore {
  func keepingLocally() -> SyncModeStore {
    SyncModeStore(
      id: id, kind: .localOnly, namespace: nil, relativeRoot: relativeRoot,
      syncProtocol: syncProtocol, quarantinedNamespace: namespace,
      revision: revision, lifecycle: .ready
    )
  }
}

extension SwiftDataSyncModePersistence {
  /// The only fields needed to recover a manifest written by the old Keep/Remove flow.
  struct LegacyAccountCopy: Codable, Equatable {
    let id: UUID
    let storeID: UUID
    let replacementStoreID: UUID
  }

  package func keepCloudCacheLocally(
    storeID: UUID, reason: ICloudSyncAttentionReason
  ) async throws {
    try await activeStoreTurns.withLease {
      try await self.stopSyncKeepingCache(storeID: storeID, reason: reason)
    }
  }

  private func stopSyncKeepingCache(storeID: UUID, reason: ICloudSyncAttentionReason) async throws {
    try resolveActivationWrite()
    guard manifest.activeStoreID == storeID,
      let index = manifest.stores.firstIndex(where: { $0.id == storeID }),
      let namespace = manifest.stores[index].namespace
    else { return }
    try beginStoreReplacement()
    defer { finishStoreReplacement() }
    let library = try libraryForTransition(storeID: storeID)
    // A reset already recorded in this store takes precedence over keeping the cache.
    try await library.checkContentWriteAdmission()
    var next = manifest
    if let transition = next.transition, transition.sourceStoreID == storeID,
      let candidate = next.stores.firstIndex(where: { $0.id == transition.candidateStoreID })
    {
      next.stores[candidate].lifecycle = .deleting
    }
    next.transition = nil
    next.stores[index] = next.stores[index].keepingLocally()
    next.attentionReason = reason
    try publishActivation(next)
    do {
      try await library.keepAvailableCloudAttachments(namespaceKey: namespace.namespaceKey)
    } catch {
      // The selected store and its cache paths are still intact.
      diagnostics.record(.failure(operation: "sync.keep-local", error: error, visibility: .background))
    }
  }

  /// A stopped cache retains the original engine and record state. Only its exact
  /// collection may resume, so pending deletes and edits keep their accepted bases.
  package func resumeKeptCloudCache(in namespace: ICloudSyncNamespaceBinding) throws -> Bool {
    guard let index = manifest.stores.firstIndex(where: { $0.id == manifest.activeStoreID }),
      manifest.stores[index].relativeRoot == Self.canonicalRelativeRoot(
        kind: .iCloudSync, id: manifest.activeStoreID
      ), manifest.stores[index].quarantinedNamespace == namespace
    else { return false }
    try beginStoreReplacement()
    defer { finishStoreReplacement() }
    var next = manifest
    let kept = next.stores[index]
    next.stores[index] = SyncModeStore(
      id: kept.id, kind: .iCloudSync, namespace: namespace, relativeRoot: kept.relativeRoot,
      syncProtocol: kept.syncProtocol, revision: kept.revision, lifecycle: .ready
    )
    next.attentionReason = nil
    try publishActivation(next)
    return true
  }

  static func recoverLegacyAccountCopy(_ manifest: inout Manifest, storeRoots: [UUID: URL]) throws {
    guard let legacy = manifest.accountIsolation,
      let source = manifest.stores.firstIndex(where: { $0.id == legacy.storeID }),
      let replacement = manifest.stores.firstIndex(where: { $0.id == legacy.replacementStoreID }),
      let namespace = manifest.stores[source].namespace, let root = storeRoots[legacy.storeID]
    else { return }
    // The old replacement could already contain edits. Select the original cache
    // and retain the replacement until its edits have been merged.
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("snips.store").path) {
      manifest.stores[source] = manifest.stores[source].keepingLocally()
      manifest.activeStoreID = legacy.storeID
      manifest.transition = nil
      if manifest.stores[replacement].lifecycle == .creating {
        manifest.stores[replacement].lifecycle = .deleting
        manifest.accountIsolation = nil
      } else {
        manifest.stores[replacement].lifecycle = .isolated
      }
    } else {
      manifest.activeStoreID = legacy.replacementStoreID
      manifest.stores[replacement].quarantinedNamespace = namespace
      manifest.accountIsolation = nil
    }
  }

  func finishLegacyAccountCopy() async throws {
    guard manifest.accountIsolation != nil else { return }
    try await activeStoreTurns.withLease {
      try await self.mergeLegacyAccountCopy()
    }
  }

  private func mergeLegacyAccountCopy() async throws {
    guard let legacy = manifest.accountIsolation, manifest.activeStoreID == legacy.storeID else { return }
    try beginStoreReplacement()
    defer { finishStoreReplacement() }
    let source = try libraryForTransition(storeID: legacy.replacementStoreID)
    let target = try libraryForTransition(storeID: legacy.storeID)
    let copy = try await source.transferSnapshot(revision: 0)
    _ = try await target.mergeTransferSnapshot(copy, transitionID: legacy.id)
    var next = manifest
    next.accountIsolation = nil
    if let index = next.stores.firstIndex(where: { $0.id == legacy.replacementStoreID }) {
      next.stores[index].lifecycle = .deleting
    }
    try publishActivation(next)
  }
}
