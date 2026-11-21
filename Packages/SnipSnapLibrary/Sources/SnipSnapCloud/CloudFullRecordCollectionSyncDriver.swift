import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

package struct CloudRecordWorkContext: Equatable, Sendable {
  let collection: CloudCollectionSyncContext
  let storeID: UUID

  var binding: ICloudSyncNamespaceBinding { collection.namespace.binding }
}

package enum CloudRecordWorkError: Error { case replaced }

/// Binds every record operation and result to the active store that created it.
package actor CloudFullRecordCollectionSyncDriver: CloudCollectionSyncDriver {
  package typealias TransportFactory = @Sendable (CloudCollectionSyncContext) -> any CloudRecordTransport
  private struct Owner {
    let context: CloudRecordWorkContext
    let coordinator: CloudFullSyncCoordinator
    let transport: any CloudRecordTransport
  }

  private let persistence: SwiftDataSyncModePersistence
  private let makeTransport: TransportFactory
  private let beforeRecordWork: @Sendable (CloudRecordWorkContext) async throws -> Void
  private let automaticResultHandler: @Sendable (CloudRecordWorkContext, SnipSnapCloudSyncResult) async throws -> Void
  private var active: Owner?

  package init(
    persistence: SwiftDataSyncModePersistence,
    makeTransport: @escaping TransportFactory,
    beforeRecordWork: @escaping @Sendable (CloudRecordWorkContext) async throws -> Void = { _ in },
    automaticResultHandler: @escaping @Sendable (CloudRecordWorkContext, SnipSnapCloudSyncResult) async throws -> Void = { _, _ in }
  ) {
    self.persistence = persistence
    self.makeTransport = makeTransport
    self.beforeRecordWork = beforeRecordWork
    self.automaticResultHandler = automaticResultHandler
  }

  package func invalidate() async {
    let prior = active
    active = nil
    await prior?.transport.reset()
  }

  package func fetch(_ context: CloudCollectionSyncContext) async throws -> CloudCollectionFetchResult {
    let owner = try await recordOwner(context)
    let outcome = try await owner.coordinator.fetchRemote {
      try await self.requireCurrent(owner.context)
    }
    try await requireActive(owner.context)
    if outcome.result == .iCloudDataReset { return .purged }
    if let issue = outcome.issue, outcome.blocksOutbound { throw CloudSyncIssueError(issue) }
    return .fetched(outcome.issue)
  }

  package func prepareAutomaticSync(_ context: CloudCollectionSyncContext) async throws {
    let owner = try await recordOwner(context)
    try await requireActive(owner.context)
    try await owner.coordinator.prepareAutomaticSync(
      beforeApply: { try await self.requireCurrent(owner.context) },
      beforeStateSave: { try await self.requireActive(owner.context) }
    )
  }

  package func send(_ context: CloudCollectionSyncContext) async throws -> CloudCollectionSendResult {
    let owner = try await recordOwner(context)
    let outcome = try await owner.coordinator.sendPendingUntilSettled(
      beforeApply: { try await self.requireCurrent(owner.context) },
      beforeSend: { _ in try await self.requireCurrent(owner.context) }
    )
    try await requireActive(owner.context)
    if outcome.result == .iCloudDataReset { return .purged }
    if let issue = outcome.issue { throw CloudSyncIssueError(issue) }
    return outcome.settled ? .settled : .sent
  }

  package func prepareManualRetry(_ context: CloudCollectionSyncContext) async throws {
    let owner = try await recordOwner(context)
    try await owner.coordinator.prepareManualRetry(
      beforeApply: { try await self.requireCurrent(owner.context) },
      beforeStateSave: { try await self.requireActive(owner.context) }
    )
  }

  private func recordOwner(_ collection: CloudCollectionSyncContext) async throws -> Owner {
    let storage = try await persistence.snapshot()
    let context = CloudRecordWorkContext(collection: collection, storeID: storage.activeStore.id)
    guard storage.activeStore.namespace == context.binding,
      storage.activeStore.kind == .iCloudSync, storage.accountIsolation == nil
    else { throw CloudRecordWorkError.replaced }
    if let active, active.context == context { return active }
    let previous = active
    active = nil
    await previous?.transport.reset()
    let library = try await persistence.libraryForTransition(storeID: context.storeID)
    let lease = try await persistence.activeCloudMutationLease(storeID: context.storeID)
    let store = CloudFullSyncPersistence(
      library: library, namespace: collection.namespace,
      dataZone: collection.metadataZone, payloadZone: collection.payloadZone, mutationLease: lease
    )
    let transport = makeTransport(collection)
    let coordinator = CloudFullSyncCoordinator(store: store, transport: transport) { [weak self] result in
      guard let self else { return }
      try await self.deliver(result, from: context)
    }
    if let automatic = transport as? any CloudAutomaticSyncConfiguring {
      await automatic.configureAutomaticSync(
        workAvailableHandler: { [weak self, weak coordinator] in
          guard let self, let coordinator else { return }
          _ = try? await coordinator.processAutomaticChanges(
            beforeApply: { try await self.requireCurrent(context) },
            beforeStateSave: { try await self.requireActive(context) }
          )
        },
        recordSendGate: { [weak self] in
          guard let self else { throw CloudRecordWorkError.replaced }
          try await self.requireCurrent(context)
        }
      )
    }
    let owner = Owner(context: context, coordinator: coordinator, transport: transport)
    active = owner
    return owner
  }

  private func requireActive(_ context: CloudRecordWorkContext) async throws {
    let storage = try await persistence.snapshot()
    guard active?.context == context, storage.activeStore.id == context.storeID,
      storage.activeStore.namespace == context.binding, storage.activeStore.kind == .iCloudSync,
      storage.accountIsolation == nil, storage.transition == nil
    else { throw CloudRecordWorkError.replaced }
  }

  private func requireCurrent(_ context: CloudRecordWorkContext) async throws {
    try await requireActive(context)
    try await beforeRecordWork(context)
    try await requireActive(context)
  }

  private func deliver(_ result: SnipSnapCloudSyncResult, from context: CloudRecordWorkContext) async throws {
    guard active?.context == context else { return }
    do { try await requireActive(context) }
    catch CloudRecordWorkError.replaced {
      guard result == .iCloudAccountChanged || result == .iCloudSignedOut,
        try await persistence.snapshot().accountIsolation?.storeID == context.storeID
      else { return }
    }
    try await automaticResultHandler(context, result)
    if [.iCloudDataReset, .iCloudAccountChanged, .iCloudSignedOut].contains(result),
      active?.context == context { await invalidate() }
  }
}

package enum CloudCollectionAssembly {
  package static let productionOperationGate = CloudCollectionOperationGate()
  package static let productionControlID = CloudRecordID(
    zone: CloudZoneID(name: "SnipSnapControl", ownerName: CKCurrentUserDefaultName),
    name: "active-collection"
  )

}
