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
    // Legacy candidate preflight and obligation retirement are deliberately still conservative.
    // In particular, a nil transition cannot prove sole candidate recovery bytes disposable.
    if store.syncProtocol == .fullRecordV1 || store.kind == .iCloudSync { return true }
    for sourceID in failedEnableSourceIDs() {
      guard let bundle = try? failedEnableFiles.read(sourceID) else { return true }
      let id = FailedEnableEncoding.uuid(store.id)
      if bundle.sourceStoreID == id || bundle.transfers.contains(where: { $0.destinationStoreID == id })
        || bundle.namespaces.flatMap(\.captures).contains(where: { $0.candidateStoreID == id }) { return true }
    }
    return false
  }
}
