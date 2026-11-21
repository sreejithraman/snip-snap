import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence.Manifest {
  /// Apple Account isolation (ADR 0015), decoded from `accountIsolation`, its two stores'
  /// lifecycles, and the active-store pointer. Only the transitions below write those fields.
  enum AccountIsolationPhase {
    case none
    /// The local replacement is declared while the iCloud cache is still active. Reopen, or the
    /// next isolate, reconcile, Keep, or Remove in this process, finishes the swap. Older builds
    /// could also store a choice here; reopen swaps it like any other.
    case declared(ICloudAccountIsolation)
    /// The replacement is active. The iCloud cache stays hidden until the user keeps or removes it.
    case isolated(ICloudAccountIsolation)
  }

  /// Throws `invalidManifest` for any combination no build writes.
  func accountIsolationPhase() throws -> AccountIsolationPhase {
    guard let isolation = accountIsolation else {
      guard !stores.contains(where: { $0.lifecycle == .isolated }) else {
        throw SyncModePersistenceError.invalidManifest
      }
      return .none
    }
    guard transition == nil,
      let source = stores.first(where: { $0.id == isolation.storeID }),
      let replacement = stores.first(where: { $0.id == isolation.replacementStoreID }),
      source.kind == .iCloudSync,
      source.namespace == isolation.namespace,
      replacement.kind == .localOnly,
      replacement.namespace == nil
    else { throw SyncModePersistenceError.invalidManifest }
    if activeStoreID == source.id, source.lifecycle == .ready,
      replacement.lifecycle == .creating
    {
      return .declared(isolation)
    }
    if activeStoreID == replacement.id, source.lifecycle == .isolated,
      replacement.lifecycle == .ready
    {
      return .isolated(isolation)
    }
    throw SyncModePersistenceError.invalidManifest
  }

  /// none → declared, for the active iCloud cache. An opt-out that never activated is dropped:
  /// its candidate is queued for deletion.
  mutating func declareAccountIsolation(
    reason: ICloudAccountIsolationReason
  ) throws -> ICloudAccountIsolation {
    guard accountIsolation == nil,
      let active = stores.first(where: { $0.id == activeStoreID }),
      active.kind == .iCloudSync,
      let namespace = active.namespace
    else { throw SyncModePersistenceError.transitionInProgress }
    if let transition {
      guard transition.sourceStoreID == active.id,
        transition.targetKind == .localOnly,
        transition.phase != .swapped
      else { throw SyncModePersistenceError.transitionInProgress }
      guard let candidateIndex = stores.firstIndex(where: { $0.id == transition.candidateStoreID })
      else { throw SyncModePersistenceError.missingStore }
      stores[candidateIndex].lifecycle = .deleting
      self.transition = nil
    }
    let replacementID = UUID()
    let replacement = SyncModeStore(
      id: replacementID,
      kind: .localOnly,
      namespace: nil,
      relativeRoot: SwiftDataSyncModePersistence.canonicalRelativeRoot(
        kind: .localOnly,
        id: replacementID
      ),
      syncProtocol: active.syncProtocol
    )
    let isolation = ICloudAccountIsolation(
      id: UUID(),
      storeID: active.id,
      replacementStoreID: replacement.id,
      namespace: namespace,
      reason: reason
    )
    stores.append(replacement)
    accountIsolation = isolation
    attentionReason = reason == .signedOut ? .accountSignedOut : .accountChanged
    return isolation
  }

  /// declared → isolated: the replacement becomes the active store.
  mutating func swapToIsolationReplacement() throws {
    guard case .declared(let isolation) = try accountIsolationPhase() else {
      throw SyncModePersistenceError.transitionInProgress
    }
    guard let sourceIndex = stores.firstIndex(where: { $0.id == isolation.storeID }),
      let replacementIndex = stores.firstIndex(where: { $0.id == isolation.replacementStoreID })
    else { throw SyncModePersistenceError.missingStore }
    activeStoreID = isolation.replacementStoreID
    stores[replacementIndex].lifecycle = .ready
    stores[sourceIndex].lifecycle = .isolated
  }

  /// Records Keep Local Copy or Remove once the replacement is active, so a failed swap never
  /// leaves a stored choice.
  mutating func chooseAccountIsolationResolution(
    _ resolution: ICloudAccountIsolationResolution
  ) throws {
    guard case .isolated(var isolation) = try accountIsolationPhase(),
      isolation.resolution == .undecided
    else { throw SyncModePersistenceError.transitionInProgress }
    isolation.resolution = resolution
    accountIsolation = isolation
  }

  /// isolated with a choice → none. The cache store is queued for deletion, and a kept copy
  /// records the collection it may rejoin.
  mutating func endAccountIsolation() throws {
    guard case .isolated(let isolation) = try accountIsolationPhase(),
      isolation.resolution != .undecided
    else { throw SyncModePersistenceError.transitionInProgress }
    guard let sourceIndex = stores.firstIndex(where: { $0.id == isolation.storeID }),
      let activeIndex = stores.firstIndex(where: { $0.id == activeStoreID })
    else { throw SyncModePersistenceError.missingStore }
    stores[sourceIndex].lifecycle = .deleting
    stores[activeIndex].revision += 1
    if isolation.resolution == .keepingLocalCopy {
      stores[activeIndex].quarantinedNamespace = isolation.namespace
    }
    accountIsolation = nil
    attentionReason = nil
  }
}

