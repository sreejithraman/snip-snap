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
        view.onFocusRefused = { [weak coordinator = context.coordinator] in coordinator?.followSystemFocusLoss() }
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
        context.coordinator.isUpdatingView = true
        defer { context.coordinator.isUpdatingView = false }
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
        view.requestFocus(isEnabled && isFocused)
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

    static func dismantleUIView(_ view: ComposerTextView, coordinator: Coordinator) {
        coordinator.isDismantled = true
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextInput
        var isUpdatingView = false
        var isDismantled = false
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

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard isUserFocusChange(textView) else { return }
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard isUserFocusChange(textView) else { return }
            // UIKit also resigns a field SwiftUI is removing, such as when a rotation or fold swaps
            // the compact and regular composers, and SwiftUI may dismantle it only afterwards.
            // That is not a blur, so decide once the removal has finished. Owners that replace
            // a field on purpose clear focus themselves.
            DispatchQueue.main.async { [self] in
                guard !isDismantled, textView.window != nil, !textView.isFirstResponder else { return }
                followSystemFocusLoss()
            }
        }

        /// The system can end editing or refuse focus, as when an iPhone Duo moves between panels.
        /// Forcing focus back would fight the keyboard service, so clear it: navigation returns and
        /// one tap resumes typing.
        func followSystemFocusLoss() {
            guard !isDismantled else { return }
            parent.isFocused = false
        }

        /// SwiftUI-driven focus changes must not echo back through the binding.
        private func isUserFocusChange(_ textView: UITextView) -> Bool {
            !isUpdatingView && !isDismantled
                && (textView as? ComposerTextView)?.isApplyingRequestedFocus != true
        }
    }
}

final class ComposerTextView: UITextView {
    var onPasteAttachments: ([NSItemProvider], NSRange) -> Void = { _, _ in }
    var isPasteEnabled = true
    var attachmentPasteSelection: NSRange?
    var onFocusRefused: () -> Void = {}
    let placeholder = UILabel()
    private(set) var isApplyingRequestedFocus = false
    private var requestedFocus = false
    private var isFocusSyncScheduled = false

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

    /// Applies SwiftUI's focus after the current SwiftUI update. A responder change inside that
    /// update re-enters SwiftUI's view graph, which loops forever when a rotation or fold swaps
    /// the compact and regular layouts.
    func requestFocus(_ focused: Bool) {
        requestedFocus = focused
        scheduleFocusSync()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleFocusSync()
    }

    private func scheduleFocusSync() {
        guard !isFocusSyncScheduled, window != nil, requestedFocus != isFirstResponder else { return }
        isFocusSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isFocusSyncScheduled = false
            guard window != nil, requestedFocus != isFirstResponder else { return }
            isApplyingRequestedFocus = true
            defer { isApplyingRequestedFocus = false }
            if !requestedFocus {
                resignFirstResponder()
            } else if !becomeFirstResponder() {
                onFocusRefused()
            }
        }
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
        if action == #selector(paste(_:)), isEditable, UIPasteboard.general.numberOfItems > 0 {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

enum ComposerPasteFailure: Error {
    case empty, unreadable

    var message: String {
        switch self {
        case .empty: String(localized: "There’s nothing to paste. Copy something, then try again.")
        case .unreadable: String(localized: "Couldn’t read the clipboard. If Paste from Other Apps is set to Deny, change it to Allow in Settings, then try again.")
        }
    }

    var diagnosticCode: String {
        switch self {
        case .empty: "snip.emptyClipboard"
        case .unreadable: "snip.clipboardUnreadable"
        }
    }
}

/// Each item's text goes in the body and its non-text data becomes an attachment. A file URL stays
/// out of the body: it only points at the attachment and can expose private folder names.
@MainActor
enum ComposerPasteboard {
    static func isAttachment(_ provider: NSItemProvider) -> Bool {
        attachmentType(of: provider) != nil
    }

