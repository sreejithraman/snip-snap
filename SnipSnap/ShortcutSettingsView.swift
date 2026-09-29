import AppKit
import Carbon.HIToolbox
import SnipSnapCore
import SwiftUI

@MainActor
enum ShortcutRecordingState {
    private static var activeRecorders: Set<ObjectIdentifier> = []

    static var isActive: Bool { !activeRecorders.isEmpty }

    static func begin(_ recorder: AnyObject) {
        activeRecorders.insert(ObjectIdentifier(recorder))
    }

    static func end(_ recorder: AnyObject) {
        activeRecorders.remove(ObjectIdentifier(recorder))
    }
}

struct ShortcutSettingsView: View {
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    let coordinator: AppCoordinator

    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(GlobalHotKeyAction.allCases) { action in
                        ShortcutSettingRow(
                            title: action.title,
                            trigger: shortcutSettings.configuration.trigger(for: action),
                            defaultTrigger: action.defaultTrigger,
                            allowsDoubleShift: true,
                            onRecord: { save($0, for: action) },
                            onUseDefault: {
                                save(action.defaultTrigger, for: action)
                            }
                        )
                    }
                } header: {
                    Text("From Any App")
                } footer: {
                    Text("Capture content or open Snip Snap while you’re using another app.")
                }

                Section("In Snip Snap") {
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
            AppDiagnostics.shared.record(.failure(
                operation: "shortcut.save",
                error: error,
                visibility: .user
            ))
            errorMessage = error.localizedDescription
        }
    }
}

private struct ShortcutSettingRow: View {
    let title: String
    let trigger: ShortcutTrigger
    let defaultTrigger: ShortcutTrigger
    var allowsDoubleShift = false
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
                    allowsDoubleShift: allowsDoubleShift,
                    allowsUnmodifiedSpecialKey: allowsUnmodifiedSpecialKey,
                    onRecord: onRecord
                )
                    .frame(width: 122, height: 28)
            }
        }
        .font(.body)
    }
}

struct ShortcutRecorderButton: NSViewRepresentable {
    let trigger: ShortcutTrigger
    var allowsDoubleShift = false
    var allowsUnmodifiedSpecialKey = false
    let onRecord: (ShortcutTrigger) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onRecord = onRecord
        button.allowsDoubleShift = allowsDoubleShift
        button.allowsUnmodifiedSpecialKey = allowsUnmodifiedSpecialKey
        button.setTrigger(trigger)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onRecord = onRecord
        button.allowsDoubleShift = allowsDoubleShift
        button.allowsUnmodifiedSpecialKey = allowsUnmodifiedSpecialKey
        button.setTrigger(trigger)
    }

    final class RecorderButton: NSButton {
        var onRecord: ((ShortcutTrigger) -> Void)?
        var allowsDoubleShift = false
        var allowsUnmodifiedSpecialKey = false
        private var trigger: ShortcutTrigger = .doubleShift(.left)
        private var isRecording = false
        private var inputMonitor: Any?
        private var focusObservers: [NSObjectProtocol] = []
        private var doubleShiftRouter = DoubleShiftRouter(gestures: [])

        override var acceptsFirstResponder: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            controlSize = .small
            font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            target = self
            action = #selector(beginRecording)
            toolTip = String(localized: "Click, then press a shortcut")
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
            guard !isRecording else { return }
            isRecording = true
            title = String(localized: "Press shortcut")
            window?.makeFirstResponder(self)
            guard isRecording else { return }
            ShortcutRecordingState.begin(self)
            let notifications = NotificationCenter.default
            if let window {
                focusObservers.append(notifications.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window,
                    queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stopRecording() }
                })
            }
            focusObservers.append(notifications.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopRecording() }
            })
            if allowsDoubleShift {
                doubleShiftRouter = DoubleShiftRouter(gestures: [
                    DoubleShiftGesture(side: .left, modifier: .none),
                    DoubleShiftGesture(side: .right, modifier: .none),
                    DoubleShiftGesture(side: .left, modifier: .command),
                    DoubleShiftGesture(side: .right, modifier: .command),
                ])
            }
            if inputMonitor == nil {
                inputMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.flagsChanged, .keyDown, .keyUp]
                ) {
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

        override func flagsChanged(with event: NSEvent) {
            if handle(event) { return }
            super.flagsChanged(with: event)
        }

        override func keyUp(with event: NSEvent) {
            if handle(event) { return }
            super.keyUp(with: event)
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
            guard isRecording else { return false }
            if event.type == .flagsChanged, allowsDoubleShift {
                if let gesture = doubleShiftRouter.receive(event) {
                    let trigger: ShortcutTrigger = gesture.modifier == .command
                        ? .commandDoubleShift(gesture.side)
                        : .doubleShift(gesture.side)
                    onRecord?(trigger)
                    stopRecording()
                }
                return true
            }
            if event.type == .keyUp {
                doubleShiftRouter.cancel()
                return false
            }
            guard event.type == .keyDown else { return false }
            doubleShiftRouter.cancel()
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
            ShortcutRecordingState.end(self)
            if let inputMonitor {
                NSEvent.removeMonitor(inputMonitor)
                self.inputMonitor = nil
            }
            for observer in focusObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            focusObservers.removeAll()
            doubleShiftRouter.cancel()
            title = trigger.displayName
        }
    }
}
