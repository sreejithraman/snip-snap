import SnipSnapCloud
import SnipSnapCore
import SnipSnapPersistence
import SwiftUI


@main
@MainActor
struct SnipSnapiOSApp: App {
    private let session: IOSAppSession
    private let uiTestAttachmentURLs: [URL]
    private let seedsCopyShareFixtures: Bool
    private let shareProcessToken: String?

    init() {
        let startup = Self.makeLibrary()
        uiTestAttachmentURLs = startup.uiTestAttachmentURLs
        seedsCopyShareFixtures = startup.seedsCopyShareFixtures
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        shareProcessToken = environment["SNIP_SNAP_UI_TEST_SHARE_EXTENSION_PROCESS"] == "1"
            ? environment["SNIP_SNAP_UI_TEST_SHARE_TOKEN"]
            : nil
#else
        shareProcessToken = nil
#endif
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
        let syncActionBridge = IOSCloudSyncActionBridge()
        let productionCloudSyncHandler = Self.makeAccountCacheHandler {
            await syncActionBridge.syncWhenPossible()
        }
        let accountNoticeModel: AppleAccountNoticeModel?
#if DEBUG
        let uiTestAccountNoticeModel =
            ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_ACCOUNT_NOTICE"] == "signedOut"
            ? AppleAccountNoticeModel(
                notice: .signedOut,
                handler: UITestAppleAccountCacheHandler()
            )
            : nil
#else
        let uiTestAccountNoticeModel: AppleAccountNoticeModel? = nil
#endif
        if let uiTestAccountNoticeModel {
            accountNoticeModel = uiTestAccountNoticeModel
        } else if let handler = productionCloudSyncHandler {
            accountNoticeModel = AppleAccountNoticeModel(handler: handler)
        } else {
            accountNoticeModel = nil
        }
        session = IOSAppSession(
            library: startup.library,
            userActions: startup.userActions,
            userActionsRebinder: startup.userActionsRebinder,
            recoveryScope: startup.recoveryScope,
            shareImports: startup.shareImports,
            startupError: startup.error,
            syncedContentSettings: cloudServices.syncedContentSettings,
            cloudSyncSession: cloudServices.syncSession,
            accountNoticeModel: accountNoticeModel,
            cloudSyncHandler: productionCloudSyncHandler
        )
        syncActionBridge.session = session
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
                session: session,
                uiTestAttachmentURLs: uiTestAttachmentURLs,
                seedsCopyShareFixtures: seedsCopyShareFixtures,
                shareProcessToken: shareProcessToken
            )
        }
    }

    private static func makeLibrary() -> IOSLibraryStartup {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["SNIP_SNAP_UI_TEST_RECOVERY"] == "1" {
            let library = RecoveryUITestSnipLibrary()
            return IOSLibraryStartup(
                library: library,
                sourceLibrary: library,
                userActions: DirectSnipLibraryUserActions(library: library),
                userActionsRebinder: .direct,
                shareImports: nil,
                error: nil,
                uiTestAttachmentURLs: [],
                seedsCopyShareFixtures: false,
                recoveryScope: SnipRecoveryScope("ui-test|account-a|generation-a"),
                syncModeStore: nil,
                syncModeRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "SnipSnap-Recovery-UI-Test-SyncMode", isDirectory: true
                )
            )
        }
#endif
        let storeURL: URL
        let syncModeRootURL: URL
        let shareImports: ShareImportStore?
#if DEBUG
        var uiTestShareStoreUnavailable = false
#endif

#if DEBUG
        let uiTestSharedRootURL: URL?
        if environment["SNIP_SNAP_UI_TESTING"] == "1" {
            let storeName = environment["SNIP_SNAP_UI_TEST_STORE"] ?? UUID().uuidString
            uiTestSharedRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(storeName, isDirectory: true)
        } else {
            uiTestSharedRootURL = nil
        }
#else
        let uiTestSharedRootURL: URL? = nil
