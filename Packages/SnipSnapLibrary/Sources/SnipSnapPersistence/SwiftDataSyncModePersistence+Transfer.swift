import CryptoKit
import Foundation
import SnipSnapCore

private struct CloudFullReenableStagedPlan: Codable {
  struct AttachmentFile: Codable {
    let id: UUID
    let relativePath: String
    let digest: Data
  }

  let storageVersion: Int
  let transitionID: UUID
  let namespaceKey: String
  let expectedNamespaceRevision: UInt64
  let targetRevision: UInt64
  let targetDigest: Data
  let snips: [Snip]
  let lists: [SnipList]
  let dormantPayload: Data
  let acceptedCAS: [CloudFullReenableAcceptedCAS]
  let conflicts: [CloudConflictInput]
  let recoveryInputs: [CloudFullRecoveryInput]
  let result: SnipLibraryTransferResult
  let attachmentFiles: [AttachmentFile]
  let planDigest: Data

  init(plan: CloudFullReenableApplyPlan) {
    storageVersion = 1
    transitionID = plan.transitionID
    namespaceKey = plan.namespaceKey
    expectedNamespaceRevision = plan.expectedNamespaceRevision
    targetRevision = plan.targetRevision
    targetDigest = plan.targetDigest
    snips = plan.snips
    lists = plan.lists
    dormantPayload = plan.dormantPayload
    acceptedCAS = plan.acceptedCAS
    conflicts = plan.conflicts
    recoveryInputs = plan.recoveryInputs
    result = plan.result
    attachmentFiles = plan.attachmentData.map { id, data in
      let digest = Data(SHA256.hash(data: data))
      return AttachmentFile(
        id: id,
        relativePath: "attachments/\(Self.hex(digest)).data",
        digest: digest
      )
    }.sorted { $0.id.uuidString < $1.id.uuidString }
    planDigest = plan.planDigest
  }

  func restore(from root: URL) throws -> CloudFullReenableApplyPlan {
    guard storageVersion == 1,
      Set(attachmentFiles.map(\.id)).count == attachmentFiles.count
    else { throw SyncModePersistenceError.invalidManifest }
    var attachmentData: [UUID: Data] = [:]
    for file in attachmentFiles {
      let expectedPath = "attachments/\(Self.hex(file.digest)).data"
      guard file.relativePath == expectedPath else {
        throw SyncModePersistenceError.invalidManifest
      }
      let data = try Data(contentsOf: root.appendingPathComponent(file.relativePath))
      guard Data(SHA256.hash(data: data)) == file.digest else {
        throw SyncModePersistenceError.invalidManifest
      }
      attachmentData[file.id] = data
    }
    let plan = try CloudFullReenableApplyPlan(
      transitionID: transitionID,
      namespaceKey: namespaceKey,
      expectedNamespaceRevision: expectedNamespaceRevision,
      targetRevision: targetRevision,
      targetDigest: targetDigest,
      snips: snips,
      lists: lists,
      attachmentData: attachmentData,
      dormantPayload: dormantPayload,
      acceptedCAS: acceptedCAS,
      conflicts: conflicts,
      recoveryInputs: recoveryInputs,
      result: result
    )
    guard plan.planDigest == planDigest else {
      throw SyncModePersistenceError.invalidManifest
    }
    return plan
  }

  private static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}


extension SwiftDataSyncModePersistence {
  package func restoreRecoveryStore(
    _ recoveryStoreID: UUID,
    intoActiveStoreWith resetID: UUID
  ) async throws {
    guard manifest.transition == nil,
      let recovery = store(id: recoveryStoreID),
      recovery.lifecycle == .recovery,
      let active = store(id: manifest.activeStoreID),
      active.id != recovery.id,
      active.kind == .iCloudSync
    else { throw SyncModePersistenceError.transitionInProgress }
    let source = try await libraryForTransition(storeID: recovery.id)
      .transferSnapshot(revision: recovery.revision)
    var recoverableSnips = source.snips
    for index in recoverableSnips.indices {
      recoverableSnips[index].attachments.removeAll {
        source.attachmentData[$0.id] == nil
      }
    }
    let userData = SnipLibraryTransferSnapshot(
      revision: source.revision,
      snips: recoverableSnips,
      lists: source.lists,
      attachmentData: source.attachmentData
    )
    let target = try libraryForTransition(storeID: active.id)
    _ = try await target.mergeTransferSnapshot(
      userData,
      transitionID: resetID
    )
    guard let namespace = active.namespace else {
      throw SyncModePersistenceError.transitionInProgress
    }
    let snapshot = try await target.checkedSnapshot(sortedBy: .manual)
    var references = Set(snapshot.lists.map {
      CloudEntityReference(kind: .list, domainID: $0.id)
    })
    references.formUnion(snapshot.snips.map {
      CloudEntityReference(kind: .snip, domainID: $0.id)
    })
    try await target.setCloudEnrollment(
      namespaceKey: Self.namespaceKey(namespace),
      references: references,
      localDependencies: Dictionary(uniqueKeysWithValues: snapshot.snips.map {
        ($0.id, $0.listID)
      })
    )
  }

  package func freezeSource() throws -> SyncModeFreezeToken {
    guard manifest.writeReservation == nil, !writeAdmissionInProgress else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    guard var transition = next.transition, transition.phase == .remoteFetched,
      transition.sourceStoreID == next.activeStoreID,
      let source = next.stores.first(where: { $0.id == transition.sourceStoreID })
    else { throw SyncModePersistenceError.transitionInProgress }
    let token = SyncModeFreezeToken(id: UUID(), sourceStoreID: source.id, revision: source.revision)
    transition.phase = .sourceFrozen
    transition.freezeToken = token
    transition.freezeSnapshotTaken = false
    next.transition = transition
    try commit(next)
    return token
  }

