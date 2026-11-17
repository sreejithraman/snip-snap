import Foundation
import SnipSnapCore

struct FailedEnablePreparedRead: Sendable {
  let sourceStoreID: UUID
  let candidateStoreID: UUID
  let transitionID: UUID
  let capture: FailedEnableCapture
  let transfer: FailedEnableTransfer

  fileprivate init(sourceStoreID: UUID, candidateStoreID: UUID, transitionID: UUID,
    capture: FailedEnableCapture, transfer: FailedEnableTransfer
  ) {
    self.sourceStoreID = sourceStoreID
    self.candidateStoreID = candidateStoreID
    self.transitionID = transitionID
    self.capture = capture
    self.transfer = transfer
  }

  var requiresTurnOffAbsence: Bool {
    capture.records.contains(where: {
      $0.preparation.classification == .deleteRecovery && $0.preparation.baseKind == .checkedTurnOff
        && $0.offlineChanged.isEmpty && $0.preparation.value.value?.fields == .absent
        && $0.observedAccepted.value == nil && $0.unqualifiedObservation.value == nil
    })
  }

  func current(in evidence: FailedEnableInstalledEvidence?) throws -> FailedEnableTransfer {
    guard let evidence, evidence.continuity.state == .verified,
      evidence.sourceStoreID == FailedEnableEncoding.uuid(sourceStoreID),
      let group = evidence.namespaces.first(where: { $0.binding == transfer.namespace }),
      let currentCapture = group.captures.last(where: {
        $0.transitionID == FailedEnableEncoding.uuid(transitionID)
          && $0.candidateStoreID == FailedEnableEncoding.uuid(candidateStoreID)
      }), currentCapture.id == capture.id,
      matchesCapture(currentCapture),
      !capture.armed || currentCapture.armed,
      let currentTransfer = evidence.transfers.last(where: {
        $0.kind == .candidate && $0.sourceCaptureIDs == [capture.id]
          && $0.destinationStoreID == FailedEnableEncoding.uuid(candidateStoreID)
      }),
      transfer.state != .checked || currentTransfer.state == .checked
    else { throw FailedEnableEvidenceError.changed }
    guard currentTransfer.kind == transfer.kind,
      currentTransfer.sourceCaptureIDs == transfer.sourceCaptureIDs,
      currentTransfer.sourceStoreID == transfer.sourceStoreID,
      currentTransfer.destinationStoreID == transfer.destinationStoreID,
      currentTransfer.namespace == transfer.namespace,
      currentTransfer.planDigest == transfer.planDigest,
      currentTransfer.dormantDigest == transfer.dormantDigest,
      currentTransfer.outputs == transfer.outputs,
      currentTransfer.conflicts == transfer.conflicts,
      currentTransfer.recoveryDescriptors == transfer.recoveryDescriptors
    else { throw FailedEnableEvidenceError.changed }
    return currentTransfer
  }

  func current(at root: URL) throws -> FailedEnableTransfer {
    do {
      return try current(in: FailedEnableEvidenceFile(root: root).read(sourceStoreID))
    } catch {
      throw FailedEnableEvidenceError.changed
    }
  }

  private func matchesCapture(_ current: FailedEnableCapture) -> Bool {
    guard current.id == capture.id, current.ordinal == capture.ordinal,
      current.transitionID == capture.transitionID, current.candidateStoreID == capture.candidateStoreID,
      current.syncProtocol == capture.syncProtocol, current.freeze == capture.freeze,
      current.seenRequestIDs == capture.seenRequestIDs, current.sourceDigest == capture.sourceDigest,
      current.normalizer == capture.normalizer, current.preparationDigest == capture.preparationDigest,
      current.predecessors == capture.predecessors, current.candidateDeletes == capture.candidateDeletes,
      current.records.count == capture.records.count else { return false }
    return zip(current.records, capture.records).allSatisfy { current, frozen in
      current.reference == frozen.reference && current.identity == frozen.identity
        && current.sourceMembership == frozen.sourceMembership && current.source == frozen.source
        && current.originalAcceptedExists == frozen.originalAcceptedExists
        && current.offlineChanged == frozen.offlineChanged && current.preparation == frozen.preparation
    }
  }
}

