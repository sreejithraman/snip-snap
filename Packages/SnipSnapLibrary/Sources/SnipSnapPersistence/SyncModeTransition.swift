import Foundation
import SnipSnapCore

/// A sync-mode change (ADR 0012, 0014): the candidate store's progress from declaration to the
/// pointer swap. Only the events below change it; reads are derived. The stored manifest keeps the
/// flat pre-machine shape, mapped at `init(from:)` and `encode(to:)`, so every build reads and
/// writes the same `transition` object.
package struct SyncModeTransition: Codable, Equatable, Sendable {
  package let id: UUID
  package let sourceStoreID: UUID
  package let candidateStoreID: UUID
  package let targetKind: SyncModeStoreKind
  package let namespace: ICloudSyncNamespaceBinding?
  package let syncProtocol: SyncModeSyncProtocol

  private var stage: Stage
  private var seeds: SeedHistory
  private var upload: SeedUpload

  private enum Stage: Equatable, Sendable {
    case candidateDeclared
    case candidateReady
    case remoteFetched
    case sourceFrozen(SyncModeFreezeToken, FinalSnapshot)
    case recordsMerged(Merged)
    case enrollmentApproved(Merged)
    case firstSendStarted(Merged)
    case firstSendComplete(Merged)
    /// The pointer swap drops the freeze; the approved IDs stay as stored.
    case pointerSwapped(approvedSnipIDs: Set<UUID>)
  }

  private enum FinalSnapshot: Equatable, Sendable {
    case notTaken
    case taken
    case merging(SyncModeMergeIntent)
  }

  private struct Merged: Equatable, Sendable {
    let token: SyncModeFreezeToken
    let approvedSnipIDs: Set<UUID>
  }

  /// What earlier attempts at this transition merged and the server accepted. Every restart keeps
  /// it, so a retry merge neither drops nor re-sends a seed.
  private struct SeedHistory: Equatable, Sendable {
    var provenance: [SyncModeSeedProvenance] = []
    var seededListIDs: Set<UUID> = []
    var supersededApprovedSnipIDs: Set<UUID> = []
    var serverAcceptedSnipIDs: Set<UUID> = []
  }

  /// The first send's operations until a settlement proves what the server kept. It is separate
  /// from `Stage` because its lifetime crosses stages: reopen carries an interrupted upload back
  /// to `candidateReady`, where the next retry fetch settles it.
  private enum SeedUpload: Equatable, Sendable {
    case none
    case recorded(SyncModeSendAttempt)
    /// Reopen interrupted the transition after its source froze. The next retry fetch records
    /// what the server accepted. Opt-out never fetches, so it keeps this until the transition ends.
    case awaitingCapture(SyncModeSendAttempt?)
  }

  init(
    id: UUID,
    sourceStoreID: UUID,
    candidateStoreID: UUID,
    targetKind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?,
    syncProtocol: SyncModeSyncProtocol
  ) {
    self.id = id
    self.sourceStoreID = sourceStoreID
    self.candidateStoreID = candidateStoreID
    self.targetKind = targetKind
    self.namespace = namespace
    self.syncProtocol = syncProtocol
    stage = .candidateDeclared
    seeds = SeedHistory()
    upload = .none
  }
}

// MARK: - Derived reads

extension SyncModeTransition {
  package var phase: SyncModeTransitionPhase {
    switch stage {
    case .candidateDeclared: .candidateDeclared
    case .candidateReady: .candidateReady
    case .remoteFetched: .remoteFetched
    case .sourceFrozen: .sourceFrozen
    case .recordsMerged: .recordsMerged
    case .enrollmentApproved: .enrollmentApproved
    case .firstSendStarted: .firstSendStarted
    case .firstSendComplete: .firstSendComplete
    case .pointerSwapped: .pointerSwapped
    }
  }

  package var freezeToken: SyncModeFreezeToken? {
    if case .sourceFrozen(let token, _) = stage { return token }
    return merged?.token
  }

  /// Whether this stage keeps the source frozen, so the source refuses library writes.
  package var freezesSource: Bool {
    switch stage {
    case .sourceFrozen, .recordsMerged, .enrollmentApproved, .firstSendStarted,
      .firstSendComplete:
      true
    case .candidateDeclared, .candidateReady, .remoteFetched, .pointerSwapped:
      false
    }
  }

