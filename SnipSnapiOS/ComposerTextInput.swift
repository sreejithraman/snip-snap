import SnipSnapCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// UIKit owns text selection and paste insertion; SwiftUI owns the draft and focus.
struct ComposerTextInput: UIViewRepresentable {
    let prompt: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var isEnabled = true
    var isPasteEnabled = true
    var isTextInputEnabled = true
    var onPasteAttachments: ([NSItemProvider], NSRange) -> Void

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.keyboardDismissMode = .interactive
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.image.identifier, UTType.fileURL.identifier, UTType.plainText.identifier,
            UTType.url.identifier,
        ])
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteAttachments = onPasteAttachments
        view.isPasteEnabled = isPasteEnabled
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.isEditable = isEnabled
        view.isSelectable = isEnabled
        if view.text != text, view.markedTextRange == nil {
            let selection = view.attachmentPasteSelection ?? view.selectedRange
            let addedLength = (text as NSString).length - (view.text as NSString).length + selection.length
            view.text = text
            view.selectedRange = NSRange(
                location: min(selection.location + max(addedLength, 0), (text as NSString).length), length: 0
            )
        }
        if isPasteEnabled { view.attachmentPasteSelection = nil }
        view.placeholder.text = prompt
        view.placeholder.font = view.font
        view.placeholder.isHidden = !text.isEmpty
        view.accessibilityLabel = prompt
        if isEnabled, isFocused, !view.isFirstResponder, view.window != nil {
            view.becomeFirstResponder()
        } else if (!isFocused || !isEnabled), view.isFirstResponder {
            view.resignFirstResponder()
        }
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let lineHeight = uiView.font?.lineHeight ?? 20
        let fullHeight = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let maximum = ceil(lineHeight * 5)
        uiView.isScrollEnabled = fullHeight > maximum
        return CGSize(width: width, height: min(max(ceil(lineHeight), fullHeight), maximum))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextInput
        private var selectionBeforeChange: NSRange?
        init(parent: ComposerTextInput) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard parent.isTextInputEnabled else { return false }
            selectionBeforeChange = textView.selectedRange
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            // The binding can reject a large insertion and stage it as a file.
            if textView.text != parent.text, textView.markedTextRange == nil {
                textView.text = parent.text
                if let selectionBeforeChange {
                    let length = (textView.text as NSString).length
                    let location = min(selectionBeforeChange.location, length)
                    textView.selectedRange = NSRange(
                        location: location, length: min(selectionBeforeChange.length, length - location)
                    )
                }
            }
            selectionBeforeChange = nil
            (textView as? ComposerTextView)?.placeholder.isHidden = !textView.text.isEmpty
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) { parent.isFocused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.isFocused = false }
    }
}

final class ComposerTextView: UITextView {
    var onPasteAttachments: ([NSItemProvider], NSRange) -> Void = { _, _ in }
    var isPasteEnabled = true
    var attachmentPasteSelection: NSRange?
    let placeholder = UILabel()

    init() {
        super.init(frame: .zero, textContainer: nil)
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = CGRect(origin: .zero, size: CGSize(width: bounds.width, height: font?.lineHeight ?? 20))
    }

    override func paste(_ sender: Any?) {
        paste(itemProviders: UIPasteboard.general.itemProviders)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard isEditable, isPasteEnabled else { return }
        if itemProviders.contains(where: ComposerPasteboard.isAttachment) {
            // Keep text and files in one operation, including their destination.
            let selection = selectedRange
            attachmentPasteSelection = selection
            isPasteEnabled = false
            onPasteAttachments(itemProviders, selection)
        } else {
            super.paste(itemProviders: itemProviders)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), !isPasteEnabled { return false }
        if action == #selector(paste(_:)), isEditable,
           UIPasteboard.general.contains(pasteboardTypes: [UTType.image.identifier, UTType.fileURL.identifier]) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

/// Keep an attachment's URL/text alternatives out of the snip body.
@MainActor
enum ComposerPasteboard {
    static func isAttachment(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    static func stage(_ providers: [NSItemProvider], in root: URL) async throws -> ComposerPastedContent {
        var text = ""
        var files: [StagedAttachment] = []
        do {
            for provider in providers where !isAttachment(provider) && provider.canLoadObject(ofClass: NSString.self) {
                try Task.checkCancellation()
                let load = ComposerProviderLoad<String>()
                let value = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        guard load.begin(continuation) else { return }
                        let progress = provider.loadObject(ofClass: String.self) { string, error in
                            load.finish {
                                if let error { throw error }
                                guard let string else { throw CocoaError(.fileReadUnknown) }
                                return string
                            }
                        }
                        load.setProgress(progress)
                    }
                } onCancel: { load.cancel() }
                text += value
            }
            files = try await stageAttachments(providers, in: root)
            if LargePastedText.shouldAttach(text) {
                let batch = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    let directory = batch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let url = try LargePastedText.write(text, to: directory)
                    files.append(StagedAttachment(fileName: url.lastPathComponent, byteCount: Int64(text.utf8.count), url: url))
                    text = ""
                } catch {
                    AttachmentDraftStager.clean(batch)
                    throw error
                }
            }
            try Task.checkCancellation()
            return ComposerPastedContent(text: text, files: files)
        } catch {
            AttachmentDraftStager.clean(files)
            throw error
        }
    }

