import AppKit
import SnipSnapCore
import ApplicationServices
import Carbon.HIToolbox
import Combine
import SwiftUI

enum PanelFocusRequest {
    case search
    case inlineEntry
}

enum PanelDialogID: Equatable {
    case newList
    case recovery
    case accessibility
    case editList(UUID)
    case backupImport
    case clearClipboardHistory
    case deleteList(UUID)
    case error
}

@MainActor
private struct PendingPanelDialog {
    let id: PanelDialogID
    let title: String
    let content: AnyView
    let onDismiss: () -> Void
}

@MainActor
final class PanelDialogPresentationState: ObservableObject {
    @Published fileprivate(set) var isPresented = false
}

enum SelectionAttachmentStagingError: Error, Equatable, Sendable {
    case writeFailed
}

@MainActor
final class AppCoordinator {
    typealias BeginFilePanel = (
        NSSavePanel,
        NSWindow,
        @escaping (NSApplication.ModalResponse) -> Void
    ) -> Void

    private let model: AppModel
    let shortcutSettings: ShortcutSettings
    private let makeHotKeyManager: (@escaping (GlobalHotKeyAction) -> Void) -> any GlobalHotKeyManaging
    let accessibilityPermissions: AccessibilityPermissionController
    private let selectionReader = AccessibilitySelectionReader()
    private let hud = CaptureHUDController()
    let panelFocusRequests = PassthroughSubject<PanelFocusRequest, Never>()
    private var hotKeys: (any GlobalHotKeyManaging)?
    private weak var panelWindow: NSWindow?
    let panelDialogs = PanelDialogPresentationState()
    private let panelDialogPresenter = PanelDialogPresenter()
    private var requestedPanelComposerExpansion: CGFloat = 0
    private var appliedPanelComposerExpansion: CGFloat = 0
    private var previousExternalApplication: NSRunningApplication?
    private var applicationActivationObserver: NSObjectProtocol?
    private let beginFilePanel: BeginFilePanel
    private let cancelFilePanel: (NSSavePanel) -> Void
    private var presentedFilePanel: NSSavePanel?
    private var filePanelCompletion: ((NSApplication.ModalResponse) -> Void)?
    private var pendingPanelDialogs: [PendingPanelDialog] = []
    private var panelUsabilitySubscriptions: Set<AnyCancellable> = []

