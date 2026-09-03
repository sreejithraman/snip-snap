import Foundation
import SnipSnapCore

public enum SyncModeActivationManifestReader {
  public enum ICloudStartupState: Equatable, Sendable {
    case localOnly
    case settingUp(ICloudSyncNamespaceBinding)
    case needsAttention(ICloudSyncNamespaceBinding)
    case active(ICloudSyncNamespaceBinding)

    public var namespace: ICloudSyncNamespaceBinding? {
      switch self {
      case .localOnly: nil
      case .settingUp(let value), .needsAttention(let value), .active(let value): value
      }
    }
  }

  /// Reads the Cloud namespace selected by an existing activation manifest.
  /// Missing, local-only, or invalid state fails closed without changing the file system.
  public static func activeCloudNamespace(
    atSyncModeRootURL rootURL: URL
  ) -> ICloudSyncNamespaceBinding? {
    guard rootURL.isFileURL else { return nil }
    let manifestURL = rootURL.appendingPathComponent("activation.json", isDirectory: false)
    do {
      let values = try manifestURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
      let manifest = try JSONDecoder().decode(
        SwiftDataSyncModePersistence.Manifest.self,
        from: Data(contentsOf: manifestURL)
      )
      try SwiftDataSyncModePersistence.validate(manifest)
      _ = try SwiftDataSyncModePersistence.validatedStoreRoots(
        manifest.stores,
        rootURL: rootURL
      )
      guard let active = manifest.stores.first(where: { $0.id == manifest.activeStoreID }),
        active.kind == .iCloudSync
      else { return nil }
      return active.namespace
    } catch {
      return nil
    }
  }

  public static func iCloudStartupState(
    atSyncModeRootURL rootURL: URL
  ) -> ICloudStartupState {
    guard rootURL.isFileURL else { return .localOnly }
    let manifestURL = rootURL.appendingPathComponent("activation.json", isDirectory: false)
    do {
      let values = try manifestURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        return .localOnly
      }
      let manifest = try JSONDecoder().decode(
        SwiftDataSyncModePersistence.Manifest.self,
        from: Data(contentsOf: manifestURL)
      )
      try SwiftDataSyncModePersistence.validate(manifest)
      _ = try SwiftDataSyncModePersistence.validatedStoreRoots(
        manifest.stores,
        rootURL: rootURL
      )
      guard let active = manifest.stores.first(where: { $0.id == manifest.activeStoreID })
      else { return .localOnly }
      if active.kind == .iCloudSync, let namespace = active.namespace {
        return .active(namespace)
      }
      guard active.kind == .localOnly,
        let transition = manifest.transition,
        transition.targetKind == .iCloudSync,
        let namespace = transition.namespace
      else { return .localOnly }
      return manifest.attentionReason == nil ? .settingUp(namespace) : .needsAttention(namespace)
    } catch {
      return .localOnly
    }
  }
}

package actor SyncModeActiveMutationLease {
  private let persistence: SwiftDataSyncModePersistence
  private let storeID: UUID

  init(persistence: SwiftDataSyncModePersistence, storeID: UUID) {
    self.persistence = persistence
    self.storeID = storeID
  }

  package func run<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let reservation = try await persistence.reserveActiveMutation(storeID: storeID)
    do {
      let value = try await operation()
      try await persistence.finishActiveMutation(reservation)
      return value
    } catch {
      // A failed clear leaves a durable reservation that reopen can clear conservatively.
      try? await persistence.finishActiveMutation(reservation)
      throw error
    }
  }
}

