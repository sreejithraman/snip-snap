import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

private struct AccountGuardedCollectionTransport: CloudCollectionControlTransport {
  let base: any CloudCollectionControlTransport
  let accountGuard: @Sendable () async throws -> Void

  func fetchControl() async throws -> CloudCollectionControlRecord? {
    try await accountGuard()
    let value = try await base.fetchControl()
    try await accountGuard()
    return value
  }

  func createZones(_ zones: Set<CloudZoneID>) async throws {
    try await accountGuard()
    try await base.createZones(zones)
    try await accountGuard()
  }

  func saveControl(
    _ descriptor: CloudCollectionDescriptor,
    replacing version: Data?
  ) async throws -> CloudCollectionControlSaveResult {
    try await accountGuard()
    let value = try await base.saveControl(descriptor, replacing: version)
    try await accountGuard()
    return value
  }

  func deleteZones(_ zones: Set<CloudZoneID>) async throws {
    try await accountGuard()
    try await base.deleteZones(zones)
    try await accountGuard()
  }
}

private struct AccountGuardedCollectionLocalStore: CloudCollectionLocalStore {
  let base: any CloudCollectionLocalStore
  let accountGuard: @Sendable () async throws -> Void

  func state() async throws -> CloudCollectionLocalState { try await checked { try await base.state() } }
  func stageCleanup(_ zones: Set<CloudZoneID>) async throws { try await checked { try await base.stageCleanup(zones) } }
  func finishCleanup(_ zones: Set<CloudZoneID>) async throws { try await checked { try await base.finishCleanup(zones) } }
  func adopt(_ namespace: CloudSyncNamespace) async throws { try await checked { try await base.adopt(namespace) } }
  func markPurged() async throws { try await checked { try await base.markPurged() } }
  func markDeletionPending() async throws { try await checked { try await base.markDeletionPending() } }
  func markDeletionCompleted() async throws { try await checked { try await base.markDeletionCompleted() } }
  func beginEncryptedDataReset(from namespace: CloudSyncNamespace) async throws { try await checked { try await base.beginEncryptedDataReset(from: namespace) } }

  private func checked<T: Sendable>(
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await accountGuard()
    let value = try await operation()
    try await accountGuard()
    return value
  }
}

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

public typealias SnipSnapDeferredEnableCompletion = SyncedContentEnableCompletion

extension SyncedContentEnableCompletion {
  package init(binding: ICloudSyncNamespaceBinding, storeID: UUID, issue: SyncedContentSyncIssue? = nil) {
    self.init(namespaceKey: binding.namespaceKey.rawValue, storeID: storeID, issue: issue)
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
  case deferredICloudSyncEnabled(SnipSnapDeferredEnableCompletion)
  case oldSyncedContentRemovalPending
  case oldSyncedContentRemovalCompleted
}

/// The pending iCloud enable marker. No marker means no enable is pending: it finished,
/// was cancelled, or never started.
enum PendingICloudSyncEnable {
  fileprivate enum Phase: Equatable {
    case pending
    case retrying(SyncedContentSyncIssue)
    case needsAttention(SyncedContentSyncIssue)
    case checkingDeferredCompletion(SyncModeDeferredEnableCompletion?)

    var resumesSetup: Bool {
      switch self {
      case .pending, .retrying: true
      case .needsAttention, .checkingDeferredCompletion: false
      }
    }
  }

  private static let pendingValue = "pending"
  private static let legacyFailedValue = Data("needs-attention".utf8)
  private static let legacyRetryPrefix = "retry:"
  private static let retryPrefix = "retry-v2:"
  private static let failurePrefix = "failure-v2:"

  static func exists(at rootURL: URL) -> Bool {
    phase(at: rootURL)?.resumesSetup == true
  }

  static func needsAttention(at rootURL: URL) -> Bool {
    failureIssue(at: rootURL) != nil
  }

  static func requiresDeferredCompletionCheck(at rootURL: URL) -> Bool {
    if case .checkingDeferredCompletion = phase(at: rootURL) { return true }
    return false
  }

  static func failureIssue(at rootURL: URL) -> SyncedContentSyncIssue? {
    guard case .needsAttention(let issue) = phase(at: rootURL) else { return nil }
    return issue
  }

  static func retryIssue(at rootURL: URL) -> SyncedContentSyncIssue? {
    guard case .retrying(let issue) = phase(at: rootURL) else { return nil }
    return issue
  }

