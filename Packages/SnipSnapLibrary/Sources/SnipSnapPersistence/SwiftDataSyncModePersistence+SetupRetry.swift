import Foundation
import SnipSnapCore

struct CloudRetainedSetupPointerDeletes: Codable, Equatable {
  let namespace: ICloudSyncNamespaceBinding
  var receipts: [CloudSetupPointerDelete]
  var holds: [CloudSetupPointerDeleteHold]? = nil

  var isValid: Bool {
    let holds = holds ?? []
    return (!receipts.isEmpty || !holds.isEmpty) && Set(receipts.map(\.key)).count == receipts.count
      && receipts.allSatisfy { $0.isValid(in: namespace) }
      && Set(holds.map(\.pointer)).count == holds.count
      && holds.allSatisfy { $0.isValid(in: namespace) }
  }
}

package struct CloudSetupDeleteProtection: Sendable {
  package let pointers: Set<CloudTextStorageIdentity>
  package let payloads: Set<CloudTextStorageIdentity>

  package init(pointers: Set<CloudTextStorageIdentity> = [], payloads: Set<CloudTextStorageIdentity> = []) {
    self.pointers = pointers
    self.payloads = payloads
  }

  package func blocks(
    _ operation: SyncModeSendOperation,
    allowingNewPointerDeletes allowed: Set<CloudTextStorageIdentity> = []
  ) -> Bool {
    payloads.contains(operation.recordIdentity)
      || (operation.kind == .delete && pointers.contains(operation.recordIdentity)
        && !allowed.contains(operation.recordIdentity))
  }
}

