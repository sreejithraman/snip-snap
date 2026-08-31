import AppKit
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers

enum PanelPastedImage: Equatable, Sendable {
    case data(fileName: String, data: Data)
    case file(URL)

    var fileName: String {
        switch self {
        case .data(let fileName, _): fileName
        case .file(let url): url.lastPathComponent
        }
    }
}

enum PanelImagePasteboard {
    static func images(from pasteboard: NSPasteboard = .general) -> [PanelPastedImage] {
        (pasteboard.pasteboardItems ?? []).compactMap(image(from:))
    }

    static func containsText(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.availableType(from: [.string]) != nil
    }

    private static func image(from item: NSPasteboardItem) -> PanelPastedImage? {
        if let value = item.string(forType: .fileURL),
           let url = URL(string: value) {
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else {
                return nil
            }
            return .file(url)
        }

        let preferredTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        let imageType = preferredTypes.first(where: item.types.contains)
            ?? item.types.first {
                UTType($0.rawValue)?.conforms(to: .image) == true
            }
        if let imageType,
           let data = item.data(forType: imageType) {
            let suffix = UTType(imageType.rawValue)?.preferredFilenameExtension ?? "png"
            return .data(fileName: String(localized: .fileNamePastedImage(suffix)), data: data)
        }
        return nil
    }
}

enum PanelPastedImageStagingError: Error, LocalizedError, Sendable {
    case writeFailed

    var errorDescription: String? {
        String(localized: .snipSnapCouldNotPrepareThePastedImages)
    }
}

enum PanelPastedImageStaging {
    nonisolated static func write(
        _ images: [PanelPastedImage],
        to directory: URL = FileManager.default.temporaryDirectory
    ) -> Result<[URL], PanelPastedImageStagingError> {
        var urls: [URL] = []
        do {
            for image in images {
                let pathExtension = URL(fileURLWithPath: image.fileName).pathExtension
                let suffix = pathExtension.isEmpty ? "png" : pathExtension
                let url = directory.appendingPathComponent(
                    "Snip Snap Paste \(UUID().uuidString).\(suffix)"
                )
                switch image {
                case .data(_, let data):
                    try data.write(to: url, options: .atomic)
                case .file(let sourceURL):
                    try FileManager.default.copyItem(at: sourceURL, to: url)
                }
                urls.append(url)
            }
            return .success(urls)
        } catch {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
            return .failure(.writeFailed)
        }
    }
}

enum PanelTextInputReturnAction: Equatable {
    case submit
    case insertNewline

    static func action(for modifiers: EventModifiers) -> Self {
        modifiers.contains(.shift) ? .insertNewline : .submit
    }
}

enum PanelImagePasteCommand {
    static func matches(modifiers: NSEvent.ModifierFlags) -> Bool {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        let disallowedModifiers: NSEvent.ModifierFlags = [.shift, .control, .option]
        return modifiers.contains(.command)
            && modifiers.intersection(disallowedModifiers).isEmpty
    }
}

@MainActor
private final class PanelTextInputWindowReference {
    weak var window: NSWindow?
    var readPastedImages: () -> [PanelPastedImage] = { [] }
    var pastedContentContainsText: () -> Bool = { false }
    var onPasteImages: ([PanelPastedImage]) -> Void = { _ in }
}

private struct PanelTextInputWindowReader: NSViewRepresentable {
    let reference: PanelTextInputWindowReference
    let readPastedImages: () -> [PanelPastedImage]
    let pastedContentContainsText: () -> Bool
    let onPasteImages: ([PanelPastedImage]) -> Void

    func makeNSView(context: Context) -> PanelTextInputWindowReaderView {
        updateReference()
        return PanelTextInputWindowReaderView(reference: reference)
    }

    func updateNSView(_ nsView: PanelTextInputWindowReaderView, context: Context) {
        nsView.reference = reference
        reference.window = nsView.window
        updateReference()
    }

