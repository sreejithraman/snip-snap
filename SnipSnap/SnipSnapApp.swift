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
                coordinator: appDelegate.coordinator
            )
        }
        .defaultSize(width: 440, height: 290)
        .windowResizability(.contentSize)
        .commands {
            SnipCommands(coordinator: appDelegate.coordinator)
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

    var body: some View {
        TabView {
            ShortcutSettingsView(coordinator: coordinator)
                .environmentObject(shortcutSettings)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            SyncedContentSettingsView(model: syncedContentSettings)
                .tabItem { Label("Sync", systemImage: "icloud") }
        }
        .preferredColorScheme(model.appearance.colorScheme)
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
    private var mainPanel: SnipSnapPanel?
    private var isFlushingBeforeTermination = false

    override init() {
        let isReleaseApp = Bundle.main.bundleIdentifier == "world.sree.snipsnap"
        let libraryStoreURL = JSONSnipLibrary.defaultStoreURL()
        let library: JSONSnipLibrary
        let initialError: String?
        do {
            let result = try JSONSnipLibrary.openRecoveringCorruptStore()
            library = result.repository
            if let backupURL = result.backupURL {
                initialError = "Snip Snap kept the unreadable snips file as \(backupURL.lastPathComponent) and started a new one."
            } else {
                initialError = nil
            }
        } catch {
            library = JSONSnipLibrary.unavailable()
            initialError = "Snip Snap could not read or safely back up its snips file. Snip Snap cannot save new snips."
        }
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
            initialError: initialError,
            recoveryScope: assembly.recoveryScope
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
        updaterController = SPUStandardUpdaterController(
            startingUpdater: updateChecksEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        coordinator = AppCoordinator(model: model, shortcutSettings: shortcutSettings)
        cloudLifecycleHooks = SnipSnapCloudLifecycleHooks {
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
                }
            } catch {
                model.presentedError = error.localizedDescription
            }
        }
        if let cloudSyncSession {
            let reloadActiveLibrary: SyncedContentSettingsModel.DeleteCompletionAction = {
                let active = try await cloudSyncSession.activeLibrary()
                await model.replaceLibrary(
                    active.library,
                    recoveryScope: active.recoveryScope
                )
            }
            syncedContentSettings.setEnableCompletionAction(reloadActiveLibrary)
            syncedContentSettings.setDeleteCompletionAction(reloadActiveLibrary)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        let rootView = ContentView(
                coordinator: coordinator,
                fileDropController: fileDropController,
                snipDragSourceController: snipDragSourceController
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
        Task { await cloudLifecycleHooks.launch() }
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
        Task { await cloudLifecycleHooks.foreground() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFlushingBeforeTermination else { return .terminateLater }
        isFlushingBeforeTermination = true
        coordinator.savePanelWindowFrame(using: AppWindowDefaults.frameAutosaveName)
        Task { @MainActor [model] in
            model.flushComposerDrafts()
            await model.clipboardHistory.flushPersistence()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

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
    let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Search") { coordinator.focusPanelSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
        if let model {
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoTitle) {
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                Button(model.redoTitle) {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            }
        }
        CommandMenu("Snips") {
            Button(SnipCommand.copy.title) { perform(.copy) }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!isAvailable(.copy))
            Divider()
            Button("Done or Not Done") { perform(.toggleDone) }
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
            Button("Move Up") { model?.moveSelectionUp() }
                .disabled(model?.canReorderSelection != true)
            Button("Move Down") { model?.moveSelectionDown() }
                .disabled(model?.canReorderSelection != true)
            Divider()
            Button(SnipCommand.delete.title) { perform(.delete) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!isAvailable(.delete))
        }
    }

    private func isAvailable(_ command: SnipCommand) -> Bool {
        model.map { command.isAvailable(for: $0.selection.count) } ?? false
    }

    private func perform(_ command: SnipCommand) {
        guard let model else { return }
        SnipCommandDispatcher(model: model, coordinator: coordinator).perform(command)
    }
}
