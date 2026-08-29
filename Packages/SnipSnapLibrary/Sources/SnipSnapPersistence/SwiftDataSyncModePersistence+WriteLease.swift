import Foundation
import SnipSnapCore

extension SwiftDataSyncModePersistence {
  package func activeLibrary() async throws -> any SnipLibrary {
    try reconcileWriteReservation()
    let initial = try await managedSnapshot(sortedBy: .chronological)
    return ModeManagedSnipLibrary(persistence: self, lastKnown: initial)
  }

  package func activeCloudMutationLease(storeID: UUID) throws -> SyncModeActiveMutationLease {
    guard storeID == manifest.activeStoreID, store(id: storeID)?.kind == .iCloudSync else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    return SyncModeActiveMutationLease(persistence: self, storeID: storeID)
  }

  package func reserveActiveMutation(storeID: UUID? = nil) throws -> SyncModeWriteReservation {
    guard !writeAdmissionInProgress, manifest.writeReservation == nil,
      manifest.transition == nil
    else { throw SyncModePersistenceError.transitionInProgress }
    let activeID = manifest.activeStoreID
    guard storeID == nil || storeID == activeID else {
      throw SyncModePersistenceError.namespaceMismatch
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
    return reservation
  }

  package func finishActiveMutation(_ reservation: SyncModeWriteReservation) throws {
    guard manifest.writeReservation == reservation else {
      throw SyncModePersistenceError.transitionInProgress
    }
    var next = manifest
    next.writeReservation = nil
    try commit(next)
  }

  fileprivate func managedSnapshot(sortedBy: SnipSortMode) async throws -> SnipLibrarySnapshot {
    try readHook()
    return try await libraryForTransition(storeID: manifest.activeStoreID)
      .checkedSnapshot(sortedBy: sortedBy)
  }

  fileprivate func managedPerform(
    _ command: SnipLibraryCommand,
    sortedBy: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    guard !writeAdmissionInProgress, manifest.writeReservation == nil else {
      throw SnipLibraryError.modeTransitionInProgress
    }
    if let transition = manifest.transition,
      transition.sourceStoreID == manifest.activeStoreID,
      [
        .sourceFrozen, .recordsMerged, .enrollmentApproved, .firstSendStarted,
        .firstSendComplete,
      ].contains(transition.phase)
    { throw SnipLibraryError.modeTransitionInProgress }
    writeAdmissionInProgress = true
    defer { writeAdmissionInProgress = false }
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
      let update = try await libraryForTransition(storeID: activeID)
        .perform(command, sortedBy: sortedBy)
      try await writeHook(.beforeReservationCleared)
      var completed = manifest
      completed.writeReservation = nil
      try commit(completed)
      return update
    } catch {
      guard error is SnipLibraryError || error is SyncModePersistenceError else {
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
    else { throw SnipLibraryError.modeTransitionInProgress }
    return try await libraryForTransition(storeID: manifest.activeStoreID)
      .previewImport(source, transitionID: transitionID)
  }

  fileprivate func managedApplyImport(
    _ preview: SnipImportPreview
  ) async throws -> SnipImportResult {
    guard !writeAdmissionInProgress, manifest.writeReservation == nil,
      manifest.transition == nil
    else { throw SnipLibraryError.modeTransitionInProgress }
    writeAdmissionInProgress = true
    defer { writeAdmissionInProgress = false }
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

  fileprivate func recordStoreReadFailure() {
    try? recordAttention(.storeReadFailed)
  }
  private func reconcileWriteReservation() throws {
    guard manifest.writeReservation != nil else { return }
    var next = manifest
    next.writeReservation = nil
    try commit(next)
  }

}

private actor ModeManagedSnipLibrary: SnipLibrary {
  let persistence: SwiftDataSyncModePersistence
  private var lastKnown: SnipLibrarySnapshot

  init(persistence: SwiftDataSyncModePersistence, lastKnown: SnipLibrarySnapshot) {
    self.persistence = persistence
    self.lastKnown = lastKnown
  }

  func snapshot(sortedBy sortMode: SnipSortMode) async -> SnipLibrarySnapshot {
    do {
      return try await checkedSnapshot(sortedBy: sortMode)
    } catch {
      return lastKnown
    }
  }

  func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot {
    do {
      let snapshot = try await persistence.managedSnapshot(sortedBy: sortMode)
      lastKnown = snapshot
      return snapshot
    } catch {
      await persistence.recordStoreReadFailure()
      throw error
    }
  }

  func perform(
    _ command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    let update = try await persistence.managedPerform(command, sortedBy: sortMode)
    lastKnown = update.snapshot
    return update
  }

  func transferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot {
    throw SnipLibraryError.transferUnsupported
  }

  func mergeTransferSnapshot(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) async throws -> SnipLibraryTransferResult {
    throw SnipLibraryError.transferUnsupported
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
