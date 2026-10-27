import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  package func activeLibrary() async throws -> any SnipLibrary {
    try reconcileWriteReservation()
    let initial = try await managedSnapshot(sortedBy: .chronological)
    return ModeManagedSnipLibrary(persistence: self, fallback: nil, lastKnown: initial)
  }

  nonisolated package func activeLibrary(
    fallback: any SnipLibrary
  ) -> any SnipLibrary {
    ModeManagedSnipLibrary(persistence: self, fallback: fallback, lastKnown: nil)
  }

  package func activeCloudMutationLease(
    storeID: UUID, purpose: SyncModeActiveMutationLease.Purpose = .sync
  ) throws -> SyncModeActiveMutationLease {
    guard storeID == manifest.activeStoreID, store(id: storeID)?.kind == .iCloudSync else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    return SyncModeActiveMutationLease(persistence: self, storeID: storeID, purpose: purpose)
  }

  func reserveActiveMutation(
    storeID: UUID, purpose: SyncModeActiveMutationLease.Purpose
  ) async throws -> SyncModeWriteReservation {
    try await reserveMutation(storeID: storeID, admission: .cloud(purpose))
  }

  private func reserveMutation(
    storeID: UUID, admission: WriteAdmission
  ) async throws -> SyncModeWriteReservation {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      guard storeID == manifest.activeStoreID else {
        throw SyncModePersistenceError.namespaceMismatch
      }
      if !writeAdmissionInProgress {
        return try reserveAvailableMutation(storeID: storeID, admission: admission)
      }
      if admission == .exclusive {
        guard writeAdmission == .cloud(.sync),
          !activeMutationWaiters.contains(where: { $0.admission == .cloud(.modeChange) })
        else { throw blockedContentWrite(reason: currentWriteBlockReason) }
        diagnostics.record(.writeAdmission(.started, reason: .syncBusy))
      }
      return try await withCheckedThrowingContinuation { continuation in
        activeMutationWaiters.append(ActiveMutationWaiter(
          id: id, storeID: storeID, admission: admission, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelActiveMutationWaiter(id) }
    }
  }

  private func reserveAvailableMutation(
    storeID: UUID, admission: WriteAdmission
  ) throws -> SyncModeWriteReservation {
    let activeID = manifest.activeStoreID
    guard storeID == activeID else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    switch admission {
    case .cloud:
      guard store(id: activeID)?.kind == .iCloudSync, manifest.accountIsolation == nil else {
        throw SyncModePersistenceError.namespaceMismatch
      }
      guard !writeAdmissionInProgress, manifest.writeReservation == nil,
        manifest.transition == nil
      else { throw SyncModePersistenceError.transitionInProgress }
    case .exclusive, .modeChange:
      guard !writeAdmissionInProgress, manifest.writeReservation == nil else {
        throw blockedContentWrite(reason: currentWriteBlockReason)
      }
      if let transition = manifest.transition,
        transition.sourceStoreID == activeID,
        [.sourceFrozen, .recordsMerged, .enrollmentApproved, .firstSendStarted,
          .firstSendComplete].contains(transition.phase)
      { throw blockedContentWrite(reason: .modeChange) }
    }
    let revision = manifest.stores[try storeIndex(id: activeID)].revision + 1
    let reservation = SyncModeWriteReservation(
      id: UUID(),
      storeID: activeID,
      reservedRevision: revision
    )
    var next = manifest
    next.stores[try storeIndex(id: activeID)].revision = revision
    next.writeReservation = reservation
    try commit(next)
    writeAdmission = admission
    return reservation
  }

  func finishActiveMutation(_ reservation: SyncModeWriteReservation) throws {
    guard manifest.writeReservation == reservation else {
      throw SyncModePersistenceError.transitionInProgress
    }
    defer { releaseWriteAdmission() }
    var next = manifest
    next.writeReservation = nil
    try commit(next)
  }

  /// Grants the next reservation before returning to other actors. All live
  /// writers release here, so retained sync work needs no new event to continue.
  func releaseWriteAdmission() {
    writeAdmission = nil
    while !activeMutationWaiters.isEmpty {
      let next = activeMutationWaiters.removeFirst()
      do {
        let reservation = try reserveAvailableMutation(storeID: next.storeID, admission: next.admission)
        next.continuation.resume(returning: reservation)
        return
      } catch {
        next.continuation.resume(throwing: error)
      }
    }
  }

  private func cancelActiveMutationWaiter(_ id: UUID) {
    guard let index = activeMutationWaiters.firstIndex(where: { $0.id == id }) else { return }
    activeMutationWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  private var currentWriteBlockReason: AppDiagnosticWriteReason {
    switch writeAdmission {
    case .modeChange, .cloud(.modeChange): return .modeChange
    case .cloud(.sync):
      return activeMutationWaiters.contains { $0.admission == .cloud(.modeChange) }
        ? .modeChange : .syncBusy
    case .exclusive: return .writeBusy
    case nil:
      return manifest.writeReservation != nil ? .reservedWrite : .modeChange
    }
  }

  private func blockedContentWrite(reason: AppDiagnosticWriteReason) -> SnipLibraryError {
    diagnostics.record(.writeAdmission(.failed, reason: reason))
    return .modeTransitionInProgress
  }

  fileprivate func managedSnapshot(sortedBy: SnipSortMode) async throws -> SnipLibrarySnapshot {
    await finishRecoveryQuarantines()
    try await readHook()
    return try await libraryForTransition(storeID: manifest.activeStoreID)
      .checkedSnapshot(sortedBy: sortedBy)
  }

  fileprivate func managedArchive() async throws -> SnipLibraryArchive {
    await finishRecoveryQuarantines()
    try await readHook()
    return try await libraryForTransition(storeID: manifest.activeStoreID).archive()
  }

  fileprivate func managedRecoverySnapshot(
    in scope: SnipRecoveryScope
  ) async throws -> SnipRecoverySnapshot {
    await finishRecoveryQuarantines()
    try await readHook()
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
    _ operation: @Sendable (SwiftDataSnipLibrary) async throws -> Value
  ) async throws -> Value {
    await finishRecoveryQuarantines()
    let reservation = try await reserveMutation(storeID: manifest.activeStoreID, admission: .exclusive)
    defer { releaseWriteAdmission() }
    try await writeHook(.afterRevisionReserved)
    do {
      try Task.checkCancellation()
      let value = try await operation(libraryForTransition(storeID: reservation.storeID))
      try await writeHook(.beforeReservationCleared)
      var completed = manifest
      completed.writeReservation = nil
      try commit(completed)
      return value
    } catch {
      guard error is SnipLibraryError || error is SyncModePersistenceError || error is CancellationError else {
        // Test crash hooks model process loss. Leave the durable reservation for reopen.
        throw error
      }
      var cleared = manifest
      cleared.writeReservation = nil
      try? commit(cleared)
      throw error
    }
  }

  fileprivate func managedPreviewImport(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) async throws -> SnipImportPreview {
    guard !writeAdmissionInProgress, manifest.writeReservation == nil,
      manifest.transition == nil
    else { throw blockedContentWrite(reason: currentWriteBlockReason) }
    return try await libraryForTransition(storeID: manifest.activeStoreID)
      .previewImport(source, transitionID: transitionID)
  }

  fileprivate func managedPreviewTransferSnapshot(
    revision: UInt64
  ) async throws -> SnipLibraryTransferSnapshot {
    guard !writeAdmissionInProgress, manifest.writeReservation == nil,
      manifest.transition == nil
    else { throw blockedContentWrite(reason: currentWriteBlockReason) }
    return try await libraryForTransition(storeID: manifest.activeStoreID)
      .previewTransferSnapshot(revision: revision)
  }

  fileprivate func managedApplyImport(
    _ preview: SnipImportPreview
  ) async throws -> SnipImportResult {
    guard !writeAdmissionInProgress, manifest.writeReservation == nil,
      manifest.transition == nil
    else { throw blockedContentWrite(reason: currentWriteBlockReason) }
    writeAdmission = .exclusive
    defer { releaseWriteAdmission() }
    let activeID = manifest.activeStoreID
    let reservedRevision = manifest.stores[try storeIndex(id: activeID)].revision + 1
    var reserved = manifest
    reserved.stores[try storeIndex(id: activeID)].revision = reservedRevision
    reserved.writeReservation = SyncModeWriteReservation(
      id: UUID(),
      storeID: activeID,
      reservedRevision: reservedRevision
    )
    try commit(reserved)
    try await writeHook(.afterRevisionReserved)
    do {
      let result = try await libraryForTransition(storeID: activeID).applyImport(preview)
      try await writeHook(.beforeReservationCleared)
      var completed = manifest
      completed.writeReservation = nil
      try commit(completed)
      return result
    } catch {
      guard error is SnipLibraryError || error is SyncModePersistenceError else {
        throw error
      }
      var cleared = manifest
      cleared.writeReservation = nil
      try? commit(cleared)
      throw error
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
  private func reconcileWriteReservation() throws {
    // A library read may recover an abandoned reservation, but it cannot release
    // admission held by an operation suspended on another actor.
    guard !writeAdmissionInProgress, manifest.writeReservation != nil else { return }
    var next = manifest
    next.writeReservation = nil
    try commit(next)
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
