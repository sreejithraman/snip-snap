import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  package func activeLibrary() async throws -> any SnipLibrary {
    let initial = try await managedSnapshot(sortedBy: .chronological)
    return ModeManagedSnipLibrary(persistence: self, fallback: nil, lastKnown: initial)
  }

  nonisolated package func activeLibrary(fallback: any SnipLibrary) -> any SnipLibrary {
    ModeManagedSnipLibrary(persistence: self, fallback: fallback, lastKnown: nil)
  }

  package func activeCloudMutation(storeID: UUID) throws -> SyncModeActiveMutation {
    guard storeID == manifest.activeStoreID, store(id: storeID)?.kind == .iCloudSync else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    return SyncModeActiveMutation(persistence: self, storeID: storeID)
  }

  func performActiveCloudMutation<Value: Sendable>(
    storeID: UUID,
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    try resolveActivationWrite()
    guard storeID == manifest.activeStoreID,
      store(id: storeID)?.kind == .iCloudSync
    else { throw SyncModePersistenceError.namespaceMismatch }
    guard manifest.transition == nil else { throw SyncModePersistenceError.transitionInProgress }
    guard !activeStoreBusy else { throw SyncModePersistenceError.transitionInProgress }
    activeStoreActivity = .cloudMutation
    defer { activeStoreActivity = nil }
    activeStoreRevision += 1
    return try await operation()
  }

  // Some operations use a different SwiftData actor and suspend. The in-process
  // gate orders writes, and this guard keeps store replacements out of those turns.
  func beginStoreReplacement() throws {
    guard !activeStoreBusy else { throw SyncModePersistenceError.transitionInProgress }
    activeStoreActivity = .replacement
  }

  func finishStoreReplacement() {
    activeStoreActivity = nil
  }

  fileprivate func managedSnapshot(sortedBy: SnipSortMode) async throws -> SnipLibrarySnapshot {
    try await finishLegacyAccountCopy()
    await finishRecoveryQuarantines()
    try await readHook()
    try resolveActivationWrite()
    return try await libraryForTransition(storeID: manifest.activeStoreID)
      .checkedSnapshot(sortedBy: sortedBy)
  }

  fileprivate func managedArchive() async throws -> SnipLibraryArchive {
    try await finishLegacyAccountCopy()
    await finishRecoveryQuarantines()
    try await readHook()
    try resolveActivationWrite()
    return try await libraryForTransition(storeID: manifest.activeStoreID).archive()
  }

  fileprivate func managedRecoverySnapshot(
    in scope: SnipRecoveryScope
  ) async throws -> SnipRecoverySnapshot {
    try await finishLegacyAccountCopy()
    await finishRecoveryQuarantines()
    try await readHook()
    try resolveActivationWrite()
    return try await libraryForTransition(storeID: manifest.activeStoreID)
      .recoverySnapshot(in: scope)
  }

  fileprivate func managedPerform(
    _ command: SnipLibraryCommand,
    sortedBy: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    try await managedWrite { library in
      try await library.perform(command, sortedBy: sortedBy)
    }
  }

  fileprivate func managedResolveRecovery(
    _ id: UUID,
    in scope: SnipRecoveryScope,
    choice: SnipRecoveryChoice,
    expectation: SnipRecoveryExpectation?
  ) async throws -> SnipLibrarySnapshot {
    try await managedWrite { library in
      try await library.resolveRecovery(id, in: scope, choice: choice, expectation: expectation)
    }
  }

  private func managedWrite<Value: Sendable>(
    _ operation: @escaping @Sendable (SwiftDataSnipLibrary) async throws -> Value
  ) async throws -> Value {
    try await finishLegacyAccountCopy()
    await finishRecoveryQuarantines()
    if activeStoreActivity == .cloudMutation {
      diagnostics.record(.writeAdmission(.started, reason: .syncBusy))
    }
    return try await activeStoreTurns.withLease {
      try await self.performManagedWrite(operation)
    }
  }

  private func performManagedWrite<Value: Sendable>(
    _ operation: @Sendable (SwiftDataSnipLibrary) async throws -> Value
  ) async throws -> Value {
    try resolveActivationWrite()
    guard !activeStoreBusy else {
      diagnostics.record(.writeAdmission(.failed, reason: .modeChange))
      throw SnipLibraryError.modeTransitionInProgress
    }
    activeStoreActivity = .libraryWrite
    defer { activeStoreActivity = nil }
    activeStoreRevision += 1
    try await writeHook(.beforeLibraryWrite)
    try Task.checkCancellation()
    return try await operation(libraryForTransition(storeID: manifest.activeStoreID))
  }

  fileprivate func managedPreviewImport(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) async throws -> SnipImportPreview {
    try await libraryForTransition(storeID: manifest.activeStoreID)
      .previewImport(source, transitionID: transitionID)
  }

  fileprivate func managedPreviewTransferSnapshot(
    revision: UInt64
  ) async throws -> SnipLibraryTransferSnapshot {
    try await libraryForTransition(storeID: manifest.activeStoreID)
      .previewTransferSnapshot(revision: revision)
  }

  fileprivate func managedApplyImport(
    _ preview: SnipImportPreview
  ) async throws -> SnipImportResult {
    try await managedWrite { library in
      try await library.applyImport(preview)
    }
  }

  fileprivate func beginManagedReadAttempt() -> UInt64 {
    nextManagedReadAttempt += 1
    return nextManagedReadAttempt
  }

  fileprivate func recordStoreReadFailure(at attempt: UInt64) {
    guard completeManagedReadAttempt(attempt) else { return }
    guard manifest.attentionReason == nil || manifest.attentionReason == .storeReadFailed else {
      return
    }
    try? recordAttention(.storeReadFailed)
  }

  fileprivate func clearRecoveredStoreReadFailure(at attempt: UInt64) throws {
    guard completeManagedReadAttempt(attempt) else { return }
    guard manifest.attentionReason == .storeReadFailed else { return }
    var next = manifest
    next.attentionReason = nil
    try commit(next)
  }

  private func completeManagedReadAttempt(_ attempt: UInt64) -> Bool {
    guard attempt > latestCompletedManagedReadAttempt else { return false }
    latestCompletedManagedReadAttempt = attempt
    return true
  }
}

