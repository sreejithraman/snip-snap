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

  package init(
    persistence: SwiftDataSyncModePersistence,
    makeTransport: @escaping TransportFactory
  ) {
    self.persistence = persistence
    self.makeTransport = makeTransport
  }

  package func fetch(
    _ context: CloudCollectionSyncContext
  ) async throws -> CloudCollectionFetchResult {
    let (coordinator, store) = try await recordCoordinator(context)
    try await coordinator.fetchRemote()
    return await store.takeEncryptedDataResetSignal() ? .encryptedDataReset : .fetched
  }

  package func send(
    _ context: CloudCollectionSyncContext
  ) async throws -> CloudCollectionSendResult {
    let (coordinator, store) = try await recordCoordinator(context)
    try await coordinator.sendPending()
    return await store.takeEncryptedDataResetSignal() ? .encryptedDataReset : .sent
  }

  private func recordCoordinator(
    _ context: CloudCollectionSyncContext
  ) async throws -> (CloudFullSyncCoordinator, CloudFullSyncPersistence) {
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
    return (
      CloudFullSyncCoordinator(store: store, transport: makeTransport(context)),
      store
    )
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
