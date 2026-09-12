import Foundation
import SnipSnapCore
import SnipSnapPersistence

package enum CloudFullSyncStatus: Sendable {
  case pending
  case settled
  case issue(SyncedContentSyncIssue)
  case purged
}

package protocol CloudFullSyncStore: Sendable {
  func loadEngineState() async throws -> CloudEngineStateEnvelope?
  func saveEngineState(_ state: CloudEngineStateEnvelope) async throws
  func clearEngineState() async throws
  func stagedBatches() async throws -> [CloudFullBatchCommit]
  func stage(_ batch: CloudSyncBatch, outbound: CloudOutboundBatch?) async throws
  func applyStaged(_ id: UUID) async throws
  func pendingChanges() async throws -> CloudOutboundBatch
  func outboundAdmission() async throws -> CloudRecordOutboundAdmission
  func syncStatus() async throws -> CloudFullSyncStatus
  func destructiveResetSignal() async throws -> CloudZoneDeletionReason?
  func prepareManualRetry() async throws -> Bool
}

package extension CloudFullSyncStore {
  func outboundAdmission() async throws -> CloudRecordOutboundAdmission {
    CloudRecordOutboundAdmission(blocksAll: try await destructiveResetSignal() != nil)
  }
}

package struct CloudFullSyncOutcome: Sendable {
  package let issue: SyncedContentSyncIssue?
  package let blocksOutbound: Bool
  package let result: SnipSnapCloudSyncResult
}