    private func updateReference() {
        reference.readPastedImages = readPastedImages
        reference.pastedContentContainsText = pastedContentContainsText
        reference.onPasteImages = onPasteImages
    }
}

private final class PanelTextInputWindowReaderView: NSView {
    var reference: PanelTextInputWindowReference

    init(reference: PanelTextInputWindowReference) {
        self.reference = reference
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reference.window = window
    }
}

struct PanelMultilineTextInput: View {
    @Binding private var text: String
    private let prompt: String
    private let lineRange: ClosedRange<Int>
    private let lineSpacing: CGFloat
    private let isFocused: Bool
    private let onFocusChange: (Bool) -> Void
    private let readPastedImages: () -> [PanelPastedImage]
    private let pastedContentContainsText: () -> Bool
    private let onPasteImages: ([PanelPastedImage]) -> Void
    private let onSubmit: () -> Void

    @FocusState private var editorFocused: Bool
    @State private var keyEventMonitor: Any?
    @State private var windowReference = PanelTextInputWindowReference()

    init(
        _ prompt: String,
        text: Binding<String>,
        lineRange: ClosedRange<Int>,
        lineSpacing: CGFloat = 0,
        isFocused: Bool,
        onFocusChange: @escaping (Bool) -> Void,
        readPastedImages: @escaping () -> [PanelPastedImage] = {
            PanelImagePasteboard.images()
        },
        pastedContentContainsText: @escaping () -> Bool = {
            PanelImagePasteboard.containsText()
        },
        onPasteImages: @escaping ([PanelPastedImage]) -> Void = { _ in },
        onSubmit: @escaping () -> Void
    ) {
        self.prompt = prompt
        _text = text
        self.lineRange = lineRange
        self.lineSpacing = lineSpacing
        self.isFocused = isFocused
        self.onFocusChange = onFocusChange
        self.readPastedImages = readPastedImages
        self.pastedContentContainsText = pastedContentContainsText
        self.onPasteImages = onPasteImages
        self.onSubmit = onSubmit
    }

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(lineRange)
        .frame(minHeight: PanelControlMetrics.floatingRowHeight)
        .font(.body)
        .foregroundStyle(SnipSnapColors.textPrimary)
        .lineSpacing(lineSpacing)
        .focused($editorFocused)
        .onKeyPress(.return, phases: .down) { press in
            guard PanelTextInputReturnAction.action(for: press.modifiers) == .submit else {
                return .ignored
            }
            onSubmit()
            return .handled
        }
        .background {
            PanelTextInputWindowReader(
                reference: windowReference,
                readPastedImages: readPastedImages,
                pastedContentContainsText: pastedContentContainsText,
                onPasteImages: onPasteImages
            )
                .allowsHitTesting(false)
        }
        .onChange(of: isFocused, initial: true) { _, focused in
            editorFocused = focused
        }
        .onAppear {
            updateKeyEventMonitor(isEnabled: isFocused)
        }
        .onChange(of: editorFocused) { _, focused in
            updateKeyEventMonitor(isEnabled: focused)
            onFocusChange(focused)
        }
        .onDisappear {
            updateKeyEventMonitor(isEnabled: false)
        }
    }

    private func updateKeyEventMonitor(isEnabled: Bool) {
        if isEnabled, keyEventMonitor == nil {
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === windowReference.window,
                      let fieldEditor = event.window?.firstResponder as? NSTextView else {
                    return event
                }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if [36, 76].contains(event.keyCode),
                   modifiers.contains(.shift),
                   modifiers.intersection([.command, .control, .option]).isEmpty {
                    fieldEditor.insertNewlineIgnoringFieldEditor(nil)
                    return nil
                }
                guard PanelImagePasteCommand.matches(modifiers: event.modifierFlags),
                      event.charactersIgnoringModifiers?.lowercased() == "v" else {
                    return event
                }
                let images = windowReference.readPastedImages()
                guard !images.isEmpty else { return event }
                windowReference.onPasteImages(images)
                return windowReference.pastedContentContainsText() ? event : nil
            }
        } else if !isEnabled, let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }
}
