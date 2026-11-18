import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  package func setupRetryFrozenSnapshot(candidateStoreID: UUID) async throws -> SnipLibrarySnapshot {
    guard let token = setupRetryFreezeToken(candidateStoreID: candidateStoreID) else {
      throw SyncModePersistenceError.invalidFreezeToken
    }
    try await readHook()
    guard setupRetryFreezeToken(candidateStoreID: candidateStoreID) == token else {
      throw SyncModePersistenceError.invalidFreezeToken
    }
    let snapshot = try await libraryForTransition(storeID: token.sourceStoreID)
      .checkedSnapshot(sortedBy: .manual)
    try Task.checkCancellation()
    guard setupRetryFreezeToken(candidateStoreID: candidateStoreID) == token else {
      throw SyncModePersistenceError.invalidFreezeToken
    }
    return snapshot
  }

  package func recordSetupRetryResults(
    _ results: [CloudSetupRetryResult],
    candidateStoreID: UUID,
    namespace: ICloudSyncNamespaceBinding
  ) throws {
    guard let transition = manifest.transition,
      transition.candidateStoreID == candidateStoreID,
      transition.namespace == namespace,
      let index = manifest.setupRetrySourceIndex
    else { return }
    var next = manifest
    var changed = false
    try next.stores[index].setupRetryHistory?.update(namespace: namespace) { evidence in
      changed = try evidence.recordResults(results, candidateStoreID: candidateStoreID) {
        try crashHook(.duringRetryBasePromotionStaging)
      }
    }
    if changed { try commit(next) }
  }

  package func setupRetryEvidence(namespace: ICloudSyncNamespaceBinding) -> CloudSetupRetryEvidence? {
    store(id: manifest.activeStoreID)?.setupRetryHistory?.namespaces
      .first { $0.namespace == namespace }
  }

  private func setupRetryFreezeToken(candidateStoreID: UUID) -> SyncModeFreezeToken? {
    guard manifest.setupRetrySourceIndex != nil,
      let transition = manifest.transition,
      transition.candidateStoreID == candidateStoreID,
      let token = transition.freezeToken,
      token.sourceStoreID == transition.sourceStoreID,
      store(id: token.sourceStoreID)?.revision == token.revision
    else { return nil }
    return token
  }
}

extension SwiftDataSyncModePersistence.Manifest {
  fileprivate var setupRetrySourceIndex: Int? {
    guard let transition,
      transition.targetKind == .iCloudSync,
      transition.syncProtocol == .fullRecordV1,
      transition.sourceStoreID == activeStoreID
    else { return nil }
    return stores.firstIndex { $0.id == activeStoreID && $0.kind == .localOnly }
  }

  mutating func migrateSetupRetryHistory() {
    guard let transition, let namespace = transition.namespace, let index = setupRetrySourceIndex,
      stores[index].setupRetryHistory?.trackedCandidateStoreID != transition.candidateStoreID
    else { return }
    var history = stores[index].setupRetryHistory ?? CloudSetupRetryHistory()
    if let attempt = transition.sendAttempt, attempt.namespace == namespace {
      history.update(namespace: namespace) { $0.recordLegacySend(attempt.operations) }
    } else if transition.mayHaveUnidentifiedSetupSend {
      history.update(namespace: namespace) { $0.recordUnidentifiedLegacySend() }
    }
    history.trackedCandidateStoreID = transition.candidateStoreID
    stores[index].setupRetryHistory = history
  }

  mutating func stopTrackingSetupRetryCandidate() {
    migrateSetupRetryHistory()
    guard let index = setupRetrySourceIndex, var history = stores[index].setupRetryHistory else {
      return
    }
    history.trackedCandidateStoreID = nil
    stores[index].setupRetryHistory = history.namespaces.isEmpty ? nil : history
  }

  mutating func recordSetupRetryOffers(
    _ offers: [CloudSetupRetryOffer]?,
    for attempt: SyncModeSendAttempt
  ) throws {
    guard let index = setupRetrySourceIndex, let transition else {
      guard offers?.isEmpty != false else { throw SyncModePersistenceError.namespaceMismatch }
      return
    }
    if let offers {
      let saves = Set(attempt.operations.compactMap { operation -> CloudSetupRetryRecordKey? in
        guard operation.kind == .save, let reference = operation.reference else { return nil }
        return CloudSetupRetryRecordKey(reference: reference, identity: operation.recordIdentity)
      })
      let offeredKeys = Set(offers.map(\.key))
      guard offeredKeys.count == offers.count, offeredKeys.isSubset(of: saves) else {
        throw SyncModePersistenceError.invalidManifest
      }
      stores[index].setupRetryHistory?.update(namespace: attempt.namespace) {
        $0.recordOffers(offers, candidateStoreID: transition.candidateStoreID)
      }
    } else {
      stores[index].setupRetryHistory?.update(namespace: attempt.namespace) {
        $0.recordLegacySend(attempt.operations)
      }
    }
  }
}