/// Owns commit order, checkpoint durability, and the outcome of each request.
package actor CloudFullSyncCoordinator {
  private struct RunState {
    var fetched = false
    var processedEvents = false
    var fetchIssue: SyncedContentSyncIssue?
    var sendIssue: SyncedContentSyncIssue?
    var blocksOutbound = false
    var resetEngine = false

    var issue: SyncedContentSyncIssue? {
      CloudSyncIssueError.preferredIssue(from: [fetchIssue, sendIssue].compactMap { $0 })
    }
  }

  private let store: any CloudFullSyncStore
  private let transport: any CloudRecordTransport
  private let fetchScope: CloudFetchScope
  private let reportResult: @Sendable (SnipSnapCloudSyncResult) async throws -> Void
  private var started = false
  private let operationGate = AsyncOperationGate()
  private var requiresInitialFetch = true

  package init(
    store: any CloudFullSyncStore,
    transport: any CloudRecordTransport,
    fetchScope: CloudFetchScope = .all,
    reportResult: @escaping @Sendable (SnipSnapCloudSyncResult) async throws -> Void = { _ in }
  ) {
    self.store = store
    self.transport = transport
    self.fetchScope = fetchScope
    self.reportResult = reportResult
  }

  @discardableResult
  package func sync() async throws -> CloudFullSyncOutcome {
    try await run(fetch: true, send: true, beforeApply: {}, beforeSend: { _ in })
  }

  @discardableResult
  package func fetchRemote(
    beforeApply: @escaping @Sendable () async throws -> Void = {}
  ) async throws -> CloudFullSyncOutcome {
    try await run(fetch: true, send: false, beforeApply: beforeApply, beforeSend: { _ in })
  }

  @discardableResult
  package func sendPending(
    beforeApply: @escaping @Sendable () async throws -> Void = {},
    beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void = { _ in }
  ) async throws -> CloudFullSyncOutcome {
    try await run(fetch: false, send: true, beforeApply: beforeApply, beforeSend: beforeSend)
  }

  @discardableResult
  package func prepareAutomaticSync(
    beforeApply: @escaping @Sendable () async throws -> Void = {},
    beforeStateSave: @escaping @Sendable () async throws -> Void = {}
  ) async throws -> CloudFullSyncOutcome {
    guard transport is any CloudAutomaticSyncScheduling else {
      return try await run(fetch: true, send: true, beforeApply: beforeApply,
        beforeSend: { _ in try await beforeApply() })
    }
    return try await automaticWork(beforeApply: beforeApply, beforeStateSave: beforeStateSave,
      schedulingRequest: true)
  }

  @discardableResult
  package func processAutomaticChanges(
    beforeApply: @escaping @Sendable () async throws -> Void = {},
    beforeStateSave: @escaping @Sendable () async throws -> Void = {}
  ) async throws -> CloudFullSyncOutcome {
    try await automaticWork(beforeApply: beforeApply, beforeStateSave: beforeStateSave,
      schedulingRequest: false)
  }

  package func prepareManualRetry(
    beforeApply: @escaping @Sendable () async throws -> Void = {},
    beforeStateSave: @escaping @Sendable () async throws -> Void = {}
  ) async throws {
    try await operationGate.withLease {
      try await self.prepareManualRetrySerially(beforeApply: beforeApply, beforeStateSave: beforeStateSave)
    }
  }

  private func prepareManualRetrySerially(
    beforeApply: @escaping @Sendable () async throws -> Void,
    beforeStateSave: @escaping @Sendable () async throws -> Void
  ) async throws {
    try await transport.finishCurrentSyncCycle()
    try await recoverStaged(beforeApply: beforeApply)
    var state = RunState()
    try await drainEvents(state: &state, beforeApply: beforeApply, beforeStateSave: beforeStateSave)
    try await beforeApply()
    if try await store.prepareManualRetry() {
      // A failed record may not change again. Drop its token so Try Again fetches it.
      try await beforeStateSave()
      try await store.clearEngineState()
      await transport.reset()
      started = false
      requiresInitialFetch = true
    }
  }

  private func automaticWork(
    beforeApply: @escaping @Sendable () async throws -> Void,
    beforeStateSave: @escaping @Sendable () async throws -> Void,
    schedulingRequest: Bool
  ) async throws -> CloudFullSyncOutcome {
    try await operationGate.withLease {
      try await self.automaticWorkSerially(beforeApply: beforeApply, beforeStateSave: beforeStateSave, schedulingRequest: schedulingRequest)
    }
  }

  private func automaticWorkSerially(
    beforeApply: @escaping @Sendable () async throws -> Void,
    beforeStateSave: @escaping @Sendable () async throws -> Void,
    schedulingRequest: Bool
  ) async throws -> CloudFullSyncOutcome {
    var state = RunState()
    do {
      try await recoverStaged(beforeApply: beforeApply)
      try await drainEvents(state: &state, beforeApply: beforeApply, beforeStateSave: beforeStateSave)
      if !schedulingRequest, !state.processedEvents { return try await outcome(for: state) }
      try await ensureStarted()
      if !state.blocksOutbound, !requiresInitialFetch {
        try await schedulePendingChanges(beforeSchedule: beforeStateSave)
      }
      let outcome = try await outcome(for: state)
      try await reportResult(outcome.result)
      return outcome
    } catch {
      try? await reportResult(automaticSyncResult(for: error))
      throw error
    }
  }

  private func run(
    fetch: Bool,
    send: Bool,
    beforeApply: @escaping @Sendable () async throws -> Void,
    beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void
  ) async throws -> CloudFullSyncOutcome {
    try await operationGate.withLease {
      try await self.runSerially(fetch: fetch, send: send, beforeApply: beforeApply, beforeSend: beforeSend)
    }
  }

  private func runSerially(
    fetch: Bool,
    send: Bool,
    beforeApply: @escaping @Sendable () async throws -> Void,
    beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void
  ) async throws -> CloudFullSyncOutcome {
    var state = RunState()
    try await transport.finishCurrentSyncCycle()
    try await recoverStaged(beforeApply: beforeApply)
    try await drainEvents(state: &state, beforeApply: beforeApply, beforeStateSave: beforeApply)
    try await ensureStarted()
    if fetch || (send && requiresInitialFetch) {
      let fetched = try await transport.fetch(scope: fetch ? fetchScope : .all)
      try await applyReturned(.fetched(fetched), outbound: nil, state: &state, beforeApply: beforeApply)
      if state.resetEngine {
        state.resetEngine = false
        try await ensureStarted()
        let retry = try await transport.fetch(scope: .all)
        try await applyReturned(.fetched(retry), outbound: nil, state: &state, beforeApply: beforeApply)
      }
    }
    if send, !state.blocksOutbound, !requiresInitialFetch {
      let outbound = try await pendingChangesOrResetEngine()
      if !outbound.operations.isEmpty || !outbound.zonesToSave.isEmpty {
        try await beforeSend(outbound)
        let sent = try await transport.send(outbound)
        try await applyReturned(.sent(sent), outbound: outbound, state: &state, beforeApply: beforeApply)
      }
    }
    try await drainEvents(state: &state, beforeApply: beforeApply, beforeStateSave: beforeApply)
    return try await outcome(for: state, includeStoredStatus: false)
  }

  private func ensureStarted() async throws {
    guard !started else { return }
    let state: CloudEngineStateEnvelope?
    do {
      state = try await store.loadEngineState()
    } catch CloudTransportError.invalidEngineState {
      try await restartEmptyEngine()
      return
    } catch CloudTransportError.stateNamespaceMismatch {
      try await restartEmptyEngine()
      return
    }
    requiresInitialFetch = state == nil || state?.requiresInitialFetch == true
    let outbound = requiresInitialFetch ? nil : try await pendingChangesOrResetEngine()
    do {
      let admission = try await store.outboundAdmission()
      try await transport.start(state: requiresInitialFetch ? nil : state, initialOutbound: outbound,
        outboundAdmission: admission)
    } catch CloudTransportError.invalidEngineState {
      try await restartEmptyEngine()
      return
    } catch CloudTransportError.stateNamespaceMismatch {
      try await restartEmptyEngine()
      return
    }
    started = true
  }

  private func restartEmptyEngine() async throws {
    try await store.clearEngineState()
    try await transport.start(state: nil, initialOutbound: nil,
      outboundAdmission: store.outboundAdmission())
    started = true
    requiresInitialFetch = true
  }

  private func recoverStaged(beforeApply: @escaping @Sendable () async throws -> Void) async throws {
    let staged = try await store.stagedBatches()
    if !staged.isEmpty { try await beforeApply() }
    for batch in staged {
      try await store.applyStaged(batch.batchID)
      if await transport.pendingEvent()?.id == batch.batchID {
        try await transport.confirmApplied(batch.batchID, outboundAdmission: store.outboundAdmission())
      }
    }
    if !staged.isEmpty, let state = try await store.loadEngineState() {
      requiresInitialFetch = state.requiresInitialFetch
    }
  }

  @discardableResult
  private func drainEvents(
    through lastID: UUID? = nil,
    state: inout RunState,
    beforeApply: @escaping @Sendable () async throws -> Void,
    beforeStateSave: @escaping @Sendable () async throws -> Void
  ) async throws -> Bool {
    while let event = await transport.pendingEvent() {
      switch event {
      case .accountChange:
        try await beforeApply()
        try await transport.confirmApplied(event.id)
      case .checkpoint(_, let checkpoint):
        try await beforeStateSave()
        try await store.saveEngineState(checkpoint)
        requiresInitialFetch = checkpoint.requiresInitialFetch
        try await transport.confirmApplied(event.id)
      case .batch(let pending):
        try await beforeApply()
        try await commit(pending.batch, outbound: pending.outbound, state: &state)
      }
      state.processedEvents = true
      if event.id == lastID { return true }
    }
    return false
  }

  private func applyReturned(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?,
    state: inout RunState,
    beforeApply: @escaping @Sendable () async throws -> Void
  ) async throws {
    // Adapters may return a batch directly while queuing earlier checkpoints.
    let committed = try await drainEvents(through: batch.id, state: &state,
      beforeApply: beforeApply, beforeStateSave: beforeApply)
    if !committed {
      try await beforeApply()
      try await commit(batch, outbound: outbound, state: &state)
      state.processedEvents = true
    }
  }

  private func commit(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?,
    state: inout RunState
  ) async throws {
    try await store.stage(batch, outbound: outbound)
    try await store.applyStaged(batch.id)
    try await transport.confirmApplied(batch.id, outboundAdmission: store.outboundAdmission())
    if CloudSyncIssueError.requiresEngineReset(batch) {
      try await store.clearEngineState()
      await transport.reset()
      started = false
      requiresInitialFetch = true
      state.resetEngine = true
      return
    }
    let issue = CloudSyncIssueError.issue(in: batch)
    switch batch {
    case .fetched:
      state.fetched = true
      state.fetchIssue = issue
      if !CloudSyncIssueError.blocksOutbound(in: batch), batch.engineState?.requiresInitialFetch == false {
        requiresInitialFetch = false
      }
    case .sent(let sent):
      if sent.hasResults { state.sendIssue = issue }
    }
    state.blocksOutbound = state.blocksOutbound || CloudSyncIssueError.blocksOutbound(in: batch)
  }

  private func outcome(
    for state: RunState,
    includeStoredStatus: Bool = true
  ) async throws -> CloudFullSyncOutcome {
    let stored: CloudFullSyncStatus
    if includeStoredStatus {
      stored = try await store.syncStatus()
    } else {
      stored = try await store.destructiveResetSignal() == nil ? .pending : .purged
    }
    let issue: SyncedContentSyncIssue?
    let result: SnipSnapCloudSyncResult
    switch stored {
    case .purged:
      issue = nil
      result = .iCloudDataReset
    case .issue(let storedIssue):
      issue = storedIssue
      result = .syncIssue(storedIssue)
    case .pending, .settled:
      issue = state.issue
      if let issue {
        result = .syncIssue(issue)
      } else if case .settled = stored, !requiresInitialFetch {
        result = .syncCompleted
      } else if state.fetched {
        result = .contentUpdated
      } else {
        result = .syncScheduled
      }
    }
    return CloudFullSyncOutcome(issue: issue,
      blocksOutbound: state.blocksOutbound || requiresInitialFetch || result == .iCloudDataReset,
      result: result)
  }

  private func schedulePendingChanges(beforeSchedule: @Sendable () async throws -> Void) async throws {
    guard let scheduler = transport as? any CloudAutomaticSyncScheduling else { return }
    let outbound = try await pendingChangesOrResetEngine()
    try await beforeSchedule()
    try await scheduler.scheduleAutomaticSync(outbound)
  }

  private func pendingChangesOrResetEngine() async throws -> CloudOutboundBatch {
    do { return try await store.pendingChanges() }
    catch is CloudRecordError {
      try await store.clearEngineState()
      await transport.reset()
      started = false
      requiresInitialFetch = true
      throw CloudSyncRetryableError.itemFailure
    }
  }


}

