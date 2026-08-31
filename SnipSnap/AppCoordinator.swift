import AppKit
import SnipSnapCore
import ApplicationServices
import Carbon.HIToolbox
import Combine

enum PanelFocusRequest {
    case search
    case inlineEntry
}

enum SelectionAttachmentStagingError: Error, Equatable, Sendable {
    case writeFailed
}

@MainActor
final class AppCoordinator {
    private let model: AppModel
    let shortcutSettings: ShortcutSettings
    private let makeHotKeyManager: (@escaping (GlobalHotKeyAction) -> Void) -> any GlobalHotKeyManaging
    private let isAccessibilityTrusted: () -> Bool
    private let requestAccessibilityTrust: () -> Void
    private let selectionReader = AccessibilitySelectionReader()
    private let hud = CaptureHUDController()
    let panelFocusRequests = PassthroughSubject<PanelFocusRequest, Never>()
    private var hotKeys: (any GlobalHotKeyManaging)?
    private var editorWindows: [UUID: DetachedEditorWindowController] = [:]
    private weak var panelWindow: NSWindow?
    private var requestedPanelComposerExpansion: CGFloat = 0
    private var appliedPanelComposerExpansion: CGFloat = 0
    private var previousExternalApplication: NSRunningApplication?
    private var applicationActivationObserver: NSObjectProtocol?

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
        }
    ) {
        self.model = model
        self.shortcutSettings = shortcutSettings
        self.makeHotKeyManager = makeHotKeyManager
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
    }

    func start() {
        observeExternalApplicationActivations()
        guard hotKeys == nil else { return }
        refreshAppShortcutMenu()
        if !isAccessibilityTrusted() {
            presentAccessibilityAccessExplanation()
        }
        let manager = newHotKeyManager()
        do {
            try manager.register(configuration: shortcutSettings.configuration)
            hotKeys = manager
        } catch {
            model.presentedError = String(localized: "Snip Snap could not register its keyboard shortcuts.")
        }
    }

    func requestAccessibilityAccess() {
        model.isAccessibilityAccessExplanationPresented = false
        guard !isAccessibilityTrusted() else { return }
        requestAccessibilityTrust()
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
            isVisible: panelWindow.isVisible,
            isMiniaturized: panelWindow.isMiniaturized,
            isOnActiveSpace: panelWindow.isOnActiveSpace
        ) {
            hidePanel(restoringPreviousApplication: panelWindow.isKeyWindow)
            return
        }
        showPanel(panelWindow, focusing: .inlineEntry)
    }

    func toggleClipboard() {
        guard let panelWindow else { return }
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
        if let target {
            DispatchQueue.main.async { [weak self] in
                self?.panelFocusRequests.send(target)
            }
        }
    }

    nonisolated static func shouldHidePanel(
        isVisible: Bool,
        isMiniaturized: Bool,
        isOnActiveSpace: Bool
    ) -> Bool {
        isVisible && !isMiniaturized && isOnActiveSpace
    }

    func focusPanelSearch() {
        panelFocusRequests.send(.search)
    }

    func setSnipCommandFocusActive(_ isActive: Bool) {
        if isActive {
            refreshAppShortcutMenu()
        }
    }

    func hidePanel(restoringPreviousApplication: Bool = true) {
        panelWindow?.orderOut(nil)
        if restoringPreviousApplication {
            previousExternalApplication?.activate(options: [])
        }
        previousExternalApplication = nil
    }

    func useClipboardEntry(_ entry: ClipboardEntry) {
        guard model.clipboardHistory.restore(entry) else {
            model.presentedError = String(localized: "Snip Snap could not set the clipboard.")
            return
        }
        guard let application = previousExternalApplication,
              focusedElementAcceptsText(in: application) else { return }
        application.activate(options: [])
        Task { @MainActor [weak self, weak application] in
            guard let self, let application else { return }
            for _ in 0..<50 where !application.isActive {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard application.isActive else {
                model.presentedError = String(localized: "Snip Snap set the clipboard but could not return to the prior app.")
                return
            }
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: true
            )
            down?.flags = .maskCommand
            let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false
            )
            up?.flags = .maskCommand
            down?.postToPid(application.processIdentifier)
            up?.postToPid(application.processIdentifier)
            panelWindow?.orderOut(nil)
            previousExternalApplication = nil
        }
    }

    func editSelectionInNewWindow() {
        Task { await editSelectionInNewWindowNow() }
    }

    func editSelectionInNewWindowNow() async {
        guard model.selection.count == 1,
              let snip = model.selectedSnips.first else { return }
        do {
            _ = try await model.prepareAttachments(snip.attachments, for: .open)
        } catch {
            model.presentedError = error.localizedDescription
            return
        }
        if let existing = editorWindows[snip.id] {
            existing.show()
            return
        }
        let snipID = snip.id
        let snipUpdatedAt = snip.updatedAt
        let controller = DetachedEditorWindowController(
            snip: snip,
            onSave: { [weak self] text in
                guard let self else {
                    return String(localized: "Snip Snap closed before it could save the snip.")
                }
                let result = await self.model.updateResult(
                    id: snipID,
                    content: text,
                    expectedUpdatedAt: snipUpdatedAt
                )
                switch result {
                case .success:
                    return nil
                case .failure(let error):
                    return error.localizedDescription
                }
            },
            onClose: { [weak self] in
                self?.editorWindows[snipID] = nil
            }
        )
        editorWindows[snipID] = controller
        controller.show()
    }

    func captureSelection() {
        guard isAccessibilityTrusted() else {
            presentAccessibilityAccessExplanation()
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
                        let message = String(localized: "Snip Snap could not prepare the captured images.")
                        self.model.presentedError = message
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
                        self.model.presentedError = error.localizedDescription
                        self.hud.show(
                            message: error.localizedDescription,
                            symbol: "exclamationmark"
                        )
                    }
                case .failure(let error):
                    if error == .accessibilityPermissionRequired {
                        self.presentAccessibilityAccessExplanation()
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

    private func presentAccessibilityAccessExplanation() {
        model.isAccessibilityAccessExplanationPresented = true
        guard let panelWindow else { return }
        showPanel(panelWindow, focusing: nil)
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
        appliedPanelComposerExpansion = 0
        applyPanelComposerExpansion()
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
        let requestedDelta = requestedPanelComposerExpansion - appliedPanelComposerExpansion
        guard abs(requestedDelta) >= 0.5 else { return }

        var frame = panelWindow.frame
        let targetHeight = max(panelWindow.minSize.height, frame.height + requestedDelta)
        let appliedDelta = targetHeight - frame.height
        frame.origin.y -= appliedDelta
        frame.size.height = targetHeight
        panelWindow.setFrame(frame, display: panelWindow.isVisible, animate: false)
        appliedPanelComposerExpansion = requestedPanelComposerExpansion
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

    private func focusedElementAcceptsText(in application: NSRunningApplication) -> Bool {
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let focused = value,
        CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let focusedElement = focused as! AXUIElement
        return [kAXSelectedTextAttribute, kAXValueAttribute].contains { attribute in
            var isSettable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(
                focusedElement,
                attribute as CFString,
                &isSettable
            ) == .success && isSettable.boolValue
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