  package func finalSnapshot(using token: SyncModeFreezeToken) async throws -> SnipLibraryTransferSnapshot {
    var next = manifest
    guard var transition = next.transition, transition.phase == .sourceFrozen,
      transition.freezeToken == token, !transition.freezeSnapshotTaken,
      store(id: token.sourceStoreID)?.revision == token.revision
    else { throw SyncModePersistenceError.invalidFreezeToken }
    transition.freezeSnapshotTaken = true
    next.transition = transition
    try commit(next)
    try readHook()
    return try await libraryForTransition(storeID: token.sourceStoreID)
      .transferSnapshot(revision: token.revision)
  }

  package func mergeFinalSnapshot(
    _ source: SnipLibraryTransferSnapshot,
    using token: SyncModeFreezeToken,
    acceptedTargetTextBySnipID suppliedAcceptedText: [UUID: String]? = nil
  ) async throws -> SnipLibraryTransferResult {
    guard let transition = manifest.transition, transition.phase == .sourceFrozen,
      transition.freezeToken == token, transition.freezeSnapshotTaken,
      source.revision == token.revision,
      let candidateStore = store(id: transition.candidateStoreID)
    else { throw SyncModePersistenceError.invalidFreezeToken }
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
      attachmentData: plan.attachmentData
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
    intended.transition?.mergeIntent = intent
    try commit(intended)
    try crashHook(.beforeCandidateMergeDurability)
    _ = try await candidate.applyTransferPlan(plan, currentRevision: candidateStore.revision)
    try crashHook(.afterCandidateMergeDurability)
    guard manifest.transition?.mergeIntent == intent else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.transition?.phase = .recordsMerged
    next.transition?.approvedSnipIDs = intent.approvedSnipIDs
    next.transition?.pendingSettlementSnipIDs = []
    next.transition?.sendAttempt = nil
    next.transition?.seedProvenance = intent.seedProvenance
    next.transition?.seededListIDs = intent.seededListIDs
    next.transition?.mergeIntent = nil
    try commit(next)
    return SnipLibraryTransferResult(
      approvedSnipIDs: intent.approvedSnipIDs,
      recoveredSourceSnipIDs: intent.recoveredSourceSnipIDs
    )
  }

  package func mergeFullReenableSnapshot(
    _ source: SnipLibraryTransferSnapshot,
    using token: SyncModeFreezeToken,
    plan: CloudFullReenableApplyPlan
  ) async throws -> SnipLibraryTransferResult {
    guard let transition = manifest.transition, transition.phase == .sourceFrozen,
      transition.freezeToken == token, transition.freezeSnapshotTaken,
      source.revision == token.revision,
      plan.transitionID == transition.id,
      plan.namespaceKey == transition.namespace.map(Self.namespaceKey),
      plan.targetRevision == store(id: transition.candidateStoreID)?.revision,
      try plan.hasValidDigest()
    else { throw SyncModePersistenceError.invalidFreezeToken }
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
    intended.transition?.mergeIntent = intent
    try commit(intended)
    try crashHook(.beforeCandidateMergeDurability)
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
      let intent = transition.mergeIntent,
      intent.fullReenablePlanID == transition.id
    else { return }
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    if let receipt = try await candidate.cloudFullReenableReceipt(
      namespaceKey: transition.namespace.map(Self.namespaceKey) ?? "",
      transitionID: transition.id
    ) {
      guard receipt == intent.planDigest else {
        try abortUnactivatedCandidate(reason: .storageFailure)
        throw SyncModePersistenceError.storageFailure
      }
      try advanceFullReenableIntent(intent)
      return
    }
    let plan: CloudFullReenableApplyPlan
    do {
      plan = try loadFullReenablePlan(
        candidateStoreID: transition.candidateStoreID,
        transitionID: transition.id
      )
      guard plan.transitionID == transition.id,
        plan.planDigest == intent.planDigest,
        try plan.hasValidDigest()
      else { throw SyncModePersistenceError.invalidManifest }
    } catch {
      try resetFullReenableIntent(intent, reason: .storageFailure)
      throw SyncModePersistenceError.storageFailure
    }
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
    guard manifest.transition?.mergeIntent == intent else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.transition?.phase = .recordsMerged
    next.transition?.approvedSnipIDs = intent.approvedSnipIDs
    next.transition?.pendingSettlementSnipIDs = []
    next.transition?.sendAttempt = nil
    next.transition?.seedProvenance = intent.seedProvenance
    next.transition?.seededListIDs = intent.seededListIDs
    next.transition?.mergeIntent = nil
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
    guard let transition = manifest.transition,
      transition.mergeIntent == intent,
      manifest.activeStoreID == transition.sourceStoreID
    else { throw SyncModePersistenceError.transitionInProgress }
    var next = manifest
    next.transition?.mergeIntent = nil
    next.transition?.phase = .candidateReady
    next.transition?.freezeToken = nil
    next.transition?.freezeSnapshotTaken = false
    next.transition?.approvedSnipIDs = []
    next.transition?.pendingSettlementSnipIDs = []
    next.transition?.sendAttempt = nil
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
  ) throws -> CloudFullReenableApplyPlan {
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

  static func namespaceKey(_ value: ICloudSyncNamespaceBinding) -> String {
    SnipRecoveryScopeFactory.namespaceKey(value)
  }

}
