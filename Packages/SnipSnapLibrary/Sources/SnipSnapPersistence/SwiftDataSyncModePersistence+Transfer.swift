import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  package func freezeSource() throws -> SyncModeFreezeToken {
    guard writeAdmissionIsIdle() else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    guard let transition = next.transition, transition.sourceStoreID == next.activeStoreID,
      let source = next.stores.first(where: { $0.id == transition.sourceStoreID })
    else { throw SyncModePersistenceError.transitionInProgress }
    let token = SyncModeFreezeToken(id: UUID(), sourceStoreID: source.id, revision: source.revision)
    try next.updateTransition { try $0.freezeSource(token) }
    try commit(next)
    return token
  }

  package func finalSnapshot(
    using token: SyncModeFreezeToken
  ) async throws -> SnipLibraryTransferSnapshot {
    var next = manifest
    try next.updateTransition(orThrow: .invalidFreezeToken) { try $0.takeFinalSnapshot(token) }
    guard store(id: token.sourceStoreID)?.revision == token.revision else {
      throw SyncModePersistenceError.invalidFreezeToken
    }
    try commit(next)
    try await readHook()
    return try await libraryForTransition(storeID: token.sourceStoreID)
      .transferSnapshot(revision: token.revision)
  }

  package func mergeFinalSnapshot(
    _ source: SnipLibraryTransferSnapshot,
    using token: SyncModeFreezeToken,
    acceptedTargetTextBySnipID suppliedAcceptedText: [UUID: String]? = nil
  ) async throws -> SnipLibraryTransferResult {
    guard let transition = manifest.transition, transition.awaitsMerge(using: token),
      source.revision == token.revision,
      let candidateStore = store(id: transition.candidateStoreID)
    else { throw SyncModePersistenceError.invalidFreezeToken }
    if transition.targetKind == .iCloudSync, transition.syncProtocol == .fullRecordV1 {
      return try await prepareFailedEnableMerge(using: token)
    }
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    let candidateBefore = try await candidate.transferSnapshot(revision: candidateStore.revision)
    let acceptedTextBySnipID: [UUID: String]
    if let suppliedAcceptedText {
      acceptedTextBySnipID = suppliedAcceptedText
    } else {
      acceptedTextBySnipID = try await candidate.acceptedCloudTextValues()
    }
    let accepted = Set(acceptedTextBySnipID.keys)
    let plan = try SnipLibraryTransferPlanner.plan(
      source: source,
      target: candidateBefore,
      transitionID: transition.id,
      acceptedTargetSnipIDs: accepted,
      acceptedTargetTextBySnipID: acceptedTextBySnipID,
      priorSeedProvenance: transition.seedProvenance,
      priorServerAcceptedSnipIDs: transition.serverAcceptedSeedSnipIDs,
      priorSeededListIDs: transition.seededListIDs
    )
    let plannedCandidate = SnipLibraryTransferSnapshot(
      revision: candidateStore.revision,
      snips: plan.snips,
      lists: plan.lists,
      attachmentData: plan.attachmentData,
      legacyManualPositions: [:],
      additionalSeenRequestIDs: plan.additionalSeenRequestIDs
    )
    let provenance = try Self.seedProvenance(
      approvedSnipIDs: plan.result.approvedSnipIDs,
      prior: transition.seedProvenance,
      source: source,
      candidate: plannedCandidate,
      transitionID: transition.id
    )
    let priorCandidateListIDs = Set(candidateBefore.lists.map(\.id))
    let seededListIDs = transition.seededListIDs.union(
      source.lists.map(\.id).filter { !priorCandidateListIDs.contains($0) }
    )
    let intent = SyncModeMergeIntent(
      id: UUID(),
      sourceRevision: source.revision,
      planDigest: plan.digest,
      approvedSnipIDs: plan.result.approvedSnipIDs,
      recoveredSourceSnipIDs: plan.result.recoveredSourceSnipIDs,
      seedProvenance: provenance,
      seededListIDs: seededListIDs
    )
    var intended = manifest
    try intended.updateTransition(orThrow: .invalidFreezeToken) {
      try $0.recordMergeIntent(intent, using: token)
    }
    try commit(intended)
    try crashHook(.beforeCandidateMergeDurability)
    _ = try await candidate.applyTransferPlan(plan, currentRevision: candidateStore.revision)
    try crashHook(.afterCandidateMergeDurability)
    var next = manifest
    try next.updateTransition { try $0.finishMerge(intent) }
    try commit(next)
    return SnipLibraryTransferResult(
      approvedSnipIDs: intent.approvedSnipIDs,
      recoveredSourceSnipIDs: intent.recoveredSourceSnipIDs
    )
  }

  func mergeFullReenableSnapshot(
    _ source: SnipLibraryTransferSnapshot,
    using token: SyncModeFreezeToken,
    plan: CloudFullReenableApplyPlan
  ) async throws -> SnipLibraryTransferResult {
    guard let transition = manifest.transition, transition.awaitsMerge(using: token),
      source.revision == token.revision,
      plan.transitionID == transition.id,
      plan.namespaceKey == transition.namespace?.namespaceKey.rawValue,
      plan.targetRevision == store(id: transition.candidateStoreID)?.revision,
      try plan.hasValidDigest()
    else { throw SyncModePersistenceError.invalidFreezeToken }
    try requireFailedEnablePreparedPlan(plan, token: token)
    guard fullReenableMergeInFlight != transition.id else {
      throw SyncModePersistenceError.transitionInProgress
    }
    fullReenableMergeInFlight = transition.id
    defer { if fullReenableMergeInFlight == transition.id { fullReenableMergeInFlight = nil } }
    let candidateSnapshot = SnipLibraryTransferSnapshot(
      revision: plan.targetRevision,
      snips: plan.snips,
      lists: plan.lists,
      attachmentData: plan.attachmentData
    )
    let provenance = try Self.seedProvenance(
      approvedSnipIDs: plan.result.approvedSnipIDs,
      prior: transition.seedProvenance,
      source: source,
      candidate: candidateSnapshot,
      transitionID: transition.id
    )
    let priorCandidate = try await libraryForTransition(storeID: transition.candidateStoreID)
      .transferSnapshot(revision: plan.targetRevision)
    let priorCandidateListIDs = Set(priorCandidate.lists.map(\.id))
    let seededListIDs = transition.seededListIDs.union(
      source.lists.map(\.id).filter { !priorCandidateListIDs.contains($0) }
    )
    let intent = SyncModeMergeIntent(
      id: UUID(),
      sourceRevision: source.revision,
      planDigest: plan.planDigest,
      approvedSnipIDs: plan.result.approvedSnipIDs,
      recoveredSourceSnipIDs: plan.result.recoveredSourceSnipIDs,
      seedProvenance: provenance,
      seededListIDs: seededListIDs,
      fullReenablePlanID: transition.id
    )
    try stageFullReenablePlan(plan, candidateStoreID: transition.candidateStoreID)
    var intended = manifest
    try intended.updateTransition(orThrow: .invalidFreezeToken) {
      try $0.recordMergeIntent(intent, using: token)
    }
    try commit(intended)
    try crashHook(.beforeCandidateMergeDurability)
    try await writeHook(.beforeFullReenablePlanApply)
    do {
      _ = try await libraryForTransition(storeID: transition.candidateStoreID)
        .applyCloudFullReenablePlan(plan, currentRevision: plan.targetRevision)
    } catch CloudFullStorageError.staleAcceptedEntity {
      try resetFullReenableIntent(intent, reason: nil)
      throw CloudFullStorageError.staleAcceptedEntity
    } catch CloudFullStorageError.namespaceStateMismatch {
      try resetFullReenableIntent(intent, reason: nil)
      throw CloudFullStorageError.namespaceStateMismatch
    } catch let error as SnipLibraryError {
      if case .transferConflict = error {
        try resetFullReenableIntent(intent, reason: .transferConflict)
      } else {
        try resetFullReenableIntent(intent, reason: .storageFailure)
      }
      throw error
    } catch {
      try resetFullReenableIntent(intent, reason: .storageFailure)
      throw error
    }
    try crashHook(.afterCandidateMergeDurability)
    try advanceFullReenableIntent(intent)
    return plan.result
  }

  package func reconcileFullReenableIntent() async throws {
    guard let transition = manifest.transition,
      transition.phase == .sourceFrozen,
      let initialIntent = transition.mergeIntent,
      initialIntent.fullReenablePlanID == transition.id,
      fullReenableMergeInFlight != transition.id
    else { return }
    fullReenableMergeInFlight = transition.id
    defer { if fullReenableMergeInFlight == transition.id { fullReenableMergeInFlight = nil } }
    var intent = initialIntent
    // A pre-upgrade intent cannot certify a missing historical source capture. Keep its
    // candidate for review and release the source through the existing intent rollback.
    guard let token = transition.freezeToken,
      let evidence = try? failedEnableFiles.read(transition.sourceStoreID),
      evidence.namespaces.flatMap(\.captures).contains(where: {
        $0.transitionID == FailedEnableEncoding.uuid(transition.id)
          && $0.freeze.id == FailedEnableEncoding.uuid(token.id)
      })
    else {
      try resetFullReenableIntent(intent, reason: .enrollmentBlocked)
      return
    }
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    let proof = CloudFullReenableCommitProof(
      namespaceKey: transition.namespace?.namespaceKey ?? CloudSyncNamespaceKey(rawValue: ""),
      transitionID: transition.id,
      digest: intent.planDigest
    )
    do {
      if try await candidate.recognizesAppliedCloudFullReenable(proof) {
        try advanceFullReenableIntent(intent)
        return
      }
    } catch {
      try abortUnactivatedCandidate(reason: .storageFailure)
      throw SyncModePersistenceError.storageFailure
    }
    var plan: CloudFullReenableApplyPlan
    do {
      let restored = try loadFullReenablePlan(
        candidateStoreID: transition.candidateStoreID,
        transitionID: transition.id
      )
      plan = restored.plan
      if let legacyDigest = restored.acceptedLegacyDigest {
        guard let candidateStore = store(id: transition.candidateStoreID),
          candidateStore.revision == plan.targetRevision
        else { throw SyncModePersistenceError.invalidManifest }
        let candidateSnapshot = try await candidate.transferSnapshot(
          revision: candidateStore.revision
        )
        plan = try plan.replacingTargetDigest(
          SnipLibraryTransferPlanner.digest(snapshot: candidateSnapshot)
        )
        if legacyDigest == intent.planDigest, plan.planDigest != intent.planDigest {
          let migrated = SyncModeMergeIntent(
            id: intent.id,
            sourceRevision: intent.sourceRevision,
            planDigest: plan.planDigest,
            approvedSnipIDs: intent.approvedSnipIDs,
            recoveredSourceSnipIDs: intent.recoveredSourceSnipIDs,
            seedProvenance: intent.seedProvenance,
            seededListIDs: intent.seededListIDs,
            fullReenablePlanID: intent.fullReenablePlanID
          )
          var next = manifest
          try next.updateTransition { try $0.replaceMergeIntent(intent, with: migrated) }
          try commit(next)
          intent = migrated
        }
        guard plan.planDigest == intent.planDigest else {
          throw SyncModePersistenceError.invalidManifest
        }
        try stageFullReenablePlan(plan, candidateStoreID: transition.candidateStoreID)
      }
      guard plan.transitionID == transition.id,
        plan.planDigest == intent.planDigest,
        try plan.hasValidDigest()
      else { throw SyncModePersistenceError.invalidManifest }
    } catch {
      try resetFullReenableIntent(intent, reason: .storageFailure)
      throw SyncModePersistenceError.storageFailure
    }
    try await writeHook(.beforeFullReenablePlanApply)
    do {
      _ = try await candidate.applyCloudFullReenablePlan(
        plan,
        currentRevision: plan.targetRevision
      )
    } catch CloudFullStorageError.staleAcceptedEntity {
      try resetFullReenableIntent(intent, reason: nil)
      throw CloudFullStorageError.staleAcceptedEntity
    } catch CloudFullStorageError.namespaceStateMismatch {
      try resetFullReenableIntent(intent, reason: nil)
      throw CloudFullStorageError.namespaceStateMismatch
    } catch let error as SnipLibraryError {
      let reason: ICloudSyncAttentionReason = if case .transferConflict = error {
        .transferConflict
      } else {
        .storageFailure
      }
      try resetFullReenableIntent(intent, reason: reason)
      throw error
    } catch {
      try resetFullReenableIntent(intent, reason: .storageFailure)
      throw error
    }
    try advanceFullReenableIntent(intent)
  }

  private func advanceFullReenableIntent(_ intent: SyncModeMergeIntent) throws {
    if let transition = manifest.transition {
      do {
        try markFailedEnableApplied(transition: transition, planDigest: intent.planDigest)
      } catch {
        // The candidate receipt and published source capture survive. Evidence bookkeeping
        // must withhold setup progress without adding a persistent source-content freeze.
        try resetFullReenableIntent(intent, reason: .enrollmentBlocked)
        throw error
      }
    }
    var next = manifest
    try next.updateTransition { try $0.finishMerge(intent) }
    try commit(next)
    removeStagedFullReenablePlan(
      candidateStoreID: manifest.transition?.candidateStoreID,
      transitionID: intent.fullReenablePlanID
    )
  }

  private func resetFullReenableIntent(
    _ intent: SyncModeMergeIntent,
    reason: ICloudSyncAttentionReason?
  ) throws {
    var next = manifest
    try next.updateTransition { try $0.abandonMerge(intent) }
    guard let transition = manifest.transition,
      manifest.activeStoreID == transition.sourceStoreID
    else { throw SyncModePersistenceError.transitionInProgress }
    next.attentionReason = reason
    try commit(next)
    removeStagedFullReenablePlan(
      candidateStoreID: transition.candidateStoreID,
      transitionID: intent.fullReenablePlanID
    )
  }

  private func fullReenablePlanRoot(
    candidateStoreID: UUID,
    transitionID: UUID
  ) throws -> URL {
    guard let candidate = store(id: candidateStoreID) else {
      throw SyncModePersistenceError.missingStore
    }
    return storeURL(candidate)
      .appendingPathComponent("full-reenable-v1", isDirectory: true)
      .appendingPathComponent(transitionID.uuidString.lowercased(), isDirectory: true)
  }

  private func stageFullReenablePlan(
    _ plan: CloudFullReenableApplyPlan,
    candidateStoreID: UUID
  ) throws {
    let root = try fullReenablePlanRoot(
      candidateStoreID: candidateStoreID,
      transitionID: plan.transitionID
    )
    let staged = CloudFullReenableStagedPlan(plan: plan)
    for file in staged.attachmentFiles {
      guard let data = plan.attachmentData[file.id] else {
        throw SyncModePersistenceError.storageFailure
      }
      let url = root.appendingPathComponent(file.relativePath)
      if FileManager.default.fileExists(atPath: url.path) {
        guard try Data(contentsOf: url) == data else {
          throw SnipLibraryError.transferConflict(.attachmentIdentity(file.id))
        }
      } else {
        try DurableFile.write(data, to: url)
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try DurableFile.write(
      encoder.encode(staged),
      to: root.appendingPathComponent("plan.json")
    )
  }

  private func loadFullReenablePlan(
    candidateStoreID: UUID,
    transitionID: UUID
  ) throws -> CloudFullReenableStagedPlan.Restored {
    let root = try fullReenablePlanRoot(
      candidateStoreID: candidateStoreID,
      transitionID: transitionID
    )
    do {
      let staged = try JSONDecoder().decode(
        CloudFullReenableStagedPlan.self,
        from: Data(contentsOf: root.appendingPathComponent("plan.json"))
      )
      guard staged.transitionID == transitionID else {
        throw SyncModePersistenceError.invalidManifest
      }
      return try staged.restore(from: root)
    } catch let error as SyncModePersistenceError {
      throw error
    } catch {
      throw SyncModePersistenceError.invalidManifest
    }
  }

  private func removeStagedFullReenablePlan(
    candidateStoreID: UUID?,
    transitionID: UUID?
  ) {
    guard let candidateStoreID, let transitionID,
      let root = try? fullReenablePlanRoot(
        candidateStoreID: candidateStoreID,
        transitionID: transitionID
      ),
      FileManager.default.fileExists(atPath: root.path)
    else { return }
    try? FileManager.default.removeItem(at: root)
  }

  private static func seedProvenance(
    approvedSnipIDs: Set<UUID>,
    prior: [SyncModeSeedProvenance],
    source: SnipLibraryTransferSnapshot,
    candidate: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) throws -> [SyncModeSeedProvenance] {
    let sourceByID = Dictionary(uniqueKeysWithValues: source.snips.map { ($0.id, $0) })
    let candidateByID = Dictionary(uniqueKeysWithValues: candidate.snips.map { ($0.id, $0) })
    var valuesByCandidate = Dictionary(
      uniqueKeysWithValues: prior.map { ($0.candidateSnipID, $0) }
    )
    let priorCandidateIDs = Set(valuesByCandidate.keys)
    for candidateID in approvedSnipIDs.subtracting(priorCandidateIDs) {
      guard let candidateSnip = candidateByID[candidateID] else {
        throw SyncModePersistenceError.storageFailure
      }
      let sourceID: UUID
      if sourceByID[candidateID] != nil {
        sourceID = candidateID
      } else if let recoveredSource = source.snips.first(where: {
        SnipLibraryTransferPlanner.derivedUUID(transitionID: transitionID, sourceID: $0.id)
          == candidateID
      }) {
        sourceID = recoveredSource.id
      } else {
        throw SyncModePersistenceError.storageFailure
      }
      valuesByCandidate[candidateID] = SyncModeSeedProvenance(
        sourceSnipID: sourceID,
        candidateSnipID: candidateID,
        candidateRequestID: candidateSnip.requestID,
        baseDigest: SnipLibraryTransferPlanner.digest(
          snip: candidateSnip,
          attachmentData: candidate.attachmentData
        ),
        baseRemoteDigest: SnipLibraryTransferPlanner.remoteDigest(snip: candidateSnip)
      )
    }
    return valuesByCandidate.values.sorted {
      $0.candidateSnipID.uuidString < $1.candidateSnipID.uuidString
    }
  }

}
