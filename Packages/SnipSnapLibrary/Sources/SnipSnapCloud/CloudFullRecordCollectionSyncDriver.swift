import CloudKit
import Foundation
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

  package func fetch(_ context: CloudCollectionSyncContext) async throws {
    let coordinator = try await recordCoordinator(context)
    try await coordinator.fetchRemote()
  }

  package func send(_ context: CloudCollectionSyncContext) async throws {
    let coordinator = try await recordCoordinator(context)
    try await coordinator.sendPending()
  }

  private func recordCoordinator(
    _ context: CloudCollectionSyncContext
  ) async throws -> CloudFullSyncCoordinator {
    let storage = try await persistence.snapshot()
    guard storage.activeStore.namespace == binding(context.namespace),
      storage.activeStore.kind == .iCloudSync
    else { throw SyncModePersistenceError.namespaceMismatch }
    let library = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: context.namespace,
      dataZone: context.metadataZone
    )
    return CloudFullSyncCoordinator(store: store, transport: makeTransport(context))
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
  /// The signed main-app lane uses this one path; local-only apps never construct it.
  package static func cloudKitCoordinator(
    rootURL: URL,
    database: CKDatabase,
    cloudScope: String,
    accountLineage: String,
    ownerName: String,
    controlID: CloudRecordID,
    makeDescriptor: CloudCollectionCoordinator.DescriptorFactory? = nil
  ) throws -> CloudCollectionCoordinator {
    let persistence = try SwiftDataSyncModePersistence(rootURL: rootURL)
    let local = try SwiftDataCloudCollectionLocalStore(
      rootURL: rootURL,
      persistence: persistence
    )
    let driver = CloudFullRecordCollectionSyncDriver(
      persistence: persistence,
      makeTransport: { context in
        CloudKitRecordTransport(
          database: database,
          namespace: context.namespace,
          automaticallyFetchedZones: [context.metadataZone]
        )
      }
    )
    return CloudCollectionCoordinator(
      cloudScope: cloudScope,
      accountLineage: accountLineage,
      ownerName: ownerName,
      localStore: local,
      transport: CloudKitCollectionControlTransport(
        database: database,
        controlID: controlID
      ),
      syncDriver: driver,
      makeDescriptor: makeDescriptor ?? {
        CloudCollectionDescriptor.fresh(ownerName: ownerName)
      }
    )
  }
}
