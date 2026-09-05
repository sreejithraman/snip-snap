import AppKit
import SnipSnapCloud
import SnipSnapCore
import Sparkle
import SnipSnapPersistence
import SwiftUI

private extension ShortcutKeyChord {
    var swiftUIEventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        let flags = eventModifierFlags
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}

private extension View {
    @ViewBuilder
    func appKeyboardShortcut(_ chord: ShortcutKeyChord) -> some View {
        if let character = chord.menuKeyEquivalent.first {
            keyboardShortcut(KeyEquivalent(character), modifiers: chord.swiftUIEventModifiers)
        } else {
            self
        }
    }
}

@main
@MainActor
struct SnipSnapApp: App {
    @NSApplicationDelegateAdaptor(SnipSnapApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            AppSettingsContent(
                model: appDelegate.model,
                shortcutSettings: appDelegate.shortcutSettings,
                syncedContentSettings: appDelegate.syncedContentSettings,
                coordinator: appDelegate.coordinator,
                accountNoticeModel: appDelegate.accountNoticeModel,
                cloudSyncHandler: appDelegate.cloudSyncHandler,
                updateChannelSettings: appDelegate.updateChannelSettings,
                updaterController: appDelegate.updateSettingsVisible
                    ? appDelegate.updaterController
                    : nil
            )
        }
        .defaultSize(width: 440, height: 290)
        .windowResizability(.contentSize)
        .commands {
            SnipCommands(
                applicationModel: appDelegate.model,
                coordinator: appDelegate.coordinator
            )
            ShortcutCommands()
            if appDelegate.updateChecksEnabled {
                UpdateCommands(updaterController: appDelegate.updaterController)
            }
        }
    }
}

private struct AppSettingsContent: View {
    @ObservedObject var model: AppModel
    let shortcutSettings: ShortcutSettings
    let syncedContentSettings: SyncedContentSettingsModel
    let coordinator: AppCoordinator
    @State var accountNoticeModel: AppleAccountNoticeModel?
    let cloudSyncHandler: (any OptionalCloudSyncHandling)?
    let updateChannelSettings: UpdateChannelSettings
    let updaterController: SPUStandardUpdaterController?
    @State private var isClearingDownloads = false
    @State private var isSyncing = false
    @State private var clearDownloadsError: String?

    var body: some View {
        TabView {
            ShortcutSettingsView(coordinator: coordinator)
                .environmentObject(shortcutSettings)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            VStack(spacing: 0) {
                if let accountNoticeModel, accountNoticeModel.notice != nil {
                    AppleAccountNoticeView(
                        model: accountNoticeModel,
                        accessibilityIdentifier: "apple-account-notice-settings"
                    )
                    Divider()
                }
                SyncedContentSettingsView(
                    model: syncedContentSettings,
                    retryAction: {
                        if syncedContentSettings.mode == .localOnly {
                            await syncedContentSettings.enableICloudSync()
                        } else {
                            await cloudSyncHandler?.retrySyncWhenPossible()
                        }
                    }
                )
                attachmentControls
            }
                .tabItem { Label("Sync", systemImage: "icloud") }

            if let updaterController {
                UpdateSettingsView(
                    settings: updateChannelSettings,
                    updater: updaterController.updater
                )
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            }
        }
        .preferredColorScheme(model.appearance.colorScheme)
    }