private actor ModeManagedSnipLibrary: SnipLibrary {
  let persistence: SwiftDataSyncModePersistence
  private let fallback: (any SnipLibrary)?
  private var lastKnown: SnipLibrarySnapshot?

  init(
    persistence: SwiftDataSyncModePersistence,
    fallback: (any SnipLibrary)?,
    lastKnown: SnipLibrarySnapshot?
  ) {
    self.persistence = persistence
    self.fallback = fallback
    self.lastKnown = lastKnown
  }

  func snapshot(sortedBy sortMode: SnipSortMode) async -> SnipLibrarySnapshot {
    do {
      return try await checkedSnapshot(sortedBy: sortMode)
    } catch {
      if let lastKnown { return lastKnown }
      if let fallback { return await fallback.snapshot(sortedBy: sortMode) }
      return SnipLibrarySnapshot(snips: [], lists: [.inbox])
    }
  }

  func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot {
    let attempt = await persistence.beginManagedReadAttempt()
    let snapshot: SnipLibrarySnapshot
    do {
      snapshot = try await persistence.managedSnapshot(sortedBy: sortMode)
    } catch {
      await persistence.recordStoreReadFailure(at: attempt)
      throw error
    }
    lastKnown = snapshot
    try await persistence.clearRecoveredStoreReadFailure(at: attempt)
    return snapshot
  }

  func archive() async throws -> SnipLibraryArchive {
    let attempt = await persistence.beginManagedReadAttempt()
    let archive: SnipLibraryArchive
    do {
      archive = try await persistence.managedArchive()
    } catch {
      await persistence.recordStoreReadFailure(at: attempt)
      throw error
    }
    let state = SnipLibraryState(
      snips: archive.snips,
      lists: archive.lists,
      seenRequestIDs: archive.seenRequestIDs
    )
    lastKnown = SnipLibrarySnapshot(
      snips: state.allSnips(sortMode: .manual),
      lists: state.allLists(),
      attachmentURLs: archive.attachmentURLs
    )
    try await persistence.clearRecoveredStoreReadFailure(at: attempt)
    return archive
  }

  func perform(
    _ command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    let update = try await persistence.managedPerform(command, sortedBy: sortMode)
    lastKnown = update.snapshot
    return update
  }

  func recoverySnapshot(in scope: SnipRecoveryScope) async throws -> SnipRecoverySnapshot {
    let attempt = await persistence.beginManagedReadAttempt()
    let recovery: SnipRecoverySnapshot
    do {
      recovery = try await persistence.managedRecoverySnapshot(in: scope)
    } catch {
      await persistence.recordStoreReadFailure(at: attempt)
      throw error
    }
    try await persistence.clearRecoveredStoreReadFailure(at: attempt)
    return recovery
  }

  func resolveRecovery(
    _ id: UUID,
    in scope: SnipRecoveryScope,
    choice: SnipRecoveryChoice
  ) async throws -> SnipLibrarySnapshot {
    try await resolveRecovery(id, in: scope, choice: choice, expectation: nil)
  }

  func resolveRecovery(
    _ id: UUID,
    in scope: SnipRecoveryScope,
    choice: SnipRecoveryChoice,
    expectation: SnipRecoveryExpectation?
  ) async throws -> SnipLibrarySnapshot {
    let snapshot = try await persistence.managedResolveRecovery(
      id, in: scope, choice: choice, expectation: expectation)
    lastKnown = snapshot
    return snapshot
  }

  func previewTransferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot {
    try await persistence.managedPreviewTransferSnapshot(revision: revision)
  }

  func previewImport(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) async throws -> SnipImportPreview {
    try await persistence.managedPreviewImport(source, transitionID: transitionID)
  }

  func applyImport(_ preview: SnipImportPreview) async throws -> SnipImportResult {
    let result = try await persistence.managedApplyImport(preview)
    lastKnown = result.snapshot
    return result
  }
}
