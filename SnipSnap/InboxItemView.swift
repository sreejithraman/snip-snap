import SwiftUI

struct InboxItemRow: View {
    let item: CaptureItem
    let isSelected: Bool
    let isEditing: Bool
    let dragPayload: ClipDragPayload
    let dragSourceController: ClipDragSourceController
    @Binding var editAttachments: [URL]
    @Binding var isSaving: Bool
    let attachmentURL: (ClipAttachment) -> URL
    let onPreviewAttachments: ([URL], URL) -> Void
    let onRemovePreviewURL: (URL) -> Void
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onToggleDone: () -> Void
    let onChooseFiles: () -> Void
    let onCaptureScreenArea: (@escaping @MainActor (URL?) -> Void) -> Void
    let onCancelEdit: () -> Void
    let onSaveEdit: (String, [URL]) async -> Bool
    let onEditError: (String) -> Void
    let onDragBegan: () -> Void
    let onDragEnded: (ClipDragOutcome) -> Void

    @State private var editText = ""
    @State private var temporaryAttachmentURLs: Set<URL> = []
    @State private var editSessionID = UUID()
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Toggle(
                "Done",
                isOn: Binding(
                    get: { item.isDone },
                    set: { _ in onToggleDone() }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .tint(SnipSnapColors.controlTint)
            .focusable(false)
            .padding(.leading, SnipSnapSpacing.cardContentInset)
            .padding(.trailing, SnipSnapSpacing.relatedContent)
            .padding(.vertical, SnipSnapSpacing.cardContentInset)
            .disabled(isEditing)
            .help(item.isDone ? "Mark Not Done" : "Mark Done")

            if isEditing {
                editingBody
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                draggableBody
                    .transition(.opacity)
            }
        }
        .background {
            if !isEditing {
                Color.clear
                    .clipCardTapActions(onSelect: onSelect, onOpen: onOpen)
            }
        }
        .panelContentCardSurface(isSelected: isSelected, isDone: item.isDone)
        .animation(.snappy(duration: 0.18), value: isEditing)
        .onChange(of: isEditing, initial: true) { _, editing in
            guard editing else {
                editSessionID = UUID()
                removeTemporaryAttachments()
                editorFocused = false
                return
            }
            editSessionID = UUID()
            editText = item.content
            Task { @MainActor in
                await Task.yield()
                editorFocused = true
            }
        }
        .onChange(of: isSaving) { _, saving in
            if saving { editSessionID = UUID() }
        }
        .onDisappear(perform: removeTemporaryAttachments)
    }

