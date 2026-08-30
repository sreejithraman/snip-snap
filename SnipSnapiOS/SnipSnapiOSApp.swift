import SnipSnapCloud
import SnipSnapCore
import SnipSnapPersistence
import SwiftUI

@main
@MainActor
struct SnipSnapiOSApp: App {
    private let library: any SnipLibrary
    private let userActions: any SnipLibraryUserActions
    private let userActionsFactory: SnipLibraryUserActionsFactory
    private let shareImports: ShareImportStore?
    private let startupError: String?
    private let uiTestAttachmentURLs: [URL]
    private let seedsCopyShareFixtures: Bool
    private let recoveryScope: SnipRecoveryScope?
    private let syncedContentSettings: SyncedContentSettingsModel
    private let cloudSyncSession: SnipSnapCloudSyncSession?
    private let accountNoticeModel: AppleAccountNoticeModel?
    private let cloudSyncHandler: (any OptionalCloudSyncHandling)?

    init() {
        let startup = Self.makeLibrary()
        library = startup.library
        userActions = startup.userActions
        userActionsFactory = startup.userActionsFactory
        shareImports = startup.shareImports
        startupError = startup.error
        uiTestAttachmentURLs = startup.uiTestAttachmentURLs
        seedsCopyShareFixtures = startup.seedsCopyShareFixtures
        recoveryScope = startup.recoveryScope
        let cloudServices: SnipSnapCloudAppServices
#if DEBUG
        if ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_SYNC_ENABLE"] == "1" {
            cloudServices = SnipSnapCloudAppAssembly.simulatedLocalOnlyServices(
                rootURL: startup.syncModeRootURL,
                sourceLibrary: startup.sourceLibrary
            )
        } else if ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_SYNC_SETTINGS"] == "1" {
            cloudServices = SnipSnapCloudAppAssembly.simulatedServices(
                rootURL: startup.syncModeRootURL,
                syncModeStore: startup.syncModeStore
            )
        } else {
            cloudServices = SnipSnapCloudAppAssembly.services(
                rootURL: startup.syncModeRootURL,
                sourceLibrary: startup.sourceLibrary,
                syncModeStore: startup.syncModeStore,
                containerIdentifier: Bundle.main.object(
                    forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
                ) as? String
            )
        }
#else
        cloudServices = SnipSnapCloudAppAssembly.services(
            rootURL: startup.syncModeRootURL,
            sourceLibrary: startup.sourceLibrary,
            syncModeStore: startup.syncModeStore,
            containerIdentifier: Bundle.main.object(
                forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
            ) as? String
        )
