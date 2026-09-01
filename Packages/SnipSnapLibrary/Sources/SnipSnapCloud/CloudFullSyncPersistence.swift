import Foundation
import SnipSnapCore
import SnipSnapPersistence

package protocol CloudFullSyncStore: Sendable {
  func loadEngineState() async throws -> CloudEngineStateEnvelope?
  func saveEngineState(_ state: CloudEngineStateEnvelope) async throws
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

  package func prepareAutomaticSync() async throws {
    guard !syncing else { throw CloudTransportError.syncAlreadyRunning }
    syncing = true
    do {
      try await recover()
      if !started {
        let state = try await store.loadEngineState()
        try await transport.start(state: state)
        started = true
      }
      if let scheduler = transport as? any CloudAutomaticSyncScheduling {
        let outbound = try await store.pendingChanges()
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
    do {
      try await beforeApply()
      try await recover(excluding: batch.id)
      try await commit(batch, outbound: outbound)
      try await schedulePendingChanges()
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
    do {
      try await recover()
      var needsBootstrapFetch = false
      if !started {
        let state = try await store.loadEngineState()
        try await transport.start(state: state)
        started = true
        needsBootstrapFetch = state == nil
      }
      if fetch || (send && needsBootstrapFetch) {
        let fetched = try await transport.fetch(scope: fetch ? fetchScope : .all)
        try await beforeFetchApply()
        try await commit(.fetched(fetched), outbound: nil)
      }
      if send {
        let outbound = try await store.pendingChanges()
        if !outbound.operations.isEmpty || !outbound.zonesToSave.isEmpty {
          try await beforeSend(outbound)
          try await commit(.sent(transport.send(outbound)), outbound: outbound)
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

  private func schedulePendingChanges() async throws {
    guard let scheduler = transport as? any CloudAutomaticSyncScheduling else { return }
    let outbound = try await store.pendingChanges()
    guard !outbound.operations.isEmpty || !outbound.zonesToSave.isEmpty else { return }
    try await scheduler.scheduleAutomaticSync(outbound)
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
  private var observedEncryptedDataReset = false

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
    let value = try JSONDecoder().decode(CloudEngineStateEnvelope.self, from: stored)
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

  package func stagedBatches() async throws -> [CloudFullBatchCommit] {
    try await library.stagedCloudFullBatches(namespaceKey: namespaceKey)
  }

  package func applyStaged(_ id: UUID) async throws {
    guard let batch = try await stagedBatches().first(where: { $0.batchID == id }) else { return }
    if let rawData = batch.rawBatchData,
      let raw = try? JSONDecoder().decode(RawStagedBatch.self, from: rawData),
      Self.containsEncryptedDataReset(raw.batch)
    {
      observedEncryptedDataReset = true
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
      if Self.containsEncryptedDataReset(batch) {
        observedEncryptedDataReset = true
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

  package func takeEncryptedDataResetSignal() -> Bool {
    defer { observedEncryptedDataReset = false }
    return observedEncryptedDataReset
  }

  private static func containsEncryptedDataReset(_ batch: CloudSyncBatch) -> Bool {
    let events: [CloudDatabaseEvent] = switch batch {
    case .fetched(let fetched): fetched.databaseEvents
    case .sent(let sent): sent.databaseEvents
    }
    return events.contains { event in
      if case .zoneDeleted(_, reason: .encryptedDataReset) = event { true } else { false }
    }
  }

  private static func rawBatchData(
    _ batch: CloudSyncBatch,
    outbound: CloudOutboundBatch?
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(RawStagedBatch(batch: batch, outbound: outbound))
  }
}
