import Foundation
import SnipSnapCore
import SnipSnapPersistence

package enum CloudNamespaceEnrollmentError: Error, Equatable, Sendable {
    case remoteFetchRequired
    case invalidSeedSelection
}

package struct CloudTextEnrollmentEvidence: Equatable, Sendable {
    package let phase: CloudNamespaceBootstrapPhase
    package let hasPendingChanges: Bool
    package let hasRetryableRecordFailures: Bool
    package let retryableEventKeys: Set<String>
    package let needsAttention: Bool
}

package enum CloudSyncRetryableError: Error, Equatable, Sendable {
    case itemFailure
}

package actor SwiftDataCloudTextPersistence: CloudTextSyncPersistence {
    package typealias ApplyHook = @Sendable () async throws -> Void
    enum RecoveryInput: Codable {
        case fetched(CloudFetchItemResult)
        case sent(CloudSendItemResult)
        case database(CloudDatabaseEvent)
        case zone(CloudZoneEvent)
        case modeRetryDeletion
    }

    private let library: SwiftDataSnipLibrary
    private let namespace: CloudSyncNamespace
    private let textZone: CloudZoneID
    private let namespaceKey: CloudSyncNamespaceKey
    private let applyHook: ApplyHook

    package init(
        library: SwiftDataSnipLibrary,
        namespace: CloudSyncNamespace,
        textZone: CloudZoneID,
        applyHook: @escaping ApplyHook = {}
    ) {
        precondition(namespace.zones.contains(textZone))
        self.library = library
        self.namespace = namespace
        self.textZone = textZone
        self.applyHook = applyHook
        namespaceKey = namespace.namespaceKey
    }

    package func loadEngineState() async throws -> CloudEngineStateEnvelope? {
        let snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        guard let data = snapshot.engineState else { return nil }
        let envelope = try JSONDecoder().decode(CloudEngineStateEnvelope.self, from: data)
        guard envelope.namespace == namespace else {
            throw CloudTransportError.stateNamespaceMismatch
        }
        return envelope
    }

    package func stagedBatches() async throws -> [CloudSyncBatch] {
        let snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        return try snapshot.stagedBatches
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map {
                guard let payload = CloudWirePayloadEnvelope.legacyPayload(from: $0.payload) else {
                    throw CloudTransportError.invalidRecord
                }
                return try JSONDecoder().decode(CloudSyncBatch.self, from: payload)
            }
    }

    package func stage(_ batch: CloudSyncBatch) async throws {
        let batch = Self.sanitizedTextBatch(batch)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try await library.stageCloudTextBatch(
            namespaceKey: namespaceKey,
            batchID: batch.id,
            payload: try CloudWirePayloadEnvelope(
                format: .legacyTextV1,
                payload: encoder.encode(batch)
            ).encoded()
        )
    }

    package func applyStaged(_ id: UUID) async throws {
        try await applyHook()
        let snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        guard let stored = snapshot.stagedBatches.first(where: { $0.id == id }) else { return }
        guard let payload = CloudWirePayloadEnvelope.legacyPayload(from: stored.payload) else {
            throw CloudTransportError.invalidRecord
        }
        let batch = try JSONDecoder().decode(CloudSyncBatch.self, from: payload)
        switch batch {
        case .fetched(let fetched):
            try await applyFetched(fetched)
        case .sent(let sent):
            try await applySent(sent)
        }
    }

    package func pendingChanges() async throws -> CloudOutboundBatch {
        var snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        if snapshot.namespaceState.phase == .seeding {
            let liveSnipIDs = Set(snapshot.snips.map(\.id))
            let remainingApproved = snapshot.namespaceState.approvedSnipIDs
                .intersection(liveSnipIDs)
            if remainingApproved != snapshot.namespaceState.approvedSnipIDs {
                let linkedSnipIDs = Set(snapshot.records.map(\.snipID))
                let seedFinished = remainingApproved.isEmpty
                    && !snapshot.namespaceState.zoneCreationPending
                let phase: CloudNamespaceBootstrapPhase = seedFinished ? .active : .seeding
                let excluded = remainingApproved.isEmpty
                    ? snapshot.namespaceState.excludedSnipIDs.union(
                        liveSnipIDs.subtracting(linkedSnipIDs)
                    )
                    : snapshot.namespaceState.excludedSnipIDs
                try await library.transitionCloudTextNamespace(
                    namespaceKey: namespaceKey,
                    expectedPhase: .seeding,
                    value: CloudNamespaceStateStorage(
                        phase: phase,
                        approvedSnipIDs: remainingApproved,
                        excludedSnipIDs: excluded,
                        zoneCreationPending: snapshot.namespaceState.zoneCreationPending
                    )
                )
                snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
            }
        }
        var eligibleSnipIDs: Set<UUID>
        switch snapshot.namespaceState.phase {
        case .seeding:
            eligibleSnipIDs = snapshot.namespaceState.approvedSnipIDs
        case .active:
            eligibleSnipIDs = Set(snapshot.snips.map(\.id))
                .subtracting(snapshot.namespaceState.excludedSnipIDs)
        case .notEnrolled, .remoteChecked, .remoteCheckedMissingZone, .blocked:
            return CloudOutboundBatch(operations: [])
        }
        eligibleSnipIDs.formUnion(snapshot.records.compactMap { record in
            Self.isModeRetryDeletion(Self.recoveryInput(record.recoveryData))
                ? record.snipID : nil
        })
        let liveSnipIDs = Set(snapshot.snips.map(\.id))
        if try await library.discardUnacceptedCloudTextRecords(
            namespaceKey: namespaceKey,
            liveSnipIDs: liveSnipIDs
        ) {
            snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        }
        let knownSnipIDs = Set(snapshot.records.map(\.snipID))
        let newEligibleSnipIDs = eligibleSnipIDs
            .intersection(liveSnipIDs)
            .subtracting(knownSnipIDs)
        let reservations = newEligibleSnipIDs.map { snipID in
            CloudTextRecordReservation(
                identity: Self.storageIdentity(.random(in: textZone)),
                snipID: snipID
            )
        }
        try await library.reserveCloudTextRecords(
            namespaceKey: namespaceKey,
            reservations: reservations
        )
        if !newEligibleSnipIDs.isEmpty {
            snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        }

        let snips = Dictionary(uniqueKeysWithValues: snapshot.snips.map { ($0.id, $0) })
        var operations: [CloudOutboundOperation] = []
        for stored in snapshot.records
            where eligibleSnipIDs.contains(stored.snipID)
                && !Self.blocksAutomaticRetry(
                    stored.recoveryData,
                    phase: snapshot.namespaceState.phase
                )
        {
            let id = Self.recordID(stored.identity)
            let shadow = try Self.shadow(stored)
            if let snip = snips[stored.snipID] {
                guard stored.acceptedText != snip.content || shadow == nil else { continue }
                operations.append(
                    .save(
                        .text(
                            id: id,
                            snipID: snip.id,
                            text: snip.content,
                            base: shadow
                        )
                    )
                )
            } else if let shadow {
                operations.append(.delete(id, base: shadow))
            }
        }
        return CloudOutboundBatch(
            operations: operations.sorted { $0.id.name < $1.id.name },
            zonesToSave: snapshot.namespaceState.zoneCreationPending ? [textZone] : []
        )
    }

    package func approveSeeding(snipIDs: Set<UUID>) async throws {
        let snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        guard snapshot.namespaceState.phase == .remoteChecked
                || snapshot.namespaceState.phase == .remoteCheckedMissingZone
        else {
            throw CloudNamespaceEnrollmentError.remoteFetchRequired
        }
        let localIDs = Set(snapshot.snips.map(\.id))
        guard snipIDs.isSubset(of: localIDs) else {
            throw CloudNamespaceEnrollmentError.invalidSeedSelection
        }
        try await library.transitionCloudTextNamespace(
            namespaceKey: namespaceKey,
            expectedPhase: snapshot.namespaceState.phase,
            value: CloudNamespaceStateStorage(
                phase: snipIDs.isEmpty
                    && snapshot.namespaceState.phase == .remoteChecked ? .active : .seeding,
                approvedSnipIDs: snipIDs,
                excludedSnipIDs: localIDs.subtracting(snipIDs),
                zoneCreationPending: snapshot.namespaceState.phase == .remoteCheckedMissingZone
            )
        )
    }

    /// Records the exact local additions approved by a mode change after remote data is durable.
    package func approveModeMerge(snipIDs: Set<UUID>) async throws {
        let snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        if snapshot.namespaceState.phase == .remoteChecked
            || snapshot.namespaceState.phase == .remoteCheckedMissingZone
        {
            try await approveSeeding(snipIDs: snipIDs)
            return
        }
        if snapshot.namespaceState.phase == .seeding {
            let localIDs = Set(snapshot.snips.map(\.id))
            guard snipIDs.isSubset(of: localIDs) else {
                throw CloudNamespaceEnrollmentError.invalidSeedSelection
            }
            try await library.prepareCloudTextModeRetry(
                namespaceKey: namespaceKey,
                supersededSnipIDs: snapshot.namespaceState.approvedSnipIDs,
                liveSnipIDs: localIDs,
                deletionRecoveryData: try Self.encode(.modeRetryDeletion)
            )
            guard snapshot.namespaceState.approvedSnipIDs != snipIDs else { return }
            try await library.transitionCloudTextNamespace(
                namespaceKey: namespaceKey,
                expectedPhase: .seeding,
                value: CloudNamespaceStateStorage(
                    phase: snipIDs.isEmpty ? .active : .seeding,
                    approvedSnipIDs: snipIDs,
                    excludedSnipIDs: snapshot.namespaceState.excludedSnipIDs
                        .subtracting(snipIDs)
                )
            )
            return
        }
        guard snapshot.namespaceState.phase == .active else {
            throw CloudNamespaceEnrollmentError.remoteFetchRequired
        }
        let localIDs = Set(snapshot.snips.map(\.id))
        let linkedIDs = Set(snapshot.records.map(\.snipID))
        let unlinkedIDs = localIDs.subtracting(linkedIDs)
        guard snipIDs.isSubset(of: localIDs) else {
            throw CloudNamespaceEnrollmentError.invalidSeedSelection
        }
        let approvedIDs = snipIDs.intersection(unlinkedIDs)
        try await library.transitionCloudTextNamespace(
            namespaceKey: namespaceKey,
            expectedPhase: .active,
            value: CloudNamespaceStateStorage(
                phase: approvedIDs.isEmpty ? .active : .seeding,
                approvedSnipIDs: approvedIDs,
                excludedSnipIDs: snapshot.namespaceState.excludedSnipIDs
                    .union(unlinkedIDs.subtracting(approvedIDs))
            )
        )
    }

    package func enrollmentEvidence() async throws -> CloudTextEnrollmentEvidence {
        let snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        let pending = try await pendingChanges()
        return Self.enrollmentEvidence(
            snapshot: snapshot,
            hasPendingChanges: !pending.operations.isEmpty || !pending.zonesToSave.isEmpty
        )
    }

    /// Reports status without running pending-change normalization or writing the store.
    package func statusEvidence() async throws -> CloudTextEnrollmentEvidence {
        let snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        return Self.enrollmentEvidence(snapshot: snapshot, hasPendingChanges: false)
    }

    package func acceptedSnipTextValues() async throws -> [UUID: String] {
        try await library.acceptedCloudTextValues()
    }

    private nonisolated static func enrollmentEvidence(
        snapshot: CloudTextStorageSnapshot,
        hasPendingChanges: Bool
    ) -> CloudTextEnrollmentEvidence {
        let recordRecoveryInputs = snapshot.records.compactMap { record in
            record.recoveryData.flatMap(Self.recoveryInput)
        }
        let retryableEventKeys = Set(snapshot.recoveryEvents.compactMap { event in
            Self.isRetryable(Self.recoveryInput(event.payload)) ? event.key : nil
        })
        let hasTerminalRecordFailure = snapshot.records.contains { record in
            guard let data = record.recoveryData else { return false }
            let input = Self.recoveryInput(data)
            return !Self.isRetryable(input) && !Self.isModeRetryDeletion(input)
        }
        let hasTerminalEvent = snapshot.recoveryEvents.contains { event in
            !Self.isRetryable(Self.recoveryInput(event.payload))
        }
        return CloudTextEnrollmentEvidence(
            phase: snapshot.namespaceState.phase,
            hasPendingChanges: hasPendingChanges,
            hasRetryableRecordFailures: recordRecoveryInputs.contains(where: Self.isRetryable),
            retryableEventKeys: retryableEventKeys,
            needsAttention: snapshot.namespaceState.phase == .blocked
                || hasTerminalRecordFailure
                || hasTerminalEvent
        )
    }

    package func currentModeSeedSettlement(
        candidates: [SyncModeSeedSettlementCandidate],
        namespace expectedNamespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSeedSettlementProof {
        let actualNamespace = ICloudSyncNamespaceBinding(
            scope: namespace.cloudScope,
            accountLineage: namespace.accountLineage,
            generation: namespace.generation,
            zones: Set(namespace.zones.map {
                ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
            })
        )
        guard actualNamespace == expectedNamespace else {
            throw SyncModePersistenceError.namespaceMismatch
        }
        let snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        let liveByID = Dictionary(uniqueKeysWithValues: snapshot.snips.map { ($0.id, $0) })
        let recordsBySnipID = Dictionary(grouping: snapshot.records, by: \.snipID)
        var values: [UUID: SyncModeSeedSettlementValue] = [:]
        for candidate in candidates {
            let records = recordsBySnipID[candidate.snipID, default: []]
            if let live = liveByID[candidate.snipID] {
                guard records.count == 1, let record = records.first,
                    record.acceptedText == live.content,
                    record.shadowData != nil, record.systemFields != nil,
                    record.recoveryData == nil,
                    candidate.acceptedRecordIdentity == nil
                        || candidate.acceptedRecordIdentity == record.identity,
                    !Self.hasRetryableState(for: record.identity, in: snapshot)
                else { continue }
                values[candidate.snipID] = .saved(
                    recordIdentity: record.identity,
                    acceptedText: live.content
                )
            } else if let identity = candidate.acceptedRecordIdentity,
                records.isEmpty,
                !snapshot.records.contains(where: { $0.identity == identity }),
                !snapshot.namespaceState.approvedSnipIDs.contains(candidate.snipID),
                !Self.hasRetryableState(for: identity, in: snapshot)
            {
                values[candidate.snipID] = .deleted(recordIdentity: identity)
            }
        }
        return SyncModeSeedSettlementProof(namespace: actualNamespace, values: values)
    }

    package func modeSendAttempt(
        for outbound: CloudOutboundBatch,
        namespace expectedNamespace: ICloudSyncNamespaceBinding
    ) async throws -> SyncModeSendAttempt {
        let actualNamespace = ICloudSyncNamespaceBinding(
            scope: namespace.cloudScope,
            accountLineage: namespace.accountLineage,
            generation: namespace.generation,
            zones: Set(namespace.zones.map {
                ICloudSyncZoneBinding(name: $0.name, ownerName: $0.ownerName)
            })
        )
        guard actualNamespace == expectedNamespace else {
            throw SyncModePersistenceError.namespaceMismatch
        }
        let snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        let recordsByIdentity = Dictionary(grouping: snapshot.records, by: \.identity)
        var operations: [SyncModeSendOperation] = []
        for outboundOperation in outbound.operations {
            let identity = Self.storageIdentity(outboundOperation.id)
            guard actualNamespace.zones.contains(
                ICloudSyncZoneBinding(name: identity.zoneName, ownerName: identity.ownerName)
            ), let records = recordsByIdentity[identity], records.count == 1,
                let record = records.first
            else { throw SyncModePersistenceError.namespaceMismatch }
            let kind: SyncModeSendOperationKind
            switch outboundOperation {
            case .save:
                kind = .save
            case .delete:
                kind = .delete
            }
            operations.append(
                SyncModeSendOperation(
                    snipID: record.snipID,
                    recordIdentity: identity,
                    kind: kind
                )
            )
        }
        guard Set(operations.map(\.recordIdentity)).count == operations.count else {
            throw SyncModePersistenceError.invalidManifest
        }
        return SyncModeSendAttempt(namespace: actualNamespace, operations: operations)
    }

    package func prepareModeRetry(snipIDs: Set<UUID>) async throws {
        guard !snipIDs.isEmpty else { return }
        let snapshot = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        try await library.prepareCloudTextModeRetry(
            namespaceKey: namespaceKey,
            supersededSnipIDs: snipIDs,
            liveSnipIDs: Set(snapshot.snips.map(\.id)),
            deletionRecoveryData: try Self.encode(.modeRetryDeletion)
        )
    }

    package func clearRetryableEvents(_ keys: Set<String>) async throws {
        try await library.removeCloudTextRecoveryEvents(namespaceKey: namespaceKey, keys: keys)
    }

    package func clear() async throws {
        try await library.clearCloudTextSyncState(namespaceKey: namespaceKey)
    }

    private func applyFetched(_ batch: CloudFetchedBatch) async throws {
        let current = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        var valuesByIdentity: [CloudTextStorageIdentity: CloudTextFetchedValue] = [:]
        var recoveryDataByIdentity: [CloudTextStorageIdentity: Data] = [:]
        var valueOrder: [CloudTextStorageIdentity] = []
        var deletedIdentities: [CloudTextStorageIdentity] = []
        var deletionRecoveryData: [CloudTextStorageIdentity: Data] = [:]
        var recoveryEvents: [CloudRecoveryEventStorage] = []
        var hadInvalidItem = false
        let currentByIdentity = Dictionary(
            uniqueKeysWithValues: current.records.map { ($0.identity, $0) }
        )
        var identityBySnipID = Dictionary(
            uniqueKeysWithValues: current.records.map { ($0.snipID, $0.identity) }
        )
        for item in batch.items {
            switch item {
            case .record(let snapshot):
                guard snapshot.id.zone == textZone else {
                    hadInvalidItem = true
                    recoveryEvents.append(
                        try Self.recoveryEvent(
                            .fetched(.failed(snapshot.id, .invalidRecord)),
                            batchID: batch.id
                        )
                    )
                    continue
                }
                do {
                    let value = try Self.storageValue(snapshot)
                    if let currentRecord = currentByIdentity[value.identity],
                       currentRecord.snipID != value.snipID
                    {
                        hadInvalidItem = true
                        recoveryEvents.append(
                            try Self.recoveryEvent(
                                .fetched(.failed(snapshot.id, .invalidRecord)),
                                batchID: batch.id
                            )
                        )
                    } else if let known = identityBySnipID[value.snipID],
                              known != value.identity
                    {
                        hadInvalidItem = true
                        recoveryEvents.append(
                            try Self.recoveryEvent(
                                .fetched(.failed(snapshot.id, .invalidRecord)),
                                batchID: batch.id
                            )
                        )
                    } else {
                        if valuesByIdentity[value.identity] == nil { valueOrder.append(value.identity) }
                        valuesByIdentity[value.identity] = value
                        recoveryDataByIdentity[value.identity] = try Self.encode(.fetched(item))
                        identityBySnipID[value.snipID] = value.identity
                    }
                } catch {
                    hadInvalidItem = true
                    recoveryEvents.append(
                        try Self.recoveryEvent(
                            .fetched(.failed(snapshot.id, .invalidRecord)),
                            batchID: batch.id
                        )
                    )
                }
            case .deleted(let id):
                guard id.zone == textZone else {
                    hadInvalidItem = true
                    recoveryEvents.append(
                        try Self.recoveryEvent(
                            .fetched(.failed(id, .invalidRecord)),
                            batchID: batch.id
                        )
                    )
                    continue
                }
                let identity = Self.storageIdentity(id)
                deletedIdentities.append(identity)
                deletionRecoveryData[identity] = try Self.encode(.fetched(item))
            case .failed:
                recoveryEvents.append(try Self.recoveryEvent(.fetched(item), batchID: batch.id))
            }
        }
        recoveryEvents.append(
            contentsOf: try batch.databaseEvents.map {
                try Self.recoveryEvent(.database($0), batchID: batch.id)
            }
        )
        recoveryEvents.append(
            contentsOf: try batch.zoneEvents.map {
                try Self.recoveryEvent(.zone($0), batchID: batch.id)
            }
        )
        let hasDestructiveReset = batch.databaseEvents.contains(where: Self.isDestructiveReset)
        let hasMissingZone = Self.hasMissingZone(batch, textZone: textZone)
        let fetchedValues = valueOrder.compactMap { valuesByIdentity[$0] }
        let namespaceState = Self.nextNamespaceStateAfterFetch(
            current: current,
            fetchedValues: fetchedValues,
            hasMissingZone: hasMissingZone,
            hasDestructiveReset: hasDestructiveReset,
            hasIncompleteFetch: hadInvalidItem || Self.hasIncompleteFetch(batch)
        )
        let mutations = hasDestructiveReset
            ? []
            : try Self.fetchedMutations(
                values: fetchedValues,
                deletedIdentities: deletedIdentities,
                recoveryDataByIdentity: recoveryDataByIdentity,
                deletionRecoveryData: deletionRecoveryData,
                current: current
            )
        let engineState = try batch.engineState.map { try JSONEncoder().encode($0) }
        try await library.applyCloudTextFetched(
            namespaceKey: namespaceKey,
            mutations: mutations,
            recoveryEvents: recoveryEvents,
            engineState: engineState,
            namespaceState: namespaceState,
            stagedBatchID: batch.id
        )
    }

    private func applySent(_ batch: CloudSentBatch) async throws {
        let current = try await library.cloudTextSyncSnapshot(namespaceKey: namespaceKey)
        var mutations: [CloudTextRecordMutation] = []
        var recoveryEvents: [CloudRecoveryEventStorage] = []
        for item in batch.items {
            switch item {
            case .saved(let snapshot):
                do {
                    mutations.append(.accept(try Self.storageValue(snapshot)))
                } catch {
                    mutations.append(
                        .recover(
                            Self.storageIdentity(snapshot.id),
                            recoveryData: try Self.encode(
                                .sent(.failed(snapshot.id, .invalidRecord))
                            )
                        )
                    )
                    recoveryEvents.append(
                        try Self.recoveryEvent(
                            .sent(.failed(snapshot.id, .invalidRecord)),
                            batchID: batch.id
                        )
                    )
                }
            case .deleted(let id):
                mutations.append(.remove(Self.storageIdentity(id)))
            case .conflict(let id, let server):
                do {
                    mutations.append(
                        .acceptAndRecover(
                            try Self.storageValue(server),
                            recoveryData: try Self.encode(.sent(item))
                        )
                    )
                } catch {
                    mutations.append(
                        .recover(
                            Self.storageIdentity(id),
                            recoveryData: try Self.encode(
                                .sent(.failed(id, .invalidRecord))
                            )
                        )
                    )
                }
            case .unknownItem(let id), .failed(let id, _):
                mutations.append(
                    .recover(
                        Self.storageIdentity(id),
                        recoveryData: try Self.encode(.sent(item))
                    )
                )
            }
        }
        recoveryEvents.append(
            contentsOf: try batch.databaseEvents.map {
                try Self.recoveryEvent(.database($0), batchID: batch.id)
            }
        )
        recoveryEvents.append(
            contentsOf: try batch.zoneEvents.map {
                try Self.recoveryEvent(.zone($0), batchID: batch.id)
            }
        )
        let namespaceState = Self.nextNamespaceStateAfterSend(
            current: current,
            batch: batch,
            textZone: textZone
        )
        let engineState = try batch.engineState.map { try JSONEncoder().encode($0) }
        try await library.applyCloudTextSent(
            namespaceKey: namespaceKey,
            mutations: mutations,
            recoveryEvents: recoveryEvents,
            engineState: engineState,
            namespaceState: namespaceState,
            stagedBatchID: batch.id
        )
    }

}