#endif
        if let sharedRootURL = uiTestSharedRootURL ?? SnipSnapAppGroupContainer.resolve()?.url {
            storeURL = ShareImportStore.storeURL(in: sharedRootURL)
            syncModeRootURL = sharedRootURL.appendingPathComponent("SyncMode", isDirectory: true)
            shareImports = ShareImportStore(sharedRootURL: sharedRootURL)
#if DEBUG
            if uiTestSharedRootURL == nil {
                uiTestShareStoreUnavailable = prepareShareProcessStoreControl(
                    sharedRootURL: sharedRootURL,
                    environment: environment
                )
            }
#endif
        } else {
            storeURL = SwiftDataSnipLibrary.defaultStoreURL()
            syncModeRootURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("SyncMode", isDirectory: true)
            shareImports = nil
        }

        do {
#if DEBUG
            if uiTestShareStoreUnavailable {
                throw SnipLibraryError.storeUnavailable
            }
#endif
#if DEBUG
            let seedsCopyShareFixtures = environment["SNIP_SNAP_UI_TEST_COPY_SHARE"] == "1"
            let fixtureURLs: [URL]
            if environment["SNIP_SNAP_UI_TEST_LIMIT_ATTACHMENTS"] == "1" {
                fixtureURLs = makeUITestLimitAttachmentFiles(nextTo: storeURL)
            } else if environment["SNIP_SNAP_UI_TEST_ATTACHMENTS"] == "1"
                        || seedsCopyShareFixtures
            {
                fixtureURLs = makeUITestAttachmentFiles(nextTo: storeURL)
            } else {
                fixtureURLs = []
            }
            let initializeSyncModeStore = environment["SNIP_SNAP_UI_TEST_SYNC_SETTINGS"] == "1"
#else
            let seedsCopyShareFixtures = false
            let fixtureURLs: [URL] = []
            let initializeSyncModeStore = false
#endif
            let sourceLibrary = try SwiftDataSnipLibrary(storeURL: storeURL)
            let assembly = SnipLibraryAssembly(
                library: sourceLibrary,
                syncModeRootURL: syncModeRootURL,
                initializeSyncModeStore: initializeSyncModeStore
            )
            return IOSLibraryStartup(
                library: assembly.library,
                sourceLibrary: sourceLibrary,
                userActions: assembly.userActions,
                userActionsRebinder: assembly.userActionsRebinder,
                shareImports: shareImports,
                error: nil,
                uiTestAttachmentURLs: fixtureURLs,
                seedsCopyShareFixtures: seedsCopyShareFixtures,
                recoveryScope: assembly.recoveryScope,
                syncModeStore: assembly.syncModeStore,
                syncModeRootURL: syncModeRootURL
            )
        } catch {
            let sourceLibrary = SwiftDataSnipLibrary.unavailable(storeURL: storeURL)
            let assembly = SnipLibraryAssembly(
                library: sourceLibrary,
                syncModeRootURL: syncModeRootURL
            )
            return IOSLibraryStartup(
                library: assembly.library,
                sourceLibrary: sourceLibrary,
                userActions: assembly.userActions,
                userActionsRebinder: assembly.userActionsRebinder,
                shareImports: shareImports,
                error: String(localized: "Snip Snap could not open its local library. Your saved data was not changed."),
                uiTestAttachmentURLs: [],
                seedsCopyShareFixtures: false,
                recoveryScope: assembly.recoveryScope,
                syncModeStore: assembly.syncModeStore,
                syncModeRootURL: syncModeRootURL
            )
        }
    }

#if DEBUG
    private static func prepareShareProcessStoreControl(
        sharedRootURL: URL,
        environment: [String: String]
    ) -> Bool {
        guard environment["SNIP_SNAP_UI_TEST_SHARE_EXTENSION_PROCESS"] == "1" else {
            return false
        }
        let markerURL = sharedRootURL.appendingPathComponent(
            "ShareProcessMainStoreUnavailable",
            isDirectory: false
        )
        if environment["SNIP_SNAP_UI_TEST_SHARE_STORE_REPAIR"] == "1" {
            try? FileManager.default.removeItem(at: markerURL)
        } else if environment["SNIP_SNAP_UI_TEST_SHARE_STORE_UNAVAILABLE"] == "1" {
            try? Data("unavailable".utf8).write(to: markerURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: markerURL)
        }
        return FileManager.default.fileExists(atPath: markerURL.path)
    }
#endif

#if DEBUG
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

    private static func makeUITestLimitAttachmentFiles(nextTo storeURL: URL) -> [URL] {
        let directory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("UITestLimitFixtures", isDirectory: true)
        let first = directory.appendingPathComponent("over-limit-a.bin", isDirectory: false)
        let second = directory.appendingPathComponent("over-limit-b.bin", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            for (url, extraByteCount) in [(first, 1), (second, 2)] {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(
                    atOffset: UInt64(
                        SnipSnapCloudAttachmentLimits.maximumFileBytes + Int64(extraByteCount)
                    )
                )
                try handle.close()
            }
            return [first, second]
        } catch {
            return []
        }
    }
#endif
}
