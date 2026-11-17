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
    let preparation = try requireFailedEnablePreparedPlan(plan, token: token)
    let semanticRegistration = failedEnableSemanticRegistration
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
      transitionID: transition.id,
      reviewSources: try failedEnableReviewSourceMap(plan: plan)
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
    let applyPreimage = manifest
    guard applyPreimage == intended, let applyingTransition = applyPreimage.transition,
      applyingTransition.id == transition.id,
      applyingTransition.sourceStoreID == transition.sourceStoreID,
      applyingTransition.candidateStoreID == transition.candidateStoreID,
      applyingTransition.freezeToken == token, applyingTransition.mergeIntent == intent
    else { throw SyncModePersistenceError.invalidFreezeToken }
    try crashHook(.beforeCandidateMergeDurability)
    try await writeHook(.beforeFullReenablePlanApply)
    do {
      guard try await validateFailedEnableTurnOffApply(transition: applyingTransition,
        preparation: preparation, digest: intent.planDigest, applied: false, expectedManifest: applyPreimage,
        expectedRegistration: semanticRegistration) else {
        if manifest.transition?.mergeIntent == intent {
          try resetFullReenableIntent(intent, reason: .enrollmentBlocked, preparation: preparation)
        }
        throw FailedEnableEvidenceError.reviewRequired
      }
    } catch is FailedEnableEvidenceError {
      if manifest.transition?.mergeIntent == intent {
        try resetFullReenableIntent(intent, reason: .enrollmentBlocked, preparation: preparation)
      }
      throw FailedEnableEvidenceError.reviewRequired
    } catch {
      if manifest.transition?.mergeIntent == intent {
        try resetFullReenableIntent(intent, reason: .storageFailure, preparation: preparation)
      }
      throw error
    }
    do {
      _ = try await libraryForTransition(storeID: transition.candidateStoreID)
        .applyCloudFullReenablePlan(plan, currentRevision: plan.targetRevision)
    } catch CloudFullStorageError.staleAcceptedEntity {
      try resetFullReenableIntent(intent, reason: nil, preparation: preparation)
      throw CloudFullStorageError.staleAcceptedEntity
    } catch CloudFullStorageError.namespaceStateMismatch {
      try resetFullReenableIntent(intent, reason: nil, preparation: preparation)
      throw CloudFullStorageError.namespaceStateMismatch
    } catch let error as SnipLibraryError {
      if case .transferConflict = error {
        try resetFullReenableIntent(intent, reason: .transferConflict, preparation: preparation)
      } else {
        try resetFullReenableIntent(intent, reason: .storageFailure, preparation: preparation)
      }
      throw error
    } catch {
      try resetFullReenableIntent(intent, reason: .storageFailure, preparation: preparation)
      throw error
    }
    try crashHook(.afterCandidateMergeDurability)
    guard try await advanceFullReenableIntent(intent, preparation: preparation, expectedManifest: applyPreimage,
        semanticRegistration: semanticRegistration) else { throw FailedEnableEvidenceError.reviewRequired }
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
    var applyPreimage = manifest
    let semanticRegistration = failedEnableSemanticRegistration
    // Missing correlation is not ordinary preparation. Roll back without discarding
    // the actual staged plan or receipt that may be the only surviving replay evidence.
    guard let token = transition.freezeToken else {
      try resetFullReenableIntent(intent, reason: .enrollmentBlocked)
      return
    }
    let preparation: FailedEnablePreparedRead
    do {
      guard let prepared = try failedEnablePreparedRead(transition: transition,
        digest: intent.planDigest, token: token) else {
        try resetFullReenableIntent(intent, reason: .enrollmentBlocked)
        return
      }
      preparation = prepared
    } catch {
      try resetFullReenableIntent(intent, reason: .enrollmentBlocked)
      return
    }
    guard failedEnableSemantics?.reviewNamespace == transition.namespace,
      !preparation.requiresTurnOffAbsence || failedEnableAccountCheck != nil else {
      try resetFullReenableIntent(intent, reason: .enrollmentBlocked, preparation: preparation)
      return
    }
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    do {
      let alreadyApplied = try await withFailedEnablePreparedReceipt(preparation) { candidate, root in
        try await candidate.recognizesFailedEnablePrepared(preparation,
          digest: intent.planDigest, evidenceRoot: root)
      }
      if alreadyApplied {
        _ = try await advanceFullReenableIntent(intent, preparation: preparation,
          expectedManifest: applyPreimage, semanticRegistration: semanticRegistration)
        return
      }
    } catch {
      if preparation.requiresTurnOffAbsence || error is FailedEnableEvidenceError
        || manifest != applyPreimage || failedEnableSemanticRegistration != semanticRegistration
        || (try? preparation.current(at: rootURL)) == nil {
        if manifest.transition?.mergeIntent == intent {
          let reason: ICloudSyncAttentionReason = error is FailedEnableEvidenceError
            ? .enrollmentBlocked : .storageFailure
          try resetFullReenableIntent(intent, reason: reason, preparation: preparation)
        }
        if error is FailedEnableEvidenceError, manifest.transition?.id == transition.id,
          manifest.transition?.phase == .candidateReady { return }
        throw error
      }
      // Keep the old ordinary receipt-error route only while its correlation still holds.
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
          guard manifest == applyPreimage,
            failedEnableSemanticRegistration == semanticRegistration else {
            throw FailedEnableEvidenceError.changed
          }
          _ = try preparation.current(at: rootURL)
          var next = manifest
          try next.updateTransition { try $0.replaceMergeIntent(intent, with: migrated) }
          try commit(next)
          applyPreimage = next
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
      if manifest.transition?.mergeIntent == intent {
        try resetFullReenableIntent(intent, reason: .storageFailure, preparation: preparation)
      }
      throw SyncModePersistenceError.storageFailure
    }
    guard let applyingTransition = applyPreimage.transition,
      applyingTransition.id == transition.id,
      applyingTransition.sourceStoreID == transition.sourceStoreID,
      applyingTransition.candidateStoreID == transition.candidateStoreID,
      applyingTransition.freezeToken == token, applyingTransition.mergeIntent == intent
    else { throw SyncModePersistenceError.invalidManifest }
    try await writeHook(.beforeFullReenablePlanApply)
    do {
      guard try await validateFailedEnableTurnOffApply(transition: applyingTransition,
        preparation: preparation, digest: intent.planDigest, applied: false, expectedManifest: applyPreimage,
        expectedRegistration: semanticRegistration) else {
        if manifest.transition?.mergeIntent == intent {
          try resetFullReenableIntent(intent, reason: .enrollmentBlocked, preparation: preparation)
        }
        guard manifest.transition?.id == transition.id,
          manifest.transition?.phase == .candidateReady else {
          throw FailedEnableEvidenceError.changed
        }
        return
      }
    } catch let error as FailedEnableEvidenceError {
      if manifest.transition?.mergeIntent == intent {
        try resetFullReenableIntent(intent, reason: .enrollmentBlocked, preparation: preparation)
      }
      guard manifest.transition?.id == transition.id,
        manifest.transition?.phase == .candidateReady else { throw error }
      return
    } catch {
      if manifest.transition?.mergeIntent == intent {
        try resetFullReenableIntent(intent, reason: .storageFailure, preparation: preparation)
      }
      throw error
    }
    do {
      _ = try await candidate.applyCloudFullReenablePlan(
        plan,
        currentRevision: plan.targetRevision
      )
    } catch CloudFullStorageError.staleAcceptedEntity {
      try resetFullReenableIntent(intent, reason: nil, preparation: preparation)
      throw CloudFullStorageError.staleAcceptedEntity
    } catch CloudFullStorageError.namespaceStateMismatch {
      try resetFullReenableIntent(intent, reason: nil, preparation: preparation)
      throw CloudFullStorageError.namespaceStateMismatch
    } catch let error as SnipLibraryError {
      let reason: ICloudSyncAttentionReason = if case .transferConflict = error {
        .transferConflict
      } else {
        .storageFailure
      }
      try resetFullReenableIntent(intent, reason: reason, preparation: preparation)
      throw error
    } catch {
      try resetFullReenableIntent(intent, reason: .storageFailure, preparation: preparation)
      throw error
    }
    do {
      _ = try await advanceFullReenableIntent(intent, preparation: preparation, expectedManifest: applyPreimage,
        semanticRegistration: semanticRegistration)
    } catch let error as FailedEnableEvidenceError {
      guard manifest.transition?.id == transition.id,
        manifest.transition?.phase == .candidateReady else { throw error }
      return
    }
  }

  private func advanceFullReenableIntent(_ intent: SyncModeMergeIntent,
    preparation: FailedEnablePreparedRead, expectedManifest: Manifest,
    semanticRegistration: UUID
  ) async throws -> Bool {
    guard let transition = expectedManifest.transition else { throw SyncModePersistenceError.transitionInProgress }
    do {
      guard manifest == expectedManifest,
        failedEnableSemanticRegistration == semanticRegistration else {
        if manifest.transition?.mergeIntent == intent {
          try resetFullReenableIntent(intent, reason: .enrollmentBlocked, preparation: preparation)
        }
        return false
      }
      _ = try preparation.current(at: rootURL)
      if preparation.requiresTurnOffAbsence {
        try await recoverFailedEnableTurnOffApply(preparation: preparation)
        let advanced = try await validateFailedEnableTurnOffApply(transition: transition,
          preparation: preparation, digest: intent.planDigest, applied: true,
          expectedManifest: expectedManifest, expectedRegistration: semanticRegistration) {
          try self.finishFullReenableIntent(intent, preparation: preparation, markApplied: false)
        }
        if !advanced, manifest.transition?.mergeIntent == intent {
          try resetFullReenableIntent(intent, reason: .enrollmentBlocked, preparation: preparation)
        }
        return advanced
      }
      try finishFullReenableIntent(intent, preparation: preparation)
      return true
    } catch {
      if manifest.transition?.mergeIntent == intent {
        try resetFullReenableIntent(intent, reason: .storageFailure, preparation: preparation)
      }
      throw error
    }
  }

  private func finishFullReenableIntent(_ intent: SyncModeMergeIntent,
    preparation: FailedEnablePreparedRead, markApplied: Bool = true
  ) throws {
    _ = try preparation.current(at: rootURL)
    if markApplied, let transition = manifest.transition {
      do {
        try markFailedEnableApplied(transition: transition, planDigest: intent.planDigest,
          preparation: preparation)
      } catch {
        try resetFullReenableIntent(intent, reason: .enrollmentBlocked, preparation: preparation)
        throw error
      }
    } else {
      guard try preparation.current(at: rootURL).state == .checked else {
        throw FailedEnableEvidenceError.changed
      }
    }
    var next = manifest
    try next.updateTransition { try $0.finishMerge(intent) }
    try commit(next)
    do {
      guard !failedEnableUncertainSources.contains(preparation.sourceStoreID) else {
        throw FailedEnableEvidenceError.changed
      }
      guard try preparation.current(at: rootURL).state == .checked else {
        throw FailedEnableEvidenceError.changed
      }
    } catch {
      // The completed private apply is real; unavailable bookkeeping cannot discard its plan.
      try unfreezeBeforePointerSwap(reason: .enrollmentBlocked)
      throw error
    }
    removeStagedFullReenablePlan(
      candidateStoreID: manifest.transition?.candidateStoreID,
      transitionID: intent.fullReenablePlanID
    )
  }

  private func resetFullReenableIntent(
    _ intent: SyncModeMergeIntent,
    reason: ICloudSyncAttentionReason?,
    preparation: FailedEnablePreparedRead? = nil
  ) throws {
    var next = manifest
    try next.updateTransition { try $0.abandonMerge(intent) }
    guard let transition = manifest.transition,
      manifest.activeStoreID == transition.sourceStoreID
    else { throw SyncModePersistenceError.transitionInProgress }
    next.attentionReason = reason
    try commit(next)
    // Nil means unavailable correlation, never proof of ordinary work. Failed cleanup
    // checks retain the staged bytes; they must not replace the original admission error.
    if let preparation, !preparation.requiresTurnOffAbsence,
      !failedEnableUncertainSources.contains(preparation.sourceStoreID),
      preparation.transitionID == transition.id,
      preparation.sourceStoreID == transition.sourceStoreID,
      preparation.candidateStoreID == transition.candidateStoreID,
      preparation.transfer.planDigest == FailedEnableEncoding.hex(intent.planDigest),
      (try? preparation.current(at: rootURL)) != nil {
      removeStagedFullReenablePlan(candidateStoreID: transition.candidateStoreID,
        transitionID: intent.fullReenablePlanID)
    }
  }

  func hasStagedFullReenableEvidence(_ transition: SyncModeTransition) throws -> Bool {
    let root = try fullReenablePlanRoot(candidateStoreID: transition.candidateStoreID,
      transitionID: transition.id)
    do {
      _ = try FileManager.default.attributesOfItem(atPath: root.path)
      return true
    } catch let error as CocoaError
      where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
      return false
    }
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
    transitionID: UUID,
    reviewSources: [UUID: UUID] = [:]
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
      } else if let reviewedSource = reviewSources[candidateID], sourceByID[reviewedSource] != nil {
        sourceID = reviewedSource
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
