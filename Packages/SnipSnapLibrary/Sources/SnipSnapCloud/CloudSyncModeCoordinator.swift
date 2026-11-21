import Foundation
import SnipSnapCore
import SnipSnapPersistence

private enum ICloudModeMergePreparation: Sendable {
    case initialEnrollment(acceptedTextBySnipID: [UUID: String])
    case fullRecord(CloudFullReenableApplyPlan)
}

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
    private let beforeApply: CloudFullSyncPersistence.ApplyHook
    private var pendingIssue: SyncedContentSyncIssue?

    init(
        raw: CloudFullSyncPersistence,
        transport: any CloudRecordTransport,
        beforeApply: @escaping CloudFullSyncPersistence.ApplyHook
    ) {
        self.raw = raw
        self.beforeApply = beforeApply
        syncDriver = CloudFullSyncCoordinator(
            store: raw,
            transport: transport,
            fetchScope: .zones([raw.dataZone])
        )
    }

    func fetchRemote(
        beforeApply: @escaping @Sendable () async throws -> Void
    ) async throws {
        pendingIssue = nil
        let outcome = try await syncDriver.fetchRemote(beforeApply: beforeApply)
        try retainFetchIssue(outcome)
    }

    func sendPending(
        beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void
    ) async throws {
        let outcome = try await syncDriver.sendPending(beforeApply: beforeApply, beforeSend: beforeSend)
        try reportCompletedSyncIssue(outcome)
    }

    private func retainFetchIssue(_ outcome: CloudFullSyncOutcome) throws {
        if let issue = outcome.issue {
            if outcome.blocksOutbound { throw CloudSyncIssueError(issue) }
            pendingIssue = issue
        }
    }

    private func reportCompletedSyncIssue(_ outcome: CloudFullSyncOutcome) throws {
        let issue = outcome.issue ?? pendingIssue
        if let issue, issue.retriesAutomatically {
            pendingIssue = issue
            return
        }
        pendingIssue = nil
        if let issue { throw CloudSyncIssueError(issue) }
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

    func statusEvidence() async throws -> CloudTextEnrollmentEvidence {
        try await raw.statusEvidence()
    }

    func dormantAcceptedBaseTransferPayload() async throws -> Data? {
        try await raw.dormantAcceptedBaseTransferPayload()
    }

    func canPrepareModeMerge() async throws -> Bool {
        try await raw.isReenableReady()
    }

    func prepareModeMerge(
        source: SnipLibraryTransferSnapshot,
        transitionID: UUID,
        targetRevision: UInt64,
        keepFetchedAttachments: Bool
    ) async throws -> ICloudModeMergePreparation {
        if let plan = try await raw.makeReenableApplyPlan(
            source: source,
            transitionID: transitionID,
            targetRevision: targetRevision,
            keepFetchedAttachments: keepFetchedAttachments
        ) {
            return .fullRecord(plan)
        }
        return .initialEnrollment(acceptedTextBySnipID: try await raw.acceptedSnipTextValues())
    }

    func clearRetryableEvents(_ keys: Set<String>) async throws {
        try await raw.clearRetryableEvents(keys)
    }

    func currentModeSeedSettlement(
        candidates: [SyncModeSeedSettlementCandidate],
        namespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSeedSettlementProof {
        try await raw.currentModeSeedSettlement(candidates: candidates, namespace: namespace)
    }

    func modeSendAttempt(
        for outbound: CloudOutboundBatch,
        namespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSendAttempt {
        try await raw.modeSendAttempt(for: outbound, namespace: namespace)
    }

    func prepareModeRetry(
        commitSettlement: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await commitSettlement()
        try await syncDriver.prepareManualRetry(beforeApply: beforeApply, beforeStateSave: beforeApply)
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

    package init(
        state: ICloudSyncModeState,
        activeStoreID: UUID,
        attentionReason: ICloudSyncAttentionReason? = nil,
        syncIssue: SyncedContentSyncIssue? = nil
    ) {
        self.state = state
        self.activeStoreID = activeStoreID
        self.attentionReason = attentionReason
        self.syncIssue = syncIssue
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
    private let checkSetupCollection: @Sendable () async throws -> Void
    private enum Operation { case enable, optOut, activeSync }
    private var currentOperation: Operation?

    package init(
        persistence: SwiftDataSyncModePersistence,
        namespace: CloudSyncNamespace,
        textZone: CloudZoneID,
        payloadZone: CloudZoneID? = nil,
        attachmentPolicy: CloudAttachmentCompatibilityPolicy = .openSourceDefault,
        makeTransport: @escaping TransportFactory,
        accountStateSource: (any ICloudAccountStateSource)? = nil,
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
        self.checkSetupCollection = checkSetupCollection
    }

    package func status() async throws -> ICloudSyncModeStatus {
        try await persistence.reconcileAccountIsolationResolution()
        return try await statusUnchecked(
            accountState: await accountStateSource.currentAccountState()
        )
    }

    @discardableResult
    package func refreshAccountState() async throws -> ICloudSyncModeStatus {
        let accountState = await accountStateSource.currentAccountState()
        let initialStorage = try await persistence.snapshot()
        if let isolation = initialStorage.accountIsolation,
           isolation.resolution != .removing,
           case .available(let accountLineage) = accountState,
           accountLineage == isolation.namespace.accountLineage,
           isolation.namespace == namespace.binding,
           let recoveredMissingBytes = try await persistence.keepReturningAccountIsolation(
               isolation.id,
               preservingAttachments: { storeID in
                   try await self.preserveIsolatedAttachmentsForLocalCopy(storeID: storeID)
               }
           ) {
            if recoveredMissingBytes {
                // Finish the safety copy first. A later explicit enable can start a
                // fresh remote-first transition without holding account isolation open.
                return try await statusUnchecked(accountState: accountState)
            }
            return try await enableOrRetry()
        }
        try await persistence.reconcileAccountIsolationResolution()
        let storage = try await persistence.snapshot()
        if storage.activeStore.kind == .iCloudSync, storage.accountIsolation == nil {
            switch accountState {
            case .noAccount:
                _ = try await persistence.isolateActiveCloudStore(reason: .signedOut)
            case .available(let accountLineage)
                where accountLineage != namespace.accountLineage:
                _ = try await persistence.isolateActiveCloudStore(reason: .accountChanged)
            case .available, .restricted, .temporarilyUnavailable, .couldNotDetermine:
                break
            }
        }
        return try await statusUnchecked(accountState: accountState)
    }

    @discardableResult
    package func resolveAccountIsolation(
        _ choice: ICloudAccountIsolationChoice
    ) async throws -> ICloudSyncModeStatus {
        try await persistence.resolveAccountIsolation(choice)
        return try await statusUnchecked(
            accountState: await accountStateSource.currentAccountState()
        )
    }

    /// The only active-store Cloud sync entry point later app assembly should use.
    @discardableResult
    package func syncActive() async throws -> ICloudSyncModeStatus {
        try begin(.activeSync)
        var operationEnded = false
        defer { if !operationEnded { end() } }
        let accountState = await accountStateSource.currentAccountState()
        if accountAttentionReason(accountState) != nil {
            end()
            operationEnded = true
            return try await refreshAccountState()
        }
        let storage = try await persistence.snapshot()
        if let isolation = storage.accountIsolation {
            return ICloudSyncModeStatus(
                state: .needsAttention,
                activeStoreID: storage.activeStore.id,
                attentionReason: isolation.reason == .signedOut ? .accountSignedOut : .accountChanged
            )
        }
        try await persistence.requireActiveNamespace(namespace.binding)
        let lease = try await persistence.activeCloudMutationLease(storeID: storage.activeStore.id)
        let adapter = try await adapter(storeID: storage.activeStore.id)
        do {
            try await lease.run { [self] in
                try await requireMatchingAccount()
                try await adapter.fetchRemote {
                    try await self.requireMatchingAccount()
                }
                var clearedEarlierRetry = false
                for _ in 0..<8 {
                    let evidence = try await adapter.enrollmentEvidence()
                    if evidence.hasRetryableRecordFailures || !evidence.retryableEventKeys.isEmpty {
                        guard !clearedEarlierRetry else { break }
                        try await adapter.clearRetryableEvents(evidence.retryableEventKeys)
                        clearedEarlierRetry = true
                        continue
                    }
                    guard evidence.hasPendingChanges, !evidence.blocksSending,
                          evidence.phase != .blocked
                    else { break }
                    try await adapter.sendPending { _ in
                        try await self.requireMatchingAccount()
                    }
                }
            }
        } catch is ICloudAccountGateError {
            end()
            operationEnded = true
            return try await refreshAccountState()
        }
        end()
        operationEnded = true
        return try await statusUnchecked()
    }

    @discardableResult
    package func enableOrRetry() async throws -> ICloudSyncModeStatus {
        try begin(.enable)
        defer { end() }
        let initial = try await persistence.snapshot()
        if initial.activeStore.kind == .iCloudSync, initial.transition == nil {
            try await persistence.requireActiveNamespace(namespace.binding)
            return try await statusUnchecked()
        }
        if initial.transition == nil, payloadZone != nil {
            let localLibrary = try await persistence.activeLibrary()
            let local = try await localLibrary.checkedSnapshot(sortedBy: .manual)
            let unsupported = CloudAttachmentTransferCoordinator.unsupportedFiles(
                in: local,
                policy: attachmentPolicy
            )
            if !unsupported.isEmpty {
                throw CloudAttachmentSetupError.unsupportedFiles(unsupported)
            }
        }

        let followsFailedSend = initial.attentionReason == .firstSyncFailed || initial.transition?.sendAttempt != nil
        var transition = try await persistence.beginOrResumeTransition(
            to: .iCloudSync,
            namespace: namespace.binding
        )
        let bridge: FullRecordSyncAdapter
        do {
            bridge = try await adapter(storeID: transition.candidateStoreID)
            if transition.phase == .candidateReady {
                try await prepareCandidate(transition, using: bridge)
                let fetchIssue = await bridge.takeSyncIssue()
                let evidence = try await bridge.statusEvidence()
                if let fetchIssue {
                    throw CloudSyncIssueError(fetchIssue)
                }
                if !evidence.retryableEventKeys.isEmpty {
                    throw CloudSyncIssueError(.someChangesPending)
                }
                if evidence.needsAttention {
                    try await persistence.discardFailedICloudEnable(
                        transitionID: transition.id, reason: .enrollmentBlocked
                    )
                    return try await statusUnchecked()
                }
                guard evidence.phase != .notEnrolled else { return try await statusUnchecked() }
                try await persistence.recordPreparationComplete()
                transition = try await currentTransition()
            }
        } catch {
            let retryable = isRetryableConnectivity(error)
            let status = try await failedEnable(
                transition,
                error: error,
                reason: retryable || CloudSyncDiagnostics.isCancellation(error) ? nil : .terminalFetchFailure
            )
            if CloudSyncDiagnostics.isCancellation(error) { throw error }
            if !retryable, error is CloudSyncIssueError { throw error }
            return status
        }

        do {
            if transition.phase == .remoteFetched {
                guard try await bridge.canPrepareModeMerge() else {
                    try await persistence.retryRemoteFetch()
                    return try await statusUnchecked()
                }
                let token = try await persistence.freezeSource()
                let source = try await persistence.finalSnapshot(using: token)
                let targetRevision = try await persistence.candidateRevision(
                    transitionID: transition.id
                )
                switch try await bridge.prepareModeMerge(
                    source: source,
                    transitionID: transition.id,
                    targetRevision: targetRevision,
                    keepFetchedAttachments: followsFailedSend
                ) {
                case .fullRecord(let plan):
                    _ = try await persistence.mergeFullReenableSnapshot(
                        source,
                        using: token,
                        plan: plan
                    )
                case .initialEnrollment(let accepted):
                    // This merge copies all retained attachments, including remote metadata
                    // whose bytes have not been downloaded on this device yet.
                    try await requireMatchingAccount()
                    _ = try await preserveIsolatedAttachmentsForLocalCopy(
                        storeID: transition.candidateStoreID
                    )
                    try await requireMatchingAccount()
                    _ = try await persistence.mergeFinalSnapshot(
                        source,
                        using: token,
                        acceptedTargetTextBySnipID: accepted
                    )
                }
                transition = try await currentTransition()
            }

            if transition.phase == .recordsMerged {
                // Approval is idempotent and must be durable before the phase can advance.
                try await bridge.approveModeMerge(snipIDs: transition.approvedSnipIDs)
                try await persistence.recordEnrollmentApproved(expected: transition.approvedSnipIDs)
                transition = try await currentTransition()
            }

            if transition.phase == .enrollmentApproved {
                try await persistence.recordFirstSendStarted()
                transition = try await currentTransition()
            }

            if transition.phase == .firstSendStarted {
                try await sendUntilSettled(adapter: bridge)
                try await persistence.recordFirstSendComplete()
                transition = try await currentTransition()
            }

            if transition.phase == .firstSendComplete {
                try await checkSetupCollection()
                try await requireMatchingAccount()
                try Task.checkCancellation()
                try await persistence.swapPointer()
                transition = try await currentTransition()
            }
        } catch {
            let cancelled = CloudSyncDiagnostics.isCancellation(error)
            if !cancelled, let stored = try? await persistence.snapshot(),
               stored.transition?.hasDurableFullReenableIntent == true {
                throw error
            }
            let retryable = isRetryableConnectivity(error)
            let reason = retryable || cancelled ? nil : failureReason(error)
            let status = try await failedEnable(transition, error: error, reason: reason)
            if retryable { return status }
            throw error
        }

        if transition.phase == .pointerSwapped {
            try await persistence.finishTransition()
            try? await persistence.cleanupRetiredStores()
        }
        return try await statusUnchecked()
    }

    private func prepareCandidate(
        _ transition: SyncModeTransition, using bridge: FullRecordSyncAdapter
    ) async throws {
        let settlement = try await bridge.currentModeSeedSettlement(
            candidates: transition.seedSettlementCandidates,
            namespace: namespace.binding
        )
        try await bridge.prepareModeRetry { [persistence] in
            try await persistence.prepareRetryFetch(settlement: settlement)
        }
        try await requireMatchingAccount()
        try await bridge.fetchRemote {
            try await self.requireMatchingAccount()
        }
    }

    private func failedEnable(
        _ transition: SyncModeTransition, error: Error, reason: ICloudSyncAttentionReason?
    ) async throws -> ICloudSyncModeStatus {
        // Read account status while the enable is still pending.
        let accountState = await accountStateSource.currentAccountState()
        let accountReason = accountAttentionReason(accountState)
        do {
            try await persistence.discardFailedICloudEnable(
                transitionID: transition.id, reason: reason,
                preserveNewBases: !CloudSyncDiagnostics.isCancellation(error)
            )
        } catch {
            // A transient manifest write failure can leave the source frozen.
            try? await persistence.discardFailedICloudEnable(transitionID: transition.id, reason: reason)
        }
        let storage = try await persistence.snapshot()
        if storage.activeStore.id != transition.sourceStoreID {
            return try await statusUnchecked(accountState: accountState)
        }
        if let attention = accountReason ?? reason {
            return ICloudSyncModeStatus(
                state: .needsAttention, activeStoreID: storage.activeStore.id, attentionReason: attention
            )
        }
        return ICloudSyncModeStatus(
            state: .settingUp, activeStoreID: storage.activeStore.id,
            syncIssue: SnipSnapCloudSyncIssueMapper.issue(for: error)
        )
    }

    @discardableResult
    package func optOut(_ choice: ICloudSyncOptOutChoice) async throws -> ICloudSyncModeStatus {
        try begin(.optOut)
        defer { end() }
        if choice == .cancel {
            currentOperation = nil
            return try await statusUnchecked()
        }
        let initial = try await persistence.snapshot()
        if initial.activeStore.kind == .localOnly, initial.transition == nil {
            return try await statusUnchecked()
        }
        if initial.transition?.targetKind == .localOnly,
           initial.transition?.phase == .pointerSwapped {
            try await persistence.finishTransition()
            try? await persistence.cleanupRetiredStores()
            return try await statusUnchecked()
        }
        try await persistence.requireActiveNamespace(namespace.binding)

        do {
            try await requireMatchingAccount()
        } catch is ICloudAccountGateError {
            return try await refreshAccountState()
        }

        if choice == .useCurrentCacheAfterStaleDataWarning {
            let source = try await persistence.libraryForTransition(storeID: initial.activeStore.id)
            let stored = try await source.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
            // A blocked collection has durable evidence against reusing its cache.
            // A local copy would drop that evidence and could later be uploaded.
            if stored.namespaceState.phase == .blocked {
                try await persistence.recordAttention(.enrollmentBlocked)
                return try await statusUnchecked()
            }
        }

        if initial.transition == nil, choice == .refreshThenCopy {
            let lease = try await persistence.activeCloudMutationLease(
                storeID: initial.activeStore.id, purpose: .modeChange)
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
                guard !evidence.needsAttention, evidence.phase == .active else {
                    try await persistence.recordAttention(.enrollmentBlocked)
                    return try await statusUnchecked()
                }
            } catch {
                if error is ICloudAccountGateError {
                    return try await refreshAccountState()
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
                    return try await refreshAccountState()
                }
                if !isRetryableConnectivity(error) {
                    try? await persistence.recordAttention(.terminalFetchFailure)
                }
                throw error
            }
        }

        var transition = try await persistence.beginTransition(to: .localOnly, namespace: nil)
        if transition.phase == .candidateReady {
            try await persistence.recordPreparationComplete()
            transition = try await currentTransition()
        }
        do {
            if transition.phase == .remoteFetched {
                let token = try await persistence.freezeSource()
                var source = try await persistence.finalSnapshot(using: token)
                let sourceAdapter = try await adapter(storeID: transition.sourceStoreID)
                if let payload = try await sourceAdapter.dormantAcceptedBaseTransferPayload() {
                    source = source.replacingOpaqueSyncStatePayload(payload)
                }
                _ = try await persistence.mergeFinalSnapshot(source, using: token)
                transition = try await currentTransition()
            }
            if transition.phase == .recordsMerged {
                try await persistence.recordEnrollmentApproved(expected: transition.approvedSnipIDs)
                transition = try await currentTransition()
            }
            if transition.phase == .enrollmentApproved {
                try await persistence.recordNoSendRequired()
                transition = try await currentTransition()
            }
            if transition.phase == .firstSendComplete {
                try await persistence.swapPointer()
                transition = try await currentTransition()
            }
        } catch {
            let retryable = isRetryableConnectivity(error)
            await restoreSourceAfterPreSwapFailure(error, retryable: retryable)
            if retryable { return try await statusUnchecked() }
            throw error
        }
        if transition.phase == .pointerSwapped {
            try await persistence.finishTransition()
            try? await persistence.cleanupRetiredStores()
        }
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
            if isCandidate && !isActive { try await self.requireMatchingAccount() }
        }
    }

    private func preserveAttachmentsForLocalCopy(storeID: UUID) async throws {
        guard payloadZone != nil else { return }
        let lease = try await persistence.activeCloudMutationLease(storeID: storeID, purpose: .modeChange)
        try await lease.run {
            _ = try await self.preserveIsolatedAttachmentsForLocalCopy(storeID: storeID)
        }
    }

    private func preserveIsolatedAttachmentsForLocalCopy(storeID: UUID) async throws -> Bool {
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

    private func currentTransition() async throws -> SyncModeTransition {
        guard let transition = try await persistence.snapshot().transition else {
            throw SyncModePersistenceError.transitionInProgress
        }
        return transition
    }

    private func sendUntilSettled(adapter: FullRecordSyncAdapter) async throws {
        for _ in 0..<8 {
            try await adapter.sendPending { [persistence, namespace] outbound in
                try await self.requireMatchingAccount()
                let attempt = try await adapter.modeSendAttempt(for: outbound, namespace: namespace.binding)
                try await self.checkSetupCollection()
                try await persistence.recordSendAttempt(attempt)
            }
            let issue = await adapter.takeSyncIssue()
            let evidence = try await adapter.enrollmentEvidence()
            if evidence.hasRetryableRecordFailures || !evidence.retryableEventKeys.isEmpty {
                try await adapter.clearRetryableEvents(evidence.retryableEventKeys)
                if let issue { throw CloudSyncIssueError(issue) }
                throw CloudSyncRetryableError.itemFailure
            }
            if evidence.phase == .blocked {
                throw CloudNamespaceEnrollmentError.invalidSeedSelection
            }
            if evidence.phase == .active, !evidence.hasPendingChanges {
                if let issue { throw CloudSyncIssueError(issue) }
                return
            }
            if let issue { throw CloudSyncIssueError(issue) }
        }
        throw CloudTransportError.sendFailed
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

    private func failureReason(_ error: Error) -> ICloudSyncAttentionReason {
        if case SnipLibraryError.transferConflict = error { return .transferConflict }
        return .transitionFailure
    }

    private func restoreSourceAfterPreSwapFailure(_ error: Error, retryable: Bool) async {
        let reason = retryable ? nil : failureReason(error)
        if (try? await persistence.unfreezeBeforePointerSwap(reason: reason)) == nil {
            try? await persistence.unfreezeBeforePointerSwap(reason: reason)
        }
    }

    private func statusUnchecked(
        accountState: ICloudAccountState? = nil,
        syncIssue: SyncedContentSyncIssue? = nil
    ) async throws -> ICloudSyncModeStatus {
        let storage = try await persistence.snapshot()
        if let isolation = storage.accountIsolation {
            let reason: ICloudSyncAttentionReason
            if case .available(let lineage) = accountState,
               lineage == isolation.namespace.accountLineage,
               isolation.namespace != namespace.binding {
                reason = .namespaceChanged
            } else {
                reason = isolation.reason == .signedOut ? .accountSignedOut : .accountChanged
            }
            return ICloudSyncModeStatus(
                state: .needsAttention,
                activeStoreID: storage.activeStore.id,
                attentionReason: reason
            )
        }
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
        if currentOperation == .optOut || currentOperation == .activeSync
            || storage.hasActiveMutationReservation {
            return ICloudSyncModeStatus(state: .syncing, activeStoreID: storage.activeStore.id)
        }
        let evidence = try await adapter(storeID: storage.activeStore.id).statusEvidence()
        let state: ICloudSyncModeState = !evidence.needsAttention && evidence.phase == .active
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
