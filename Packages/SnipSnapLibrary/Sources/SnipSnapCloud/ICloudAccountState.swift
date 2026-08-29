import CloudKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

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
public actor AppleAccountCacheCoordinatorHandler: AppleAccountCacheHandling {
    private struct ProductionConfiguration: Sendable {
        let syncRootURL: URL
        let containerIdentifier: String
    }

    private var coordinator: ICloudSyncModeCoordinator?
    private let productionConfiguration: ProductionConfiguration?

    package init(coordinator: ICloudSyncModeCoordinator) {
        self.coordinator = coordinator
        productionConfiguration = nil
    }

    /// Opens only a sync store that another flow has already configured.
    /// Empty local-only builds never construct a CloudKit container.
    public init?(syncRootURL: URL, containerIdentifier: String) {
        let identifier = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              !identifier.contains("$("),
              (try? SwiftDataSyncModePersistence.existingCloudNamespace(
                rootURL: syncRootURL
              )) != nil
        else { return nil }
        coordinator = nil
        productionConfiguration = ProductionConfiguration(
            syncRootURL: syncRootURL,
            containerIdentifier: identifier
        )
    }

    public func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
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
    }

    private func requireCoordinator() async throws -> ICloudSyncModeCoordinator {
        if let coordinator { return coordinator }
        guard let productionConfiguration else {
            throw SnipLibraryError.transferUnsupported
        }
        let persistence = try SwiftDataSyncModePersistence(
            rootURL: productionConfiguration.syncRootURL
        )
        let storage = try await persistence.snapshot()
        guard let binding = storage.accountIsolation?.namespace
            ?? storage.transition?.namespace
            ?? storage.activeStore.namespace
        else { throw SnipLibraryError.transferUnsupported }
        let namespace = CloudSyncNamespace(
            cloudScope: binding.scope,
            accountLineage: binding.accountLineage,
            generation: binding.generation,
            zones: Set(binding.zones.map {
                CloudZoneID(name: $0.name, ownerName: $0.ownerName)
            })
        )
        guard let metadataZone = namespace.zones.first(where: { $0.name == "metadata" })
            ?? namespace.zones.sorted(by: { ($0.ownerName, $0.name) < ($1.ownerName, $1.name) }).first
        else { throw SnipLibraryError.transferUnsupported }
        let container = CKContainer(identifier: productionConfiguration.containerIdentifier)
        let source = CloudKitICloudAccountStateSource(container: container)
        let created = ICloudSyncModeCoordinator(
            persistence: persistence,
            namespace: namespace,
            textZone: metadataZone,
            makeTransport: {
                CloudKitRecordTransport(
                    database: container.privateCloudDatabase,
                    namespace: namespace
                )
            },
            accountStateSource: source
        )
        coordinator = created
        return created
    }
}

private actor CloudKitICloudAccountStateSource: ICloudAccountStateSource {
    private let container: CKContainer

    init(container: CKContainer) {
        self.container = container
    }

    func currentAccountState() async -> ICloudAccountState {
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
