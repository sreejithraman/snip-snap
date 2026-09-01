import Foundation
import SnipSnapCore
import SnipSnapPersistence

private protocol ICloudSyncAdapter: Sendable {
    func sync() async throws
    func fetchRemote(
        beforeApply: @escaping @Sendable () async throws -> Void
    ) async throws
    func sendPending(
        beforeSend: @escaping @Sendable (CloudOutboundBatch) async throws -> Void
    ) async throws
    func approveModeMerge(snipIDs: Set<UUID>) async throws
    func enrollmentEvidence() async throws -> CloudTextEnrollmentEvidence
    func statusEvidence() async throws -> CloudTextEnrollmentEvidence
    func acceptedSnipTextValues() async throws -> [UUID: String]
    func dormantAcceptedBaseTransferPayload() async throws -> Data?
    func isReenableReady() async throws -> Bool
    func makeReenableApplyPlan(
        source: SnipLibraryTransferSnapshot,
        transitionID: UUID,
        targetRevision: UInt64
    ) async throws -> CloudFullReenableApplyPlan?
    func clearRetryableEvents(_ keys: Set<String>) async throws
    func currentModeSeedSettlement(
        candidates: [SyncModeSeedSettlementCandidate],
        namespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSeedSettlementProof
    func modeSendAttempt(
        for outbound: CloudOutboundBatch,
        namespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSendAttempt
    func prepareModeRetry(snipIDs: Set<UUID>) async throws
}

private enum ICloudAccountGateError: Error {
    case stateChanged
}

private actor LegacyTextSyncAdapter: ICloudSyncAdapter {
    private let raw: SwiftDataCloudTextPersistence
    private let syncDriver: CloudTextSyncCoordinator

    init(raw: SwiftDataCloudTextPersistence, transport: any CloudRecordTransport) {
        self.raw = raw
        syncDriver = CloudTextSyncCoordinator(store: raw, transport: transport)
    }

    func sync() async throws {
        try await syncDriver.sync()
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

    func approveModeMerge(snipIDs: Set<UUID>) async throws {
        try await raw.approveModeMerge(snipIDs: snipIDs)
    }

    func enrollmentEvidence() async throws -> CloudTextEnrollmentEvidence {
        try await raw.enrollmentEvidence()
    }

    func statusEvidence() async throws -> CloudTextEnrollmentEvidence {
        try await raw.statusEvidence()
    }

    func acceptedSnipTextValues() async throws -> [UUID: String] {
        try await raw.acceptedSnipTextValues()
    }

    func dormantAcceptedBaseTransferPayload() async throws -> Data? { nil }

    func isReenableReady() async throws -> Bool { true }

    func makeReenableApplyPlan(
        source: SnipLibraryTransferSnapshot,
        transitionID: UUID,
        targetRevision: UInt64
    ) async throws -> CloudFullReenableApplyPlan? { nil }

    func clearRetryableEvents(_ keys: Set<String>) async throws {
        try await raw.clearRetryableEvents(keys)
    }

    func currentModeSeedSettlement(
        candidates: [SyncModeSeedSettlementCandidate],
        namespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSeedSettlementProof {
        try await raw.currentModeSeedSettlement(candidates: candidates, namespace: namespace)
    }

    func prepareModeRetry(snipIDs: Set<UUID>) async throws {
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

    init(raw: CloudFullSyncPersistence, transport: any CloudRecordTransport) {
        self.raw = raw
        syncDriver = CloudFullSyncCoordinator(
            store: raw,
            transport: transport,
            fetchScope: .zones([raw.dataZone])
        )
    }

    func sync() async throws { try await syncDriver.sync() }

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

    func approveModeMerge(snipIDs: Set<UUID>) async throws {
        try await raw.approveModeMerge(snipIDs: snipIDs)
    }

    func enrollmentEvidence() async throws -> CloudTextEnrollmentEvidence {
        try await raw.enrollmentEvidence()
    }

    func statusEvidence() async throws -> CloudTextEnrollmentEvidence {
        try await raw.statusEvidence()
    }

    func acceptedSnipTextValues() async throws -> [UUID: String] {
        try await raw.acceptedSnipTextValues()
    }

    func dormantAcceptedBaseTransferPayload() async throws -> Data? {
        try await raw.dormantAcceptedBaseTransferPayload()
    }

    func isReenableReady() async throws -> Bool {
        try await raw.isReenableReady()
    }

    func makeReenableApplyPlan(
        source: SnipLibraryTransferSnapshot,
        transitionID: UUID,
        targetRevision: UInt64
    ) async throws -> CloudFullReenableApplyPlan? {
        try await raw.makeReenableApplyPlan(
            source: source,
            transitionID: transitionID,
            targetRevision: targetRevision
        )
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

    func prepareModeRetry(snipIDs: Set<UUID>) async throws {
        try await raw.prepareModeRetry(snipIDs: snipIDs)
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

    package init(
        state: ICloudSyncModeState,
        activeStoreID: UUID,
        attentionReason: ICloudSyncAttentionReason? = nil
    ) {
        self.state = state
        self.activeStoreID = activeStoreID
        self.attentionReason = attentionReason
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
        accountStateSource: (any ICloudAccountStateSource)? = nil
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
        try await persistence.reconcileAccountIsolationResolution()
        let storage = try await persistence.snapshot()
        if let isolation = storage.accountIsolation,
           case .available(let accountLineage) = accountState,
           accountLineage == isolation.namespace.accountLineage,
           isolation.namespace == namespace.binding {
            try await persistence.resolveAccountIsolation(.keepLocalCopy)
            return try await enableOrRetry()
        }
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
                    guard evidence.hasPendingChanges, !evidence.needsAttention,
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

        var transition = try await persistence.beginTransition(
            to: .iCloudSync,
            namespace: namespace.binding
        )
        let bridge = try await adapter(storeID: transition.candidateStoreID)
        try await persistence.reconcileFullReenableIntent()
        transition = try await currentTransition()

        if transition.phase == .candidateReady {
            do {
                let candidates = settlementCandidates(transition)
                let settlement = try await bridge.currentModeSeedSettlement(
                    candidates: candidates,
                    namespace: namespace.binding
                )
                try await bridge.prepareModeRetry(snipIDs: Set(candidates.map(\.snipID)))
                try await persistence.prepareRetryFetch(settlement: settlement)
                try await requireMatchingAccount()
                try await bridge.fetchRemote {
                    try await self.requireMatchingAccount()
                }
            } catch {
                if error is ICloudAccountGateError {
                    return try await statusUnchecked(
                        accountState: await accountStateSource.currentAccountState()
                    )
                }
                if isRetryableConnectivity(error) { return try await statusUnchecked() }
                try await persistence.recordAttention(.terminalFetchFailure)
                return try await statusUnchecked()
            }
            let evidence = try await bridge.enrollmentEvidence()
            if !evidence.retryableEventKeys.isEmpty {
                try await bridge.clearRetryableEvents(evidence.retryableEventKeys)
                return try await statusUnchecked()
            }
            if evidence.needsAttention {
                try await persistence.recordAttention(.enrollmentBlocked)
                return try await statusUnchecked()
            }
            guard evidence.phase != .notEnrolled else { return try await statusUnchecked() }
            try await persistence.recordPreparationComplete()
            transition = try await currentTransition()
        }

        do {
            if transition.phase == .remoteFetched {
                guard try await bridge.isReenableReady() else {
                    try await persistence.retryRemoteFetch()
                    return try await statusUnchecked()
                }
                let token = try await persistence.freezeSource()
                let source = try await persistence.finalSnapshot(using: token)
                let targetRevision = try await persistence.candidateRevision(
                    transitionID: transition.id
                )
                if let plan = try await bridge.makeReenableApplyPlan(
                    source: source,
                    transitionID: transition.id,
                    targetRevision: targetRevision
                ) {
                    _ = try await persistence.mergeFullReenableSnapshot(
                        source,
                        using: token,
                        plan: plan
                    )
                } else {
                    let accepted = try await bridge.acceptedSnipTextValues()
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
                try await persistence.swapPointer()
                transition = try await currentTransition()
            }
        } catch {
            if let stored = try? await persistence.snapshot(),
               stored.transition?.mergeIntent?.fullReenablePlanID != nil {
                throw error
            }
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
            let lease = try await persistence.activeCloudMutationLease(storeID: initial.activeStore.id)
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

    private func adapter(storeID: UUID) async throws -> any ICloudSyncAdapter {
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
            let raw = try await fullBridge(storeID: storeID)
            return FullRecordSyncAdapter(raw: raw, transport: makeTransport())
        }
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


    private func fullBridge(storeID: UUID) async throws -> CloudFullSyncPersistence {
        let library = try await persistence.libraryForTransition(storeID: storeID)
        return CloudFullSyncPersistence(
            library: library,
            namespace: namespace,
            dataZone: textZone,
            payloadZone: payloadZone,
            attachmentPolicy: attachmentPolicy
        )
    }

    private func currentTransition() async throws -> SyncModeTransition {
        guard let transition = try await persistence.snapshot().transition else {
            throw SyncModePersistenceError.transitionInProgress
        }
        return transition
    }

    private func sendUntilSettled(
        adapter: any ICloudSyncAdapter
    ) async throws {
        for _ in 0..<8 {
            try await adapter.sendPending { [persistence, namespace] outbound in
                try await self.requireMatchingAccount()
                let attempt = try await adapter.modeSendAttempt(
                    for: outbound,
                    namespace: namespace.binding
                )
                try await persistence.recordSendAttempt(attempt)
            }
            let evidence = try await adapter.enrollmentEvidence()
            if evidence.hasRetryableRecordFailures || !evidence.retryableEventKeys.isEmpty {
                try await adapter.clearRetryableEvents(evidence.retryableEventKeys)
                throw CloudSyncRetryableError.itemFailure
            }
            if evidence.phase == .blocked {
                throw CloudNamespaceEnrollmentError.invalidSeedSelection
            }
            if evidence.phase == .active, !evidence.hasPendingChanges { return }
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
        return false
    }

    private func restoreSourceAfterPreSwapFailure(_ error: Error, retryable: Bool) async {
        guard let storage = try? await persistence.snapshot(),
              let transition = storage.transition,
              transition.phase != .pointerSwapped,
              storage.activeStore.id == transition.sourceStoreID else { return }
        let reason: ICloudSyncAttentionReason? = if retryable {
            nil
        } else if case SnipLibraryError.transferConflict = error {
            .transferConflict
        } else {
            .transitionFailure
        }
        if [.firstSendStarted, .firstSendComplete].contains(transition.phase) {
            let modeAdapter = try? await adapter(storeID: transition.candidateStoreID)
            let candidates = settlementCandidates(transition)
            let settlement: SyncModeSeedSettlementProof?
            if let modeAdapter {
                settlement = try? await modeAdapter.currentModeSeedSettlement(
                    candidates: settlementCandidates(transition),
                    namespace: namespace.binding
                )
                try? await modeAdapter.prepareModeRetry(snipIDs: Set(candidates.map(\.snipID)))
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

    private func settlementCandidates(
        _ transition: SyncModeTransition
    ) -> [SyncModeSeedSettlementCandidate] {
        let provenanceIDs = Set(transition.seedProvenance.map(\.candidateSnipID))
        return transition.sendAttempt?.operations.compactMap { operation in
            guard let reference = operation.reference,
                  reference.kind == .snip,
                  provenanceIDs.contains(reference.domainID)
            else { return nil }
            return SyncModeSeedSettlementCandidate(
                snipID: reference.domainID,
                acceptedRecordIdentity: operation.recordIdentity
            )
        } ?? []
    }

    private func statusUnchecked(
        accountState: ICloudAccountState? = nil
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
            return ICloudSyncModeStatus(state: state, activeStoreID: storage.activeStore.id)
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
        guard case .available(let accountLineage) = await accountStateSource.currentAccountState(),
              accountLineage == namespace.accountLineage
        else { throw ICloudAccountGateError.stateChanged }
    }
}

private extension CloudSyncNamespace {
    var binding: ICloudSyncNamespaceBinding {
        ICloudSyncNamespaceBinding(
            scope: cloudScope,
            accountLineage: accountLineage,
            generation: generation,
            zones: Set(zones.map { ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName) })
        )
    }
}
