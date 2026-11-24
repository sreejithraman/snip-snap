import Foundation
import SnipSnapCore
import SnipSnapPersistence

package struct CloudCollectionDescriptor: Codable, Equatable, Sendable {
  package let generation: UUID
  package let metadataZone: CloudZoneID
  package let payloadZone: CloudZoneID

  package init(
    generation: UUID,
    metadataZone: CloudZoneID,
    payloadZone: CloudZoneID
  ) {
    self.generation = generation
    self.metadataZone = metadataZone
    self.payloadZone = payloadZone
  }

  package var zones: Set<CloudZoneID> { [metadataZone, payloadZone] }

  package static func fresh(ownerName: String) -> Self {
    let generation = UUID()
    let value = generation.uuidString.lowercased()
    return Self(
      generation: generation,
      metadataZone: CloudZoneID(name: "snips-\(value)", ownerName: ownerName),
      payloadZone: CloudZoneID(name: "payloads-\(value)", ownerName: ownerName)
    )
  }

  package func namespace(
    cloudScope: String,
    accountLineage: String
  ) -> CloudSyncNamespace {
    CloudSyncNamespace(
      cloudScope: cloudScope,
      accountLineage: accountLineage,
      generation: generation,
      zones: zones
    )
  }

  package func validate(ownerName: String, reservedZones: Set<CloudZoneID> = []) throws {
    guard metadataZone != payloadZone,
      zones.isDisjoint(with: reservedZones),
      !metadataZone.name.isEmpty,
      !payloadZone.name.isEmpty,
      metadataZone.ownerName == ownerName,
      payloadZone.ownerName == ownerName
    else { throw CloudCollectionError.invalidDescriptor }
  }
}

package struct CloudCollectionControlRecord: Codable, Equatable, Sendable {
  package let descriptor: CloudCollectionDescriptor
  package let version: Data

  package init(descriptor: CloudCollectionDescriptor, version: Data) {
    self.descriptor = descriptor
    self.version = version
  }
}

package enum CloudCollectionControlSaveResult: Equatable, Sendable {
  case accepted(CloudCollectionControlRecord)
  case conflict(CloudCollectionControlRecord)
}

package protocol CloudCollectionControlTransport: Sendable {
  func fetchControl() async throws -> CloudCollectionControlRecord?
  func createZones(_ zones: Set<CloudZoneID>) async throws
  func saveControl(
    _ descriptor: CloudCollectionDescriptor,
    replacing version: Data?
  ) async throws -> CloudCollectionControlSaveResult
  func deleteZones(_ zones: Set<CloudZoneID>) async throws
}

package struct CloudCollectionLocalState: Equatable, Sendable {
  package let hasSyncedBefore: Bool
  package let activeNamespace: CloudSyncNamespace?
  package let cleanupZones: Set<CloudZoneID>
  package let keptAfterReset: Bool

  package init(
    hasSyncedBefore: Bool,
    activeNamespace: CloudSyncNamespace?,
    cleanupZones: Set<CloudZoneID>,
    keptAfterReset: Bool = false
  ) {
    self.hasSyncedBefore = hasSyncedBefore
    self.activeNamespace = activeNamespace
    self.cleanupZones = cleanupZones
    self.keptAfterReset = keptAfterReset
  }
}

package struct CloudCollectionSyncContext: Equatable, Sendable {
  package let namespace: CloudSyncNamespace
  package let metadataZone: CloudZoneID
  package let payloadZone: CloudZoneID

  package init(
    namespace: CloudSyncNamespace,
    metadataZone: CloudZoneID,
    payloadZone: CloudZoneID
  ) {
    self.namespace = namespace
    self.metadataZone = metadataZone
    self.payloadZone = payloadZone
  }
}

package protocol CloudCollectionLocalStore: Sendable {
  func state() async throws -> CloudCollectionLocalState
  func stageCleanup(_ zones: Set<CloudZoneID>) async throws
  func finishCleanup(_ zones: Set<CloudZoneID>) async throws
  func stopAfterDataReset(in namespace: CloudSyncNamespace) async throws -> Bool
}

package enum CloudCollectionFetchResult: Equatable, Sendable {
  case fetched(SyncedContentSyncIssue?)
  case purged

  var issue: SyncedContentSyncIssue? {
    guard case .fetched(let issue) = self else { return nil }
    return issue
  }
}

package enum CloudCollectionSendResult: Equatable, Sendable {
  case sent
  case settled
  case purged
}

package protocol CloudCollectionSyncDriver: Sendable {
  func invalidate() async
  func prepareAutomaticSync(_ context: CloudCollectionSyncContext) async throws
  func prepareManualRetry(_ context: CloudCollectionSyncContext) async throws
  func fetch(_ context: CloudCollectionSyncContext) async throws -> CloudCollectionFetchResult
  func send(_ context: CloudCollectionSyncContext) async throws -> CloudCollectionSendResult
}

package extension CloudCollectionSyncDriver {
  func invalidate() async {}
  func prepareAutomaticSync(_ context: CloudCollectionSyncContext) async throws {}
  func prepareManualRetry(_ context: CloudCollectionSyncContext) async throws {}
}

