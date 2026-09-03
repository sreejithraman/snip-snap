import Foundation
import SnipSnapCore
import SnipSnapPersistence

package protocol CloudFullSyncStore: Sendable {
  func loadEngineState() async throws -> CloudEngineStateEnvelope?
  func saveEngineState(_ state: CloudEngineStateEnvelope) async throws
  func clearEngineState() async throws
  func stagedBatches() async throws -> [CloudFullBatchCommit]
  func stage(_ batch: CloudSyncBatch, outbound: CloudOutboundBatch?) async throws
  func applyStaged(_ id: UUID) async throws
  func pendingChanges() async throws -> CloudOutboundBatch
}

package actor CloudFullSyncCoordinator {
  private let store: any CloudFullSyncStore
  private let transport: any CloudRecordTransport
  private let fetchScope: CloudFetchScope
  private var started = false
  private var syncing = false
  private var lastIssue: SyncedContentSyncIssue?
  private var blocksOutbound = false

  package init(
    store: any CloudFullSyncStore,
    transport: any CloudRecordTransport,
    fetchScope: CloudFetchScope = .all
  ) {
    self.store = store
    self.transport = transport
    self.fetchScope = fetchScope
  }

  package func sync() async throws {
    try await run(fetch: true, send: true, beforeSend: { _ in })
  }

  package func fetchRemote(
    beforeApply: @escaping @Sendable () async throws -> Void = {}
  ) async throws {
    try await run(
      fetch: true,
      send: false,
      beforeFetchApply: beforeApply,
      beforeSend: { _ in }
    )
  }

  package func sendPending() async throws {
    try await run(fetch: false, send: true, beforeSend: { _ in })
  }

  package func sendPending(
    beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void
  ) async throws {
    try await run(fetch: false, send: true, beforeSend: beforeSend)
  }

  package func prepareAutomaticSync(
    beforeApply: @escaping @Sendable () async throws -> Void = {}
  ) async throws {
    guard !syncing else { throw CloudTransportError.syncAlreadyRunning }
    syncing = true
    lastIssue = nil
    blocksOutbound = false
    do {
      try await recover()
      let needsBootstrapFetch = try await ensureStarted()
      if needsBootstrapFetch {
        let fetched = try await transport.fetch(scope: .all)
        try await beforeApply()
        let batch = CloudSyncBatch.fetched(fetched)
        try await commitAndRecoverExpiredToken(
          batch,
          outbound: nil,
          beforeApply: beforeApply
        )
      }
      if !blocksOutbound, let scheduler = transport as? any CloudAutomaticSyncScheduling {
        let outbound = try await pendingChangesOrResetEngine()
        if !outbound.operations.isEmpty || !outbound.zonesToSave.isEmpty {
          try await scheduler.scheduleAutomaticSync(outbound)
        }
      }
      syncing = false
      await transport.drainAutomaticSyncEvents()
    } catch {
      syncing = false
      await transport.drainAutomaticSyncEvents()
      throw error
    }
  }

  package func applyAutomatically(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?,
    beforeApply: @escaping @Sendable () async throws -> Void
  ) async throws {
    guard !syncing else { throw CloudTransportError.syncAlreadyRunning }
    syncing = true
    lastIssue = nil
    blocksOutbound = false
    do {
      try await beforeApply()
      try await recover(excluding: batch.id)
      try await commitAndRecoverExpiredToken(
        batch,
        outbound: outbound,
        beforeApply: beforeApply
      )
      if !blocksOutbound { try await schedulePendingChanges() }
      syncing = false
      await transport.drainAutomaticSyncEvents()
    } catch {
      syncing = false
      await transport.drainAutomaticSyncEvents()
      throw error
    }
  }

  private func run(
    fetch: Bool,
    send: Bool,
    beforeFetchApply: @escaping @Sendable () async throws -> Void = {},
    beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void
  ) async throws {
    guard !syncing else { throw CloudTransportError.syncAlreadyRunning }
    syncing = true
    lastIssue = nil
    blocksOutbound = false
    do {
      try await recover()
      let needsBootstrapFetch = try await ensureStarted()
      if fetch || (send && needsBootstrapFetch) {
        let fetched = try await transport.fetch(scope: fetch ? fetchScope : .all)
        try await beforeFetchApply()
        let batch = CloudSyncBatch.fetched(fetched)
        try await commitAndRecoverExpiredToken(
          batch,
          outbound: nil,
          beforeApply: beforeFetchApply
        )
      }
      if send, !blocksOutbound {
        let outbound = try await pendingChangesOrResetEngine()
        if !outbound.operations.isEmpty || !outbound.zonesToSave.isEmpty {
          try await beforeSend(outbound)
          let batch = CloudSyncBatch.sent(try await transport.send(outbound))
          try await commitAndRecoverExpiredToken(
            batch,
            outbound: outbound,
            beforeApply: beforeFetchApply
          )
        }
      }
      syncing = false
      await transport.drainAutomaticSyncEvents()
    } catch {
      syncing = false
      await transport.drainAutomaticSyncEvents()
      throw error
    }
  }

  private func ensureStarted() async throws -> Bool {
    guard !started else { return false }
    let state: CloudEngineStateEnvelope?
    do {
      state = try await store.loadEngineState()
    } catch CloudTransportError.invalidEngineState {
      try await store.clearEngineState()
      try await transport.start(state: nil, initialOutbound: nil)
      started = true
      return true
    } catch CloudTransportError.stateNamespaceMismatch {
      try await store.clearEngineState()
      try await transport.start(state: nil, initialOutbound: nil)
      started = true
      return true
    }
    let outbound = state == nil ? nil : try await pendingChangesOrResetEngine()
    do {
      try await transport.start(state: state, initialOutbound: outbound)
    } catch CloudTransportError.invalidEngineState {
      try await store.clearEngineState()
      try await transport.start(state: nil, initialOutbound: nil)
      started = true
      return true
    } catch CloudTransportError.stateNamespaceMismatch {
      try await store.clearEngineState()
      try await transport.start(state: nil, initialOutbound: nil)
      started = true
      return true
    }
    started = true
    return state == nil
  }

  private func recover(excluding excludedBatchID: UUID? = nil) async throws {
    for batch in try await store.stagedBatches() where batch.batchID != excludedBatchID {
      try await store.applyStaged(batch.batchID)
      try await transport.confirmApplied(batch.batchID)
    }
    var recovered: Set<UUID> = []
    while let pending = await transport.pendingBatch(),
      pending.batch.id != excludedBatchID,
      recovered.insert(pending.batch.id).inserted
    {
      try await commit(pending.batch, outbound: pending.outbound)
      await transport.drainAutomaticSyncEvents()
    }
  }

  private func commit(_ batch: CloudSyncBatch, outbound: CloudOutboundBatch?) async throws {
    try await store.stage(batch, outbound: outbound)
    try await store.applyStaged(batch.id)
    try await transport.confirmApplied(batch.id)
  }

  package func persistEngineState(_ state: CloudEngineStateEnvelope) async throws {
    try await store.saveEngineState(state)
  }

  package func takeSyncIssue() -> SyncedContentSyncIssue? {
    defer { lastIssue = nil }
    return lastIssue
  }

  package func isOutboundBlocked() -> Bool { blocksOutbound }

  private func schedulePendingChanges() async throws {
    guard let scheduler = transport as? any CloudAutomaticSyncScheduling else { return }
    let outbound = try await pendingChangesOrResetEngine()
    guard !outbound.operations.isEmpty || !outbound.zonesToSave.isEmpty else { return }
    try await scheduler.scheduleAutomaticSync(outbound)
  }

  private func pendingChangesOrResetEngine() async throws -> CloudOutboundBatch {
    do {
      return try await store.pendingChanges()
    } catch is CloudRecordError {
      try await store.clearEngineState()
      await transport.reset()
      started = false
      throw CloudSyncRetryableError.itemFailure
    }
  }

  private func recordSyncIssue(in batch: CloudSyncBatch) {
    if let issue = CloudSyncIssueError.issue(in: batch) { lastIssue = issue }
    blocksOutbound = blocksOutbound || CloudSyncIssueError.blocksOutbound(in: batch)
  }

  private func commitAndRecoverExpiredToken(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?,
    beforeApply: @escaping @Sendable () async throws -> Void
  ) async throws {
    try await commit(batch, outbound: outbound)
    guard CloudSyncIssueError.requiresEngineReset(batch) else {
      recordSyncIssue(in: batch)
      return
    }
    try await store.clearEngineState()
    await transport.reset()
    started = false
    lastIssue = nil
    blocksOutbound = false
    _ = try await ensureStarted()
    let fetched = CloudSyncBatch.fetched(try await transport.fetch(scope: .all))
    try await beforeApply()
    try await commit(fetched, outbound: nil)
    recordSyncIssue(in: fetched)
    if CloudSyncIssueError.requiresEngineReset(fetched) {
      blocksOutbound = true
    }
  }
}

