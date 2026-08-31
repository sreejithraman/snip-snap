import AppKit
import SnipSnapCore
import SwiftUI

@MainActor
final class DetachedEditorWindowController: NSWindowController, NSWindowDelegate {
    private let session: DetachedEditorSession
    private let onSave: @MainActor (String) async -> String?
    private let onClose: () -> Void

    init(
        snip: Snip,
        onSave: @escaping @MainActor (String) async -> String?,
        onClose: @escaping () -> Void
    ) {
        session = DetachedEditorSession(text: snip.content)
        self.onSave = onSave
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 390),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = String(localized: .editSnip)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 280)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: DetachedEditorView(
                session: session,
                onSave: { [weak self] in self?.save() },
                onCancel: { [weak window] in window?.performClose(nil) }
            )
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func save() {
        guard let text = session.beginSave() else {
            NSSound.beep()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let errorMessage = await self.onSave(text)
            self.session.finishSave(errorMessage: errorMessage)
            if errorMessage == nil {
                self.window?.performClose(nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

@MainActor
final class DetachedEditorSession: ObservableObject {
    @Published var text: String
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?

    init(text: String) {
        self.text = text
    }

    func beginSave() -> String? {
        guard !isSaving else { return nil }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }
        errorMessage = nil
        isSaving = true
        return cleanText
    }

    func finishSave(errorMessage: String?) {
        isSaving = false
        self.errorMessage = errorMessage
    }
}

private struct DetachedEditorView: View {
    @ObservedObject var session: DetachedEditorSession
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading) {
            TextEditor(text: $session.text)
                .focused($editorFocused)

            if let errorMessage = session.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SnipSnapColors.textError)
            }

            HStack {
                Text(.sSave)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SnipSnapColors.textSecondary)
                Spacer()
                Button(.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(.save, action: onSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(
                        session.isSaving
                            || session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding()
        .onAppear {
            DispatchQueue.main.async {
                editorFocused = true
            }
        }
    }
}