package struct SyncModeDeferredEnableCompletion: Codable, Equatable, Sendable {
  package static let prefix = "checking-deferred-completion:"
  package let binding: ICloudSyncNamespaceBinding
  package let storeID: UUID
  package let issue: SyncedContentSyncIssue?

  package init(binding: ICloudSyncNamespaceBinding, storeID: UUID, issue: SyncedContentSyncIssue?) {
    self.binding = binding
    self.storeID = storeID
    self.issue = issue
  }

  package static func markerURL(at rootURL: URL) -> URL {
    rootURL.appendingPathComponent("icloud-sync-enable-pending", isDirectory: false)
  }

  package func record(at rootURL: URL) throws {
    let encoded = try JSONEncoder().encode(self).base64EncodedString()
    try DurableFile.write(Data((Self.prefix + encoded).utf8), to: Self.markerURL(at: rootURL))
  }

  package static func decode(_ value: String) -> Self? {
    guard let data = Data(base64Encoded: String(value.dropFirst(prefix.count))) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}

extension SwiftDataSyncModePersistence {
  package func hasDeletedSetupSnip(in transition: SyncModeTransition) async throws -> Bool {
    guard manifest.setupRetrySourceIndex != nil, let namespace = transition.namespace,
      let evidence = setupRetryEvidence(namespace: namespace)
    else { return false }
    let acknowledged = Set(evidence.acknowledgedSnipKeys.map(\.reference.domainID))
    guard !acknowledged.isEmpty else { return false }
    let source = try await libraryForTransition(storeID: transition.sourceStoreID)
      .checkedSnapshot(sortedBy: .manual)
    guard manifest.transition == transition else { throw SyncModePersistenceError.transitionInProgress }
    return !acknowledged.subtracting(source.snips.map(\.id)).isEmpty
  }

  package func withSetupRetryBatchCommit<Value: Sendable>(
    candidateStoreID: UUID,
    namespace: ICloudSyncNamespaceBinding,
    _ commit: @Sendable () async throws -> Value
  ) async throws -> Value {
    guard manifest.setupRetrySourceIndex != nil, let transition = manifest.transition,
      transition.candidateStoreID == candidateStoreID, transition.namespace == namespace
    else { throw SyncModePersistenceError.transitionInProgress }
    // Fetched tombstones and sent pointer results can queue payload cleanup.
    // Keep source writes out of the check and commit.
    try beginStoreReplacement()
    defer { finishStoreReplacement() }
    return try await commit()
  }

  package func holdSetupForDeletedSnip(transitionID: UUID) throws {
    guard let transition = manifest.transition,
      transition.id == transitionID, transition.targetKind == .iCloudSync,
      transition.sourceStoreID == manifest.activeStoreID
    else { throw SyncModePersistenceError.transitionInProgress }
    var next = manifest
    try next.updateTransition {
      if $0.phase == .sourceFrozen { try $0.unfreeze() }
      if $0.phase == .remoteFetched { try $0.retryRemoteFetch() }
      guard $0.phase == .candidateReady else {
        throw SyncModePersistenceError.transitionInProgress
      }
    }
    next.attentionReason = .transferConflict
    try commitRollback(next)
  }

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

  package func setupReplacementAllocations(
    candidateStoreID: UUID, namespace: ICloudSyncNamespaceBinding
  ) async throws -> [UUID: CloudSetupPointerDelete.Replacement] {
    guard let token = setupRetryFreezeToken(candidateStoreID: candidateStoreID),
      manifest.transition?.namespace == namespace
    else { return [:] }
    let dependencies = Set(setupRetryEvidence(namespace: namespace)?.acceptedPointerDeletes
      .flatMap { $0.replacementDependencies ?? [] } ?? [])
    guard !dependencies.isEmpty else { return [:] }
    // A rebuilt candidate may reuse an unpublished allocation only for the
    // same attachment and bytes in the frozen source.
    let source = try await libraryForTransition(storeID: token.sourceStoreID).checkedSnapshot(sortedBy: .manual)
    guard setupRetryFreezeToken(candidateStoreID: candidateStoreID) == token else {
      throw SyncModePersistenceError.invalidFreezeToken
    }
    let groups = Dictionary(grouping: dependencies, by: \.attachmentID)
    var result: [UUID: CloudSetupPointerDelete.Replacement] = [:]
    for snip in source.snips {
      for attachment in snip.attachments {
        let id = attachment.id
        guard let bindings = groups[id], bindings.count == 1, let binding = bindings.first,
          let url = source.attachmentURLs[id],
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          binding.matchesSource(snipID: snip.id, sha256: try AttachmentFileIO.digest(at: url), byteCount: Int64(size))
        else { continue }
        result[id] = binding
      }
    }
    return result
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

  /// All exact source receipts from one sent batch are durable before the candidate can consume it.
  package func retainSetupPointerDeletes(
    _ bindings: [CloudSetupPointerDelete.Binding],
    candidateStoreID: UUID,
    namespace: ICloudSyncNamespaceBinding,
    receivedWhileFrozen: Bool = false
  ) async throws -> [CloudSetupPointerDelete] {
    guard let batchID = bindings.first?.key.batchID else { return [] }
    guard bindings.allSatisfy({ $0.key.batchID == batchID }),
      Set(bindings.map(\.key)).count == bindings.count
    else { throw SyncModePersistenceError.invalidManifest }
    guard let index = manifest.setupRetrySourceIndex, let transition = manifest.transition,
      transition.candidateStoreID == candidateStoreID, transition.namespace == namespace
    else { throw SyncModePersistenceError.transitionInProgress }
    var retained = Dictionary(uniqueKeysWithValues:
      (setupRetryEvidence(namespace: namespace)?.acceptedPointerDeletes ?? []).map { ($0.key, $0) })
    let missing = try bindings.filter { binding in
      guard let existing = retained[binding.key] else { return true }
      guard existing.bindingDigest == binding.digest else { throw SyncModePersistenceError.invalidManifest }
      return false
    }
    if receivedWhileFrozen, !missing.isEmpty {
      guard setupRetryFreezeToken(candidateStoreID: candidateStoreID) != nil,
        let attempt = transition.sendAttempt, attempt.namespace == namespace
      else { throw SyncModePersistenceError.invalidFreezeToken }
      let offeredDeletes = Set(attempt.operations.filter { $0.kind == .delete }.map(\.recordIdentity))
      guard Set(missing.map(\.key.pointer)).isSubset(of: offeredDeletes)
      else { throw SyncModePersistenceError.invalidFreezeToken }
    }
    if !missing.isEmpty {
      let receipts = try await libraryForTransition(storeID: candidateStoreID).setupPointerDeletes(
        namespaceKey: namespace.namespaceKey, bindings: missing
      )
      guard manifest.transition == transition, manifest.setupRetrySourceIndex == index else {
        throw SyncModePersistenceError.transitionInProgress
      }
      var next = manifest
      let previous = next.stores[index].setupRetryHistory ?? CloudSetupRetryHistory()
      var history = previous
      try history.update(namespace: namespace) { evidence in
        for receipt in receipts { try evidence.retainPointerDelete(receipt) }
        retained = Dictionary(uniqueKeysWithValues: evidence.acceptedPointerDeletes.map { ($0.key, $0) })
      }
      if history != previous {
        next.stores[index].setupRetryHistory = history
        try commit(next)
        try crashHook(.afterSetupPointerDeleteRetention)
      }
    }
    return try bindings.map { binding in
      guard let receipt = retained[binding.key], receipt.bindingDigest == binding.digest else {
        throw SyncModePersistenceError.invalidManifest
      }
      return receipt
    }
  }

  package func pendingSetupPointerDeletes(for transition: SyncModeTransition) -> [CloudSetupPointerDelete] {
    guard transition.targetKind == .iCloudSync, let namespace = transition.namespace,
      let evidence = store(id: transition.sourceStoreID)?.setupRetryHistory?.namespaces
        .first(where: { $0.namespace == namespace })
    else { return [] }
    return evidence.acceptedPointerDeletes
  }

  package func retainedSetupPointerDeletes(in namespace: ICloudSyncNamespaceBinding) -> [CloudSetupPointerDelete] {
    manifest.retainedSetupPointerDeletes.first { $0.namespace == namespace }?.receipts ?? []
  }

  package func setupDeleteProtection(in namespace: ICloudSyncNamespaceBinding) -> CloudSetupDeleteProtection {
    let retained = manifest.retainedSetupPointerDeletes.first { $0.namespace == namespace }
    let receipts = (retained?.receipts ?? []) + (setupRetryEvidence(namespace: namespace)?.acceptedPointerDeletes ?? [])
    let holds = retained?.holds ?? []
    return CloudSetupDeleteProtection(
      pointers: Set(receipts.map(\.key.pointer)).union(holds.map(\.pointer)),
      payloads: Set(receipts.flatMap(\.payloadIdentities)).union(holds.flatMap(\.payloads))
    )
  }

  /// Only this send may use the newly protected pointers. A later attempt sees them as already protected.
  package func recordSetupSendAttempt(
    _ attempt: SyncModeSendAttempt,
    offers: [CloudSetupRetryOffer],
    pointerDeletes: [CloudSetupPointerDeleteOffer],
    candidateStoreID: UUID,
    using token: SyncModeFreezeToken
  ) async throws -> Set<CloudTextStorageIdentity> {
    guard let transition = manifest.transition, transition.namespace == attempt.namespace,
      setupRetryFreezeToken(candidateStoreID: candidateStoreID) == token
    else { throw SyncModePersistenceError.invalidFreezeToken }
    let pointers = Set(pointerDeletes.map(\.pointer))
    let offeredPointers = attempt.operations.filter {
      $0.kind == .delete && CloudSetupPointerDeleteOffer.isPointer($0.recordIdentity)
    }.map(\.recordIdentity)
    guard pointers.count == pointerDeletes.count, pointers.count == offeredPointers.count,
      pointers == Set(offeredPointers)
    else {
      throw SyncModePersistenceError.invalidManifest
    }
    let holds = if pointerDeletes.isEmpty {
      [CloudSetupPointerDeleteHold]()
    } else {
      try await libraryForTransition(storeID: candidateStoreID).setupPointerDeleteHolds(
        namespaceKey: attempt.namespace.namespaceKey, offers: pointerDeletes
      )
    }
    let previousProtection = setupDeleteProtection(in: attempt.namespace)
    guard manifest.transition == transition, setupRetryFreezeToken(candidateStoreID: candidateStoreID) == token,
      !attempt.operations.contains(where: { previousProtection.blocks($0) })
    else { throw SyncModePersistenceError.transitionInProgress }
    try commitSendAttempt(attempt, setupRetryOffers: offers, holding: holds)
    return pointers
  }

  package func requireCurrentSetupSend(
    candidateStoreID: UUID, namespace: ICloudSyncNamespaceBinding, using token: SyncModeFreezeToken
  ) throws -> CloudSetupDeleteProtection {
    guard let transition = manifest.transition, transition.phase == .firstSendStarted,
      transition.namespace == namespace, setupRetryFreezeToken(candidateStoreID: candidateStoreID) == token
    else { throw SyncModePersistenceError.invalidFreezeToken }
    return setupDeleteProtection(in: namespace)
  }

  package func preserveSetupPointerReplacementRemaps(
    _ remaps: CloudSetupPointerDelete.ReplacementRemaps, for transition: SyncModeTransition
  ) throws {
    guard !remaps.isEmpty, let namespace = transition.namespace else { return }
    guard manifest.transition == transition, let index = manifest.setupRetrySourceIndex else {
      throw SyncModePersistenceError.transitionInProgress
    }
    guard let history = manifest.stores[index].setupRetryHistory else { return }
    var updated = history
    try updated.update(namespace: namespace) { try $0.applyPointerReplacementRemaps(remaps) }
    if updated != history {
      var next = manifest
      next.stores[index].setupRetryHistory = updated
      try commit(next)
    }
  }

  package func finishDeferredSetupEnableIfNeeded() throws -> Bool {
    guard let transition = manifest.transition, transition.phase == .pointerSwapped,
      manifest.checkedEnableStoreID == transition.candidateStoreID
    else { return false }
    try finishTransition()
    try? cleanupRetiredStores()
    return true
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
  mutating func holdSetupPointerDeletes(_ holds: [CloudSetupPointerDeleteHold], in namespace: ICloudSyncNamespaceBinding) {
    guard !holds.isEmpty else { return }
    if let index = retainedSetupPointerDeletes.firstIndex(where: { $0.namespace == namespace }) {
      retainedSetupPointerDeletes[index].holds = (retainedSetupPointerDeletes[index].holds ?? []) + holds
    } else {
      retainedSetupPointerDeletes.append(.init(namespace: namespace, receipts: [], holds: holds))
    }
  }

  mutating func retainSetupPointerDeletes(
    _ receipts: [CloudSetupPointerDelete], in namespace: ICloudSyncNamespaceBinding?
  ) throws {
    guard !receipts.isEmpty else { return }
    guard let namespace else { throw SyncModePersistenceError.invalidManifest }
    guard let index = retainedSetupPointerDeletes.firstIndex(where: { $0.namespace == namespace }) else {
      retainedSetupPointerDeletes.append(.init(namespace: namespace, receipts: receipts))
      return
    }
    for receipt in receipts {
      if let retained = retainedSetupPointerDeletes[index].receipts.first(where: { $0.key == receipt.key }) {
        guard retained == receipt else { throw SyncModePersistenceError.invalidManifest }
      } else {
        retainedSetupPointerDeletes[index].receipts.append(receipt)
      }
    }
  }

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
    if let attempt = transition.sendAttempt, attempt.namespace == namespace,
      !attempt.operations.isEmpty
    {
      history.update(namespace: namespace) { $0.recordLegacySend(attempt.operations) }
    } else if transition.mayHaveLegacySetupSend {
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
      let saves = Dictionary(grouping: attempt.operations.filter { $0.kind == .save }, by: \.recordIdentity)
      let offeredKeys = Set(offers.map(\.key))
      guard offeredKeys.count == offers.count, offeredKeys.allSatisfy({ key in
        saves[key.identity]?.contains { save in
          save.reference == key.reference || (save.reference == nil && key.attachmentID != nil)
        } == true
      }) else {
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
