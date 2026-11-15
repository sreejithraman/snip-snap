import Foundation
import Synchronization

/// Durable admission comes from the store. Scheduling cannot loosen it.
package struct CloudRecordOutboundAdmission: Equatable, Sendable {
  package let blockedRecordIDs: Set<CloudRecordID>
  package let blocksAll: Bool

  package init(blockedRecordIDs: Set<CloudRecordID> = [], blocksAll: Bool = false) {
    self.blockedRecordIDs = blockedRecordIDs
    self.blocksAll = blocksAll
  }

  package static let open = Self()
}

/// Records and checkpoints share one order. A checkpoint cannot pass uncommitted records.
package enum CloudRecordTransportEvent: Sendable {
  case batch(CloudPendingBatch)
  case checkpoint(UUID, CloudEngineStateEnvelope)
  case accountChange(UUID)

  package var id: UUID {
    switch self {
    case .batch(let value): value.batch.id
    case .checkpoint(let id, _), .accountChange(let id): id
    }
  }
}

package final class CloudRecordTransportMailbox: Sendable {
  private typealias WorkAvailable = @Sendable () async -> Void

  /// One notification runs at a time. Events that arrive meanwhile request one follow-up.
  private enum WorkNotification: Sendable {
    case unconfigured
    case idle(WorkAvailable)
    case notifying(WorkAvailable, head: UUID, followUpRequested: Bool)
  }

  private struct State: Sendable {
    var events: [CloudRecordTransportEvent] = []
    var notification = WorkNotification.unconfigured

    mutating func configure(_ workAvailable: @escaping WorkAvailable) {
      if case .notifying(_, let head, let followUpRequested) = notification {
        notification = .notifying(workAvailable, head: head, followUpRequested: followUpRequested)
      } else {
        notification = .idle(workAvailable)
      }
    }

    /// Returns the handler only when this request starts a notification.
    mutating func startNotification() -> WorkAvailable? {
      guard let head = events.first?.id else { return nil }
      switch notification {
      case .unconfigured:
        return nil
      case .idle(let workAvailable):
        notification = .notifying(workAvailable, head: head, followUpRequested: false)
        return workAvailable
      case .notifying(let workAvailable, let running, _):
        notification = .notifying(workAvailable, head: running, followUpRequested: true)
        return nil
      }
    }

    /// Returns whether to notify again.
    mutating func finishNotification() -> Bool {
      guard case .notifying(let workAvailable, let head, let followUpRequested) = notification
      else { return false }
      notification = .idle(workAvailable)
      return events.first?.id != head || followUpRequested
    }

    mutating func reset() {
      events.removeAll()
      // The transport can reset inside a delivery. That notification keeps running, so the
      // new engine's first event waits for one follow-up instead of starting a second consumer.
      if case .notifying(let workAvailable, let head, _) = notification {
        notification = .notifying(workAvailable, head: head, followUpRequested: false)
      }
    }
  }

  private let state = Mutex(State())

  package var first: CloudRecordTransportEvent? { state.withLock { $0.events.first } }
  package var diagnosticCounts: (events: Int, downloads: Int) {
    state.withLock {
      ($0.events.count, $0.events.reduce(0) { count, event in
        guard case .batch(let pending) = event, case .fetched(let batch) = pending.batch else { return count }
        return count + batch.items.count
      })
    }
  }
  package var blocksRecordProvider: Bool {
    state.withLock { $0.events.contains { event in
      guard case .batch(let pending) = event else { return false }
      switch pending.batch {
      case .fetched(let batch):
        // An empty incremental fetch cannot change a planned record body. Keep
        // its checkpoint ordered, without starving the same cycle's send.
        return batch.isInitialFetch || !batch.items.isEmpty
          || !batch.databaseEvents.isEmpty || !batch.zoneEvents.isEmpty
      case .sent:
        return true
      }
    } }
  }

  package func configure(workAvailable: @escaping @Sendable () async -> Void) {
    state.withLock { $0.configure(workAvailable) }
  }

  package func append(_ event: CloudRecordTransportEvent) {
    state.withLock { $0.events.append(event) }
    notify()
  }

  package func confirm(_ id: UUID) throws -> CloudRecordTransportEvent? {
    try state.withLock { state in
      guard let first = state.events.first else { return nil }
      guard first.id == id else { throw CloudTransportError.wrongBatchConfirmation }
      return state.events.removeFirst()
    }
  }

  package func reset() {
    state.withLock { $0.reset() }
  }

  /// A producer never waits for the consumer, which may hold or await a record lease.
  package func notify() {
    guard let workAvailable = state.withLock({ $0.startNotification() }) else { return }
    Task {
      await workAvailable()
      // Keep an intervening request even if apply failed, but never spin on failure alone.
      if state.withLock({ $0.finishNotification() }) { notify() }
    }
  }
}

