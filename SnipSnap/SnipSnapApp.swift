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
                coordinator: appDelegate.coordinator,
                accountNoticeModel: appDelegate.accountNoticeModel,
                cloudSyncHandler: appDelegate.cloudSyncHandler
            )
        }
        .defaultSize(width: 400, height: 230)
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
    @State var accountNoticeModel: AppleAccountNoticeModel?
    let cloudSyncHandler: (any OptionalCloudSyncHandling)?
    @State private var isClearingDownloads = false
    @State private var clearDownloadsError: String?

    var body: some View {
        VStack(spacing: 0) {
            if let accountNoticeModel, accountNoticeModel.notice != nil {
                AppleAccountNoticeView(
                    model: accountNoticeModel,
                    accessibilityIdentifier: "apple-account-notice-settings"
                )
                Divider()
            }
            ShortcutSettingsView(coordinator: coordinator)
            if let cloudSyncHandler {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("iCloud Attachments")
                            .font(.headline)
                        Text("Downloaded files can be fetched again when you open them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isClearingDownloads ? "Clearing…" : "Clear Downloaded Files") {
                        isClearingDownloads = true
                        clearDownloadsError = nil
                        Task {
                            do {
                                try await cloudSyncHandler.clearDownloadedFiles()
                                clearDownloadsError = nil
                            } catch {
                                clearDownloadsError = "Snip Snap could not clear the downloaded files."
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
    let accountNoticeModel: AppleAccountNoticeModel?
    let cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private var mainPanel: SnipSnapPanel?
    private var isFlushingBeforeTermination = false

    override init() {
        let isReleaseApp = Bundle.main.bundleIdentifier == "world.sree.snipsnap"
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
        let model = AppModel(library: library, initialError: initialError)
        let shortcutSettings = ShortcutSettings()
        let fileDropController = PanelFileDropController()
        let snipDragSourceController = SnipDragSourceController()
        self.model = model
        self.shortcutSettings = shortcutSettings
        self.fileDropController = fileDropController
        self.snipDragSourceController = snipDragSourceController
        updateChecksEnabled = isReleaseApp &&
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        let productionCloudSyncHandler = Self.makeAccountCacheHandler()
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
        Task { [cloudSyncHandler, accountNoticeModel] in
            await cloudSyncHandler?.syncWhenPossible()
            await accountNoticeModel?.refresh()
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
        Task { [cloudSyncHandler, accountNoticeModel] in
            await cloudSyncHandler?.syncWhenPossible()
            await accountNoticeModel?.refresh()
        }
    }

    private static func makeAccountCacheHandler() -> AppleAccountCacheCoordinatorHandler? {
        guard let containerIdentifier = Bundle.main.object(
            forInfoDictionaryKey: "SnipSnapCloudKitContainerIdentifier"
        ) as? String else { return nil }
        let syncRootURL = JSONSnipLibrary.defaultStoreURL()
            .deletingLastPathComponent()
            .appendingPathComponent("SyncMode", isDirectory: true)
        return AppleAccountCacheCoordinatorHandler(
            syncRootURL: syncRootURL,
            containerIdentifier: containerIdentifier
        )
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
        case .paused: "iCloud Sync Paused"
        case .signedOut: "Signed Out of iCloud"
        case .accountChanged: "Apple Account Changed"
        case nil: ""
        }
    }

    var message: String {
        switch notice {
        case .paused:
            "Your synced cache is still on this Mac. Snip Snap will try again when iCloud is available."
        case .signedOut, .accountChanged:
            "Snip Snap kept the prior account’s cache apart. Keep it as a local copy or remove it from this Mac."
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
            errorMessage = "Snip Snap could not finish that choice. Please try again."
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
            Text("Needs Attention")
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
