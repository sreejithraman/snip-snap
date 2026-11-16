import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  var failedEnableFiles: FailedEnableEvidenceFile { FailedEnableEvidenceFile(root: rootURL) }

  package func installFailedEnableSemantics(_ semantics: any FailedEnableSemantics) async {
    failedEnableSemantics = semantics
    await reconcileFailedEnableOnOpen()
  }

  /// Reads, certifies and publishes through the durable owner before exposing the apply plan.
  package func prepareFailedEnableMerge(using token: SyncModeFreezeToken) async throws -> SnipLibraryTransferResult {
    guard let policy = failedEnableSemantics,
      let transition = manifest.transition, transition.awaitsMerge(using: token),
      transition.syncProtocol == .fullRecordV1, let namespace = transition.namespace
    else { throw FailedEnableEvidenceError.reviewRequired }
    try requireNoUncapturedFailedEnableRoots(transition)
    let prepared: FailedEnablePreparedMerge = try await withFailedEnableRead(transition: transition) {
      source, candidate in
      var prior = try self.failedEnableFiles.read(transition.sourceStoreID)
      let verified = try self.failedEnableContinuityMatches(prior, source: source,
        sourceID: transition.sourceStoreID)
      // A checked fetch by this newly registered candidate can establish an earlier Q by
      // value. Its observation records this actual owner, without claiming the old save ran.
      if verified, var retained = prior,
        let group = retained.namespaces.firstIndex(where: { $0.binding == FailedEnableBinding(namespace) }) {
        for index in retained.namespaces[group].captures.indices {
          retained.namespaces[group].captures[index] = try policy.observe(
            capture: retained.namespaces[group].captures[index], candidate: candidate,
            candidateStoreID: transition.candidateStoreID, namespace: namespace)
        }
        if retained != prior {
          let preimage = prior
          try self.failedEnableFiles.update(transition.sourceStoreID) { current in
            guard current == preimage else { throw FailedEnableEvidenceError.changed }
            return retained
          }
          prior = try self.failedEnableFiles.read(transition.sourceStoreID)
        }
      }
      let input = FailedEnablePreparationRead(source: source, candidate: candidate,
        transition: transition, token: token, evidence: prior, continuityVerified: verified)
      let prepared = try policy.prepare(input)
      let sourceDigest = try source.sourceDigest(sourceID: transition.sourceStoreID)
      let images = try source.images()
      let plannedImages = try self.failedEnableImages(prepared.plan)
      let ordinal = try prior?.namespaces.flatMap(\.captures).map {
        try FailedEnableEncoding.revision($0.ordinal)
      }.max() ?? 0
      guard ordinal < UInt64.max else { throw FailedEnableEvidenceError.unsupported }
      let id = FailedEnableEncoding.uuid(UUID())
      struct PreparationBinding: Encodable {
        let captureID: String
        let sourceDigest: String
        let namespace: FailedEnableBinding
        let syncProtocol: SyncModeSyncProtocol
        let predecessors: [String]
        let records: [FailedEnableRecord]
        let candidateDeletes: [FailedEnableCandidateDelete]
      }
      let binding = PreparationBinding(captureID: id, sourceDigest: sourceDigest,
        namespace: FailedEnableBinding(namespace), syncProtocol: transition.syncProtocol,
        predecessors: prepared.predecessors, records: prepared.records, candidateDeletes: [])
      var capture = FailedEnableCapture(id: id, ordinal: String(ordinal + 1),
        transitionID: FailedEnableEncoding.uuid(transition.id),
        candidateStoreID: FailedEnableEncoding.uuid(transition.candidateStoreID),
        syncProtocol: .fullRecordV1,
        freeze: FailedEnableFreeze(id: FailedEnableEncoding.uuid(token.id), sourceRevision: String(token.revision)),
        seenRequestIDs: source.seenRequestIDs.map(FailedEnableEncoding.uuid).sorted(),
        sourceDigest: sourceDigest, normalizer: 1,
        preparationDigest: try FailedEnableEncoding.digest(binding),
        predecessors: prepared.predecessors, armed: false,
        records: prepared.records, candidateDeletes: [])
      capture = try policy.observe(capture: capture, candidate: candidate,
        candidateStoreID: transition.candidateStoreID, namespace: namespace)
      let transfer = FailedEnableTransfer(kind: .candidate, sourceCaptureIDs: [id],
        sourceStoreID: FailedEnableEncoding.uuid(transition.sourceStoreID),
        destinationStoreID: FailedEnableEncoding.uuid(transition.candidateStoreID),
        namespace: FailedEnableBinding(namespace),
        planDigest: FailedEnableEncoding.hex(prepared.plan.planDigest),
        dormantDigest: FailedEnableEncoding.digest(prepared.plan.dormantPayload),
        outputs: plannedImages, conflicts: try prepared.plan.conflicts.map(FailedEnableEncoding.json),
        recoveryDescriptors: try prepared.plan.recoveryInputs.map(FailedEnableEncoding.json), state: .prepared)
      try self.failedEnableFiles.update(transition.sourceStoreID) { existing in
        guard existing == prior else { throw FailedEnableEvidenceError.changed }
        var bundle = existing ?? self.newFailedEnableBundle(sourceID: transition.sourceStoreID,
          source: source, digest: sourceDigest)
        if !verified && existing != nil { throw FailedEnableEvidenceError.reviewRequired }
        let index: Int
        if let found = bundle.namespaces.firstIndex(where: { $0.binding == FailedEnableBinding(namespace) }) {
          index = found
        } else {
          bundle.namespaces.append(FailedEnableNamespace(binding: FailedEnableBinding(namespace),
            captures: [], alternatives: [], reviews: []))
          index = bundle.namespaces.count - 1
        }
        bundle.namespaces[index].captures.append(capture)
        bundle.transfers.append(transfer)
        for (hash, data) in try self.failedEnableBlobs(images: images + plannedImages,
          bytes: source.snapshot.attachmentData.merging(prepared.plan.attachmentData) { a, _ in a }) {
          bundle.blobs[hash] = data
        }
        return bundle
      }
      return prepared
    }
    let source = try await libraryForTransition(storeID: transition.sourceStoreID)
      .transferSnapshot(revision: token.revision)
    let result = try await mergeFullReenableSnapshot(source, using: token, plan: prepared.plan)
    try await observeFailedEnableCommittedValues()
    return result
  }

  /// Both failed-send restore and retry-fetch call this before clearing upload evidence.
  func recoverFailedEnableEvidence() async throws {
    guard let transition = manifest.transition, transition.targetKind == .iCloudSync,
      transition.syncProtocol == .fullRecordV1
    else { return }
    if transition.phase == .candidateReady, !transition.awaitsAcceptedServerCapture,
      try failedEnableFiles.read(transition.sourceStoreID)?.namespaces.flatMap(\.captures)
        .contains(where: { $0.transitionID == FailedEnableEncoding.uuid(transition.id) }) != true {
      return
    }
    try await observeFailedEnableCommittedValues()
  }

  package func recordCheckedFailedEnableTurnOff() async throws {
    guard let policy = failedEnableSemantics, let transition = manifest.transition,
      transition.targetKind == .localOnly, transition.syncProtocol == .fullRecordV1,
      let sourceStore = store(id: transition.sourceStoreID), let namespace = sourceStore.namespace
    else { return }
    try await withFailedEnableRead(transition: transition) { source, candidate in
      guard let payload = try policy.checkedTurnOffPayload(source: source),
        payload == candidate.snapshot.opaqueSyncStatePayload
      else { return }
      let images = try candidate.images()
      let sourceID = transition.candidateStoreID
      let digest = try candidate.sourceDigest(sourceID: sourceID)
      let transfer = FailedEnableTransfer(kind: .turnOff, sourceCaptureIDs: [],
        sourceStoreID: FailedEnableEncoding.uuid(transition.sourceStoreID),
        destinationStoreID: FailedEnableEncoding.uuid(sourceID), namespace: FailedEnableBinding(namespace),
        planDigest: try FailedEnableEncoding.digest(images), dormantDigest: FailedEnableEncoding.digest(payload),
        outputs: images, conflicts: [], recoveryDescriptors: candidate.recoveryDescriptors, state: .checked)
      try self.failedEnableFiles.update(sourceID) { prior in
        if let prior {
          guard prior.transfers.contains(transfer), prior.continuity.sourceDigest == digest else {
            throw FailedEnableEvidenceError.changed
          }
          return prior
        }
        var bundle = self.newFailedEnableBundle(sourceID: sourceID, source: candidate, digest: digest)
        bundle.transfers = [transfer]
        bundle.blobs = try self.failedEnableBlobs(images: images, bytes: candidate.snapshot.attachmentData)
        return bundle
      }
    }
  }

  package func observeFailedEnableCommittedValues() async throws {
    guard let transition = manifest.transition, transition.targetKind == .iCloudSync,
      transition.syncProtocol == .fullRecordV1, let namespace = transition.namespace
    else { return }
    guard let policy = failedEnableSemantics,
      let prior = try failedEnableFiles.read(transition.sourceStoreID),
      let group = prior.namespaces.firstIndex(where: { $0.binding == FailedEnableBinding(namespace) }),
      prior.namespaces[group].captures.contains(where: {
        $0.transitionID == FailedEnableEncoding.uuid(transition.id)
      })
    else { throw FailedEnableEvidenceError.reviewRequired }
    try await withFailedEnableRead(transition: transition) { source, candidate in
      guard try self.failedEnableContinuityMatches(prior, source: source, sourceID: transition.sourceStoreID)
      else { throw FailedEnableEvidenceError.reviewRequired }
      var updated = prior
      for index in updated.namespaces[group].captures.indices {
        let capture = updated.namespaces[group].captures[index]
        guard capture.transitionID == FailedEnableEncoding.uuid(transition.id) else { continue }
        updated.namespaces[group].captures[index] = try policy.observe(capture: capture,
          candidate: candidate, candidateStoreID: transition.candidateStoreID, namespace: namespace)
      }
      // A committed candidate can own values/bytes not in the original source image.
      // Until the full review transfer is implemented, cleanup retains that candidate root too.
      guard updated != prior else { return }
      try self.failedEnableFiles.update(transition.sourceStoreID) { current in
        guard current == prior else { throw FailedEnableEvidenceError.changed }
        return updated
      }
    }
  }

  func requireFailedEnableCapture() throws -> FailedEnableCapture? {
    guard let transition = manifest.transition, transition.targetKind == .iCloudSync,
      transition.syncProtocol == .fullRecordV1
    else { return nil }
    guard failedEnableSemantics != nil, let token = transition.freezeToken,
      token.sourceStoreID == transition.sourceStoreID,
      !failedEnableUncertainSources.contains(transition.sourceStoreID),
      let bundle = try failedEnableFiles.read(transition.sourceStoreID),
      bundle.continuity.state == .verified, bundle.continuity.inFlight.value == nil,
      bundle.continuity.activationDigest == failedEnableActivationDigest(manifest),
      let group = bundle.namespaces.first(where: { $0.binding == transition.namespace.map(FailedEnableBinding.init) }),
      let capture = group.captures.last(where: {
        $0.transitionID == FailedEnableEncoding.uuid(transition.id)
          && $0.candidateStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
          && $0.freeze.id == FailedEnableEncoding.uuid(token.id)
          && $0.freeze.sourceRevision == String(token.revision)
      }),
      capture.normalizer == 1, capture.syncProtocol == .fullRecordV1,
      capture.records.allSatisfy({ $0.preparation.normalizer == 1 }),
      capture.records.allSatisfy({
        [.nonconflicting, .equalFetched, .realConflict].contains($0.preparation.classification)
      }),
      capture.candidateDeletes.isEmpty,
      bundle.transfers.contains(where: {
        $0.sourceCaptureIDs == [capture.id] && $0.state == .checked && $0.kind == .candidate
      })
    else { throw FailedEnableEvidenceError.reviewRequired }
    return capture
  }

  private func requireNoUncapturedFailedEnableRoots(_ transition: SyncModeTransition) throws {
    var represented: Set<String> = []
    for id in failedEnableSourceIDs() {
      guard let bundle = try failedEnableFiles.read(id) else { continue }
      for group in bundle.namespaces {
        for capture in group.captures { represented.insert(capture.candidateStoreID) }
      }
      for transfer in bundle.transfers {
        represented.insert(transfer.sourceStoreID)
        represented.insert(transfer.destinationStoreID)
      }
    }
    let unknown = manifest.stores.contains { store in
      store.id != transition.candidateStoreID && store.id != transition.sourceStoreID
        && store.kind == .iCloudSync && store.namespace == transition.namespace
        && [.deleting, .retired, .recovery].contains(store.lifecycle)
        && !represented.contains(FailedEnableEncoding.uuid(store.id))
    }
    guard !unknown else { throw FailedEnableEvidenceError.reviewRequired }
  }

  func armFailedEnableCapture() async throws {
    guard let capture = try requireFailedEnableCapture(),
      let transition = manifest.transition, let policy = failedEnableSemantics else { return }
    try await withFailedEnableRead(transition: transition) { source, candidate in
      let prior = try self.failedEnableFiles.read(transition.sourceStoreID)
      guard try self.failedEnableContinuityMatches(prior, source: source, sourceID: transition.sourceStoreID) else {
        throw FailedEnableEvidenceError.reviewRequired
      }
      try policy.validateExposure(capture: capture, candidate: candidate)
      guard !capture.armed else { return }
      try self.failedEnableFiles.update(transition.sourceStoreID) { current in
        guard var current, current == prior else { throw FailedEnableEvidenceError.changed }
        for group in current.namespaces.indices {
          if let index = current.namespaces[group].captures.firstIndex(where: { $0.id == capture.id }) {
            current.namespaces[group].captures[index].armed = true
            return current
          }
        }
        throw FailedEnableEvidenceError.changed
      }
    }
  }

  func requireFailedEnableSwapEvidence() throws {
    guard let capture = try requireFailedEnableCapture() else { return }
    guard capture.records.allSatisfy({ record in
      [.nonconflicting, .equalFetched].contains(record.preparation.classification)
        && record.observedAccepted.value != nil
    }) else { throw FailedEnableEvidenceError.reviewRequired }
  }

  func markFailedEnableApplied(transition: SyncModeTransition, planDigest: Data) throws {
    try failedEnableFiles.update(transition.sourceStoreID) { current in
      guard var current,
        let index = current.transfers.lastIndex(where: {
          $0.kind == .candidate && $0.destinationStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
            && $0.planDigest == FailedEnableEncoding.hex(planDigest)
        })
      else { throw FailedEnableEvidenceError.changed }
      current.transfers[index].state = .checked
      return current
    }
  }

  func requireFailedEnablePreparedPlan(_ plan: CloudFullReenableApplyPlan, token: SyncModeFreezeToken) throws {
    guard let transition = manifest.transition,
      let bundle = try failedEnableFiles.read(transition.sourceStoreID),
      let capture = bundle.namespaces.flatMap(\.captures).last(where: {
        $0.transitionID == FailedEnableEncoding.uuid(transition.id)
          && $0.freeze.id == FailedEnableEncoding.uuid(token.id)
          && $0.freeze.sourceRevision == String(token.revision)
      }),
      bundle.transfers.contains(where: {
        $0.kind == .candidate && $0.sourceCaptureIDs == [capture.id]
          && $0.destinationStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
          && $0.planDigest == FailedEnableEncoding.hex(plan.planDigest)
      })
    else { throw FailedEnableEvidenceError.reviewRequired }
  }

  func withFailedEnableRead<Value: Sendable>(
    transition: SyncModeTransition,
    _ read: (FailedEnableStoreRead, FailedEnableStoreRead) throws -> Value
  ) async throws -> Value {
    guard failedEnablePublicationInFlight == nil,
      writeAdmissionIsIdle(),
      manifest.transition == transition,
      let sourceStore = store(id: transition.sourceStoreID),
      let candidateStore = store(id: transition.candidateStoreID),
      let namespace = transition.namespace ?? sourceStore.namespace
    else { throw FailedEnableEvidenceError.changed }
    let source = try libraryForTransition(storeID: sourceStore.id)
    let candidate = try libraryForTransition(storeID: candidateStore.id)
    let urls = [(sourceStore.id, await source.lockURL), (candidateStore.id, await candidate.lockURL)]
    let preimage = manifest
    failedEnablePublicationInFlight = transition.id
    defer { failedEnablePublicationInFlight = nil }
    let locks = try FailedEnableReadLocks(stores: urls)
    defer { withExtendedLifetime(locks) {} }
    let local = try await source.failedEnableRead(revision: sourceStore.revision, namespace: namespace, locks: locks)
    let remote = try await candidate.failedEnableRead(revision: candidateStore.revision, namespace: namespace, locks: locks)
    guard manifest == preimage else { throw FailedEnableEvidenceError.changed }
    return try read(local, remote)
  }

  func failedEnableContinuityMatches(_ bundle: FailedEnableInstalledEvidence?,
    source: FailedEnableStoreRead, sourceID: UUID
  ) throws -> Bool {
    guard let bundle else { return !failedEnableUncertainSources.contains(sourceID) }
    return !failedEnableUncertainSources.contains(sourceID)
      && bundle.continuity.state == .verified && bundle.continuity.inFlight.value == nil
      && bundle.continuity.activationDigest == failedEnableActivationDigest(manifest)
      && bundle.continuity.sourceRevision == String(source.snapshot.revision)
      && bundle.continuity.sourceDigest == (try source.sourceDigest(sourceID: sourceID))
  }

  private func newFailedEnableBundle(sourceID: UUID, source: FailedEnableStoreRead,
    digest: String
  ) -> FailedEnableInstalledEvidence {
    FailedEnableInstalledEvidence(version: 1, purpose: .installedEvidence,
      sourceStoreID: FailedEnableEncoding.uuid(sourceID), sequence: "0",
      continuity: FailedEnableContinuity(state: .verified,
        activationDigest: failedEnableActivationDigest(manifest), sourceRevision: String(source.snapshot.revision),
        sourceDigest: digest, inFlight: .init(nil)), namespaces: [], transfers: [], blobs: [:])
  }

  private func failedEnableImages(_ plan: CloudFullReenableApplyPlan) throws -> [FailedEnableImage] {
    try (plan.snips.map { FailedEnableImage.snip(try FailedEnableSnipImage($0, attachmentData: plan.attachmentData)) }
      + plan.lists.map { FailedEnableImage.list(FailedEnableListImage($0)) })
      .sorted { $0.reference.sortKey < $1.reference.sortKey }
  }

  private func failedEnableBlobs(images: [FailedEnableImage], bytes: [UUID: Data]) throws -> [String: Data] {
    var blobs: [String: Data] = [:]
    for image in images {
      guard case .snip(let snip) = image else { continue }
      for attachment in snip.attachments {
        guard let data = bytes[try FailedEnableEncoding.uuid(attachment.id)],
          FailedEnableEncoding.digest(data) == attachment.availability.sha256
        else { throw FailedEnableEvidenceError.unavailable }
        blobs[attachment.availability.sha256] = data
      }
    }
    return blobs
  }

  /// Every manifest collection is a set. Canonicalize the existing v2 logical projection.
  func failedEnableActivationDigest(_ value: Manifest) -> String {
    func normalized(_ value: Any) -> Any {
      if let map = value as? [String: Any] { return map.mapValues(normalized) }
      if let array = value as? [Any] {
        return array.map(normalized).sorted {
          let a = (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
          let b = (try? JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
          return a.lexicographicallyPrecedes(b)
        }
      }
      return value
    }
    guard let bytes = try? FailedEnableEncoding.json(value),
      let object = try? JSONSerialization.jsonObject(with: bytes),
      let canonical = try? JSONSerialization.data(withJSONObject: normalized(object), options: [.sortedKeys])
    else { return "unavailable" }
    return FailedEnableEncoding.digest(canonical)
  }
}