    init(
        model: AppModel,
        shortcutSettings: ShortcutSettings,
        makeHotKeyManager: @escaping (
            @escaping (GlobalHotKeyAction) -> Void
        ) -> any GlobalHotKeyManaging = { GlobalHotKeyManager(handler: $0) },
        isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        requestAccessibilityTrust: @escaping () -> Void = {
            _ = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            )
        },
        openAccessibilitySettings: @escaping () -> Void = {
            let pane = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
            )
            if let pane, NSWorkspace.shared.open(pane) { return }
            _ = NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/System Settings.app")
            )
        },
        accessibilitySetupDefaults: UserDefaults = .standard,
        accessibilityNotificationCenter: NotificationCenter = .default,
        beginFilePanel: @escaping BeginFilePanel = { panel, parent, completion in
            panel.beginSheetModal(for: parent, completionHandler: completion)
        },
        cancelFilePanel: @escaping (NSSavePanel) -> Void = { panel in
            panel.cancel(nil)
        }
    ) {
        self.model = model
        self.shortcutSettings = shortcutSettings
        self.makeHotKeyManager = makeHotKeyManager
        self.beginFilePanel = beginFilePanel
        self.cancelFilePanel = cancelFilePanel
        accessibilityPermissions = AccessibilityPermissionController(
            defaults: accessibilitySetupDefaults,
            notificationCenter: accessibilityNotificationCenter,
            isTrusted: isAccessibilityTrusted,
            requestTrust: requestAccessibilityTrust,
            openSettings: openAccessibilitySettings
        )
        accessibilityPermissions.onBecameGranted = { [weak self] in
            self?.restartShortcutsAfterAccessibilityGrant()
        }
    }

    func start() {
        observeExternalApplicationActivations()
        accessibilityPermissions.start()
        guard hotKeys == nil else { return }
        refreshAppShortcutMenu()
        let manager = newHotKeyManager()
        do {
            try manager.register(configuration: shortcutSettings.configuration)
            hotKeys = manager
        } catch {
            model.presentError(String(localized: "Couldn’t enable keyboard shortcuts. Try again."))
        }
        if accessibilityPermissions.isSetupCardVisible, let panelWindow {
            showPanel(panelWindow, focusing: nil)
        }
    }

    func setShortcut(_ trigger: ShortcutTrigger, for action: GlobalHotKeyAction) throws {
        let configuration = try shortcutSettings.candidate(setting: trigger, for: action)
        try installShortcuts(configuration)
        shortcutSettings.save(configuration)
    }

    func setShortcut(_ chord: ShortcutKeyChord, for action: AppShortcutAction) throws {
        shortcutSettings.save(try shortcutSettings.candidate(setting: chord, for: action))
        refreshAppShortcutMenu()
    }

    func resetShortcut(_ action: AppShortcutAction) throws {
        try shortcutSettings.reset(action)
        refreshAppShortcutMenu()
    }

    func togglePanel() {
        guard let panelWindow else { return }
        if Self.shouldHidePanel(
            isDialogPresented: panelDialogs.isPresented,
            isVisible: panelWindow.isVisible,
            isMiniaturized: panelWindow.isMiniaturized,
            isOnActiveSpace: panelWindow.isOnActiveSpace
        ) {
            hidePanel(
                restoringPreviousApplication: Self.shouldRestorePreviousApplication(
                    panelIsKey: panelWindow.isKeyWindow,
                    dialogIsKey: panelDialogPresenter.isKeyWindow,
                    filePanelIsKey: presentedFilePanel?.isKeyWindow == true
                )
            )
            return
        }
        showPanel(panelWindow, focusing: .inlineEntry)
    }

    func toggleClipboard() {
        guard let panelWindow else { return }
        guard !panelDialogs.isPresented else { return }
        if model.isShowingClipboard,
           Self.shouldHidePanel(
               isVisible: panelWindow.isVisible,
               isMiniaturized: panelWindow.isMiniaturized,
               isOnActiveSpace: panelWindow.isOnActiveSpace
           ) {
            hidePanel(restoringPreviousApplication: panelWindow.isKeyWindow)
            return
        }
        model.showClipboard()
        model.query = ""
        showPanel(panelWindow, focusing: .search)
    }

    private func showPanel(_ panelWindow: NSWindow, focusing target: PanelFocusRequest?) {
        previousExternalApplication = frontmostExternalApplication()
        NSApp.activate(ignoringOtherApps: true)
        if panelWindow.isMiniaturized {
            panelWindow.deminiaturize(nil)
        } else if panelWindow.isVisible && !panelWindow.isOnActiveSpace {
            panelWindow.orderOut(nil)
        }
        panelWindow.makeKeyAndOrderFront(nil)
        if !presentNextPendingPanelDialog() {
            updatePresentedError()
        }
        if let target {
            DispatchQueue.main.async { [weak self] in
                self?.panelFocusRequests.send(target)
            }
        }
    }

    nonisolated static func shouldHidePanel(
        isDialogPresented: Bool = false,
        isVisible: Bool,
        isMiniaturized: Bool,
        isOnActiveSpace: Bool
    ) -> Bool {
        isDialogPresented || (isVisible && !isMiniaturized && isOnActiveSpace)
    }

    nonisolated static func shouldRestorePreviousApplication(
        panelIsKey: Bool,
        dialogIsKey: Bool,
        filePanelIsKey: Bool = false
    ) -> Bool {
        panelIsKey || dialogIsKey || filePanelIsKey
    }

    nonisolated static func shouldPresentPendingError(
        isVisible: Bool,
        isMiniaturized: Bool,
        isOnActiveSpace: Bool
    ) -> Bool {
        isVisible && !isMiniaturized && isOnActiveSpace
    }

    func focusPanelSearch() {
        guard !panelDialogs.isPresented else { return }
        panelFocusRequests.send(.search)
    }

    func setSnipCommandFocusActive(_ isActive: Bool) {
        if isActive {
            refreshAppShortcutMenu()
        }
    }

    func hidePanel(restoringPreviousApplication: Bool = true) {
        dismissFilePanel()
        dismissPendingPanelDialogs()
        panelDialogPresenter.dismissForParentHide()
        panelWindow?.orderOut(nil)
        if restoringPreviousApplication {
            previousExternalApplication?.activate(options: [])
        }
        previousExternalApplication = nil
    }

    @discardableResult
    func copyClipboardEntry(_ entry: ClipboardEntry) -> Bool {
        model.placeOnClipboard(.clipboardEntry(entry), feedback: .notify)
    }

    func captureSelection() {
        guard !panelDialogs.isPresented else { return }
        guard accessibilityPermissions.refresh() else {
            presentAccessibilityRepair()
            return
        }
        guard let sourceApplication = frontmostExternalApplication() else {
            hud.show(
                message: SelectionCaptureFailure.sourceUnavailable.localizedDescription,
                symbol: "exclamationmark"
            )
            return
        }
        let requestID = UUID()
        let name = sourceApplication.localizedName ?? String(localized: "Unknown app")
        let clipboardHistory = model.clipboardHistory
        let suppressionToken = clipboardHistory.beginSuppression()
        selectionReader.capture(
            processID: sourceApplication.processIdentifier,
            applicationName: name
        ) { [weak self] result in
            Task { @MainActor in
                clipboardHistory.endSuppression(suppressionToken)
                guard let self else { return }
                switch result {
                case .success(let capture):
                    let staging = await Task.detached(priority: .userInitiated) {
                        Self.writeTemporaryAttachments(
                            capture.attachments,
                            requestID: requestID
                        )
                    }.value
                    guard case .success(let temporaryAttachments) = staging else {
                        let message = String(localized: "Couldn’t prepare the captured images. Try again.")
                        self.model.presentError(message)
                        self.hud.show(message: message, symbol: "exclamationmark")
                        return
                    }
                    defer {
                        if let directory = temporaryAttachments.directory {
                            try? FileManager.default.removeItem(at: directory)
                        }
                    }
                    let outcome = await self.model.addResult(
                        content: capture.content,
                        origin: .selection,
                        source: capture.source,
                        attachmentURLs: temporaryAttachments.urls,
                        requestID: requestID
                    )
                    switch outcome {
                    case .success(.added):
                        self.hud.show(message: String(localized: "Captured"), symbol: "checkmark")
                    case .success(.duplicate):
                        self.hud.show(message: String(localized: "Already captured"), symbol: "minus")
                    case .failure(let error):
                        self.model.presentError(error)
                        self.hud.show(
                            message: error.localizedDescription,
                            symbol: "exclamationmark"
                        )
                    }
                case .failure(let error):
                    if error == .accessibilityPermissionRequired {
                        self.presentAccessibilityRepair()
                        return
                    }
                    self.hud.show(
                        message: error.localizedDescription,
                        symbol: error == .duplicateSelection ? "minus" : "exclamationmark"
                    )
                }
            }
        }
    }

    private func presentAccessibilityRepair() {
        accessibilityPermissions.presentRepair()
        guard let panelWindow else { return }
        showPanel(panelWindow, focusing: nil)
    }

    private func restartShortcutsAfterAccessibilityGrant() {
        guard hotKeys != nil else { return }
        do {
            try installShortcuts(shortcutSettings.configuration)
        } catch {
            model.presentError(String(
                localized: "Couldn’t restart keyboard shortcuts. Try again."
            ))
        }
    }

    nonisolated static func writeTemporaryAttachments(
        _ attachments: [SelectionCaptureAttachment],
        requestID: UUID,
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Result<(directory: URL?, urls: [URL]), SelectionAttachmentStagingError> {
        guard !attachments.isEmpty else { return .success((nil, [])) }
        let directory = baseDirectory
            .appendingPathComponent("Snip SnapSelection-\(requestID.uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var urls: [URL] = []
            for (index, attachment) in attachments.enumerated() {
                let fileName = attachment.fileName
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "\0", with: "")
                let url = directory.appendingPathComponent(
                    "\(index + 1)-\(fileName.isEmpty ? "Attachment" : fileName)"
                )
                try attachment.data.write(to: url, options: .atomic)
                urls.append(url)
            }
            return .success((directory, urls))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return .failure(.writeFailed)
        }
    }

    func attachPanelWindow(_ window: NSWindow) {
        panelWindow = window
        observePanelUsability(window)
        appliedPanelComposerExpansion = 0
        applyPanelComposerExpansion()
    }

    private func observePanelUsability(_ window: NSWindow) {
        panelUsabilitySubscriptions.removeAll()
        let windowNotifications = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification
        ].map { notification in
            NotificationCenter.default.publisher(for: notification, object: window)
                .eraseToAnyPublisher()
        }
        Publishers.MergeMany(windowNotifications)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.retryPendingPanelWork() }
            }
            .store(in: &panelUsabilitySubscriptions)
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.activeSpaceDidChangeNotification
        )
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.retryPendingPanelWork() }
        }
        .store(in: &panelUsabilitySubscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.retryPendingPanelWork() }
            }
            .store(in: &panelUsabilitySubscriptions)
    }

    private func retryPendingPanelWork() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.presentNextPendingPanelDialog() {
                self.updatePresentedError()
            }
        }
    }

    func presentPanelDialog<Content: View>(
        id: PanelDialogID,
        title: String,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        let request = PendingPanelDialog(
            id: id,
            title: title,
            content: AnyView(
                PanelDialogContent(
                    model: model,
                    showsModelErrors: id != .error,
                    content: content()
                )
                    .tint(SnipSnapTheme.controlTint)
                    .preferredColorScheme(model.appearance.colorScheme)
            ),
            onDismiss: onDismiss
        )
        guard presentedFilePanel == nil,
              !panelDialogs.isPresented,
              let panelWindow,
              Self.shouldPresentPendingError(
                  isVisible: panelWindow.isVisible,
                  isMiniaturized: panelWindow.isMiniaturized,
                  isOnActiveSpace: panelWindow.isOnActiveSpace
              ) else {
            enqueuePanelDialog(request)
            return
        }
        showPanelDialog(request)
    }

    private func showPanelDialog(_ request: PendingPanelDialog) {
        guard let panelWindow else { return }
        panelDialogPresenter.present(
            id: request.id,
            title: request.title,
            parent: panelWindow,
            content: request.content,
            onDismiss: { [weak self] reason in
                guard let self else { return }
                panelDialogs.isPresented = false
                if request.id != .error || reason != .parentHide {
                    request.onDismiss()
                }
                if reason == .close {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if !self.presentNextPendingPanelDialog() {
                            self.updatePresentedError()
                        }
                    }
                }
            }
        )
        panelDialogs.isPresented = true
    }

    private func enqueuePanelDialog(_ request: PendingPanelDialog) {
        pendingPanelDialogs.removeAll { $0.id == request.id }
        pendingPanelDialogs.append(request)
    }

    @discardableResult
    private func presentNextPendingPanelDialog() -> Bool {
        guard presentedFilePanel == nil,
              !panelDialogs.isPresented,
              let panelWindow,
              Self.shouldPresentPendingError(
                  isVisible: panelWindow.isVisible,
                  isMiniaturized: panelWindow.isMiniaturized,
                  isOnActiveSpace: panelWindow.isOnActiveSpace
              ),
              !pendingPanelDialogs.isEmpty else { return false }
        let request = pendingPanelDialogs.removeFirst()
        showPanelDialog(request)
        return true
    }

    private func dismissPendingPanelDialogs() {
        let requests = pendingPanelDialogs
        pendingPanelDialogs.removeAll()
        for request in requests where request.id != .error {
            request.onDismiss()
        }
    }

    @discardableResult
    func presentOpenPanel(
        _ panel: NSOpenPanel,
        completion: @escaping ([URL]?) -> Void
    ) -> Bool {
        presentFilePanel(panel) { [weak panel] response in
            completion(response == .OK ? panel?.urls : nil)
        }
    }

    @discardableResult
    func presentSavePanel(
        _ panel: NSSavePanel,
        completion: @escaping (URL?) -> Void
    ) -> Bool {
        presentFilePanel(panel) { [weak panel] response in
            completion(response == .OK ? panel?.url : nil)
        }
    }

    private func presentFilePanel(
        _ panel: NSSavePanel,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) -> Bool {
        guard !panelDialogs.isPresented, presentedFilePanel == nil else { return false }
        guard let panelWindow else { return false }
        if !Self.shouldPresentPendingError(
            isVisible: panelWindow.isVisible,
            isMiniaturized: panelWindow.isMiniaturized,
            isOnActiveSpace: panelWindow.isOnActiveSpace
        ) {
            showPanel(panelWindow, focusing: nil)
        }
        guard !panelDialogs.isPresented else { return false }
        presentedFilePanel = panel
        filePanelCompletion = completion
        panelDialogs.isPresented = true
        beginFilePanel(panel, panelWindow) { [weak self, weak panel] response in
            Task { @MainActor in
                guard let self, let panel, self.presentedFilePanel === panel else { return }
                self.finishFilePanel(panel, response: response, updateError: true)
            }
        }
        return true
    }

    private func dismissFilePanel() {
        guard let panel = presentedFilePanel else { return }
        cancelFilePanel(panel)
        finishFilePanel(panel, response: .cancel, updateError: false)
    }

    private func finishFilePanel(
        _ panel: NSSavePanel,
        response: NSApplication.ModalResponse,
        updateError: Bool
    ) {
        guard presentedFilePanel === panel else { return }
        let completion = filePanelCompletion
        presentedFilePanel = nil
        filePanelCompletion = nil
        panelDialogs.isPresented = false
        completion?(response)
        if updateError, !presentNextPendingPanelDialog() { updatePresentedError() }
    }

    func dismissPanelDialog(id: PanelDialogID, restoringParent: Bool = true) {
        pendingPanelDialogs.removeAll { $0.id == id }
        panelDialogPresenter.dismiss(id: id, restoringParent: restoringParent)
    }

    func updatePresentedError() {
        guard model.presentedError != nil else {
            dismissPanelDialog(id: .error)
            return
        }
        guard let panelWindow,
              Self.shouldPresentPendingError(
                  isVisible: panelWindow.isVisible,
                  isMiniaturized: panelWindow.isMiniaturized,
                  isOnActiveSpace: panelWindow.isOnActiveSpace
              ) else { return }
        guard !panelDialogs.isPresented else { return }
        presentPanelDialog(
            id: .error,
            title: model.presentedErrorTitle ?? String(localized: "Something Went Wrong")
        ) { [weak model] in
            model?.dismissPresentedError()
        } content: {
            PanelErrorDialog(model: model)
        }
    }

    func updatePanelComposerExpansion(_ expansion: CGFloat) {
        requestedPanelComposerExpansion = max(expansion, 0)
        applyPanelComposerExpansion()
    }

    func savePanelWindowFrame(using frameAutosaveName: NSWindow.FrameAutosaveName) {
        requestedPanelComposerExpansion = 0
        applyPanelComposerExpansion()
        panelWindow?.saveFrame(usingName: frameAutosaveName)
    }

    func isPanelWindow(_ window: NSWindow?) -> Bool {
        window === panelWindow
    }

    private func applyPanelComposerExpansion() {
        guard let panelWindow else { return }
        let requestedExpansion = requestedPanelComposerExpansion
        let requestedDelta = requestedExpansion - appliedPanelComposerExpansion
        guard abs(requestedDelta) >= 0.5 else { return }

        var frame = panelWindow.frame
        let targetHeight = max(panelWindow.minSize.height, frame.height + requestedDelta)
        let appliedDelta = targetHeight - frame.height
        frame.origin.y -= appliedDelta
        frame.size.height = targetHeight
        appliedPanelComposerExpansion = requestedExpansion
        panelWindow.setFrame(frame, display: panelWindow.isVisible, animate: false)
    }

    private func handle(_ action: GlobalHotKeyAction) {
        switch action {
        case .captureSelection:
            captureSelection()
        case .togglePanel:
            togglePanel()
        case .toggleClipboard:
            toggleClipboard()
        }
    }

    private func refreshAppShortcutMenu() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let mainMenu = NSApp.mainMenu else { return }
            for action in AppShortcutAction.allCases {
                guard let item = mainMenu.item(withTitle: action.title, recursively: true) else {
                    continue
                }
                let chord = self.shortcutSettings.chord(for: action)
                item.keyEquivalent = chord.menuKeyEquivalent
                item.keyEquivalentModifierMask = chord.eventModifierFlags
            }
        }
    }

    private func installShortcuts(_ configuration: GlobalShortcutConfiguration) throws {
        let previous = shortcutSettings.configuration
        hotKeys?.unregister()
        hotKeys = nil

        let replacement = newHotKeyManager()
        do {
            try replacement.register(configuration: configuration)
            hotKeys = replacement
        } catch {
            replacement.unregister()
            let rollback = newHotKeyManager()
            do {
                try rollback.register(configuration: previous)
                hotKeys = rollback
            } catch {
                hotKeys = nil
            }
            throw error
        }
    }

    private func newHotKeyManager() -> any GlobalHotKeyManaging {
        makeHotKeyManager { [weak self] action in
            DispatchQueue.main.async {
                self?.handle(action)
            }
        }
    }

    private func frontmostExternalApplication() -> NSRunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return application
    }

    private func observeExternalApplicationActivations() {
        guard applicationActivationObserver == nil else { return }
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return
            }
            Task { @MainActor [weak self] in
                self?.previousExternalApplication = application
            }
        }
    }

}

