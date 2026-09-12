import Foundation

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

package final class CloudRecordTransportMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [CloudRecordTransportEvent] = []
  private var workAvailable: (@Sendable () async -> Void)?
  private var notifying = false
  private var notificationPending = false

  package var first: CloudRecordTransportEvent? { lock.withLock { events.first } }
  package var hasUncommittedRecords: Bool {
    lock.withLock { events.contains { if case .batch = $0 { true } else { false } } }
  }

  package func configure(workAvailable: @escaping @Sendable () async -> Void) {
    lock.withLock { self.workAvailable = workAvailable }
  }

  package func append(_ event: CloudRecordTransportEvent) {
    lock.withLock { events.append(event) }
    notify()
  }

  package func confirm(_ id: UUID) throws -> CloudRecordTransportEvent? {
    try lock.withLock {
      guard let first = events.first else { return nil }
      guard first.id == id else { throw CloudTransportError.wrongBatchConfirmation }
      return events.removeFirst()
    }
  }

  package func reset() {
    lock.withLock {
      events.removeAll()
      notificationPending = false
    }
  }

  /// A producer never waits for the consumer, which may hold or await a record lease.
  package func notify() {
    let delivery: (UUID, @Sendable () async -> Void)? = lock.withLock {
      guard let id = events.first?.id, let workAvailable else { return nil }
      if notifying {
        notificationPending = true
        return nil
      }
      notifying = true
      notificationPending = false
      return (id, workAvailable)
    }
    guard let (headID, action) = delivery else { return }
    Task {
      await action()
      let needsDelivery = lock.withLock {
        notifying = false
        let needed = events.first?.id != headID || notificationPending
        notificationPending = false
        return needed
      }
      // Keep an intervening request even if apply failed, but never spin on failure alone.
      if needsDelivery { notify() }
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

/// Keeps the latest desired snapshot apart from frozen and unconfirmed sends.
package struct CloudRecordOutboundQueue: Sendable {
  private var queued: [CloudRecordID: CloudOutboundOperation] = [:]
  private var order: [CloudRecordID] = []
  private var zones: Set<CloudZoneID> = []
  private var unconfirmed: [UUID: CloudOutboundBatch] = [:]
  package private(set) var cycle: CloudRecordSendCycle?
  private var suppliedIDs: Set<CloudRecordID> = []
  private var stopped = false
  private var durableAdmission = CloudRecordOutboundAdmission.open
  private var observedAdmission: [UUID: CloudRecordOutboundAdmission] = [:]

  package var admission: CloudRecordOutboundAdmission {
    CloudRecordOutboundAdmission(
      blockedRecordIDs: observedAdmission.values.reduce(into: durableAdmission.blockedRecordIDs) {
        $0.formUnion($1.blockedRecordIDs)
      },
      blocksAll: stopped || durableAdmission.blocksAll || observedAdmission.values.contains(where: \.blocksAll)
    )
  }

  package var current: CloudOutboundBatch {
    CloudOutboundBatch(operations: order.compactMap { queued[$0] }, zonesToSave: zones)
  }

  /// Replaces all unsent work, including omissions and an empty snapshot.
  package mutating func schedule(_ batch: CloudOutboundBatch) -> CloudOutboundBatch? {
    let admission = admission
    guard !admission.blocksAll else { return nil }
    queued.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
    for operation in batch.operations where !admission.blockedRecordIDs.contains(operation.id) {
      if queued[operation.id] == nil { order.append(operation.id) }
      queued[operation.id] = operation
    }
    zones = batch.zonesToSave
    let withdrawn = Set(cycle?.outbound.operations.compactMap { frozen -> CloudRecordID? in
      switch (frozen, queued[frozen.id]) {
      case (.save, .save?), (.delete, .delete?): nil
      default: frozen.id
      }
    } ?? [])
    // A provider may still be building an older batch across an await. Keep these
    // withdrawals for the whole cycle, even if a later snapshot restores the ID.
    cycle?.withhold(withdrawn.subtracting(suppliedIDs))
    return cycle == nil && unconfirmed.isEmpty ? current : nil
  }

  package mutating func restoreAdmission(_ value: CloudRecordOutboundAdmission) {
    durableAdmission = value
    stopped = stopped || value.blocksAll
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
    stopped = stopped || resets
    let prior = observedAdmission[batch.id] ?? .open
    observedAdmission[batch.id] = CloudRecordOutboundAdmission(
      blockedRecordIDs: prior.blockedRecordIDs.union(ids), blocksAll: prior.blocksAll || resets)
    enforceAdmission()
  }

  package mutating func confirmAdmission(_ batchID: UUID, durable: CloudRecordOutboundAdmission) {
    durableAdmission = durable
    stopped = stopped || durable.blocksAll
    observedAdmission.removeValue(forKey: batchID)
    enforceAdmission()
  }

  /// The legacy adapter has no full-record recovery rows; its acknowledgement is durable.
  package mutating func confirmLegacyAdmission(_ batch: CloudSyncBatch) {
    var blocked = durableAdmission.blockedRecordIDs
    if case .fetched(let fetched) = batch {
      blocked.formUnion(observedAdmission[batch.id]?.blockedRecordIDs ?? [])
      blocked.subtract(fetched.items.compactMap { item -> CloudRecordID? in
        switch item {
        case .record(let record): record.id
        case .deleted(let id): id
        case .failed: nil
        }
      })
    }
    confirmAdmission(batch.id, durable: CloudRecordOutboundAdmission(
      blockedRecordIDs: blocked, blocksAll: durableAdmission.blocksAll))
  }

  private mutating func enforceAdmission() {
    let admission = admission
    let ids = admission.blocksAll
      ? Set(queued.keys).union(cycle?.outbound.operations.map(\.id) ?? [])
      : admission.blockedRecordIDs
    for id in ids { queued.removeValue(forKey: id) }
    order.removeAll { ids.contains($0) }
    cycle?.withhold(ids.subtracting(suppliedIDs))
    if admission.blocksAll { zones = [] }
  }

  package mutating func beginCycle() {
    cycle = CloudRecordSendCycle(current)
    suppliedIDs = []
  }

  package mutating func recordSupplied(_ ids: Set<CloudRecordID>) {
    suppliedIDs.formUnion(ids)
  }

  package mutating func finishCycle(_ id: UUID) -> CloudOutboundBatch {
    let sent = CloudOutboundBatch(
      operations: cycle?.operations(pendingIDs: suppliedIDs) ?? [],
      zonesToSave: cycle?.outbound.zonesToSave ?? []
    )
    unconfirmed[id] = sent
    cycle = nil
    suppliedIDs = []
    return sent
  }

  package mutating func confirm(_ batch: CloudSentBatch) {
    guard let sent = unconfirmed.removeValue(forKey: batch.id) else { return }
    let retrying = CloudKitRecordTransport.retryingRecordIDs(in: batch)
    zones.subtract(batch.databaseEvents.compactMap { event -> CloudZoneID? in
      guard case .zoneSaved(let zone) = event else { return nil }
      return zone
    })
    for operation in sent.operations where !retrying.contains(operation.id) {
      if queued[operation.id] == operation { queued.removeValue(forKey: operation.id) }
    }
    order.removeAll { queued[$0] == nil }
  }
}
