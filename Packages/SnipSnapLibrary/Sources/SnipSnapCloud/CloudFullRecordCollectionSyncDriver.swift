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
  private let automaticResultHandler: @Sendable (SnipSnapCloudSyncResult) async throws -> Void
  private var activeContext: CloudCollectionSyncContext?
  private var activeCoordinator: CloudFullSyncCoordinator?
  private var activeStore: CloudFullSyncPersistence?
  private var pendingIssue: SyncedContentSyncIssue?

  package init(
    persistence: SwiftDataSyncModePersistence,
    makeTransport: @escaping TransportFactory,
    beforeAutomaticApply: @escaping @Sendable () async throws -> Void = {},
    beforeAutomaticSchedule: @escaping @Sendable (CloudCollectionSyncContext) async throws -> Void = { _ in },
    beforeEngineStateSave: @escaping @Sendable (CloudCollectionSyncContext) async throws -> Void = { _ in },
    automaticResultHandler: @escaping @Sendable (SnipSnapCloudSyncResult) async throws -> Void = { _ in }
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
    pendingIssue = nil
    if try await store.destructiveResetSignal() != nil { return .purged }
    try await coordinator.fetchRemote(beforeApply: beforeAutomaticApply)
    if try await store.destructiveResetSignal() != nil {
      _ = await coordinator.takeSyncIssue()
      pendingIssue = nil
      return .purged
    }
    let blocksOutbound = await coordinator.isOutboundBlocked()
    if let issue = await coordinator.takeSyncIssue() {
      if blocksOutbound { throw CloudSyncIssueError(issue) }
      pendingIssue = issue
    } else {
      _ = try await store.clearRetryableRecoveryEvents(kind: .retryableFetch)
    }
    return try await store.destructiveResetSignal() == nil ? .fetched : .purged
  }

  package func prepareAutomaticSync(
    _ context: CloudCollectionSyncContext
  ) async throws {
    try await beforeAutomaticSchedule(context)
    let (coordinator, store) = try await recordCoordinator(context)
    pendingIssue = nil
    if try await store.destructiveResetSignal() != nil {
      try await automaticResultHandler(.iCloudDataReset)
      return
    }
    try await coordinator.prepareAutomaticSync(beforeApply: beforeAutomaticApply)
    if try await store.destructiveResetSignal() != nil {
      _ = await coordinator.takeSyncIssue()
      pendingIssue = nil
      try await automaticResultHandler(.iCloudDataReset)
      return
    }
    if let issue = await coordinator.takeSyncIssue() {
      try await automaticResultHandler(.syncIssue(issue))
    }
  }

  package func send(
    _ context: CloudCollectionSyncContext
  ) async throws -> CloudCollectionSendResult {
    let (coordinator, store) = try await recordCoordinator(context)
    if try await store.destructiveResetSignal() != nil { return .purged }
    try await coordinator.sendPending { [beforeAutomaticApply] _ in
      try await beforeAutomaticApply()
    }
    if try await store.destructiveResetSignal() != nil {
      _ = await coordinator.takeSyncIssue()
      pendingIssue = nil
      return .purged
    }
    let issue = await coordinator.takeSyncIssue() ?? pendingIssue
    pendingIssue = nil
    if let issue { throw CloudSyncIssueError(issue) }
    _ = try await store.clearRetryableRecoveryEvents(kind: .retryableSend)
    if let issue = try await store.unresolvedSyncIssue() {
      throw CloudSyncIssueError(issue)
    }
    return try await store.destructiveResetSignal() == nil ? .sent : .purged
  }

  package func prepareManualRetry(
    _ context: CloudCollectionSyncContext
  ) async throws {
    let (_, store) = try await recordCoordinator(context)
    try await store.prepareManualRetry()
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
          do {
            guard let coordinator else { return }
            try await coordinator.applyAutomatically(
              batch,
              outbound: outbound,
              beforeApply: beforeAutomaticApply
            )
            guard let store else { return }
            if try await store.destructiveResetSignal() != nil {
              _ = await coordinator.takeSyncIssue()
              try await automaticResultHandler(.iCloudDataReset)
              return
            }
            if let issue = await coordinator.takeSyncIssue() {
              try await automaticResultHandler(.syncIssue(issue))
              return
            }
            switch batch {
            case .fetched:
              try await automaticResultHandler(
                try await Self.automaticFetchedResult(store: store)
              )
            case .sent:
              try await automaticResultHandler(try await Self.automaticSentResult(store: store))
            }
          } catch {
            try? await automaticResultHandler(
              Self.automaticFailureResult(error)
            )
            throw error
          }
        },
        accountChangeHandler: { [beforeAutomaticApply, automaticResultHandler] in
          do {
            try await beforeAutomaticApply()
          } catch {
            try? await automaticResultHandler(Self.automaticFailureResult(error))
          }
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
    pendingIssue = nil
    return (coordinator, store)
  }

  package static func automaticSentResult(
    store: CloudFullSyncPersistence
  ) async throws -> SnipSnapCloudSyncResult {
    _ = try await store.clearRetryableRecoveryEvents(kind: .retryableSend)
    let settled = try await store.isSyncSettled()
    return settled ? .syncCompleted : .noChange
  }

  package static func automaticFetchedResult(
    store: CloudFullSyncPersistence
  ) async throws -> SnipSnapCloudSyncResult {
    let recovered = try await store.clearRetryableRecoveryEvents(kind: .retryableFetch)
    let settled = try await store.isSyncSettled()
    return recovered && settled ? .syncCompleted : .contentUpdated
  }

  package static func automaticFailureResult(_ error: any Error) -> SnipSnapCloudSyncResult {
    automaticSyncResult(for: error)
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
