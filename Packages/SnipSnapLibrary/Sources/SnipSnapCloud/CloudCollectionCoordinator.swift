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

  package init(
    hasSyncedBefore: Bool,
    activeNamespace: CloudSyncNamespace?,
    cleanupZones: Set<CloudZoneID>
  ) {
    self.hasSyncedBefore = hasSyncedBefore
    self.activeNamespace = activeNamespace
    self.cleanupZones = cleanupZones
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
  func adopt(_ namespace: CloudSyncNamespace) async throws
  func markPurged() async throws
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
  case purged
  case requiresEnable
}

package enum CloudCollectionError: Error, Equatable, Sendable {
  case noActiveCollection
  case invalidDescriptor
}

package enum CloudCollectionStep: Equatable, Sendable {
  case freshZonesCreated
  case controlPublished
  case localCollectionAdopted
  case oldZonesDeleted
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

  package init(
    cloudScope: String,
    accountLineage: String,
    ownerName: String,
    localStore: any CloudCollectionLocalStore,
    transport: any CloudCollectionControlTransport,
    syncDriver: any CloudCollectionSyncDriver,
    makeDescriptor: @escaping DescriptorFactory,
    afterStep: @escaping StepHook = { _ in }
  ) {
    self.cloudScope = cloudScope
    self.accountLineage = accountLineage
    self.ownerName = ownerName
    self.localStore = localStore
    self.transport = transport
    self.syncDriver = syncDriver
    self.makeDescriptor = makeDescriptor
    self.afterStep = afterStep
  }

  package func deleteSyncedContent() async throws -> CloudCollectionStatus {
    guard let current = try await transport.fetchControl() else {
      throw CloudCollectionError.noActiveCollection
    }
    let fresh = makeDescriptor()
    try validate(fresh)
    try await localStore.stageCleanup(fresh.zones)
    try await transport.createZones(fresh.zones)
    try afterStep(.freshZonesCreated)
    let saved = try await transport.saveControl(fresh, replacing: current.version)
    switch saved {
    case .accepted(let accepted):
      try afterStep(.controlPublished)
      let namespace = accepted.descriptor.namespace(
        cloudScope: cloudScope,
        accountLineage: accountLineage
      )
      let oldZones = current.descriptor.zones.subtracting(accepted.descriptor.zones)
      try await localStore.stageCleanup(oldZones)
      try await localStore.adopt(namespace)
      try afterStep(.localCollectionAdopted)
      try await localStore.finishCleanup(accepted.descriptor.zones)
      try await syncDriver.fetch(context(accepted.descriptor))
      try await transport.deleteZones(oldZones)
      try afterStep(.oldZonesDeleted)
      try await localStore.finishCleanup(oldZones)
      return .deletedSyncedContent(namespace)
    case .conflict(let winning):
      try await transport.deleteZones(fresh.zones.subtracting(winning.descriptor.zones))
      try await localStore.finishCleanup(fresh.zones)
      let namespace = winning.descriptor.namespace(
        cloudScope: cloudScope,
        accountLineage: accountLineage
      )
      try await localStore.adopt(namespace)
      try await syncDriver.fetch(context(winning.descriptor))
      return .adoptedRemoteCollection(namespace)
    }
  }

  /// Fetches the control record before work and again immediately before the only send.
  package func synchronize() async throws -> CloudCollectionStatus {
    let local = try await localStore.state()
    guard let control = try await transport.fetchControl() else {
      if local.hasSyncedBefore {
        try await localStore.markPurged()
        return .purged
      }
      return .requiresEnable
    }
    try validate(control.descriptor)
    try await localStore.finishCleanup(control.descriptor.zones)
    try await cleanPendingZones(protecting: control.descriptor.zones)
    let remoteNamespace = control.descriptor.namespace(
      cloudScope: cloudScope,
      accountLineage: accountLineage
    )
    guard local.activeNamespace == remoteNamespace else {
      if let prior = local.activeNamespace {
        try await localStore.stageCleanup(prior.zones.subtracting(control.descriptor.zones))
      }
      try await localStore.adopt(remoteNamespace)
      try await syncDriver.fetch(context(control.descriptor))
      try await cleanPendingZones(protecting: control.descriptor.zones)
      return .adoptedRemoteCollection(remoteNamespace)
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
      try await cleanPendingZones(protecting: checked.descriptor.zones)
      return .adoptedRemoteCollection(checkedNamespace)
    }
    try await syncDriver.send(context(checked.descriptor))
    return .on(remoteNamespace)
  }

  /// Explicit user intent is required before a missing control record may be recreated.
  package func enableSync() async throws -> CloudCollectionStatus {
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
      let namespace = accepted.descriptor.namespace(
        cloudScope: cloudScope,
        accountLineage: accountLineage
      )
      try await localStore.adopt(namespace)
      try await localStore.finishCleanup(accepted.descriptor.zones)
      try await syncDriver.fetch(context(accepted.descriptor))
      return .enabled(namespace)
    case .conflict(let winning):
      let unused = fresh.zones.subtracting(winning.descriptor.zones)
      try await transport.deleteZones(unused)
      try await localStore.finishCleanup(fresh.zones)
      let namespace = winning.descriptor.namespace(
        cloudScope: cloudScope,
        accountLineage: accountLineage
      )
      try await localStore.adopt(namespace)
      try await syncDriver.fetch(context(winning.descriptor))
      return .enabled(namespace)
    }
  }

  private func cleanPendingZones(protecting active: Set<CloudZoneID>) async throws {
    let pending = try await localStore.state().cleanupZones.subtracting(active)
    guard !pending.isEmpty else { return }
    try await transport.deleteZones(pending)
    try await localStore.finishCleanup(pending)
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
      !descriptor.metadataZone.name.isEmpty,
      !descriptor.payloadZone.name.isEmpty,
      descriptor.metadataZone.ownerName == ownerName,
      descriptor.payloadZone.ownerName == ownerName
    else { throw CloudCollectionError.invalidDescriptor }
  }
}