package enum CloudCollectionStatus: Equatable, Sendable {
  case on(CloudSyncNamespace)
  case settled(CloudSyncNamespace)
  case scheduled(CloudSyncNamespace)
  case purged
  case requiresEnable
}

package enum CloudCollectionError: LocalizedError, Equatable, Sendable {
  case noActiveCollection
  case invalidDescriptor
  case operationInProgress
  case syncNeedsAttention

  package var errorDescription: String? {
    switch self {
    case .noActiveCollection:
      String(localized: "iCloud sync has no active library.", bundle: .main)
    case .invalidDescriptor:
      String(localized: "This iCloud library can’t be used for sync.", bundle: .main)
    case .operationInProgress:
      String(localized: "Another iCloud sync task is still running.", bundle: .main)
    case .syncNeedsAttention:
      String(localized: "iCloud sync needs attention before setup can finish.", bundle: .main)
    }
  }
}

/// Creates or joins the collection control record without changing the local mode pointer.
package actor CloudCollectionBootstrapper {
  private let ownerName: String
  private let localStore: any CloudCollectionLocalStore
  private let transport: any CloudCollectionControlTransport
  private let makeDescriptor: CloudCollectionCoordinator.DescriptorFactory
  private let reservedZones: Set<CloudZoneID>

  package init(
    ownerName: String,
    localStore: any CloudCollectionLocalStore,
    transport: any CloudCollectionControlTransport,
    makeDescriptor: @escaping CloudCollectionCoordinator.DescriptorFactory,
    reservedZones: Set<CloudZoneID> = []
  ) {
    self.ownerName = ownerName
    self.localStore = localStore
    self.transport = transport
    self.makeDescriptor = makeDescriptor
    self.reservedZones = reservedZones
  }

  package func activeOrCreate(
    afterReset reset: ICloudSyncNamespaceBinding? = nil
  ) async throws -> CloudCollectionDescriptor {
    let current = try await transport.fetchControl()
    if let current, canUse(current.descriptor, afterReset: reset) {
      try validate(current.descriptor)
      return current.descriptor
    }
    let fresh = makeDescriptor()
    try validate(fresh)
    guard canUse(fresh, afterReset: reset) else { throw CloudCollectionError.invalidDescriptor }
    try await transport.createZones(fresh.zones)
    switch try await transport.saveControl(fresh, replacing: current?.version) {
    case .accepted(let accepted):
      try validate(accepted.descriptor)
      return accepted.descriptor
    case .conflict(let winner):
      try validate(winner.descriptor)
      let unused = fresh.zones.subtracting(winner.descriptor.zones)
      if !unused.isEmpty {
        try await localStore.stageCleanup(unused)
        do {
          try await transport.deleteZones(unused)
          try await localStore.finishCleanup(unused)
        } catch {
          // The next generation-gated sync retries the durable cleanup work.
        }
      }
      guard canUse(winner.descriptor, afterReset: reset) else {
        throw CloudCollectionError.syncNeedsAttention
      }
      return winner.descriptor
    }
  }

  private func canUse(_ descriptor: CloudCollectionDescriptor, afterReset reset: ICloudSyncNamespaceBinding?) -> Bool {
    guard let reset else { return true }
    return descriptor.generation != reset.generation
      && descriptor.zones.allSatisfy { zone in
        !reset.zones.contains(ICloudSyncZoneBinding(name: zone.name, ownerName: zone.ownerName))
      }
  }

  private func validate(_ descriptor: CloudCollectionDescriptor) throws {
    try descriptor.validate(ownerName: ownerName, reservedZones: reservedZones)
  }
}

/// Excludes normal sends and resets across coordinators owned by one app process.
package final class CloudCollectionOperationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var inProgress = false

  package init() {}

  fileprivate func begin() throws {
    try lock.withLock {
      guard !inProgress else { throw CloudCollectionError.operationInProgress }
      inProgress = true
    }
  }

  fileprivate func finish() {
    lock.withLock { inProgress = false }
  }
}