package actor CloudFullSyncPersistence: CloudFullSyncStore {
  package typealias ApplyHook = @Sendable () async throws -> Void

  struct RawStagedBatch: Codable, Equatable, Sendable {
    let storageVersion: Int
    let batch: CloudSyncBatch
    let outbound: CloudOutboundBatch?

    init(batch: CloudSyncBatch, outbound: CloudOutboundBatch?) {
      storageVersion = 1
      self.batch = batch
      self.outbound = outbound
    }
  }

  let library: SwiftDataSnipLibrary
  let namespace: CloudSyncNamespace
  let dataZone: CloudZoneID
  let payloadZone: CloudZoneID?
  let attachmentPolicy: CloudAttachmentCompatibilityPolicy
  let namespaceKey: CloudSyncNamespaceKey
  let now: @Sendable () -> Date
  let afterCommitHook: ApplyHook
  private var observedDestructiveReset: CloudZoneDeletionReason?
  private let mutationLease: SyncModeActiveMutationLease?

  package init(
    library: SwiftDataSnipLibrary,
    namespace: CloudSyncNamespace,
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID? = nil,
    mutationLease: SyncModeActiveMutationLease? = nil,
    attachmentPolicy: CloudAttachmentCompatibilityPolicy = .openSourceDefault,
    now: @escaping @Sendable () -> Date = Date.init,
    afterCommitHook: @escaping ApplyHook = {}
  ) {
    precondition(namespace.zones.contains(dataZone))
    precondition(payloadZone.map(namespace.zones.contains) ?? true)
    self.library = library
    self.namespace = namespace
    self.dataZone = dataZone
    self.payloadZone = payloadZone
    self.mutationLease = mutationLease
    self.attachmentPolicy = attachmentPolicy
    self.now = now
    self.afterCommitHook = afterCommitHook
    namespaceKey = namespace.namespaceKey
  }
}