  fileprivate static func mark(at rootURL: URL) throws {
    try write(.pending, at: rootURL)
  }

  fileprivate static func markNeedsAttention(_ issue: SyncedContentSyncIssue, at rootURL: URL) {
    guard !requiresDeferredCompletionCheck(at: rootURL) else { return }
    try? write(.needsAttention(issue), at: rootURL)
  }

  fileprivate static func markRetrying(_ issue: SyncedContentSyncIssue, at rootURL: URL) {
    guard !requiresDeferredCompletionCheck(at: rootURL) else { return }
    try? write(.retrying(issue), at: rootURL)
  }

  fileprivate static func clear(at rootURL: URL) throws {
    do {
      try FileManager.default.removeItem(at: url(at: rootURL))
    } catch CocoaError.fileNoSuchFile {}
  }

  private static func url(at rootURL: URL) -> URL {
    SyncModeDeferredEnableCompletion.markerURL(at: rootURL)
  }

  fileprivate static func phase(at rootURL: URL) -> Phase? {
    guard let data = try? Data(contentsOf: url(at: rootURL)) else { return nil }
    if data == legacyFailedValue { return .needsAttention(.appDataIssue) }
    guard let value = String(data: data, encoding: .utf8) else { return .pending }
    if value.hasPrefix(SyncModeDeferredEnableCompletion.prefix) {
      return .checkingDeferredCompletion(SyncModeDeferredEnableCompletion.decode(value))
    }
    if value.hasPrefix(failurePrefix) {
      return .needsAttention(issue(in: value, after: failurePrefix) ?? .appDataIssue)
    }
    if let issue = issue(in: value, after: retryPrefix) ?? legacyRetryIssue(in: value) {
      return .retrying(issue)
    }
    return .pending
  }

  private static func write(_ phase: Phase, at rootURL: URL) throws {
    let value: String
    switch phase {
    case .pending: value = pendingValue
    case .checkingDeferredCompletion(let completion):
      guard let completion else { throw CloudCollectionError.syncNeedsAttention }
      return try completion.record(at: rootURL)
    case .retrying(let issue): value = try retryPrefix + payload(for: issue)
    case .needsAttention(let issue): value = try failurePrefix + payload(for: issue)
    }
    try DurableFile.write(Data(value.utf8), to: url(at: rootURL))
  }

  private static func payload(for issue: SyncedContentSyncIssue) throws -> String {
    try JSONEncoder().encode(issue).base64EncodedString()
  }

  private static func issue(in value: String, after prefix: String) -> SyncedContentSyncIssue? {
    guard value.hasPrefix(prefix),
      let payload = Data(base64Encoded: String(value.dropFirst(prefix.count)))
    else { return nil }
    return try? JSONDecoder().decode(SyncedContentSyncIssue.self, from: payload)
  }

  private static func legacyRetryIssue(in value: String) -> SyncedContentSyncIssue? {
    guard value.hasPrefix(legacyRetryPrefix) else { return nil }
    return switch String(value.dropFirst(legacyRetryPrefix.count)) {
    case "waiting-for-connection": .waitingForConnection
    case "icloud-unavailable": .iCloudUnavailable
    case "retrying-soon": .retryingSoon
    case "checking-account": .checkingAccount
    case "account-temporarily-unavailable": .accountTemporarilyUnavailable
    case "some-changes-pending": .someChangesPending
    case "attachment-unavailable": .attachmentUnavailable
    default: nil
    }
  }
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
  private let accountLineageProvider: (@Sendable () async throws -> String)?
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
    accountLineageProvider: (@Sendable () async throws -> String)? = nil,
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
    self.accountLineageProvider = accountLineageProvider
    self.accountStateSource = accountStateSource
    self.ownerName = ownerName
    self.controlTransport = controlTransport
    self.makeRecordTransport = makeRecordTransport
    self.makeDescriptor = makeDescriptor
    self.reservedZones = reservedZones
    self.operationGate = operationGate
    self.automaticResultHandler = automaticResultHandler
  }

