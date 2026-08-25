import AppKit
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
            return .data(fileName: "Pasted Image.\(suffix)", data: data)
        }
        return nil
    }
}

enum PanelPastedImageStagingError: Error, LocalizedError, Sendable {
    case writeFailed

    var errorDescription: String? {
        "Snip Snap could not prepare the pasted images."
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

enum PanelMultilineTextMetrics {
    static let verticalInset: CGFloat = 8
    static let horizontalTextInset: CGFloat = 0
    static let systemTextEditorInset: CGFloat = 5
    static let horizontalViewportExpansion: CGFloat = systemTextEditorInset
    static let systemTextEditorTopInset: CGFloat = 5
    static let placeholderTopInset: CGFloat = systemTextEditorTopInset

    static var lineHeight: CGFloat {
        ceil(NSFont.preferredFont(forTextStyle: .body).boundingRectForFont.height)
    }

    static var effectiveHorizontalInset: CGFloat {
        systemTextEditorInset - horizontalViewportExpansion
    }

    static func height(
        measuredContentHeight: CGFloat,
        lineRange: ClosedRange<Int>,
        lineSpacing: CGFloat
    ) -> CGFloat {
        func height(for lineCount: Int) -> CGFloat {
            lineHeight * CGFloat(lineCount)
                + lineSpacing * CGFloat(max(lineCount - 1, 0))
                + verticalInset
        }
        let minimumHeight = height(for: lineRange.lowerBound)
        let maximumHeight = height(for: lineRange.upperBound)
        return min(max(measuredContentHeight, minimumHeight), maximumHeight)
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
    @State private var measuredContentHeight: CGFloat = 0
    @State private var imagePasteMonitor: Any?
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
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .accessibilityLabel(prompt)
                .scrollContentBackground(.hidden)
                .contentMargins(
                    .horizontal,
                    PanelMultilineTextMetrics.horizontalTextInset,
                    for: .scrollContent
                )
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
                .padding(
                    .horizontal,
                    -PanelMultilineTextMetrics.horizontalViewportExpansion
                )

            if text.isEmpty {
                Text(prompt)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, PanelMultilineTextMetrics.horizontalTextInset)
                    .padding(.top, PanelMultilineTextMetrics.placeholderTopInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: editorHeight)
        .background {
            Text(measurementText)
                .font(.body)
                .lineSpacing(lineSpacing)
                .padding(.horizontal, PanelMultilineTextMetrics.horizontalTextInset)
                .padding(.vertical, PanelMultilineTextMetrics.verticalInset / 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .allowsHitTesting(false)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    measuredContentHeight = height
                }

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
            updateImagePasteMonitor(isEnabled: isFocused)
        }
        .onChange(of: editorFocused) { _, focused in
            updateImagePasteMonitor(isEnabled: focused)
            onFocusChange(focused)
        }
        .onDisappear {
            updateImagePasteMonitor(isEnabled: false)
        }
    }

    private var editorHeight: CGFloat {
        PanelMultilineTextMetrics.height(
            measuredContentHeight: measuredContentHeight,
            lineRange: lineRange,
            lineSpacing: lineSpacing
        )
    }

    private var measurementText: String {
        (text.isEmpty ? " " : text) + "\u{200B}"
    }

    private func updateImagePasteMonitor(isEnabled: Bool) {
        if isEnabled, imagePasteMonitor == nil {
            imagePasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === windowReference.window,
                      event.window?.firstResponder is NSTextView,
                      PanelImagePasteCommand.matches(modifiers: event.modifierFlags),
                      event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
                let images = windowReference.readPastedImages()
                guard !images.isEmpty else { return event }
                windowReference.onPasteImages(images)
                return windowReference.pastedContentContainsText() ? event : nil
            }
        } else if !isEnabled, let imagePasteMonitor {
            NSEvent.removeMonitor(imagePasteMonitor)
            self.imagePasteMonitor = nil
        }
    }
}
