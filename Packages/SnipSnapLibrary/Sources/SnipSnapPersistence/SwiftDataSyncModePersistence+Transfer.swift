import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  package func sourceSnapshot(
    for transition: SyncModeTransition,
    validate: @Sendable (SnipLibrarySnapshot) throws -> Void = { _ in }
  ) async throws -> SnipLibraryTransferSnapshot {
    try await readHook()
    return try await activeStoreTurns.withLease {
      try await self.readSourceSnapshot(for: transition, validate: validate)
    }
  }

  private func readSourceSnapshot(
    for transition: SyncModeTransition,
    validate: (SnipLibrarySnapshot) throws -> Void
  ) async throws -> SnipLibraryTransferSnapshot {
    guard manifest.transition == transition, manifest.activeStoreID == transition.sourceStoreID,
      !activeStoreBusy
    else { throw SyncModePersistenceError.transitionInProgress }
    let library = try libraryForTransition(storeID: transition.sourceStoreID)
    let current = try await library.checkedSnapshot(sortedBy: .manual)
    try validate(current)
    return try await library.transferSnapshot(revision: activeStoreRevision)
  }

  package func mergeCandidate(
    _ source: SnipLibraryTransferSnapshot,
    for transition: SyncModeTransition,
    acceptedTargetSnipIDs: Set<UUID> = []
  ) async throws -> SnipLibraryTransferResult {
    guard manifest.transition == transition, transition.phase == .declared else {
      throw SyncModePersistenceError.transitionInProgress
    }
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    let target = try await candidate.transferSnapshot(revision: 0)
    let plan = try SnipLibraryTransferPlanner.plan(
      source: source,
      target: target,
      transitionID: transition.id,
      acceptedTargetSnipIDs: acceptedTargetSnipIDs,
      keepingUnavailableDownloads: true
    )
    try crashHook(.beforeCandidateMergeDurability)
    let result = try await candidate.applyTransferPlan(plan)
    if manifest.attentionReason == .namespaceChanged,
      let prior = store(id: transition.sourceStoreID)?.quarantinedNamespace,
      let namespace = transition.namespace
    {
      let library = try libraryForTransition(storeID: transition.sourceStoreID)
      try await library.copyRecoveryReviews(from: prior.namespaceKey, to: candidate,
        namespaceKey: namespace.namespaceKey)
    }
    return result
  }

  package func markCandidateMerged(transitionID: UUID) throws {
    guard manifest.transition?.id == transitionID else {
      throw SyncModePersistenceError.transitionInProgress
    }
    try crashHook(.afterCandidateMergeDurability)
    var next = manifest
    try next.updateTransition { try $0.completeMerge() }
    try commit(next)
  }

  package func requireActiveNamespace(_ namespace: ICloudSyncNamespaceBinding) throws {
    guard let active = store(id: manifest.activeStoreID), active.kind == .iCloudSync,
      active.namespace == namespace
    else { throw SyncModePersistenceError.namespaceMismatch }
  }
}
