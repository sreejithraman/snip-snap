import Foundation

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
  package let deletionState: CloudCollectionDeletionState

  package init(
    hasSyncedBefore: Bool,
    activeNamespace: CloudSyncNamespace?,
    cleanupZones: Set<CloudZoneID>,
    deletionState: CloudCollectionDeletionState = .none
  ) {
    self.hasSyncedBefore = hasSyncedBefore
    self.activeNamespace = activeNamespace
    self.cleanupZones = cleanupZones
    self.deletionState = deletionState
  }
}

package enum CloudCollectionDeletionState: String, Codable, Equatable, Sendable {
  case none
  case pending
  case completed
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
  func adopt(_ namespace: CloudSyncNamespace) async throws
  func markPurged() async throws
  func markDeletionPending() async throws
  func markDeletionCompleted() async throws
}

package protocol CloudCollectionSyncDriver: Sendable {
  func fetch(_ context: CloudCollectionSyncContext) async throws
  func send(_ context: CloudCollectionSyncContext) async throws
}

package enum CloudCollectionStatus: Equatable, Sendable {
  case on(CloudSyncNamespace)
  case enabled(CloudSyncNamespace)
  case adoptedRemoteCollection(CloudSyncNamespace)
  case deletedSyncedContent(CloudSyncNamespace)
  case oldSyncedContentRemovalPending(CloudSyncNamespace)
  case purged
  case requiresEnable
}

package enum CloudCollectionError: LocalizedError, Equatable, Sendable {
  case noActiveCollection
  case invalidDescriptor
  case operationInProgress

  package var errorDescription: String? {
    switch self {
    case .noActiveCollection:
      "iCloud Sync does not have an active collection."
    case .invalidDescriptor:
      "The iCloud Sync collection is not valid."
    case .operationInProgress:
      "Another iCloud Sync task is still running."
    }
  }
}

package enum CloudCollectionStep: Equatable, Sendable {
  case freshZonesCreated
  case controlPublished
  case localCollectionAdopted
  case oldZonesDeleted
}