  package var mergeIntent: SyncModeMergeIntent? {
    if case .sourceFrozen(_, .merging(let intent)) = stage { return intent }
    return nil
  }

  package var approvedSnipIDs: Set<UUID> {
    if case .pointerSwapped(let approvedSnipIDs) = stage { return approvedSnipIDs }
    return merged?.approvedSnipIDs ?? []
  }

  package var sendAttempt: SyncModeSendAttempt? {
    switch upload {
    case .none: nil
    case .recorded(let attempt): attempt
    case .awaitingCapture(let attempt): attempt
    }
  }

  package var pendingSettlementSnipIDs: Set<UUID> {
    sendAttempt?.snipIDs ?? []
  }

  package var seedProvenance: [SyncModeSeedProvenance] { seeds.provenance }

  package var seededListIDs: Set<UUID> { seeds.seededListIDs }

  package var serverAcceptedSeedSnipIDs: Set<UUID> { seeds.serverAcceptedSnipIDs }

  package var hasDurableFullReenableIntent: Bool {
    mergeIntent?.fullReenablePlanID != nil
  }

  package var seedSettlementCandidates: [SyncModeSeedSettlementCandidate] {
    let provenanceIDs = Set(seeds.provenance.map(\.candidateSnipID))
    return sendAttempt?.operations.compactMap { operation in
      guard let reference = operation.reference,
        reference.kind == .snip,
        provenanceIDs.contains(reference.domainID)
      else { return nil }
      return SyncModeSeedSettlementCandidate(
        snipID: reference.domainID,
        acceptedRecordIdentity: operation.recordIdentity
      )
    } ?? []
  }

  var awaitsAcceptedServerCapture: Bool {
    if case .awaitingCapture = upload { return true }
    return false
  }

  var mayHaveLegacySetupSend: Bool {
    // Older retries returned to candidateReady after clearing the send attempt. A list-only
    // send could leave no snip settlement IDs, and the retry could advance from there.
    phase != .candidateDeclared
  }

  func awaitsMerge(using token: SyncModeFreezeToken) -> Bool {
    stage == .sourceFrozen(token, .taken)
  }

  private var merged: Merged? {
    switch stage {
    case .recordsMerged(let merged), .enrollmentApproved(let merged),
      .firstSendStarted(let merged), .firstSendComplete(let merged):
      merged
    case .candidateDeclared, .candidateReady, .remoteFetched, .sourceFrozen, .pointerSwapped:
      nil
    }
  }

  private var finalSnapshotTaken: Bool {
    switch stage {
    case .candidateDeclared, .candidateReady, .remoteFetched, .sourceFrozen(_, .notTaken):
      false
    case .sourceFrozen(_, .taken), .sourceFrozen(_, .merging), .recordsMerged,
      .enrollmentApproved, .firstSendStarted, .firstSendComplete, .pointerSwapped:
      true
    }
  }
}

// MARK: - Events

extension SyncModeTransition {
  mutating func markCandidateReady() throws {
    guard case .candidateDeclared = stage else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .candidateReady
  }

  mutating func recordPreparationComplete() throws {
    guard case .candidateReady = stage else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .remoteFetched
  }

  mutating func retryRemoteFetch() throws {
    guard case .remoteFetched = stage else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .candidateReady
  }

  mutating func freezeSource(_ token: SyncModeFreezeToken) throws {
    guard case .remoteFetched = stage else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .sourceFrozen(token, .notTaken)
  }

  mutating func takeFinalSnapshot(_ token: SyncModeFreezeToken) throws {
    guard case .sourceFrozen(token, .notTaken) = stage else {
      throw SyncModePersistenceError.invalidFreezeToken
    }
    stage = .sourceFrozen(token, .taken)
  }

  mutating func recordMergeIntent(
    _ intent: SyncModeMergeIntent,
    using token: SyncModeFreezeToken
  ) throws {
    guard awaitsMerge(using: token) else { throw SyncModePersistenceError.invalidFreezeToken }
    stage = .sourceFrozen(token, .merging(intent))
  }

  mutating func replaceMergeIntent(
    _ old: SyncModeMergeIntent,
    with new: SyncModeMergeIntent
  ) throws {
    guard case .sourceFrozen(let token, .merging(old)) = stage else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .sourceFrozen(token, .merging(new))
  }