package actor CloudFullSyncPersistence: CloudFullSyncStore {
  package typealias ApplyHook = @Sendable () async throws -> Void

  private struct RawStagedBatch: Codable, Equatable, Sendable {
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

  package init(
    library: SwiftDataSnipLibrary,
    namespace: CloudSyncNamespace,
    dataZone: CloudZoneID,
    payloadZone: CloudZoneID? = nil,
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
    self.attachmentPolicy = attachmentPolicy
    self.now = now
    self.afterCommitHook = afterCommitHook
    namespaceKey = namespace.namespaceKey
  }
}

extension CloudFullSyncPersistence {
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
    guard state.namespace == namespace else {
      throw CloudTransportError.stateNamespaceMismatch
    }
    try await library.saveCloudEngineState(
      namespaceKey: namespaceKey,
      envelopeData: JSONEncoder().encode(state)
    )
  }

  package func clearEngineState() async throws {
    try await library.clearCloudEngineState(namespaceKey: namespaceKey)
  }

  package func stagedBatches() async throws -> [CloudFullBatchCommit] {
    try await library.stagedCloudFullBatches(namespaceKey: namespaceKey)
  }

  package func applyStaged(_ id: UUID) async throws {
    guard let batch = try await stagedBatches().first(where: { $0.batchID == id }) else { return }
    if let rawData = batch.rawBatchData,
      let raw = try? JSONDecoder().decode(RawStagedBatch.self, from: rawData),
      let reason = Self.destructiveResetReason(raw.batch)
    {
      observedDestructiveReset = reason
    }
    do {
      _ = try await library.commitCloudFullBatch(batch)
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
      try await afterCommitHook()
    }
  }

  package func stage(_ batch: CloudSyncBatch) async throws {
    try await stage(batch, outbound: nil)
  }

  package func stage(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?
  ) async throws {
    do {
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

  private static func rawBatchData(
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