private struct PanelDialogContent<Content: View>: View {
    @ObservedObject var model: AppModel
    let showsModelErrors: Bool
    let content: Content

    var body: some View {
        content
            .alert(
                model.presentedErrorTitle ?? String(localized: "Something Went Wrong"),
                isPresented: Binding(
                    get: { showsModelErrors && model.presentedError != nil },
                    set: { _ in }
                )
            ) {
                Button("OK", role: .cancel) { model.dismissPresentedError() }
            } message: {
                Text(model.presentedError ?? "")
            }
    }
}

private struct PanelErrorDialog: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.paneContentInset) {
            Text(model.presentedErrorTitle ?? String(localized: "Something Went Wrong"))
                .font(.headline)
            Text(model.presentedError ?? "")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                AppPrimaryActionButton(action: model.dismissPresentedError) {
                    Text("OK")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SnipSnapSpacing.paneContentInset)
        .onExitCommand(perform: model.dismissPresentedError)
    }
}

struct PanelConfirmationDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    var isDestructive = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.paneContentInset) {
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if isDestructive {
                    Button(confirmTitle, role: .destructive, action: onConfirm)
                        .buttonStyle(.bordered)
                } else {
                    AppPrimaryActionButton(action: onConfirm) {
                        Text(confirmTitle)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(SnipSnapSpacing.paneContentInset)
    }
}

private struct PanelDialogGlassSurface: View {
    let content: AnyView

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: PanelShapeMetrics.paneCornerRadius,
            style: .continuous
        )
        content
            .frame(width: PanelDialogMetrics.width)
            .background {
                shape
                    .fill(.clear)
                    .panelGlassSurface(
                        in: shape,
                        tint: SnipSnapColors.nestedGlassTint
                    )
            }
            .clipShape(shape)
    }
}

