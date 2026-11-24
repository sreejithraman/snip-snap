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

/// App sync actions and on-demand attachment access for the active library.
public actor SnipSnapCloudSyncHandler: OptionalCloudSyncHandling {
    public typealias SyncAction = @MainActor @Sendable () async -> Void
    package typealias AttachmentCoordinatorFactory = @Sendable (
        SwiftDataSnipLibrary,
        CloudSyncNamespace,
        CloudCollectionDescriptor
    ) async -> any CloudAttachmentTransferring
    private let persistence: @Sendable () async throws -> SwiftDataSyncModePersistence?
    private let controlTransport: any CloudCollectionControlTransport
    private let accountStateSource: (any ICloudAccountStateSource)?
    private let makeAttachmentCoordinator: AttachmentCoordinatorFactory
    private let ownerName: String
    private let reservedZones: Set<CloudZoneID>
    private let operationGate: AsyncOperationGate
    private let syncAction: SyncAction?
    private let retryAction: SyncAction?
    private let scheduleAction: SyncAction?

    private struct AttachmentBinding {
        let storeID: UUID
        let descriptor: CloudCollectionDescriptor
        let coordinator: any CloudAttachmentTransferring
    }

    private var attachmentBinding: AttachmentBinding?

    package init(
        persistence: @escaping @Sendable () async throws -> SwiftDataSyncModePersistence?,
        controlTransport: any CloudCollectionControlTransport,
        accountStateSource: (any ICloudAccountStateSource)? = nil,
        makeAttachmentCoordinator: @escaping AttachmentCoordinatorFactory,
        ownerName: String = CKCurrentUserDefaultName,
        reservedZones: Set<CloudZoneID> = [CloudCollectionAssembly.productionControlID.zone],
        operationGate: AsyncOperationGate = AsyncOperationGate(),
        syncWhenPossible: SyncAction? = nil,
        retrySyncWhenPossible: SyncAction? = nil,
        scheduleSyncAfterLocalChange: SyncAction? = nil
    ) {
        self.persistence = persistence
        self.controlTransport = controlTransport
        self.accountStateSource = accountStateSource
        self.makeAttachmentCoordinator = makeAttachmentCoordinator
        self.ownerName = ownerName
        self.reservedZones = reservedZones
        self.operationGate = operationGate
        syncAction = syncWhenPossible
        retryAction = retrySyncWhenPossible
        scheduleAction = scheduleSyncAfterLocalChange
    }

    public func syncWhenPossible() async { await syncAction?() }

    public func retrySyncWhenPossible() async { await (retryAction ?? syncAction)?() }

    public func scheduleSyncAfterLocalChange() async { await (scheduleAction ?? syncAction)?() }

    public func isCloudSyncActive() async throws -> Bool {
        try await operationGate.withLease { try await self.cloudSyncIsActive() }
    }

    private func cloudSyncIsActive() async throws -> Bool {
        guard let persistence = try await persistence() else { return false }
        return try await persistence.snapshot().activeStore.kind == .iCloudSync
    }

    public func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] {
        guard let persistence = try await persistence()
        else { throw SnipLibraryError.transferUnsupported }
        let storage = try await persistence.snapshot()
        guard storage.activeStore.kind == .iCloudSync,
              let binding = storage.activeStore.namespace
        else { throw SnipLibraryError.transferUnsupported }
        try await requireCurrentSource(storage, persistence: persistence)
        let library = try await persistence.libraryForTransition(storeID: storage.activeStore.id)
        let snapshot = try await library.cloudAttachmentStorageSnapshot(namespaceKey: binding.namespaceKey)
        try await requireCurrentSource(storage, persistence: persistence)
        return Dictionary(uniqueKeysWithValues: snapshot.publications.map { publication in
            let state: SyncedAttachmentTransferState = switch publication.transferState {
            case .waitingForUpload, .waitingForMetadata, .waitingForDeletion: .waiting
            case .available: .available
            case .failed: .failed
            }
            return (publication.metadata.attachmentID, state)
        })
    }

    public func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        try await operationGate.withLease {
            try await self.withAttachmentCoordinator { coordinator, _ in try await coordinator.prepare(attachmentID: id, for: use) }
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

    private func withAttachmentCoordinator<Value: Sendable>(
        _ operation: @escaping @Sendable (any CloudAttachmentTransferring, AttachmentSource?) async throws -> Value
    ) async throws -> Value {
        guard let persistence = try await persistence()
        else { throw SnipLibraryError.transferUnsupported }
        let storage = try await persistence.snapshot()
        guard storage.activeStore.kind == .iCloudSync,
              let binding = storage.activeStore.namespace
        else { throw SnipLibraryError.transferUnsupported }
        if let accountStateSource,
           await accountStateSource.currentAccountState() != .available(accountLineage: binding.accountLineage)
        {
            throw SnipLibraryError.transferUnsupported
        }
        let descriptor = try await resolveDescriptor(matching: binding)
        try await requireCurrentSource(storage, persistence: persistence)
        let lease = try await persistence.activeCloudMutation(storeID: storage.activeStore.id)
        return try await lease.run {
            try await self.requireCurrentSource(storage, persistence: persistence)
            let attachment = try await self.attachmentCoordinator(
                persistence: persistence, storeID: storage.activeStore.id,
                binding: binding, descriptor: descriptor)
            try await self.requireCurrentSource(storage, persistence: persistence)
            let source = AttachmentSource(library: try await persistence.libraryForTransition(storeID: storage.activeStore.id),
                storeID: storage.activeStore.id, namespaceKey: binding.namespaceKey)
            return try await operation(attachment, source)
        }
    }

    private func attachmentCoordinator(
        persistence: SwiftDataSyncModePersistence,
        storeID: UUID,
        binding: ICloudSyncNamespaceBinding,
        descriptor: CloudCollectionDescriptor
    ) async throws -> any CloudAttachmentTransferring {
        if let attachmentBinding, attachmentBinding.storeID == storeID, attachmentBinding.descriptor == descriptor {
            return attachmentBinding.coordinator
        }
        let namespace = descriptor.namespace(cloudScope: binding.scope, accountLineage: binding.accountLineage)
        let library = try await persistence.libraryForTransition(storeID: storeID)
        let created = await makeAttachmentCoordinator(library, namespace, descriptor)
        attachmentBinding = AttachmentBinding(storeID: storeID, descriptor: descriptor, coordinator: created)
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
              current.transition == storage.transition
        else { throw SyncModePersistenceError.namespaceMismatch }
    }

    private func resolveDescriptor(
        matching binding: ICloudSyncNamespaceBinding
    ) async throws -> CloudCollectionDescriptor {
        guard let current = try await controlTransport.fetchControl() else {
            throw SnipLibraryError.transferUnsupported
        }
        return try Self.validatedDescriptor(
            current,
            matching: binding,
            ownerName: ownerName,
            reservedZones: reservedZones
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
