import Foundation
import SnipSnapCore

/// Who may write the active store. `manifest.writeReservation` is the durable form of a
/// reserved writer; reopen clears it, so every persistence starts idle.
struct ActiveStoreWriteAdmission {
  fileprivate enum Request: Equatable {
    /// Managed edits, recovery resolution, and imports.
    case libraryWrite
    case cloudMutation(SyncModeActiveMutationLease.Purpose)
  }

  fileprivate enum Writer {
    case reserved(Request, SyncModeWriteReservation)
    /// Account isolation, empty activation, and discard swap the active store without a
    /// reservation.
    case storeReplacement
  }

  fileprivate struct QueuedWriter {
    let id: UUID
    let storeID: UUID
    let request: Request
    let continuation: CheckedContinuation<SyncModeWriteReservation, any Error>
  }

  fileprivate enum Phase {
    case idle
    case admitted(Writer, queue: [QueuedWriter])
    /// The writer finished, but its reservation clear did not reach disk. The next request
    /// that needs an idle store retries the clear.
    case releaseFailed(SyncModeWriteReservation)
    /// The writer was lost mid-write. Only a library read or reopen clears the reservation it
    /// left in the manifest.
    case abandoned
  }

  fileprivate var phase = Phase.idle

  init() {}
}

extension SwiftDataSyncModePersistence {
  package func activeLibrary() async throws -> any SnipLibrary {
    try clearLeftoverReservation()
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
    try await reserveMutation(storeID: storeID, request: .cloudMutation(purpose))
  }

  /// Whether no writer holds the active store. Retries a failed release first, so a
  /// transient storage failure does not keep refusing writes and mode changes.
  func writeAdmissionIsIdle() -> Bool {
    guard failedEnablePublicationInFlight == nil else { return false }
    if case .releaseFailed = writeAdmission.phase { try? clearReservation() }
    if case .idle = writeAdmission.phase { return true }
    return false
  }

  func beginStoreReplacement() throws {
    guard writeAdmissionIsIdle() else { throw SyncModePersistenceError.transitionInProgress }
    writeAdmission.phase = .admitted(.storeReplacement, queue: [])
  }

  func finishStoreReplacement() {
    guard case .admitted(.storeReplacement, let queue) = writeAdmission.phase else { return }
    writeAdmission.phase = .idle
    handOff(queue)
  }

  /// Writers waiting for admission, for tests that observe the queue.
  var queuedWriterCount: Int {
    guard case .admitted(_, let queue) = writeAdmission.phase else { return 0 }
    return queue.count
  }