    /// Non-text content has no body form, so it is kept as a file. Apps such as Files register private
    /// file-reference types first, so a type with a file extension wins over undeclared ones.
    private static func attachmentType(of provider: NSItemProvider) -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return UTType.fileURL.identifier
        }
        let registered = provider.registeredTypeIdentifiers
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return registered.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
        }
        if isText(provider) { return registered.first(where: isFileBesideText) }
        return registered.first { UTType($0)?.preferredFilenameExtension != nil }
            ?? registered.first { UTType($0).map { $0.isDeclared && $0.conforms(to: .data) } == true }
            ?? registered.first
    }

    /// A text item can carry a real file, such as a PDF. Its rich-text forms only restate the text.
    private static func isFileBesideText(_ identifier: String) -> Bool {
        guard let type = UTType(identifier), type.isDeclared, type.preferredFilenameExtension != nil else { return false }
        return ![UTType.text, .url, .rtfd, .flatRTFD, .webArchive].contains { type.conforms(to: $0) }
    }

    private static func isText(_ provider: NSItemProvider) -> Bool {
        provider.canLoadObject(ofClass: NSString.self) || provider.canLoadObject(ofClass: NSAttributedString.self)
    }

    /// Paste and Save stages the clipboard through its providers, which load the content off the main
    /// thread. Under Ask, iOS can refuse those loads until a direct read passes the paste permission,
    /// so a refused load gets one access check and one retry. Local staging errors surface as they are.
    static func stageForSaving(
        from pasteboard: UIPasteboard,
        in root: URL,
        providers: (UIPasteboard) -> [NSItemProvider] = { $0.itemProviders },
        requestAccess: (UIPasteboard) async throws -> Void = { pasteboard in
            try await Task.detached { try ComposerPasteboard.requestAccess(to: pasteboard) }.value
        }
    ) async throws -> ComposerPastedContent {
        guard pasteboard.numberOfItems > 0, !pasteboard.types.isEmpty else { throw ComposerPasteFailure.empty }
        do {
            return try await stageForSaving(loading: providers(pasteboard), in: root)
        } catch is ProviderLoadFailure {
            try await requestAccess(pasteboard)
            do {
                return try await stageForSaving(loading: providers(pasteboard), in: root)
            } catch let failure as ProviderLoadFailure {
                throw failure.underlying
            }
        }
    }

    /// Reads the clipboard directly, which shows or passes the paste permission. Paste and Save runs it
    /// off the main thread. It reads the smallest form: strings, URLs, or a non-content type such as
    /// Files' private reference. A first item with only content types, such as a video, is read in full.
    nonisolated static func requestAccess(to pasteboard: UIPasteboard) throws {
        let types = pasteboard.types
        let isReadable = if pasteboard.hasStrings {
            pasteboard.strings?.isEmpty == false
        } else if pasteboard.hasURLs {
            pasteboard.urls?.isEmpty == false
        } else if let type = types.first(where: { UTType($0)?.conforms(to: .content) != true }) ?? types.first {
            pasteboard.data(forPasteboardType: type) != nil
        } else {
            false
        }
        guard isReadable else { throw ComposerPasteFailure.unreadable }
    }

    private static func stageForSaving(loading providers: [NSItemProvider], in root: URL) async throws -> ComposerPastedContent {
        // The clipboard reports content, so providers without types mean the load was refused.
        guard providers.contains(where: { !$0.registeredTypeIdentifiers.isEmpty }) else {
            throw ProviderLoadFailure(underlying: ComposerPasteFailure.unreadable)
        }
        let pasted = try await stageLoading(providers, in: root)
        guard pasted.files.isEmpty,
              pasted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return pasted }
        throw ComposerPasteFailure.empty
    }

    static func stage(_ providers: [NSItemProvider], in root: URL) async throws -> ComposerPastedContent {
        do {
            return try await stageLoading(providers, in: root)
        } catch let failure as ProviderLoadFailure {
            throw failure.underlying
        }
    }

    private static func stageLoading(_ providers: [NSItemProvider], in root: URL) async throws -> ComposerPastedContent {
        var text = ""
        var files: [StagedAttachment] = []
        do {
            for provider in providers
            where isText(provider) && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                try Task.checkCancellation()
                let load = ComposerProviderLoad<String>()
                let value = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        guard load.begin(continuation) else { return }
                        let finish: @Sendable (String?, (any Error)?) -> Void = { string, error in
                            load.finish {
                                if let error { throw ProviderLoadFailure(underlying: error) }
                                guard let string else { throw ProviderLoadFailure(underlying: CocoaError(.fileReadUnknown)) }
                                return string
                            }
                        }
                        let progress = provider.canLoadObject(ofClass: NSString.self)
                            ? provider.loadObject(ofClass: String.self) { finish($0, $1) }
                            : provider.loadObject(ofClass: NSAttributedString.self) {
                                finish(($0 as? NSAttributedString)?.string, $1)
                            }
                        load.setProgress(progress)
                    }
                } onCancel: { load.cancel() }
                let isFileURL = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?.isFileURL == true
                if !isFileURL || !isAttachment(provider) { text += value }
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

    private static func stageAttachments(_ providers: [NSItemProvider], in root: URL) async throws -> [StagedAttachment] {
        let batch = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var staged: [StagedAttachment] = []
        do {
            for provider in providers {
                guard let type = attachmentType(of: provider) else { continue }
                try Task.checkCancellation()
                let isFileURL = type == UTType.fileURL.identifier
                let directory = batch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let suggestedName = provider.suggestedName
                let load = ComposerProviderLoad<StagedAttachment>()
                let file: StagedAttachment = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        guard load.begin(continuation) else { return }
                        let copy: @Sendable (URL?, Error?) -> Void = { source, error in
                            load.finish {
                                if let error { throw ProviderLoadFailure(underlying: error) }
                                guard let source, source.isFileURL else { throw SnipLibraryError.attachmentCopyFailed }
                                let access = source.startAccessingSecurityScopedResource()
                                defer { if access { source.stopAccessingSecurityScopedResource() } }
                                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                                    throw SnipLibraryError.attachmentCopyFailed
                                }
                                var name = URL(fileURLWithPath: suggestedName ?? source.lastPathComponent).lastPathComponent
                                if name.isEmpty { name = "Pasted File" }
                                if URL(fileURLWithPath: name).pathExtension.isEmpty {
                                    let suffix = isFileURL ? source.pathExtension : UTType(type)?.preferredFilenameExtension
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
                        if isFileURL {
                            progress = provider.loadObject(ofClass: URL.self) { url, error in copy(url, error) }
                        } else {
                            progress = provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: copy)
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

/// A provider load that failed or was refused, unlike a local staging error. Only these can mean the
/// paste permission has not passed yet.
private struct ProviderLoadFailure: Error {
    let underlying: any Error
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
