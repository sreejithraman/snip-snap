import CloudKit
import CryptoKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

public enum SnipSnapCloudNotifications {
    public static let accountChanged = Notification.Name.CKAccountChanged
}

/// The Apple Account facts needed by sync policy. Sync generation stays in the namespace seam.
package enum ICloudAccountState: Equatable, Sendable {
    case available(accountLineage: String)
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
}

package protocol ICloudAccountStateSource: Sendable {
    func currentAccountState() async -> ICloudAccountState
}

package struct FixedICloudAccountStateSource: ICloudAccountStateSource {
    private let state: ICloudAccountState

    package init(state: ICloudAccountState) {
        self.state = state
    }

    package func currentAccountState() async -> ICloudAccountState {
        state
    }
}

/// Narrow production-capable action seam for platform notice models.
public actor AppleAccountCacheCoordinatorHandler: OptionalCloudSyncHandling {
    public typealias SyncAction = @MainActor @Sendable () async -> Void
    public typealias RetryOutcomeAction = @MainActor @Sendable () async throws -> SyncedContentActionOutcome
    public typealias ScheduleAction = @MainActor @Sendable () async -> Void
    package typealias AttachmentCoordinatorFactory = @Sendable (
        SwiftDataSnipLibrary,
        CloudSyncNamespace,
        CloudCollectionDescriptor
    ) async -> any CloudAttachmentTransferring
    package typealias SyncCoordinatorFactory = @Sendable (
        SwiftDataSyncModePersistence,
        CloudSyncNamespace,
        CloudCollectionDescriptor
    ) async -> ICloudSyncModeCoordinator

    private struct Configuration: Sendable {
        let persistence: @Sendable () async throws -> SwiftDataSyncModePersistence?
        let controlTransport: any CloudCollectionControlTransport
        let accountStateSource: any ICloudAccountStateSource
        let makeSyncCoordinator: SyncCoordinatorFactory
        let makeAttachmentCoordinator: AttachmentCoordinatorFactory
        let ownerName: String
        let reservedZones: Set<CloudZoneID>
    }

    private enum CoordinatorSource {
        /// A caller supplied the sync coordinator; attachment actions are unsupported.
        case injected(ICloudSyncModeCoordinator)
        /// Coordinators are built for the active store's namespace and cached in `bindings`.
        case resolved(Configuration)
    }

    private struct SyncCoordinatorBinding {
        let descriptor: CloudCollectionDescriptor
        let coordinator: ICloudSyncModeCoordinator
    }

    private struct AttachmentCoordinatorBinding {
        let storeID: UUID
        let descriptor: CloudCollectionDescriptor
        let coordinator: any CloudAttachmentTransferring
    }

    /// Coordinators built for the active store's namespace. The sync and attachment lifetimes
    /// overlap, so each has its own slot.
    private struct CoordinatorBindings {
        private var sync: SyncCoordinatorBinding?
        private var attachment: AttachmentCoordinatorBinding?

        func syncCoordinator(for descriptor: CloudCollectionDescriptor) -> ICloudSyncModeCoordinator? {
            guard let sync, sync.descriptor == descriptor else { return nil }
            return sync.coordinator
        }

        func attachmentCoordinator(
            storeID: UUID,
            descriptor: CloudCollectionDescriptor
        ) -> (any CloudAttachmentTransferring)? {
            guard let attachment, attachment.storeID == storeID,
                  attachment.descriptor == descriptor
            else { return nil }
            return attachment.coordinator
        }

        mutating func bind(_ sync: SyncCoordinatorBinding) {
            self.sync = sync
        }

        mutating func bind(_ attachment: AttachmentCoordinatorBinding) {
            self.attachment = attachment
        }

        /// Drops the attachment coordinator before a sync coordinator for another collection is built.
        mutating func releaseAttachment() {
            attachment = nil
        }

        /// Account isolation ended; the next action resolves the new active store.
        mutating func removeAll() {
            self = Self()
        }
    }

    private let coordinatorSource: CoordinatorSource
    private var bindings = CoordinatorBindings()
    private let operationGate: AsyncOperationGate
    private let syncAction: SyncAction?
    private let retryAction: SyncAction?
    private let retryOutcomeAction: RetryOutcomeAction?
    private let scheduleAction: ScheduleAction?
    private let currentStatusAction: (@Sendable (SnipLibraryReadSource) async throws -> SyncedContentCurrentSyncObservation)?

    package init(
        coordinator: ICloudSyncModeCoordinator,
        syncWhenPossible: SyncAction? = nil,
        retrySyncWhenPossible: SyncAction? = nil,
        retrySyncWithOutcome: RetryOutcomeAction? = nil,
        scheduleSyncAfterLocalChange: ScheduleAction? = nil,
        checkedCurrentSyncStatus: (@Sendable (SnipLibraryReadSource) async throws -> SyncedContentCurrentSyncObservation)? = nil
    ) {
        coordinatorSource = .injected(coordinator)
        operationGate = AsyncOperationGate()
        syncAction = syncWhenPossible
        retryAction = retrySyncWhenPossible
        retryOutcomeAction = retrySyncWithOutcome
        scheduleAction = scheduleSyncAfterLocalChange
        currentStatusAction = checkedCurrentSyncStatus
    }

    package init(
        persistence: @escaping @Sendable () async throws -> SwiftDataSyncModePersistence?,
        controlTransport: any CloudCollectionControlTransport,
        accountStateSource: any ICloudAccountStateSource,
        makeSyncCoordinator: @escaping SyncCoordinatorFactory,
        makeAttachmentCoordinator: @escaping AttachmentCoordinatorFactory,
        ownerName: String = CKCurrentUserDefaultName,
        reservedZones: Set<CloudZoneID> = [CloudCollectionAssembly.productionControlID.zone],
        operationGate: AsyncOperationGate = AsyncOperationGate(),
        syncWhenPossible: SyncAction? = nil,
        retrySyncWhenPossible: SyncAction? = nil,
        retrySyncWithOutcome: RetryOutcomeAction? = nil,
        scheduleSyncAfterLocalChange: ScheduleAction? = nil,
        checkedCurrentSyncStatus: (@Sendable (SnipLibraryReadSource) async throws -> SyncedContentCurrentSyncObservation)? = nil
    ) {
        coordinatorSource = .resolved(Configuration(
            persistence: persistence,
            controlTransport: controlTransport,
            accountStateSource: accountStateSource,
            makeSyncCoordinator: makeSyncCoordinator,
            makeAttachmentCoordinator: makeAttachmentCoordinator,
            ownerName: ownerName,
            reservedZones: reservedZones
        ))
        self.operationGate = operationGate
        syncAction = syncWhenPossible
        retryAction = retrySyncWhenPossible
        retryOutcomeAction = retrySyncWithOutcome
        scheduleAction = scheduleSyncAfterLocalChange
        currentStatusAction = checkedCurrentSyncStatus
    }

    public func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
        try await operationGate.withLease { try await self.refreshNotice() }
    }

    private func refreshNotice() async throws -> AppleAccountNotice? {
        if case .resolved(let configuration) = coordinatorSource {
            guard let persistence = try await configuration.persistence() else { return nil }
            let local = try await persistence.snapshot()
            guard local.accountIsolation?.namespace != nil || local.transition?.namespace != nil
                || local.activeStore.namespace != nil else { return nil }
            let account = await configuration.accountStateSource.currentAccountState()
            let storage = try await persistence.snapshot()
            guard let binding = storage.accountIsolation?.namespace
                ?? storage.transition?.namespace ?? storage.activeStore.namespace
            else { return nil }
            let notice: AppleAccountNotice? = switch account {
            case .noAccount: .signedOut
            case .available(let lineage) where lineage != binding.accountLineage: .accountChanged
            case .restricted, .temporarilyUnavailable, .couldNotDetermine: .paused
            case .available: nil
            }
            if let notice {
                if storage.activeStore.kind == .iCloudSync, notice != .paused {
                    _ = try await persistence.isolateActiveCloudStore(
                        reason: notice == .signedOut ? .signedOut : .accountChanged,
                        expectedStoreID: storage.activeStore.id)
                }
                return notice
            }
        }
        let status = try await requireCoordinator().refreshAccountState()
        return switch status.attentionReason {
        case .accountSignedOut: .signedOut
        case .accountChanged, .namespaceChanged: .accountChanged
        case .accountTemporarilyUnavailable, .accountStatusUnknown, .accountRestricted: .paused
        case nil, .enrollmentBlocked, .firstSyncFailed, .transferConflict, .storageFailure,
             .storeReadFailed, .terminalFetchFailure, .transitionFailure:
            nil
        }
    }

    public func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {
        try await operationGate.withLease { try await self.resolveCache(choice) }
    }

    private func resolveCache(_ choice: AppleAccountCacheChoice) async throws {
        switch coordinatorSource {
        case .injected(let coordinator):
            _ = try await coordinator.resolveAccountIsolation(choice == .keepLocalCopy ? .keepLocalCopy : .remove)
        case .resolved(let configuration):
            guard let persistence = try await configuration.persistence() else {
                throw SnipLibraryError.transferUnsupported
            }
            try await persistence.resolveAccountIsolation(choice == .keepLocalCopy ? .keepLocalCopy : .remove)
            bindings.removeAll()
        }
    }

    public func syncWhenPossible() async {
        if let syncAction {
            await syncAction()
            return
        }
        do {
            try await operationGate.withLease {
                let coordinator = try await self.requireCoordinator()
                let status = try await coordinator.status()
                guard status.state != .off, status.attentionReason == nil else { return }
                _ = try await coordinator.syncActive()
            }
        } catch {
            // Launch and foreground work is best effort. Durable work remains queued.
        }
    }

    public func retrySyncWhenPossible() async {
        if let retryAction {
            await retryAction()
            return
        }
        await syncWhenPossible()
    }

    public func retrySyncWithOutcome() async throws -> SyncedContentActionOutcome {
        guard let retryOutcomeAction else { return .notRun(.unsupportedLegacyHandler) }
        return try await retryOutcomeAction()
    }

    public func scheduleSyncAfterLocalChange() async {
        if let scheduleAction {
            await scheduleAction()
            return
        }
        await syncWhenPossible()
    }

    public func isCloudSyncActive() async throws -> Bool {
        try await operationGate.withLease { try await self.cloudSyncIsActive() }
    }

    private func cloudSyncIsActive() async throws -> Bool {
        guard case .resolved(let configuration) = coordinatorSource else { return true }
        guard let persistence = try await configuration.persistence() else { return false }
        return try await persistence.snapshot().activeStore.kind == .iCloudSync
    }

    public func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] {
        try await operationGate.withLease {
            let values = try await self.withAttachmentCoordinator { coordinator, _ in try await coordinator.transferStates() }
            return values.mapValues { value in
                switch value {
                case .waitingForUpload, .waitingForMetadata, .waitingForDeletion: .waiting
                case .available: .available
                case .failed: .failed
                }
            }
        }
    }

    public func checkedAttachmentStates() async throws -> SyncedAttachmentReadObservation {
        try await operationGate.withLease {
            guard case .resolved(let configuration) = self.coordinatorSource,
                  let persistence = try await configuration.persistence()
            else { throw SnipLibraryError.transferUnsupported }
            let storage = try await persistence.snapshot()
            if storage.activeStore.kind == .localOnly {
                let library = try await persistence.activeLibrary()
                guard let observing = library as? any SnipLibraryReadObserving else {
                    throw SnipLibraryError.transferUnsupported
                }
                let read = try await observing.checkedRead(sortedBy: .manual)
                guard let source = read.source, source.storageMode == .localOnly else {
                    throw SyncModePersistenceError.namespaceMismatch
                }
                return SyncedAttachmentReadObservation(source: source, states: [:], publication: read.publication,
                    predecessor: read.publication, libraryBinding: read.target?.library)
            }
            return try await self.withCheckedAttachmentCoordinator()
        }
    }

    public func checkedCurrentSyncStatus(for source: SnipLibraryReadSource) async throws -> SyncedContentCurrentSyncObservation {
        guard let currentStatusAction else { throw SnipLibraryError.transferUnsupported }
        return try await currentStatusAction(source)
    }

    public func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        try await operationGate.withLease {
            try await self.withAttachmentCoordinator { coordinator, _ in try await coordinator.prepare(attachmentID: id, for: use) }
        }
    }

    public func clearDownloadedFiles() async throws {
        try await operationGate.withLease {
            try await self.withAttachmentCoordinator { coordinator, _ in try await coordinator.clearDownloads() }
        }
    }

    public func downloadedAttachmentCache(in scope: SnipRecoveryScope) async throws -> SyncedAttachmentCacheSnapshot {
        try await operationGate.withLease {
            try await self.withAttachmentCoordinator { _, source in
                try await Self.cacheSnapshot(source: source, scope: scope)
            }
        }
    }

    public func clearDownloadedFiles(ifRevision revision: String, in scope: SnipRecoveryScope) async throws -> Bool {
        try await operationGate.withLease {
            try await self.withAttachmentCoordinator { coordinator, source in
                let current = try await Self.cacheSnapshot(source: source, scope: scope)
                guard !revision.isEmpty, current.revision == revision else { return false }
                try await coordinator.clearDownloads()
                return true
            }
        }
    }

    private struct AttachmentSource: Sendable {
        let library: SwiftDataSnipLibrary
        let storeID: UUID
        let namespaceKey: CloudSyncNamespaceKey
    }

    private static func cacheSnapshot(
        source: AttachmentSource?, scope: SnipRecoveryScope
    ) async throws -> SyncedAttachmentCacheSnapshot {
        guard let source, source.namespaceKey.rawValue == scope.rawValue else {
            throw SyncModePersistenceError.namespaceMismatch
        }
        let snapshot = try await source.library.cloudAttachmentStorageSnapshot(namespaceKey: source.namespaceKey)
        var values = ["store": source.storeID.uuidString, "namespace": source.namespaceKey.rawValue]
        let states = Dictionary(uniqueKeysWithValues: snapshot.publications.map { publication in
            let id = publication.metadata.attachmentID
            values["publication.\(id)"] = String(publication.revision)
            let state: SyncedAttachmentTransferState = switch publication.transferState {
            case .waitingForUpload, .waitingForMetadata, .waitingForDeletion: .waiting
            case .available: .available
            case .failed: .failed
            }
            return (id, state)
        })
        for entry in snapshot.cacheEntries {
            let prefix = "cache.\(entry.attachmentID)"
            values[prefix + ".payload"] = entry.payloadIdentity.key
            values[prefix + ".bytes"] = String(entry.byteCount)
            values[prefix + ".accessed"] = String(entry.lastAccessedAt.timeIntervalSinceReferenceDate)
            values[prefix + ".file"] = entry.fileURL.lastPathComponent
            values[prefix + ".present"] = String(FileManager.default.fileExists(atPath: entry.fileURL.path))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let revision = SHA256.hash(data: try encoder.encode(values))
            .map { String(format: "%02x", $0) }.joined()
        return SyncedAttachmentCacheSnapshot(states: states, revision: revision)
    }

    private func requireCoordinator() async throws -> ICloudSyncModeCoordinator {
        let configuration: Configuration
        switch coordinatorSource {
        case .injected(let coordinator): return coordinator
        case .resolved(let value): configuration = value
        }
        guard let persistence = try await configuration.persistence()
        else { throw SnipLibraryError.transferUnsupported }
        let storage = try await persistence.snapshot()
        guard let binding = storage.accountIsolation?.namespace
            ?? storage.transition?.namespace
            ?? storage.activeStore.namespace
        else { throw SnipLibraryError.transferUnsupported }
        let descriptor = try await resolveDescriptor(
            matching: binding,
            configuration: configuration
        )
        try await requireCurrentSource(storage, persistence: persistence)
        let namespace = descriptor.namespace(
            cloudScope: binding.scope,
            accountLineage: binding.accountLineage
        )
        if let coordinator = bindings.syncCoordinator(for: descriptor) {
            return coordinator
        }
        bindings.releaseAttachment()
        let created = await configuration.makeSyncCoordinator(persistence, namespace, descriptor)
        try await requireCurrentSource(storage, persistence: persistence)
        bindings.bind(SyncCoordinatorBinding(descriptor: descriptor, coordinator: created))
        return created
    }

    private struct AttachmentLease: Sendable {
        let persistence: SwiftDataSyncModePersistence
        let storage: SyncModeStorageSnapshot
        let binding: ICloudSyncNamespaceBinding
        let descriptor: CloudCollectionDescriptor
        let configuration: Configuration
        let lease: SyncModeActiveMutationLease
    }

    private func selectAttachmentLease() async throws -> AttachmentLease {
        guard case .resolved(let configuration) = coordinatorSource,
              let persistence = try await configuration.persistence()
        else { throw SnipLibraryError.transferUnsupported }
        let storage = try await persistence.snapshot()
        guard storage.activeStore.kind == .iCloudSync,
              let binding = storage.activeStore.namespace
        else { throw SnipLibraryError.transferUnsupported }
        let descriptor = try await resolveDescriptor(matching: binding, configuration: configuration)
        try await requireCurrentSource(storage, persistence: persistence)
        let lease = try await persistence.activeCloudMutationLease(storeID: storage.activeStore.id)
        return AttachmentLease(persistence: persistence, storage: storage, binding: binding,
            descriptor: descriptor, configuration: configuration, lease: lease)
    }

    private func boundAttachment(
        _ selected: AttachmentLease
    ) async throws -> (coordinator: any CloudAttachmentTransferring, source: AttachmentSource) {
        let persistence = selected.persistence
        let storage = selected.storage
        try await requireCurrentSource(storage, persistence: persistence)
        let attachment = try await attachmentCoordinator(persistence: persistence,
            storeID: storage.activeStore.id, binding: selected.binding,
            descriptor: selected.descriptor, configuration: selected.configuration)
        try await requireCurrentSource(storage, persistence: persistence)
        let source = AttachmentSource(library: try await persistence.libraryForTransition(storeID: storage.activeStore.id),
            storeID: storage.activeStore.id, namespaceKey: selected.binding.namespaceKey)
        return (attachment, source)
    }

    private func withAttachmentCoordinator<Value: Sendable>(
        _ operation: @escaping @Sendable (any CloudAttachmentTransferring, AttachmentSource?) async throws -> Value
    ) async throws -> Value {
        let selected = try await selectAttachmentLease()
        return try await selected.lease.run {
            let bound = try await self.boundAttachment(selected)
            return try await operation(bound.coordinator, bound.source)
        }
    }

    private func withCheckedAttachmentCoordinator() async throws -> SyncedAttachmentReadObservation {
        let selected = try await selectAttachmentLease()
        return try await selected.lease.runAttachmentRead { reservation in
            try await selected.persistence.beginAttachmentRead(reservation)
            let bound = try await self.boundAttachment(selected)
            let values = try await bound.coordinator.transferStates()
            let states = values.mapValues { value -> SyncedAttachmentTransferState in
                switch value {
                case .waitingForUpload, .waitingForMetadata, .waitingForDeletion: SyncedAttachmentTransferState.waiting
                case .available: .available
                case .failed: .failed
                }
            }
            return try await selected.persistence.captureAttachmentRead(states,
                source: SnipLibraryReadSource(storeID: bound.source.storeID, storageMode: .iCloudSync,
                    namespaceKey: bound.source.namespaceKey.rawValue), reservation: reservation)
        }
    }

    private func attachmentCoordinator(
        persistence: SwiftDataSyncModePersistence,
        storeID: UUID,
        binding: ICloudSyncNamespaceBinding,
        descriptor: CloudCollectionDescriptor,
        configuration: Configuration
    ) async throws -> any CloudAttachmentTransferring {
        if let coordinator = bindings.attachmentCoordinator(storeID: storeID, descriptor: descriptor) {
            return coordinator
        }
        let namespace = descriptor.namespace(cloudScope: binding.scope, accountLineage: binding.accountLineage)
        let library = try await persistence.libraryForTransition(storeID: storeID)
        let created = await configuration.makeAttachmentCoordinator(library, namespace, descriptor)
        bindings.bind(AttachmentCoordinatorBinding(storeID: storeID, descriptor: descriptor, coordinator: created))
        return created
    }

    private func requireCurrentSource(
        _ storage: SyncModeStorageSnapshot,
        persistence: SwiftDataSyncModePersistence
    ) async throws {
        let current = try await persistence.snapshot()
        guard current.activeStore.kind == storage.activeStore.kind,
              current.activeStore.id == storage.activeStore.id,
              current.activeStore.namespace == storage.activeStore.namespace,
              current.accountIsolation == storage.accountIsolation,
              current.transition == storage.transition
        else { throw SyncModePersistenceError.namespaceMismatch }
    }

    private func resolveDescriptor(
        matching binding: ICloudSyncNamespaceBinding,
        configuration: Configuration
    ) async throws -> CloudCollectionDescriptor {
        guard let current = try await configuration.controlTransport.fetchControl() else {
            throw SnipLibraryError.transferUnsupported
        }
        return try Self.validatedDescriptor(
            current,
            matching: binding,
            ownerName: configuration.ownerName,
            reservedZones: configuration.reservedZones
        )
    }

    package static func validatedDescriptor(
        _ control: CloudCollectionControlRecord,
        matching binding: ICloudSyncNamespaceBinding,
        ownerName: String,
        reservedZones: Set<CloudZoneID>
    ) throws -> CloudCollectionDescriptor {
        try control.descriptor.validate(ownerName: ownerName, reservedZones: reservedZones)
        let namespace = control.descriptor.namespace(
            cloudScope: binding.scope,
            accountLineage: binding.accountLineage
        )
        guard namespace.generation == binding.generation,
              namespace.zones == Set(binding.zones.map {
                  CloudZoneID(name: $0.name, ownerName: $0.ownerName)
              })
        else { throw SnipLibraryError.transferUnsupported }
        return control.descriptor
    }
}