extension SwiftDataSyncModePersistence {
  var failedEnableFiles: FailedEnableEvidenceFile { FailedEnableEvidenceFile(root: rootURL) }

  package func installFailedEnableSemantics(_ semantics: any FailedEnableSemantics,
    accountCheck: (@Sendable () async -> Bool)? = nil
  ) async {
    await installFailedEnableSemantics(semantics, preservingInFlightMerge: false,
      accountCheck: accountCheck)
  }

  package func installFailedEnableSemantics(_ semantics: any FailedEnableSemantics,
    preservingInFlightMerge: Bool,
    accountCheck: (@Sendable () async -> Bool)? = nil
  ) async {
    if preservingInFlightMerge, let inFlight = fullReenableMergeInFlight,
      manifest.transition?.id == inFlight { return }
    failedEnableSemantics = semantics
    failedEnableAccountCheck = accountCheck
    failedEnableSemanticRegistration = UUID()
    await reconcileFailedEnableOnOpen()
  }

  /// Reads, certifies and publishes through the durable owner before exposing the apply plan.
  package func prepareFailedEnableMerge(using token: SyncModeFreezeToken) async throws -> SnipLibraryTransferResult {
    guard let policy = failedEnableSemantics,
      let transition = manifest.transition, transition.awaitsMerge(using: token),
      transition.syncProtocol == .fullRecordV1, let namespace = transition.namespace
    else { throw FailedEnableEvidenceError.reviewRequired }
    try requireNoUncapturedFailedEnableRoots(transition)
    let prepared: FailedEnablePreparedMerge? = try await withFailedEnableDispositionRead(transition: transition) {
      source, candidate, retained in
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
      func retainedWithCurrentFrame(_ current: FailedEnableInstalledEvidence?) -> FailedEnableRetainedTurnOffRead? {
        guard let retained else { return nil }
        var frames = retained.frames.filter {
          $0.sourceStoreID != FailedEnableEncoding.uuid(transition.sourceStoreID)
        }
        if let current { frames.append(current) }
        return FailedEnableRetainedTurnOffRead(store: retained.store, source: retained.source,
          frames: frames.sorted { $0.sourceStoreID < $1.sourceStoreID })
      }
      var input = FailedEnablePreparationRead(source: source, candidate: candidate,
        transition: transition, token: token, evidence: prior, continuityVerified: verified, retainedTurnOff: retainedWithCurrentFrame(prior))
      let reviews = try policy.reviewDrafts(input.reviewRead)
      if !reviews.isEmpty {
        var applicable = true
        for row in reviews {
          guard let decision = row.decision.value,
            let selection = FailedEnableSetupSelection(rawValue: decision.choice.rawValue),
            try policy.choices(for: row).contains(selection) else { applicable = false; continue }
        }
        let alternatives = prior?.namespaces.first {
          $0.binding == FailedEnableBinding(namespace)
        }?.alternatives ?? []
        let blocked = !applicable || !alternatives.isEmpty
        let records: [FailedEnableRecord]?
        if blocked { records = try policy.reviewCaptureRecords(input, reviews: reviews) }
        else { records = nil }
        try self.publishFailedEnableReviews(reviews, input: input, captureRecords: records)
        prior = try self.failedEnableFiles.read(transition.sourceStoreID)
        if blocked { return nil }
        input = FailedEnablePreparationRead(source: source, candidate: candidate,
          transition: transition, token: token, evidence: prior, continuityVerified: verified, retainedTurnOff: retainedWithCurrentFrame(prior))
      }
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
    guard let prepared else {
      try unfreezeBeforePointerSwap(reason: .enrollmentBlocked)
      throw FailedEnableEvidenceError.reviewRequired
    }
    let source = try await libraryForTransition(storeID: transition.sourceStoreID)
      .transferSnapshot(revision: token.revision)
    let result = try await mergeFullReenableSnapshot(source, using: token, plan: prepared.plan)
    try await observeFailedEnableCommittedValues()
    return result
  }

  /// Both failed-send restore and retry-fetch call this before clearing upload evidence.
  @discardableResult
  func recoverFailedEnableEvidence() async throws -> FailedEnablePreparedRead? {
    guard let transition = manifest.transition, transition.targetKind == .iCloudSync,
      transition.syncProtocol == .fullRecordV1, let namespace = transition.namespace
    else { return nil }
    let before = manifest
    let candidate = try libraryForTransition(storeID: transition.candidateStoreID)
    // A fresh candidate can still contain remote-only attachment metadata. Reading receipt
    // metadata here must not bypass the existing preservation/download owner.
    let receipts = try await candidate.failedEnableReenableReceipts(
      namespaceKey: namespace.namespaceKey.rawValue, transitionID: transition.id)
    guard manifest == before else { throw FailedEnableEvidenceError.changed }
    guard let preparation = try failedEnablePreparedRead(transition: transition) else {
      guard transition.phase == .candidateReady, !transition.awaitsAcceptedServerCapture,
        receipts.modern == nil, receipts.ambiguous == nil,
        try !hasStagedFullReenableEvidence(transition)
      else { throw FailedEnableEvidenceError.changed }
      // Acquisition only: this does not authorize apply, progress or receipt retirement.
      return nil
    }
    try await recoverFailedEnableTurnOffApply(preparation: preparation)
    guard manifest == before else { throw FailedEnableEvidenceError.changed }
    try await observeFailedEnableCommittedValues()
    _ = try preparation.current(at: rootURL)
    return preparation
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
        let reviewed = hasFailedEnableReviewDecision($0, capture: capture, bundle: bundle)
        return ([.nonconflicting, .equalFetched, .realConflict].contains($0.preparation.classification)
          && ($0.preparation.baseKind != .unverified || reviewed))
          || ($0.preparation.classification == .deleteRecovery && (reviewed
            || $0.preparation.baseKind == .checkedTurnOff))
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

  /// All first-send/send/swap publication is synchronous inside this owner operation.
  func withFailedEnableExposure<Value: Sendable>(
    requiresAccepted: Bool, attempt: SyncModeSendAttempt? = nil, arm: Bool = false,
    _ publish: (Set<FailedEnableReference>) throws -> Value
  ) async throws -> Value {
    guard let capture = try requireFailedEnableCapture(),
      let transition = manifest.transition, let policy = failedEnableSemantics else {
      return try publish([])
    }
    return try await withFailedEnableDispositionRead(transition: transition) { source, candidate, retained in
      let prior = try self.failedEnableFiles.read(transition.sourceStoreID)
      guard let prior,
        try self.failedEnableContinuityMatches(prior, source: source, sourceID: transition.sourceStoreID)
      else { throw FailedEnableEvidenceError.reviewRequired }
      let input = FailedEnableReviewRead(source: source, candidate: candidate,
        transition: transition, evidence: prior, retainedTurnOff: retained)
      let absent = try policy.validateTurnOffOutput(input, capture: capture, applied: true)
      let conflicts = try policy.validateExposure(input, capture: capture, requiresAccepted: requiresAccepted)
      if !conflicts.isEmpty {
        guard !transition.awaitsAcceptedServerCapture, self.failedEnableSendInFlight == nil else {
          throw FailedEnableEvidenceError.reviewRequired
        }
      }
      guard try self.requireFailedEnableCapture() == capture else { throw FailedEnableEvidenceError.changed }
      if let attempt {
        var preflight = self.manifest
        try preflight.updateTransition(orThrow: .namespaceMismatch) { try $0.recordSendAttempt(attempt) }
        let excluded = capture.records.filter { absent.contains($0.reference) }
        guard !attempt.operations.contains(where: { operation in
          excluded.contains(where: { record in
            operation.reference == (try? record.reference.domain)
              || operation.recordIdentity == record.identity.domain
          })
        }) else { throw FailedEnableEvidenceError.reviewRequired }
      }
      if arm && !capture.armed {
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
      self.failedEnablePublicationInFlight = nil
      defer { self.failedEnablePublicationInFlight = transition.id }
      return try publish(absent.union(conflicts))
    }
  }

  func requireFailedEnableSwapEvidence(checkedDispositions: Set<FailedEnableReference>) throws {
    guard let capture = try requireFailedEnableCapture() else { return }
    guard let transition = manifest.transition,
      let bundle = try failedEnableFiles.read(transition.sourceStoreID),
      capture.records.allSatisfy({ record in
      ([.nonconflicting, .equalFetched].contains(record.preparation.classification)
        && record.observedAccepted.value != nil)
        || hasFailedEnableReviewDecision(record, capture: capture, bundle: bundle)
        || checkedDispositions.contains(record.reference)
    }) else { throw FailedEnableEvidenceError.reviewRequired }
  }

  func markFailedEnableApplied(transition: SyncModeTransition, planDigest: Data,
    preparation: FailedEnablePreparedRead, expected: FailedEnableInstalledEvidence? = nil
  ) throws {
    try failedEnableFiles.update(transition.sourceStoreID) { current in
      _ = try preparation.current(in: current)
      guard var current, expected == nil || current == expected,
        let index = current.transfers.lastIndex(where: {
          $0.kind == .candidate && $0.sourceCaptureIDs == [preparation.capture.id]
            && $0.sourceStoreID == FailedEnableEncoding.uuid(transition.sourceStoreID)
            && $0.destinationStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
            && $0.namespace == preparation.transfer.namespace
            && $0.planDigest == FailedEnableEncoding.hex(planDigest)
        })
      else { throw FailedEnableEvidenceError.changed }
      current.transfers[index].state = .checked
      return current
    }
  }

  func failedEnablePreparedRead(transition: SyncModeTransition,
    digest: Data? = nil, token: SyncModeFreezeToken? = nil
  ) throws -> FailedEnablePreparedRead? {
    guard transition.syncProtocol == .fullRecordV1,
      !failedEnableUncertainSources.contains(transition.sourceStoreID),
      let namespace = transition.namespace else {
      throw FailedEnableEvidenceError.changed
    }
    guard let evidence = try failedEnableFiles.read(transition.sourceStoreID) else { return nil }
    let captures = evidence.namespaces.first(where: {
      $0.binding == FailedEnableBinding(namespace)
    })?.captures.filter {
      $0.transitionID == FailedEnableEncoding.uuid(transition.id)
        && $0.candidateStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
    } ?? []
    guard let capture = captures.last else {
      guard !evidence.namespaces.flatMap(\.captures).contains(where: {
        $0.transitionID == FailedEnableEncoding.uuid(transition.id)
          && $0.candidateStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
      }), !evidence.transfers.contains(where: {
        $0.kind == .candidate
          && $0.destinationStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
      }) else { throw FailedEnableEvidenceError.changed }
      return nil
    }
    guard capture.syncProtocol == .fullRecordV1,
      token == nil || (capture.freeze.id == token.map { FailedEnableEncoding.uuid($0.id) }
        && capture.freeze.sourceRevision == token.map { String($0.revision) })
    else { throw FailedEnableEvidenceError.changed }
    guard let transfer = evidence.transfers.last(where: {
      $0.kind == .candidate && $0.sourceCaptureIDs == [capture.id]
        && $0.sourceStoreID == FailedEnableEncoding.uuid(transition.sourceStoreID)
        && $0.destinationStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
        && $0.namespace == FailedEnableBinding(namespace)
    }) else {
      // Review publication can capture L before a plan exists. Only discovery may return
      // nil; the caller must independently exclude an actual intent, staged plan and receipt.
      guard digest == nil, token == nil, !evidence.transfers.contains(where: {
        $0.kind == .candidate
          && $0.destinationStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
      }) else { throw FailedEnableEvidenceError.changed }
      return nil
    }
    guard digest == nil || transfer.planDigest == digest.map(FailedEnableEncoding.hex)
    else { throw FailedEnableEvidenceError.changed }
    let preparation = FailedEnablePreparedRead(sourceStoreID: transition.sourceStoreID,
      candidateStoreID: transition.candidateStoreID, transitionID: transition.id,
      capture: capture, transfer: transfer)
    _ = try preparation.current(in: evidence)
    return preparation
  }

  func requireFailedEnablePreparedPlan(_ plan: CloudFullReenableApplyPlan,
    token: SyncModeFreezeToken
  ) throws -> FailedEnablePreparedRead {
    guard let transition = manifest.transition,
      let preparation = try failedEnablePreparedRead(transition: transition,
        digest: plan.planDigest, token: token)
    else { throw FailedEnableEvidenceError.reviewRequired }
    return preparation
  }


  func failedEnableHasTurnOffOutput(_ transition: SyncModeTransition) throws -> Bool {
    guard let capture = try failedEnableFiles.read(transition.sourceStoreID)?.namespaces.flatMap(\.captures)
      .last(where: { $0.transitionID == FailedEnableEncoding.uuid(transition.id)
        && $0.candidateStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID) })
    else { return false }
    return capture.records.contains(where: {
      $0.preparation.classification == .deleteRecovery && $0.preparation.baseKind == .checkedTurnOff
        && $0.offlineChanged.isEmpty && $0.preparation.value.value?.fields == .absent
        && $0.observedAccepted.value == nil && $0.unqualifiedObservation.value == nil
    })
  }

  /// Called only from the explicit setup driver; the hint acquires inventory, never eligibility.
  package func failedEnableNeedsInitialInventory() async throws -> Bool {
    guard let transition = manifest.transition, transition.targetKind == .iCloudSync,
      transition.syncProtocol == .fullRecordV1, transition.phase != .pointerSwapped,
      let policy = failedEnableSemantics else { return false }
    return try await withFailedEnableRead(transition: transition) { source, candidate in
      try policy.needsTurnOffInventory(FailedEnableReviewRead(source: source, candidate: candidate,
        transition: transition, evidence: self.failedEnableFiles.read(transition.sourceStoreID)))
    }
  }

  package func retryFailedEnableTurnOffFetch(settlement: SyncModeSeedSettlementProof? = nil) async throws {
    let before = manifest
    guard try await failedEnableNeedsInitialInventory(), manifest == before,
      let transition = manifest.transition,
      [.remoteFetched, .recordsMerged, .enrollmentApproved, .firstSendStarted, .firstSendComplete]
        .contains(transition.phase)
    else { return }
    try await recoverFailedEnableEvidence()
    guard manifest == before else { throw FailedEnableEvidenceError.changed }
    if [.enrollmentApproved, .firstSendStarted, .firstSendComplete].contains(transition.phase) {
      guard let settlement, settlement.namespace == transition.namespace else {
        throw SyncModePersistenceError.namespaceMismatch
      }
      try await restartAfterFirstSendFailure(reason: before.attentionReason, settlement: settlement)
    } else {
      if transition.freezesSource { try unfreezeBeforePointerSwap(reason: before.attentionReason) }
      try retryRemoteFetch()
    }
  }

  /// Returns false only for this new disposition's unavailable proof. Old storage/CAS errors escape.
  func validateFailedEnableTurnOffApply(transition: SyncModeTransition,
    preparation: FailedEnablePreparedRead, digest: Data, applied: Bool, expectedManifest: Manifest,
    expectedRegistration: UUID, publish: () throws -> Void = {}
  ) async throws -> Bool {
    guard manifest == expectedManifest, expectedManifest.transition == transition,
      expectedManifest.activeStoreID == transition.sourceStoreID,
      let intent = transition.mergeIntent, intent.fullReenablePlanID == transition.id,
      intent.planDigest == digest, let token = transition.freezeToken,
      token.sourceStoreID == transition.sourceStoreID, token.revision == intent.sourceRevision,
      expectedManifest.stores.first(where: { $0.id == transition.sourceStoreID })?.revision == token.revision,
      let policy = failedEnableSemantics,
      failedEnableSemanticRegistration == expectedRegistration,
      preparation.transitionID == transition.id,
      preparation.sourceStoreID == transition.sourceStoreID,
      preparation.candidateStoreID == transition.candidateStoreID,
      preparation.transfer.planDigest == FailedEnableEncoding.hex(digest),
      !failedEnableUncertainSources.contains(transition.sourceStoreID)
    else { return false }
    do {
      _ = try preparation.current(at: rootURL)
      if !preparation.requiresTurnOffAbsence {
        try publish()
        return true
      }
      return try await withFailedEnableDispositionRead(transition: transition) { source, candidate, retained in
        guard self.manifest == expectedManifest,
          self.failedEnableSemanticRegistration == expectedRegistration,
          let evidence = try self.failedEnableFiles.read(transition.sourceStoreID),
          try self.failedEnableContinuityMatches(evidence, source: source, sourceID: transition.sourceStoreID),
          let capture = evidence.namespaces.flatMap(\.captures).last(where: {
            $0.transitionID == FailedEnableEncoding.uuid(transition.id)
              && $0.candidateStoreID == FailedEnableEncoding.uuid(transition.candidateStoreID)
              && $0.freeze.id == FailedEnableEncoding.uuid(token.id)
              && $0.freeze.sourceRevision == String(token.revision)
          }),
          evidence.transfers.contains(where: { $0.kind == .candidate
            && $0.sourceCaptureIDs == [capture.id]
            && $0.planDigest == FailedEnableEncoding.hex(digest) })
        else { return false }
        _ = try preparation.current(in: evidence)
        let input = FailedEnableReviewRead(source: source, candidate: candidate,
          transition: transition, evidence: evidence, retainedTurnOff: retained)
        _ = try policy.validateTurnOffOutput(input, capture: capture, applied: applied)
        self.failedEnablePublicationInFlight = nil
        defer { self.failedEnablePublicationInFlight = transition.id }
        try publish()
        return true
      }
    } catch is FailedEnableEvidenceError {
      return false
    }
  }

  /// Before receipt retirement or intent rollback, retain truthful checked private output.
  /// It deliberately does not call the account callback or certify current remote absence.
  func recoverFailedEnableTurnOffApply(preparation: FailedEnablePreparedRead) async throws {
    guard let transition = manifest.transition,
      transition.id == preparation.transitionID, let policy = failedEnableSemantics else {
      throw FailedEnableEvidenceError.changed
    }
    let current = try preparation.current(at: rootURL)
    if current.state == .checked, !preparation.requiresTurnOffAbsence { return }
    try await withFailedEnableRead(transition: transition) { source, candidate in
      let evidence = try self.failedEnableFiles.read(transition.sourceStoreID)
      _ = try preparation.current(in: evidence)
      guard let receipt = candidate.reenableReceiptDigest else { return }
      guard FailedEnableEncoding.hex(receipt) == preparation.transfer.planDigest else {
        throw CloudFullStorageError.invalidBatchReplay
      }
      // This proves only the past private apply and exact outputs, never current absence.
      try policy.validatePastTurnOffApply(FailedEnableReviewRead(source: source, candidate: candidate,
        transition: transition, evidence: evidence), capture: preparation.capture)
      if current.state == .prepared {
        try self.markFailedEnableApplied(transition: transition, planDigest: receipt,
          preparation: preparation, expected: evidence)
      }
    }
  }

  func withFailedEnablePreparedReceipt<Value: Sendable>(
    _ preparation: FailedEnablePreparedRead,
    _ operation: (SwiftDataSnipLibrary, URL) async throws -> Value
  ) async throws -> Value {
    let before = manifest
    let registration = failedEnableSemanticRegistration
    guard before.transition?.id == preparation.transitionID,
      before.transition?.sourceStoreID == preparation.sourceStoreID,
      before.transition?.candidateStoreID == preparation.candidateStoreID,
      !failedEnableUncertainSources.contains(preparation.sourceStoreID),
      writeAdmissionIsIdle(), failedEnablePublicationInFlight == nil else {
      throw FailedEnableEvidenceError.changed
    }
    _ = try preparation.current(at: rootURL)
    let candidate = try libraryForTransition(storeID: preparation.candidateStoreID)
    failedEnablePublicationInFlight = preparation.transitionID
    defer { failedEnablePublicationInFlight = nil }
    let result = try await operation(candidate, rootURL)
    guard manifest == before, failedEnableSemanticRegistration == registration else {
      throw FailedEnableEvidenceError.changed
    }
    _ = try preparation.current(at: rootURL)
    return result
  }

  /// Two-root discovery never returns a disposition. The destructive path is re-read under
  /// all three UUID-ordered locks, with the exact manifest, registration, T0 and frames bound.
  func withFailedEnableDispositionRead<Value: Sendable>(
    transition: SyncModeTransition,
    _ read: (FailedEnableStoreRead, FailedEnableStoreRead, FailedEnableRetainedTurnOffRead?) throws -> Value
  ) async throws -> Value {
    guard let policy = failedEnableSemantics else { throw FailedEnableEvidenceError.reviewRequired }
    let registration = failedEnableSemanticRegistration
    let preimage = manifest
    let discovery: (needsRetainedRoot: Bool, value: Value?) =
      try await withFailedEnableRead(transition: transition) { source, candidate in
        guard self.manifest == preimage, self.failedEnableSemanticRegistration == registration else {
          throw FailedEnableEvidenceError.changed
        }
        let frame = try self.failedEnableFiles.read(transition.sourceStoreID)
        let input = FailedEnableReviewRead(source: source, candidate: candidate,
          transition: transition, evidence: frame)
        let candidates = try policy.turnOffAbsenceCandidates(input)
        let tagged = try self.failedEnableHasTurnOffOutput(transition)
        if !candidates.isEmpty || tagged { return (true, nil) }
        return (false, .some(try read(source, candidate, nil)))
      }
    if !discovery.needsRetainedRoot {
      guard let value = discovery.value else { throw FailedEnableEvidenceError.changed }
      return value
    }
    guard manifest == preimage, failedEnableSemanticRegistration == registration else {
      throw FailedEnableEvidenceError.changed
    }
    guard let accountCheck = failedEnableAccountCheck, await accountCheck(),
      manifest == preimage, failedEnableSemanticRegistration == registration,
      policy.reviewNamespace == transition.namespace,
      let namespace = transition.namespace,
      let sourceStore = store(id: transition.sourceStoreID),
      let candidateStore = store(id: transition.candidateStoreID),
      let frame = try failedEnableFiles.read(transition.sourceStoreID)
    else { throw FailedEnableEvidenceError.reviewRequired }
    let turnOffs = frame.transfers.filter {
      $0.kind == .turnOff && $0.state == .checked
        && $0.destinationStoreID == FailedEnableEncoding.uuid(sourceStore.id)
        && $0.namespace == FailedEnableBinding(namespace)
        && $0.dormantDigest.count == 64
    }
    guard turnOffs.count == 1, let turnOff = turnOffs.first,
      let root = store(id: try FailedEnableEncoding.uuid(turnOff.sourceStoreID)),
      root.kind == .iCloudSync, root.syncProtocol == .fullRecordV1, root.namespace == namespace,
      root.id != sourceStore.id, root.id != candidateStore.id,
      [.retired, .deleting, .recovery].contains(root.lifecycle)
    else { throw FailedEnableEvidenceError.reviewRequired }
    try requireNoUncapturedFailedEnableRoots(transition)
    let source = try libraryForTransition(storeID: sourceStore.id)
    let candidate = try libraryForTransition(storeID: candidateStore.id)
    let urls = [(sourceStore.id, await source.lockURL),
      (candidateStore.id, await candidate.lockURL),
      (root.id, storeFileURL(root).appendingPathExtension("lock"))]
    guard Set(urls.map { $0.1.standardizedFileURL.path }).count == 3,
      manifest == preimage, failedEnableSemanticRegistration == registration,
      failedEnablePublicationInFlight == nil, writeAdmissionIsIdle() else {
      throw FailedEnableEvidenceError.changed
    }
    failedEnablePublicationInFlight = transition.id
    defer { failedEnablePublicationInFlight = nil }
    let locks = try FailedEnableReadLocks(stores: urls)
    defer { withExtendedLifetime(locks) {} }
    let frameIDs = failedEnableSourceIDs()
    let frames = try frameIDs.compactMap { try failedEnableFiles.read($0) }
    let local = try await source.failedEnableRead(revision: sourceStore.revision,
      namespace: namespace, locks: locks)
    guard manifest == preimage, failedEnableSemanticRegistration == registration else {
      throw FailedEnableEvidenceError.changed
    }
    let remote = try await candidate.failedEnableRead(revision: candidateStore.revision,
      namespace: namespace, locks: locks, reenableTransitionID: transition.id)
    guard manifest == preimage, failedEnableSemanticRegistration == registration else {
      throw FailedEnableEvidenceError.changed
    }
    let retained: FailedEnableStoreRead
    do {
      retained = try SwiftDataSnipLibrary.retainedFailedEnableRead(storeURL: storeFileURL(root),
        revision: root.revision, namespace: namespace, locks: locks)
    } catch {
      throw FailedEnableEvidenceError.unavailable
    }
    guard await accountCheck(), manifest == preimage,
      failedEnableSemanticRegistration == registration,
      failedEnablePublicationInFlight == transition.id,
      writeAdmission.isIdle, manifest.writeReservation == nil,
      failedEnableSourceIDs() == frameIDs,
      try frameIDs.compactMap({ try self.failedEnableFiles.read($0) }) == frames,
      try self.failedEnableContinuityMatches(frame, source: local, sourceID: sourceStore.id),
      try self.failedEnableFiles.read(sourceStore.id) == frame
    else { throw FailedEnableEvidenceError.reviewRequired }
    for (_, url) in urls { try locks.require(url) }
    return try read(local, remote, FailedEnableRetainedTurnOffRead(store: root, source: retained, frames: frames))
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
    let preimage = manifest
    let source = try libraryForTransition(storeID: sourceStore.id)
    let candidate = try libraryForTransition(storeID: candidateStore.id)
    let urls = [(sourceStore.id, await source.lockURL), (candidateStore.id, await candidate.lockURL)]
    guard failedEnablePublicationInFlight == nil, writeAdmissionIsIdle(),
      manifest == preimage else { throw FailedEnableEvidenceError.changed }
    failedEnablePublicationInFlight = transition.id
    defer { failedEnablePublicationInFlight = nil }
    let locks = try FailedEnableReadLocks(stores: urls)
    defer { withExtendedLifetime(locks) {} }
    let local = try await source.failedEnableRead(revision: sourceStore.revision, namespace: namespace, locks: locks)
    let remote = try await candidate.failedEnableRead(revision: candidateStore.revision,
      namespace: namespace, locks: locks, reenableTransitionID: transition.id)
    guard manifest == preimage else { throw FailedEnableEvidenceError.changed }
    return try read(local, remote)
  }

  func failedEnableContinuityMatches(_ bundle: FailedEnableInstalledEvidence?,
    source: FailedEnableStoreRead, sourceID: UUID
  ) throws -> Bool {
    guard let bundle else { return !failedEnableUncertainSources.contains(sourceID) }
    guard !failedEnableUncertainSources.contains(sourceID),
      bundle.continuity.state == .verified, bundle.continuity.inFlight.value == nil,
      bundle.continuity.activationDigest == failedEnableActivationDigest(manifest),
      bundle.continuity.sourceRevision == String(source.snapshot.revision)
    else { return false }
    let digest = try source.sourceDigest(sourceID: sourceID)
    return bundle.continuity.sourceDigest == digest
  }

  func newFailedEnableBundle(sourceID: UUID, source: FailedEnableStoreRead,
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

  func failedEnableBlobs(images: [FailedEnableImage], bytes: [UUID: Data]) throws -> [String: Data] {
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
