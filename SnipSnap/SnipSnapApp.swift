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
        .defaultSize(width: 400, height: 310)
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
    let snipDragSourceController: SnipDragSourceController
    let updaterController: SPUStandardUpdaterController
    let updateChecksEnabled: Bool
    private var mainPanel: SnipSnapPanel?
    private var isFlushingBeforeTermination = false

    override init() {
        let isReleaseApp = Bundle.main.bundleIdentifier == "world.sree.snipsnap"
        let model = AppModel()
        let shortcutSettings = ShortcutSettings()
        let fileDropController = PanelFileDropController()
        let snipDragSourceController = SnipDragSourceController()
        self.model = model
        self.shortcutSettings = shortcutSettings
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
                Text("Snip Snap Settings…")
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
