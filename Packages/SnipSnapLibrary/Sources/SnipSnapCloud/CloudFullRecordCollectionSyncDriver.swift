import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

/// Builds a namespace-bound record driver only after the control coordinator authorizes it.
package actor CloudFullRecordCollectionSyncDriver: CloudCollectionSyncDriver {
  package typealias TransportFactory = @Sendable (
    CloudCollectionSyncContext
  ) -> any CloudRecordTransport

  private let persistence: SwiftDataSyncModePersistence
  private let makeTransport: TransportFactory
  private let beforeAutomaticApply: @Sendable () async throws -> Void
  private let beforeAutomaticSchedule: @Sendable (CloudCollectionSyncContext) async throws -> Void
  private let beforeEngineStateSave: @Sendable (CloudCollectionSyncContext) async throws -> Void
  private let automaticResultHandler: @Sendable (CloudCollectionFetchResult) async -> Void
  private var activeContext: CloudCollectionSyncContext?
  private var activeCoordinator: CloudFullSyncCoordinator?
  private var activeStore: CloudFullSyncPersistence?

  package init(
    persistence: SwiftDataSyncModePersistence,
    makeTransport: @escaping TransportFactory,
    beforeAutomaticApply: @escaping @Sendable () async throws -> Void = {},
    beforeAutomaticSchedule: @escaping @Sendable (CloudCollectionSyncContext) async throws -> Void = { _ in },
    beforeEngineStateSave: @escaping @Sendable (CloudCollectionSyncContext) async throws -> Void = { _ in },
    automaticResultHandler: @escaping @Sendable (CloudCollectionFetchResult) async -> Void = { _ in }
  ) {
    self.persistence = persistence
    self.makeTransport = makeTransport
    self.beforeAutomaticApply = beforeAutomaticApply
    self.beforeAutomaticSchedule = beforeAutomaticSchedule
    self.beforeEngineStateSave = beforeEngineStateSave
    self.automaticResultHandler = automaticResultHandler
  }

  package func fetch(
    _ context: CloudCollectionSyncContext
  ) async throws -> CloudCollectionFetchResult {
    let (coordinator, store) = try await recordCoordinator(context)
    try await coordinator.fetchRemote(beforeApply: beforeAutomaticApply)
    return await store.takeEncryptedDataResetSignal() ? .encryptedDataReset : .fetched
  }

  package func prepareAutomaticSync(
    _ context: CloudCollectionSyncContext
  ) async throws {
    try await beforeAutomaticSchedule(context)
    let (coordinator, _) = try await recordCoordinator(context)
    try await coordinator.prepareAutomaticSync()
  }

  package func send(
    _ context: CloudCollectionSyncContext
  ) async throws -> CloudCollectionSendResult {
    let (coordinator, store) = try await recordCoordinator(context)
    try await coordinator.sendPending { [beforeAutomaticApply] _ in
      try await beforeAutomaticApply()
    }
    return await store.takeEncryptedDataResetSignal() ? .encryptedDataReset : .sent
  }

  private func recordCoordinator(
    _ context: CloudCollectionSyncContext
  ) async throws -> (CloudFullSyncCoordinator, CloudFullSyncPersistence) {
    if activeContext == context, let activeCoordinator, let activeStore {
      return (activeCoordinator, activeStore)
    }
    let storage = try await persistence.snapshot()
    guard storage.activeStore.namespace == binding(context.namespace),
      storage.activeStore.kind == .iCloudSync
    else { throw SyncModePersistenceError.namespaceMismatch }
    let library = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: context.namespace,
      dataZone: context.metadataZone,
      payloadZone: context.payloadZone
    )
    let transport = makeTransport(context)
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport)
    if let automatic = transport as? any CloudAutomaticSyncConfiguring {
      await automatic.configureAutomaticSync(
        batchHandler: {
          [weak coordinator, weak store, beforeAutomaticApply, automaticResultHandler]
          batch, outbound in
          guard let coordinator else { return }
          try await coordinator.applyAutomatically(
            batch,
            outbound: outbound,
            beforeApply: beforeAutomaticApply
          )
          guard let store else { return }
          await automaticResultHandler(
            await store.takeEncryptedDataResetSignal() ? .encryptedDataReset : .fetched
          )
        },
        accountChangeHandler: { [beforeAutomaticApply] in
          _ = try? await beforeAutomaticApply()
        },
        recordSendGate: beforeAutomaticApply,
        engineStateHandler: { [weak coordinator, beforeEngineStateSave] state in
          try await beforeEngineStateSave(context)
          guard let coordinator else { return }
          try await coordinator.persistEngineState(state)
        }
      )
    }
    activeContext = context
    activeCoordinator = coordinator
    activeStore = store
    return (coordinator, store)
  }

  private func binding(_ namespace: CloudSyncNamespace) -> ICloudSyncNamespaceBinding {
    ICloudSyncNamespaceBinding(
      scope: namespace.cloudScope,
      accountLineage: namespace.accountLineage,
      generation: namespace.generation,
      zones: Set(namespace.zones.map {
        ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
      })
    )
  }
}

package enum CloudCollectionAssembly {
  package static let productionOperationGate = CloudCollectionOperationGate()
  package static let productionControlID = CloudRecordID(
    zone: CloudZoneID(name: "SnipSnapControl", ownerName: CKCurrentUserDefaultName),
    name: "active-collection"
  )

}