extension CloudFullSyncPersistence {
  func mutate<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    if let mutationLease { return try await mutationLease.run(operation) }
    return try await operation()
  }

  package func loadEngineState() async throws -> CloudEngineStateEnvelope? {
    let stored = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey).engineState
    guard let stored else { return nil }
    let value: CloudEngineStateEnvelope
    do {
      value = try JSONDecoder().decode(CloudEngineStateEnvelope.self, from: stored)
    } catch {
      throw CloudTransportError.invalidEngineState
    }
    guard value.namespace == namespace else { throw CloudTransportError.stateNamespaceMismatch }
    return value
  }

  package func saveEngineState(_ state: CloudEngineStateEnvelope) async throws {
    try await mutate { try await self.saveEngineStateWithinMutation(state) }
  }

  private func saveEngineStateWithinMutation(_ state: CloudEngineStateEnvelope) async throws {
    guard state.namespace == namespace else {
      throw CloudTransportError.stateNamespaceMismatch
    }
    try await library.saveCloudEngineState(
      namespaceKey: namespaceKey,
      envelopeData: JSONEncoder().encode(state)
    )
  }

  package func clearEngineState() async throws {
    try await mutate { try await self.clearEngineStateWithinMutation() }
  }

  private func clearEngineStateWithinMutation() async throws {
    try await library.clearCloudEngineState(namespaceKey: namespaceKey)
  }

  package func stagedBatches() async throws -> [CloudFullBatchCommit] {
    try await library.stagedCloudFullBatches(namespaceKey: namespaceKey)
  }

  package func applyStaged(_ id: UUID) async throws {
    try await mutate { try await self.applyStagedWithinMutation(id) }
  }

  private func applyStagedWithinMutation(_ id: UUID) async throws {
    guard let batch = try await stagedBatches().first(where: { $0.batchID == id }) else { return }
    if let rawData = batch.rawBatchData,
      let raw = try? JSONDecoder().decode(RawStagedBatch.self, from: rawData),
      let reason = Self.destructiveResetReason(raw.batch)
    {
      observedDestructiveReset = reason
    }
    do {
      _ = try await library.commitCloudFullBatch(batch)
      try await clearRecoveredFailure(in: batch)
      try await afterCommitHook()
    } catch CloudFullStorageError.staleLocalEntity {
      guard let rawData = batch.rawBatchData else { throw CloudFullStorageError.staleLocalEntity }
      let raw = try JSONDecoder().decode(RawStagedBatch.self, from: rawData)
      guard raw.storageVersion == 1, raw.batch.id == id else {
        throw CloudFullStorageError.invalidBatchReplay
      }
      let replacement = try await makeCommit(
        raw.batch,
        outbound: raw.outbound,
        rawBatchData: rawData
      )
      try await library.replaceStagedCloudFullBatch(replacement)
      _ = try await library.commitCloudFullBatch(replacement)
      try await clearRecoveredFailure(in: replacement)
      try await afterCommitHook()
    }
  }

  private func clearRecoveredFailure(in batch: CloudFullBatchCommit) async throws {
    guard let rawData = batch.rawBatchData,
      let raw = try? JSONDecoder().decode(RawStagedBatch.self, from: rawData),
      CloudSyncIssueError.issue(in: raw.batch) == nil,
      Self.destructiveResetReason(raw.batch) == nil
    else { return }
    switch raw.batch {
    case .fetched: _ = try await clearRetryableRecoveryEvents(kind: .retryableFetch)
    case .sent(let sent):
      if sent.hasResults { _ = try await clearRetryableRecoveryEvents(kind: .retryableSend) }
    }
  }

  package func syncStatus() async throws -> CloudFullSyncStatus {
    if try await destructiveResetSignal() != nil { return .purged }
    if let issue = try await unresolvedSyncIssue() { return .issue(issue) }
    return try await isSyncSettled() ? .settled : .pending
  }

  package func stage(_ batch: CloudSyncBatch) async throws {
    try await stage(batch, outbound: nil)
  }

  package func stage(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?
  ) async throws {
    try await mutate { try await self.stageWithinMutation(batch, outbound: outbound) }
  }

  private func stageWithinMutation(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?
  ) async throws {
    do {
      try validateResetScope(batch)
      if let reason = Self.destructiveResetReason(batch) {
        observedDestructiveReset = reason
      }
      let rawData = try Self.rawBatchData(batch, outbound: outbound)
      let commit = try await makeCommit(batch, outbound: outbound, rawBatchData: rawData)
      try await library.stageCloudFullBatch(commit)
    } catch CloudTransportError.invalidRecord {
      if case .sent(let sent) = batch, let outbound {
        try await library.recordCloudFullRecovery(
          Self.malformedSentRecovery(
            sent: sent,
            outbound: outbound,
            namespaceKey: namespaceKey
          )
        )
      }
      throw CloudTransportError.invalidRecord
    }
  }

  private func validateResetScope(_ batch: CloudSyncBatch) throws {
    if let state = batch.engineState, state.namespace != namespace {
      throw CloudTransportError.stateNamespaceMismatch
    }
    let events = switch batch {
    case .fetched(let fetched): fetched.databaseEvents
    case .sent(let sent): sent.databaseEvents
    }
    for event in events {
      if case .zoneDeleted(let zone, let reason) = event,
        reason != .deleted, !namespace.zones.contains(zone)
      {
        throw CloudTransportError.stateNamespaceMismatch
      }
    }
  }

  package func destructiveResetSignal() async throws -> CloudZoneDeletionReason? {
    if let observedDestructiveReset {
      self.observedDestructiveReset = nil
      return observedDestructiveReset
    }
    for recovery in try await library.cloudFullRecoveryEvents(namespaceKey: namespaceKey)
      where recovery.kind == .destructiveReset
    {
      let raw = try JSONDecoder().decode(RawStagedBatch.self, from: recovery.resultData)
      guard raw.storageVersion == 1 else { throw CloudFullStorageError.invalidBatchReplay }
      if let reason = Self.destructiveResetReason(raw.batch) { return reason }
    }
    return nil
  }

  private static func destructiveResetReason(
    _ batch: CloudSyncBatch
  ) -> CloudZoneDeletionReason? {
    let events: [CloudDatabaseEvent] = switch batch {
    case .fetched(let fetched): fetched.databaseEvents
    case .sent(let sent): sent.databaseEvents
    }
    for event in events {
      guard case .zoneDeleted(_, let reason) = event else { continue }
      switch reason {
      case .purged, .encryptedDataReset:
        return reason
      case .deleted:
        continue
      }
    }
    return nil
  }

  static func rawBatchData(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(RawStagedBatch(batch: batch, outbound: outbound))
  }

  static func storedSyncIssue(
    for recovery: CloudFullRecoveryInput
  ) -> SyncedContentSyncIssue {
    switch recovery.kind {
    case .retryableFetch, .terminalFetch, .retryableSend, .terminalSend:
      guard let raw = try? JSONDecoder().decode(RawStagedBatch.self, from: recovery.resultData),
        raw.storageVersion == 1
      else { return .appDataIssue }
      return CloudSyncIssueError.issue(in: raw.batch)
        ?? (recovery.kind == .retryableFetch || recovery.kind == .retryableSend
          ? .someChangesPending : .appDataIssue)
    case .destructiveReset:
      return .iCloudDataReset
    case .malformedSentBatch, .modeRecoveredSnip, .modeRecoveredList,
         .modeDeletedListPlacement, .deletedListPlacement:
      return .appDataIssue
    }
  }

  static func storedSyncIssues(
    for recovery: CloudFullRecoveryInput
  ) -> [SyncedContentSyncIssue]? {
    guard recovery.kind == .terminalFetch || recovery.kind == .terminalSend,
      let raw = try? JSONDecoder().decode(RawStagedBatch.self, from: recovery.resultData),
      raw.storageVersion == 1
    else { return nil }
    let issues = CloudSyncIssueError.issues(in: raw.batch)
    return issues.isEmpty ? nil : issues
  }
}