  mutating func finishMerge(_ intent: SyncModeMergeIntent) throws {
    guard case .sourceFrozen(let token, .merging(intent)) = stage else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .recordsMerged(Merged(token: token, approvedSnipIDs: intent.approvedSnipIDs))
    seeds.provenance = intent.seedProvenance
    seeds.seededListIDs = intent.seededListIDs
    dropAttempt()
  }

  mutating func abandonMerge(_ intent: SyncModeMergeIntent) throws {
    guard case .sourceFrozen(_, .merging(intent)) = stage else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .candidateReady
    dropAttempt()
  }

  mutating func approveEnrollment(expected: Set<UUID>) throws {
    guard case .recordsMerged(let merged) = stage, merged.approvedSnipIDs == expected else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .enrollmentApproved(merged)
  }

  mutating func startFirstSend() throws {
    guard case .enrollmentApproved(let merged) = stage else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .firstSendStarted(merged)
    dropAttempt()
  }

  mutating func recordSendAttempt(_ attempt: SyncModeSendAttempt) throws {
    guard case .firstSendStarted = stage, namespace == attempt.namespace else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    let allowedZones = attempt.namespace.zones
    guard attempt.operations.allSatisfy({ operation in
      allowedZones.contains(
        ICloudSyncZoneBinding(
          name: operation.recordIdentity.zoneName,
          ownerName: operation.recordIdentity.ownerName
        )
      )
    }) else { throw SyncModePersistenceError.namespaceMismatch }

    var operations = sendAttempt?.operations ?? []
    for operation in attempt.operations {
      if let existing = operations.first(where: {
        $0.recordIdentity == operation.recordIdentity
      }) {
        guard existing == operation else { throw SyncModePersistenceError.invalidManifest }
      } else {
        operations.append(operation)
      }
    }
    operations.sort {
      if $0.reference?.kind != $1.reference?.kind {
        return ($0.reference?.kind.rawValue ?? "") < ($1.reference?.kind.rawValue ?? "")
      }
      if $0.reference?.domainID != $1.reference?.domainID {
        return ($0.reference?.domainID.uuidString ?? "")
          < ($1.reference?.domainID.uuidString ?? "")
      }
      return $0.recordIdentity.key < $1.recordIdentity.key
    }
    let saved = SyncModeSendAttempt(namespace: attempt.namespace, operations: operations)
    if case .awaitingCapture = upload {
      upload = .awaitingCapture(saved)
    } else {
      upload = .recorded(saved)
    }
  }

  mutating func completeFirstSend() throws {
    guard case .firstSendStarted(let merged) = stage else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .firstSendComplete(merged)
  }

  mutating func skipFirstSend() throws {
    guard targetKind == .localOnly, case .enrollmentApproved(let merged) = stage else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .firstSendComplete(merged)
  }

  mutating func swapPointer() throws {
    guard case .firstSendComplete(let merged) = stage else {
      throw SyncModePersistenceError.transitionInProgress
    }
    stage = .pointerSwapped(approvedSnipIDs: merged.approvedSnipIDs)
  }

  mutating func unfreeze() throws {
    guard freezesSource else { throw SyncModePersistenceError.transitionInProgress }
    if case .sourceFrozen(_, .merging(let intent)) = stage {
      absorb(intent)
      stage = .candidateReady
    } else {
      stage = .remoteFetched
    }
  }

  mutating func restartAfterFirstSendFailure(
    acceptedSeedIDs: Set<UUID>,
    provenance: [SyncModeSeedProvenance]
  ) throws {
    switch stage {
    case .enrollmentApproved(let merged), .firstSendStarted(let merged),
      .firstSendComplete(let merged):
      seeds.supersededApprovedSnipIDs.formUnion(merged.approvedSnipIDs)
      seeds.serverAcceptedSnipIDs.formUnion(acceptedSeedIDs)
      seeds.provenance = provenance
      upload = .none
      stage = .candidateReady
    case .candidateDeclared, .candidateReady, .remoteFetched, .sourceFrozen, .recordsMerged,
      .pointerSwapped:
      throw SyncModePersistenceError.transitionInProgress
    }
  }

