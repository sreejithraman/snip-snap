import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

public struct SnipSnapCloudActiveLibrary: Sendable {
  public let library: any SnipLibrary
  public let recoveryScope: SnipRecoveryScope?

  package init(library: any SnipLibrary, recoveryScope: SnipRecoveryScope?) {
    self.library = library
    self.recoveryScope = recoveryScope
  }
}

@MainActor
public final class SnipSnapCloudLifecycleHooks {
  public typealias SyncAction = @MainActor @Sendable () async -> Void
  private enum Phase: Equatable {
    case idle
    case syncing(followUpRequested: Bool)
  }

  private let syncAction: SyncAction
  private var phase = Phase.idle

  public init(syncWhenPossible: @escaping SyncAction) {
    syncAction = syncWhenPossible
  }

  /// A trigger during a sync returns at once and asks for one more sync after it.
  public func run() async {
    guard phase == .idle else {
      phase = .syncing(followUpRequested: true)
      return
    }
    repeat {
      phase = .syncing(followUpRequested: false)
      await syncAction()
    } while phase == .syncing(followUpRequested: true)
    phase = .idle
  }
}

public enum SnipSnapCloudSyncResult: Equatable, Sendable {
  case noChange
  case contentUpdated
  case libraryReplaced
  case libraryReplacedWithSyncIssue(SyncedContentSyncIssue)
  case libraryReplacedAndSyncCompleted
  case libraryReplacedAndSyncScheduled
  case iCloudDataReset
  case iCloudSignedOut
  case iCloudAccountChanged
  case syncIssue(SyncedContentSyncIssue)
  case syncCompleted
  case syncScheduled
  case iCloudSyncSettingUp(SyncedContentSyncIssue? = nil)
  case iCloudSyncEnabled
  case oldSyncedContentRemovalPending
  case oldSyncedContentRemovalCompleted
}

