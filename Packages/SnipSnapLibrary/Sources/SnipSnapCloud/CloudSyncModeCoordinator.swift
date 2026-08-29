import Foundation
import SnipSnapCore
import SnipSnapPersistence

private protocol ICloudModeTextPersistence: CloudTextSyncPersistence {
    func approveModeMerge(snipIDs: Set<UUID>) async throws
    func enrollmentEvidence() async throws -> CloudTextEnrollmentEvidence
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

extension SwiftDataCloudTextPersistence: ICloudModeTextPersistence {}

private actor ModeManagedCloudTextPersistence: ICloudModeTextPersistence {
    private let raw: SwiftDataCloudTextPersistence
    private let lease: SyncModeActiveMutationLease

    init(raw: SwiftDataCloudTextPersistence, lease: SyncModeActiveMutationLease) {
        self.raw = raw
        self.lease = lease
    }

    func loadEngineState() async throws -> CloudEngineStateEnvelope? {
        try await raw.loadEngineState()
    }

    func stagedBatches() async throws -> [CloudSyncBatch] {
        try await raw.stagedBatches()
    }

    func stage(_ batch: CloudSyncBatch) async throws {
        try await lease.run { [raw] in try await raw.stage(batch) }
    }

    func applyStaged(_ id: UUID) async throws {
        try await lease.run { [raw] in try await raw.applyStaged(id) }
    }

    func pendingChanges() async throws -> CloudOutboundBatch {
        try await lease.run { [raw] in try await raw.pendingChanges() }
    }

    func clear() async throws {
        try await lease.run { [raw] in try await raw.clear() }
    }

    func approveModeMerge(snipIDs: Set<UUID>) async throws {
        try await lease.run { [raw] in try await raw.approveModeMerge(snipIDs: snipIDs) }
    }

    func enrollmentEvidence() async throws -> CloudTextEnrollmentEvidence {
        try await lease.run { [raw] in try await raw.enrollmentEvidence() }
    }

    func clearRetryableEvents(_ keys: Set<String>) async throws {
        try await lease.run { [raw] in try await raw.clearRetryableEvents(keys) }
    }

    func currentModeSeedSettlement(
        candidates: [SyncModeSeedSettlementCandidate],
        namespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSeedSettlementProof {
        try await lease.run { [raw] in
            try await raw.currentModeSeedSettlement(candidates: candidates, namespace: namespace)
        }
    }

    func prepareModeRetry(snipIDs: Set<UUID>) async throws {
        try await lease.run { [raw] in try await raw.prepareModeRetry(snipIDs: snipIDs) }
    }

    func modeSendAttempt(
        for outbound: CloudOutboundBatch,
        namespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSendAttempt {
        try await lease.run { [raw] in
            try await raw.modeSendAttempt(for: outbound, namespace: namespace)
        }
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
    private let makeTransport: TransportFactory
    private let applyHook: SwiftDataCloudTextPersistence.ApplyHook
    private enum Operation { case enable, optOut, activeSync }
    private var currentOperation: Operation?

    package init(
        persistence: SwiftDataSyncModePersistence,
        namespace: CloudSyncNamespace,
        textZone: CloudZoneID,
        makeTransport: @escaping TransportFactory,
        applyHook: @escaping SwiftDataCloudTextPersistence.ApplyHook = {}
    ) {
        precondition(namespace.zones.contains(textZone))
        self.persistence = persistence
        self.namespace = namespace
        self.textZone = textZone
        self.makeTransport = makeTransport
        self.applyHook = applyHook
    }

    package func status() async throws -> ICloudSyncModeStatus {
        try await statusUnchecked()
    }

    /// The only active-store Cloud sync entry point later app assembly should use.
    @discardableResult
    package func syncActive() async throws -> ICloudSyncModeStatus {
        try begin(.activeSync)
        var operationEnded = false
        defer { if !operationEnded { end() } }
        let storage = try await persistence.snapshot()
        try await persistence.requireActiveNamespace(namespace.binding)
        let lease = try await persistence.activeCloudMutationLease(storeID: storage.activeStore.id)
        let raw = try await rawBridge(storeID: storage.activeStore.id)
        try await lease.run {
            let sync = CloudTextSyncCoordinator(store: raw, transport: self.makeTransport())
            try await sync.sync()
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

        var transition = try await persistence.beginTransition(
            to: .iCloudSync,
            namespace: namespace.binding
        )
        let bridge = try await bridge(storeID: transition.candidateStoreID)
        let sync = CloudTextSyncCoordinator(store: bridge, transport: makeTransport())

        if transition.phase == .candidateReady {
            do {
                let candidates = settlementCandidates(transition)
                let settlement = try await bridge.currentModeSeedSettlement(
                    candidates: candidates,
                    namespace: namespace.binding
                )
                try await bridge.prepareModeRetry(snipIDs: Set(candidates.map(\.snipID)))
                try await persistence.prepareRetryFetch(settlement: settlement)
                try await sync.fetchRemote()
            } catch {
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
                let token = try await persistence.freezeSource()
                let source = try await persistence.finalSnapshot(using: token)
                _ = try await persistence.mergeFinalSnapshot(source, using: token)
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
                try await sendUntilSettled(sync: sync, bridge: bridge)
                try await persistence.recordFirstSendComplete()
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

        if initial.transition == nil, choice == .refreshThenCopy {
            let lease = try await persistence.activeCloudMutationLease(storeID: initial.activeStore.id)
            let activeBridge = try await rawBridge(storeID: initial.activeStore.id)
            do {
                let evidence = try await lease.run {
                    let sync = CloudTextSyncCoordinator(
                        store: activeBridge,
                        transport: self.makeTransport()
                    )
                    try await sync.fetchRemote()
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
                let source = try await persistence.finalSnapshot(using: token)
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

    private func bridge(storeID: UUID) async throws -> any ICloudModeTextPersistence {
        let storage = try await persistence.snapshot()
        let isActive = storage.activeStore.id == storeID
        let isCandidate = storage.transition?.candidateStoreID == storeID
        guard isActive || isCandidate else { throw SyncModePersistenceError.missingStore }
        let raw = try await rawBridge(storeID: storeID)
        guard isActive, storage.activeStore.kind == .iCloudSync else { return raw }
        let lease = try await persistence.activeCloudMutationLease(storeID: storeID)
        return ModeManagedCloudTextPersistence(raw: raw, lease: lease)
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

    private func currentTransition() async throws -> SyncModeTransition {
        guard let transition = try await persistence.snapshot().transition else {
            throw SyncModePersistenceError.transitionInProgress
        }
        return transition
    }

    private func sendUntilSettled(
        sync: CloudTextSyncCoordinator,
        bridge: any ICloudModeTextPersistence
    ) async throws {
        for _ in 0..<8 {
            try await sync.sendPending { [persistence, namespace] outbound in
                let attempt = try await bridge.modeSendAttempt(
                    for: outbound,
                    namespace: namespace.binding
                )
                try await persistence.recordSendAttempt(attempt)
            }
            let evidence = try await bridge.enrollmentEvidence()
            if evidence.hasRetryableRecordFailures || !evidence.retryableEventKeys.isEmpty {
                try await bridge.clearRetryableEvents(evidence.retryableEventKeys)
                throw CloudSyncRetryableError.itemFailure
            }
            if evidence.needsAttention || evidence.phase == .blocked {
                throw CloudNamespaceEnrollmentError.invalidSeedSelection
            }
            if evidence.phase == .active, !evidence.hasPendingChanges { return }
        }
        throw CloudTransportError.sendFailed
    }

    private func isRetryableConnectivity(_ error: Error) -> Bool {
        if let error = error as? FakeCloudError {
            return error == .injectedFetchFailure || error == .injectedSendFailure
        }
        if let error = error as? CloudTransportError {
            return error == .fetchFailed || error == .sendFailed
        }
        if error is CloudSyncRetryableError { return true }
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
            let raw = try? await rawBridge(storeID: transition.candidateStoreID)
            let candidates = settlementCandidates(transition)
            let settlement: SyncModeSeedSettlementProof?
            if let raw {
                settlement = try? await raw.currentModeSeedSettlement(
                    candidates: settlementCandidates(transition),
                    namespace: namespace.binding
                )
                try? await raw.prepareModeRetry(snipIDs: Set(candidates.map(\.snipID)))
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
            guard provenanceIDs.contains(operation.snipID) else { return nil }
            return SyncModeSeedSettlementCandidate(
                snipID: operation.snipID,
                acceptedRecordIdentity: operation.recordIdentity
            )
        } ?? []
    }

    private func statusUnchecked() async throws -> ICloudSyncModeStatus {
        let storage = try await persistence.snapshot()
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
        try await persistence.requireActiveNamespace(namespace.binding)
        if currentOperation == .optOut || currentOperation == .activeSync
            || storage.hasActiveMutationReservation {
            return ICloudSyncModeStatus(state: .syncing, activeStoreID: storage.activeStore.id)
        }
        let evidence = try await bridge(storeID: storage.activeStore.id).enrollmentEvidence()
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