    static func stageAttachments(_ providers: [NSItemProvider], in root: URL) async throws -> [StagedAttachment] {
        let batch = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var staged: [StagedAttachment] = []
        do {
            for provider in providers where isAttachment(provider) {
                try Task.checkCancellation()
                let type: UTType = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    ? .fileURL : provider.registeredTypeIdentifiers.compactMap(UTType.init)
                        .first(where: { $0.conforms(to: .image) }) ?? .image
                let directory = batch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let suggestedName = provider.suggestedName
                let load = ComposerProviderLoad<StagedAttachment>()
                let file: StagedAttachment = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        guard load.begin(continuation) else { return }
                        let copy: @Sendable (URL?, Error?) -> Void = { source, error in
                            load.finish {
                                if let error { throw error }
                                guard let source, source.isFileURL else { throw SnipLibraryError.attachmentCopyFailed }
                                let access = source.startAccessingSecurityScopedResource()
                                defer { if access { source.stopAccessingSecurityScopedResource() } }
                                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                                    throw SnipLibraryError.attachmentCopyFailed
                                }
                                var name = URL(fileURLWithPath: suggestedName ?? source.lastPathComponent).lastPathComponent
                                if name.isEmpty { name = "Pasted Image" }
                                if URL(fileURLWithPath: name).pathExtension.isEmpty {
                                    let suffix = type == .fileURL ? source.pathExtension : type.preferredFilenameExtension
                                    if let suffix, !suffix.isEmpty { name += "." + suffix }
                                }
                                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                                let destination = directory.appendingPathComponent(name)
                                // Provider URLs expire when this callback returns.
                                try FileManager.default.copyItem(at: source, to: destination)
                                let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                                return StagedAttachment(fileName: name, byteCount: Int64(size), url: destination)
                            }
                        }
                        let progress: Progress
                        if type == .fileURL {
                            progress = provider.loadObject(ofClass: URL.self) { url, error in copy(url, error) }
                        } else {
                            progress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier, completionHandler: copy)
                        }
                        load.setProgress(progress)
                    }
                } onCancel: {
                    load.cancel()
                }
                staged.append(file)
            }
            try Task.checkCancellation()
            return staged
        } catch {
            AttachmentDraftStager.clean(batch)
            throw error
        }
    }
}

/// Cancellation and callback completion share a lock so a late file callback
/// cannot recreate staging files after the cancelled batch has been cleaned.
private final class ComposerProviderLoad<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var progress: Progress?
    private var isCancelled = false

    func begin(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setProgress(_ progress: Progress) {
        lock.lock()
        self.progress = progress
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { progress.cancel() }
    }

    func finish(_ operation: () throws -> Value) {
        lock.lock()
        guard let continuation, !isCancelled else { lock.unlock(); return }
        self.continuation = nil
        let result = Result { try operation() }
        lock.unlock()
        continuation.resume(with: result)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let continuation = continuation
        self.continuation = nil
        let progress = progress
        lock.unlock()
        progress?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}

struct ComposerPastedContent {
    let text: String
    let files: [StagedAttachment]

    func inserting(into body: String, at selection: NSRange) -> String {
        guard !text.isEmpty else { return body }
        let original = body as NSString
        let location = min(max(selection.location, 0), original.length)
        let length = min(max(selection.length, 0), original.length - location)
        return original.replacingCharacters(in: NSRange(location: location, length: length), with: text)
    }
}
