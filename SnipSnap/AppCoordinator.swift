import AppKit
import SnipSnapCore
import ApplicationServices
import Carbon.HIToolbox
import Combine
import SwiftUI

enum PanelFocusRequest {
    case clipboard
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
fileprivate struct PendingPanelDialog {
    let id: PanelDialogID
    let title: String
    let content: AnyView
    let onDismiss: () -> Void
}

@MainActor
fileprivate struct PanelDialogSession {
    let token = UUID()
    let request: PendingPanelDialog
}

@MainActor
fileprivate struct PanelFilePickerSession {
    let token = UUID()
    let panel: NSSavePanel
    let parent: NSWindow
    let parentAlphaValue: CGFloat
    let completion: (NSApplication.ModalResponse) -> Void
}

@MainActor
fileprivate enum ActivePanelPresentation {
    case idle
    case dialog(PanelDialogSession)
    case filePicker(PanelFilePickerSession)
    case hiding
}

@MainActor
final class PanelDialogPresentationState: ObservableObject {
    @Published fileprivate var active: ActivePanelPresentation = .idle

    var isPresented: Bool {
        if case .idle = active { return false }
        return true
    }
}

@MainActor
final class PanelSnipCommandFocusState: ObservableObject {
    @Published fileprivate(set) var isActive = false
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
    var clipboardHistory: ClipboardHistory { model.clipboardHistory }
    let shortcutSettings: ShortcutSettings
    private let makeHotKeyManager: (@escaping (GlobalHotKeyAction) -> Void) -> any GlobalHotKeyManaging
    let accessibilityPermissions: AccessibilityPermissionController
    private let selectionReader = AccessibilitySelectionReader()
    private let hud = CaptureHUDController()
    let panelFocusRequests = PassthroughSubject<PanelFocusRequest, Never>()
    private var hotKeys: (any GlobalHotKeyManaging)?
    private var hasStarted = false
    private var shortcutRecordingSubscription: AnyCancellable?
    private weak var panelWindow: NSWindow?
    let panelDialogs = PanelDialogPresentationState()
    let snipCommandFocus = PanelSnipCommandFocusState()
    private let panelDialogPresenter = PanelDialogPresenter()
    private var requestedPanelComposerExpansion: CGFloat = 0
    private var appliedPanelComposerExpansion: CGFloat = 0
    private var previousExternalApplication: NSRunningApplication?
    private var panelFocusRequestGeneration = 0
    private var applicationActivationObserver: NSObjectProtocol?
    private let beginFilePanel: BeginFilePanel
    private let cancelFilePanel: (NSSavePanel) -> Void
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
            panel.begin(completionHandler: completion)
            DispatchQueue.main.async { [weak panel, weak parent] in
                guard let panel, let parent, panel.isVisible else { return }
                AppCoordinator.positionFilePanel(panel, beside: parent)
            }
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
            self?.restartShortcuts()
        }
        model.cliDialogIsPresented = { [weak self] in
            guard let self else { return false }
            return panelDialogs.isPresented || !pendingPanelDialogs.isEmpty
        }
        shortcutRecordingSubscription = ShortcutRecordingState.changes.sink { [weak self] isActive in
            MainActor.assumeIsolated {
                guard let self, self.hasStarted else { return }
                if isActive {
                    self.hotKeys?.unregister()
                    self.hotKeys = nil
                } else {
                    self.restartShortcuts()
                }
            }
        }
    }

    private static func positionFilePanel(_ panel: NSSavePanel, beside parent: NSWindow) {
        let bounds = parent.screen?.visibleFrame ?? parent.frame
        let size = panel.frame.size
        let gap: CGFloat = 16
        let left = parent.frame.minX - size.width - gap
        let right = parent.frame.maxX + gap
        let x: CGFloat
        if left >= bounds.minX {
            x = left
        } else if right + size.width <= bounds.maxX {
            x = right
        } else {
            // The picker would obscure the dimmed panel on a narrow screen.
            parent.alphaValue = 0
            x = min(
                max(parent.frame.midX - size.width / 2, bounds.minX),
                max(bounds.minX, bounds.maxX - size.width)
            )
        }
        let y = min(
            max(parent.frame.midY - size.height / 2, bounds.minY),
            max(bounds.minY, bounds.maxY - size.height)
        )
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func start() {
        hasStarted = true
        observeExternalApplicationActivations()
        accessibilityPermissions.start()
        guard hotKeys == nil, !ShortcutRecordingState.isActive else { return }
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

    private var presentedFilePanelIsKey: Bool {
        guard case .filePicker(let session) = panelDialogs.active else { return false }
        return session.panel.isKeyWindow
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
                    filePanelIsKey: presentedFilePanelIsKey
                )
            )
            return
        }
        if model.editingID == nil {
            if model.isShowingClipboard {
                let activeList = model.lists.first(where: { $0.id == model.activeListID }) ?? .inbox
                model.selectList(activeList)
            }
            model.exitSearch()
        }
        showPanel(panelWindow, focusing: model.editingID == nil ? .inlineEntry : nil)
    }

    func toggleClipboard() {
        guard let panelWindow else { return }
        guard !panelDialogs.isPresented else { return }
        if model.editingID != nil {
            if !panelWindow.isVisible || panelWindow.isMiniaturized
                || !panelWindow.isOnActiveSpace || !panelWindow.isKeyWindow {
                showPanel(panelWindow, focusing: nil)
            }
            return
        }
        if model.isShowingClipboard,
           !model.isSearchExpanded,
           Self.shouldHidePanel(
               isVisible: panelWindow.isVisible,
               isMiniaturized: panelWindow.isMiniaturized,
               isOnActiveSpace: panelWindow.isOnActiveSpace
           ) {
            hidePanel(restoringPreviousApplication: panelWindow.isKeyWindow)
            return
        }
        model.showClipboard()
        model.exitSearch()
        showPanel(panelWindow, focusing: .clipboard)
    }

    private func showPanel(_ panelWindow: NSWindow, focusing target: PanelFocusRequest?) {
        if case .hiding = panelDialogs.active { return }
        panelFocusRequestGeneration += 1
        let focusRequestGeneration = panelFocusRequestGeneration
        if let externalApplication = frontmostExternalApplication() {
            previousExternalApplication = externalApplication
        }
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
                guard let self,
                      self.panelFocusRequestGeneration == focusRequestGeneration else { return }
                self.panelFocusRequests.send(target)
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
        guard !panelDialogs.isPresented,
              model.editingID == nil,
              let panelWindow else { return }
        showPanel(panelWindow, focusing: .search)
    }

    func setSnipCommandFocusActive(_ isActive: Bool) {
        snipCommandFocus.isActive = isActive
        if isActive {
            refreshAppShortcutMenu()
        }
    }

    /// Original dismissal callbacks may queue one terminal cleanup batch,
    /// deduplicated by workflow ID. Requests raised by that batch are discarded
    /// without callbacks so hiding cannot prolong itself through new requests.
    func hidePanel(restoringPreviousApplication: Bool = true) {
        if case .hiding = panelDialogs.active { return }
        let active = panelDialogs.active
        let pending = pendingPanelDialogs
        pendingPanelDialogs.removeAll()
        panelDialogs.active = .hiding
        panelFocusRequestGeneration += 1

        // Retire native ownership before external callbacks. Keep admission
        // blocked until the parent is hidden, including during native cancel.
        panelDialogPresenter.dismissForParentHide()
        if case .filePicker(let session) = active {
            restoreFilePanelParent(session)
            cancelFilePanel(session.panel)
            session.completion(.cancel)
        }
        for request in pending where request.id != .error {
            request.onDismiss()
        }
        if case .dialog(let session) = active, session.request.id != .error {
            session.request.onDismiss()
        }
        // Settle forms requested by the original callbacks once. Terminal
        // cleanup cannot start another cleanup cascade, even with fresh IDs.
        dismissPendingPanelDialogs()
        pendingPanelDialogs.removeAll()
        panelWindow?.orderOut(nil)
        if restoringPreviousApplication {
            previousExternalApplication?.activate(options: [])
        }
        previousExternalApplication = nil
        panelDialogs.active = .idle
    }

    /// CLI completion follows the saved snip, so retries never start a second capture.
    func captureSelectionForCLI(requestID: UUID, scopeToken: String?) async throws -> Snip {
        guard !panelDialogs.isPresented else { throw SnipCLIRequestError.editingInProgress }
        guard accessibilityPermissions.refresh() else {
            throw SelectionCaptureFailure.accessibilityPermissionRequired
        }
        guard let sourceApplication = frontmostExternalApplication() else {
            throw SelectionCaptureFailure.sourceUnavailable
        }
        let listID = model.activeListID
        let token = model.clipboardHistory.beginSuppression()
        defer { model.clipboardHistory.endSuppression(token) }
        let capture: SelectionCapture = try await withCheckedThrowingContinuation { continuation in
            selectionReader.capture(
                processID: sourceApplication.processIdentifier,
                applicationName: sourceApplication.localizedName ?? "Unknown app"
            ) { continuation.resume(with: $0) }
        }
        let staging = await Task.detached(priority: .userInitiated) {
            Self.writeTemporaryAttachments(capture.attachments, requestID: requestID)
        }.value
        let temporaryAttachments = try staging.get()
        defer {
            if let directory = temporaryAttachments.directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        return try await model.performCLIMutation(scopeToken: scopeToken) {
            guard self.model.editingID == nil else { throw SnipCLIRequestError.editingInProgress }
            let update = try await self.model.session.performLibraryCommand(
                .add(content: capture.content, origin: .selection, source: capture.source,
                     listID: listID, attachmentURLs: temporaryAttachments.urls,
                     requestID: requestID, now: Date()),
                sortedBy: self.model.sortMode
            )
            guard let snip = update.snapshot.snips.first(where: { $0.requestID == requestID }) else {
                throw SnipCLIOutcomeUncertain()
            }
            return (update, snip)
        }
    }

    /// Installed by the panel's SwiftUI environment, which owns the Settings scene.
    var openSettingsAction: (@MainActor () -> Void)?

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
                    self.hud.show(failure: error)
                }
            }
        }
    }

    private func presentAccessibilityRepair() {
        accessibilityPermissions.presentRepair()
        guard let panelWindow else { return }
        showPanel(panelWindow, focusing: nil)
    }

    private func restartShortcuts() {
        guard hasStarted, !ShortcutRecordingState.isActive else { return }
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
        guard !model.isCLIInteractionReserved else {
            onDismiss()
            return
        }
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
        guard !panelDialogs.isPresented,
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
        let session = PanelDialogSession(request: request)
        panelDialogs.active = .dialog(session)
        panelDialogPresenter.present(
            id: request.id,
            title: request.title,
            parent: panelWindow,
            content: request.content,
            onDismiss: { [weak self] reason in
                guard let self,
                      case .dialog(let current) = panelDialogs.active,
                      current.token == session.token else { return }
                panelDialogs.active = .idle
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
    }

    private func enqueuePanelDialog(_ request: PendingPanelDialog) {
        pendingPanelDialogs.removeAll { $0.id == request.id }
        pendingPanelDialogs.append(request)
    }

    @discardableResult
    private func presentNextPendingPanelDialog() -> Bool {
        guard !panelDialogs.isPresented,
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
        guard !model.isCLIInteractionReserved, !panelDialogs.isPresented else { return false }
        guard let panelWindow else { return false }
        switch model.appearance {
        case .system:
            panel.appearance = nil
        case .light:
            panel.appearance = NSAppearance(named: .aqua)
        case .dark:
            panel.appearance = NSAppearance(named: .darkAqua)
        }
        if !Self.shouldPresentPendingError(
            isVisible: panelWindow.isVisible,
            isMiniaturized: panelWindow.isMiniaturized,
            isOnActiveSpace: panelWindow.isOnActiveSpace
        ) {
            showPanel(panelWindow, focusing: nil)
        }
        guard !panelDialogs.isPresented else { return false }
        let session = PanelFilePickerSession(
            panel: panel,
            parent: panelWindow,
            parentAlphaValue: panelWindow.alphaValue,
            completion: completion
        )
        panelDialogs.active = .filePicker(session)
        panelWindow.alphaValue = 0.45
        (panelWindow as? SnipSnapPanel)?.setPresentedModalWindow(panel)
        let token = session.token
        beginFilePanel(panel, panelWindow) { [weak self] response in
            Task { @MainActor in
                self?.finishFilePanel(token: token, response: response)
            }
        }
        return true
    }

    private func restoreFilePanelParent(_ session: PanelFilePickerSession) {
        session.parent.alphaValue = session.parentAlphaValue
        (session.parent as? SnipSnapPanel)?.setPresentedModalWindow(nil)
    }

    private func finishFilePanel(
        token: UUID,
        response: NSApplication.ModalResponse
    ) {
        guard case .filePicker(let session) = panelDialogs.active,
              session.token == token else { return }
        restoreFilePanelParent(session)
        panelDialogs.active = .idle
        if session.parent.isVisible {
            session.parent.makeKeyAndOrderFront(nil)
        }
        session.completion(response)
        if !presentNextPendingPanelDialog() { updatePresentedError() }
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
        guard !ShortcutRecordingState.isActive else { return }
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
        if ShortcutRecordingState.isActive {
            // Validate the new binding while recording, then release it so the
            // recorder keeps receiving input until recording ends.
            let candidate = newHotKeyManager()
            defer { candidate.unregister() }
            try candidate.register(configuration: configuration)
            return
        }
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
