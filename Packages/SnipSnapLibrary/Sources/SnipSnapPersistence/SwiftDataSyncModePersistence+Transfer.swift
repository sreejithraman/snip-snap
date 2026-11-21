import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  package func sourceSnapshot(for transition: SyncModeTransition) async throws -> SnipLibraryTransferSnapshot {
    try await readHook()
    return try await activeStoreTurns.withLease {
      try await self.readSourceSnapshot(for: transition)
    }
  }

  private func readSourceSnapshot(for transition: SyncModeTransition) async throws -> SnipLibraryTransferSnapshot {
    guard manifest.transition == transition, manifest.activeStoreID == transition.sourceStoreID,
      !activeStoreBusy
    else { throw SyncModePersistenceError.transitionInProgress }
    return try await libraryForTransition(storeID: transition.sourceStoreID)
      .transferSnapshot(revision: activeStoreRevision)
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
      acceptedTargetSnipIDs: acceptedTargetSnipIDs
    )
    try crashHook(.beforeCandidateMergeDurability)
    return try await candidate.applyTransferPlan(plan)
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