#endif
        syncedContentSettings = cloudServices.syncedContentSettings
        cloudSyncSession = cloudServices.syncSession
        let productionCloudSyncHandler = Self.makeAccountCacheHandler(
            syncWhenPossible: {
                guard let session = cloudServices.syncSession else { return }
                _ = try? await session.synchronize()
            }
        )
        cloudSyncHandler = productionCloudSyncHandler
        if ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_ACCOUNT_NOTICE"] == "signedOut" {
            accountNoticeModel = AppleAccountNoticeModel(
                notice: .signedOut,
                handler: UITestAppleAccountCacheHandler()
            )
        } else if let handler = productionCloudSyncHandler {
            accountNoticeModel = AppleAccountNoticeModel(handler: handler)
        } else {
            accountNoticeModel = nil
        }
    }

    private static func makeAccountCacheHandler(
        syncWhenPossible: @escaping AppleAccountCacheCoordinatorHandler.SyncAction
    ) -> AppleAccountCacheCoordinatorHandler? {
        guard let sharedRootURL = SnipSnapAppGroupContainer.resolve()?.url,
              let containerIdentifier = Bundle.main.object(
                forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
              ) as? String
        else { return nil }
        return AppleAccountCacheCoordinatorHandler(
            syncRootURL: sharedRootURL.appendingPathComponent("SyncMode", isDirectory: true),
            containerIdentifier: containerIdentifier,
            syncWhenPossible: syncWhenPossible
        )
    }

    var body: some Scene {
        WindowGroup {
            IOSAppRootView(
                library: library,
                userActions: userActions,
                recoveryScope: recoveryScope,
                shareImports: shareImports,
                startupError: startupError,
                uiTestAttachmentURLs: uiTestAttachmentURLs,
                seedsCopyShareFixtures: seedsCopyShareFixtures,
                syncedContentSettings: syncedContentSettings,
                cloudSyncSession: cloudSyncSession,
                accountNoticeModel: accountNoticeModel,
                cloudSyncHandler: cloudSyncHandler,
                userActionsFactory: userActionsFactory
            )
        }
    }

    private static func makeLibrary() -> (
        library: any SnipLibrary,
        sourceLibrary: any SnipLibrary,
        userActions: any SnipLibraryUserActions,
        userActionsFactory: SnipLibraryUserActionsFactory,
        shareImports: ShareImportStore?,
        error: String?,
        uiTestAttachmentURLs: [URL],
        seedsCopyShareFixtures: Bool,
        recoveryScope: SnipRecoveryScope?,
        syncModeStore: SnipSyncModeStore?,
        syncModeRootURL: URL
    ) {
        let environment = ProcessInfo.processInfo.environment
#if DEBUG
        if environment["SNIP_SNAP_UI_TEST_RECOVERY"] == "1" {
            let library = RecoveryUITestSnipLibrary()
            let actionsFactory = SnipLibraryUserActionsFactory.durable(
                journalURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SnipSnap-RecoveryUITest-Actions.json"),
                collectionIdentity: {
                    SnipLibraryCollectionIdentity(
                        digest: Data("ui-test-recovery-library".utf8)
                    )
                }
            )
            return (
                library,
                library,
                actionsFactory.actions(for: library),
                actionsFactory,
                nil,
                nil,
                [],
                false,
                SnipRecoveryScope("ui-test|account-a|generation-a"),
                nil,
                FileManager.default.temporaryDirectory.appendingPathComponent(
                    "SnipSnap-Recovery-UI-Test-SyncMode", isDirectory: true
                )
            )
        }
#endif
        let storeURL: URL
        let syncModeRootURL: URL
        let shareImports: ShareImportStore?

        if environment["SNIP_SNAP_UI_TESTING"] == "1" {
            let storeName = environment["SNIP_SNAP_UI_TEST_STORE"] ?? UUID().uuidString
            let sharedRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(storeName, isDirectory: true)
            storeURL = ShareImportStore.storeURL(in: sharedRootURL)
            syncModeRootURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("SyncMode", isDirectory: true)
            shareImports = ShareImportStore(sharedRootURL: sharedRootURL)
        } else if let sharedRootURL = SnipSnapAppGroupContainer.resolve()?.url {
            storeURL = ShareImportStore.storeURL(in: sharedRootURL)
            syncModeRootURL = sharedRootURL.appendingPathComponent("SyncMode", isDirectory: true)
            shareImports = ShareImportStore(sharedRootURL: sharedRootURL)
        } else {
            storeURL = SwiftDataSnipLibrary.defaultStoreURL()
            syncModeRootURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("SyncMode", isDirectory: true)
            shareImports = nil
        }

        do {
            let seedsCopyShareFixtures = environment["SNIP_SNAP_UI_TEST_COPY_SHARE"] == "1"
            let fixtureURLs = environment["SNIP_SNAP_UI_TEST_ATTACHMENTS"] == "1"
                    || seedsCopyShareFixtures
                ? makeUITestAttachmentFiles(nextTo: storeURL) : []
            let sourceLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
            let assembly = SnipLibraryAssembly(
                library: sourceLibrary,
                syncModeRootURL: syncModeRootURL,
                initializeSyncModeStore: environment["SNIP_SNAP_UI_TEST_SYNC_SETTINGS"] == "1"
            )
            return (
                assembly.library,
                sourceLibrary,
                assembly.userActions,
                assembly.userActionsFactory,
                shareImports,
                nil,
                fixtureURLs,
                seedsCopyShareFixtures,
                assembly.recoveryScope,
                assembly.syncModeStore,
                syncModeRootURL
            )
        } catch {
            let sourceLibrary = SwiftDataSnipLibrary.unavailable(storeURL: storeURL)
            let assembly = SnipLibraryAssembly(
                library: sourceLibrary,
                syncModeRootURL: syncModeRootURL
            )
            return (
                assembly.library,
                sourceLibrary,
                assembly.userActions,
                assembly.userActionsFactory,
                shareImports,
                "Snip Snap could not open its local library. Your saved data was not changed.",
                [],
                false,
                assembly.recoveryScope,
                assembly.syncModeStore,
                syncModeRootURL
            )
        }
    }

    private static func makeUITestAttachmentFiles(nextTo storeURL: URL) -> [URL] {
        let directory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("UITestFixtures", isDirectory: true)
        let imageURL = directory.appendingPathComponent("sample.png", isDirectory: false)
        let textURL = directory.appendingPathComponent("notes.txt", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let png = Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            ) ?? Data()
            try png.write(to: imageURL, options: .atomic)
            try Data("A local file attachment".utf8).write(to: textURL, options: .atomic)
            return [imageURL, textURL]
        } catch {
            return []
        }
    }
}

