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
        CloudZoneID
    ) async -> any CloudAttachmentTransferring
    package typealias SyncCoordinatorFactory = @Sendable (
        SwiftDataSyncModePersistence,
        CloudSyncNamespace,
        CloudCollectionDescriptor
    ) async -> ICloudSyncModeCoordinator

    private enum SyncBackend: Sendable {
        case cloudKit(containerIdentifier: String)
        case injected(
            controlTransport: any CloudCollectionControlTransport,
            makeSyncCoordinator: SyncCoordinatorFactory,
            makeAttachmentCoordinator: AttachmentCoordinatorFactory
        )
    }

    private struct ProductionConfiguration: Sendable {
        let syncRootURL: URL
        let backend: SyncBackend
    }

    private var coordinator: ICloudSyncModeCoordinator?
    private var attachmentCoordinator: (any CloudAttachmentTransferring)?
    private var attachmentStoreID: UUID?
    private var coordinatorDescriptor: CloudCollectionDescriptor?
    private var attachmentDescriptor: CloudCollectionDescriptor?
    private let productionConfiguration: ProductionConfiguration?
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
        productionConfiguration = nil
        syncAction = syncWhenPossible
        retryAction = retrySyncWhenPossible
        scheduleAction = scheduleSyncAfterLocalChange
    }

    package init(
        syncRootURL: URL,
        controlTransport: any CloudCollectionControlTransport,
        makeSyncCoordinator: @escaping SyncCoordinatorFactory,
        makeAttachmentCoordinator: @escaping AttachmentCoordinatorFactory
    ) {
        coordinator = nil
        attachmentCoordinator = nil
        attachmentStoreID = nil
        coordinatorDescriptor = nil
        attachmentDescriptor = nil
        productionConfiguration = ProductionConfiguration(
            syncRootURL: syncRootURL,
            backend: .injected(
                controlTransport: controlTransport,
                makeSyncCoordinator: makeSyncCoordinator,
                makeAttachmentCoordinator: makeAttachmentCoordinator
            )
        )
        syncAction = nil
        retryAction = nil
        scheduleAction = nil
    }

    /// Opens the account seam without constructing CloudKit until an account action runs.
    public init?(
        syncRootURL: URL,
        containerIdentifier: String,
        syncWhenPossible: @escaping SyncAction,
        retrySyncWhenPossible: SyncAction? = nil,
        scheduleSyncAfterLocalChange: @escaping ScheduleAction = {}
    ) {
        let identifier = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              !identifier.contains("$(")
        else { return nil }
        coordinator = nil
        attachmentCoordinator = nil
        attachmentStoreID = nil
        coordinatorDescriptor = nil
        attachmentDescriptor = nil
        productionConfiguration = ProductionConfiguration(
            syncRootURL: syncRootURL,
            backend: .cloudKit(containerIdentifier: identifier)
        )
        syncAction = syncWhenPossible
        retryAction = retrySyncWhenPossible
        scheduleAction = scheduleSyncAfterLocalChange
    }

    public func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
        if let productionConfiguration {
            let persistence = try SwiftDataSyncModePersistence(
                rootURL: productionConfiguration.syncRootURL
            )
            let storage = try await persistence.snapshot()
            guard storage.accountIsolation?.namespace != nil
                    || storage.transition?.namespace != nil
                    || storage.activeStore.namespace != nil
            else { return nil }
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
        let coordinator = try await requireCoordinator()
        switch choice {
        case .keepLocalCopy:
            _ = try await coordinator.resolveAccountIsolation(.keepLocalCopy)
        case .remove:
            _ = try await coordinator.resolveAccountIsolation(.remove)
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
        guard let productionConfiguration else { return coordinator != nil }
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: productionConfiguration.syncRootURL
        )
        return try await persistence.snapshot().activeStore.kind == .iCloudSync
    }

    public func syncedAttachmentStates() async throws
        -> [UUID: SyncedAttachmentTransferState]
    {
        let values = try await requireAttachmentCoordinator().transferStates()
        return values.mapValues { value in
            switch value {
            case .waitingForUpload, .waitingForMetadata, .waitingForDeletion: .waiting
            case .available: .available
            case .failed: .failed
            }
        }
    }

    public func prepareSyncedAttachment(
        _ id: UUID,
        for use: SyncedAttachmentUse
    ) async throws -> URL {
        try await requireAttachmentCoordinator().prepare(attachmentID: id, for: use)
    }

    public func clearDownloadedFiles() async throws {
        try await requireAttachmentCoordinator().clearDownloads()
    }

    private func requireCoordinator() async throws -> ICloudSyncModeCoordinator {
        if productionConfiguration == nil {
            guard let coordinator else { throw SnipLibraryError.transferUnsupported }
            return coordinator
        }
        guard let productionConfiguration else { throw SnipLibraryError.transferUnsupported }
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: productionConfiguration.syncRootURL
        )
        let storage = try await persistence.snapshot()
        guard let binding = storage.accountIsolation?.namespace
            ?? storage.transition?.namespace
            ?? storage.activeStore.namespace
        else { throw SnipLibraryError.transferUnsupported }
        let descriptor = try await resolveDescriptor(
            matching: binding,
            configuration: productionConfiguration
        )
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
        let created: ICloudSyncModeCoordinator
        switch productionConfiguration.backend {
        case .cloudKit(let identifier):
            let container = CKContainer(identifier: identifier)
            let source = CloudKitICloudAccountStateSource(container: container)
            created = ICloudSyncModeCoordinator(
                persistence: persistence,
                namespace: namespace,
                textZone: descriptor.metadataZone,
                payloadZone: descriptor.payloadZone,
                makeTransport: {
                    CloudKitRecordTransport(
                        database: container.privateCloudDatabase,
                        namespace: namespace
                    )
                },
                accountStateSource: source
            )
        case .injected(_, let makeSyncCoordinator, _):
            created = await makeSyncCoordinator(persistence, namespace, descriptor)
        }
        coordinator = created
        coordinatorDescriptor = descriptor
        return created
    }

    private func requireAttachmentCoordinator() async throws
        -> any CloudAttachmentTransferring
    {
        if let attachmentCoordinator, productionConfiguration == nil {
            return attachmentCoordinator
        }
        guard let productionConfiguration else { throw SnipLibraryError.transferUnsupported }
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: productionConfiguration.syncRootURL
        )
        let storage = try await persistence.snapshot()
        guard storage.activeStore.kind == .iCloudSync,
              let binding = storage.activeStore.namespace
        else { throw SnipLibraryError.transferUnsupported }
        let descriptor = try await resolveDescriptor(
            matching: binding,
            configuration: productionConfiguration
        )
        if let attachmentCoordinator,
           attachmentStoreID == storage.activeStore.id,
           attachmentDescriptor == descriptor
        {
            return attachmentCoordinator
        }
        let namespace = descriptor.namespace(
            cloudScope: binding.scope,
            accountLineage: binding.accountLineage
        )
        let library = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
        let created: any CloudAttachmentTransferring
        switch productionConfiguration.backend {
        case .injected(_, _, let makeAttachmentCoordinator):
            created = await makeAttachmentCoordinator(library, namespace, descriptor.payloadZone)
        case .cloudKit(let identifier):
            let container = CKContainer(identifier: identifier)
            created = CloudAttachmentTransferCoordinator(
                library: library,
                namespace: namespace,
                payloadZone: descriptor.payloadZone,
                transport: CloudKitRecordTransport(
                    database: container.privateCloudDatabase,
                    namespace: namespace
                ),
                maximumCacheBytes: 512 * 1_024 * 1_024
            )
        }
        attachmentCoordinator = created
        attachmentStoreID = storage.activeStore.id
        attachmentDescriptor = descriptor
        return created
    }

    private func resolveDescriptor(
        matching binding: ICloudSyncNamespaceBinding,
        configuration: ProductionConfiguration
    ) async throws -> CloudCollectionDescriptor {
        let control: any CloudCollectionControlTransport
        switch configuration.backend {
        case .injected(let injected, _, _):
            control = injected
        case .cloudKit(let identifier):
            let container = CKContainer(identifier: identifier)
            control = CloudKitCollectionControlTransport(
                database: container.privateCloudDatabase,
                controlID: CloudCollectionAssembly.productionControlID
            )
        }
        guard let current = try await control.fetchControl() else {
            throw SnipLibraryError.transferUnsupported
        }
        return try Self.validatedDescriptor(
            current,
            matching: binding,
            ownerName: CKCurrentUserDefaultName,
            reservedZones: [CloudCollectionAssembly.productionControlID.zone]
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
