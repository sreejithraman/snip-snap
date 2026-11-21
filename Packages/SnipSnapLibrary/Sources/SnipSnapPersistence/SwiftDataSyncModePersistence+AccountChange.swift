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

  package enum KeepCacheResult: Sendable {
    case kept, keptAfterReset, sourceReplaced
  }

  @discardableResult
  package func keepCloudCacheLocally(
    storeID: UUID, namespace: ICloudSyncNamespaceBinding, reason: ICloudSyncAttentionReason
  ) async throws -> KeepCacheResult {
    try await activeStoreTurns.withLease {
      try await self.stopSyncKeepingCache(storeID: storeID, namespace: namespace, reason: reason)
    }
  }

  /// Replay a reset committed before the lifecycle could stop sync. Account
  /// changes and regular sync entry points use the same source-bound transition.
  package func recoverRecordedCloudReset(
    storeID: UUID, namespace: ICloudSyncNamespaceBinding
  ) async throws -> Bool {
    try await activeStoreTurns.withLease {
      try await self.stopSyncKeepingCache(storeID: storeID, namespace: namespace, reason: nil)
        == .keptAfterReset
    }
  }

  private func stopSyncKeepingCache(
    storeID: UUID, namespace: ICloudSyncNamespaceBinding, reason: ICloudSyncAttentionReason?
  ) async throws -> KeepCacheResult {
    try resolveActivationWrite()
    guard manifest.activeStoreID == storeID,
      let index = manifest.stores.firstIndex(where: { $0.id == storeID }),
      manifest.stores[index].namespace == namespace
    else { return .sourceReplaced }
    try beginStoreReplacement()
    defer { finishStoreReplacement() }
    let library = try libraryForTransition(storeID: storeID)
    // namespaceChanged is the existing on-disk attention value reserved here for
    // a reset. Persist it before any cleanup, including for a missing control record.
    let reset: Bool
    if manifest.attentionReason == .namespaceChanged || reason == .namespaceChanged {
      reset = true
    } else {
      reset = try await library.hasPendingCloudReset()
    }
    guard let stopReason = reset ? .namespaceChanged : reason else { return .sourceReplaced }
    if reset {
      // Close outbound admission durably before retiring the old sync rows.
      if manifest.attentionReason != .namespaceChanged { try recordAttention(.namespaceChanged) }
      try await finishReset(library, namespace: namespace, storeID: storeID)
    } else {
      await library.keepAvailableCloudAttachments(namespaceKey: namespace.namespaceKey)
    }
    try PendingICloudSyncEnable.clear(at: rootURL)
    var next = manifest
    if let transition = next.transition, transition.sourceStoreID == storeID,
      let candidate = next.stores.firstIndex(where: { $0.id == transition.candidateStoreID })
    {
      next.stores[candidate].lifecycle = .deleting
    }
    next.transition = nil
    next.stores[index] = next.stores[index].keepingLocally()
    next.attentionReason = stopReason
    try publishActivation(next)
    return reset ? .keptAfterReset : .kept
  }

  private func finishReset(
    _ library: SwiftDataSnipLibrary, namespace: ICloudSyncNamespaceBinding, storeID: UUID
  ) async throws {
    try await library.promoteAvailableCloudAttachments(namespaceKey: namespace.namespaceKey)
    try await library.clearCloudSyncState(namespaceKey: namespace.namespaceKey, afterReset: true)
    try Self.clearLegacyCloudReset(at: rootURL, matching: namespace, storeID: storeID)
  }

  /// A stopped cache retains the original engine and record state. Only its exact
  /// collection may resume, so pending deletes and edits keep their accepted bases.
  package func resumeKeptCloudCache(
    in namespace: ICloudSyncNamespaceBinding,
    prepareForInitialFetch: @Sendable (SwiftDataSnipLibrary) async throws -> Void
  ) async throws -> Bool {
    guard manifest.attentionReason != .namespaceChanged,
      let index = manifest.stores.firstIndex(where: { $0.id == manifest.activeStoreID }),
      manifest.stores[index].relativeRoot == Self.canonicalRelativeRoot(
        kind: .iCloudSync, id: manifest.activeStoreID
      ), manifest.stores[index].quarantinedNamespace == namespace
    else { return false }
    try beginStoreReplacement()
    defer { finishStoreReplacement() }
    let kept = manifest.stores[index]
    let library = try libraryForTransition(storeID: kept.id)
    try await prepareForInitialFetch(library)
    var next = manifest
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
    let target = try libraryForTransition(storeID: legacy.storeID)
    if let binding = store(id: legacy.storeID)?.quarantinedNamespace {
      if manifest.attentionReason == .namespaceChanged {
        try PendingICloudSyncEnable.clear(at: rootURL)
        try await finishReset(target, namespace: binding, storeID: legacy.storeID)
      } else {
        await target.keepAvailableCloudAttachments(namespaceKey: binding.namespaceKey)
      }
    }
    if store(id: legacy.replacementStoreID)?.lifecycle == .isolated {
      let source = try libraryForTransition(storeID: legacy.replacementStoreID)
      let copy = try await source.transferSnapshot(revision: 0)
      _ = try await target.mergeTransferSnapshot(copy, transitionID: legacy.id)
    }
    var next = manifest
    next.accountIsolation = nil
    if let index = next.stores.firstIndex(where: { $0.id == legacy.replacementStoreID }) {
      next.stores[index].lifecycle = .deleting
    }
    try publishActivation(next)
  }
}
