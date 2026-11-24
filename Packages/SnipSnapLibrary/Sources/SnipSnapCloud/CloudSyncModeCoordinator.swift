import Foundation
import SnipSnapCore
import SnipSnapPersistence

package enum ICloudAccountGateError: Error, Equatable, Sendable {
    case couldNotDetermine
    case noAccount
    case restricted
    case temporarilyUnavailable
    case accountChanged
}

private actor FullRecordSyncAdapter {
    private let raw: CloudFullSyncPersistence
    private let syncDriver: CloudFullSyncCoordinator
    private var pendingIssue: SyncedContentSyncIssue?

    init(
        raw: CloudFullSyncPersistence,
        transport: any CloudRecordTransport,
        accountChanged: @escaping CloudFullSyncPersistence.ApplyHook
    ) {
        self.raw = raw
        syncDriver = CloudFullSyncCoordinator(
            store: raw,
            transport: transport,
            fetchScope: .zones([raw.dataZone]),
            accountChanged: accountChanged
        )
    }

    func fetchRemote(
        beforeApply: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        pendingIssue = nil
        let outcome = try await syncDriver.fetchRemote(beforeApply: beforeApply)
        try retainFetchIssue(outcome)
    }

    private func retainFetchIssue(_ outcome: CloudFullSyncOutcome) throws {
        if let issue = outcome.issue {
            if outcome.blocksOutbound { throw CloudSyncIssueError(issue) }
            pendingIssue = issue
        }
    }

    func takeSyncIssue() async -> SyncedContentSyncIssue? {
        defer { pendingIssue = nil }
        return pendingIssue
    }

    func approveModeMerge(snipIDs: Set<UUID>) async throws {
        try await raw.approveModeMerge(snipIDs: snipIDs)
    }

    func enrollmentEvidence() async throws -> CloudTextEnrollmentEvidence {
        try await raw.enrollmentEvidence()
    }

    func dormantAcceptedBaseTransferPayload() async throws -> Data? {
        try await raw.dormantAcceptedBaseTransferPayload()
    }

    func canPrepareModeMerge() async throws -> Bool {
        try await raw.isReenableReady()
    }

    func makeReenableApplyPlan(
        source: SnipLibraryTransferSnapshot, transitionID: UUID
    ) async throws -> CloudFullReenableApplyPlan? {
        try await raw.makeReenableApplyPlan(source: source, transitionID: transitionID)
    }

    func acceptedSnipIDs() async throws -> Set<UUID> {
        try await raw.acceptedSnipIDs()
    }

    func clearRetryableEvents(_ keys: Set<String>) async throws {
        try await raw.clearRetryableEvents(keys)
    }

}

package enum ICloudSyncModeState: String, Codable, Equatable, Sendable {
    case off
    case settingUp
    case on
    case syncing
    case needsAttention
}

package struct ICloudSyncModeStatus: Equatable, Sendable {
    package let state: ICloudSyncModeState
    package let activeStoreID: UUID
    package let attentionReason: ICloudSyncAttentionReason?
    package let syncIssue: SyncedContentSyncIssue?
    let activatedCloudStore: Bool

    package init(
        state: ICloudSyncModeState,
        activeStoreID: UUID,
        attentionReason: ICloudSyncAttentionReason? = nil,
        syncIssue: SyncedContentSyncIssue? = nil,
        activatedCloudStore: Bool = false
    ) {
        self.state = state
        self.activeStoreID = activeStoreID
        self.attentionReason = attentionReason
        self.syncIssue = syncIssue
        self.activatedCloudStore = activatedCloudStore
    }
}

package enum ICloudSyncOptOutChoice: Equatable, Sendable {
    case refreshThenCopy
    case useCurrentCacheAfterStaleDataWarning
    case cancel
}