@MainActor
private enum PanelDialogDismissalReason {
    case close
    case parentHide
}

private final class PanelDialogWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class PanelDialogPresenter {
    private var id: PanelDialogID?
    private weak var parentWindow: NSWindow?
    private var restoresParentOnDismissal = true
    private var dismissalReason = PanelDialogDismissalReason.close
    private var windowController: NSWindowController?
    private var onDismiss: ((PanelDialogDismissalReason) -> Void)?

    var isKeyWindow: Bool {
        windowController?.window?.isKeyWindow == true
    }

    func present(
        id: PanelDialogID,
        title: String,
        parent: NSWindow,
        content: AnyView,
        onDismiss: @escaping (PanelDialogDismissalReason) -> Void
    ) {
        guard windowController == nil else { return }

        let hostingController = NSHostingController(
            rootView: PanelDialogGlassSurface(content: content)
        )
        let window = PanelDialogWindow(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.animationBehavior = .utilityWindow
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController

        hostingController.view.layoutSubtreeIfNeeded()
        let size = hostingController.view.fittingSize
        window.setContentSize(size)

        self.parentWindow = parent
        self.id = id
        self.onDismiss = onDismiss
        windowController = NSWindowController(window: window)
        parent.beginSheet(window) { [weak self, weak window] _ in
            guard let self, let window else { return }
            window.close()
            self.finishDismissal(for: window)
        }
    }

    func dismiss(id: PanelDialogID, restoringParent: Bool = true) {
        guard self.id == id else { return }
        dismissCurrent(restoringParent: restoringParent)
    }

    func dismissForParentHide() {
        dismissCurrent(restoringParent: false, reason: .parentHide)
    }

    private func dismissCurrent(
        restoringParent: Bool = true,
        reason: PanelDialogDismissalReason = .close
    ) {
        guard let window = windowController?.window else { return }
        restoresParentOnDismissal = restoringParent
        dismissalReason = reason
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.close()
            finishDismissal(for: window)
        }
    }

    private func finishDismissal(for window: NSWindow) {
        guard windowController?.window === window else { return }
        let callback = onDismiss
        let reason = dismissalReason
        if restoresParentOnDismissal, parentWindow?.isVisible == true {
            parentWindow?.makeKeyAndOrderFront(nil)
        }
        windowController = nil
        parentWindow = nil
        restoresParentOnDismissal = true
        dismissalReason = .close
        id = nil
        onDismiss = nil
        callback?(reason)
    }
}

private extension NSMenu {
    func item(withTitle title: String, recursively: Bool) -> NSMenuItem? {
        if let item = items.first(where: { $0.title == title }) {
            return item
        }
        guard recursively else { return nil }
        for item in items {
            if let match = item.submenu?.item(withTitle: title, recursively: true) {
                return match
            }
        }
        return nil
    }
}