package actor CloudKitICloudAccountStateSource: ICloudAccountStateSource {
    private let accountStatus: @Sendable () async throws -> CKAccountStatus
    private let userRecordID: @Sendable () async throws -> CKRecord.ID
    private let bound: CloudKitCallBound

    package init(container: CKContainer, bound: CloudKitCallBound = .standard) {
        self.init(
            accountStatus: {
                try await container.configuredWith(configuration: bound.configuration(.small)) {
                    try await $0.accountStatus()
                }
            },
            userRecordID: {
                try await container.configuredWith(configuration: bound.configuration(.small)) {
                    try await $0.userRecordID()
                }
            },
            bound: bound
        )
    }

    init(
        accountStatus: @escaping @Sendable () async throws -> CKAccountStatus,
        userRecordID: @escaping @Sendable () async throws -> CKRecord.ID,
        bound: CloudKitCallBound = .standard
    ) {
        self.accountStatus = accountStatus
        self.userRecordID = userRecordID
        self.bound = bound
    }

    package func currentAccountState() async -> ICloudAccountState {
        do {
            switch try await bound.read(.small, accountStatus) {
            case .available:
                let recordID = try await bound.read(.small, userRecordID)
                return .available(accountLineage: recordID.recordName)
            case .noAccount:
                return .noAccount
            case .restricted:
                return .restricted
            case .temporarilyUnavailable:
                return .temporarilyUnavailable
            case .couldNotDetermine:
                return .couldNotDetermine
            @unknown default:
                return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }
}
