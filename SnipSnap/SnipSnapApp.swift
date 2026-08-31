import AppKit
import Observation
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
                cloudSyncHandler: appDelegate.cloudSyncHandler
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
    @State private var isClearingDownloads = false
    @State private var isSyncing = false
    @State private var clearDownloadsError: String?

    var body: some View {
        TabView {
            ShortcutSettingsView(coordinator: coordinator)
                .environmentObject(shortcutSettings)
                .tabItem { Label(.shortcuts, systemImage: "keyboard") }

            VStack(spacing: 0) {
                if let accountNoticeModel, accountNoticeModel.notice != nil {
                    AppleAccountNoticeView(
                        model: accountNoticeModel,
                        accessibilityIdentifier: "apple-account-notice-settings"
                    )
                    Divider()
                }
                SyncedContentSettingsView(model: syncedContentSettings)
                attachmentControls
            }
                .tabItem { Label(.sync, systemImage: "icloud") }
        }
        .preferredColorScheme(model.appearance.colorScheme)
    }

    @ViewBuilder
    private var attachmentControls: some View {
        if let cloudSyncHandler {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(.iCloudAttachments).font(.headline)
                    Text(.downloadedFilesCanBeFetchedAgainWhenYouOpenThem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isSyncing
                    ? String(localized: .actionSyncing)
                    : String(localized: .syncNow)) {
                    isSyncing = true
                    Task {
                        await cloudSyncHandler.syncWhenPossible()
                        isSyncing = false
                    }
                }
                .disabled(isSyncing)
                .accessibilityIdentifier("sync-icloud-now")
                Button {
                    isClearingDownloads = true
                    clearDownloadsError = nil
                    Task {
                        do {
                            try await model.clearDownloadedFiles()
                        } catch {
                            clearDownloadsError = String(localized: .snipSnapCouldNotClearTheDownloadedFiles)
                        }
                        isClearingDownloads = false
                    }
                } label: {
                    Text(isClearingDownloads ? .clearing : .clearDownloadedFiles)
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
    let snipDragSourceController: SnipDragSourceController
    let updaterController: SPUStandardUpdaterController
    let updateChecksEnabled: Bool
    let accountNoticeModel: AppleAccountNoticeModel?
    let cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private var cloudSyncActivity: NSBackgroundActivityScheduler?
    private var mainPanel: SnipSnapPanel?
    private var isFlushingBeforeTermination = false

    override init() {
        let isReleaseApp = Bundle.main.bundleIdentifier == "world.sree.snipsnap"
        let libraryStoreURL = JSONSnipLibrary.defaultStoreURL()
        let store = Self.openLibrary(jsonURL: libraryStoreURL)
        let library = store.library
        let syncModeRootURL = libraryStoreURL.deletingLastPathComponent()
            .appendingPathComponent("SyncMode", isDirectory: true)
        let assembly = SnipLibraryAssembly(
            library: library,
            syncModeRootURL: syncModeRootURL,
            initializeSyncModeStore:
                ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_SYNC_SETTINGS"] == "1"
        )
        let model = AppModel(
            library: assembly.library,
            initialError: store.errorMessage,
            recoveryScope: assembly.recoveryScope,
            userActions: assembly.userActions,
            userActionsRebinder: assembly.userActionsRebinder
        )
        let shortcutSettings = ShortcutSettings()
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
        let snipDragSourceController = SnipDragSourceController()
        self.model = model
        self.shortcutSettings = shortcutSettings
        syncedContentSettings = cloudServices.syncedContentSettings
        cloudSyncSession = cloudServices.syncSession
        self.fileDropController = fileDropController
        self.snipDragSourceController = snipDragSourceController
        updateChecksEnabled = isReleaseApp &&
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        let syncAction: SnipSnapCloudLifecycleHooks.SyncAction = {
            guard let session = cloudServices.syncSession else { return }
            do {
                switch try await session.synchronize() {
                case .noChange:
                    break
                case .contentUpdated:
                    await model.reload()
                case .libraryReplaced:
                    let active = try await session.activeLibrary()
                    await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                case .oldSyncedContentRemovalPending:
                    let active = try await session.activeLibrary()
                    await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                    cloudServices.syncedContentSettings.recordRemovalPending(true)
                case .oldSyncedContentRemovalCompleted:
                    let active = try await session.activeLibrary()
                    await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                    cloudServices.syncedContentSettings.recordRemovalPending(false)
                case .encryptedDataResetRequiresChoice:
                    let active = try await session.activeLibrary()
                    await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                    cloudServices.syncedContentSettings.recordEncryptedDataReset()
                case .syncKeptOff:
                    let active = try await session.activeLibrary()
                    await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                }
            } catch {
                model.presentedError = error.localizedDescription
            }
        }
        cloudLifecycleHooks = SnipSnapCloudLifecycleHooks(syncWhenPossible: syncAction)
        let productionCloudSyncHandler = Self.makeAccountCacheHandler(
            syncWhenPossible: syncAction
        )
        cloudSyncHandler = productionCloudSyncHandler
        model.setCloudSyncHandler(productionCloudSyncHandler)
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
        updaterController = SPUStandardUpdaterController(
            startingUpdater: updateChecksEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        coordinator = AppCoordinator(model: model, shortcutSettings: shortcutSettings)
        if let cloudSyncSession {
            let reloadActiveLibrary: SyncedContentSettingsModel.DeleteCompletionAction = {
                let active = try await cloudSyncSession.activeLibrary()
                await model.replaceLibrary(
                    active.library,
                    recoveryScope: active.recoveryScope
                )
            }
            syncedContentSettings.setEnableCompletionAction(reloadActiveLibrary)
            syncedContentSettings.setDisableCompletionAction(reloadActiveLibrary)
            syncedContentSettings.setDeleteCompletionAction(reloadActiveLibrary)
            syncedContentSettings.setEncryptedDataResetCompletionAction(reloadActiveLibrary)
        }
        super.init()
    }

    static func openLibrary(
        jsonURL: URL = JSONSnipLibrary.defaultStoreURL()
    ) -> LocalSnipLibraryOpenResult {
        MacLocalSnipLibraryBootstrap.open(jsonURL: jsonURL)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        let rootView = ContentView(
                coordinator: coordinator,
                fileDropController: fileDropController,
                snipDragSourceController: snipDragSourceController,
                accountNoticeModel: accountNoticeModel
            )
                .environmentObject(model)
                .environmentObject(shortcutSettings)
        let hostingView = PanelFileDropHostingView(
            rootView: rootView,
            controller: fileDropController,
            snipDragSourceController: snipDragSourceController
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
        scheduleBackgroundSync()
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

    private static func makeAccountCacheHandler(
        syncWhenPossible: @escaping AppleAccountCacheCoordinatorHandler.SyncAction
    ) -> AppleAccountCacheCoordinatorHandler? {
        guard let containerIdentifier = Bundle.main.object(
            forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
        ) as? String else { return nil }
        let syncRootURL = JSONSnipLibrary.defaultStoreURL()
            .deletingLastPathComponent()
            .appendingPathComponent("SyncMode", isDirectory: true)
        return AppleAccountCacheCoordinatorHandler(
            syncRootURL: syncRootURL,
            containerIdentifier: containerIdentifier,
            syncWhenPossible: syncWhenPossible
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFlushingBeforeTermination else { return .terminateLater }
        isFlushingBeforeTermination = true
        cloudSyncActivity?.invalidate()
        coordinator.savePanelWindowFrame(using: AppWindowDefaults.frameAutosaveName)
        Task { @MainActor [model] in
            model.flushComposerDrafts()
            await model.clipboardHistory.flushPersistence()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func scheduleBackgroundSync() {
        guard cloudSyncSession != nil else { return }
        let activity = NSBackgroundActivityScheduler(
            identifier: (Bundle.main.bundleIdentifier ?? "org.example.snipsnap")
                + ".optional-cloud-sync"
        )
        activity.repeats = true
        activity.interval = 15 * 60
        activity.tolerance = 5 * 60
        activity.qualityOfService = .utility
        activity.schedule { [self] completion in
            Task { @MainActor [cloudLifecycleHooks = self.cloudLifecycleHooks] in
                await cloudLifecycleHooks.launch()
                completion(.finished)
            }
        }
        cloudSyncActivity = activity
    }
}

@MainActor
@Observable
final class AppleAccountNoticeModel {
    private(set) var notice: AppleAccountNotice?
    private(set) var isResolving = false
    private(set) var errorMessage: String?
    private let handler: (any AppleAccountCacheHandling)?

    init(
        notice: AppleAccountNotice? = nil,
        handler: (any AppleAccountCacheHandling)? = nil
    ) {
        self.notice = handler == nil ? nil : notice
        self.handler = handler
    }

    var title: String {
        switch notice {
        case .paused: String(localized: .iCloudSyncPaused)
        case .signedOut: String(localized: .signedOutOfICloud)
        case .accountChanged: String(localized: .appleAccountChanged)
        case nil: ""
        }
    }

    var message: String {
        switch notice {
        case .paused:
            String(localized: .yourSyncedCacheIsStillOnThisMacSnipSnapWillTryAgainWhenICloudIsAvailable)
        case .signedOut, .accountChanged:
            String(localized: .snipSnapKeptThePriorAccountsCacheApartKeepItAsALocalCopyOrRemoveItFromThisMac)
        case nil:
            ""
        }
    }

    var showsResolutionActions: Bool {
        notice == .signedOut || notice == .accountChanged
    }

    func resolve(_ choice: AppleAccountCacheChoice) async {
        guard let handler, notice != nil, !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            try await handler.resolveAppleAccountCache(choice)
            notice = try await handler.refreshAppleAccountNotice()
            errorMessage = nil
        } catch {
            errorMessage = String(localized: .snipSnapCouldNotFinishThatChoicePleaseTryAgain)
        }
    }

    func refresh() async {
        guard let handler, !isResolving else { return }
        do {
            notice = try await handler.refreshAppleAccountNotice()
            errorMessage = nil
        } catch {
            // Keep the last safe state. Account lookup failures must not prompt removal.
        }
    }
}

struct AppleAccountNoticeView: View {
    let model: AppleAccountNoticeModel
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.needsAttention)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Label(
                model.title,
                systemImage: model.notice == .paused
                    ? "icloud.slash" : "person.crop.circle.badge.exclamationmark"
            )
                .font(.headline)
            Text(model.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.showsResolutionActions {
                HStack(spacing: 12) {
                    Button(.keepLocalCopy) {
                        Task { await model.resolve(.keepLocalCopy) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("keep-account-cache")
                    Button(.remove, role: .destructive) {
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

private actor UITestAppleAccountCacheHandler: AppleAccountCacheHandling {
    private var didResolve = false
    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
        didResolve ? nil : .signedOut
    }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {
        didResolve = true
    }
}

private struct UpdateCommands: Commands {
    let updaterController: SPUStandardUpdaterController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(.checkForUpdates) {
                updaterController.checkForUpdates(nil)
            }
        }
    }
}

private struct ShortcutCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            SettingsLink {
                Text(.actionOpenKeyboardShortcuts)
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

enum BackupImportCommandRoute: CaseIterable {
    case previewThenConfirm

    var title: String { String(localized: .actionImportBackup) }
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
            Button(.search) { coordinator.focusPanelSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu(.snips) {
            Button(BackupImportCommandRoute.previewThenConfirm.title) {
                model?.beginBackupImport()
            }
                .disabled(model == nil)
            Divider()
            Button(SnipCommand.copy.title) { perform(.copy) }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!isAvailable(.copy))
            Divider()
            Button(SnipCompletionLanguage.toggle) { perform(.toggleDone) }
                .appKeyboardShortcut(coordinator.shortcutSettings.chord(for: .toggleDone))
                .disabled(!isAvailable(.toggleDone))
            Button(SnipCommand.edit.title) { perform(.edit) }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isAvailable(.edit))
            Button(SnipCommand.editInNewWindow.title) { perform(.editInNewWindow) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isAvailable(.editInNewWindow))
            Button(SnipCommand.merge.title) { perform(.merge) }
                .appKeyboardShortcut(coordinator.shortcutSettings.chord(for: .merge))
                .disabled(!isAvailable(.merge))
            Divider()
            Button(.moveUp) { model?.moveSelectionUp() }
                .disabled(model?.canReorderSelection != true)
            Button(.moveDown) { model?.moveSelectionDown() }
                .disabled(model?.canReorderSelection != true)
            Divider()
            Button(SnipCommand.delete.title) { perform(.delete) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!isAvailable(.delete))
            Button(.actionExportBackup) {
                exportJSONBackup(from: applicationModel)
            }
        }
    }

    private func isAvailable(_ command: SnipCommand) -> Bool {
        model.map { command.isAvailable(for: $0.selection.count) } ?? false
    }

    private func perform(_ command: SnipCommand) {
        guard let model else { return }
        SnipCommandDispatcher(model: model, coordinator: coordinator).perform(command)
    }

    private func exportJSONBackup(from model: AppModel) {
        let panel = NSSavePanel()
        panel.title = String(localized: .dialogExportBackupTitle)
        panel.prompt = String(localized: .export)
        panel.nameFieldStringValue = String(localized: .snipSnapBackup)
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