    @ViewBuilder
    private var attachmentControls: some View {
        if let cloudSyncHandler {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("iCloud Attachments").font(.headline)
                    Text("Downloaded files can be fetched again when you open them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isSyncing ? "Syncing…" : "Sync Now") {
                    isSyncing = true
                    Task {
                        await cloudSyncHandler.syncWhenPossible()
                        isSyncing = false
                    }
                }
                .disabled(isSyncing)
                .accessibilityIdentifier("sync-icloud-now")
                Button(isClearingDownloads ? "Clearing…" : "Clear Downloaded Files") {
                    isClearingDownloads = true
                    clearDownloadsError = nil
                    Task {
                        do {
                            try await model.clearDownloadedFiles()
                        } catch {
                            clearDownloadsError = String(localized: "Snip Snap could not clear the downloaded files.")
                        }
                        isClearingDownloads = false
                    }
                }
                .disabled(isClearingDownloads)
                .accessibilityIdentifier("clear-icloud-downloads")
            }
            .padding(16)
            if let clearDownloadsError {
                Text(clearDownloadsError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }
}

@MainActor
final class SnipSnapApplicationDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let shortcutSettings: ShortcutSettings
    let syncedContentSettings: SyncedContentSettingsModel
    let cloudSyncSession: SnipSnapCloudSyncSession?
    let cloudLifecycleHooks: SnipSnapCloudLifecycleHooks
    let coordinator: AppCoordinator
    let fileDropController: PanelFileDropController
    let dragSessionController: PanelDragSessionController
    let updaterController: SPUStandardUpdaterController
    let updateChannelSettings: UpdateChannelSettings
    let updateChecksEnabled: Bool
    let updateSettingsVisible: Bool
    let accountNoticeModel: AppleAccountNoticeModel?
    let cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private var cloudAccountObserver: NSObjectProtocol?
    private var automaticSyncTask: Task<Void, Never>?
    private var mainPanel: SnipSnapPanel?
    private var isFlushingBeforeTermination = false

    override init() {
        let isReleaseApp = Bundle.main.bundleIdentifier == "world.sree.snipsnap"
        let libraryStoreURL = SwiftDataSnipLibrary.defaultStoreURL()
        let store = Self.openLibrary(storeURL: libraryStoreURL)
        let library = store.library
        let syncModeRootURL = LocalSnipStorePaths(storeURL: libraryStoreURL).rootDirectory
            .appendingPathComponent("SyncMode", isDirectory: true)
#if DEBUG
        let initializeSyncModeStore =
            ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_SYNC_SETTINGS"] == "1"
#else
        let initializeSyncModeStore = false
#endif
        let assembly = SnipLibraryAssembly(
            library: library,
            syncModeRootURL: syncModeRootURL,
            initializeSyncModeStore: initializeSyncModeStore
        )
        let model = AppModel(
            library: assembly.library,
            initialError: store.errorMessage,
            recoveryScope: assembly.recoveryScope,
            userActions: assembly.userActions,
            userActionsRebinder: assembly.userActionsRebinder
        )
        let shortcutSettings = ShortcutSettings()
        let updateChannelSettings = UpdateChannelSettings()
        let cloudServices: SnipSnapCloudAppServices
#if DEBUG
        if ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_SYNC_ENABLE"] == "1" {
            cloudServices = SnipSnapCloudAppAssembly.simulatedLocalOnlyServices(
                rootURL: syncModeRootURL,
                sourceLibrary: library
            )
        } else if ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_SYNC_SETTINGS"] == "1" {
            cloudServices = SnipSnapCloudAppAssembly.simulatedServices(
                rootURL: syncModeRootURL,
                syncModeStore: assembly.syncModeStore
            )
        } else {
            cloudServices = SnipSnapCloudAppAssembly.services(
                rootURL: syncModeRootURL,
                sourceLibrary: library,
                syncModeStore: assembly.syncModeStore,
                containerIdentifier: Bundle.main.object(
                    forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
                ) as? String
            )
        }
#else
        cloudServices = SnipSnapCloudAppAssembly.services(
            rootURL: syncModeRootURL,
            sourceLibrary: library,
            syncModeStore: assembly.syncModeStore,
            containerIdentifier: Bundle.main.object(
                forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
            ) as? String
        )
#endif
        let fileDropController = PanelFileDropController()
        let dragSessionController = PanelDragSessionController()
        self.model = model
        self.shortcutSettings = shortcutSettings
        self.updateChannelSettings = updateChannelSettings
        syncedContentSettings = cloudServices.syncedContentSettings
        cloudSyncSession = cloudServices.syncSession
        self.fileDropController = fileDropController
        self.dragSessionController = dragSessionController
        updateChecksEnabled = isReleaseApp &&
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
#if DEBUG
        updateSettingsVisible = updateChecksEnabled ||
            ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_UPDATE_SETTINGS"] == "1"
#else
        updateSettingsVisible = updateChecksEnabled
#endif
        let reloadActiveLibrary: SyncedContentSettingsModel.DeleteCompletionAction = {
            guard let session = cloudServices.syncSession else { return }
            let active = try await session.activeLibrary()
            await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
        }
        let performSync: @MainActor @Sendable (Bool) async -> Void = { retry in
            guard let session = cloudServices.syncSession else { return }
            cloudServices.syncedContentSettings.recordSyncStarted()
            do {
                let result: SnipSnapCloudSyncResult
                if retry {
                    result = try await session.retrySynchronization()
                } else {
                    result = try await session.synchronize()
                }
                switch result {
                case .noChange:
                    break
                case .contentUpdated:
                    await model.reload()
                case .syncCompleted:
                    cloudServices.syncedContentSettings.recordOutstandingSyncRecovered()
                case .libraryReplaced:
                    try await reloadActiveLibrary()
                case .iCloudDataReset, .iCloudSignedOut, .iCloudAccountChanged:
                    try await reloadActiveLibrary()
                    let issue: SyncedContentSyncIssue
                    switch result {
                    case .iCloudDataReset:
                        issue = .iCloudDataReset
                    case .iCloudSignedOut:
                        issue = .signInRequired
                    default:
                        issue = .iCloudAccountChanged
                    }
                    cloudServices.syncedContentSettings.recordSyncStopped(issue)
                case .syncIssue(let issue):
                    cloudServices.syncedContentSettings.recordSyncFailure(issue)
                    return
                case .iCloudSyncSettingUp(let issue):
                    cloudServices.syncedContentSettings.recordEnableSettingUp(issue)
                case .iCloudSyncEnabled:
                    try await reloadActiveLibrary()
                    cloudServices.syncedContentSettings.recordEnableCompleted()
                case .oldSyncedContentRemovalPending:
                    try await reloadActiveLibrary()
                    cloudServices.syncedContentSettings.recordRemovalPending(true)
                case .oldSyncedContentRemovalCompleted:
                    try await reloadActiveLibrary()
                    cloudServices.syncedContentSettings.recordRemovalPending(false)
                }
                cloudServices.syncedContentSettings.recordSyncCompleted()
            } catch {
                cloudServices.syncedContentSettings.recordSyncFailure(
                    SnipSnapCloudSyncIssueMapper.issue(for: error)
                )
            }
        }
        let syncAction: SnipSnapCloudLifecycleHooks.SyncAction = {
            await performSync(false)
        }
        let retryAction: AppleAccountCacheCoordinatorHandler.SyncAction = {
            await performSync(true)
        }
        cloudLifecycleHooks = SnipSnapCloudLifecycleHooks(syncWhenPossible: syncAction)
        let productionCloudSyncHandler = Self.makeAccountCacheHandler(
            syncWhenPossible: syncAction,
            retrySyncWhenPossible: retryAction,
            scheduleSyncAfterLocalChange: {
                await cloudServices.syncSession?.scheduleAutomaticSync()
            }
        )
        cloudSyncHandler = productionCloudSyncHandler
        model.setCloudSyncHandler(productionCloudSyncHandler)
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
            accountNoticeModel = AppleAccountNoticeModel(
                handler: handler,
                activeLibraryChangeAction: reloadActiveLibrary
            )
        } else {
            accountNoticeModel = nil
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: updateChecksEnabled,
            updaterDelegate: updateChannelSettings,
            userDriverDelegate: nil
        )
        coordinator = AppCoordinator(model: model, shortcutSettings: shortcutSettings)
        if cloudSyncSession != nil {
            syncedContentSettings.setEnableCompletionAction(reloadActiveLibrary)
            syncedContentSettings.setDisableCompletionAction(reloadActiveLibrary)
            syncedContentSettings.setDeleteCompletionAction(reloadActiveLibrary)
        }
        super.init()
    }

    static func openLibrary(
        storeURL: URL = SwiftDataSnipLibrary.defaultStoreURL()
    ) -> LocalSnipLibraryOpenResult {
        MacLocalSnipLibraryBootstrap.open(storeURL: storeURL)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        let rootView = ContentView(
                coordinator: coordinator,
                fileDropController: fileDropController,
                dragSessionController: dragSessionController,
                accountNoticeModel: accountNoticeModel
            )
                .environmentObject(model)
                .environmentObject(shortcutSettings)
        let hostingView = PanelFileDropHostingView(
            rootView: rootView,
            controller: fileDropController,
            dragSessionController: dragSessionController
        )
        let hostingController = NSViewController()
        hostingController.view = hostingView
        let panel = SnipSnapPanel.make(
            contentViewController: hostingController,
            frameAutosaveName: AppWindowDefaults.frameAutosaveName
        )
        coordinator.attachPanelWindow(panel)
        coordinator.start()
        Task { [cloudLifecycleHooks, accountNoticeModel] in
            await cloudLifecycleHooks.launch()
            await accountNoticeModel?.refresh()
        }
        if let cloudSyncSession {
            let results = cloudSyncSession.automaticSyncResults
            automaticSyncTask = Task { @MainActor [weak self] in
                for await result in results {
                    guard let self, !Task.isCancelled else { return }
                    await self.handleAutomaticSyncResult(result)
                }
            }
        }
        cloudAccountObserver = NotificationCenter.default.addObserver(
            forName: SnipSnapCloudNotifications.accountChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.cloudLifecycleHooks.foreground()
                await self.accountNoticeModel?.refresh()
            }
        }
        if !panel.restoredSavedFrame {
            panel.center()
        }
        mainPanel = panel
