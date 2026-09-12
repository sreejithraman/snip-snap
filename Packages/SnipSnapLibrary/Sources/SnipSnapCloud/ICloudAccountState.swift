import CloudKit
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

    private var coordinator: ICloudSyncModeCoordinator?
    private var attachmentCoordinator: (any CloudAttachmentTransferring)?
    private var attachmentStoreID: UUID?
    private var coordinatorDescriptor: CloudCollectionDescriptor?
    private var attachmentDescriptor: CloudCollectionDescriptor?
    private let configuration: Configuration?
    private let operationGate: AsyncOperationGate
    private let syncAction: SyncAction?
    private let retryAction: SyncAction?
    private let scheduleAction: ScheduleAction?

    package init(
        coordinator: ICloudSyncModeCoordinator,
        attachmentCoordinator: (any CloudAttachmentTransferring)? = nil,
        activeDescriptor: CloudCollectionDescriptor? = nil,
        syncWhenPossible: SyncAction? = nil,
        retrySyncWhenPossible: SyncAction? = nil,
        scheduleSyncAfterLocalChange: ScheduleAction? = nil
    ) {
        self.coordinator = coordinator
        self.attachmentCoordinator = attachmentCoordinator
        attachmentStoreID = nil
        coordinatorDescriptor = activeDescriptor
        attachmentDescriptor = activeDescriptor
        configuration = nil
        operationGate = AsyncOperationGate()
        syncAction = syncWhenPossible
        retryAction = retrySyncWhenPossible
        scheduleAction = scheduleSyncAfterLocalChange
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
        scheduleSyncAfterLocalChange: ScheduleAction? = nil
    ) {
        coordinator = nil
        attachmentCoordinator = nil
        attachmentStoreID = nil
        coordinatorDescriptor = nil
        attachmentDescriptor = nil
        configuration = Configuration(
            persistence: persistence,
            controlTransport: controlTransport,
            accountStateSource: accountStateSource,
            makeSyncCoordinator: makeSyncCoordinator,
            makeAttachmentCoordinator: makeAttachmentCoordinator,
            ownerName: ownerName,
            reservedZones: reservedZones
        )
        self.operationGate = operationGate
        syncAction = syncWhenPossible
        retryAction = retrySyncWhenPossible
        scheduleAction = scheduleSyncAfterLocalChange
    }

    public func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
        try await operationGate.withLease { try await self.refreshNotice() }
    }

    private func refreshNotice() async throws -> AppleAccountNotice? {
        if let configuration {
            guard let persistence = try await configuration.persistence() else { return nil }
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
        if let configuration {
            guard let persistence = try await configuration.persistence() else {
                throw SnipLibraryError.transferUnsupported
            }
            try await persistence.resolveAccountIsolation(choice == .keepLocalCopy ? .keepLocalCopy : .remove)
        } else {
            let coordinator = try await requireCoordinator()
            _ = try await coordinator.resolveAccountIsolation(choice == .keepLocalCopy ? .keepLocalCopy : .remove)
        }
        attachmentCoordinator = nil
        attachmentStoreID = nil
        coordinatorDescriptor = nil
        attachmentDescriptor = nil
    }

    public func syncWhenPossible() async {
        if let syncAction {
            await syncAction()
            return
        }
        do {
            let coordinator = try await requireCoordinator()
            let status = try await coordinator.status()
            guard status.state != .off, status.attentionReason == nil else { return }
            _ = try await coordinator.syncActive()
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
        guard let configuration else { return coordinator != nil }
        guard let persistence = try await configuration.persistence() else { return false }
        return try await persistence.snapshot().activeStore.kind == .iCloudSync
    }

    public func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] {
        try await operationGate.withLease {
            let values = try await self.withAttachmentCoordinator { try await $0.transferStates() }
            return values.mapValues { value in
                switch value {
                case .waitingForUpload, .waitingForMetadata, .waitingForDeletion: .waiting
                case .available: .available
                case .failed: .failed
                }
            }
        }
    }

    public func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        try await operationGate.withLease {
            try await self.withAttachmentCoordinator { try await $0.prepare(attachmentID: id, for: use) }
        }
    }

    public func clearDownloadedFiles() async throws {
        try await operationGate.withLease {
            try await self.withAttachmentCoordinator { try await $0.clearDownloads() }
        }
    }

    private func requireCoordinator() async throws -> ICloudSyncModeCoordinator {
        if configuration == nil {
            guard let coordinator else { throw SnipLibraryError.transferUnsupported }
            return coordinator
        }
        guard let configuration,
              let persistence = try await configuration.persistence()
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
        if let coordinator, coordinatorDescriptor == descriptor {
            return coordinator
        }
        attachmentCoordinator = nil
        attachmentStoreID = nil
        attachmentDescriptor = nil
        let created = await configuration.makeSyncCoordinator(persistence, namespace, descriptor)
        try await requireCurrentSource(storage, persistence: persistence)
        coordinator = created
        coordinatorDescriptor = descriptor
        return created
    }

    private func withAttachmentCoordinator<Value: Sendable>(
        _ operation: @escaping @Sendable (any CloudAttachmentTransferring) async throws -> Value
    ) async throws -> Value {
        if let attachmentCoordinator, configuration == nil {
            return try await operation(attachmentCoordinator)
        }
        guard let configuration,
              let persistence = try await configuration.persistence()
        else { throw SnipLibraryError.transferUnsupported }
        let storage = try await persistence.snapshot()
        guard storage.activeStore.kind == .iCloudSync,
              let binding = storage.activeStore.namespace
        else { throw SnipLibraryError.transferUnsupported }
        let descriptor = try await resolveDescriptor(
            matching: binding,
            configuration: configuration
        )
        try await requireCurrentSource(storage, persistence: persistence)
        let lease = try await persistence.activeCloudMutationLease(storeID: storage.activeStore.id)
        return try await lease.run {
            let attachment = try await self.attachmentCoordinator(
                persistence: persistence, storeID: storage.activeStore.id,
                binding: binding, descriptor: descriptor, configuration: configuration)
            return try await operation(attachment)
        }
    }

    private func attachmentCoordinator(
        persistence: SwiftDataSyncModePersistence,
        storeID: UUID,
        binding: ICloudSyncNamespaceBinding,
        descriptor: CloudCollectionDescriptor,
        configuration: Configuration
    ) async throws -> any CloudAttachmentTransferring {
        if let attachmentCoordinator, attachmentStoreID == storeID,
           attachmentDescriptor == descriptor {
            return attachmentCoordinator
        }
        let namespace = descriptor.namespace(cloudScope: binding.scope, accountLineage: binding.accountLineage)
        let library = try await persistence.libraryForTransition(storeID: storeID)
        let created = await configuration.makeAttachmentCoordinator(library, namespace, descriptor)
        attachmentCoordinator = created
        attachmentStoreID = storeID
        attachmentDescriptor = descriptor
        return created
    }

    private func requireCurrentSource(
        _ storage: SyncModeStorageSnapshot,
        persistence: SwiftDataSyncModePersistence
    ) async throws {
        let current = try await persistence.snapshot()
        guard current.activeStore.id == storage.activeStore.id,
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
    private let container: CKContainer

    package init(container: CKContainer) {
        self.container = container
    }

    package func currentAccountState() async -> ICloudAccountState {
        do {
            switch try await container.accountStatus() {
            case .available:
                let recordID = try await container.userRecordID()
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
