import QuickLook
import SnipSnapCore
import SwiftUI

enum SnipCollectionLayout: Equatable {
    case compactStack
    case inlineList
}

private struct CompactInlineEditSession {
    let original: Snip
    var text: String
    var isSaving = false
}

struct SnipCollectionView: View {
    let model: IOSAppModel
    let copyShare: IOSCopyShareCoordinator
    @Binding var sheet: AppSheet?
    let layout: SnipCollectionLayout
    var dismissComposerKeyboard: () -> Void = {}
    @State private var editMode: EditMode = .inactive
    @State private var isSelecting = false
    @State private var inlineEditSession: CompactInlineEditSession?
    @State private var previewURLs: [URL] = []
    @State private var selectedPreviewURL: URL?
    @FocusState private var isInlineEditorFocused: Bool

    var body: some View {
        Group {
            if model.visibleSnips.isEmpty {
                if layout == .compactStack {
                    compactEmptyState
                } else {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: emptySystemImage,
                        description: Text(emptyDescription)
                    )
                    .accessibilityIdentifier("empty-snips")
                }
            } else {
                List {
                    ForEach(model.recoverySnapshot.pendingSnips.filter { recovery in
                        recovery.recovered.listID == model.selectedListID
                            && !model.snips.contains { $0.id == recovery.id }
                    }) { recovery in
                        Button {
                            sheet = .recoverSnip(id: recovery.id)
                        } label: {
                            RecoveredSnipRow(recovery: recovery)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("recovered-snip-\(recovery.id)")
                    }
                    ForEach(model.visibleSnips) { snip in
                        Group {
                            if isSelecting {
                                Button {
                                    toggleSelection(snip.id)
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: model.selectedSnipIDs.contains(snip.id)
                                            ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(
                                                model.selectedSnipIDs.contains(snip.id)
                                                    ? SnipSnapTheme.controlTint : Color.secondary
                                            )
                                            .accessibilityHidden(true)
                                        SnipRow(
                                            snip: snip,
                                            model: model,
                                            isRecovered: model.isRecoveredSnip(snip.id),
                                            showsStatusIcon: false
                                        )
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(
                                    model.selectedSnipIDs.contains(snip.id) ? .isSelected : []
                                )
                                .accessibilityIdentifier("snip-\(snip.id)")
                            } else {
                                if inlineEditSession?.original.id == snip.id {
                                    CompactInlineSnipEditor(
                                        snip: snip,
                                        model: model,
                                        text: inlineEditText,
                                        isSaving: inlineEditSession?.isSaving == true,
                                        isFocused: $isInlineEditorFocused,
                                        previewAttachment: previewAttachment,
                                        cancel: cancelInlineEdit,
                                        save: saveInlineEdit
                                    )
                                } else {
                                    SnipRow(
                                        snip: snip,
                                        model: model,
                                        isRecovered: model.isRecoveredSnip(snip.id),
                                        onPreviewAttachment: previewAttachment
                                    )
                                    .contentShape(Rectangle())
                                    .highPriorityGesture(
                                        TapGesture(count: 2).onEnded {
                                            beginEditing(snip)
                                        }
                                    )
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityHint("Double tap to edit. Touch and hold for actions.")
                                    .accessibilityAction {
                                        beginEditing(snip)
                                    }
                                    .accessibilityAction(named: "Edit") {
                                        beginEditing(snip)
                                    }
                                    .accessibilityIdentifier("snip-\(snip.id)")
                                }
                            }
                        }
                        .tag(snip.id)
                        .swipeActions(edge: .leading) {
                            SemanticSwipeAction(
                                title: SnipCompletionLanguage.actionTitle(isDone: snip.isDone),
                                systemImage: snip.isDone ? "circle" : "checkmark",
                                tint: snip.isDone ? .gray : .green,
                                role: nil,
                                accessibilityIdentifier: snip.isDone
                                    ? "not-done" : "done"
                            ) {
                                Task { await model.toggleDone(id: snip.id) }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            SemanticSwipeAction(
                                title: String(localized: "Delete"),
                                systemImage: "trash",
                                tint: .red,
                                role: .destructive,
                                accessibilityIdentifier: "delete-snip"
                            ) {
                                Task { await model.deleteSnip(id: snip.id) }
                            }
                        }
                        .contextMenu {
                            Button(SnipCompletionLanguage.actionTitle(isDone: snip.isDone)) {
                                Task { await model.toggleDone(id: snip.id) }
                            }
                            Button("Edit") { beginEditing(snip) }
                            Button("Edit Attachments…", systemImage: "paperclip") {
                                model.selectedSnipID = snip.id
                                sheet = .editSnip(id: snip.id)
                            }
                            .accessibilityIdentifier("edit-attachments")
                            MoveSnipMenu(model: model, snip: snip)
                            Divider()
                            CopyShareActions(
                                snips: [snip],
                                model: model,
                                coordinator: copyShare,
                                identifierSuffix: "snip"
                            )
                            Divider()
                            Button("Delete", role: .destructive) {
                                Task { await model.deleteSnip(id: snip.id) }
                            }
                        }
                    }
                    .onMove(perform: move)
                    .moveDisabled(!model.canReorderVisibleSnips)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onChanged { value in
                guard value.translation.height > 8,
                      abs(value.translation.height) > abs(value.translation.width)
                else { return }
                dismissComposerKeyboard()
            }
        )
        .quickLookPreview($selectedPreviewURL, in: previewURLs)
        .navigationTitle(model.selectedList.name)
        .modifier(PhoneAwareSearchModifier(
            isEnabled: layout != .compactStack,
            text: Binding(
                get: { model.searchText },
                set: { model.searchText = $0 }
            )
        ))
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isSelecting {
                    SelectionActionsMenu(
                        model: model,
                        copyShare: copyShare,
                        endSelection: endSelection
                    )
                        .disabled(model.selectedSnipIDs.isEmpty)
                } else {
                    WorkflowOptionsMenu(model: model)
                }
                Button(isSelecting ? "Done" : "Edit") {
                    setSelecting(!isSelecting)
                }
                    .disabled(model.visibleSnips.isEmpty)
                    .accessibilityIdentifier("select-snips")
            }
        }
        .onChange(of: model.selectedListID) {
            cancelInlineEdit()
            guard isSelecting else { return }
            setSelecting(false)
        }
    }

    private var emptyTitle: String {
        if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "No Results")
        }
        return model.completionFilter.emptyStateTitle
    }

