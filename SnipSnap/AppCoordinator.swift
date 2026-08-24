import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

enum InboxFocusRequest {
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
    private let requestAccessibilityTrust: () -> Bool
    private let selectionReader = AccessibilitySelectionReader()
    private let hud = CaptureHUDController()
    let inboxFocusRequests = PassthroughSubject<InboxFocusRequest, Never>()
    private var hotKeys: (any GlobalHotKeyManaging)?
    private var editorWindows: [UUID: DetachedEditorWindowController] = [:]
    private weak var inboxWindow: NSWindow?
    private var requestedInboxComposerExpansion: CGFloat = 0
    private var appliedInboxComposerExpansion: CGFloat = 0
    private var previousExternalApplication: NSRunningApplication?
    private var applicationActivationObserver: NSObjectProtocol?

    init(
        model: AppModel,
        shortcutSettings: ShortcutSettings,
        makeHotKeyManager: @escaping (
            @escaping (GlobalHotKeyAction) -> Void
        ) -> any GlobalHotKeyManaging = { GlobalHotKeyManager(handler: $0) },
        requestAccessibilityTrust: @escaping () -> Bool = {
            AXIsProcessTrusted() || AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            )
        }
    ) {
        self.model = model
        self.shortcutSettings = shortcutSettings
        self.makeHotKeyManager = makeHotKeyManager
        self.requestAccessibilityTrust = requestAccessibilityTrust
    }

    func start() {
        observeExternalApplicationActivations()
        guard hotKeys == nil else { return }
        refreshAppShortcutMenu()
        if shortcutSettings.configuration.usesDoubleShift,
           !requestAccessibilityTrust() {
            model.presentedError = "Allow Snip Snap in System Settings → Privacy & Security → Accessibility so its Shift shortcuts work."
        }
        let manager = newHotKeyManager()
        do {
            try manager.register(configuration: shortcutSettings.configuration)
            hotKeys = manager
        } catch {
            model.presentedError = "Snip Snap could not register its keyboard shortcuts."
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

    func toggleInbox() {
        guard let inboxWindow else { return }
        if Self.shouldHideInbox(
            isVisible: inboxWindow.isVisible,
            isMiniaturized: inboxWindow.isMiniaturized,
            isOnActiveSpace: inboxWindow.isOnActiveSpace
        ) {
            hideInbox(restoringPreviousApplication: inboxWindow.isKeyWindow)
            return
        }
        showInbox(inboxWindow, focusing: .inlineEntry)
    }

    func toggleClipboard() {
        guard let inboxWindow else { return }
        if model.isShowingClipboard,
           Self.shouldHideInbox(
               isVisible: inboxWindow.isVisible,
               isMiniaturized: inboxWindow.isMiniaturized,
               isOnActiveSpace: inboxWindow.isOnActiveSpace
           ) {
            hideInbox(restoringPreviousApplication: inboxWindow.isKeyWindow)
            return
        }
        model.showClipboard()
        model.query = ""
        showInbox(inboxWindow, focusing: .search)
    }

    private func showInbox(_ inboxWindow: NSWindow, focusing target: InboxFocusRequest) {
        previousExternalApplication = frontmostExternalApplication()
        NSApp.activate(ignoringOtherApps: true)
        if inboxWindow.isMiniaturized {
            inboxWindow.deminiaturize(nil)
        } else if inboxWindow.isVisible && !inboxWindow.isOnActiveSpace {
            inboxWindow.orderOut(nil)
        }
        inboxWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.inboxFocusRequests.send(target)
        }
    }

    nonisolated static func shouldHideInbox(
        isVisible: Bool,
        isMiniaturized: Bool,
        isOnActiveSpace: Bool
    ) -> Bool {
        isVisible && !isMiniaturized && isOnActiveSpace
    }

    func focusInboxSearch() {
        inboxFocusRequests.send(.search)
    }

    func setInboxCommandFocusActive(_ isActive: Bool) {
        if isActive {
            refreshAppShortcutMenu()
        }
    }

    func hideInbox(restoringPreviousApplication: Bool = true) {
        inboxWindow?.orderOut(nil)
        if restoringPreviousApplication {
            previousExternalApplication?.activate(options: [])
        }
        previousExternalApplication = nil
    }

    func useClipboardEntry(_ entry: ClipboardEntry) {
        guard model.clipboardHistory.restore(entry) else {
            model.presentedError = "Snip Snap could not set the clipboard."
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
                model.presentedError = "Snip Snap set the clipboard but could not return to the prior app."
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
            inboxWindow?.orderOut(nil)
            previousExternalApplication = nil
        }
    }

    func editSelectionInNewWindow() {
        guard model.selection.count == 1,
              let item = model.selectedItems.first else { return }
        if let existing = editorWindows[item.id] {
            existing.show()
            return
        }
        let itemID = item.id
        let itemUpdatedAt = item.updatedAt
        let controller = DetachedEditorWindowController(
            item: item,
            onSave: { [weak self] text in
                guard let self else { return "Snip Snap closed before it could save the item." }
                let result = await self.model.updateResult(
                    id: itemID,
                    content: text,
                    expectedUpdatedAt: itemUpdatedAt
                )
                switch result {
                case .success:
                    return nil
                case .failure(let error):
                    return error.localizedDescription
                }
            },
            onClose: { [weak self] in
                self?.editorWindows[itemID] = nil
            }
        )
        editorWindows[itemID] = controller
        controller.show()
    }

    func captureSelection() {
        guard let sourceApplication = frontmostExternalApplication() else {
            hud.show(
                message: SelectionCaptureFailure.sourceUnavailable.localizedDescription,
                symbol: "exclamationmark"
            )
            return
        }
        let requestID = UUID()
        let name = sourceApplication.localizedName ?? "Unknown app"
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
                        let message = "Snip Snap could not prepare the captured images."
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
                        self.hud.show(message: "Captured", symbol: "checkmark")
                    case .success(.duplicate):
                        self.hud.show(message: "Already captured", symbol: "minus")
                    case .failure(let error):
                        self.model.presentedError = error.localizedDescription
                        self.hud.show(
                            message: error.localizedDescription,
                            symbol: "exclamationmark"
                        )
                    }
                case .failure(let error):
                    self.hud.show(
                        message: error.localizedDescription,
                        symbol: error == .duplicateSelection ? "minus" : "exclamationmark"
                    )
                }
            }
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

    func attachInboxWindow(_ window: NSWindow) {
        inboxWindow = window
        appliedInboxComposerExpansion = 0
        applyInboxComposerExpansion()
    }

    func updateInboxComposerExpansion(_ expansion: CGFloat) {
        requestedInboxComposerExpansion = max(expansion, 0)
        applyInboxComposerExpansion()
    }

    func isInboxWindow(_ window: NSWindow?) -> Bool {
        window === inboxWindow
    }

    private func applyInboxComposerExpansion() {
        guard let inboxWindow else { return }
        let requestedDelta = requestedInboxComposerExpansion - appliedInboxComposerExpansion
        guard abs(requestedDelta) >= 0.5 else { return }

        var frame = inboxWindow.frame
        let targetHeight = max(inboxWindow.minSize.height, frame.height + requestedDelta)
        let appliedDelta = targetHeight - frame.height
        frame.origin.y -= appliedDelta
        frame.size.height = targetHeight
        inboxWindow.setFrame(frame, display: inboxWindow.isVisible, animate: false)
        appliedInboxComposerExpansion = requestedInboxComposerExpansion
    }

    private func handle(_ action: GlobalHotKeyAction) {
        switch action {
        case .captureSelection:
            captureSelection()
        case .toggleInbox:
            toggleInbox()
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