  package func enableICloudSync(offerPeerCopies: Bool = false) async throws -> SyncedContentEnableOutcome {
    try await finishDeferredSetupEnableIfNeeded()
    try await clearSupersededLocalEnable()
    if case .checkingDeferredCompletion = PendingICloudSyncEnable.phase(at: rootURL) {
      return .checked(try await retryCheckedEnableCompletion())
    }
    try PendingICloudSyncEnable.mark(at: rootURL)
    return try await resumePendingEnable(offerPeerCopies: offerPeerCopies)
  }

  package func restoreSetupPeerCopies(_ offer: SyncedContentPeerCopyOffer) async throws -> SyncedContentEnableOutcome {
    guard PendingICloudSyncEnable.exists(at: rootURL) || PendingICloudSyncEnable.needsAttention(at: rootURL),
      SyncModeActivationManifestReader.activeCloudNamespace(atSyncModeRootURL: rootURL) == nil
    else { throw CloudCollectionError.syncNeedsAttention }
    return try await resumePendingEnable(offerPeerCopies: true, restoring: offer)
  }

  private func resumePendingEnable(
    offerPeerCopies: Bool = false, restoring consent: SyncedContentPeerCopyOffer? = nil
  ) async throws -> SyncedContentEnableOutcome {
    let wasICloudActive = SyncModeActivationManifestReader.activeCloudNamespace(
      atSyncModeRootURL: rootURL
    ) != nil
    let outcome: SyncedContentEnableOutcome
    do {
      outcome = try await finishPendingEnable(offerPeerCopies: offerPeerCopies, restoring: consent)
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
    case .checked, .settingUp(nil):
      break
    }
    return outcome
  }