/// The provider and acknowledgement use the same operations throughout a send cycle.
package struct CloudRecordSendCycle: Sendable {
  package let id = UUID()
  package let outbound: CloudOutboundBatch
  private let operationsByID: [CloudRecordID: CloudOutboundOperation]
  private var withheldIDs: Set<CloudRecordID> = []

  package init(_ outbound: CloudOutboundBatch) {
    self.outbound = outbound
    operationsByID = Dictionary(uniqueKeysWithValues: outbound.operations.map { ($0.id, $0) })
  }

  package func operations(pendingIDs: Set<CloudRecordID>) -> [CloudOutboundOperation] {
    outbound.operations.filter { pendingIDs.contains($0.id) && !withheldIDs.contains($0.id) }
  }

  package mutating func withhold(_ ids: Set<CloudRecordID>) {
    withheldIDs.formUnion(ids)
  }

  package func draft(_ id: CloudRecordID) -> CloudRecordDraft? {
    guard !withheldIDs.contains(id),
      case .save(let draft)? = operationsByID[id]
    else { return nil }
    return draft
  }
}

/// Keeps the latest desired snapshot apart from frozen and unacknowledged sends.
package struct CloudRecordOutboundQueue: Sendable {
  /// Supplied records belong to one open send cycle.
  private enum SendCycle: Sendable {
    case idle
    case open(CloudRecordSendCycle, supplied: Set<CloudRecordID>)

    /// Supplied operations stay in the cycle's acknowledgement.
    mutating func withholdUnsupplied(where withdrawn: (CloudOutboundOperation) -> Bool) {
      guard case .open(var cycle, let supplied) = self else { return }
      let withdrawnIDs = Set(cycle.outbound.operations.filter(withdrawn).map(\.id))
      cycle.withhold(withdrawnIDs.subtracting(supplied))
      self = .open(cycle, supplied: supplied)
    }

    mutating func recordSupplied(_ ids: Set<CloudRecordID>) {
      guard case .open(let cycle, let supplied) = self else { return }
      self = .open(cycle, supplied: supplied.union(ids))
    }
  }

  /// A stop lasts for the queue's lifetime. Record blocks stay tracked after a stop
  /// because the transport reports them as blocked records.
  private struct AdmissionGate: Sendable {
    private enum Phase: Sendable { case admitting, stopped }

    private var phase = Phase.admitting
    private var durableBlocks: Set<CloudRecordID> = []
    private var observedBlocks: [UUID: Set<CloudRecordID>] = [:]

    var blocksAll: Bool { phase == .stopped }
    var blockedRecordIDs: Set<CloudRecordID> {
      observedBlocks.values.reduce(into: durableBlocks) { $0.formUnion($1) }
    }
    var admission: CloudRecordOutboundAdmission {
      CloudRecordOutboundAdmission(blockedRecordIDs: blockedRecordIDs, blocksAll: blocksAll)
    }

    mutating func restore(_ value: CloudRecordOutboundAdmission) {
      durableBlocks = value.blockedRecordIDs
      if value.blocksAll { phase = .stopped }
    }

    mutating func observe(_ batchID: UUID, blocking ids: Set<CloudRecordID>, resets: Bool) {
      if resets { phase = .stopped }
      observedBlocks[batchID, default: []].formUnion(ids)
    }

    mutating func confirm(_ batchID: UUID, durable: CloudRecordOutboundAdmission) {
      restore(durable)
      observedBlocks.removeValue(forKey: batchID)
    }

    mutating func confirmLegacy(_ batch: CloudSyncBatch) {
      if case .fetched(let fetched) = batch {
        durableBlocks.formUnion(observedBlocks[batch.id] ?? [])
        durableBlocks.subtract(fetched.items.compactMap { item -> CloudRecordID? in
          switch item {
          case .record(let record): record.id
          case .deleted(let id): id
          case .failed: nil
          }
        })
      }
      observedBlocks.removeValue(forKey: batch.id)
    }
  }

  private var desired = CloudOutboundBatch(operations: [])
  private var sendCycle = SendCycle.idle
  private var awaitingAcknowledgement: [UUID: CloudOutboundBatch] = [:]
  private var gate = AdmissionGate()

  package var cycle: CloudRecordSendCycle? {
    guard case .open(let cycle, _) = sendCycle else { return nil }
    return cycle
  }
  package var admission: CloudRecordOutboundAdmission { gate.admission }
  package var current: CloudOutboundBatch { desired }
  package var pendingOperationCount: Int {
    let cyclingIDs = cycle.map {
      $0.operations(pendingIDs: Set($0.outbound.operations.map(\.id))).map(\.id)
    } ?? []
    return Set(desired.operations.map(\.id))
      .union(cyclingIDs)
      .union(awaitingAcknowledgement.values.flatMap { $0.operations.map(\.id) }).count
  }

  /// New record bodies wait until no send cycle is open and every send is acknowledged.
  private var admitsEngineWork: Bool {
    guard case .idle = sendCycle else { return false }
    return awaitingAcknowledgement.isEmpty
  }

  /// Replaces all unsent work, including omissions and an empty snapshot.
  package mutating func schedule(_ batch: CloudOutboundBatch) -> CloudOutboundBatch? {
    guard !gate.blocksAll else { return nil }
    desired = Self.snapshot(batch, excluding: gate.blockedRecordIDs)
    let scheduled = Dictionary(desired.operations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    // A provider may still be building an older batch across an await. Keep these
    // withdrawals for the whole cycle, even if a later snapshot restores the ID.
    sendCycle.withholdUnsupplied { frozen in
      switch (frozen, scheduled[frozen.id]) {
      case (.save, .save?), (.delete, .delete?): false
      default: true
      }
    }
    return admitsEngineWork ? desired : nil
  }

  package mutating func restoreAdmission(_ value: CloudRecordOutboundAdmission) {
    gate.restore(value)
    enforceAdmission()
  }

  /// Observation blocks immediately; only a durable acknowledgement can release it.
  package mutating func observe(_ batch: CloudSyncBatch, zones: Set<CloudZoneID>) {
    let ids: Set<CloudRecordID>
    let events: [CloudDatabaseEvent]
    switch batch {
    case .fetched(let fetched):
      ids = Set(fetched.items.compactMap { item in
        guard case .failed(let id?, _) = item, zones.contains(id.zone) else { return nil }
        return id
      })
      events = fetched.databaseEvents
    case .sent(let sent):
      ids = []
      events = sent.databaseEvents
    }
    let resets = events.contains { event in
      guard case .zoneDeleted(let zone, let reason) = event else { return false }
      return zones.contains(zone) && reason != .deleted
    }
    guard !ids.isEmpty || resets else { return }
    gate.observe(batch.id, blocking: ids, resets: resets)
    enforceAdmission()
  }

  package mutating func confirmAdmission(_ batchID: UUID, durable: CloudRecordOutboundAdmission) {
    gate.confirm(batchID, durable: durable)
    enforceAdmission()
  }

  /// The legacy adapter has no full-record recovery rows; its acknowledgement is durable.
  package mutating func confirmLegacyAdmission(_ batch: CloudSyncBatch) {
    gate.confirmLegacy(batch)
    enforceAdmission()
  }

  private mutating func enforceAdmission() {
    if gate.blocksAll {
      sendCycle.withholdUnsupplied { _ in true }
      desired = CloudOutboundBatch(operations: [])
    } else {
      let blocked = gate.blockedRecordIDs
      sendCycle.withholdUnsupplied { blocked.contains($0.id) }
      desired = CloudOutboundBatch(operations: desired.operations.filter { !blocked.contains($0.id) },
        zonesToSave: desired.zonesToSave)
    }
  }

  package mutating func beginCycle() {
    sendCycle = .open(CloudRecordSendCycle(desired), supplied: [])
  }

  package mutating func recordSupplied(_ ids: Set<CloudRecordID>) {
    sendCycle.recordSupplied(ids)
  }

  package mutating func finishCycle(_ id: UUID) -> CloudOutboundBatch {
    let sent = switch sendCycle {
    case .idle:
      CloudOutboundBatch(operations: [])
    case .open(let cycle, let supplied):
      CloudOutboundBatch(
        operations: cycle.operations(pendingIDs: supplied), zonesToSave: cycle.outbound.zonesToSave)
    }
    sendCycle = .idle
    awaitingAcknowledgement[id] = sent
    return sent
  }

  package mutating func confirm(_ batch: CloudSentBatch) {
    guard let sent = awaitingAcknowledgement.removeValue(forKey: batch.id) else { return }
    let retrying = CloudKitRecordTransport.retryingRecordIDs(in: batch)
    let acknowledged = Dictionary(
      sent.operations.filter { !retrying.contains($0.id) }.map { ($0.id, $0) },
      uniquingKeysWith: { _, last in last })
    let savedZones = batch.databaseEvents.compactMap { event -> CloudZoneID? in
      guard case .zoneSaved(let zone) = event else { return nil }
      return zone
    }
    desired = CloudOutboundBatch(operations: desired.operations.filter { acknowledged[$0.id] != $0 },
      zonesToSave: desired.zonesToSave.subtracting(savedZones))
  }

  /// Each record keeps its first position and its last operation.
  private static func snapshot(
    _ batch: CloudOutboundBatch, excluding blocked: Set<CloudRecordID>
  ) -> CloudOutboundBatch {
    var operations: [CloudOutboundOperation] = []
    var positions: [CloudRecordID: Int] = [:]
    for operation in batch.operations where !blocked.contains(operation.id) {
      if let position = positions[operation.id] {
        operations[position] = operation
      } else {
        positions[operation.id] = operations.count
        operations.append(operation)
      }
    }
    return CloudOutboundBatch(operations: operations, zonesToSave: batch.zonesToSave)
  }
}
