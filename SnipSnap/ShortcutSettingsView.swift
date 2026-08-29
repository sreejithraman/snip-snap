import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutSettingsView: View {
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    let coordinator: AppCoordinator
    @ObservedObject private var accessibilityPermissions: AccessibilityPermissionController

    @State private var errorMessage: String?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _accessibilityPermissions = ObservedObject(
            wrappedValue: coordinator.accessibilityPermissions
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Keyboard Shortcuts") {
                    ForEach(GlobalHotKeyAction.allCases) { action in
                        ShortcutSettingRow(
                            title: action.title,
                            trigger: shortcutSettings.configuration.trigger(for: action),
                            defaultTrigger: action.defaultTrigger,
                            onRecord: { save($0, for: action) },
                            onUseDefault: {
                                save(action.defaultTrigger, for: action)
                            }
                        )
                    }

                    ForEach(AppShortcutAction.allCases) { action in
                        let chord = shortcutSettings.chord(for: action)
                        ShortcutSettingRow(
                            title: action.title,
                            trigger: .keyChord(chord),
                            defaultTrigger: .keyChord(action.defaultChord),
                            allowsUnmodifiedSpecialKey: true,
                            onRecord: { trigger in
                                if let chord = trigger.chord {
                                    save(chord, for: action)
                                }
                            },
                            onUseDefault: { reset(action) }
                        )
                    }
                }

                Section("Permissions") {
                    AccessibilitySettingsRow(controller: accessibilityPermissions)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(SnipSnapColors.textError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom])
            }
        }
        .frame(width: 400, height: 310)
        .background(ShortcutSettingsWindowConfigurator())
        .onAppear {
            accessibilityPermissions.refresh()
        }
    }

    private func save(_ trigger: ShortcutTrigger, for action: GlobalHotKeyAction) {
        apply {
            try coordinator.setShortcut(trigger, for: action)
        }
    }

    private func save(_ chord: ShortcutKeyChord, for action: AppShortcutAction) {
        apply {
            try coordinator.setShortcut(chord, for: action)
        }
    }

    private func reset(_ action: AppShortcutAction) {
        apply {
            try coordinator.resetShortcut(action)
        }
    }

    private func apply(_ change: () throws -> Void) {
        do {
            try change()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ShortcutSettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguringView {
        ConfiguringView()
    }

    func updateNSView(_ view: ConfiguringView, context: Context) {
        view.configureWindow()
    }

    final class ConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            window?.title = "Snip Snap Settings"
            window?.level = .modalPanel
        }
    }
}

private struct AccessibilitySettingsRow: View {
    @ObservedObject var controller: AccessibilityPermissionController

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            LabeledContent("Accessibility") {
                HStack(spacing: SnipSnapSpacing.relatedContent) {
                    Label(
                        controller.isGranted ? "On" : "Off",
                        systemImage: controller.isGranted
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(
                        controller.isGranted
                            ? Color(nsColor: .systemGreen)
                            : Color.secondary
                    )

                    Button("Open Settings…") {
                        controller.openSettings()
                    }
                }
            }

            Text("Needed for global Shift shortcuts and selected-content capture.")
                .font(.caption)
                .foregroundStyle(SnipSnapColors.textSecondary)
        }
    }
}

private struct ShortcutSettingRow: View {
    let title: String
    let trigger: ShortcutTrigger
    let defaultTrigger: ShortcutTrigger
    var allowsUnmodifiedSpecialKey = false
    let onRecord: (ShortcutTrigger) -> Void
    let onUseDefault: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                if trigger != defaultTrigger {
                    Button("Use Default", systemImage: "arrow.counterclockwise", action: onUseDefault)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(SnipSnapColors.textSecondary)
                        .help("Use Default")
                }
                ShortcutRecorderButton(
                    trigger: trigger,
                    allowsUnmodifiedSpecialKey: allowsUnmodifiedSpecialKey,
                    onRecord: onRecord
                )
                    .frame(width: 122, height: 28)
            }
        }
        .font(.body)
    }
}

private struct ShortcutRecorderButton: NSViewRepresentable {
    let trigger: ShortcutTrigger
    var allowsUnmodifiedSpecialKey = false
    let onRecord: (ShortcutTrigger) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onRecord = onRecord
        button.allowsUnmodifiedSpecialKey = allowsUnmodifiedSpecialKey
        button.setTrigger(trigger)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onRecord = onRecord
        button.allowsUnmodifiedSpecialKey = allowsUnmodifiedSpecialKey
        button.setTrigger(trigger)
    }

    final class RecorderButton: NSButton {
        var onRecord: ((ShortcutTrigger) -> Void)?
        var allowsUnmodifiedSpecialKey = false
        private var trigger: ShortcutTrigger = .doubleShift(.left)
        private var isRecording = false
        private var keyMonitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            controlSize = .small
            font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            target = self
            action = #selector(beginRecording)
            toolTip = "Click, then press a shortcut"
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                stopRecording()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func setTrigger(_ trigger: ShortcutTrigger) {
            self.trigger = trigger
            if !isRecording {
                title = trigger.displayName
            }
        }

        @objc private func beginRecording() {
            isRecording = true
            title = "Press shortcut"
            window?.makeFirstResponder(self)
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                    [weak self] event in
                    guard let self, self.isRecording else { return event }
                    return self.handle(event) ? nil : event
                }
            }
        }

        override func keyDown(with event: NSEvent) {
            if handle(event) { return }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            return handle(event)
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            stopRecording()
            return result
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard isRecording, event.type == .keyDown else { return false }
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return true
            }
            guard let chord = ShortcutKeyChord(
                event: event,
                allowsUnmodifiedSpecialKey: allowsUnmodifiedSpecialKey
            ) else {
                NSSound.beep()
                return true
            }
            onRecord?(.keyChord(chord))
            stopRecording()
            return true
        }

        private func stopRecording() {
            guard isRecording else { return }
            isRecording = false
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            title = trigger.displayName
        }
    }
}