  @discardableResult
  package func cancelPendingEnable() async throws -> SyncedContentSetupCancellation {
    try await finishDeferredSetupEnableIfNeeded()
    try await clearSupersededLocalEnable()
    if let mode = try openExistingModePersistence() {
      let snapshot = try await mode.snapshot()
      if snapshot.activeStore.kind == .iCloudSync, snapshot.accountIsolation == nil {
        if snapshot.transition?.phase == .pointerSwapped {
          try await mode.finishTransition()
          try? await mode.cleanupRetiredStores()
        }
        if case .checkingDeferredCompletion(let expected?) = PendingICloudSyncEnable.phase(at: rootURL),
          let active = try await finishedICloudSwitch(), matches(active, expected)
        {
          return .switched(.init(binding: active.binding, storeID: active.storeID, issue: expected.issue))
        }
        if PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: rootURL) {
          return .switched(try await retryCheckedEnableCompletion())
        }
        try PendingICloudSyncEnable.clear(at: rootURL)
        return .switched(nil)
      }
      try await CloudSetupRetryCapture.retainStagedPointerDeletes(in: mode)
      try await mode.cancelPendingICloudEnable()
    }
    try PendingICloudSyncEnable.clear(at: rootURL)
    await clearCollectionCoordinator()
    return .cancelled
  }

  private func finishPendingEnable(
    offerPeerCopies: Bool, restoring consent: SyncedContentPeerCopyOffer?
  ) async throws -> SyncedContentEnableOutcome {
    try await requireAvailableAccount()
    if let accountLineageProvider {
      accountLineage = try await accountLineageProvider()
    }
    try await requireAccountLineage(accountLineage)
    let modePersistence = try await modePersistenceAndImportedSource()
    let enableLineage = accountLineage
    let descriptor: CloudCollectionDescriptor
    if let consent {
      let expected = try JSONDecoder().decode(CloudSetupPeerRestoreScope.Binding.self, from: consent.scope)
      let storage = try await modePersistence.snapshot()
      guard let transition = storage.transition, expected.matches(transition),
        storage.activeStore.kind == .localOnly, storage.activeStore.id == expected.sourceStoreID,
        let current = try await controlTransport.fetchControl()?.descriptor,
        current.namespace(cloudScope: cloudScope, accountLineage: enableLineage).namespaceKey == expected.namespaceKey
      else { throw CloudCollectionError.syncNeedsAttention }
      try current.validate(ownerName: ownerName, reservedZones: reservedZones)
      descriptor = current
    } else {
      let collectionLocal = try SwiftDataCloudCollectionLocalStore(
        rootURL: rootURL,
        persistence: modePersistence
      )
      if try await collectionLocal.state().encryptedDataReset != nil {
        try await collectionLocal.markPurged()
      }
      let enableGuard: @Sendable () async throws -> Void = { [weak self] in
        guard let self else { return }
        try await self.requireAccountLineage(enableLineage)
      }
      let bootstrap = CloudCollectionBootstrapper(
        ownerName: ownerName,
        localStore: AccountGuardedCollectionLocalStore(
          base: collectionLocal,
          accountGuard: enableGuard
        ),
        transport: AccountGuardedCollectionTransport(
          base: controlTransport,
          accountGuard: enableGuard
        ),
        makeDescriptor: makeDescriptor,
        reservedZones: reservedZones
      )
      descriptor = try await bootstrap.activeOrCreate()
    }
    try await requireAccountLineage(accountLineage)
    let namespace = descriptor.namespace(
      cloudScope: cloudScope,
      accountLineage: accountLineage
    )
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
      checkSetupCollection: { [weak self] in
        guard let self else { throw CloudCollectionError.syncNeedsAttention }
        try await self.requireAccountLineage(enableLineage)
        try await self.requireControlRecord(for: namespace.binding)
        try await self.requireAccountLineage(enableLineage)
      }
    )
    let status = try await mode.enableOrRetry(restoring: consent, offerPeerCopies: offerPeerCopies)
    switch status.state {
    case .on:
      break
    case .settingUp, .syncing:
      return .settingUp(
        status.syncIssue ?? status.attentionReason.flatMap(Self.issue(for:))
      )
    case .needsAttention:
      if let error = Self.accountGateError(for: status.attentionReason) { throw error }
      if status.attentionReason == .transferConflict,
        let offer = await mode.peerCopyOffer
      {
        try await requireAccountLineage(enableLineage)
        try await requireControlRecord(for: namespace.binding)
        try await requireAccountLineage(enableLineage)
        throw offer
      }
      throw CloudCollectionError.syncNeedsAttention
    case .off:
      throw CloudCollectionError.syncNeedsAttention
    }
    await clearCollectionCoordinator()
    collectionCoordinator = try makeCollectionCoordinator(modePersistence)
    if case .checkingDeferredCompletion(let expected?) = PendingICloudSyncEnable.phase(at: rootURL) {
      guard let active = try await finishedICloudSwitch(), matches(active, expected),
        active.binding == namespace.binding, active.storeID == status.activeStoreID
      else { throw CloudCollectionError.syncNeedsAttention }
      return .checked(.init(binding: active.binding, storeID: active.storeID, issue: expected.issue))
    }
    return .enabled
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
    try await finishDeferredSetupEnableIfNeeded()
    try await clearSupersededLocalEnable()
    let enablePhase = PendingICloudSyncEnable.phase(at: rootURL)
    let finished = if enablePhase != nil {
      try await finishedICloudSwitch()
    } else {
      (binding: ICloudSyncNamespaceBinding, storeID: UUID)?.none
    }
    let retryFailedSetup = retryingUserRecoverableFailures && finished == nil
      && PendingICloudSyncEnable.failureIssue(at: rootURL)?.canRetry == true
    if let finished {
      guard case .checkingDeferredCompletion(let expected) = enablePhase else {
        try PendingICloudSyncEnable.clear(at: rootURL)
        return .iCloudSyncEnabled
      }
      do {
        guard matches(finished, expected) else { throw CloudCollectionError.syncNeedsAttention }
        if !retryingUserRecoverableFailures || expected?.issue == nil {
          try await checkDeferredEnable(for: finished.binding)
          return try await deferredEnableResult(for: finished.binding, issue: expected?.issue, storeID: finished.storeID)
        }
      } catch let isolation as CloudAccountIsolationError {
        try PendingICloudSyncEnable.clear(at: rootURL)
        return isolation.syncResult
      } catch CloudCollectionError.syncNeedsAttention {
        // The normal collection path below handles a reset of the switched store.
      }
    } else if enablePhase?.resumesSetup == true || retryFailedSetup {
      switch try await resumePendingEnable(offerPeerCopies: retryingUserRecoverableFailures) {
      case .settingUp(let issue): return .iCloudSyncSettingUp(issue)
      case .enabled: return .iCloudSyncEnabled
      case .checked(let completion): return .deferredICloudSyncEnabled(completion)
      }
    }
    let coordinator: CloudCollectionCoordinator
    do {
      guard let active = try await activeCollectionCoordinator() else { return .noChange }
      coordinator = active
    } catch let isolation as CloudAccountIsolationError {
      return isolation.syncResult
    } catch CloudCollectionError.syncNeedsAttention {
      if let persistence {
        let snapshot = try await persistence.snapshot()
        if snapshot.accountIsolation != nil, snapshot.activeStore.kind == .localOnly {
          return snapshot.accountIsolation?.reason == .signedOut
            ? .iCloudSignedOut : .iCloudAccountChanged
        }
      }
      throw CloudCollectionError.syncNeedsAttention
    }
    let status: CloudCollectionStatus
    do {
      status = if retryingUserRecoverableFailures {
        try await coordinator.retrySynchronization()
      } else {
        try await coordinator.scheduleSynchronization()
      }
    } catch let isolation as CloudAccountIsolationError {
      await clearCollectionCoordinator()
      return isolation.syncResult
    } catch let account as ICloudAccountGateError
      where account == .accountChanged || account == .noAccount
    {
      if let persistence {
        let snapshot = try await persistence.snapshot()
        if snapshot.activeStore.kind == .iCloudSync {
          _ = try await persistence.isolateActiveCloudStore(
            reason: account == .noAccount ? .signedOut : .accountChanged,
            expectedStoreID: snapshot.activeStore.id
          )
        }
      }
      await clearCollectionCoordinator()
      return account == .noAccount ? .iCloudSignedOut : .iCloudAccountChanged
    }
    let result = syncResult(for: status)
    if case .checkingDeferredCompletion = enablePhase {
      switch status {
      case .on(let namespace), .settled(let namespace), .scheduled(let namespace),
        .enabled(let namespace), .adoptedRemoteCollection(let namespace),
        .adoptedRemoteCollectionSettled(let namespace), .adoptedRemoteCollectionScheduled(let namespace):
        return try await deferredEnableResult(for: namespace.binding, issue: nil)
      case .adoptedRemoteCollectionWithIssue(let namespace, let issue):
        return try await deferredEnableResult(for: namespace.binding, issue: issue)
      case .purged:
        try PendingICloudSyncEnable.clear(at: rootURL)
      default: break
      }
    }
    if result == .iCloudDataReset { await clearCollectionCoordinator() }
    return result
  }

  private func openExistingModePersistence() throws -> SwiftDataSyncModePersistence? {
    if let persistence { return persistence }
    guard FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("activation.json").path)
    else { return nil }
    let mode = try SwiftDataSyncModePersistence(rootURL: rootURL, attachmentCacheRootURL: attachmentCacheRootURL)
    persistence = mode
    return mode
  }

  private func clearSupersededLocalEnable() async throws {
    guard PendingICloudSyncEnable.requiresDeferredCompletionCheck(at: rootURL) else { return }
    if let mode = try openExistingModePersistence() {
      let storage = try await mode.snapshot()
      if storage.activeStore.kind == .iCloudSync, storage.accountIsolation == nil { return }
    }
    try PendingICloudSyncEnable.clear(at: rootURL)
  }

  private func retryCheckedEnableCompletion() async throws -> SnipSnapDeferredEnableCompletion {
    guard case .deferredICloudSyncEnabled(let completion) = try await synchronize(retryingUserRecoverableFailures: true)
    else { throw CloudCollectionError.syncNeedsAttention }
    return completion
  }

  private func finishDeferredSetupEnableIfNeeded() async throws {
    guard SyncModeActivationManifestReader.activeCloudNamespace(atSyncModeRootURL: rootURL) != nil,
      let mode = try openExistingModePersistence()
    else { return }
    if try await mode.finishDeferredSetupEnableIfNeeded() { await clearCollectionCoordinator() }
  }

  private func checkDeferredEnable(for binding: ICloudSyncNamespaceBinding) async throws {
    try await requireMatchingAccountForActiveStore()
    try await requireControlRecord(for: binding)
    try await requireMatchingAccountForActiveStore()
  }

  private func deferredEnableResult(
    for binding: ICloudSyncNamespaceBinding, issue: SyncedContentSyncIssue?, storeID: UUID? = nil
  ) async throws -> SnipSnapCloudSyncResult {
    guard let active = try await finishedICloudSwitch(), active.binding == binding,
      storeID.map({ $0 == active.storeID }) ?? true
    else {
      throw CloudCollectionError.syncNeedsAttention
    }
    try SyncModeDeferredEnableCompletion(binding: binding, storeID: active.storeID, issue: issue).record(at: rootURL)
    return .deferredICloudSyncEnabled(.init(binding: binding, storeID: active.storeID, issue: issue))
  }

  package func acknowledgeDeferredEnableCompletion(
    for completion: SnipSnapDeferredEnableCompletion,
    whileCurrent isCurrent: @escaping SyncedContentSettingsModel.EnableCompletionIsCurrent = { true }
  ) async throws -> Bool {
    guard let active = try await checkedEnableMatching(completion) else { return false }
    do {
      try await checkDeferredEnable(for: active.binding)
    } catch is CloudAccountIsolationError {
      try await clearSupersededLocalEnable()
      return false
    } catch CloudCollectionError.syncNeedsAttention {
      return false
    }
    guard try await checkedEnableMatching(completion) != nil else { return false }
    let rootURL = rootURL
    return try await MainActor.run {
      guard isCurrent() else { return false }
      try PendingICloudSyncEnable.clear(at: rootURL)
      return true
    }
  }

  private func checkedEnableMatching(_ completion: SnipSnapDeferredEnableCompletion)
    async throws -> (binding: ICloudSyncNamespaceBinding, storeID: UUID)?
  {
    guard let active = try await finishedICloudSwitch(), active.storeID == completion.storeID,
      active.binding.namespaceKey.rawValue == completion.namespaceKey,
      case .checkingDeferredCompletion(let expected?) = PendingICloudSyncEnable.phase(at: rootURL),
      matches(active, expected), expected.issue == completion.issue
    else { return nil }
    return active
  }

  private func matches(
    _ active: (binding: ICloudSyncNamespaceBinding, storeID: UUID), _ marker: SyncModeDeferredEnableCompletion?
  ) -> Bool {
    marker?.binding == active.binding && marker?.storeID == active.storeID
  }

  private func finishedICloudSwitch() async throws -> (binding: ICloudSyncNamespaceBinding, storeID: UUID)? {
    guard SyncModeActivationManifestReader.activeCloudNamespace(atSyncModeRootURL: rootURL) != nil,
      let mode = try openExistingModePersistence()
    else { return nil }
    let snapshot = try await mode.snapshot()
    guard snapshot.activeStore.kind == .iCloudSync, snapshot.transition == nil,
      snapshot.accountIsolation == nil, let binding = snapshot.activeStore.namespace
    else { return nil }
    return (binding, snapshot.activeStore.id)
  }

  package func scheduleAutomaticSync() async throws {
    try await requireMatchingAccountForActiveStore()
    guard let coordinator = try await locallyActiveCollectionCoordinator(),
      let persistence,
      let binding = try await persistence.snapshot().activeStore.namespace,
      let cached = try? cachedDescriptor(for: binding)
    else { return }
    try await coordinator.prepareAutomaticSync(cached)
  }

  package func disableICloudSync(_ choice: SyncedContentDisableChoice) async throws {
    guard let persistence else { return }
    if choice == .refreshThenCopy {
      guard let coordinator = try await activeCollectionCoordinator() else { return }
      let result = syncResult(for: try await coordinator.synchronize())
      if result == .iCloudDataReset { throw CloudCollectionError.syncNeedsAttention }
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
    guard let coordinator = try await activeCollectionCoordinator() else {
      throw CloudCollectionError.noActiveCollection
    }
    return deleteOutcome(for: try await coordinator.deleteSyncedContent())
  }

  package func activeLibrary() async throws -> SnipSnapCloudActiveLibrary {
    guard let persistence else {
      return SnipSnapCloudActiveLibrary(library: sourceLibrary, recoveryScope: nil)
    }
    let snapshot = try await persistence.snapshot()
    return SnipSnapCloudActiveLibrary(
      library: try await persistence.activeLibrary(),
      recoveryScope: SnipRecoveryScopeFactory.scope(
        forActiveCloudNamespace: snapshot.activeStore.namespace
      )
    )
  }

  package nonisolated func makeAccountCacheHandler(
    operationGate: AsyncOperationGate,
    syncWhenPossible: AppleAccountCacheCoordinatorHandler.SyncAction? = nil,
    retrySyncWhenPossible: AppleAccountCacheCoordinatorHandler.SyncAction? = nil,
    scheduleSyncAfterLocalChange: AppleAccountCacheCoordinatorHandler.ScheduleAction? = nil,
    makeAttachmentCoordinator: AppleAccountCacheCoordinatorHandler.AttachmentCoordinatorFactory? = nil
  ) -> AppleAccountCacheCoordinatorHandler {
    AppleAccountCacheCoordinatorHandler(
      persistence: { await self.persistence },
      controlTransport: controlTransport,
      accountStateSource: self,
      makeSyncCoordinator: { [makeRecordTransport, accountStateSource] persistence, namespace, descriptor in
        ICloudSyncModeCoordinator(
          persistence: persistence, namespace: namespace,
          textZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone,
          makeTransport: {
            makeRecordTransport(CloudCollectionSyncContext(namespace: namespace,
              metadataZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone))
          },
          accountStateSource: accountStateSource
        )
      },
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
    let marker = rootURL.appendingPathComponent("local-source-imported", isDirectory: false)
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

  private func requireAvailableAccount() async throws {
    guard let accountStateSource else { return }
    switch await accountStateSource.currentAccountState() {
    case .available:
      return
    case .noAccount:
      throw ICloudAccountGateError.noAccount
    case .restricted:
      throw ICloudAccountGateError.restricted
    case .temporarilyUnavailable:
      throw ICloudAccountGateError.temporarilyUnavailable
    case .couldNotDetermine:
      throw ICloudAccountGateError.couldNotDetermine
    }
  }

  private func activeCollectionCoordinator() async throws -> CloudCollectionCoordinator? {
    try await requireMatchingAccountForActiveStore()
    guard let persistence else { return nil }
    let snapshot = try await persistence.snapshot()
    guard snapshot.activeStore.namespace != nil else {
      await clearCollectionCoordinator()
      return nil
    }
    if let collectionCoordinator { return collectionCoordinator }
    let coordinator = try makeCollectionCoordinator(persistence)
    collectionCoordinator = coordinator
    return coordinator
  }

  private func locallyActiveCollectionCoordinator() async throws
    -> CloudCollectionCoordinator?
  {
    guard let persistence else { return nil }
    let snapshot = try await persistence.snapshot()
    guard snapshot.activeStore.kind == .iCloudSync,
      snapshot.accountIsolation == nil,
      snapshot.activeStore.namespace != nil
    else {
      await clearCollectionCoordinator()
      return nil
    }
    if let collectionCoordinator { return collectionCoordinator }
    let coordinator = try makeCollectionCoordinator(persistence)
    collectionCoordinator = coordinator
    return coordinator
  }

  private func requireMatchingAccountForActiveStore() async throws {
    guard let persistence, let accountStateSource else { return }
    let snapshot = try await persistence.snapshot()
    guard snapshot.activeStore.kind == .iCloudSync else { return }
    guard snapshot.accountIsolation == nil else {
      await clearCollectionCoordinator()
      throw CloudCollectionError.syncNeedsAttention
    }
    guard let binding = snapshot.activeStore.namespace else {
      await clearCollectionCoordinator()
      throw CloudCollectionError.syncNeedsAttention
    }
    switch await accountStateSource.currentAccountState() {
    case .available(let currentLineage) where currentLineage == binding.accountLineage:
      return
    case .available:
      _ = try await persistence.isolateActiveCloudStore(reason: .accountChanged)
      await clearCollectionCoordinator()
      throw CloudAccountIsolationError.accountChanged
    case .noAccount:
      _ = try await persistence.isolateActiveCloudStore(reason: .signedOut)
      await clearCollectionCoordinator()
      throw CloudAccountIsolationError.signedOut
    case .restricted:
      throw ICloudAccountGateError.restricted
    case .temporarilyUnavailable:
      throw ICloudAccountGateError.temporarilyUnavailable
    case .couldNotDetermine:
      throw ICloudAccountGateError.couldNotDetermine
    }
  }

  private func requireAccountLineage(_ expected: String) async throws {
    guard let accountStateSource else { return }
    switch await accountStateSource.currentAccountState() {
    case .available(let current) where current == expected:
      return
    case .available:
      throw ICloudAccountGateError.accountChanged
    case .noAccount:
      throw ICloudAccountGateError.noAccount
    case .restricted:
      throw ICloudAccountGateError.restricted
    case .temporarilyUnavailable:
      throw ICloudAccountGateError.temporarilyUnavailable
    case .couldNotDetermine:
      throw ICloudAccountGateError.couldNotDetermine
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
    try await requireAccountForRecordWork(context)
    guard let persistence else { throw CloudCollectionError.noActiveCollection }
    let snapshot = try await persistence.snapshot()
    guard snapshot.activeStore.id == context.storeID,
      snapshot.activeStore.namespace == context.binding,
      context.binding.scope == cloudScope, context.binding.accountLineage == accountLineage
    else {
      throw CloudCollectionError.syncNeedsAttention
    }
    try await requireControlRecord(for: context.binding)
    try await requireLocalRecordContext(context)
  }

  private func requireControlRecord(for binding: ICloudSyncNamespaceBinding) async throws {
    guard let remote = try await controlTransport.fetchControl() else {
      throw CloudCollectionError.syncNeedsAttention
    }
    try remote.descriptor.validate(ownerName: ownerName, reservedZones: reservedZones)
    guard remote.descriptor.namespace(
      cloudScope: binding.scope, accountLineage: binding.accountLineage
    ).binding == binding else {
      throw CloudCollectionError.syncNeedsAttention
    }
  }

  private func requireAccountForRecordWork(_ context: CloudRecordWorkContext) async throws {
    guard let accountStateSource, let persistence else { return }
    let account = await accountStateSource.currentAccountState()
    try await requireLocalRecordContext(context)
    switch account {
    case .available(let lineage) where lineage == context.binding.accountLineage: return
    case .available:
      _ = try await persistence.isolateActiveCloudStore(reason: .accountChanged, expectedStoreID: context.storeID)
      throw CloudAccountIsolationError.accountChanged
    case .noAccount:
      _ = try await persistence.isolateActiveCloudStore(reason: .signedOut, expectedStoreID: context.storeID)
      throw CloudAccountIsolationError.signedOut
    case .restricted: throw ICloudAccountGateError.restricted
    case .temporarilyUnavailable: throw ICloudAccountGateError.temporarilyUnavailable
    case .couldNotDetermine: throw ICloudAccountGateError.couldNotDetermine
    }
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
    let expectedLineage = accountLineage
    let accountGuard: @Sendable () async throws -> Void = { [weak self] in
      guard let self else { return }
      try await self.requireAccountLineage(expectedLineage)
    }
    let guardedLocal = AccountGuardedCollectionLocalStore(
      base: local,
      accountGuard: accountGuard
    )
    let guardedTransport = AccountGuardedCollectionTransport(
      base: controlTransport,
      accountGuard: accountGuard
    )
    let driver = CloudFullRecordCollectionSyncDriver(
      persistence: persistence,
      makeTransport: makeRecordTransport,
      beforeRecordWork: { [weak self] context in
        guard let self else { throw CloudRecordWorkError.replaced }
        try await self.requireCurrentCollectionForRecordWork(context)
      },
      automaticResultHandler: { [weak self, local] context, result in
        guard let self else { return }
        try await self.deliverAutomaticResult(result, from: context, ownerID: ownerID, local: local)
      }
    )
    return CloudCollectionCoordinator(
      cloudScope: cloudScope,
      accountLineage: accountLineage,
      ownerName: ownerName,
      localStore: guardedLocal,
      transport: guardedTransport,
      syncDriver: driver,
      makeDescriptor: makeDescriptor,
      reservedZones: reservedZones,
      operationGate: operationGate
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
      snapshot.activeStore.kind == .iCloudSync, snapshot.accountIsolation == nil
    else { throw CloudRecordWorkError.replaced }
  }

  private func deliverAutomaticResult(
    _ result: SnipSnapCloudSyncResult,
    from context: CloudRecordWorkContext,
    ownerID: UUID,
    local: SwiftDataCloudCollectionLocalStore
  ) async throws {
    guard collectionOwnerID == ownerID else { return }
    do { try await requireLocalRecordContext(context) }
    catch CloudRecordWorkError.replaced {
      guard result == .iCloudAccountChanged || result == .iCloudSignedOut,
        let persistence, try await persistence.snapshot().accountIsolation?.storeID == context.storeID
      else { return }
    }
    if result == .iCloudDataReset {
      guard let replacementID = try await local.markPurged(ifMatching: context),
        let persistence, try await persistence.snapshot().activeStore.id == replacementID
      else { return }
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