extension SwiftDataSyncModePersistence {
  package func isolateActiveCloudStore(
    reason: ICloudAccountIsolationReason,
    expectedStoreID: UUID? = nil
  ) async throws -> ICloudAccountIsolation {
    guard expectedStoreID == nil || manifest.activeStoreID == expectedStoreID else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    if let isolation = manifest.accountIsolation {
      try? await resumeDeclaredAccountIsolation()
      return isolation
    }
    try beginStoreReplacement()
    defer { finishStoreReplacement() }
    if manifest.transition?.phase == .swapped,
      store(id: manifest.activeStoreID)?.kind == .iCloudSync
    {
      try finishTransition()
    }
    var declared = manifest
    let isolation = try declared.declareAccountIsolation(reason: reason)
    try commit(declared)
    try crashHook(.afterAccountIsolationManifest)
    try await completeAccountIsolation(isolation)
    return isolation
  }

  /// declared → isolated. The caller holds store replacement.
  private func completeAccountIsolation(_ isolation: ICloudAccountIsolation) async throws {
    guard let replacement = store(id: isolation.replacementStoreID) else {
      throw SyncModePersistenceError.missingStore
    }
    let replacementRoot = storeURL(replacement)
    try crashHook(.beforeAccountIsolationDurability)
    _ = try SwiftDataSnipLibrary(
      storeURL: replacementRoot.appendingPathComponent("snips.store", isDirectory: false),
      attachmentCacheRootURL: Self.cacheRootURL(
        base: attachmentCacheRootURL,
        storeID: replacement.id
      )
    )
    try DurableFile.syncDirectory(replacementRoot)
    try DurableFile.syncDirectory(replacementRoot.deletingLastPathComponent())
    try crashHook(.afterAccountIsolationDurability)

    let isolatedLibrary = try libraryForTransition(storeID: isolation.storeID)
    try await writeHook(.beforeStoreRetirement)
    try await isolatedLibrary.markReadOnlyRecovery()

    var isolated = manifest
    try isolated.swapToIsolationReplacement()
    try crashHook(.beforeAccountIsolationPointerSwap)
    try commit(isolated)
    try crashHook(.afterAccountIsolationPointerSwap)
  }

  /// Finishes a declaration whose swap failed or was interrupted in this process. Isolate and
  /// reconcile only report the isolation, so they ignore a failure: the account notice still
  /// shows, and the next call retries. Keep and Remove run the swap before storing the choice,
  /// so a failed swap, or `transitionInProgress` while another writer holds the store, throws
  /// and leaves the isolation undecided.
  private func resumeDeclaredAccountIsolation() async throws {
    guard case .declared(let isolation) = try manifest.accountIsolationPhase() else { return }
    try beginStoreReplacement()
    defer { finishStoreReplacement() }
    try await completeAccountIsolation(isolation)
  }