    private var emptySystemImage: String {
        model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "text.page" : "magnifyingglass"
    }

    private var emptyDescription: String {
        if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Try a different search.")
        }
        return model.completionFilter == .all
            ? String(localized: "Save text here when you want to keep it close.")
            : String(localized: "Change the filter to see other snips.")
    }

    private var compactEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptySystemImage)
                .font(.title3.weight(.regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(emptyTitle)
                .font(.subheadline.weight(.semibold))
            Text(emptyDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("empty-snips")
    }

    private var inlineEditText: Binding<String> {
        Binding(
            get: { inlineEditSession?.text ?? "" },
            set: { value in
                guard var session = inlineEditSession else { return }
                session.text = value
                inlineEditSession = session
            }
        )
    }

    private func beginEditing(_ snip: Snip) {
        model.selectedSnipID = snip.id
        inlineEditSession = CompactInlineEditSession(
            original: snip,
            text: snip.content
        )
        Task { @MainActor in
            await Task.yield()
            isInlineEditorFocused = true
        }
    }

    private func cancelInlineEdit() {
        guard inlineEditSession?.isSaving != true else { return }
        isInlineEditorFocused = false
        inlineEditSession = nil
    }

    private func saveInlineEdit() {
        guard var session = inlineEditSession,
              !session.isSaving,
              !session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !session.original.attachments.isEmpty else { return }
        session.isSaving = true
        inlineEditSession = session
        Task { @MainActor in
            let saved = await model.editSnip(
                session.original,
                content: session.text
            )
            guard inlineEditSession?.original.id == session.original.id else { return }
            if saved {
                isInlineEditorFocused = false
                inlineEditSession = nil
            } else {
                session.isSaving = false
                inlineEditSession = session
            }
        }
    }

    private func previewAttachment(_ attachment: SnipAttachment) {
        Task { @MainActor in
            guard let url = await model.prepareAttachment(attachment.id, for: .preview) else {
                return
            }
            previewURLs = [url]
            selectedPreviewURL = url
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var orderedIDs = model.visibleSnips.map(\.id)
        orderedIDs.move(fromOffsets: source, toOffset: destination)
        Task { _ = await model.placeVisibleSnips(orderedIDs) }
    }

    private func endSelection() {
        setSelecting(false)
    }

    private func toggleSelection(_ id: UUID) {
        if model.selectedSnipIDs.contains(id) {
            model.selectedSnipIDs.remove(id)
        } else {
            model.selectedSnipIDs.insert(id)
        }
    }

    private func setSelecting(_ selecting: Bool) {
        if selecting { cancelInlineEdit() }
        isSelecting = selecting
        editMode = selecting ? .active : .inactive
        model.selectedSnipIDs = []
        if selecting { model.selectedSnipID = nil }
    }
}

private struct CompactInlineSnipEditor: View {
    @Environment(\.colorScheme) private var colorScheme

    let snip: Snip
    let model: IOSAppModel
    @Binding var text: String
    let isSaving: Bool
    @FocusState.Binding var isFocused: Bool
    let previewAttachment: (SnipAttachment) -> Void
    let cancel: () -> Void
    let save: () -> Void

    private var canSave: Bool {
        !isSaving
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !snip.attachments.isEmpty)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: snip.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                TextField("Snip text", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .disabled(isSaving)
                    .accessibilityIdentifier("inline-snip-text")

                if !snip.attachments.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(snip.attachments.prefix(3))) { attachment in
                            CompactAttachmentPreviewButton(
                                attachment: attachment,
                                model: model,
                                action: { previewAttachment(attachment) }
                            )
                        }
                        if snip.attachments.count > 3 {
                            Text("+\(snip.attachments.count - 3)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 8)

                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 36)
                            .background(
                                SnipSnapTheme.standaloneActionFill,
                                in: Capsule(style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                    .accessibilityLabel("Cancel Editing")
                    .accessibilityIdentifier("inline-snip-cancel")

                    Button(action: save) {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.bold))
                            .foregroundStyle(
                                canSave
                                    ? SnipSnapTheme.primaryActionLabel(for: colorScheme)
                                    : SnipSnapTheme.disabledPrimaryActionLabel(for: colorScheme)
                            )
                            .frame(width: 46, height: 36)
                            .background {
                                Capsule(style: .continuous).fill(
                                    canSave
                                        ? SnipSnapTheme.primaryActionTint(for: colorScheme)
                                        : SnipSnapTheme.disabledPrimaryActionTint(for: colorScheme)
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                    .accessibilityLabel("Save Snip")
                    .accessibilityIdentifier("inline-snip-save")
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct PhoneAwareSearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: String(localized: "Search Snips")
            )
        } else {
            content
        }
    }
}

private struct SnipRow: View {
    let snip: Snip
    let model: IOSAppModel
    let isRecovered: Bool
    var showsStatusIcon = true
    var onPreviewAttachment: ((SnipAttachment) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsStatusIcon {
                Image(systemName: snip.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(snip.isDone ? .secondary : .tertiary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(snip.content)
                    .font(.body)
                    .foregroundStyle(snip.isDone ? .secondary : .primary)
                    .strikethrough(snip.isDone)
                    .lineLimit(3)
                Text(snip.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isRecovered {
                    Label("Recovered", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if !snip.attachments.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(snip.attachments.prefix(3))) { attachment in
                            if let onPreviewAttachment {
                                CompactAttachmentPreviewButton(
                                    attachment: attachment,
                                    model: model,
                                    action: { onPreviewAttachment(attachment) }
                                )
                            } else {
                                AttachmentStatusThumbnail(attachment: attachment, model: model)
                                    .frame(width: 48, height: 48)
                            }
                        }
                        if snip.attachments.count > 3 {
                            Text("+\(snip.attachments.count - 3)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: onPreviewAttachment == nil ? .combine : .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            SnipCompletionLanguage.stateTitle(isDone: snip.isDone)
        )
    }

    private var accessibilityLabel: String {
        let text = snip.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = snip.attachments.map(\.fileName).joined(separator: ", ")
        return [
            text.isEmpty ? nil : text,
            attachments.isEmpty ? nil : String(localized: "Attachments: \(attachments)"),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private struct CompactAttachmentPreviewButton: View {
    let attachment: SnipAttachment
    let model: IOSAppModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AttachmentStatusThumbnail(attachment: attachment, model: model)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview \(attachment.fileName)")
        .accessibilityIdentifier("compact-attachment-preview-\(attachment.fileName)")
    }
}

private struct AttachmentStatusThumbnail: View {
    let attachment: SnipAttachment
    let model: IOSAppModel

    var body: some View {
        Group {
            if let url = model.attachmentURL(for: attachment.id) {
                AttachmentThumbnail(url: url)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    switch model.attachmentTransferState(for: attachment.id) {
                    case .syncing:
                        ProgressView()
                    case .failed:
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(.red)
                    case .waiting:
                        Image(systemName: "icloud")
                            .foregroundStyle(.secondary)
                    case .available:
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(attachment.fileName), \(stateLabel)")
    }

    private var stateLabel: String {
        switch model.attachmentTransferState(for: attachment.id) {
        case .waiting: String(localized: "waiting for iCloud")
        case .syncing: String(localized: "syncing")
        case .failed: String(localized: "failed")
        case .available: String(localized: "available")
        }
    }
}