#if DEBUG
        if ProcessInfo.processInfo.environment["SNIP_SNAP_SHOW_PANEL_ON_LAUNCH"] == "1" {
            panel.makeKeyAndOrderFront(nil)
        }
#endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard mainPanel != nil else { return }
        Task { [cloudLifecycleHooks, accountNoticeModel] in
            await cloudLifecycleHooks.foreground()
            await accountNoticeModel?.refresh()
        }
    }

    private func handleAutomaticSyncResult(_ result: SnipSnapCloudSyncResult) async {
        switch result {
        case .contentUpdated:
            await model.reload()
        case .syncCompleted:
            await model.reload()
            syncedContentSettings.recordOutstandingSyncRecovered()
        case .iCloudDataReset, .iCloudSignedOut, .iCloudAccountChanged:
            if let active = try? await cloudSyncSession?.activeLibrary() {
                await model.replaceLibrary(
                    active.library,
                    recoveryScope: active.recoveryScope
                )
            }
            let issue: SyncedContentSyncIssue
            switch result {
            case .iCloudDataReset:
                issue = .iCloudDataReset
            case .iCloudSignedOut:
                issue = .signInRequired
            default:
                issue = .iCloudAccountChanged
            }
            syncedContentSettings.recordSyncStopped(issue)
        case .syncIssue(let issue):
            syncedContentSettings.recordSyncFailure(issue)
            return
        default:
            break
        }
    }

    private static func makeAccountCacheHandler(
        syncWhenPossible: @escaping AppleAccountCacheCoordinatorHandler.SyncAction,
        retrySyncWhenPossible: @escaping AppleAccountCacheCoordinatorHandler.SyncAction,
        scheduleSyncAfterLocalChange: @escaping AppleAccountCacheCoordinatorHandler.ScheduleAction
    ) -> AppleAccountCacheCoordinatorHandler? {
        guard let containerIdentifier = Bundle.main.object(
            forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
        ) as? String else { return nil }
        let syncRootURL = LocalSnipStorePaths(storeURL: SwiftDataSnipLibrary.defaultStoreURL())
            .rootDirectory
            .appendingPathComponent("SyncMode", isDirectory: true)
        return AppleAccountCacheCoordinatorHandler(
            syncRootURL: syncRootURL,
            containerIdentifier: containerIdentifier,
            syncWhenPossible: syncWhenPossible,
            retrySyncWhenPossible: retrySyncWhenPossible,
            scheduleSyncAfterLocalChange: scheduleSyncAfterLocalChange
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFlushingBeforeTermination else { return .terminateLater }
        isFlushingBeforeTermination = true
        if let cloudAccountObserver {
            NotificationCenter.default.removeObserver(cloudAccountObserver)
            self.cloudAccountObserver = nil
        }
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        coordinator.savePanelWindowFrame(using: AppWindowDefaults.frameAutosaveName)
        Task { @MainActor [model] in
            model.flushComposerDrafts()
            await model.clipboardHistory.flushPersistence()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

}

extension AppleAccountNoticeModel {
    var message: String {
        switch notice {
        case .paused:
            String(localized: "Your synced cache is still on this Mac. Snip Snap will try again when iCloud is available.")
        case .signedOut, .accountChanged:
            String(localized: "Snip Snap kept the prior account’s cache apart. Keep it as a local copy or remove it from this Mac.")
        case nil:
            ""
        }
    }

}

struct AppleAccountNoticeView: View {
    let model: AppleAccountNoticeModel
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Needs Attention")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Label(
                model.title,
                systemImage: model.systemImage
            )
                .font(.headline)
            Text(model.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.showsResolutionActions {
                HStack(spacing: 12) {
                    Button("Keep Local Copy") {
                        Task { await model.resolve(.keepLocalCopy) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("keep-account-cache")
                    Button("Remove", role: .destructive) {
                        Task { await model.resolve(.remove) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("remove-account-cache")
                }
                .disabled(model.isResolving)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

#if DEBUG
private actor UITestAppleAccountCacheHandler: AppleAccountCacheHandling {
    private var didResolve = false
    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
        didResolve ? nil : .signedOut
    }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {
        didResolve = true
    }
}
#endif

private struct UpdateCommands: Commands {
    let updaterController: SPUStandardUpdaterController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updaterController.checkForUpdates(nil)
            }
        }
    }
}

private struct ShortcutCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            SettingsLink {
                Text("Keyboard Shortcuts…")
            }
            .keyboardShortcut("/", modifiers: .command)
        }
    }
}

private struct SnipCommandModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var snipCommandModel: AppModel? {
        get { self[SnipCommandModelKey.self] }
        set { self[SnipCommandModelKey.self] = newValue }
    }
}