package enum SyncModeCrashPoint: Equatable, Sendable {
  case afterCandidateManifest
  case beforeCandidateDurability
  case afterCandidateDurability
  case beforeCandidateMergeDurability
  case afterCandidateMergeDurability
  case afterEnrollmentApproval
  case afterFirstSendStarted
  case beforeSendAttemptManifest
  case afterFirstSendComplete
  case afterRetryBasePromotion
  case duringRetryBasePromotionStaging
  case beforePointerSwap
  case afterPointerSwap
  case afterRetiredCleanupDeclared
  case afterAccountIsolationManifest
  case beforeAccountIsolationDurability
  case afterAccountIsolationDurability
  case beforeAccountIsolationPointerSwap
  case afterAccountIsolationPointerSwap
  case afterAccountResolutionIntent
  case afterAccountLocalCopyMerge
  case beforeAccountIsolationRemovalCommit
  case afterAccountIsolationRemovalCommit
  case afterAccountIsolationRootRemoval
}


package enum SyncModeWritePoint: Equatable, Sendable {
  case afterRevisionReserved
  case beforeReservationCleared
}

/// Owns mode-store roots and the one atomic file that selects the active root.
package actor SwiftDataSyncModePersistence {
  package typealias ManifestWriter = @Sendable (Data, URL) throws -> Void
  package typealias WriteHook = @Sendable (SyncModeWritePoint) async throws -> Void
  package typealias ReadHook = @Sendable () throws -> Void
  package typealias RecoveryQuarantineHook = @Sendable () throws -> Void

  struct Manifest: Codable, Equatable {
    let version: Int
    var activeStoreID: UUID
    var stores: [SyncModeStore]
    var transition: SyncModeTransition?
    var accountIsolation: ICloudAccountIsolation?
    var attentionReason: ICloudSyncAttentionReason?
    var writeReservation: SyncModeWriteReservation?

    private enum CodingKeys: String, CodingKey {
      case version, activeStoreID, stores, transition, accountIsolation
      case attentionReason, writeReservation
    }

    init(
      version: Int,
      activeStoreID: UUID,
      stores: [SyncModeStore],
      transition: SyncModeTransition?,
      accountIsolation: ICloudAccountIsolation? = nil,
      attentionReason: ICloudSyncAttentionReason?,
      writeReservation: SyncModeWriteReservation?
    ) {
      self.version = version
      self.activeStoreID = activeStoreID
      self.stores = stores
      self.transition = transition
      self.accountIsolation = accountIsolation
      self.attentionReason = attentionReason
      self.writeReservation = writeReservation
    }

    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      version = try values.decode(Int.self, forKey: .version)
      activeStoreID = try values.decode(UUID.self, forKey: .activeStoreID)
      stores = try values.decode([SyncModeStore].self, forKey: .stores)
      transition = try values.decodeIfPresent(SyncModeTransition.self, forKey: .transition)
      accountIsolation = try values.decodeIfPresent(
        ICloudAccountIsolation.self,
        forKey: .accountIsolation
      )
      attentionReason = try values.decodeIfPresent(
        ICloudSyncAttentionReason.self,
        forKey: .attentionReason
      )
      writeReservation = try values.decodeIfPresent(
        SyncModeWriteReservation.self,
        forKey: .writeReservation
      )
    }
  }

  let rootURL: URL
  let manifestURL: URL
  let crashHook: @Sendable (SyncModeCrashPoint) throws -> Void
  let manifestWriter: ManifestWriter
  let writeHook: WriteHook
  let readHook: ReadHook
  let recoveryQuarantineHook: RecoveryQuarantineHook
  let defaultSyncProtocol: SyncModeSyncProtocol
  var manifest: Manifest
  var writeAdmissionInProgress = false
  var completedRecoveryQuarantineStoreIDs: Set<UUID> = []

  package init(
    rootURL: URL,
    defaultSyncProtocol: SyncModeSyncProtocol = .fullRecordV1,
    crashHook: @escaping @Sendable (SyncModeCrashPoint) throws -> Void = { _ in },
    manifestWriter: @escaping ManifestWriter = { try DurableFile.write($0, to: $1) },
    writeHook: @escaping WriteHook = { _ in },
    readHook: @escaping ReadHook = {},
    recoveryQuarantineHook: @escaping RecoveryQuarantineHook = {}
  ) throws {
    self.rootURL = rootURL
    manifestURL = rootURL.appendingPathComponent("activation.json", isDirectory: false)
    self.crashHook = crashHook
    self.manifestWriter = manifestWriter
    self.writeHook = writeHook
    self.readHook = readHook
    self.recoveryQuarantineHook = recoveryQuarantineHook
    self.defaultSyncProtocol = defaultSyncProtocol
    try DurableFile.createDirectory(rootURL)
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      do {
        var loaded = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        try Self.recover(&loaded, rootURL: rootURL)
        try Self.validate(loaded)
        manifest = loaded
        try Self.write(loaded, to: manifestURL, using: manifestWriter)
      } catch {
        throw SyncModePersistenceError.invalidManifest
      }
    } else {
      var store = Self.newStore(
        kind: .localOnly,
        namespace: nil,
        syncProtocol: defaultSyncProtocol
      )
      let declared = Manifest(
        version: 2,
        activeStoreID: store.id,
        stores: [store],
        transition: nil,
        accountIsolation: nil,
        attentionReason: nil,
        writeReservation: nil
      )
      try Self.write(declared, to: manifestURL, using: manifestWriter)
      let storeURL = rootURL.appendingPathComponent(store.relativeRoot, isDirectory: true)
      _ = try SwiftDataSnipLibrary(
        storeURL: storeURL.appendingPathComponent("snips.store", isDirectory: false)
      )
      try DurableFile.syncDirectory(storeURL)
      store.lifecycle = .ready
      manifest = Manifest(
        version: 2,
        activeStoreID: store.id,
        stores: [store],
        transition: nil,
        accountIsolation: nil,
        attentionReason: nil,
        writeReservation: nil
      )
      try Self.write(manifest, to: manifestURL, using: manifestWriter)
    }
  }

  package nonisolated static func existingCloudNamespace(
    rootURL: URL
  ) throws -> ICloudSyncNamespaceBinding? {
    let manifestURL = rootURL.appendingPathComponent("activation.json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
    let stored = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    return stored.accountIsolation?.namespace
      ?? stored.transition?.namespace
      ?? stored.stores.first(where: { $0.id == stored.activeStoreID })?.namespace
  }

  package func snapshot() async throws -> SyncModeStorageSnapshot {
    await finishRecoveryQuarantines()
    guard let active = manifest.stores.first(where: { $0.id == manifest.activeStoreID }) else {
      throw SyncModePersistenceError.missingStore
    }
    return SyncModeStorageSnapshot(
      activeStore: active,
      transition: manifest.transition,
      accountIsolation: manifest.accountIsolation,
      attentionReason: manifest.attentionReason,
      hasActiveMutationReservation: manifest.writeReservation != nil
    )
  }

  package func isolateActiveCloudStore(
    reason: ICloudAccountIsolationReason
  ) async throws -> ICloudAccountIsolation {
    if let isolation = manifest.accountIsolation { return isolation }
    guard manifest.writeReservation == nil, !writeAdmissionInProgress,
      let active = store(id: manifest.activeStoreID),
      active.kind == .iCloudSync,
      let namespace = active.namespace
    else { throw SyncModePersistenceError.transitionInProgress }
    if let transition = manifest.transition {
      guard transition.sourceStoreID == active.id,
        transition.targetKind == .localOnly,
        transition.phase != .pointerSwapped
      else { throw SyncModePersistenceError.transitionInProgress }
    }

    let replacement = Self.newStore(
      kind: .localOnly,
      namespace: nil,
      syncProtocol: active.syncProtocol
    )
    let isolation = ICloudAccountIsolation(
      id: UUID(),
      storeID: active.id,
      replacementStoreID: replacement.id,
      namespace: namespace,
      reason: reason
    )
    var declared = manifest
    if let transition = declared.transition {
      declared.stores[try storeIndex(id: transition.candidateStoreID)].lifecycle = .deleting
      declared.transition = nil
    }
    declared.stores.append(replacement)
    declared.accountIsolation = isolation
    declared.attentionReason = reason == .signedOut ? .accountSignedOut : .accountChanged
    try commit(declared)
    try crashHook(.afterAccountIsolationManifest)

    let replacementRoot = storeURL(replacement)
    try crashHook(.beforeAccountIsolationDurability)
    _ = try SwiftDataSnipLibrary(
      storeURL: replacementRoot.appendingPathComponent("snips.store", isDirectory: false)
    )
    try DurableFile.syncDirectory(replacementRoot)
    try DurableFile.syncDirectory(replacementRoot.deletingLastPathComponent())
    try crashHook(.afterAccountIsolationDurability)

    let isolatedLibrary = try libraryForTransition(storeID: active.id)
    try await isolatedLibrary.markReadOnlyRecovery()

    var isolated = manifest
    isolated.activeStoreID = replacement.id
    isolated.stores[try storeIndex(id: replacement.id)].lifecycle = .ready
    isolated.stores[try storeIndex(id: active.id)].lifecycle = .isolated
    try crashHook(.beforeAccountIsolationPointerSwap)
    try commit(isolated)
    try crashHook(.afterAccountIsolationPointerSwap)
    return isolation
  }

  package func resolveAccountIsolation(
    _ choice: ICloudAccountIsolationChoice
  ) async throws {
    guard var isolation = manifest.accountIsolation else {
      throw SyncModePersistenceError.transitionInProgress
    }
    let requested: ICloudAccountIsolationResolution = choice == .keepLocalCopy
      ? .keepingLocalCopy : .removing
    guard isolation.resolution == .undecided || isolation.resolution == requested else {
      throw SyncModePersistenceError.transitionInProgress
    }
    if isolation.resolution == .undecided {
      isolation.resolution = requested
      var intended = manifest
      intended.accountIsolation = isolation
      try commit(intended)
      try crashHook(.afterAccountResolutionIntent)
    }
    try await reconcileAccountIsolationResolution()
  }

  package func reconcileAccountIsolationResolution() async throws {
    guard let isolation = manifest.accountIsolation,
      isolation.resolution != .undecided
    else { return }
    if isolation.resolution == .keepingLocalCopy {
      let sourceStore = try storeForIsolation(id: isolation.storeID)
      let source = try await libraryForTransition(storeID: sourceStore.id)
        .transferSnapshot(revision: sourceStore.revision)
      let target = try libraryForTransition(storeID: manifest.activeStoreID)
      _ = try await target.mergeTransferSnapshot(source, transitionID: isolation.id)
      try crashHook(.afterAccountLocalCopyMerge)
    }
    try finishAccountIsolationResolution(isolation)
  }

  private func finishAccountIsolationResolution(
    _ isolation: ICloudAccountIsolation
  ) throws {
    guard manifest.accountIsolation == isolation,
      isolation.resolution != .undecided,
      isolation.storeID != manifest.activeStoreID
    else { throw SyncModePersistenceError.transitionInProgress }
    let roots = try Self.validatedStoreRoots(manifest.stores, rootURL: rootURL)
    guard let isolatedRoot = roots[isolation.storeID] else {
      throw SyncModePersistenceError.invalidManifest
    }
    var deleting = manifest
    deleting.stores[try storeIndex(id: isolation.storeID)].lifecycle = .deleting
    let activeIndex = try storeIndex(id: manifest.activeStoreID)
    deleting.stores[activeIndex].revision += 1
    if isolation.resolution == .keepingLocalCopy {
      deleting.stores[activeIndex].quarantinedNamespace = isolation.namespace
    }
    deleting.accountIsolation = nil
    deleting.attentionReason = nil
    try crashHook(.beforeAccountIsolationRemovalCommit)
    try commit(deleting)
    try crashHook(.afterAccountIsolationRemovalCommit)
    do {
      if FileManager.default.fileExists(atPath: isolatedRoot.path) {
        try FileManager.default.removeItem(at: isolatedRoot)
      }
    } catch {
      try? recordAttention(.storageFailure)
      throw error
    }
    try crashHook(.afterAccountIsolationRootRemoval)
    var removed = manifest
    removed.stores.removeAll { $0.id == isolation.storeID }
    try commit(removed)
  }

  private func storeForIsolation(id: UUID) throws -> SyncModeStore {
    guard let value = store(id: id), value.lifecycle == .isolated else {
      throw SyncModePersistenceError.missingStore
    }
    return value
  }

  /// The only library later app assembly should retain.
  package func libraryForTransition(storeID: UUID) throws -> SwiftDataSnipLibrary {
    guard let store = manifest.stores.first(where: { $0.id == storeID }) else {
      throw SyncModePersistenceError.missingStore
    }
    guard store.lifecycle != .creating else { throw SyncModePersistenceError.missingStore }
    return try SwiftDataSnipLibrary(storeURL: storeURL(store).appendingPathComponent("snips.store"))
  }

  package func candidateRevision(transitionID: UUID) throws -> UInt64 {
    guard let transition = manifest.transition, transition.id == transitionID,
      let candidate = store(id: transition.candidateStoreID)
    else { throw SyncModePersistenceError.transitionInProgress }
    return candidate.revision
  }

  package func beginTransition(
    to targetKind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?
  ) throws -> SyncModeTransition {
    guard manifest.writeReservation == nil, !writeAdmissionInProgress,
      manifest.accountIsolation == nil
    else {
      throw SyncModePersistenceError.transitionInProgress
    }
    if let transition = manifest.transition {
      guard transition.targetKind == targetKind, transition.namespace == namespace else {
        throw SyncModePersistenceError.transitionInProgress
      }
      return transition
    }
    guard (targetKind == .iCloudSync) == (namespace != nil) else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    if targetKind == .iCloudSync,
      let quarantine = store(id: manifest.activeStoreID)?.quarantinedNamespace,
      quarantine != namespace
    {
      throw SyncModePersistenceError.namespaceMismatch
    }
    let syncProtocol = targetKind == .iCloudSync
      ? defaultSyncProtocol
      : try currentTransitionProtocolForOptOut()
    let candidate = Self.newStore(
      kind: targetKind,
      namespace: namespace,
      syncProtocol: syncProtocol
    )
    let transition = SyncModeTransition(
      id: UUID(),
      sourceStoreID: manifest.activeStoreID,
      candidateStoreID: candidate.id,
      targetKind: targetKind,
      namespace: namespace,
      syncProtocol: syncProtocol
    )
    var declared = manifest
    declared.stores.append(candidate)
    declared.transition = transition
    declared.attentionReason = nil
    try commit(declared)
    try crashHook(.afterCandidateManifest)
    do {
      try crashHook(.beforeCandidateDurability)
      let candidateRoot = storeURL(candidate)
      _ = try SwiftDataSnipLibrary(
        storeURL: candidateRoot.appendingPathComponent("snips.store", isDirectory: false)
      )
      try DurableFile.syncDirectory(candidateRoot)
      try DurableFile.syncDirectory(candidateRoot.deletingLastPathComponent())
      try crashHook(.afterCandidateDurability)
      var ready = manifest
      ready.stores[try storeIndex(id: candidate.id)].lifecycle = .ready
      ready.transition?.phase = .candidateReady
      try commit(ready)
      return try currentTransition()
    } catch {
      try? abortUnactivatedCandidate(reason: .storageFailure)
      throw error
    }
  }

  /// Fences an active-store mutation performed by a store-specific adapter.
  package func recordPreparationComplete() throws {
    guard manifest.transition?.phase == .candidateReady else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.transition?.phase = .remoteFetched
    next.attentionReason = nil
    try commit(next)
  }

  package func retryRemoteFetch() throws {
    guard let transition = manifest.transition,
      transition.phase == .remoteFetched,
      transition.sourceStoreID == manifest.activeStoreID,
      transition.freezeToken == nil,
      !transition.freezeSnapshotTaken,
      transition.mergeIntent == nil
    else { throw SyncModePersistenceError.transitionInProgress }
    var next = manifest
    next.transition?.phase = .candidateReady
    if next.attentionReason == .enrollmentBlocked {
      next.attentionReason = nil
    }
    try commit(next)
  }

  package func swapPointer() throws {
    guard let transition = manifest.transition, transition.phase == .firstSendComplete,
      store(id: transition.candidateStoreID)?.lifecycle == .ready
    else { throw SyncModePersistenceError.transitionInProgress }
    try crashHook(.beforePointerSwap)
    var next = manifest
    next.activeStoreID = transition.candidateStoreID
    next.stores[try storeIndex(id: transition.sourceStoreID)].lifecycle = .retired
    next.transition?.phase = .pointerSwapped
    next.transition?.freezeToken = nil
    try commit(next)
    try crashHook(.afterPointerSwap)
  }

  package func finishTransition() throws {
    guard manifest.transition?.phase == .pointerSwapped else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.transition = nil
    next.attentionReason = nil
    for index in next.stores.indices where next.stores[index].lifecycle == .retired {
      next.stores[index].lifecycle = .deleting
    }
    try commit(next)
    try crashHook(.afterRetiredCleanupDeclared)
  }

  package func unfreezeBeforePointerSwap(reason: ICloudSyncAttentionReason? = nil) throws {
    guard let transition = manifest.transition,
      transition.sourceStoreID == manifest.activeStoreID,
      [
        .sourceFrozen, .recordsMerged, .enrollmentApproved, .firstSendStarted,
        .firstSendComplete,
      ].contains(transition.phase)
    else { return }
    var next = manifest
    if next.transition?.mergeIntent != nil {
      Self.absorbMergeIntent(&next.transition!)
      next.transition?.phase = .candidateReady
    } else {
      next.transition?.phase = .remoteFetched
    }
    next.transition?.freezeToken = nil
    next.transition?.freezeSnapshotTaken = false
    next.transition?.approvedSnipIDs = []
    next.attentionReason = reason
    try commit(next)
  }
  package func recordAttention(_ reason: ICloudSyncAttentionReason) throws {
    var next = manifest
    next.attentionReason = reason
    try commit(next)
  }

  package func cleanupRetiredStores(limit: Int = 2) throws {
    let protected = Set([
      Optional(manifest.activeStoreID),
      manifest.transition?.sourceStoreID,
      manifest.transition?.candidateStoreID,
      manifest.accountIsolation?.storeID,
      manifest.accountIsolation?.replacementStoreID,
    ].compactMap { $0 })
    for value in manifest.stores
      .filter({ [.retired, .deleting].contains($0.lifecycle) && !protected.contains($0.id) })
      .prefix(limit)
    {
      if value.lifecycle == .retired {
        var deleting = manifest
        deleting.stores[try storeIndex(id: value.id)].lifecycle = .deleting
        try commit(deleting)
      }
      do {
        try FileManager.default.removeItem(at: storeURL(value))
        var removed = manifest
        removed.stores.removeAll { $0.id == value.id }
        try commit(removed)
      } catch {
        try? recordAttention(.storageFailure)
        throw error
      }
    }
  }

  /// Activates a fresh empty store while keeping the prior store as a recovery copy.
  package func activateEmptyCollection(
    namespace: ICloudSyncNamespaceBinding?
  ) async throws {
    guard manifest.transition == nil,
      manifest.writeReservation == nil,
      !writeAdmissionInProgress,
      let current = store(id: manifest.activeStoreID)
    else { throw SyncModePersistenceError.transitionInProgress }
    if current.namespace == namespace,
      (namespace == nil ? current.kind == .localOnly : current.kind == .iCloudSync)
    {
      return
    }
    let kind: SyncModeStoreKind = namespace == nil ? .localOnly : .iCloudSync
    var candidate = Self.newStore(
      kind: kind,
      namespace: namespace,
      syncProtocol: current.syncProtocol
    )
    var declared = manifest
    declared.stores.append(candidate)
    declared.attentionReason = nil
    try commit(declared)
    do {
      let candidateRoot = storeURL(candidate)
      _ = try SwiftDataSnipLibrary(
        storeURL: candidateRoot.appendingPathComponent("snips.store", isDirectory: false)
      )
      try DurableFile.syncDirectory(candidateRoot)
      try DurableFile.syncDirectory(candidateRoot.deletingLastPathComponent())
      let currentLibrary = try libraryForTransition(storeID: current.id)
      try await currentLibrary.markReadOnlyRecovery()
      candidate.lifecycle = .ready
      var activated = manifest
      activated.stores[try storeIndex(id: candidate.id)] = candidate
      activated.stores[try storeIndex(id: current.id)].lifecycle = .recovery
      activated.activeStoreID = candidate.id
      try commit(activated)
      do {
        try await quarantineRecoveryStore(current)
      } catch {
        try? recordAttention(.storageFailure)
      }
    } catch {
      if let currentLibrary = try? libraryForTransition(storeID: current.id) {
        try? await currentLibrary.removeReadOnlyRecoveryMarker()
        try? await currentLibrary.removeRecoveryQuarantineCompleteMarker()
      }
      var restored = manifest
      restored.stores.removeAll { $0.id == candidate.id }
      try? FileManager.default.removeItem(at: storeURL(candidate))
      try? commit(restored)
      throw error
    }
  }

  /// Replaces the active synced cache and queues its store for deletion.
  package func discardActiveCloudCollection() async throws {
    guard manifest.transition == nil,
      manifest.writeReservation == nil,
      !writeAdmissionInProgress,
      let current = store(id: manifest.activeStoreID),
      current.kind == .iCloudSync
    else {
      if store(id: manifest.activeStoreID)?.kind == .localOnly { return }
      throw SyncModePersistenceError.transitionInProgress
    }
    let original = manifest
    var candidate = Self.newStore(
      kind: .localOnly,
      namespace: nil,
      syncProtocol: current.syncProtocol
    )
    var declared = manifest
    declared.stores.append(candidate)
    declared.attentionReason = nil
    try commit(declared)
    do {
      let candidateRoot = storeURL(candidate)
      _ = try SwiftDataSnipLibrary(
        storeURL: candidateRoot.appendingPathComponent("snips.store", isDirectory: false)
      )
      try DurableFile.syncDirectory(candidateRoot)
      try DurableFile.syncDirectory(candidateRoot.deletingLastPathComponent())
      let currentLibrary = try libraryForTransition(storeID: current.id)
      try await currentLibrary.markReadOnlyRecovery()
      candidate.lifecycle = .ready
      var activated = manifest
      activated.stores[try storeIndex(id: candidate.id)] = candidate
      activated.stores[try storeIndex(id: current.id)].lifecycle = .deleting
      activated.activeStoreID = candidate.id
      try commit(activated)
      try? cleanupRetiredStores()
    } catch {
      if let currentLibrary = try? libraryForTransition(storeID: current.id) {
        try? await currentLibrary.removeReadOnlyRecoveryMarker()
      }
      try commit(original)
      try? FileManager.default.removeItem(at: storeURL(candidate))
      throw error
    }
  }

  /// Queues a prior synced cache for deletion without changing the active library.
  package func discardInactiveCloudCollection(storeID: UUID) throws {
    guard storeID != manifest.activeStoreID,
      let index = manifest.stores.firstIndex(where: { $0.id == storeID })
    else { return }
    guard manifest.stores[index].kind == .iCloudSync,
      manifest.transition?.sourceStoreID != storeID,
      manifest.transition?.candidateStoreID != storeID,
      manifest.accountIsolation?.storeID != storeID,
      manifest.accountIsolation?.replacementStoreID != storeID
    else { throw SyncModePersistenceError.transitionInProgress }
    var deleting = manifest
    deleting.stores[index].lifecycle = .deleting
    try commit(deleting)
    try? cleanupRetiredStores()
  }

  func finishRecoveryQuarantines() async {
    for store in manifest.stores where store.lifecycle == .recovery {
      do {
        try await quarantineRecoveryStore(store)
      } catch {
        try? recordAttention(.storageFailure)
      }
    }
  }

  private func quarantineRecoveryStore(_ store: SyncModeStore) async throws {
    guard !completedRecoveryQuarantineStoreIDs.contains(store.id) else { return }
    let library = try libraryForTransition(storeID: store.id)
    if await library.isRecoveryQuarantineComplete() {
      completedRecoveryQuarantineStoreIDs.insert(store.id)
      return
    }
    try recoveryQuarantineHook()
    try await library.markReadOnlyRecovery()
    if let namespace = store.namespace {
      try await library.clearCloudTextSyncState(
        namespaceKey: namespace.namespaceKey
      )
    }
    try await library.markRecoveryQuarantineComplete()
    completedRecoveryQuarantineStoreIDs.insert(store.id)
  }

  private func currentTransition() throws -> SyncModeTransition {
    guard let transition = manifest.transition else { throw SyncModePersistenceError.transitionInProgress }
    return transition
  }

  package func cancelPendingICloudEnable() throws {
    guard let transition = manifest.transition,
      transition.targetKind == .iCloudSync,
      manifest.activeStoreID == transition.sourceStoreID,
      transition.phase != .pointerSwapped
    else { return }
    try abortUnactivatedCandidate(reason: nil)
  }

  func abortUnactivatedCandidate(reason: ICloudSyncAttentionReason?) throws {
    guard let transition = manifest.transition, manifest.activeStoreID == transition.sourceStoreID else { return }
    var next = manifest
    if let candidate = store(id: transition.candidateStoreID) {
      do {
        if FileManager.default.fileExists(atPath: storeURL(candidate).path) {
          try FileManager.default.removeItem(at: storeURL(candidate))
        }
        next.stores.removeAll { $0.id == transition.candidateStoreID }
      } catch {
        next.stores[try storeIndex(id: candidate.id)].lifecycle = .deleting
      }
    }
    next.transition = nil
    next.attentionReason = reason
    try commit(next)
  }

  func store(id: UUID) -> SyncModeStore? {
    manifest.stores.first { $0.id == id }
  }

  func storeIndex(id: UUID) throws -> Int {
    guard let index = manifest.stores.firstIndex(where: { $0.id == id }) else {
      throw SyncModePersistenceError.missingStore
    }
    return index
  }

  func storeURL(_ store: SyncModeStore) -> URL {
    rootURL.appendingPathComponent(store.relativeRoot, isDirectory: true)
  }

  func commit(_ next: Manifest) throws {
    try Self.validate(next)
    do {
      try Self.write(next, to: manifestURL, using: manifestWriter)
    } catch {
      throw SyncModePersistenceError.storageFailure
    }
    manifest = next
  }

  private static func newStore(
    kind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?,
    syncProtocol: SyncModeSyncProtocol
  ) -> SyncModeStore {
    let id = UUID()
    return SyncModeStore(
      id: id,
      kind: kind,
      namespace: namespace,
      relativeRoot: "stores/\(kind.rawValue)-\(id.uuidString.lowercased())",
      syncProtocol: syncProtocol,
      revision: 0,
      lifecycle: .creating
    )
  }

  private func currentTransitionProtocolForOptOut() throws -> SyncModeSyncProtocol {
    guard let active = store(id: manifest.activeStoreID), active.kind == .iCloudSync else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    return active.syncProtocol
  }

}