/// Creates or adopts the collection control record without changing the local mode pointer.
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

  package func activeOrCreate() async throws -> CloudCollectionDescriptor {
    if let current = try await transport.fetchControl() {
      try validate(current.descriptor)
      return current.descriptor
    }
    let fresh = makeDescriptor()
    try validate(fresh)
    try await transport.createZones(fresh.zones)
    switch try await transport.saveControl(fresh, replacing: nil) {
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
      return winner.descriptor
    }
  }

  private func validate(_ descriptor: CloudCollectionDescriptor) throws {
    guard descriptor.metadataZone != descriptor.payloadZone,
      descriptor.zones.isDisjoint(with: reservedZones),
      !descriptor.metadataZone.name.isEmpty,
      !descriptor.payloadZone.name.isEmpty,
      descriptor.metadataZone.ownerName == ownerName,
      descriptor.payloadZone.ownerName == ownerName
    else { throw CloudCollectionError.invalidDescriptor }
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

/// Owns the generation check and the reset order for one private CloudKit collection.
package actor CloudCollectionCoordinator {
  package typealias DescriptorFactory = @Sendable () -> CloudCollectionDescriptor
  package typealias StepHook = @Sendable (CloudCollectionStep) throws -> Void

  private let cloudScope: String
  private let accountLineage: String
  private let ownerName: String
  private let localStore: any CloudCollectionLocalStore
  private let transport: any CloudCollectionControlTransport
  private let syncDriver: any CloudCollectionSyncDriver
  private let makeDescriptor: DescriptorFactory
  private let afterStep: StepHook
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
    afterStep: @escaping StepHook = { _ in }
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
    self.afterStep = afterStep
  }

  package func deleteSyncedContent() async throws -> CloudCollectionStatus {
    try beginOperation()
    defer { finishOperation() }
    guard let current = try await transport.fetchControl() else {
      throw CloudCollectionError.noActiveCollection
    }
    try validate(current.descriptor)
    let fresh = makeDescriptor()
    try validate(fresh)
    try await localStore.stageCleanup(fresh.zones)
    try await transport.createZones(fresh.zones)
    try afterStep(.freshZonesCreated)
    let saved = try await transport.saveControl(fresh, replacing: current.version)
    switch saved {
    case .accepted(let accepted):
      try validate(accepted.descriptor)
      try await localStore.markDeletionPending()
      try afterStep(.controlPublished)
      let namespace = accepted.descriptor.namespace(
        cloudScope: cloudScope,
        accountLineage: accountLineage
      )
      let oldZones = current.descriptor.zones.subtracting(accepted.descriptor.zones)
      try await localStore.stageCleanup(oldZones)
      try await localStore.adopt(namespace)
      try afterStep(.localCollectionAdopted)
      await finishCleanupWhenPossible(accepted.descriptor.zones)
      await fetchWhenPossible(accepted.descriptor)
      guard await deleteZonesWhenPossible(oldZones) else {
        return .oldSyncedContentRemovalPending(namespace)
      }
      try afterStep(.oldZonesDeleted)
      await finishCleanupWhenPossible(oldZones)
      try await localStore.markDeletionCompleted()
      return .deletedSyncedContent(namespace)
    case .conflict(let winning):
      try validate(winning.descriptor)
      let oldZones = current.descriptor.zones.subtracting(winning.descriptor.zones)
      try await localStore.stageCleanup(oldZones)
      let namespace = winning.descriptor.namespace(
        cloudScope: cloudScope,
        accountLineage: accountLineage
      )
      try await localStore.adopt(namespace)
      try await localStore.markDeletionPending()
      await fetchWhenPossible(winning.descriptor)
      await cleanPendingZonesWhenPossible(protecting: winning.descriptor.zones)
      let pending = try await localStore.state().cleanupZones
        .subtracting(winning.descriptor.zones.union(reservedZones))
      if pending.isEmpty {
        try await localStore.markDeletionCompleted()
        return .deletedSyncedContent(namespace)
      }
      return .oldSyncedContentRemovalPending(namespace)
    }
  }

  /// Fetches the control record before work and again immediately before the only send.
  package func synchronize() async throws -> CloudCollectionStatus {
    try beginOperation()
    defer { finishOperation() }
    let local = try await localStore.state()
    guard let control = try await transport.fetchControl() else {
      if local.hasSyncedBefore {
        try await localStore.markPurged()
        return .purged
      }
      return .requiresEnable
    }
    try validate(control.descriptor)
    let remoteNamespace = control.descriptor.namespace(
      cloudScope: cloudScope,
      accountLineage: accountLineage
    )
    try await localStore.finishCleanup(control.descriptor.zones)
    do {
      try await cleanPendingZones(protecting: control.descriptor.zones)
    } catch {
      if local.deletionState == .pending {
        return .oldSyncedContentRemovalPending(remoteNamespace)
      }
      throw error
    }
    let cleanedLocal = try await localStore.state()
    guard local.activeNamespace == remoteNamespace else {
      if let prior = local.activeNamespace {
        try await localStore.stageCleanup(prior.zones.subtracting(control.descriptor.zones))
      }
      try await localStore.adopt(remoteNamespace)
      try await syncDriver.fetch(context(control.descriptor))
      do {
        try await cleanPendingZones(protecting: control.descriptor.zones)
      } catch {
        if (try await localStore.state()).deletionState == .pending {
          return .oldSyncedContentRemovalPending(remoteNamespace)
        }
        throw error
      }
      return try await deletionStatusIfNeeded(
        cleanedLocal.deletionState,
        remoteNamespace,
        fallback: .adoptedRemoteCollection(remoteNamespace)
      )
    }

    try await syncDriver.fetch(context(control.descriptor))
    guard let checked = try await transport.fetchControl() else {
      try await localStore.markPurged()
      return .purged
    }
    try validate(checked.descriptor)
    try await localStore.finishCleanup(checked.descriptor.zones)
    let checkedNamespace = checked.descriptor.namespace(
      cloudScope: cloudScope,
      accountLineage: accountLineage
    )
    guard checkedNamespace == remoteNamespace else {
      try await localStore.stageCleanup(
        remoteNamespace.zones.subtracting(checked.descriptor.zones)
      )
      try await localStore.adopt(checkedNamespace)
      try await syncDriver.fetch(context(checked.descriptor))
      do {
        try await cleanPendingZones(protecting: checked.descriptor.zones)
      } catch {
        if (try await localStore.state()).deletionState == .pending {
          return .oldSyncedContentRemovalPending(checkedNamespace)
        }
        throw error
      }
      let state = try await localStore.state()
      return try await deletionStatusIfNeeded(
        state.deletionState,
        checkedNamespace,
        fallback: .adoptedRemoteCollection(checkedNamespace)
      )
    }
    try await syncDriver.send(context(checked.descriptor))
    let state = try await localStore.state()
    return try await deletionStatusIfNeeded(
      state.deletionState,
      remoteNamespace,
      fallback: .on(remoteNamespace)
    )
  }

  /// Explicit user intent is required before a missing control record may be recreated.
  package func enableSync() async throws -> CloudCollectionStatus {
    try beginOperation()
    defer { finishOperation() }
    if let current = try await transport.fetchControl() {
      try validate(current.descriptor)
      try await localStore.finishCleanup(current.descriptor.zones)
      let namespace = current.descriptor.namespace(
        cloudScope: cloudScope,
        accountLineage: accountLineage
      )
      try await cleanPendingZones(protecting: current.descriptor.zones)
      if try await localStore.state().activeNamespace != namespace {
        try await localStore.adopt(namespace)
      }
      try await syncDriver.fetch(context(current.descriptor))
      return .enabled(namespace)
    }

    let fresh = makeDescriptor()
    try validate(fresh)
    try await localStore.stageCleanup(fresh.zones)
    try await transport.createZones(fresh.zones)
    let result = try await transport.saveControl(fresh, replacing: nil)
    switch result {
    case .accepted(let accepted):
      try validate(accepted.descriptor)
      let namespace = accepted.descriptor.namespace(
        cloudScope: cloudScope,
        accountLineage: accountLineage
      )
      try await localStore.adopt(namespace)
      try await localStore.finishCleanup(accepted.descriptor.zones)
      try await syncDriver.fetch(context(accepted.descriptor))
      try await cleanPendingZones(protecting: accepted.descriptor.zones)
      return .enabled(namespace)
    case .conflict(let winning):
      try validate(winning.descriptor)
      let namespace = winning.descriptor.namespace(
        cloudScope: cloudScope,
        accountLineage: accountLineage
      )
      try await localStore.adopt(namespace)
      try await syncDriver.fetch(context(winning.descriptor))
      try await cleanPendingZones(protecting: winning.descriptor.zones)
      return .enabled(namespace)
    }
  }

  private func cleanPendingZones(protecting active: Set<CloudZoneID>) async throws {
    let pending = try await localStore.state().cleanupZones
      .subtracting(active.union(reservedZones))
    guard !pending.isEmpty else { return }
    try await transport.deleteZones(pending)
    try await localStore.finishCleanup(pending)
  }

  private func fetchWhenPossible(_ descriptor: CloudCollectionDescriptor) async {
    try? await syncDriver.fetch(context(descriptor))
  }

  private func deleteZonesWhenPossible(_ zones: Set<CloudZoneID>) async -> Bool {
    do {
      try await transport.deleteZones(zones)
      return true
    } catch {
      return false
    }
  }

  private func finishCleanupWhenPossible(_ zones: Set<CloudZoneID>) async {
    try? await localStore.finishCleanup(zones)
  }

  private func cleanPendingZonesWhenPossible(protecting active: Set<CloudZoneID>) async {
    try? await cleanPendingZones(protecting: active)
  }

  private func beginOperation() throws {
    try operationGate.begin()
  }

  private func finishOperation() {
    operationGate.finish()
  }

  private func deletionStatusIfNeeded(
    _ state: CloudCollectionDeletionState,
    _ namespace: CloudSyncNamespace,
    fallback: CloudCollectionStatus
  ) async throws -> CloudCollectionStatus {
    switch state {
    case .none:
      return fallback
    case .pending:
      let pending = try await localStore.state().cleanupZones
        .subtracting(namespace.zones.union(reservedZones))
      guard pending.isEmpty else {
        return .oldSyncedContentRemovalPending(namespace)
      }
      try await localStore.markDeletionCompleted()
      return .deletedSyncedContent(namespace)
    case .completed:
      return .deletedSyncedContent(namespace)
    }
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
    guard descriptor.metadataZone != descriptor.payloadZone,
      descriptor.zones.isDisjoint(with: reservedZones),
      !descriptor.metadataZone.name.isEmpty,
      !descriptor.payloadZone.name.isEmpty,
      descriptor.metadataZone.ownerName == ownerName,
      descriptor.payloadZone.ownerName == ownerName
    else { throw CloudCollectionError.invalidDescriptor }
  }
}