private struct SnipCommands: Commands {
    @FocusedValue(\.snipCommandModel) private var model
    let applicationModel: AppModel
    let coordinator: AppCoordinator

    init(applicationModel: AppModel, coordinator: AppCoordinator) {
        self.applicationModel = applicationModel
        self.coordinator = coordinator
    }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Search") { coordinator.focusPanelSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("Snips") {
            Button(SnipCommand.copy.title, systemImage: "doc.on.doc") { perform(.copy) }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!isAvailable(.copy))
            Divider()
            Button(SnipCommand.edit.title) { perform(.edit) }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isAvailable(.edit))
            Button(SnipCommand.merge.title) { perform(.merge) }
                .appKeyboardShortcut(coordinator.shortcutSettings.chord(for: .merge))
                .disabled(!isAvailable(.merge))
            Button(SnipCompletionLanguage.toggle, systemImage: "checkmark") { perform(.toggleDone) }
                .appKeyboardShortcut(coordinator.shortcutSettings.chord(for: .toggleDone))
                .disabled(!isAvailable(.toggleDone))
            Divider()
            Button(SnipCommand.delete.title, systemImage: "trash", role: .destructive) { perform(.delete) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!isAvailable(.delete))
            Divider()
            Button(String(localized: "Import Backup…")) {
                model?.beginBackupImport()
            }
            .disabled(model == nil)
            Button("Export JSON Backup…") {
                exportJSONBackup(from: applicationModel)
            }
        }
    }

    private func isAvailable(_ command: SnipCommand) -> Bool {
        model.map { command.isAvailable(for: $0.selection.count) } ?? false
    }

    private func perform(_ command: SnipCommand) {
        guard let model else { return }
        SnipCommandDispatcher(model: model).perform(command)
    }

    private func exportJSONBackup(from model: AppModel) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export JSON Backup")
        panel.prompt = String(localized: "Export")
        panel.nameFieldStringValue = String(localized: "Snip Snap Backup")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let archive = try await model.exportArchive()
                try await Task.detached {
                    try JSONSnipArchiveTransfer.write(archive, to: url)
                }.value
            } catch {
                model.presentedError = error.localizedDescription
            }
        }
    }
}