package actor SnipSnapICloudSyncLifecycle: ICloudAccountStateSource {
  package typealias RecordTransportFactory = @Sendable (
    CloudCollectionSyncContext
  ) -> any CloudRecordTransport

  private static let importID = UUID(
    uuidString: "7b4f8730-42bd-4b56-9117-cc7db03ec46e"
  )!
  private let rootURL: URL
  private let attachmentCacheRootURL: URL?
  private let sourceLibrary: any SnipLibrary
  private let cloudScope: String
  private var accountLineage: String
  private let accountStateSource: (any ICloudAccountStateSource)?
  private let ownerName: String
  private let controlTransport: any CloudCollectionControlTransport
  private let makeRecordTransport: RecordTransportFactory
  private let makeDescriptor: CloudCollectionCoordinator.DescriptorFactory
  private let reservedZones: Set<CloudZoneID>
  private let operationGate: CloudCollectionOperationGate
  private let automaticResultHandler: @Sendable (SnipSnapCloudSyncResult) -> Void
  private var persistence: SwiftDataSyncModePersistence?
  private var collectionCoordinator: CloudCollectionCoordinator?
  private var collectionOwnerID: UUID?

  package init(
    rootURL: URL,
    attachmentCacheRootURL: URL? = nil,
    sourceLibrary: any SnipLibrary,
    syncModeStore: SnipSyncModeStore?,
    cloudScope: String,
    accountLineage: String,
    accountStateSource: (any ICloudAccountStateSource)? = nil,
    ownerName: String,
    controlTransport: any CloudCollectionControlTransport,
    makeRecordTransport: @escaping RecordTransportFactory,
    makeDescriptor: @escaping CloudCollectionCoordinator.DescriptorFactory,
    reservedZones: Set<CloudZoneID> = [],
    operationGate: CloudCollectionOperationGate = CloudCollectionOperationGate(),
    automaticResultHandler: @escaping @Sendable (SnipSnapCloudSyncResult) -> Void = { _ in }
  ) {
    self.rootURL = rootURL
    self.attachmentCacheRootURL = attachmentCacheRootURL
    self.sourceLibrary = sourceLibrary
    persistence = syncModeStore?.persistence
    self.cloudScope = cloudScope
    self.accountLineage = accountLineage
    self.accountStateSource = accountStateSource
    self.ownerName = ownerName
    self.controlTransport = controlTransport
    self.makeRecordTransport = makeRecordTransport
    self.makeDescriptor = makeDescriptor
    self.reservedZones = reservedZones
    self.operationGate = operationGate
    self.automaticResultHandler = automaticResultHandler
  }

  package func enableICloudSync() async throws -> SyncedContentEnableOutcome {
    _ = try await stopRecordedResetIfNeeded()
    try PendingICloudSyncEnable.mark(at: rootURL)
    return try await resumePendingEnable()
  }

  private func resumePendingEnable() async throws -> SyncedContentEnableOutcome {
    let wasICloudActive = SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: rootURL
    ) != nil
    let outcome: SyncedContentEnableOutcome
    do {
      outcome = try await finishPendingEnable()
    } catch where Self.isRetryableSetupError(error) {
      let issue = SnipSnapCloudSyncIssueMapper.issue(for: error)
      PendingICloudSyncEnable.markRetrying(issue, at: rootURL)
      return .settingUp(issue)
    } catch {
      PendingICloudSyncEnable.markNeedsAttention(
        SnipSnapCloudSyncIssueMapper.issue(for: error),
        at: rootURL
      )
      throw error
    }
    switch outcome {
    case .enabled:
      do {
        try PendingICloudSyncEnable.clear(at: rootURL)
      } catch where !wasICloudActive {
        // This attempt switched to the iCloud store, so the caller must reload it.
        // The marker stays, and the next sync finishes the cleanup.
        AppDiagnosticRecorder.live.record(
          .failure(operation: "sync.enable", error: error, visibility: .background)
        )
      }
    case .settingUp(let issue?):
      PendingICloudSyncEnable.markRetrying(issue, at: rootURL)
    case .settingUp(nil):
      break
    }
    return outcome
  }

  @discardableResult
  package func cancelPendingEnable() async throws -> SyncedContentSetupCancellation {
    let activePersistence: SwiftDataSyncModePersistence?
    if let persistence {
      activePersistence = persistence
    } else {
      let manifest = rootURL.appendingPathComponent("activation.json", isDirectory: false)
      activePersistence = FileManager.default.fileExists(atPath: manifest.path)
        ? try SwiftDataSyncModePersistence(
          rootURL: rootURL,
          attachmentCacheRootURL: attachmentCacheRootURL
        ) : nil
    }
    persistence = activePersistence
    if let activePersistence {
      let snapshot = try await activePersistence.snapshot()
      if snapshot.activeStore.kind == .iCloudSync {
        if snapshot.transition?.phase == .swapped {
          try await activePersistence.finishTransition()
          try? await activePersistence.cleanupRetiredStores()
        }
        try PendingICloudSyncEnable.clear(at: rootURL)
        return .switched
      }
      try await activePersistence.cancelPendingICloudEnable()
    }
    try PendingICloudSyncEnable.clear(at: rootURL)
    await clearCollectionCoordinator()
    return .cancelled
  }

  private func finishPendingEnable() async throws -> SyncedContentEnableOutcome {
    if let persistence, let binding = try await persistence.snapshot().activeStore.namespace {
      try await requireAccountLineage(binding.accountLineage)
      if try await persistence.snapshot().transition?.phase == .swapped {
        try await persistence.finishTransition()
        try? await persistence.cleanupRetiredStores()
      }
      return .enabled
    }
    let lineage = try await availableAccountLineage()
    let modePersistence = try await modePersistenceAndImportedSource()
    let storage = try await modePersistence.snapshot()
    let kept = storage.activeStore.quarantinedNamespace
    if let kept, kept.accountLineage != lineage {
      throw ICloudAccountGateError.accountChanged
    }
    let collectionLocal = try SwiftDataCloudCollectionLocalStore(
      rootURL: rootURL,
      persistence: modePersistence
    )
    let bootstrap = CloudCollectionBootstrapper(
      ownerName: ownerName,
      localStore: collectionLocal,
      transport: controlTransport,
      makeDescriptor: makeDescriptor,
      reservedZones: reservedZones
    )
    let descriptor: CloudCollectionDescriptor
    if kept != nil, !storage.keptAfterCloudReset {
      // Read the existing control record before allowing the kept library to rejoin.
      guard let remote = try await controlTransport.fetchControl() else {
        throw CloudCollectionError.noActiveCollection
      }
      try remote.descriptor.validate(ownerName: ownerName, reservedZones: reservedZones)
      descriptor = remote.descriptor
    } else {
      descriptor = try await bootstrap.activeOrCreate(
        afterReset: storage.keptAfterCloudReset ? kept : nil
      )
    }
    let namespace = descriptor.namespace(cloudScope: cloudScope, accountLineage: lineage)
    if let kept, !storage.keptAfterCloudReset, kept != namespace.binding {
      throw SyncModePersistenceError.namespaceMismatch
    }
    accountLineage = lineage
    if kept != nil, !storage.keptAfterCloudReset {
      try await requireAccountLineage(lineage)
      let resumed = try await modePersistence.resumeKeptCloudCache(in: namespace.binding) { library in
        let records = CloudFullSyncPersistence(library: library, namespace: namespace,
          dataZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone)
        for batch in try await records.stagedBatches() {
          try await records.applyStaged(batch.batchID)
        }
        guard try await !records.outboundAdmission().blocksAll else {
          throw CloudCollectionError.syncNeedsAttention
        }
        try await records.clearEngineState()
      }
      if resumed { return .enabled }
    }
    let mode = ICloudSyncModeCoordinator(
      persistence: modePersistence,
      namespace: namespace,
      textZone: descriptor.metadataZone,
      payloadZone: descriptor.payloadZone,
      makeTransport: { [makeRecordTransport] in
        makeRecordTransport(
          CloudCollectionSyncContext(
            namespace: namespace,
            metadataZone: descriptor.metadataZone,
            payloadZone: descriptor.payloadZone
          )
        )
      },
      accountStateSource: accountStateSource,
      initialAccountState: .available(accountLineage: lineage),
      checkSetupCollection: { [weak self] in
        guard let self else { throw CloudCollectionError.syncNeedsAttention }
        try await self.requireControlRecord(for: namespace.binding)
      }
    )
    let status = try await mode.enableOrRetry()
    if !status.activatedCloudStore {
      switch status.state {
      case .on:
        break
      case .settingUp, .syncing:
        return .settingUp(
          status.syncIssue ?? status.attentionReason.flatMap(Self.issue(for:))
        )
      case .needsAttention:
        if let error = Self.accountGateError(for: status.attentionReason) { throw error }
        // The new store may already be active with recovered snips to review.
        guard status.attentionReason == nil, try await modePersistence.snapshot().activeStore.kind == .iCloudSync
        else { throw CloudCollectionError.syncNeedsAttention }
      case .off:
        throw CloudCollectionError.syncNeedsAttention
      }
    }
    await clearCollectionCoordinator()
    collectionCoordinator = try makeCollectionCoordinator(modePersistence)
    return .enabled
  }

  package func checkActiveAccount() async throws -> SnipSnapCloudSyncResult {
    if try await stopRecordedResetIfNeeded() { return .iCloudDataReset }
    do {
      _ = try await checkedActiveBinding()
      return .noChange
    } catch let error as ICloudAccountGateError {
      guard let result = try await stopSync(for: error) else { throw error }
      return result
    }
  }

  package func synchronize() async throws -> SnipSnapCloudSyncResult {
    try await synchronize(retryingUserRecoverableFailures: false)
  }

  package func retrySynchronization() async throws -> SnipSnapCloudSyncResult {
    try await synchronize(retryingUserRecoverableFailures: true)
  }

  private func synchronize(
    retryingUserRecoverableFailures: Bool
  ) async throws -> SnipSnapCloudSyncResult {
    if try await stopRecordedResetIfNeeded() { return .iCloudDataReset }
    do {
      if let coordinator = try await activeCollectionCoordinator() {
        if PendingICloudSyncEnable.exists(at: rootURL), let persistence {
          if try await persistence.snapshot().transition?.phase == .swapped {
            try await persistence.finishTransition()
            try? await persistence.cleanupRetiredStores()
          }
          try PendingICloudSyncEnable.clear(at: rootURL)
          return .iCloudSyncEnabled
        }
        let status = if retryingUserRecoverableFailures {
          try await coordinator.retrySynchronization()
        } else {
          try await coordinator.scheduleSynchronization()
        }
        let result = syncResult(for: status)
        if result == .iCloudDataReset { await clearCollectionCoordinator() }
        return result
      }
      if PendingICloudSyncEnable.exists(at: rootURL)
        || (retryingUserRecoverableFailures && PendingICloudSyncEnable.needsAttention(at: rootURL))
      {
        return switch try await resumePendingEnable() {
        case .settingUp(let issue): .iCloudSyncSettingUp(issue)
        case .enabled: .iCloudSyncEnabled
        }
      }
      return .noChange
    } catch let error as ICloudAccountGateError {
      guard let result = try await stopSync(for: error) else { throw error }
      return result
    }
  }

  package func scheduleAutomaticSync() async throws {
    if try await stopRecordedResetIfNeeded() {
      automaticResultHandler(.iCloudDataReset)
      return
    }
    do {
      guard let coordinator = try await activeCollectionCoordinator(),
        let persistence,
        let binding = try await persistence.snapshot().activeStore.namespace,
        let cached = try? cachedDescriptor(for: binding)
      else { return }
      try await coordinator.prepareAutomaticSync(cached)
    } catch let error as ICloudAccountGateError {
      guard let result = try await stopSync(for: error) else { throw error }
      automaticResultHandler(result)
    }
  }

  package func disableICloudSync(_ choice: SyncedContentDisableChoice) async throws {
    guard let persistence else { return }
    if try await stopRecordedResetIfNeeded() {
      automaticResultHandler(.iCloudDataReset)
      return
    }
    let coordinator: CloudCollectionCoordinator
    do {
      guard let active = try await activeCollectionCoordinator() else { return }
      coordinator = active
    } catch let error as ICloudAccountGateError {
      guard let result = try await stopSync(for: error) else { throw error }
      automaticResultHandler(result)
      return
    }
    if choice == .refreshThenCopy {
      let result = syncResult(for: try await coordinator.synchronize())
      if result == .iCloudDataReset {
        await clearCollectionCoordinator()
        automaticResultHandler(result)
        return
      }
    }
    let snapshot = try await persistence.snapshot()
    guard snapshot.activeStore.kind == .iCloudSync,
      let activeBinding = snapshot.activeStore.namespace
    else { return }
    try PendingICloudSyncEnable.clear(at: rootURL)
    let descriptor = try await descriptor(
      for: activeBinding,
      allowsCachedRoles: choice == .useCurrentCache
    )
    let namespace = descriptor.namespace(
      cloudScope: activeBinding.scope,
      accountLineage: activeBinding.accountLineage
    )
    let mode = ICloudSyncModeCoordinator(
      persistence: persistence,
      namespace: namespace,
      textZone: descriptor.metadataZone,
      payloadZone: descriptor.payloadZone,
      makeTransport: { [makeRecordTransport] in
        makeRecordTransport(
          CloudCollectionSyncContext(
            namespace: namespace,
            metadataZone: descriptor.metadataZone,
            payloadZone: descriptor.payloadZone
          )
        )
      },
      accountStateSource: accountStateSource
    )
    let optOutChoice: ICloudSyncOptOutChoice = choice == .refreshThenCopy
      ? .refreshThenCopy : .useCurrentCacheAfterStaleDataWarning
    let status = try await mode.optOut(optOutChoice)
    guard status.state == .off else { throw CloudSyncRetryableError.itemFailure }
    await clearCollectionCoordinator()
  }

  package func deleteSyncedContent() async throws -> SyncedContentDeleteOutcome {
    if try await stopRecordedResetIfNeeded() {
      automaticResultHandler(.iCloudDataReset)
      throw CloudCollectionError.noActiveCollection
    }
    do {
      guard let coordinator = try await activeCollectionCoordinator() else {
        throw CloudCollectionError.noActiveCollection
      }
      return deleteOutcome(for: try await coordinator.deleteSyncedContent())
    } catch let error as ICloudAccountGateError {
      if let result = try await stopSync(for: error) { automaticResultHandler(result) }
      throw error
    }
  }

  package func activeLibrary() async throws -> SnipSnapCloudActiveLibrary {
    guard let persistence else {
      return SnipSnapCloudActiveLibrary(library: sourceLibrary, recoveryScope: nil)
    }
    let snapshot = try await persistence.snapshot()
    return SnipSnapCloudActiveLibrary(
      library: try await persistence.activeLibrary(),
      recoveryScope: SnipRecoveryScopeFactory.scope(
        forActiveCloudNamespace: snapshot.activeStore.namespace ?? snapshot.activeStore.quarantinedNamespace
      )
    )
  }

  package nonisolated func makeCloudSyncHandler(
    operationGate: AsyncOperationGate,
    syncWhenPossible: SnipSnapCloudSyncHandler.SyncAction? = nil,
    retrySyncWhenPossible: SnipSnapCloudSyncHandler.SyncAction? = nil,
    scheduleSyncAfterLocalChange: SnipSnapCloudSyncHandler.SyncAction? = nil,
    makeAttachmentCoordinator: SnipSnapCloudSyncHandler.AttachmentCoordinatorFactory? = nil
  ) -> SnipSnapCloudSyncHandler {
    SnipSnapCloudSyncHandler(
      persistence: { await self.persistence },
      controlTransport: controlTransport,
      accountStateSource: accountStateSource,
      makeAttachmentCoordinator: makeAttachmentCoordinator ?? { [makeRecordTransport] library, namespace, descriptor in
        CloudAttachmentTransferCoordinator(
          library: library, namespace: namespace, payloadZone: descriptor.payloadZone,
          transport: makeRecordTransport(CloudCollectionSyncContext(namespace: namespace,
            metadataZone: descriptor.metadataZone,
            payloadZone: descriptor.payloadZone)),
          maximumCacheBytes: CloudAttachmentTransferCoordinator.standardMaximumCacheBytes
        )
      },
      ownerName: ownerName, reservedZones: reservedZones, operationGate: operationGate,
      syncWhenPossible: syncWhenPossible, retrySyncWhenPossible: retrySyncWhenPossible,
      scheduleSyncAfterLocalChange: scheduleSyncAfterLocalChange
    )
  }

  package func currentAccountState() async -> ICloudAccountState {
    if let accountStateSource { return await accountStateSource.currentAccountState() }
    return .available(accountLineage: accountLineage)
  }

  private func modePersistenceAndImportedSource() async throws -> SwiftDataSyncModePersistence {
    let value: SwiftDataSyncModePersistence
    if let persistence {
      value = persistence
    } else {
      value = try SwiftDataSyncModePersistence(
        rootURL: rootURL,
        attachmentCacheRootURL: attachmentCacheRootURL
      )
      persistence = value
    }
    try await value.materializeLocalSource()
    let marker = value.initialImportMarkerURL
    guard !FileManager.default.fileExists(atPath: marker.path) else { return value }
    let snapshot = try await sourceLibrary.transferSnapshot(revision: 0)
    let active = try await value.snapshot().activeStore
    let target = try await value.libraryForTransition(storeID: active.id)
    _ = try await target.mergeTransferSnapshot(snapshot, transitionID: Self.importID)
    try DurableFile.write(Data("1".utf8), to: marker)
    return value
  }

  private nonisolated static func isRetryableSetupError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let error = error as? ICloudAccountGateError {
      return error == .temporarilyUnavailable || error == .couldNotDetermine
    }
    if CloudKitRetryPolicy.isTransient(error) { return true }
    if let error = error as? CloudTransportError {
      return error == .fetchFailed || error == .sendFailed
    }
    if error is CloudSyncRetryableError { return true }
    if let error = error as? CloudSyncIssueError { return error.issue.retriesAutomatically }
    return false
  }

  private func availableAccountLineage() async throws -> String {
    switch await currentAccountState() {
    case .available(let lineage): return lineage
    case .noAccount: throw ICloudAccountGateError.noAccount
    case .restricted: throw ICloudAccountGateError.restricted
    case .temporarilyUnavailable: throw ICloudAccountGateError.temporarilyUnavailable
    case .couldNotDetermine: throw ICloudAccountGateError.couldNotDetermine
    }
  }

  private func requireAccountLineage(_ expected: String) async throws {
    guard try await availableAccountLineage() == expected else {
      throw ICloudAccountGateError.accountChanged
    }
  }

  private func activeCollectionCoordinator() async throws -> CloudCollectionCoordinator? {
    guard let persistence, let binding = try await checkedActiveBinding() else {
      await clearCollectionCoordinator()
      return nil
    }
    if let collectionCoordinator { return collectionCoordinator }
    accountLineage = binding.accountLineage
    let coordinator = try makeCollectionCoordinator(persistence)
    collectionCoordinator = coordinator
    return coordinator
  }

  private func checkedActiveBinding() async throws -> ICloudSyncNamespaceBinding? {
    guard let binding = try await persistence?.snapshot().activeStore.namespace else { return nil }
    try await requireAccountLineage(binding.accountLineage)
    return binding
  }

  private func stopRecordedResetIfNeeded() async throws -> Bool {
    guard let persistence else { return false }
    let store = try await persistence.snapshot().activeStore
    guard let namespace = store.namespace,
      try await persistence.recoverRecordedCloudReset(storeID: store.id, namespace: namespace)
    else { return false }
    await clearCollectionCoordinator()
    return true
  }

  private func stopSync(for error: ICloudAccountGateError) async throws -> SnipSnapCloudSyncResult? {
    guard error == .noAccount || error == .accountChanged, let persistence else { return nil }
    let store = try await persistence.snapshot().activeStore
    guard let namespace = store.namespace else { return nil }
    await clearCollectionCoordinator()
    let signedOut = error == .noAccount
    let result = try await persistence.keepCloudCacheLocally(
      storeID: store.id, namespace: namespace, reason: signedOut ? .accountSignedOut : .accountChanged
    )
    switch result {
    case .kept: return signedOut ? .iCloudSignedOut : .iCloudAccountChanged
    case .keptAfterReset: return .iCloudDataReset
    case .sourceReplaced: return nil
    }
  }

  private nonisolated static func accountGateError(
    for reason: ICloudSyncAttentionReason?
  ) -> ICloudAccountGateError? {
    switch reason {
    case .accountStatusUnknown: .couldNotDetermine
    case .accountSignedOut: .noAccount
    case .accountRestricted: .restricted
    case .accountTemporarilyUnavailable: .temporarilyUnavailable
    case .accountChanged: .accountChanged
    default: nil
    }
  }

  private nonisolated static func issue(
    for reason: ICloudSyncAttentionReason
  ) -> SyncedContentSyncIssue? {
    switch reason {
    case .accountStatusUnknown: .checkingAccount
    case .accountTemporarilyUnavailable: .accountTemporarilyUnavailable
    default: nil
    }
  }

  private func requireCurrentCollectionForRecordWork(_ context: CloudRecordWorkContext) async throws {
    try await requireLocalRecordContext(context)
    let descriptor = try await currentControlDescriptor()
    try await requireLocalRecordContext(context)
    if descriptor?.namespace(
      cloudScope: context.binding.scope, accountLineage: context.binding.accountLineage
    ).binding == context.binding { return }
    if descriptor == nil || descriptor?.generation == context.binding.generation {
      // A different account may return no control record for this collection.
      try await requireAccountLineage(context.binding.accountLineage)
      if try await keepLibraryAfterReset(context) { automaticResultHandler(.iCloudDataReset) }
      throw CloudRecordWorkError.replaced
    }
    throw CloudCollectionError.syncNeedsAttention
  }

  private func currentControlDescriptor() async throws -> CloudCollectionDescriptor? {
    let descriptor = try await controlTransport.fetchControl()?.descriptor
    try descriptor?.validate(ownerName: ownerName, reservedZones: reservedZones)
    return descriptor
  }

  private func requireControlRecord(for binding: ICloudSyncNamespaceBinding) async throws {
    guard try await currentControlDescriptor()?.namespace(
      cloudScope: binding.scope, accountLineage: binding.accountLineage
    ).binding == binding else { throw CloudCollectionError.syncNeedsAttention }
  }

  private func makeCollectionCoordinator(
    _ persistence: SwiftDataSyncModePersistence
  ) throws -> CloudCollectionCoordinator {
    let local = try SwiftDataCloudCollectionLocalStore(
      rootURL: rootURL,
      persistence: persistence
    )
    let ownerID = UUID()
    collectionOwnerID = ownerID
    let driver = CloudFullRecordCollectionSyncDriver(
      persistence: persistence,
      makeTransport: makeRecordTransport,
      beforeRecordWork: { [weak self] context in
        guard let self else { throw CloudRecordWorkError.replaced }
        try await self.requireCurrentCollectionForRecordWork(context)
      },
      accountChanged: { [weak self] context in
        guard let self else { throw CloudRecordWorkError.replaced }
        try await self.requireLocalRecordContext(context)
        try await self.requireAccountLineage(context.binding.accountLineage)
      },
      automaticResultHandler: { [weak self] context, result in
        guard let self else { return }
        try await self.deliverAutomaticResult(result, from: context, ownerID: ownerID)
      }
    )
    return CloudCollectionCoordinator(
      cloudScope: cloudScope,
      accountLineage: accountLineage,
      ownerName: ownerName,
      localStore: local,
      transport: controlTransport,
      syncDriver: driver,
      makeDescriptor: makeDescriptor,
      reservedZones: reservedZones,
      operationGate: operationGate,
      beforeReplacingCollection: { [weak self, accountLineage] in
        guard let self else { throw CloudRecordWorkError.replaced }
        try await self.requireAccountLineage(accountLineage)
      }
    )
  }

  private func descriptor(
    for binding: ICloudSyncNamespaceBinding,
    allowsCachedRoles: Bool
  ) async throws -> CloudCollectionDescriptor {
    do {
      if let remote = try await controlTransport.fetchControl() {
        try remote.descriptor.validate(ownerName: ownerName, reservedZones: reservedZones)
        guard remote.descriptor.namespace(
          cloudScope: cloudScope, accountLineage: accountLineage
        ).binding == binding else {
          throw CloudCollectionError.invalidDescriptor
        }
        return remote.descriptor
      }
    } catch where allowsCachedRoles {
      return try cachedDescriptor(for: binding)
    }
    guard allowsCachedRoles else { throw CloudCollectionError.noActiveCollection }
    return try cachedDescriptor(for: binding)
  }

  private func requireLocalRecordContext(_ context: CloudRecordWorkContext) async throws {
    guard let persistence else { throw CloudRecordWorkError.replaced }
    let snapshot = try await persistence.snapshot()
    guard snapshot.activeStore.id == context.storeID,
      snapshot.activeStore.namespace == context.binding,
      snapshot.activeStore.kind == .iCloudSync
    else { throw CloudRecordWorkError.replaced }
  }

  private func keepLibraryAfterReset(_ context: CloudRecordWorkContext) async throws -> Bool {
    guard let persistence, try await persistence.keepCloudCacheLocally(
      storeID: context.storeID, namespace: context.binding, reason: .namespaceChanged
    ) == .keptAfterReset else { return false }
    await clearCollectionCoordinator()
    return true
  }

  private func deliverAutomaticResult(
    _ result: SnipSnapCloudSyncResult,
    from context: CloudRecordWorkContext,
    ownerID: UUID
  ) async throws {
    guard collectionOwnerID == ownerID else { return }
    do { try await requireLocalRecordContext(context) }
    catch CloudRecordWorkError.replaced { return }
    if result == .iCloudSignedOut || result == .iCloudAccountChanged {
      if let stopped = try await stopSync(for: result == .iCloudSignedOut ? .noAccount : .accountChanged) {
        automaticResultHandler(stopped)
      }
      return
    }
    if result == .iCloudDataReset {
      guard try await keepLibraryAfterReset(context) else { return }
      automaticResultHandler(result)
      return
    }
    guard collectionOwnerID == ownerID else { return }
    automaticResultHandler(result)
  }

  private func cachedDescriptor(
    for binding: ICloudSyncNamespaceBinding
  ) throws -> CloudCollectionDescriptor {
    let zones = binding.zones.map { CloudZoneID(name: $0.name, ownerName: $0.ownerName) }
    guard let metadata = zones.first(where: { $0.name.hasPrefix("snips-") }),
      let payload = zones.first(where: { $0.name.hasPrefix("payloads-") })
    else { throw CloudCollectionError.invalidDescriptor }
    let descriptor = CloudCollectionDescriptor(
      generation: binding.generation,
      metadataZone: metadata,
      payloadZone: payload
    )
    try descriptor.validate(ownerName: ownerName, reservedZones: reservedZones)
    return descriptor
  }

  private func clearCollectionCoordinator() async {
    let previous = collectionCoordinator
    collectionCoordinator = nil
    collectionOwnerID = nil
    await previous?.invalidateRecordSync()
  }
}
