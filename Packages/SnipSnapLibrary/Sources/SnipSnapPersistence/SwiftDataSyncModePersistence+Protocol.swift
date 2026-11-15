import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  package func recordEnrollmentApproved(expected: Set<UUID>) throws {
    var next = manifest
    try next.updateTransition { try $0.approveEnrollment(expected: expected) }
    try crashHook(.afterEnrollmentApproval)
    try commit(next)
  }

  package func recordFirstSendStarted() throws {
    try crashHook(.afterFirstSendStarted)
    var next = manifest
    try next.updateTransition { try $0.startFirstSend() }
    try commit(next)
  }

  package func recordSendAttempt(_ attempt: SyncModeSendAttempt) throws {
    var next = manifest
    try next.updateTransition(orThrow: .namespaceMismatch) { try $0.recordSendAttempt(attempt) }
    try crashHook(.beforeSendAttemptManifest)
    try commit(next)
  }

  package func recordFirstSendComplete() throws {
    try crashHook(.afterFirstSendComplete)
    var next = manifest
    try next.updateTransition { try $0.completeFirstSend() }
    try commit(next)
  }

  package func recordNoSendRequired() throws {
    var next = manifest
    try next.updateTransition { try $0.skipFirstSend() }
    try commit(next)
  }

  package func restartAfterFirstSendFailure(
    reason: ICloudSyncAttentionReason?,
    settlement: SyncModeSeedSettlementProof?
  ) async throws {
    guard let transition = manifest.transition,
      transition.sourceStoreID == manifest.activeStoreID,
      [.enrollmentApproved, .firstSendStarted, .firstSendComplete].contains(transition.phase)
    else { return }
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    try await promoteAcceptedFullRetryBases(transition: transition, candidate: candidate)
    try crashHook(.afterRetryBasePromotion)
    let settledState = try await settledSeedState(
      transition: transition,
      candidate: candidate,
      settlement: settlement
    )
    var next = manifest
    try next.updateTransition {
      try $0.restartAfterFirstSendFailure(
        acceptedSeedIDs: settledState.acceptedSeedIDs,
        provenance: settledState.provenance
      )
    }
    next.attentionReason = reason
    try commit(next)
  }

  /// Keeps the sent records' accepted bases in the source, but never replaces a base it already
  /// holds: that one is an ancestor of both sides, while a sent record can be a merge result the
  /// source never held.
  func promoteAcceptedFullRetryBases(
    transition: SyncModeTransition,
    candidate: SwiftDataSnipLibrary
  ) async throws {
    guard transition.syncProtocol == .fullRecordV1,
      let attempt = transition.sendAttempt,
      let namespace = transition.namespace,
      attempt.namespace == namespace
    else { return }
    let namespaceKey = namespace.namespaceKey
    let stored = try await candidate.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let accepted = Dictionary(uniqueKeysWithValues:
      (stored.readyEntities + stored.deferredEntities).map { ($0.reference, $0) }
    )
    let source = try libraryForTransition(storeID: transition.sourceStoreID)
    let held = try await source.dormantCloudBases()
      .filter { $0.namespaceKey == namespaceKey.rawValue }
    let kept = Set(held.map(\.reference))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var bases: [CloudDormantBase] = []
    for operation in attempt.operations where operation.kind == .save {
      guard let reference = operation.reference,
        !kept.contains(reference),
        let entity = accepted[reference],
        entity.identity == operation.recordIdentity
      else { continue }
      let payload = try encoder.encode(CloudAcceptedEntityInput(
        reference: entity.reference,
        identity: entity.identity,
        schemaVersion: entity.schemaVersion,
        acceptedData: entity.acceptedData,
        presenceData: entity.presenceData,
        shadowData: entity.shadowData,
        systemFields: entity.systemFields,
        dependencyListID: entity.dependencyListID
      ))
      bases.append(CloudDormantBase(
        namespaceKey: namespaceKey.rawValue,
        reference: entity.reference,
        identity: entity.identity,
        payload: payload
      ))
    }
    guard !bases.isEmpty else { return }
    let crashHook = self.crashHook
    try await source.storeDormantCloudBases(
      namespaceKey: namespaceKey,
      bases: bases,
      afterStagingFirst: {
        try crashHook(.duringRetryBasePromotionStaging)
      }
    )
  }

  package func prepareRetryFetch(settlement: SyncModeSeedSettlementProof) async throws {
    guard let transition = manifest.transition, transition.phase == .candidateReady else {
      return
    }
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    if transition.syncProtocol == .fullRecordV1, let namespace = transition.namespace {
      // A new merge may have a different plan. Only pending merge intents need
      // the prior receipt for crash recovery; candidateReady has none.
      try await candidate.retireCompletedCloudFullReenable(
        namespaceKey: namespace.namespaceKey,
        transitionID: transition.id
      )
    }
    guard transition.awaitsAcceptedServerCapture else { return }
    try await promoteAcceptedFullRetryBases(transition: transition, candidate: candidate)
    let settledState = try await settledSeedState(
      transition: transition,
      candidate: candidate,
      settlement: settlement
    )
    var next = manifest
    try next.updateTransition {
      try $0.settleInterruptedUpload(
        acceptedSeedIDs: settledState.acceptedSeedIDs,
        provenance: settledState.provenance
      )
    }
    try crashHook(.beforeRetryFetchSettlementCommit)
    try commit(next)
  }

  package func requireActiveNamespace(_ namespace: ICloudSyncNamespaceBinding) throws {
    guard let active = store(id: manifest.activeStoreID), active.kind == .iCloudSync,
      active.namespace == namespace
    else { throw SyncModePersistenceError.namespaceMismatch }
  }

  private func settledSeedState(
    transition: SyncModeTransition,
    candidate: SwiftDataSnipLibrary,
    settlement: SyncModeSeedSettlementProof?
  ) async throws -> (
    acceptedSeedIDs: Set<UUID>,
    provenance: [SyncModeSeedProvenance]
  ) {
    let accepted = try await acceptedSnipIDs(
      transition: transition,
      candidate: candidate,
      settlement: settlement
    )
    return (
      accepted.intersection(transition.seedProvenance.map(\.candidateSnipID)),
      try await settledSeedProvenance(
        transition: transition,
        accepted: accepted,
        settlement: settlement
      )
    )
  }

  private func settledSeedProvenance(
    transition: SyncModeTransition,
    accepted: Set<UUID>,
    settlement: SyncModeSeedSettlementProof?
  ) async throws -> [SyncModeSeedProvenance] {
    guard settlement?.namespace == transition.namespace else { return transition.seedProvenance }
    let source = try await libraryForTransition(storeID: transition.sourceStoreID)
      .transferSnapshot(revision: 0)
    let candidate = try await libraryForTransition(storeID: transition.candidateStoreID)
      .transferSnapshot(revision: 0)
    let sourceIDs = Set(source.snips.map(\.id))
    let candidateByID = Dictionary(uniqueKeysWithValues: candidate.snips.map { ($0.id, $0) })
    let knownAccepted = transition.serverAcceptedSeedSnipIDs.union(accepted)
    return transition.seedProvenance.map { value in
      if transition.pendingSettlementSnipIDs.contains(value.candidateSnipID),
        case .saved(let identity, let acceptedText) = settlement?.values[value.candidateSnipID],
        accepted.contains(value.candidateSnipID),
        let snip = candidateByID[value.candidateSnipID],
        snip.content == acceptedText
      {
        return SyncModeSeedProvenance(
          sourceSnipID: value.sourceSnipID,
          candidateSnipID: value.candidateSnipID,
          candidateRequestID: value.candidateRequestID,
          baseDigest: SnipLibraryTransferPlanner.digest(
            snip: snip,
            attachmentData: candidate.attachmentData
          ),
          baseRemoteDigest: SnipLibraryTransferPlanner.remoteDigest(snip: snip),
          acceptedRecordIdentity: identity
        )
      }
      if !sourceIDs.contains(value.sourceSnipID),
        candidateByID[value.candidateSnipID] == nil,
        knownAccepted.contains(value.candidateSnipID),
        !accepted.contains(value.candidateSnipID),
        case .deleted(let identity) = settlement?.values[value.candidateSnipID],
        identity == value.acceptedRecordIdentity
      {
        return SyncModeSeedProvenance(
          sourceSnipID: value.sourceSnipID,
          candidateSnipID: value.candidateSnipID,
          candidateRequestID: value.candidateRequestID,
          baseDigest: SnipLibraryTransferPlanner.digest(snip: nil, attachmentData: [:]),
          baseRemoteDigest: SnipLibraryTransferPlanner.remoteDigest(snip: nil),
          acceptedRecordIdentity: identity
        )
      }
      return value
    }
  }

  private func acceptedSnipIDs(
    transition: SyncModeTransition,
    candidate: SwiftDataSnipLibrary,
    settlement: SyncModeSeedSettlementProof?
  ) async throws -> Set<UUID> {
    switch transition.syncProtocol {
    case .legacyTextV1:
      return try await candidate.acceptedCloudTextSnipIDs()
    case .fullRecordV1:
      guard settlement?.namespace == transition.namespace else { return [] }
      return Set(settlement?.values.compactMap { id, value in
        if case .saved = value { id } else { nil }
      } ?? [])
    }
  }
}