  mutating func settleInterruptedUpload(
    acceptedSeedIDs: Set<UUID>,
    provenance: [SyncModeSeedProvenance]
  ) throws {
    guard case .candidateReady = stage, awaitsAcceptedServerCapture else {
      throw SyncModePersistenceError.transitionInProgress
    }
    seeds.serverAcceptedSnipIDs.formUnion(acceptedSeedIDs)
    seeds.provenance = provenance
    upload = .none
  }

  /// Reopen moves a frozen source back to `candidateReady`, except a full re-enable merge, which
  /// `reconcileFullReenableIntent` finishes or resets.
  mutating func interruptByReopen() {
    switch stage {
    case .sourceFrozen(_, .merging(let intent)) where intent.fullReenablePlanID != nil:
      return
    case .sourceFrozen(_, .merging(let intent)):
      absorb(intent)
    case .sourceFrozen, .recordsMerged, .enrollmentApproved, .firstSendStarted,
      .firstSendComplete:
      break
    case .candidateDeclared, .candidateReady, .remoteFetched, .pointerSwapped:
      return
    }
    seeds.supersededApprovedSnipIDs.formUnion(approvedSnipIDs)
    upload = .awaitingCapture(sendAttempt)
    stage = .candidateReady
  }

  private mutating func absorb(_ intent: SyncModeMergeIntent) {
    seeds.provenance = intent.seedProvenance
    seeds.seededListIDs = intent.seededListIDs
    seeds.supersededApprovedSnipIDs.formUnion(intent.approvedSnipIDs)
    dropAttempt()
  }

  private mutating func dropAttempt() {
    switch upload {
    case .none, .recorded: upload = .none
    case .awaitingCapture: upload = .awaitingCapture(nil)
    }
  }
}

// MARK: - Stored form

extension SyncModeTransition {
  private enum CodingKeys: String, CodingKey {
    case id, sourceStoreID, candidateStoreID, targetKind, namespace, syncProtocol, phase
    case freezeToken, freezeSnapshotTaken, approvedSnipIDs, pendingSettlementSnipIDs
    case sendAttempt, supersededApprovedSnipIDs, seedProvenance, serverAcceptedSeedSnipIDs
    case captureAcceptedServerProvenance, seededListIDs, mergeIntent
  }

  /// Rejects stored combinations no build writes and drops fields a stage doesn't hold.
  ///
  /// Every commit since #92 has validated that a merge intent exists only in `sourceFrozen` after
  /// the final snapshot, and that the pending settlement IDs are the attempt's snip IDs. Only
  /// `freezeSource` enters `sourceFrozen`, and it sets the token; later frozen phases are entered
  /// only from there, and every write that clears the token also leaves the frozen phases.
  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    sourceStoreID = try values.decode(UUID.self, forKey: .sourceStoreID)
    candidateStoreID = try values.decode(UUID.self, forKey: .candidateStoreID)
    targetKind = try values.decode(SyncModeStoreKind.self, forKey: .targetKind)
    namespace = try values.decodeIfPresent(ICloudSyncNamespaceBinding.self, forKey: .namespace)
    syncProtocol = try values.decodeIfPresent(
      SyncModeSyncProtocol.self,
      forKey: .syncProtocol
    ) ?? .legacyTextV1
    let phase = try values.decode(SyncModeTransitionPhase.self, forKey: .phase)
    let freezeToken = try values.decodeIfPresent(SyncModeFreezeToken.self, forKey: .freezeToken)
    let finalSnapshotTaken = try values.decode(Bool.self, forKey: .freezeSnapshotTaken)
    let approvedSnipIDs = try values.decode(Set<UUID>.self, forKey: .approvedSnipIDs)
    let pendingSettlementSnipIDs = try values.decode(
      Set<UUID>.self,
      forKey: .pendingSettlementSnipIDs
    )
    let sendAttempt = try values.decodeIfPresent(SyncModeSendAttempt.self, forKey: .sendAttempt)
    let supersededApprovedSnipIDs = try values.decode(
      Set<UUID>.self,
      forKey: .supersededApprovedSnipIDs
    )
    let seedProvenance = try values.decode(
      [SyncModeSeedProvenance].self,
      forKey: .seedProvenance
    )
    let serverAcceptedSeedSnipIDs = try values.decode(
      Set<UUID>.self,
      forKey: .serverAcceptedSeedSnipIDs
    )
    let awaitsCapture = try values.decode(Bool.self, forKey: .captureAcceptedServerProvenance)
    let seededListIDs = try values.decode(Set<UUID>.self, forKey: .seededListIDs)
    let mergeIntent = try values.decodeIfPresent(SyncModeMergeIntent.self, forKey: .mergeIntent)