    private var draggableBody: some View {
        ClipCardBody(
            text: item.content,
            isDone: item.isDone,
            hasAttachments: !item.attachments.isEmpty,
            leadingInset: 0
        ) {
            if !item.attachments.isEmpty {
                AttachmentPreviewStrip(
                    items: attachmentPreviewItems,
                    onPreview: { url in
                        onPreviewAttachments(attachmentPreviewItems.map(\.url), url)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipCardTapActions(onSelect: onSelect, onOpen: onOpen)
        .background {
            ClipDragSourceRegion(
                controller: dragSourceController,
                id: item.id,
                payload: dragPayload,
                onBegan: onDragBegan,
                onEnded: onDragEnded
            )
        }
    }

    private var attachmentPreviewItems: [AttachmentPreviewItem] {
        item.attachments.map { attachment in
            AttachmentPreviewItem(
                attachment: attachment,
                url: attachmentURL(attachment)
            )
        }
    }

    private var editingBody: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            if !editAttachments.isEmpty {
                AttachmentPreviewStrip(
                    items: editAttachmentPreviewItems,
                    onPreview: { url in
                        onPreviewAttachments(editAttachments, url)
                    },
                    onRemove: { item in
                        onRemovePreviewURL(item.url)
                        editAttachments.removeAll { $0 == item.url }
                    }
                )
                .padding(.top, SnipSnapSpacing.cardContentInset)
                .padding(.trailing, SnipSnapSpacing.cardContentInset)
            }

            PanelMultilineTextInput(
                "Clip text",
                text: $editText,
                lineRange: PanelInlineEditMetrics.textLineRange,
                lineSpacing: 2,
                isFocused: editorFocused,
                onFocusChange: { editorFocused = $0 },
                onPasteImages: pasteImagesIntoEdit,
                onSubmit: saveEdit
            )
                .onKeyPress(.escape) {
                    cancelEdit()
                    return .handled
                }
                .onKeyPress("s", phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    saveEdit()
                    return .handled
                }
                .padding(.top, editAttachments.isEmpty ? SnipSnapSpacing.cardContentInset : 0)
                .padding(.trailing, SnipSnapSpacing.cardContentInset)

            editActions
                .padding(.trailing, SnipSnapSpacing.cardContentInset)
                .padding(.bottom, SnipSnapSpacing.cardContentInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editAttachmentPreviewItems: [AttachmentPreviewItem] {
        editAttachments.map(AttachmentPreviewItem.init(url:))
    }

    private func addEditAttachments(_ urls: [URL]) {
        guard !isSaving else { return }
        editAttachments.append(
            contentsOf: PanelFileDropValidation.newFiles(
                in: urls,
                excluding: editAttachments
            )
        )
    }

    @MainActor
    private func pasteImagesIntoEdit(_ images: [PanelPastedImage]) {
        guard !isSaving else { return }
        let sessionID = editSessionID
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                PanelPastedImageStaging.write(images)
            }.value
            switch result {
            case .success(let urls):
                guard editSessionID == sessionID else {
                    removeTemporaryFiles(urls)
                    return
                }
                temporaryAttachmentURLs.formUnion(urls)
                addEditAttachments(urls)
            case .failure(let error):
                onEditError(error.localizedDescription)
            }
        }
    }

    private func captureScreenAreaIntoEdit() {
        guard !isSaving else { return }
        let sessionID = editSessionID
        onCaptureScreenArea { url in
            guard let url else { return }
            guard editSessionID == sessionID else {
                removeTemporaryFiles([url])
                return
            }
            temporaryAttachmentURLs.insert(url)
            addEditAttachments([url])
        }
    }

    private func removeTemporaryAttachments() {
        removeTemporaryFiles(Array(temporaryAttachmentURLs))
        temporaryAttachmentURLs.removeAll()
    }

    private func removeTemporaryFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var editActions: some View {
        HStack(spacing: SnipSnapSpacing.relatedContent) {
            Menu {
                Button("Choose Files…", action: onChooseFiles)
                Button("Capture Screen Area…", action: captureScreenAreaIntoEdit)
            } label: {
                editActionIcon("plus")
                    .panelEmbeddedActionControl()
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .disabled(isSaving)
            .help("Add Attachment")
            .accessibilityLabel("Add Attachment")

            Spacer(minLength: SnipSnapSpacing.relatedContent)

            Button(action: cancelEdit) {
                editActionIcon("xmark")
                    .panelEmbeddedActionControl()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Cancel Editing")
            .accessibilityLabel("Cancel Editing")

            Button(action: saveEdit) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
            }
            .panelEmbeddedProminentActionControl()
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!canSaveEdit)
            .help("Save Clip")
            .accessibilityLabel("Save Clip")
        }
    }

    private func editActionIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .frame(
                width: PanelControlMetrics.floatingIconLength,
                height: PanelControlMetrics.floatingIconLength
            )
    }

    private var canSaveEdit: Bool {
        !isSaving
            && (!editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !editAttachments.isEmpty)
    }

    private func cancelEdit() {
        guard !isSaving else { return }
        editorFocused = false
        onCancelEdit()
    }

    private func saveEdit() {
        guard canSaveEdit else { return }
        isSaving = true
        let text = editText
        let attachments = editAttachments
        Task { @MainActor in
            let saved = await onSaveEdit(text, attachments)
            isSaving = false
            if saved {
                editorFocused = false
            }
        }
    }
}

private extension View {
    func clipCardTapActions(
        onSelect: @escaping () -> Void,
        onOpen: @escaping () -> Void
    ) -> some View {
        contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onOpen)
            .onTapGesture(perform: onSelect)
    }
}

struct ClipCardBody<AttachmentContent: View>: View {
    let text: String
    let isDone: Bool
    let hasAttachments: Bool
    let leadingInset: CGFloat
    @ViewBuilder let attachments: () -> AttachmentContent

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            if hasAttachments {
                attachments()
                    .padding(.top, SnipSnapSpacing.cardContentInset)
                    .padding(.leading, leadingInset)
                    .padding(.trailing, SnipSnapSpacing.cardContentInset)
            }

            ClipCardTextBlock(
                text: text,
                isDone: isDone,
                hasAttachments: hasAttachments,
                leadingPadding: leadingInset
            )
        }
    }
}

struct ClipCardTextBlock: View {
    let text: String
    let isDone: Bool
    let hasAttachments: Bool
    let leadingPadding: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            if !text.isEmpty {
                Text(text)
                    .foregroundStyle(SnipSnapColors.textPrimary)
                    .strikethrough(isDone, color: SnipSnapColors.doneStrikethrough)
                    .opacity(isDone ? SnipSnapColors.doneTextOpacity : 1)
                    .lineLimit(5)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, SnipSnapSpacing.cardContentInset)
        .padding(.top, hasAttachments ? 0 : SnipSnapSpacing.cardContentInset)
        .padding(.bottom, SnipSnapSpacing.cardContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
