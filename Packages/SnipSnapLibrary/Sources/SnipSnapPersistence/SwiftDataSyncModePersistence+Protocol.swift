import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  package func recordEnrollmentApproved(expected: Set<UUID>) throws {
    var next = manifest
    try next.updateTransition { try $0.approveEnrollment(expected: expected) }
    try crashHook(.afterEnrollmentApproval)
    try commit(next)
  }

  package func recordFirstSendStarted() async throws {
    try await withFailedEnableExposure(requiresAccepted: false) { _ in
      try self.crashHook(.afterFirstSendStarted)
      var next = self.manifest
      try next.updateTransition { try $0.startFirstSend() }
      try self.commit(next)
    }
  }

  package func recordSendAttempt(_ attempt: SyncModeSendAttempt) async throws {
    let transition = manifest.transition
    try await withFailedEnableExposure(requiresAccepted: false, attempt: attempt, arm: true) { _ in
      guard self.manifest.transition == transition else { throw SyncModePersistenceError.transitionInProgress }
      var next = self.manifest
      try next.updateTransition(orThrow: .namespaceMismatch) { try $0.recordSendAttempt(attempt) }
      try self.crashHook(.beforeSendAttemptManifest)
      try self.commit(next)
      if transition?.syncProtocol == .fullRecordV1 { self.failedEnableSendInFlight = transition?.id }
    }
  }

  package func finishFailedEnableSend() {
    failedEnableSendInFlight = nil
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
    try await recoverFailedEnableEvidence()
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

  package func prepareRetryFetch(settlement: SyncModeSeedSettlementProof) async throws {
    guard let transition = manifest.transition, transition.phase == .candidateReady else {
      return
    }
    let preparation = try await recoverFailedEnableEvidence()
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    if let preparation {
      // Past private output must be durably checked before retiring its actual receipt.
      try await withFailedEnablePreparedReceipt(preparation) { candidate, root in
        try await candidate.retireFailedEnablePrepared(preparation, evidenceRoot: root)
      }
    }
    guard transition.awaitsAcceptedServerCapture else { return }
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