/// Owns the generation check for one private CloudKit collection. A control record that no longer
/// describes the active collection means this device missed an iCloud reset, so it keeps the
/// library on this device and turns sync off (ADR 0018, ADR 0024).
package actor CloudCollectionCoordinator {
  package typealias DescriptorFactory = @Sendable () -> CloudCollectionDescriptor

  /// The sync requests of ADR 0028.
  private enum SyncRequest {
    /// Launch, foreground, and edits: check the collection, then let the engine schedule.
    case schedule
    /// A checked fetch, a control re-check, and the only send.
    case transfer
    /// Try Again: prepare user-recoverable failures, transfer, and report settled work.
    case retry
  }

  private let cloudScope: String
  private let accountLineage: String
  private let ownerName: String
  private let localStore: any CloudCollectionLocalStore
  private let transport: any CloudCollectionControlTransport
  private let syncDriver: any CloudCollectionSyncDriver
  private let makeDescriptor: DescriptorFactory
  private let beforeReplacingCollection: @Sendable () async throws -> Void
  private let reservedZones: Set<CloudZoneID>
  private let operationGate: CloudCollectionOperationGate

  package init(
    cloudScope: String,
    accountLineage: String,
    ownerName: String,
    localStore: any CloudCollectionLocalStore,
    transport: any CloudCollectionControlTransport,
    syncDriver: any CloudCollectionSyncDriver,
    makeDescriptor: @escaping DescriptorFactory,
    reservedZones: Set<CloudZoneID> = [],
    operationGate: CloudCollectionOperationGate = CloudCollectionOperationGate(),
    beforeReplacingCollection: @escaping @Sendable () async throws -> Void = {}
  ) {
    self.cloudScope = cloudScope
    self.accountLineage = accountLineage
    self.ownerName = ownerName
    self.localStore = localStore
    self.transport = transport
    self.syncDriver = syncDriver
    self.makeDescriptor = makeDescriptor
    self.reservedZones = reservedZones
    self.operationGate = operationGate
    self.beforeReplacingCollection = beforeReplacingCollection
  }

  package func invalidateRecordSync() async {
    await syncDriver.invalidate()
  }

  package func prepareAutomaticSync(_ descriptor: CloudCollectionDescriptor) async throws {
    try beginOperation()
    defer { finishOperation() }
    try validate(descriptor)
    try await syncDriver.prepareAutomaticSync(context(descriptor))
  }

  /// Fetches the control record before work and again immediately before the only send.
  package func synchronize() async throws -> CloudCollectionStatus {
    try await synchronize(.transfer)
  }

  /// Retries failures that need a clear user action before another CloudKit request.
  package func retrySynchronization() async throws -> CloudCollectionStatus {
    try await synchronize(.retry)
  }

  /// Checks the collection, then lets the record engine choose when to fetch and send.
  package func scheduleSynchronization() async throws -> CloudCollectionStatus {
    try await synchronize(.schedule)
  }

  private func synchronize(_ request: SyncRequest) async throws -> CloudCollectionStatus {
    try beginOperation()
    defer { finishOperation() }
    let local = try await localStore.state()
    // Only an explicit enable may join or create a collection.
    guard !local.keptAfterReset, let active = local.activeNamespace else { return .requiresEnable }
    guard let control = try await currentControl(describing: active) else {
      try await beforeReplacingCollection()
      return try await stopAfterDataReset(in: active)
    }
    try await localStore.finishCleanup(control.zones)
    try await cleanPendingZones(protecting: control.zones)

    switch request {
    case .schedule:
      try await syncDriver.prepareAutomaticSync(context(control))
      if try await localStore.state().activeNamespace == nil { return .purged }
      return .scheduled(active)
    case .retry:
      try await syncDriver.prepareManualRetry(context(control))
    case .transfer:
      break
    }

    let fetchResult = try await syncDriver.fetch(context(control))
    if fetchResult == .purged {
      return try await stopAfterDataReset(in: active)
    }
    guard let checked = try await currentControl(describing: active) else {
      try await beforeReplacingCollection()
      return try await stopAfterDataReset(in: active)
    }
    try await localStore.finishCleanup(checked.zones)
    let sendResult = try await syncDriver.send(context(checked))
    if sendResult == .purged {
      return try await stopAfterDataReset(in: active)
    }
    if let issue = fetchResult.issue { throw CloudSyncIssueError(issue) }
    return request == .retry && sendResult == .settled ? .settled(active) : .on(active)
  }

  /// The control record's collection when it still describes `active`. A missing record, other
  /// zones, or another generation all mean that this device missed an iCloud reset.
  private func currentControl(
    describing active: CloudSyncNamespace
  ) async throws -> CloudCollectionDescriptor? {
    guard let descriptor = try await transport.fetchControl()?.descriptor,
      descriptor.namespace(cloudScope: cloudScope, accountLineage: accountLineage) == active
    else { return nil }
    try validate(descriptor)
    return descriptor
  }

  private func stopAfterDataReset(in namespace: CloudSyncNamespace) async throws -> CloudCollectionStatus {
    guard try await localStore.stopAfterDataReset(in: namespace) else { return .requiresEnable }
    await syncDriver.invalidate()
    return .purged
  }

  private func cleanPendingZones(protecting active: Set<CloudZoneID>) async throws {
    let pending = try await localStore.state().cleanupZones
      .subtracting(active.union(reservedZones))
    guard !pending.isEmpty else { return }
    try await transport.deleteZones(pending)
    try await localStore.finishCleanup(pending)
  }

  private func beginOperation() throws {
    try operationGate.begin()
  }

  private func finishOperation() {
    operationGate.finish()
  }

  private func context(_ descriptor: CloudCollectionDescriptor) -> CloudCollectionSyncContext {
    CloudCollectionSyncContext(
      namespace: descriptor.namespace(
        cloudScope: cloudScope,
        accountLineage: accountLineage
      ),
      metadataZone: descriptor.metadataZone,
      payloadZone: descriptor.payloadZone
    )
  }

  private func validate(_ descriptor: CloudCollectionDescriptor) throws {
    try descriptor.validate(ownerName: ownerName, reservedZones: reservedZones)
  }
}