    if mergeIntent != nil, phase != .sourceFrozen || !finalSnapshotTaken {
      throw DecodingError.dataCorruptedError(
        forKey: .mergeIntent,
        in: values,
        debugDescription: "A merge intent needs a taken final snapshot."
      )
    }
    guard pendingSettlementSnipIDs == (sendAttempt?.snipIDs ?? []) else {
      throw DecodingError.dataCorruptedError(
        forKey: .pendingSettlementSnipIDs,
        in: values,
        debugDescription: "Pending settlement IDs must be the send attempt's snip IDs."
      )
    }
    func storedToken() throws -> SyncModeFreezeToken {
      guard let freezeToken else {
        throw DecodingError.dataCorruptedError(
          forKey: .freezeToken,
          in: values,
          debugDescription: "A frozen phase needs a freeze token."
        )
      }
      return freezeToken
    }
    func storedMerge() throws -> Merged {
      try Merged(token: storedToken(), approvedSnipIDs: approvedSnipIDs)
    }
    switch phase {
    case .candidateDeclared: stage = .candidateDeclared
    case .candidateReady: stage = .candidateReady
    case .remoteFetched: stage = .remoteFetched
    case .sourceFrozen:
      let snapshot: FinalSnapshot = if let mergeIntent {
        .merging(mergeIntent)
      } else if finalSnapshotTaken {
        .taken
      } else {
        .notTaken
      }
      stage = try .sourceFrozen(storedToken(), snapshot)
    case .recordsMerged: stage = try .recordsMerged(storedMerge())
    case .enrollmentApproved: stage = try .enrollmentApproved(storedMerge())
    case .firstSendStarted: stage = try .firstSendStarted(storedMerge())
    case .firstSendComplete: stage = try .firstSendComplete(storedMerge())
    case .pointerSwapped: stage = .pointerSwapped(approvedSnipIDs: approvedSnipIDs)
    }
    seeds = SeedHistory(
      provenance: seedProvenance,
      seededListIDs: seededListIDs,
      supersededApprovedSnipIDs: supersededApprovedSnipIDs,
      serverAcceptedSnipIDs: serverAcceptedSeedSnipIDs
    )
    if awaitsCapture {
      upload = .awaitingCapture(sendAttempt)
    } else if let sendAttempt {
      upload = .recorded(sendAttempt)
    } else {
      upload = .none
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(sourceStoreID, forKey: .sourceStoreID)
    try values.encode(candidateStoreID, forKey: .candidateStoreID)
    try values.encode(targetKind, forKey: .targetKind)
    try values.encodeIfPresent(namespace, forKey: .namespace)
    try values.encode(syncProtocol, forKey: .syncProtocol)
    try values.encode(phase, forKey: .phase)
    try values.encodeIfPresent(freezeToken, forKey: .freezeToken)
    try values.encode(finalSnapshotTaken, forKey: .freezeSnapshotTaken)
    try values.encode(approvedSnipIDs, forKey: .approvedSnipIDs)
    try values.encode(pendingSettlementSnipIDs, forKey: .pendingSettlementSnipIDs)
    try values.encodeIfPresent(sendAttempt, forKey: .sendAttempt)
    try values.encode(seeds.supersededApprovedSnipIDs, forKey: .supersededApprovedSnipIDs)
    try values.encode(seeds.provenance, forKey: .seedProvenance)
    try values.encode(seeds.serverAcceptedSnipIDs, forKey: .serverAcceptedSeedSnipIDs)
    try values.encode(awaitsAcceptedServerCapture, forKey: .captureAcceptedServerProvenance)
    try values.encode(seeds.seededListIDs, forKey: .seededListIDs)
    try values.encodeIfPresent(mergeIntent, forKey: .mergeIntent)
  }
}

private extension SyncModeSendAttempt {
  var snipIDs: Set<UUID> {
    Set(operations.compactMap { $0.reference?.kind == .snip ? $0.reference?.domainID : nil })
  }
}