#if DEBUG
private actor RecoveryUITestSnipLibrary: SnipLibrary {
    private let listID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let snipID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let recoveredSnipID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let recoveredListID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private var snips: [Snip]
    private var lists: [SnipList]
    private var recovery: SnipRecoverySnapshot

    init() {
        let list = SnipList(
            id: listID,
            name: "Server Notes",
            systemImage: "folder",
            position: 1
        )
        let current = Snip(
            id: snipID,
            content: "Current text from iCloud",
            origin: .quickEntry,
            listID: listID
        )
        let recoveredValue = Snip(
            id: recoveredSnipID,
            content: "Recovered text from this device",
            origin: .quickEntry,
            source: SnipSource(applicationName: "Notes"),
            listID: listID,
            isDone: true
        )
        snips = [current]
        lists = [.inbox, list]
        recovery = SnipRecoverySnapshot(
            pendingSnips: [
                RecoveredSnip(
                    id: recoveredSnipID,
                    currentSnipID: snipID,
                    recovered: recoveredValue,
                    conflictingFields: [.text, .source, .done]
                )
            ],
            pendingLists: [
                RecoveredListEdit(
                    id: recoveredListID,
                    currentListID: listID,
                    recovered: SnipList(
                        id: listID,
                        name: "Recovered Notes",
                        systemImage: "star",
                        position: list.position,
                        sortKey: list.sortKey
                    ),
                    conflictingFields: [.name, .icon]
                )
            ]
        )
    }

    func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        SnipLibrarySnapshot(snips: Snip.sorted(snips, by: sortMode), lists: lists)
    }

    func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) throws -> SnipLibraryUpdate {
        guard case .pruneAttachments = command else {
            throw SnipLibraryError.storeUnavailable
        }
        return SnipLibraryUpdate(snapshot: snapshot(sortedBy: sortMode), outcome: .none)
    }

    func recoverySnapshot(in scope: SnipRecoveryScope) -> SnipRecoverySnapshot {
        recovery
    }

    func resolveRecovery(
        _ id: UUID,
        in scope: SnipRecoveryScope,
        choice: SnipRecoveryChoice
    ) throws -> SnipLibrarySnapshot {
        if let pending = recovery.pendingSnips.first(where: { $0.id == id }) {
            try resolve(pending, choice: choice)
            recovery = SnipRecoverySnapshot(
                promotedSnips: recovery.promotedSnips,
                pendingLists: recovery.pendingLists
            )
        } else if let pending = recovery.pendingLists.first(where: { $0.id == id }) {
            try resolve(pending, choice: choice)
            recovery = SnipRecoverySnapshot(
                pendingSnips: recovery.pendingSnips,
                promotedSnips: recovery.promotedSnips
            )
        } else {
            throw SnipLibraryError.recoveryNotFound
        }
        return snapshot(sortedBy: .chronological)
    }

    private func resolve(_ pending: RecoveredSnip, choice: SnipRecoveryChoice) throws {
        guard let index = snips.firstIndex(where: { $0.id == pending.currentSnipID }) else {
            throw SnipLibraryError.recoveryChanged
        }
        switch choice {
        case .keepCurrent:
            break
        case .useRecovered:
            snips[index] = applying(pending.recovered, to: snips[index], fields: pending.conflictingFields)
        case .keepBoth:
            snips.append(pending.recovered)
            recovery = SnipRecoverySnapshot(
                pendingSnips: recovery.pendingSnips,
                promotedSnips: recovery.promotedSnips + [pending.promoted()],
                pendingLists: recovery.pendingLists
            )
        case .editSnip(let edited):
            snips[index] = applying(edited, to: snips[index], fields: pending.conflictingFields)
        case .editList:
            throw SnipLibraryError.invalidRecoveryChoice
        }
    }

    private func resolve(_ pending: RecoveredListEdit, choice: SnipRecoveryChoice) throws {
        guard let index = lists.firstIndex(where: { $0.id == pending.currentListID }) else {
            throw SnipLibraryError.recoveryChanged
        }
        switch choice {
        case .keepCurrent:
            break
        case .useRecovered:
            lists[index] = applying(pending.recovered, to: lists[index], fields: pending.conflictingFields)
        case .editList(let edited):
            lists[index] = applying(edited, to: lists[index], fields: pending.conflictingFields)
        case .keepBoth, .editSnip:
            throw SnipLibraryError.invalidRecoveryChoice
        }
    }

    private func applying(
        _ candidate: Snip,
        to current: Snip,
        fields: Set<RecoveredSnipField>
    ) -> Snip {
        var result = current
        if fields.contains(.text) { result.content = candidate.content }
        if fields.contains(.source) { result.source = candidate.source }
        if fields.contains(.done) { result.isDone = candidate.isDone }
        if fields.contains(.placement) { result.listID = candidate.listID }
        return result
    }

    private func applying(
        _ candidate: SnipList,
        to current: SnipList,
        fields: Set<RecoveredListField>
    ) -> SnipList {
        SnipList(
            id: current.id,
            name: fields.contains(.name) ? candidate.name : current.name,
            systemImage: fields.contains(.icon) ? candidate.systemImage : current.systemImage,
            position: current.position,
            sortKey: current.sortKey
        )
    }
}
#endif

private actor UITestAppleAccountCacheHandler: AppleAccountCacheHandling {
    private var didResolve = false
    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
        didResolve ? nil : .signedOut
    }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {
        didResolve = true
    }
}
