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

  /// Whether sync mode has an activation manifest under its root. Presence, not
  /// validity: a broken file still means this device activated sync mode.
  /// Assembly tries to open that store and falls back to the legacy library
  /// when the open fails. The app publisher then writes whichever library
  /// assembly returned, so a broken manifest is not treated as local-only
  /// before the open.
  package static func hasActivationManifest(atSyncModeRootURL rootURL: URL) -> Bool {
    let manifestURL = rootURL
      .appendingPathComponent("activation.json", isDirectory: false)
    guard rootURL.isFileURL else { return false }
    let values = try? manifestURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    return values?.isRegularFile == true && values?.isSymbolicLink != true
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
  package enum Purpose: Equatable, Sendable {
    case sync
    case modeChange
  }

  private let persistence: SwiftDataSyncModePersistence
  private let storeID: UUID
  private let purpose: Purpose

  init(persistence: SwiftDataSyncModePersistence, storeID: UUID, purpose: Purpose) {
    self.persistence = persistence
    self.storeID = storeID
    self.purpose = purpose
  }

  package func run<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let reservation = try await persistence.reserveActiveMutation(storeID: storeID, purpose: purpose)
    do {
      try Task.checkCancellation()
      let value = try await operation()
      try await persistence.finishActiveMutation(reservation)
      return value
    } catch {
      // A failed clear leaves the store release-failed; this retry or the next admission clears it.
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
  case beforeRetryFetchSettlementCommit
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
  /// A hook that throws here models process loss: the write never starts, and its reservation stays for reopen.
  case afterRevisionReserved
  /// A hook that throws here fails the write after the library saved it, like a store error, so the reservation is released.
  case beforeReservationCleared
  case beforeStoreRetirement
  /// Before a Keep Local Copy reads the isolated cache; a test can pause here.
  case beforeAccountLocalCopyMerge
  /// Before a full re-enable applies its staged plan; a test can pause here.
  case beforeFullReenablePlanApply
}

/// Owns mode-store roots and the one atomic file that selects the active root.
package actor SwiftDataSyncModePersistence {
  package typealias ManifestWriter = @Sendable (Data, URL) throws -> Void
  package typealias WriteHook = @Sendable (SyncModeWritePoint) async throws -> Void
  package typealias ReadHook = @Sendable () async throws -> Void
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

    mutating func updateTransition(
      orThrow missing: SyncModePersistenceError = .transitionInProgress,
      _ event: (inout SyncModeTransition) throws -> Void
    ) throws {
      guard var current = transition else { throw missing }
      try event(&current)
      transition = current
    }
  }

  let rootURL: URL
  let attachmentCacheRootURL: URL?
  let manifestURL: URL
  let crashHook: @Sendable (SyncModeCrashPoint) throws -> Void
  let manifestWriter: ManifestWriter
  let writeHook: WriteHook
  let readHook: ReadHook
  let recoveryQuarantineHook: RecoveryQuarantineHook
  let afterMutationBeforeSave: @Sendable () throws -> Void
  let defaultSyncProtocol: SyncModeSyncProtocol
  let diagnostics: AppDiagnosticRecorder
  var manifest: Manifest

  /// Reconciles of an account-isolation choice take turns, so a background status never runs a
  /// second Keep merge.
  let accountIsolationTurns = AsyncOperationGate()

  var writeAdmission = ActiveStoreWriteAdmission()
  var completedRecoveryQuarantineStoreIDs: Set<UUID> = []

  /// The transition a rollback left when its commit failed. Try Again finishes only this one.
  private var strandedRollback: SyncModeTransition?

  /// The transition whose full re-enable merge this process is applying. Try Again skips it.
  var fullReenableMergeInFlight: UUID?

  // A checked read may suspend while another wrapper starts and finishes its
  // own read. The newest started read whose result we have seen owns health.
  var nextManagedReadAttempt: UInt64 = 0
  var latestCompletedManagedReadAttempt: UInt64 = 0

  package init(
    rootURL: URL,
    attachmentCacheRootURL: URL? = nil,
    defaultSyncProtocol: SyncModeSyncProtocol = .fullRecordV1,
    crashHook: @escaping @Sendable (SyncModeCrashPoint) throws -> Void = { _ in },
    manifestWriter: @escaping ManifestWriter = { try DurableFile.write($0, to: $1) },
    writeHook: @escaping WriteHook = { _ in },
    readHook: @escaping ReadHook = {},
    recoveryQuarantineHook: @escaping RecoveryQuarantineHook = {},
    afterMutationBeforeSave: @escaping @Sendable () throws -> Void = {},
    diagnostics: AppDiagnosticRecorder = .live
  ) throws {
    self.rootURL = rootURL
    self.attachmentCacheRootURL = attachmentCacheRootURL
    manifestURL = rootURL.appendingPathComponent("activation.json", isDirectory: false)
    self.crashHook = crashHook
    self.manifestWriter = manifestWriter
    self.writeHook = writeHook
    self.readHook = readHook
    self.recoveryQuarantineHook = recoveryQuarantineHook
    self.afterMutationBeforeSave = afterMutationBeforeSave
    self.defaultSyncProtocol = defaultSyncProtocol
    self.diagnostics = diagnostics
    try DurableFile.createDirectory(rootURL)
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      do {
        var loaded = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        try Self.recover(
          &loaded,
          rootURL: rootURL,
          attachmentCacheRootURL: attachmentCacheRootURL
        )
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
        storeURL: storeURL.appendingPathComponent("snips.store", isDirectory: false),
        attachmentCacheRootURL: Self.cacheRootURL(
          base: attachmentCacheRootURL,
          storeID: store.id
        )
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

  /// The only library later app assembly should retain.
  package func libraryForTransition(storeID: UUID) throws -> SwiftDataSnipLibrary {
    guard let store = manifest.stores.first(where: { $0.id == storeID }) else {
      throw SyncModePersistenceError.missingStore
    }
    guard store.lifecycle != .creating, store.lifecycle != .deleting else {
      throw SyncModePersistenceError.missingStore
    }
    let fileURL = storeFileURL(store)
    // A mode change's inactive candidate before the swap, and its retired source after it, must
    // have their files, so an empty recreate never stands in for either. The active store keeps
    // open-or-create so the app stays usable, though that can't protect a swapped-in candidate
    // whose files vanish. Recovery, isolated, and other inactive stores are exempt: recreating
    // them can't replace user data, and refusing them would strand the user.
    let isModeChangeStore = manifest.transition.map {
      [$0.sourceStoreID, $0.candidateStoreID].contains(store.id)
    } ?? false
    guard store.id == manifest.activeStoreID || !isModeChangeStore
      || FileManager.default.fileExists(atPath: fileURL.path)
    else { throw SyncModePersistenceError.missingStore }
    return try SwiftDataSnipLibrary(
      storeURL: fileURL,
      attachmentCacheRootURL: Self.cacheRootURL(
        base: attachmentCacheRootURL,
        storeID: store.id
      ),
      afterMutationBeforeSave: afterMutationBeforeSave,
      diagnostics: diagnostics
    )
  }

  package func candidateRevision(transitionID: UUID) throws -> UInt64 {
    guard let transition = manifest.transition, transition.id == transitionID,
      let candidate = store(id: transition.candidateStoreID)
    else { throw SyncModePersistenceError.transitionInProgress }
    return candidate.revision
  }

  /// Creates a mode transition or resumes its durable merge before returning it.
  package func beginOrResumeTransition(
    to targetKind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?
  ) async throws -> SyncModeTransition {
    _ = try beginTransition(to: targetKind, namespace: namespace)
    if targetKind == .iCloudSync {
      try await reconcileFullReenableIntent()
    }
    guard let transition = manifest.transition else {
      throw SyncModePersistenceError.transitionInProgress
    }
    return transition
  }

  package func beginTransition(
    to targetKind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?
  ) throws -> SyncModeTransition {
    guard writeAdmissionIsIdle(), manifest.accountIsolation == nil else {
      throw SyncModePersistenceError.transitionInProgress
    }
    if let transition = manifest.transition {
      guard transition.targetKind == targetKind, transition.namespace == namespace else {
        throw SyncModePersistenceError.transitionInProgress
      }
      if manifest.activeStoreID == transition.sourceStoreID,
        fullReenableMergeInFlight != transition.id,
        !hasStoreFile(id: transition.candidateStoreID)
      {
        // Before the swap the source still holds the library. Keep its send history
        // before replacing the missing candidate.
        try abortUnactivatedCandidate(reason: nil)
        let operation: StaticString = transition.targetKind == .iCloudSync
          ? "sync.setup" : "sync.disable"
        diagnostics.record(.missing(operation: operation))
      } else {
        // Finish only a rollback this process couldn't commit, so another operation's work in
        // flight is never undone.
        guard transition == strandedRollback else { return transition }
        if transition.phase == .candidateDeclared {
          try abortUnactivatedCandidate(reason: nil)
        } else if transition.phase == .sourceFrozen, !transition.hasDurableFullReenableIntent {
          try unfreezeBeforePointerSwap()
          return try currentTransition()
        } else {
          return transition
        }
      }
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
    declared.migrateSetupRetryHistory()
    declared.attentionReason = nil
    try commit(declared)
    try crashHook(.afterCandidateManifest)
    do {
      try crashHook(.beforeCandidateDurability)
      let candidateRoot = storeURL(candidate)
      _ = try SwiftDataSnipLibrary(
        storeURL: candidateRoot.appendingPathComponent("snips.store", isDirectory: false),
        attachmentCacheRootURL: Self.cacheRootURL(
          base: attachmentCacheRootURL,
          storeID: candidate.id
        )
      )
      try DurableFile.syncDirectory(candidateRoot)
      try DurableFile.syncDirectory(candidateRoot.deletingLastPathComponent())
      try crashHook(.afterCandidateDurability)
      var ready = manifest
      ready.stores[try storeIndex(id: candidate.id)].lifecycle = .ready
      try ready.updateTransition { try $0.markCandidateReady() }
      try commit(ready)
      return try currentTransition()
    } catch {
      try? abortUnactivatedCandidate(reason: .storageFailure)
      throw error
    }
  }

  package func recordPreparationComplete() throws {
    var next = manifest
    try next.updateTransition { try $0.recordPreparationComplete() }
    next.attentionReason = nil
    try commit(next)
  }

  package func retryRemoteFetch() throws {
    var next = manifest
    try next.updateTransition { try $0.retryRemoteFetch() }
    guard manifest.transition?.sourceStoreID == manifest.activeStoreID else {
      throw SyncModePersistenceError.transitionInProgress
    }
    if next.attentionReason == .enrollmentBlocked {
      next.attentionReason = nil
    }
    try commit(next)
  }

  package func swapPointer() throws {
    var next = manifest
    try next.updateTransition { try $0.swapPointer() }
    guard let transition = manifest.transition,
      store(id: transition.candidateStoreID)?.lifecycle == .ready
    else { throw SyncModePersistenceError.transitionInProgress }
    guard hasStoreFile(id: transition.candidateStoreID) else {
      throw SyncModePersistenceError.missingStore
    }
    try crashHook(.beforePointerSwap)
    next.activeStoreID = transition.candidateStoreID
    let sourceIndex = try storeIndex(id: transition.sourceStoreID)
    next.stores[sourceIndex].lifecycle = .retired
    next.stores[sourceIndex].setupRetryHistory = nil
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
      transition.freezesSource
    else { return }
    var next = manifest
    try next.updateTransition { try $0.unfreeze() }
    next.attentionReason = reason
    try commitRollback(next)
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
        try removeStoreFiles(value)
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
      writeAdmissionIsIdle(),
      let current = store(id: manifest.activeStoreID)
    else { throw SyncModePersistenceError.transitionInProgress }
    if current.namespace == namespace,
      (namespace == nil ? current.kind == .localOnly : current.kind == .iCloudSync)
    {
      return
    }
    try beginStoreReplacement()
    defer { finishStoreReplacement() }
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
        storeURL: candidateRoot.appendingPathComponent("snips.store", isDirectory: false),
        attachmentCacheRootURL: Self.cacheRootURL(
          base: attachmentCacheRootURL,
          storeID: candidate.id
        )
      )
      try DurableFile.syncDirectory(candidateRoot)
      try DurableFile.syncDirectory(candidateRoot.deletingLastPathComponent())
      let currentLibrary = try libraryForTransition(storeID: current.id)
      try await writeHook(.beforeStoreRetirement)
      try await currentLibrary.markReadOnlyRecovery()
      candidate.lifecycle = .ready
      var activated = manifest
      activated.stores[try storeIndex(id: candidate.id)] = candidate
      let sourceIndex = try storeIndex(id: current.id)
      activated.stores[sourceIndex].lifecycle = .recovery
      activated.stores[sourceIndex].setupRetryHistory = nil
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
      }
      var restored = manifest
      restored.stores.removeAll { $0.id == candidate.id }
      try? removeStoreFiles(candidate)
      try? commit(restored)
      throw error
    }
  }

  /// Replaces the active synced cache and queues its store for deletion.
  package func discardActiveCloudCollection() async throws {
    _ = try await discardActiveCloudCollection(matching: nil)
  }

  package func discardActiveCloudCollection(
    storeID: UUID, namespace: ICloudSyncNamespaceBinding
  ) async throws -> UUID? {
    try await discardActiveCloudCollection(matching: (storeID, namespace))
  }

  private func discardActiveCloudCollection(
    matching expected: (UUID, ICloudSyncNamespaceBinding)?
  ) async throws -> UUID? {
    if let expected {
      guard manifest.activeStoreID == expected.0,
        store(id: expected.0)?.namespace == expected.1
      else { return nil }
    }
    guard manifest.transition == nil,
      let current = store(id: manifest.activeStoreID),
      current.kind == .iCloudSync
    else {
      if store(id: manifest.activeStoreID)?.kind == .localOnly { return nil }
      throw SyncModePersistenceError.transitionInProgress
    }
    try beginStoreReplacement()
    defer { finishStoreReplacement() }
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
        storeURL: candidateRoot.appendingPathComponent("snips.store", isDirectory: false),
        attachmentCacheRootURL: Self.cacheRootURL(
          base: attachmentCacheRootURL,
          storeID: candidate.id
        )
      )
      try DurableFile.syncDirectory(candidateRoot)
      try DurableFile.syncDirectory(candidateRoot.deletingLastPathComponent())
      let currentLibrary = try libraryForTransition(storeID: current.id)
      try await writeHook(.beforeStoreRetirement)
      try await currentLibrary.markReadOnlyRecovery()
      candidate.lifecycle = .ready
      var activated = manifest
      activated.stores[try storeIndex(id: candidate.id)] = candidate
      activated.stores[try storeIndex(id: current.id)].lifecycle = .deleting
      activated.activeStoreID = candidate.id
      try commit(activated)
      try? cleanupRetiredStores()
      return candidate.id
    } catch {
      if let currentLibrary = try? libraryForTransition(storeID: current.id) {
        try? await currentLibrary.removeReadOnlyRecoveryMarker()
      }
      try commit(original)
      try? removeStoreFiles(candidate)
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
    if let index = next.stores.firstIndex(where: { $0.id == transition.candidateStoreID }) {
      next.stores[index].lifecycle = .deleting
    }
    next.stopTrackingSetupRetryCandidate()
    next.transition = nil
    next.attentionReason = reason
    // Commit before removing any files. A candidate whose files are gone but whose manifest
    // entry survives a failed commit is reopened empty by the next enable.
    try commitRollback(next)
    guard let candidate = store(id: transition.candidateStoreID) else { return }
    do {
      try removeStoreFiles(candidate)
      var removed = manifest
      removed.stores.removeAll { $0.id == candidate.id }
      try commit(removed)
    } catch {
      // The candidate stays deleting, for reopen or a later cleanup to finish.
    }
  }

  func commitRollback(_ next: Manifest) throws {
    do {
      try commit(next)
    } catch {
      strandedRollback = manifest.transition
      throw error
    }
    strandedRollback = nil
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

  func storeFileURL(_ store: SyncModeStore) -> URL {
    storeURL(store).appendingPathComponent("snips.store", isDirectory: false)
  }

  private func hasStoreFile(id: UUID) -> Bool {
    guard let listed = store(id: id) else { return false }
    return FileManager.default.fileExists(atPath: storeFileURL(listed).path)
  }

  nonisolated static func cacheRootURL(base: URL?, storeID: UUID) -> URL? {
    base?
      .appendingPathComponent(storeID.uuidString.lowercased(), isDirectory: true)
  }

  func removeStoreFiles(_ store: SyncModeStore) throws {
    if let cacheRoot = Self.cacheRootURL(base: attachmentCacheRootURL, storeID: store.id),
      FileManager.default.fileExists(atPath: cacheRoot.path)
    {
      try CloudAttachmentCacheFiles.removeCacheContainer(cacheRoot)
    }
    let root = storeURL(store)
    if FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
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
      relativeRoot: canonicalRelativeRoot(kind: kind, id: id),
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
