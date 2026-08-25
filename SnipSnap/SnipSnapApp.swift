import AppKit
import Sparkle
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
                coordinator: appDelegate.coordinator
            )
        }
        .defaultSize(width: 400, height: 230)
        .windowResizability(.contentSize)
        .commands {
            InboxCommands(coordinator: appDelegate.coordinator)
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
    let coordinator: AppCoordinator

    var body: some View {
        ShortcutSettingsView(coordinator: coordinator)
            .environmentObject(shortcutSettings)
            .preferredColorScheme(model.appearance.colorScheme)
    }
}

@MainActor
final class SnipSnapApplicationDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let shortcutSettings: ShortcutSettings
    let coordinator: AppCoordinator
    let fileDropController: PanelFileDropController
    let clipDragSourceController: ClipDragSourceController
    let updaterController: SPUStandardUpdaterController
    let updateChecksEnabled: Bool
    private var inboxPanel: SnipSnapPanel?
    private var isFlushingBeforeTermination = false

    override init() {
        let isReleaseApp = Bundle.main.bundleIdentifier == "world.sree.snipsnap"
        let model = AppModel()
        let shortcutSettings = ShortcutSettings()
        let fileDropController = PanelFileDropController()
        let clipDragSourceController = ClipDragSourceController()
        self.model = model
        self.shortcutSettings = shortcutSettings
        self.fileDropController = fileDropController
        self.clipDragSourceController = clipDragSourceController
        updateChecksEnabled = isReleaseApp &&
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        updaterController = SPUStandardUpdaterController(
            startingUpdater: updateChecksEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        coordinator = AppCoordinator(model: model, shortcutSettings: shortcutSettings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        let rootView = ContentView(
                coordinator: coordinator,
                fileDropController: fileDropController,
                clipDragSourceController: clipDragSourceController
            )
                .environmentObject(model)
                .environmentObject(shortcutSettings)
        let hostingView = PanelFileDropHostingView(
            rootView: rootView,
            controller: fileDropController,
            clipDragSourceController: clipDragSourceController
        )
        let hostingController = NSViewController()
        hostingController.view = hostingView
        let panel = SnipSnapPanel.make(
            contentViewController: hostingController,
            frameAutosaveName: AppWindowDefaults.frameAutosaveName
        )
        coordinator.attachInboxWindow(panel)
        coordinator.start()
        if !panel.restoredSavedFrame {
            panel.center()
        }
        inboxPanel = panel
#if DEBUG
        if ProcessInfo.processInfo.environment["SNIP_SNAP_SHOW_PANEL_ON_LAUNCH"] == "1" {
            panel.makeKeyAndOrderFront(nil)
        }
#endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFlushingBeforeTermination else { return .terminateLater }
        isFlushingBeforeTermination = true
        coordinator.saveInboxWindowFrame(using: AppWindowDefaults.frameAutosaveName)
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

private struct InboxCommandModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var inboxCommandModel: AppModel? {
        get { self[InboxCommandModelKey.self] }
        set { self[InboxCommandModelKey.self] = newValue }
    }
}

private struct InboxCommands: Commands {
    @FocusedValue(\.inboxCommandModel) private var model
    let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Search") { coordinator.focusInboxSearch() }
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
        CommandMenu("Items") {
            Button("Copy") { perform(.copy) }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!isAvailable(.copy))
            Divider()
            Button("Done or Not Done") { perform(.toggleDone) }
                .appKeyboardShortcut(coordinator.shortcutSettings.chord(for: .toggleDone))
                .disabled(!isAvailable(.toggleDone))
            Button("Edit") { perform(.edit) }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isAvailable(.edit))
            Button("Edit in New Window") { perform(.editInNewWindow) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isAvailable(.editInNewWindow))
            Button("Merge Clips") { perform(.merge) }
                .appKeyboardShortcut(coordinator.shortcutSettings.chord(for: .merge))
                .disabled(!isAvailable(.merge))
            Divider()
            Button("Move Up") { model?.moveSelectionUp() }
                .disabled(model?.canReorderSelection != true)
            Button("Move Down") { model?.moveSelectionDown() }
                .disabled(model?.canReorderSelection != true)
            Divider()
            Button("Delete") { perform(.delete) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!isAvailable(.delete))
        }
    }

    private func isAvailable(_ command: InboxItemCommand) -> Bool {
        model.map { command.isAvailable(for: $0.selection.count) } ?? false
    }

    private func perform(_ command: InboxItemCommand) {
        guard let model else { return }
        InboxItemCommandDispatcher(model: model, coordinator: coordinator).perform(command)
    }
}
