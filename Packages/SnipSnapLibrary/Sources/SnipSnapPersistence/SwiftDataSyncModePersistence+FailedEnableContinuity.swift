import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  func failedEnableSourceIDs() -> [UUID] {
    guard let urls = try? FileManager.default.contentsOfDirectory(at: failedEnableFiles.directory,
      includingPropertiesForKeys: nil) else { return [] }
    return urls.compactMap { url in
      guard url.pathExtension == "bundle" else { return nil }
      let stem = url.deletingPathExtension().lastPathComponent
      guard let id = UUID(uuidString: stem), FailedEnableEncoding.uuid(id) == stem else { return nil }
      return id
    }.sorted { $0.uuidString < $1.uuidString }
  }

  /// Checkpoint failure cannot make local content unavailable. A later setup rereads it.
  func beginFailedEnableManifestWrite(_ next: Manifest) {
    guard failedEnableReopenManifest == nil else { return }
    let beforeDigest = failedEnableActivationDigest(manifest)
    let afterDigest = failedEnableActivationDigest(next)
    guard beforeDigest != afterDigest else { return }
    for id in failedEnableSourceIDs() {
      do {
        guard let before = try failedEnableFiles.read(id),
          before.continuity.inFlight.value?.kind != .source else { continue }
        try failedEnableFiles.update(id) { current in
          guard var current else { throw FailedEnableEvidenceError.unavailable }
          if current.continuity.inFlight.value?.kind == .source { return current }
          guard current.continuity.activationDigest == beforeDigest else {
            current.continuity.state = .uncertain
            return current
          }
          current.continuity.inFlight = .init(FailedEnableWriterTicket(kind: .manifest,
            ownerNonce: FailedEnableEncoding.uuid(failedEnableOwnerNonce),
            previousActivationDigest: beforeDigest,
            previousSourceRevision: current.continuity.sourceRevision,
            previousSourceDigest: current.continuity.sourceDigest,
            reservedRevision: .init(nil), manifestPostimageDigest: .init(afterDigest)))
          return current
        }
      } catch { failedEnableUncertainSources.insert(id) }
    }
  }

  func completeFailedEnableManifestWrite() {
    guard failedEnableReopenManifest == nil else { return }
    let digest = failedEnableActivationDigest(manifest)
    for id in failedEnableSourceIDs() {
      do {
        guard !failedEnableUncertainSources.contains(id) else { continue }
        guard let before = try failedEnableFiles.read(id),
          before.continuity.inFlight.value?.kind == .manifest else { continue }
        try failedEnableFiles.update(id) { current in
          guard var current else { throw FailedEnableEvidenceError.unavailable }
          guard let ticket = current.continuity.inFlight.value, ticket.kind == .manifest else { return current }
          guard ticket.manifestPostimageDigest.value == digest else {
            current.continuity.state = .uncertain
            return current
          }
          current.continuity.activationDigest = digest
          current.continuity.inFlight = .init(nil)
          return current
        }
      } catch { failedEnableUncertainSources.insert(id) }
    }
  }

  func beginFailedEnableSourceWrite(storeID: UUID, reservedRevision: UInt64) {
    guard FileManager.default.fileExists(atPath: failedEnableFiles.url(storeID).path) else { return }
    do {
      try failedEnableFiles.update(storeID) { current in
        guard var current else { throw FailedEnableEvidenceError.unavailable }
        guard current.continuity.inFlight.value == nil,
          current.continuity.activationDigest == failedEnableActivationDigest(manifest)
        else {
          current.continuity.state = .uncertain
          return current
        }
        current.continuity.inFlight = .init(FailedEnableWriterTicket(kind: .source,
          ownerNonce: FailedEnableEncoding.uuid(failedEnableOwnerNonce),
          previousActivationDigest: current.continuity.activationDigest,
          previousSourceRevision: current.continuity.sourceRevision,
          previousSourceDigest: current.continuity.sourceDigest,
          reservedRevision: .init(String(reservedRevision)), manifestPostimageDigest: .init(nil)))
        return current
      }
    } catch { failedEnableUncertainSources.insert(storeID) }
  }

  func checkFailedEnableSourceBeforeWrite() async {
    guard writeAdmissionIsIdle() else { return }
    let id = manifest.activeStoreID
    guard FileManager.default.fileExists(atPath: failedEnableFiles.url(id).path) else { return }
    do {
      guard let prior = try failedEnableFiles.read(id), let store = store(id: id),
        let binding = prior.namespaces.first?.binding ?? prior.transfers.first?.namespace
      else { throw FailedEnableEvidenceError.unavailable }
      let namespace = try binding.domain
      let library = try libraryForTransition(storeID: id)
      guard failedEnablePublicationInFlight == nil else { throw FailedEnableEvidenceError.changed }
      failedEnablePublicationInFlight = failedEnableOwnerNonce
      defer { failedEnablePublicationInFlight = nil }
      let locks = try FailedEnableReadLocks(stores: [(id, await library.lockURL)])
      defer { withExtendedLifetime(locks) {} }
      let read = try await library.failedEnableRead(revision: store.revision, namespace: namespace, locks: locks)
      guard try failedEnableContinuityMatches(prior, source: read, sourceID: id) else {
        try failedEnableFiles.update(id) { current in
          guard var current, current == prior else { throw FailedEnableEvidenceError.changed }
          current.continuity.state = .uncertain
          return current
        }
        throw FailedEnableEvidenceError.reviewRequired
      }
    } catch { failedEnableUncertainSources.insert(id) }
  }

  func completeFailedEnableSourceWrite(storeID: UUID) async {
    guard !failedEnableUncertainSources.contains(storeID),
      let store = store(id: storeID),
      let prior = try? failedEnableFiles.read(storeID),
      let ticket = prior.continuity.inFlight.value, ticket.kind == .source,
      ticket.ownerNonce == FailedEnableEncoding.uuid(failedEnableOwnerNonce),
      ticket.reservedRevision.value == String(store.revision),
      let binding = prior.namespaces.first?.binding ?? prior.transfers.first?.namespace,
      let namespace = try? binding.domain,
      let library = try? libraryForTransition(storeID: storeID)
    else { return }
    do {
      guard failedEnablePublicationInFlight == nil else { throw FailedEnableEvidenceError.changed }
      failedEnablePublicationInFlight = failedEnableOwnerNonce
      defer { failedEnablePublicationInFlight = nil }
      let locks = try FailedEnableReadLocks(stores: [(storeID, await library.lockURL)])
      let read = try await library.failedEnableRead(revision: store.revision, namespace: namespace, locks: locks)
      defer { withExtendedLifetime(locks) {} }
      let digest = try read.sourceDigest(sourceID: storeID)
      try failedEnableFiles.update(storeID) { current in
        guard var current, current.continuity.inFlight.value == ticket,
          self.store(id: storeID)?.revision == store.revision
        else { throw FailedEnableEvidenceError.changed }
        current.continuity.sourceRevision = String(store.revision)
        current.continuity.sourceDigest = digest
        current.continuity.activationDigest = failedEnableActivationDigest(manifest)
        current.continuity.inFlight = .init(nil)
        return current
      }
    } catch { failedEnableUncertainSources.insert(storeID) }
  }

  func reconcileFailedEnableOnOpen() async {
    guard failedEnablePublicationInFlight == nil, let original = failedEnableReopenManifest else { return }
    for id in failedEnableSourceIDs() {
      do {
        guard let store = store(id: id), let prior = try failedEnableFiles.read(id),
          let binding = prior.namespaces.first?.binding ?? prior.transfers.first?.namespace
        else { continue }
        let namespace = try binding.domain
        let library = try libraryForTransition(storeID: id)
        guard failedEnablePublicationInFlight == nil else { throw FailedEnableEvidenceError.changed }
        failedEnablePublicationInFlight = failedEnableOwnerNonce
        defer { failedEnablePublicationInFlight = nil }
        let locks = try FailedEnableReadLocks(stores: [(id, await library.lockURL)])
        defer { withExtendedLifetime(locks) {} }
        let read = try await library.failedEnableRead(revision: store.revision, namespace: namespace, locks: locks)
        let digest = try read.sourceDigest(sourceID: id)
        let actualOriginal = failedEnableActivationDigest(original)
        let ticket = prior.continuity.inFlight.value
        let matches = prior.continuity.state == .verified
          && prior.continuity.sourceRevision == String(store.revision)
          && prior.continuity.sourceDigest == digest
          && (ticket == nil && prior.continuity.activationDigest == actualOriginal
            || ticket?.kind == .manifest && (ticket?.previousActivationDigest == actualOriginal
              || ticket?.manifestPostimageDigest.value == actualOriginal))
        try failedEnableFiles.update(id) { current in
          guard var current, current == prior else { throw FailedEnableEvidenceError.changed }
          current.continuity.state = matches ? .verified : .uncertain
          if matches {
            current.continuity.activationDigest = failedEnableActivationDigest(manifest)
            current.continuity.inFlight = .init(nil)
          }
          return current
        }
      } catch { failedEnableUncertainSources.insert(id) }
    }
    failedEnableReopenManifest = nil
  }

  /// No evidence error is allowed to turn a valid mode owner into another writable collection.
  func failedEnableMustRetainStore(_ store: SyncModeStore) -> Bool {
    do {
      let bundles = try failedEnableSourceIDs().map { id in
        guard let bundle = try failedEnableFiles.read(id) else { throw FailedEnableEvidenceError.unavailable }
        return bundle
      }
      let id = FailedEnableEncoding.uuid(store.id)
      let referenced = bundles.filter {
        $0.sourceStoreID == id
          || $0.namespaces.flatMap(\.captures).contains(where: { $0.candidateStoreID == id })
          || $0.transfers.contains(where: { $0.sourceStoreID == id || $0.destinationStoreID == id })
      }
      if referenced.isEmpty, failedEnableCreationWasAborted(store) { return false }
      guard referenced.allSatisfy({ failedEnableEvidenceIsSelfContained($0) }) else { return true }
      if referenced.contains(where: { $0.sourceStoreID == id }) {
        guard let source = referenced.first(where: { $0.sourceStoreID == id }),
          failedEnableSourceWasCopied(store, evidence: source) else { return true }
      }
      if failedEnableIsolationRemovalHasSettled(store) { return false }
      if let source = referenced.first(where: { $0.sourceStoreID == id }),
        failedEnableSourceWasCopied(store, evidence: source) { return false }
      // A deleting candidate never became an account cache. Its kind or a nil transition
      // cannot authorize disposal, even when some accepted values reached the server.
      return store.syncProtocol == .fullRecordV1 || store.kind == .iCloudSync || !referenced.isEmpty
    } catch {
      return true
    }
  }

  private func failedEnableCreationWasAborted(_ candidate: SyncModeStore) -> Bool {
    // A creating candidate has not reached fetch, source capture, apply or send admission.
    guard candidate.lifecycle == .creating, manifest.transition == nil,
      manifest.accountIsolation == nil, manifest.activeStoreID != candidate.id else { return false }
    var aborted = candidate
    aborted.lifecycle = .deleting
    return store(id: candidate.id) == aborted
  }

  private func failedEnableIsolationRemovalHasSettled(_ isolated: SyncModeStore) -> Bool {
    // The account owner passes its pre-commit isolated value after endAccountIsolation.
    // Other cleanup callers pass current retired/deleting values and cannot use this proof.
    guard isolated.lifecycle == .isolated, isolated.kind == .iCloudSync, isolated.namespace != nil,
      manifest.accountIsolation == nil,
      manifest.transition == nil, manifest.activeStoreID != isolated.id,
      let replacement = store(id: manifest.activeStoreID), replacement.kind == .localOnly,
      replacement.lifecycle == .ready else { return false }
    var ended = isolated
    ended.lifecycle = .deleting
    return store(id: isolated.id) == ended
  }

  private func failedEnableSourceWasCopied(_ source: SyncModeStore,
    evidence: FailedEnableInstalledEvidence
  ) -> Bool {
    guard source.kind == .localOnly, source.namespace == nil,
      manifest.transition == nil,
      source.id != manifest.activeStoreID, [.retired, .deleting].contains(source.lifecycle),
      !failedEnableUncertainSources.contains(source.id), evidence.continuity.state == .verified,
      evidence.continuity.inFlight.value == nil,
      evidence.continuity.activationDigest == failedEnableActivationDigest(manifest),
      evidence.continuity.sourceRevision == String(source.revision) else { return false }
    return evidence.namespaces.contains { group in
      group.captures.contains { capture in
        guard capture.sourceDigest == evidence.continuity.sourceDigest,
          capture.freeze.sourceRevision == String(source.revision) else { return false }
        return evidence.transfers.contains { transfer in
          guard transfer.kind == .candidate, transfer.state == .checked,
            transfer.sourceCaptureIDs.contains(capture.id), transfer.namespace == group.binding,
            transfer.destinationStoreID == FailedEnableEncoding.uuid(manifest.activeStoreID),
            let destination = store(id: manifest.activeStoreID), destination.kind == .iCloudSync,
            destination.namespace.map(FailedEnableBinding.init) == group.binding else { return false }
          return transfer.destinationStoreID == capture.candidateStoreID
        }
      }
    }
  }

  private func failedEnableEvidenceIsSelfContained(_ evidence: FailedEnableInstalledEvidence) -> Bool {
    guard let sourceID = try? FailedEnableEncoding.uuid(evidence.sourceStoreID),
      !failedEnableUncertainSources.contains(sourceID), evidence.continuity.state == .verified,
      evidence.continuity.inFlight.value == nil else { return false }
    func embedded(_ image: FailedEnableImage) -> Bool {
      switch image {
      case .list: true
      case .snip(let snip): snip.attachments.allSatisfy { $0.availability.kind == .embedded }
      }
    }
    // The file decoder has already checked complete image fields and each embedded blob's
    // hash/length. Keep every bundle; this proves only that deleting a root loses no F5 version.
    return evidence.namespaces.allSatisfy { group in
      group.reviews.isEmpty && group.alternatives.allSatisfy { alternative in
        guard let image = alternative.image.value, embedded(image) else { return false }
        return alternative.attachmentHashes.allSatisfy { evidence.blobs[$0] != nil }
      } && group.captures.allSatisfy { capture in
        capture.normalizer == 1 && capture.syncProtocol == .fullRecordV1
          && capture.candidateDeletes.isEmpty && capture.records.allSatisfy { record in
            guard record.sourceMembership == .present, let image = record.source.value, embedded(image),
              record.preparation.normalizer == 1,
              [.nonconflicting, .equalFetched].contains(record.preparation.classification),
              let accepted = record.observedAccepted.value, !accepted.isDeferred,
              !accepted.hasUnresolvedLegacyAbsence else { return false }
            return record.preparation.value.value != nil
          }
      }
    } && evidence.transfers.allSatisfy { transfer in
      transfer.state == .checked && transfer.conflicts.isEmpty && transfer.recoveryDescriptors.isEmpty
        && transfer.outputs.allSatisfy(embedded)
    }
  }
}
