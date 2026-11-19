import Foundation
import SnipSnapCore
import SnipSnapPersistence

private enum ICloudModeMergePreparation: Sendable {
    case legacy(acceptedTextBySnipID: [UUID: String])
    case fullRecord(CloudFullReenableApplyPlan)
}

private protocol ICloudSyncAdapter: Sendable {
    func fetchRemote(
        beforeApply: @escaping @Sendable () async throws -> Void
    ) async throws
    func sendPending(
        beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void
    ) async throws
    func takeSyncIssue() async -> SyncedContentSyncIssue?
    func approveModeMerge(snipIDs: Set<UUID>) async throws
    func enrollmentEvidence() async throws -> CloudTextEnrollmentEvidence
    func statusEvidence() async throws -> CloudTextEnrollmentEvidence
    func setupRetryMustHold(
        deletedSnipIDs: Set<UUID>, pointerDeletes: [CloudSetupPointerDelete]
    ) async throws -> Bool
    func recheckSetupPointerCleanup(
        deletedSnipIDs: Set<UUID>, receipts: [CloudSetupPointerDelete]
    ) async throws -> Bool
    func dormantAcceptedBaseTransferPayload() async throws -> Data?
    func canPrepareModeMerge() async throws -> Bool
    func prepareModeMerge(
        source: SnipLibraryTransferSnapshot,
        transitionID: UUID,
        targetRevision: UInt64,
        priorSeedProvenance: [SyncModeSeedProvenance],
        retryEvidence: CloudSetupRetryEvidence?
    ) async throws -> ICloudModeMergePreparation
    func clearRetryableEvents(_ keys: Set<String>) async throws
    func currentModeSeedSettlement(
        candidates: [SyncModeSeedSettlementCandidate],
        namespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSeedSettlementProof
    func modeSendAttempt(
        for outbound: CloudOutboundBatch,
        namespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSendAttempt
    func prepareFailureRecovery(snipIDs: Set<UUID>) async throws
    func prepareModeRetry(
        snipIDs: Set<UUID>,
        forceInitialFetch: Bool,
        commitSettlement: @escaping @Sendable () async throws -> Void
    ) async throws
}

private extension ICloudSyncAdapter {
    func setupRetryMustHold(
        deletedSnipIDs: Set<UUID>, pointerDeletes: [CloudSetupPointerDelete]
    ) async throws -> Bool { false }
    func recheckSetupPointerCleanup(
        deletedSnipIDs: Set<UUID>, receipts: [CloudSetupPointerDelete]
    ) async throws -> Bool { false }
}

package enum ICloudAccountGateError: Error, Equatable, Sendable {
    case couldNotDetermine
    case noAccount
    case restricted
    case temporarilyUnavailable
    case accountChanged
}

private actor LegacyTextSyncAdapter: ICloudSyncAdapter {
    private let raw: SwiftDataCloudTextPersistence
    private let syncDriver: CloudTextSyncCoordinator

    init(raw: SwiftDataCloudTextPersistence, transport: any CloudRecordTransport) {
        self.raw = raw
        syncDriver = CloudTextSyncCoordinator(store: raw, transport: transport)
    }

    func fetchRemote(
        beforeApply: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await syncDriver.fetchRemote(beforeApply: beforeApply)
    }

    func sendPending(
        beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void
    ) async throws {
        try await syncDriver.sendPending(beforeSend: beforeSend)
    }

    func takeSyncIssue() async -> SyncedContentSyncIssue? { nil }

    func approveModeMerge(snipIDs: Set<UUID>) async throws {
        try await raw.approveModeMerge(snipIDs: snipIDs)
    }

    func enrollmentEvidence() async throws -> CloudTextEnrollmentEvidence {
        try await raw.enrollmentEvidence()
    }

    func statusEvidence() async throws -> CloudTextEnrollmentEvidence {
        try await raw.statusEvidence()
    }

    func dormantAcceptedBaseTransferPayload() async throws -> Data? { nil }

    func canPrepareModeMerge() async throws -> Bool { true }

    func prepareModeMerge(
        source: SnipLibraryTransferSnapshot,
        transitionID: UUID,
        targetRevision: UInt64,
        priorSeedProvenance: [SyncModeSeedProvenance],
        retryEvidence: CloudSetupRetryEvidence?
    ) async throws -> ICloudModeMergePreparation {
        return .legacy(acceptedTextBySnipID: try await raw.acceptedSnipTextValues())
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

    func prepareModeRetry(
        snipIDs: Set<UUID>,
        forceInitialFetch: Bool,
        commitSettlement: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await raw.prepareModeRetry(snipIDs: snipIDs)
        try await commitSettlement()
    }

    func prepareFailureRecovery(snipIDs: Set<UUID>) async throws {
        try await raw.prepareModeRetry(snipIDs: snipIDs)
    }

    func modeSendAttempt(
        for outbound: CloudOutboundBatch,
        namespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSendAttempt {
        try await raw.modeSendAttempt(for: outbound, namespace: namespace)
    }
}

private actor FullRecordSyncAdapter: ICloudSyncAdapter {
    private let raw: CloudFullSyncPersistence
    private let syncDriver: CloudFullSyncCoordinator
    private let beforeApply: CloudFullSyncPersistence.ApplyHook
    private var pendingIssue: SyncedContentSyncIssue?
    private var checkedSetupMetadata = false

    init(
        raw: CloudFullSyncPersistence,
        transport: any CloudRecordTransport,
        checksSetupRetry: Bool,
        beforeApply: @escaping CloudFullSyncPersistence.ApplyHook
    ) {
        self.raw = raw
        self.beforeApply = beforeApply
        syncDriver = CloudFullSyncCoordinator(
            store: raw,
            transport: transport,
            fetchScope: .zones([raw.dataZone]),
            initializeOutboundOnStart: !checksSetupRetry
        )
    }

    func fetchRemote(
        beforeApply: @escaping @Sendable () async throws -> Void
    ) async throws {
        pendingIssue = nil
        let outcome = try await syncDriver.fetchRemote(beforeApply: beforeApply)
        try retainFetchIssue(outcome)
        checkedSetupMetadata = outcome.completedInitialFetchZones.contains(raw.dataZone)
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

    func setupRetryMustHold(
        deletedSnipIDs: Set<UUID>, pointerDeletes: [CloudSetupPointerDelete]
    ) async throws -> Bool {
        guard !deletedSnipIDs.isEmpty || !pointerDeletes.isEmpty else { return false }
        guard checkedSetupMetadata else { return true }
        return try await raw.setupRetryMustHold(
            deletedSnipIDs: deletedSnipIDs, pointerDeletes: pointerDeletes
        )
    }

    func recheckSetupPointerCleanup(
        deletedSnipIDs: Set<UUID>, receipts: [CloudSetupPointerDelete]
    ) async throws -> Bool {
        checkedSetupMetadata = false
        try await syncDriver.prepareManualRetry(
            forceInitialFetch: true, beforeApply: beforeApply, beforeStateSave: beforeApply
        )
        try await fetchRemote(beforeApply: beforeApply)
        guard checkedSetupMetadata, pendingIssue == nil else { return false }
        return try await raw.canReleaseSetupPointerCleanup(deletedSnipIDs: deletedSnipIDs, receipts: receipts)
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
        priorSeedProvenance: [SyncModeSeedProvenance],
        retryEvidence: CloudSetupRetryEvidence?
    ) async throws -> ICloudModeMergePreparation {
        if let plan = try await raw.makeReenableApplyPlan(
            source: source,
            transitionID: transitionID,
            targetRevision: targetRevision,
            priorSeedProvenance: priorSeedProvenance,
            retryEvidence: retryEvidence
        ) {
            return .fullRecord(plan)
        }
        return .legacy(acceptedTextBySnipID: try await raw.acceptedSnipTextValues())
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
        snipIDs: Set<UUID>,
        forceInitialFetch: Bool,
        commitSettlement: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await commitSettlement()
        // Full-record recovery is batch scoped, so seed IDs cannot narrow it.
        _ = snipIDs
        checkedSetupMetadata = false
        if forceInitialFetch {
            try await beforeApply()
            try await raw.discardHeldSetupRetryFetches()
        }
        try await syncDriver.prepareManualRetry(
            forceInitialFetch: forceInitialFetch, beforeApply: beforeApply, beforeStateSave: beforeApply
        )
    }

    func prepareFailureRecovery(snipIDs: Set<UUID>) async throws {
        // Keep the failed batch until the durable transition restart records settlement.
        _ = snipIDs
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
    private let applyHook: SwiftDataCloudTextPersistence.ApplyHook
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
        applyHook: @escaping SwiftDataCloudTextPersistence.ApplyHook = {},
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
        self.applyHook = applyHook
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

        if initial.transition != nil {
            try await CloudSetupRetryCapture.retainStagedPointerDeletes(in: persistence)
        }
        var transition = try await persistence.beginOrResumeTransition(
            to: .iCloudSync,
            namespace: namespace.binding
        )
        let retryHistory = transition.syncProtocol == .fullRecordV1
            ? await persistence.setupRetryEvidence(namespace: namespace.binding) : nil
        let checksSetupRetry = retryHistory?.isEmpty == false
        if checksSetupRetry, transition.phase == .remoteFetched {
            // An interrupted setup may have committed its fetch before checking the frozen source.
            try await persistence.retryRemoteFetch()
            transition = try await currentTransition()
        }
        let bridge = try await adapter(
            storeID: transition.candidateStoreID, captureSetupRetry: true,
            checksSetupRetry: checksSetupRetry
        )

        if transition.phase == .candidateReady {
            var deletedBeforeFetch: Set<UUID> = []
            do {
                if checksSetupRetry {
                    deletedBeforeFetch = try await deletedSetupSnipIDs(await acknowledgedSetupSnipIDs())
                }
                let candidates = transition.seedSettlementCandidates
                let settlement = try await bridge.currentModeSeedSettlement(
                    candidates: candidates,
                    namespace: namespace.binding
                )
                let candidateIDs = Set(candidates.map(\.snipID))
                let deferred = await persistence.deferredSetupPointerDeletes(for: transition)
                try await bridge.prepareModeRetry(
                    snipIDs: candidateIDs, forceInitialFetch: !deletedBeforeFetch.isEmpty || !deferred.isEmpty
                ) { [persistence] in
                    try await persistence.prepareRetryFetch(settlement: settlement)
                }
                if checksSetupRetry {
                    deletedBeforeFetch = try await deletedSetupSnipIDs(await acknowledgedSetupSnipIDs())
                }
                try await requireMatchingAccount()
                try await bridge.fetchRemote {
                    try await self.requireMatchingAccount()
                }
            } catch {
                if error is CloudSetupRetryHold {
                    return try await holdSetupForDeletedSnip(transition)
                }
                if error is ICloudAccountGateError {
                    return try await statusUnchecked(
                        accountState: await accountStateSource.currentAccountState()
                    )
                }
                if isRetryableConnectivity(error) {
                    return try await statusUnchecked(
                        syncIssue: SnipSnapCloudSyncIssueMapper.issue(for: error)
                    )
                }
                try await persistence.recordAttention(.terminalFetchFailure)
                if error is CloudSyncIssueError { throw error }
                return try await statusUnchecked()
            }
            let fetchIssue = await bridge.takeSyncIssue()
            let evidence = try await bridge.statusEvidence()
            if !evidence.retryableEventKeys.isEmpty {
                try await bridge.clearRetryableEvents(evidence.retryableEventKeys)
                return try await statusUnchecked(
                    syncIssue: fetchIssue ?? .someChangesPending
                )
            }
            if let fetchIssue {
                return try await statusUnchecked(syncIssue: fetchIssue)
            }
            if evidence.needsAttention {
                try await persistence.recordAttention(.enrollmentBlocked)
                return try await statusUnchecked()
            }
            guard evidence.phase != .notEnrolled else { return try await statusUnchecked() }
            if try await bridge.setupRetryMustHold(
                deletedSnipIDs: deletedBeforeFetch,
                pointerDeletes: persistence.deferredSetupPointerDeletes(for: transition)
            ) {
                return try await holdSetupForDeletedSnip(transition)
            }
            try await persistence.recordPreparationComplete()
            transition = try await currentTransition()
        }

        do {
            if transition.phase == .remoteFetched {
                guard try await bridge.canPrepareModeMerge() else {
                    try await persistence.retryRemoteFetch()
                    return try await statusUnchecked()
                }
                let token = try await persistence.freezeSource()
                let source = try await persistence.finalSnapshot(using: token)
                if checksSetupRetry {
                    let deleted = await acknowledgedSetupSnipIDs().subtracting(source.snips.map(\.id))
                    let deferred = await persistence.deferredSetupPointerDeletes(for: transition)
                    if try await bridge.setupRetryMustHold(deletedSnipIDs: deleted, pointerDeletes: deferred) {
                        return try await holdSetupForDeletedSnip(transition)
                    }
                }
                let targetRevision = try await persistence.candidateRevision(
                    transitionID: transition.id
                )
                let retryEvidence: CloudSetupRetryEvidence?
                if transition.syncProtocol == .fullRecordV1 {
                    retryEvidence = await persistence.setupRetryEvidence(namespace: namespace.binding)
                    if retryEvidence != nil { try await requireMatchingAccount() }
                } else {
                    retryEvidence = nil
                }
                if payloadZone != nil, let retryEvidence, !retryEvidence.isEmpty {
                    _ = try await preserveIsolatedAttachmentsForLocalCopy(
                        storeID: transition.candidateStoreID,
                        setupRetry: (source, retryEvidence)
                    )
                    try await requireMatchingAccount()
                }
                switch try await bridge.prepareModeMerge(
                    source: source,
                    transitionID: transition.id,
                    targetRevision: targetRevision,
                    priorSeedProvenance: transition.seedProvenance,
                    retryEvidence: retryEvidence
                ) {
                case .fullRecord(let plan):
                    _ = try await persistence.mergeFullReenableSnapshot(
                        source,
                        using: token,
                        plan: plan
                    )
                case .legacy(let accepted):
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
                try await sendUntilSettled(adapter: bridge, transition: transition)
                try await persistence.recordFirstSendComplete()
                transition = try await currentTransition()
            }

            if transition.phase == .firstSendComplete {
                let receipts = await persistence.deferredSetupPointerDeletes(for: transition)
                var authorizedPointerDeletes: Set<CloudSetupPointerDelete.Key> = []
                if !receipts.isEmpty {
                    try await requireMatchingAccount()
                    try await checkSetupCollection()
                    let frozenSource = try await persistence.setupRetryFrozenSnapshot(
                        candidateStoreID: transition.candidateStoreID
                    )
                    let deleted = await acknowledgedSetupSnipIDs().subtracting(frozenSource.snips.map(\.id))
                    guard try await bridge.recheckSetupPointerCleanup(
                        deletedSnipIDs: deleted, receipts: receipts
                    ) else {
                        throw CloudSetupRetryHold()
                    }
                    try await requireMatchingAccount()
                    try await checkSetupCollection()
                    authorizedPointerDeletes = Set(receipts.map(\.key))
                }
                try await persistence.swapPointer(authorizedSetupPointerDeletes: authorizedPointerDeletes)
                transition = try await currentTransition()
            }
        } catch {
            if let stored = try? await persistence.snapshot(),
               stored.transition?.hasDurableFullReenableIntent == true {
                throw error
            }
            let retryable = isRetryableConnectivity(error)
            await restoreSourceAfterPreSwapFailure(error, retryable: retryable)
            if error is CloudSetupRetryHold { return try await statusUnchecked() }
            if retryable {
                return try await statusUnchecked(
                    syncIssue: SnipSnapCloudSyncIssueMapper.issue(for: error)
                )
            }
            throw error
        }

        if transition.phase == .pointerSwapped {
            try await persistence.finishTransition()
            try? await persistence.cleanupRetiredStores()
        }
        return try await statusUnchecked()
    }

    private func acknowledgedSetupSnipIDs() async -> Set<UUID> {
        let evidence = await persistence.setupRetryEvidence(namespace: namespace.binding)
        return Set(evidence?.acknowledgedSnipKeys.compactMap { key in
            guard CloudFullSyncPersistence.recordID(key.identity).zone == textZone else { return nil }
            return key.reference.domainID
        } ?? [])
    }

    private func deletedSetupSnipIDs(_ acknowledged: Set<UUID>) async throws -> Set<UUID> {
        guard !acknowledged.isEmpty else { return [] }
        let source = try await persistence.activeLibrary().checkedSnapshot(sortedBy: .manual)
        return acknowledged.subtracting(source.snips.map(\.id))
    }

    private func holdSetupForDeletedSnip(_ transition: SyncModeTransition) async throws -> ICloudSyncModeStatus {
        try await persistence.holdSetupForDeletedSnip(transitionID: transition.id)
        return try await statusUnchecked()
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

    private func adapter(
        storeID: UUID,
        captureSetupRetry: Bool = false,
        checksSetupRetry: Bool = false
    ) async throws -> any ICloudSyncAdapter {
        let storage = try await persistence.snapshot()
        let isActive = storage.activeStore.id == storeID
        let isCandidate = storage.transition?.candidateStoreID == storeID
        guard isActive || isCandidate else { throw SyncModePersistenceError.missingStore }
        guard let syncProtocol = isActive
            ? storage.activeStore.syncProtocol
            : storage.transition?.syncProtocol
        else { throw SyncModePersistenceError.missingStore }
        switch syncProtocol {
        case .legacyTextV1:
            let raw = try await rawBridge(storeID: storeID)
            return LegacyTextSyncAdapter(raw: raw, transport: makeTransport())
        case .fullRecordV1:
            let validateSetupAccount: CloudFullSyncPersistence.ApplyHook?
            if captureSetupRetry && isCandidate && !isActive {
                validateSetupAccount = { try await self.requireMatchingAccount() }
            } else {
                validateSetupAccount = nil
            }
            let raw = try await fullBridge(
                storeID: storeID,
                validateSetupAccount: validateSetupAccount,
                checksSetupRetry: checksSetupRetry
            )
            return FullRecordSyncAdapter(
                raw: raw,
                transport: makeTransport(),
                checksSetupRetry: checksSetupRetry,
                beforeApply: validateSetupAccount ?? {}
            )
        }
    }

    private func preserveAttachmentsForLocalCopy(storeID: UUID) async throws {
        guard payloadZone != nil else { return }
        let lease = try await persistence.activeCloudMutationLease(storeID: storeID, purpose: .modeChange)
        try await lease.run {
            _ = try await self.preserveIsolatedAttachmentsForLocalCopy(storeID: storeID)
        }
    }

    private func preserveIsolatedAttachmentsForLocalCopy(
        storeID: UUID,
        setupRetry: (source: SnipLibraryTransferSnapshot, evidence: CloudSetupRetryEvidence)? = nil
    ) async throws -> Bool {
        guard let payloadZone else { return false }
        let library = try await persistence.libraryForTransition(storeID: storeID)
        let coordinator = CloudAttachmentTransferCoordinator(
            library: library,
            namespace: namespace,
            payloadZone: payloadZone,
            transport: makeTransport(),
            maximumCacheBytes: CloudAttachmentTransferCoordinator.standardMaximumCacheBytes
        )
        if let setupRetry {
            let accepted = try await library.cloudFullStorageSnapshot(namespaceKey: namespace.namespaceKey)
            let attachments = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace.namespaceKey)
            let removedFromSnipOffers = try CloudSetupRetryCapture.removedAttachmentIDsBySnip(
                source: setupRetry.source, accepted: accepted.readyEntities,
                evidence: setupRetry.evidence, namespace: namespace, dataZone: textZone
            )
            let removedFromPointerOffers = CloudSetupRetryCapture.removedOfferedAttachmentIDsBySnip(
                source: setupRetry.source, publications: attachments.publications, evidence: setupRetry.evidence
            )
            return try await coordinator.preserveAllAttachmentsForLocalCopy(
                excluding: Set(setupRetry.source.attachmentData.keys),
                removedAttachmentIDsBySnip: removedFromSnipOffers.merging(removedFromPointerOffers) { $0.union($1) }
            )
        }
        return try await coordinator.preserveAllAttachmentsForLocalCopy()
    }

    private func rawBridge(storeID: UUID) async throws -> SwiftDataCloudTextPersistence {
        let library = try await persistence.libraryForTransition(storeID: storeID)
        return SwiftDataCloudTextPersistence(
            library: library,
            namespace: namespace,
            textZone: textZone,
            applyHook: applyHook
        )
    }


    private func fullBridge(
        storeID: UUID,
        validateSetupAccount: CloudFullSyncPersistence.ApplyHook?,
        checksSetupRetry: Bool
    ) async throws -> CloudFullSyncPersistence {
        let library = try await persistence.libraryForTransition(storeID: storeID)
        let recordResults: CloudFullSyncPersistence.SetupRetryResultHook?
        let retainPointerDelete: CloudFullSyncPersistence.RetainSetupPointerDelete?
        let setupPointerDeletes: (@Sendable () async -> [CloudSetupPointerDelete])?
        let setupAllocations: (@Sendable () async throws -> [UUID: CloudSetupPointerDelete.Replacement])?
        let preserveSetupReplacementRemaps: (@Sendable (CloudSetupPointerDelete.ReplacementRemaps) async throws -> Void)?
        if let validateSetupAccount {
            recordResults = { [persistence, namespace] results in
                try await validateSetupAccount()
                try await persistence.recordSetupRetryResults(
                    results,
                    candidateStoreID: storeID,
                    namespace: namespace.binding
                )
            }
            retainPointerDelete = { [persistence, namespace] binding in
                return try await persistence.retainSetupPointerDelete(
                    binding, candidateStoreID: storeID, namespace: namespace.binding
                )
            }
            setupPointerDeletes = { [persistence, namespace] in
                let evidence = await persistence.setupRetryEvidence(namespace: namespace.binding)
                return evidence?.acceptedPointerDeletes ?? []
            }
            setupAllocations = { [persistence, namespace] in
                try await persistence.setupReplacementAllocations(candidateStoreID: storeID, namespace: namespace.binding)
            }
            preserveSetupReplacementRemaps = { [persistence, namespace] remaps in
                guard !remaps.isEmpty else { return }
                let storage = try await persistence.snapshot()
                guard let transition = storage.transition, transition.candidateStoreID == storeID,
                      transition.namespace == namespace.binding
                else { throw SyncModePersistenceError.transitionInProgress }
                try await persistence.preserveSetupPointerReplacementRemaps(remaps, for: transition)
            }
        } else {
            recordResults = nil
            retainPointerDelete = nil
            setupPointerDeletes = nil
            setupAllocations = nil
            preserveSetupReplacementRemaps = nil
        }
        let deletedSnipIDs: (@Sendable () async throws -> Set<UUID>)?
        let withBatchCommit: CloudFullSyncPersistence.SetupRetryBatchCommit?
        if checksSetupRetry {
            deletedSnipIDs = { [self] in
                try await deletedSetupSnipIDs(await acknowledgedSetupSnipIDs())
            }
            withBatchCommit = { [persistence, namespace] commit in
                try await persistence.withSetupRetryBatchCommit(
                    candidateStoreID: storeID, namespace: namespace.binding, commit
                )
            }
        } else {
            deletedSnipIDs = nil
            withBatchCommit = nil
        }
        return CloudFullSyncPersistence(
            library: library,
            namespace: namespace,
            dataZone: textZone,
            payloadZone: payloadZone,
            attachmentPolicy: attachmentPolicy,
            recordSetupRetryResults: recordResults,
            retainSetupPointerDelete: retainPointerDelete,
            setupPointerDeletes: setupPointerDeletes,
            setupReplacementAllocations: setupAllocations,
            preserveSetupReplacementRemaps: preserveSetupReplacementRemaps,
            setupRetryDeletedSnipIDs: deletedSnipIDs,
            withSetupRetryBatchCommit: withBatchCommit
        )
    }

    private func currentTransition() async throws -> SyncModeTransition {
        guard let transition = try await persistence.snapshot().transition else {
            throw SyncModePersistenceError.transitionInProgress
        }
        return transition
    }

    private func sendUntilSettled(
        adapter: any ICloudSyncAdapter,
        transition: SyncModeTransition
    ) async throws {
        let candidateStoreID = transition.candidateStoreID
        let capturesSetupRetry = transition.syncProtocol == .fullRecordV1
        for _ in 0..<8 {
            try await adapter.sendPending { [persistence, namespace, textZone, payloadZone] outbound in
                try await self.requireMatchingAccount()
                let attempt = try await adapter.modeSendAttempt(
                    for: outbound,
                    namespace: namespace.binding
                )
                if capturesSetupRetry {
                    guard let freezeToken = transition.freezeToken else {
                        throw SyncModePersistenceError.invalidFreezeToken
                    }
                    let source = try await persistence.setupRetryFrozenSnapshot(candidateStoreID: candidateStoreID)
                    let offers = try CloudSetupRetryCapture.offers(
                        for: outbound,
                        source: source,
                        dataZone: textZone,
                        payloadZone: payloadZone
                    )
                    try await self.requireMatchingAccount()
                    try await persistence.recordSendAttempt(
                        attempt,
                        setupRetryOffers: offers,
                        expectedSetupFreezeToken: freezeToken
                    )
                    try await self.checkSetupCollection()
                    let retained = await persistence.setupRetryEvidence(namespace: namespace.binding)
                    let protected = CloudSetupPointerDelete.protectedIdentities(retained?.acceptedPointerDeletes ?? [])
                    if outbound.operations.contains(where: { protected.contains(CloudFullSyncPersistence.storageIdentity($0.id)) }) {
                        throw CloudSetupRetryHold()
                    }
                } else {
                    try await persistence.recordSendAttempt(attempt)
                }
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

    private func restoreSourceAfterPreSwapFailure(_ error: Error, retryable: Bool) async {
        guard let storage = try? await persistence.snapshot(),
              let transition = storage.transition,
              transition.phase != .pointerSwapped,
              storage.activeStore.id == transition.sourceStoreID else { return }
        let reason: ICloudSyncAttentionReason? = if retryable {
            nil
        } else if error is CloudSetupRetryHold {
            .transferConflict
        } else if case SnipLibraryError.transferConflict = error {
            .transferConflict
        } else {
            .transitionFailure
        }
        if [.firstSendStarted, .firstSendComplete].contains(transition.phase) {
            let modeAdapter = try? await adapter(storeID: transition.candidateStoreID)
            let candidates = transition.seedSettlementCandidates
            let settlement: SyncModeSeedSettlementProof?
            if let modeAdapter {
                settlement = try? await modeAdapter.currentModeSeedSettlement(
                    candidates: candidates,
                    namespace: namespace.binding
                )
                try? await modeAdapter.prepareFailureRecovery(
                    snipIDs: Set(candidates.map(\.snipID))
                )
            } else {
                settlement = nil
            }
            if (try? await persistence.restartAfterFirstSendFailure(
                reason: reason,
                settlement: settlement
            )) == nil {
                try? await persistence.restartAfterFirstSendFailure(
                    reason: reason,
                    settlement: settlement
                )
            }
        } else if (try? await persistence.unfreezeBeforePointerSwap(reason: reason)) == nil {
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
        if let reason = storage.attentionReason {
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