  private func reserveMutation(
    storeID: UUID, request: ActiveStoreWriteAdmission.Request
  ) async throws -> SyncModeWriteReservation {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      guard storeID == manifest.activeStoreID else {
        throw SyncModePersistenceError.namespaceMismatch
      }
      guard case .admitted(let writer, let queue) = writeAdmission.phase else {
        return try reserveAvailableMutation(storeID: storeID, request: request)
      }
      if request == .libraryWrite {
        // A library write waits only behind normal sync.
        let reason = currentWriteBlockReason
        guard reason == .syncBusy else { throw blockedContentWrite(reason: reason) }
        diagnostics.record(.writeAdmission(.started, reason: .syncBusy))
      }
      return try await withCheckedThrowingContinuation { continuation in
        let waiter = ActiveStoreWriteAdmission.QueuedWriter(
          id: id, storeID: storeID, request: request, continuation: continuation)
        writeAdmission.phase = .admitted(writer, queue: queue + [waiter])
      }
    } onCancel: {
      Task { await self.cancelQueuedWriter(id) }
    }
  }

  private func reserveAvailableMutation(
    storeID: UUID,
    request: ActiveStoreWriteAdmission.Request,
    queue: [ActiveStoreWriteAdmission.QueuedWriter] = []
  ) throws -> SyncModeWriteReservation {
    let activeID = manifest.activeStoreID
    guard storeID == activeID else {
      throw SyncModePersistenceError.namespaceMismatch
    }
    switch request {
    case .cloudMutation:
      guard store(id: activeID)?.kind == .iCloudSync, manifest.accountIsolation == nil else {
        throw SyncModePersistenceError.namespaceMismatch
      }
      guard writeAdmissionIsIdle(), manifest.transition == nil
      else { throw SyncModePersistenceError.transitionInProgress }
    case .libraryWrite:
      guard writeAdmissionIsIdle() else {
        throw blockedContentWrite(reason: currentWriteBlockReason)
      }
      if let transition = manifest.transition,
        transition.sourceStoreID == activeID,
        transition.freezesSource
      { throw blockedContentWrite(reason: .modeChange) }
    }
    return try reserveRevision(for: request, queue: queue)
  }

  private func reserveRevision(
    for request: ActiveStoreWriteAdmission.Request,
    queue: [ActiveStoreWriteAdmission.QueuedWriter] = []
  ) throws -> SyncModeWriteReservation {
    let activeID = manifest.activeStoreID
    let index = try storeIndex(id: activeID)
    let revision = manifest.stores[index].revision + 1
    let reservation = SyncModeWriteReservation(
      id: UUID(),
      storeID: activeID,
      reservedRevision: revision
    )
    beginFailedEnableSourceWrite(storeID: activeID, reservedRevision: revision)
    var next = manifest
    next.stores[index].revision = revision
    next.writeReservation = reservation
    try commit(next)
    writeAdmission.phase = .admitted(.reserved(request, reservation), queue: queue)
    return reservation
  }

  /// Releases a reserved writer, or retries the clear its release could not commit.
  func finishActiveMutation(_ reservation: SyncModeWriteReservation) throws {
    switch writeAdmission.phase {
    case .admitted(.reserved(_, reservation), let queue):
      defer { handOff(queue) }
      do {
        try clearReservation()
      } catch {
        writeAdmission.phase = .releaseFailed(reservation)
        throw error
      }
    case .releaseFailed(reservation):
      try clearReservation()
    default:
      throw SyncModePersistenceError.transitionInProgress
    }
  }

  /// Leaves a lost writer's reservation for reopen or the next library read.
  private func abandonWriteAdmission(ifHeldBy reservation: SyncModeWriteReservation) {
    guard case .admitted(.reserved(_, reservation), let queue) = writeAdmission.phase else {
      return
    }
    writeAdmission.phase = .abandoned
    handOff(queue)
  }

  /// A library read may clear a reservation left by a failed release or a lost writer, but it
  /// cannot release admission held by an operation suspended on another actor.
  private func clearLeftoverReservation() throws {
    switch writeAdmission.phase {
    case .releaseFailed, .abandoned: try clearReservation()
    case .idle, .admitted: return
    }
  }

  private func clearReservation() throws {
    var next = manifest
    next.writeReservation = nil
    try commit(next)
    writeAdmission.phase = .idle
  }

  /// Grants the next reservation before returning to other actors. All live
  /// writers release here, so retained sync work needs no new event to continue.
  private func handOff(_ queue: [ActiveStoreWriteAdmission.QueuedWriter]) {
    var waiting = queue[...]
    while let next = waiting.popFirst() {
      do {
        let reservation = try reserveAvailableMutation(
          storeID: next.storeID, request: next.request, queue: Array(waiting))
        next.continuation.resume(returning: reservation)
        return
      } catch {
        next.continuation.resume(throwing: error)
      }
    }
  }

  private func cancelQueuedWriter(_ id: UUID) {
    guard case .admitted(let writer, var queue) = writeAdmission.phase,
      let index = queue.firstIndex(where: { $0.id == id })
    else { return }
    let cancelled = queue.remove(at: index)
    writeAdmission.phase = .admitted(writer, queue: queue)
    cancelled.continuation.resume(throwing: CancellationError())
  }

  private var currentWriteBlockReason: AppDiagnosticWriteReason {
    switch writeAdmission.phase {
    case .admitted(.storeReplacement, _), .admitted(.reserved(.cloudMutation(.modeChange), _), _):
      return .modeChange
    case .admitted(.reserved(.cloudMutation(.sync), _), let queue):
      return queue.contains { $0.request == .cloudMutation(.modeChange) } ? .modeChange : .syncBusy
    case .admitted(.reserved(.libraryWrite, _), _): return .writeBusy
    case .releaseFailed, .abandoned: return .reservedWrite
    case .idle: return .modeChange
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

  package func importInitialLocalSource(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) async throws -> SnipLibraryTransferResult {
    try await managedWrite { library in
      try await library.mergeTransferSnapshot(source, transitionID: transitionID)
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
    await reconcileFailedEnableOnOpen()
    if case .idle = writeAdmission.phase,
      failedEnablePublicationInFlight == nil, manifest.writeReservation == nil,
      let transition = manifest.transition,
      transition.sourceStoreID == manifest.activeStoreID, transition.freezesSource
    {
      try Task.checkCancellation()
      throw blockedContentWrite(reason: .modeChange)
    }
    await checkFailedEnableSourceBeforeWrite()
    let reservation = try await reserveMutation(
      storeID: manifest.activeStoreID, request: .libraryWrite)
    defer { abandonWriteAdmission(ifHeldBy: reservation) }
    try await writeHook(.afterRevisionReserved)
    do {
      try Task.checkCancellation()
      let value = try await operation(libraryForTransition(storeID: reservation.storeID))
      try await writeHook(.beforeReservationCleared)
      try finishActiveMutation(reservation)
      await completeFailedEnableSourceWrite(storeID: reservation.storeID)
      return value
    } catch {
      try? finishActiveMutation(reservation)
      throw error
    }
  }

  fileprivate func managedPreviewImport(
    _ source: SnipLibraryTransferSnapshot,
    transitionID: UUID
  ) async throws -> SnipImportPreview {
    guard writeAdmissionIsIdle(), manifest.transition == nil
    else { throw blockedContentWrite(reason: currentWriteBlockReason) }
    return try await libraryForTransition(storeID: manifest.activeStoreID)
      .previewImport(source, transitionID: transitionID)
  }

  fileprivate func managedPreviewTransferSnapshot(
    revision: UInt64
  ) async throws -> SnipLibraryTransferSnapshot {
    guard writeAdmissionIsIdle(), manifest.transition == nil
    else { throw blockedContentWrite(reason: currentWriteBlockReason) }
    return try await libraryForTransition(storeID: manifest.activeStoreID)
      .previewTransferSnapshot(revision: revision)
  }

  fileprivate func managedApplyImport(
    _ preview: SnipImportPreview
  ) async throws -> SnipImportResult {
    await reconcileFailedEnableOnOpen()
    if case .idle = writeAdmission.phase,
      failedEnablePublicationInFlight == nil, manifest.writeReservation == nil,
      manifest.transition != nil
    {
      throw blockedContentWrite(reason: .modeChange)
    }
    await checkFailedEnableSourceBeforeWrite()
    guard writeAdmissionIsIdle(), manifest.transition == nil
    else { throw blockedContentWrite(reason: currentWriteBlockReason) }
    let reservation = try reserveRevision(for: .libraryWrite)
    defer { abandonWriteAdmission(ifHeldBy: reservation) }
    try await writeHook(.afterRevisionReserved)
    do {
      let result = try await libraryForTransition(storeID: reservation.storeID)
        .applyImport(preview)
      try await writeHook(.beforeReservationCleared)
      try finishActiveMutation(reservation)
      await completeFailedEnableSourceWrite(storeID: reservation.storeID)
      return result
    } catch {
      try? finishActiveMutation(reservation)
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