  package func resolveAccountIsolation(
    _ choice: ICloudAccountIsolationChoice
  ) async throws {
    try await resumeDeclaredAccountIsolation()
    let requested: ICloudAccountIsolationResolution = choice == .keepLocalCopy
      ? .keepingLocalCopy : .removing
    try storeAccountIsolationResolution(requested)
    try await reconcileAccountIsolationResolution()
  }

  private func storeAccountIsolationResolution(
    _ requested: ICloudAccountIsolationResolution
  ) throws {
    guard let isolation = manifest.accountIsolation else {
      throw SyncModePersistenceError.transitionInProgress
    }
    guard isolation.resolution != requested else { return }
    var intended = manifest
    try intended.chooseAccountIsolationResolution(requested)
    try commit(intended)
    try crashHook(.afterAccountResolutionIntent)
  }

  /// Finishes a stored Keep or Remove. Calls run one at a time in arrival order. A call that
  /// waited re-reads the manifest: if the earlier call finished, it returns; if that call
  /// failed, it makes its own attempt.
  package func reconcileAccountIsolationResolution() async throws {
    try await accountIsolationTurns.withLease { try await self.reconcileInTurn() }
  }

  private func reconcileInTurn() async throws {
    try? await resumeDeclaredAccountIsolation()
    guard let isolation = manifest.accountIsolation,
      isolation.resolution != .undecided
    else { return }
    if isolation.resolution == .keepingLocalCopy {
      let sourceStore = try storeForIsolation(id: isolation.storeID)
      let sourceLibrary = try libraryForTransition(storeID: sourceStore.id)
      try await writeHook(.beforeAccountLocalCopyMerge)
      try await sourceLibrary.prepareCloudAttachmentsForLocalCopy(
        namespaceKey: isolation.namespace.namespaceKey
      )
      let source = try await sourceLibrary.transferSnapshot(revision: sourceStore.revision)
      let target = try libraryForTransition(storeID: manifest.activeStoreID)
      _ = try await target.mergeTransferSnapshot(source, transitionID: isolation.id)
      try crashHook(.afterAccountLocalCopyMerge)
    }
    try finishAccountIsolationResolution(isolation)
  }

  /// Keeps a returning account's isolated copy in one turn. `preserve` readies that copy's
  /// attachments first, and its result is returned. Returns nil, and stores nothing, when that
  /// isolation ended or the user chose Remove.
  package func keepReturningAccountIsolation(
    _ isolationID: UUID,
    preservingAttachments preserve: @Sendable (_ isolatedStoreID: UUID) async throws -> Bool
  ) async throws -> Bool? {
    try await accountIsolationTurns.withLease {
      try await self.keepReturningInTurn(isolationID, preserve)
    }
  }

  private func keepReturningInTurn(
    _ isolationID: UUID,
    _ preserve: @Sendable (_ isolatedStoreID: UUID) async throws -> Bool
  ) async throws -> Bool? {
    try await resumeDeclaredAccountIsolation()
    guard let isolation = keepableIsolation(isolationID) else { return nil }
    let recovered = try await preserve(isolation.storeID)
    // A Remove stored during the download wins.
    guard keepableIsolation(isolationID) != nil else { return nil }
    try storeAccountIsolationResolution(.keepingLocalCopy)
    try await reconcileInTurn()
    return recovered
  }

  private func keepableIsolation(_ id: UUID) -> ICloudAccountIsolation? {
    guard let isolation = manifest.accountIsolation, isolation.id == id,
      isolation.resolution != .removing
    else { return nil }
    return isolation
  }

  private func finishAccountIsolationResolution(
    _ isolation: ICloudAccountIsolation
  ) throws {
    guard manifest.accountIsolation == isolation else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var deleting = manifest
    try deleting.endAccountIsolation()
    let roots = try Self.validatedStoreRoots(manifest.stores, rootURL: rootURL)
    guard roots[isolation.storeID] != nil,
      let isolatedStore = store(id: isolation.storeID)
    else {
      throw SyncModePersistenceError.invalidManifest
    }
    try crashHook(.beforeAccountIsolationRemovalCommit)
    try commit(deleting)
    try crashHook(.afterAccountIsolationRemovalCommit)
    do {
      try removeStoreFiles(isolatedStore)
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
}
