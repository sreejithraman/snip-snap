import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  package func recordEnrollmentApproved(expected: Set<UUID>) throws {
    guard manifest.transition?.phase == .recordsMerged,
      manifest.transition?.approvedSnipIDs == expected
    else { throw SyncModePersistenceError.transitionInProgress }
    try crashHook(.afterEnrollmentApproval)
    try changeTransition(from: .recordsMerged, to: .enrollmentApproved)
  }

  package func recordFirstSendStarted() throws {
    try crashHook(.afterFirstSendStarted)
    guard manifest.transition?.phase == .enrollmentApproved else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.transition?.phase = .firstSendStarted
    next.transition?.pendingSettlementSnipIDs = []
    next.transition?.sendAttempt = nil
    try commit(next)
  }

  package func recordSendAttempt(_ attempt: SyncModeSendAttempt) throws {
    guard let transition = manifest.transition,
      transition.phase == .firstSendStarted,
      transition.namespace == attempt.namespace
    else { throw SyncModePersistenceError.namespaceMismatch }
    let allowedZones = attempt.namespace.zones
    guard attempt.operations.allSatisfy({ operation in
      allowedZones.contains(
        ICloudSyncZoneBinding(
          name: operation.recordIdentity.zoneName,
          ownerName: operation.recordIdentity.ownerName
        )
      )
    }) else { throw SyncModePersistenceError.namespaceMismatch }

    var operations = transition.sendAttempt?.operations ?? []
    for operation in attempt.operations {
      if let existing = operations.first(where: { $0.reference == operation.reference }) {
        guard existing == operation else { throw SyncModePersistenceError.invalidManifest }
      } else {
        operations.append(operation)
      }
    }
    operations.sort {
      if $0.reference.kind != $1.reference.kind {
        return $0.reference.kind.rawValue < $1.reference.kind.rawValue
      }
      if $0.reference.domainID != $1.reference.domainID {
        return $0.reference.domainID.uuidString < $1.reference.domainID.uuidString
      }
      return $0.recordIdentity.key < $1.recordIdentity.key
    }
    var next = manifest
    let saved = SyncModeSendAttempt(namespace: attempt.namespace, operations: operations)
    next.transition?.sendAttempt = saved
    next.transition?.pendingSettlementSnipIDs = Set(operations.compactMap {
      $0.reference.kind == .snip ? $0.reference.domainID : nil
    })
    try crashHook(.beforeSendAttemptManifest)
    try commit(next)
  }

  package func recordFirstSendComplete() throws {
    try crashHook(.afterFirstSendComplete)
    try changeTransition(from: .firstSendStarted, to: .firstSendComplete)
  }

  package func recordNoSendRequired() throws {
    guard manifest.transition?.targetKind == .localOnly else {
      throw SyncModePersistenceError.transitionInProgress
    }
    try changeTransition(from: .enrollmentApproved, to: .firstSendComplete)
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
    let accepted = try await acceptedSnipIDs(
      transition: transition,
      candidate: candidate,
      settlement: settlement
    )
    let seedIDs = Set(transition.seedProvenance.map(\.candidateSnipID))
    let settled = try await settledSeedProvenance(
      transition: transition,
      accepted: accepted,
      settlement: settlement
    )
    var next = manifest
    next.transition?.supersededApprovedSnipIDs.formUnion(transition.approvedSnipIDs)
    next.transition?.serverAcceptedSeedSnipIDs.formUnion(accepted.intersection(seedIDs))
    next.transition?.seedProvenance = settled
    next.transition?.pendingSettlementSnipIDs = []
    next.transition?.sendAttempt = nil
    next.transition?.captureAcceptedServerProvenance = false
    next.transition?.phase = .candidateReady
    next.transition?.freezeToken = nil
    next.transition?.freezeSnapshotTaken = false
    next.transition?.approvedSnipIDs = []
    next.attentionReason = reason
    try commit(next)
  }

  private func promoteAcceptedFullRetryBases(
    transition: SyncModeTransition,
    candidate: SwiftDataSnipLibrary
  ) async throws {
    guard transition.syncProtocol == .fullRecordV1,
      let attempt = transition.sendAttempt,
      let namespace = transition.namespace,
      attempt.namespace == namespace
    else { return }
    let namespaceKey = Self.namespaceKey(namespace)
    let stored = try await candidate.cloudFullStorageSnapshot(namespaceKey: namespaceKey)
    let accepted = Dictionary(uniqueKeysWithValues:
      (stored.readyEntities + stored.deferredEntities).map { ($0.reference, $0) }
    )
    let source = try libraryForTransition(storeID: transition.sourceStoreID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var bases: [CloudDormantBase] = []
    for operation in attempt.operations where operation.kind == .save {
      guard let entity = accepted[operation.reference],
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
        namespaceKey: namespaceKey,
        reference: entity.reference,
        identity: entity.identity,
        payload: payload
      ))
    }
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
    guard let transition = manifest.transition, transition.phase == .candidateReady,
      transition.captureAcceptedServerProvenance
    else { return }
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    try await promoteAcceptedFullRetryBases(transition: transition, candidate: candidate)
    let accepted = try await acceptedSnipIDs(
      transition: transition,
      candidate: candidate,
      settlement: settlement
    )
    let seedIDs = Set(transition.seedProvenance.map(\.candidateSnipID))
    let settled = try await settledSeedProvenance(
      transition: transition,
      accepted: accepted,
      settlement: settlement
    )
    var next = manifest
    next.transition?.serverAcceptedSeedSnipIDs.formUnion(accepted.intersection(seedIDs))
    next.transition?.seedProvenance = settled
    next.transition?.pendingSettlementSnipIDs = []
    next.transition?.sendAttempt = nil
    next.transition?.captureAcceptedServerProvenance = false
    try commit(next)
  }

  package func requireActiveNamespace(_ namespace: ICloudSyncNamespaceBinding) throws {
    guard let active = store(id: manifest.activeStoreID), active.kind == .iCloudSync,
      active.namespace == namespace
    else { throw SyncModePersistenceError.namespaceMismatch }
  }

  private func changeTransition(from: SyncModeTransitionPhase, to: SyncModeTransitionPhase) throws {
    guard manifest.transition?.phase == from else { throw SyncModePersistenceError.transitionInProgress }
    var next = manifest
    next.transition?.phase = to
    try commit(next)
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