/// Coordinates safe mode changes while platform startup owns only assembly and presentation.
package actor ICloudSyncModeCoordinator {
    package typealias TransportFactory = @Sendable () -> any CloudRecordTransport

    private let persistence: SwiftDataSyncModePersistence
    private let namespace: CloudSyncNamespace
    private let textZone: CloudZoneID
    private let payloadZone: CloudZoneID?
    private let attachmentPolicy: CloudAttachmentCompatibilityPolicy
    private let makeTransport: TransportFactory
    private let accountStateSource: any ICloudAccountStateSource
    private let initialAccountState: ICloudAccountState?
    private let checkSetupCollection: @Sendable () async throws -> Void
    private enum Operation { case enable, optOut }
    private var currentOperation: Operation?

    package init(
        persistence: SwiftDataSyncModePersistence,
        namespace: CloudSyncNamespace,
        textZone: CloudZoneID,
        payloadZone: CloudZoneID? = nil,
        attachmentPolicy: CloudAttachmentCompatibilityPolicy = .openSourceDefault,
        makeTransport: @escaping TransportFactory,
        accountStateSource: (any ICloudAccountStateSource)? = nil,
        initialAccountState: ICloudAccountState? = nil,
        checkSetupCollection: @escaping @Sendable () async throws -> Void = {}
    ) {
        precondition(namespace.zones.contains(textZone))
        precondition(payloadZone.map(namespace.zones.contains) ?? true)
        self.persistence = persistence
        self.namespace = namespace
        self.textZone = textZone
        self.payloadZone = payloadZone
        self.attachmentPolicy = attachmentPolicy
        self.makeTransport = makeTransport
        self.accountStateSource = accountStateSource ?? FixedICloudAccountStateSource(
            state: .available(accountLineage: namespace.accountLineage)
        )
        self.initialAccountState = initialAccountState
        self.checkSetupCollection = checkSetupCollection
    }

    private func updateAccountStatus(_ accountState: ICloudAccountState) async throws -> ICloudSyncModeStatus {
        let store = try await persistence.snapshot().activeStore
        if let binding = store.namespace {
            if case .noAccount = accountState {
                try await persistence.keepCloudCacheLocally(storeID: store.id, namespace: binding, reason: .accountSignedOut)
            } else if case .available(let lineage) = accountState, binding.accountLineage != lineage {
                try await persistence.keepCloudCacheLocally(storeID: store.id, namespace: binding, reason: .accountChanged)
            }
        }
        return try await statusUnchecked(accountState: accountState)
    }

    @discardableResult
    package func enableOrRetry() async throws -> ICloudSyncModeStatus {
        try begin(.enable)
        defer { end() }
        let initial = try await persistence.snapshot()
        if initial.activeStore.kind == .iCloudSync {
            try await persistence.requireActiveNamespace(namespace.binding)
            if initial.transition?.phase == .swapped {
                try await finishSwap()
                return await statusAfterActivation(storeID: initial.activeStore.id)
            }
            return try await statusUnchecked()
        }
        if payloadZone != nil {
            let local = try await persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
            try validateAttachmentCompatibility(local)
        }

        let transition = try await persistence.beginTransition(to: .iCloudSync, namespace: namespace.binding)
        var failure: ICloudSyncAttentionReason = .terminalFetchFailure
        do {
            let bridge = try await adapter(storeID: transition.candidateStoreID)
            if initialAccountState == nil { try await requireMatchingAccount() }
            try await bridge.fetchRemote()
            if let issue = await bridge.takeSyncIssue() { throw CloudSyncIssueError(issue) }
            let evidence = try await bridge.enrollmentEvidence()
            guard evidence.retryableEventKeys.isEmpty else {
                throw CloudSyncIssueError(.someChangesPending)
            }
            if evidence.needsAttention {
                try await persistence.abortUnactivatedCandidate(
                    transitionID: transition.id, reason: .enrollmentBlocked
                )
                return try await statusUnchecked()
            }
            guard evidence.phase != .notEnrolled, try await bridge.canPrepareModeMerge() else {
                throw CloudSyncRetryableError.itemFailure
            }

            failure = .transitionFailure
            try Task.checkCancellation()
            let source = try await persistence.sourceSnapshot(for: transition) { snapshot in
                try self.validateAttachmentCompatibility(snapshot)
            }
            let approvedSnipIDs: Set<UUID>
            if !initial.keptAfterCloudReset, let plan = try await bridge.makeReenableApplyPlan(source: source, transitionID: transition.id) {
                let candidate = try await persistence.libraryForTransition(storeID: transition.candidateStoreID)
                try await candidate.applyCloudFullReenablePlan(plan)
                approvedSnipIDs = plan.transfer.result.approvedSnipIDs
            } else {
                _ = try await preserveAttachments(storeID: transition.candidateStoreID)
                let acceptedSnipIDs = try await bridge.acceptedSnipIDs()
                let result = try await persistence.mergeCandidate(
                    source, for: transition, acceptedTargetSnipIDs: acceptedSnipIDs
                )
                approvedSnipIDs = result.approvedSnipIDs
            }
            try await bridge.approveModeMerge(snipIDs: approvedSnipIDs)
            try await persistence.markCandidateMerged(transitionID: transition.id)
            try await checkSetupCollection()
            try await requireMatchingAccount()
            try await persistence.swapPointer(transitionID: transition.id, sourceRevision: source.revision)
        } catch {
            let cancelled = CloudSyncDiagnostics.isCancellation(error)
            let retryable = isRetryableConnectivity(error)
            let reason = cancelled || retryable ? nil : failureReason(error, default: failure)
            await discardCandidate(transition, reason: reason)
            if cancelled { throw error }
            if failure == .terminalFetchFailure || retryable {
                let storage = try await persistence.snapshot()
                let accountState = await accountStateSource.currentAccountState()
                if let attention = accountAttentionReason(accountState) ?? reason {
                    return ICloudSyncModeStatus(
                        state: .needsAttention, activeStoreID: storage.activeStore.id, attentionReason: attention
                    )
                }
                return ICloudSyncModeStatus(
                    state: .settingUp, activeStoreID: storage.activeStore.id,
                    syncIssue: SnipSnapCloudSyncIssueMapper.issue(for: error)
                )
            }
            throw error
        }
        try await finishSwap()
        return await statusAfterActivation(storeID: transition.candidateStoreID)
    }

    private func statusAfterActivation(storeID: UUID) async -> ICloudSyncModeStatus {
        let current = try? await statusUnchecked()
        return ICloudSyncModeStatus(
            state: current?.state ?? .needsAttention,
            activeStoreID: storeID,
            attentionReason: current?.attentionReason,
            syncIssue: current?.syncIssue,
            activatedCloudStore: true
        )
    }

    private nonisolated func validateAttachmentCompatibility(_ snapshot: SnipLibrarySnapshot) throws {
        guard payloadZone != nil else { return }
        let unsupported = CloudAttachmentTransferCoordinator.unsupportedFiles(
            in: snapshot, policy: attachmentPolicy, keepingUnavailableDownloads: true
        )
        if !unsupported.isEmpty { throw CloudAttachmentSetupError.unsupportedFiles(unsupported) }
    }

    private func discardCandidate(
        _ transition: SyncModeTransition, reason: ICloudSyncAttentionReason?
    ) async {
        do {
            try await persistence.abortUnactivatedCandidate(transitionID: transition.id, reason: reason)
        } catch {
            try? await persistence.abortUnactivatedCandidate(transitionID: transition.id, reason: reason)
        }
    }

    private func finishSwap() async throws {
        try await persistence.finishTransition()
        try? await persistence.cleanupRetiredStores()
    }

    @discardableResult
    package func optOut(_ choice: ICloudSyncOptOutChoice) async throws -> ICloudSyncModeStatus {
        try begin(.optOut)
        defer { end() }
        if choice == .cancel {
            currentOperation = nil
            return try await statusUnchecked()
        }
        try await persistence.retryCandidateRollback()
        let initial = try await persistence.snapshot()
        if initial.activeStore.kind == .localOnly, initial.transition == nil {
            return try await statusUnchecked()
        }
        if initial.transition?.targetKind == .localOnly,
           initial.transition?.phase == .swapped {
            try await finishSwap()
            return try await statusUnchecked()
        }
        try await persistence.requireActiveNamespace(namespace.binding)

        do {
            try await requireMatchingAccount()
        } catch is ICloudAccountGateError {
            return try await updateAccountStatus(await accountStateSource.currentAccountState())
        }

        if choice == .useCurrentCacheAfterStaleDataWarning {
            let source = try await persistence.libraryForTransition(storeID: initial.activeStore.id)
            let stored = try await source.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
            // Do not transfer an unresolved cloud collection.
            if stored.namespaceState.phase == .blocked {
                try await persistence.recordAttention(.enrollmentBlocked)
                return try await statusUnchecked()
            }
        }

        if choice == .refreshThenCopy {
            let lease = try await persistence.activeCloudMutation(storeID: initial.activeStore.id)
            let activeBridge = try await adapter(storeID: initial.activeStore.id)
            do {
                let evidence = try await lease.run {
                    try await self.requireMatchingAccount()
                    try await activeBridge.fetchRemote {
                        try await self.requireMatchingAccount()
                    }
                    let evidence = try await activeBridge.enrollmentEvidence()
                    if evidence.hasRetryableRecordFailures || !evidence.retryableEventKeys.isEmpty {
                        try await activeBridge.clearRetryableEvents(evidence.retryableEventKeys)
                        throw CloudSyncRetryableError.itemFailure
                    }
                    return evidence
                }
                guard !evidence.needsAttention, [.active, .seeding].contains(evidence.phase) else {
                    try await persistence.recordAttention(.enrollmentBlocked)
                    return try await statusUnchecked()
                }
            } catch {
                if error is ICloudAccountGateError {
                    return try await updateAccountStatus(await accountStateSource.currentAccountState())
                }
                if !isRetryableConnectivity(error) {
                    try? await persistence.recordAttention(.terminalFetchFailure)
                }
                throw error
            }
        }

        if initial.transition == nil {
            do {
                try await preserveAttachmentsForLocalCopy(storeID: initial.activeStore.id)
            } catch {
                if error is ICloudAccountGateError {
                    return try await updateAccountStatus(await accountStateSource.currentAccountState())
                }
                if !isRetryableConnectivity(error) {
                    try? await persistence.recordAttention(.terminalFetchFailure)
                }
                throw error
            }
        }

        let transition = try await persistence.beginTransition(to: .localOnly, namespace: nil)
        do {
            var source = try await persistence.sourceSnapshot(for: transition)
            let sourceAdapter = try await adapter(storeID: transition.sourceStoreID)
            if let payload = try await sourceAdapter.dormantAcceptedBaseTransferPayload() {
                source = source.replacingOpaqueSyncStatePayload(payload)
            }
            _ = try await persistence.mergeCandidate(source, for: transition)
            try await persistence.markCandidateMerged(transitionID: transition.id)
            try await persistence.swapPointer(transitionID: transition.id, sourceRevision: source.revision)
        } catch {
            let retryable = isRetryableConnectivity(error)
            let reason = retryable || CloudSyncDiagnostics.isCancellation(error) ? nil : failureReason(error)
            await discardCandidate(transition, reason: reason)
            if retryable { return try await statusUnchecked() }
            throw error
        }
        try await finishSwap()
        return try await statusUnchecked()
    }

    private func adapter(storeID: UUID) async throws -> FullRecordSyncAdapter {
        let storage = try await persistence.snapshot()
        let isActive = storage.activeStore.id == storeID
        let isCandidate = storage.transition?.candidateStoreID == storeID
        guard isActive || isCandidate else { throw SyncModePersistenceError.missingStore }
        let library = try await persistence.libraryForTransition(storeID: storeID)
        let raw = CloudFullSyncPersistence(
            library: library,
            namespace: namespace,
            dataZone: textZone,
            payloadZone: payloadZone,
            attachmentPolicy: attachmentPolicy
        )
        return FullRecordSyncAdapter(raw: raw, transport: makeTransport()) {
            try await self.requireMatchingAccount()
        }
    }

    private func preserveAttachmentsForLocalCopy(storeID: UUID) async throws {
        guard payloadZone != nil else { return }
        let lease = try await persistence.activeCloudMutation(storeID: storeID)
        try await lease.run {
            _ = try await self.preserveAttachments(storeID: storeID)
        }
    }

    private func preserveAttachments(storeID: UUID) async throws -> Bool {
        guard let payloadZone else { return false }
        let library = try await persistence.libraryForTransition(storeID: storeID)
        let coordinator = CloudAttachmentTransferCoordinator(
            library: library,
            namespace: namespace,
            payloadZone: payloadZone,
            transport: makeTransport(),
            maximumCacheBytes: CloudAttachmentTransferCoordinator.standardMaximumCacheBytes
        )
        return try await coordinator.preserveAllAttachmentsForLocalCopy()
    }

    private func isRetryableConnectivity(_ error: Error) -> Bool {
        if CloudKitRetryPolicy.isTransient(error) { return true }
        if let error = error as? CloudTransportError {
            return error == .fetchFailed || error == .sendFailed
        }
        if error is CloudSyncRetryableError { return true }
        if error is ICloudAccountGateError { return true }
        if let error = error as? CloudSyncIssueError { return error.issue.retriesAutomatically }
        return false
    }

    private func failureReason(
        _ error: Error, default reason: ICloudSyncAttentionReason = .transitionFailure
    ) -> ICloudSyncAttentionReason {
        if case SnipLibraryError.transferConflict = error { return .transferConflict }
        return reason
    }

    private func statusUnchecked(
        accountState: ICloudAccountState? = nil,
        syncIssue: SyncedContentSyncIssue? = nil
    ) async throws -> ICloudSyncModeStatus {
        let storage = try await persistence.snapshot()
        if storage.transition?.targetKind == .iCloudSync {
            let transitionAccountState: ICloudAccountState
            if let accountState {
                transitionAccountState = accountState
            } else {
                transitionAccountState = await accountStateSource.currentAccountState()
            }
            if let reason = accountAttentionReason(transitionAccountState) {
                return ICloudSyncModeStatus(
                    state: .needsAttention,
                    activeStoreID: storage.activeStore.id,
                    attentionReason: reason
                )
            }
        }
        if storage.activeStore.kind == .localOnly, storage.activeStore.quarantinedNamespace != nil,
            storage.transition == nil
        {
            return ICloudSyncModeStatus(state: .off, activeStoreID: storage.activeStore.id,
                attentionReason: storage.attentionReason)
        }
        if let reason = storage.attentionReason, reason != .firstSyncFailed {
            return ICloudSyncModeStatus(
                state: .needsAttention,
                activeStoreID: storage.activeStore.id,
                attentionReason: reason
            )
        }
        if let transition = storage.transition {
            let state: ICloudSyncModeState = transition.targetKind == .iCloudSync
                ? .settingUp
                : .syncing
            return ICloudSyncModeStatus(
                state: state,
                activeStoreID: storage.activeStore.id,
                syncIssue: syncIssue
            )
        }
        guard storage.activeStore.kind == .iCloudSync else {
            return ICloudSyncModeStatus(state: .off, activeStoreID: storage.activeStore.id)
        }
        let currentAccountState: ICloudAccountState
        if let accountState {
            currentAccountState = accountState
        } else {
            currentAccountState = await accountStateSource.currentAccountState()
        }
        if let reason = accountAttentionReason(currentAccountState) {
            return ICloudSyncModeStatus(
                state: .needsAttention,
                activeStoreID: storage.activeStore.id,
                attentionReason: reason
            )
        }
        try await persistence.requireActiveNamespace(namespace.binding)
        if currentOperation == .optOut {
            return ICloudSyncModeStatus(state: .syncing, activeStoreID: storage.activeStore.id)
        }
        let evidence = try await adapter(storeID: storage.activeStore.id).enrollmentEvidence()
        let state: ICloudSyncModeState = !evidence.needsAttention && [.active, .seeding].contains(evidence.phase)
            ? .on
            : .needsAttention
        return ICloudSyncModeStatus(state: state, activeStoreID: storage.activeStore.id)
    }

    private func begin(_ operation: Operation) throws {
        guard currentOperation == nil else { throw SnipLibraryError.modeTransitionInProgress }
        currentOperation = operation
    }

    private func end() { currentOperation = nil }

    private func accountAttentionReason(
        _ state: ICloudAccountState
    ) -> ICloudSyncAttentionReason? {
        switch state {
        case .available(let accountLineage):
            accountLineage == namespace.accountLineage ? nil : .accountChanged
        case .temporarilyUnavailable:
            .accountTemporarilyUnavailable
        case .couldNotDetermine:
            .accountStatusUnknown
        case .noAccount:
            .accountSignedOut
        case .restricted:
            .accountRestricted
        }
    }

    private func requireMatchingAccount() async throws {
        switch await accountStateSource.currentAccountState() {
        case .available(let accountLineage):
            guard accountLineage == namespace.accountLineage else {
                throw ICloudAccountGateError.accountChanged
            }
        case .couldNotDetermine:
            throw ICloudAccountGateError.couldNotDetermine
        case .noAccount:
            throw ICloudAccountGateError.noAccount
        case .restricted:
            throw ICloudAccountGateError.restricted
        case .temporarilyUnavailable:
            throw ICloudAccountGateError.temporarilyUnavailable
        }
    }
}
