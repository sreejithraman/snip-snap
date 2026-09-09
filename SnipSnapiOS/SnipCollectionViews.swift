import QuickLook
import SnipSnapCore
import SwiftUI
import UIKit

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
    let clipboard: IOSClipboardModel
    let copyShare: IOSCopyShareCoordinator
    @Binding var sheet: AppSheet?
    let layout: SnipCollectionLayout
    @Binding var editMode: EditMode
    var dismissComposerKeyboard: () -> Void = {}
    var libraryActions: LibraryActionsMenu?
    @State private var isReordering = false
    @State private var inlineEditSession: CompactInlineEditSession?
    @State private var previewURLs: [URL] = []
    @State private var selectedPreviewURL: URL?
    @FocusState private var isInlineEditorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isEditingList: Bool { model.editingListID == model.selectedListID }
    private var showsListEditor: Bool { isEditingList && !model.isSearchPresented }

    var body: some View {
        Group {
            if model.isSearchPresented {
                LibrarySearchView(model: model, clipboard: clipboard, copyShare: copyShare, sheet: $sheet)
            } else if model.visibleSnips.isEmpty {
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
                List(selection: isSelecting ? selectedSnipIDs : nil) {
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
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("recovered-snip-\(recovery.id)")
                    }
                    ForEach(model.visibleSnips) { snip in
                        Group {
                            if isSelecting {
                                SnipRow(
                                    snip: snip,
                                    model: model,
                                    isRecovered: model.isRecoveredSnip(snip.id),
                                    showsStatusIcon: false
                                )
                                .contentShape(Rectangle())
                                .accessibilityAddTraits(.isButton)
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
                                        save: saveInlineEdit,
                                        copy: { Task { await copyShare.copy(snips: [snip], model: model) } }
                                    )
                                } else {
                                    SnipRow(
                                        snip: snip,
                                        model: model,
                                        isRecovered: model.isRecoveredSnip(snip.id),
                                        onPreviewAttachment: previewAttachment,
                                        onCopy: { Task { await copyShare.copy(snips: [snip], model: model) } }
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
                                    .accessibilityAction(named: Text(snip.isPinned ? "Unpin" : "Pin")) {
                                        Task { await model.togglePinned(id: snip.id) }
                                    }
                                    .accessibilityActions {
                                        if snip.isPinned {
                                            Button("Copy") {
                                                Task { await copyShare.copy(snips: [snip], model: model) }
                                            }
                                        } else {
                                            Button(SnipCompletionLanguage.actionTitle(isDone: snip.isDone)) {
                                                Task { await model.toggleDone(id: snip.id) }
                                            }
                                        }
                                    }
                                    .accessibilityIdentifier("snip-\(snip.id)")
                                }
                            }
                        }
                        .tag(snip.id)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .leading) {
                            if !snip.isPinned {
                                SemanticSwipeAction(
                                    title: SnipCompletionLanguage.actionTitle(isDone: snip.isDone),
                                    systemImage: snip.isDone ? "arrow.uturn.backward" : "checkmark",
                                    tint: snip.isDone ? .gray : .green,
                                    role: nil,
                                    accessibilityIdentifier: snip.isDone ? "not-done" : "done"
                                ) {
                                    Task { await model.toggleDone(id: snip.id) }
                                }
                                .id(snip.isDone)
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
                        .contextMenu { itemContextActions(for: snip) }
                        .moveDisabled(snip.isPinned || !model.canReorderVisibleSnips || inlineEditSession != nil)
                    }
                    .onMove(perform: move)
                }
                .listStyle(.plain)
                .environment(\.editMode, isReordering ? .constant(.active) : $editMode)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .modifier(ListEditorRecession(isActive: showsListEditor))
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
        .modifier(CollectionScreenPresentation(
            title: isEditingList ? "" : model.selectedList.name,
            titleColor: model.selectedList.accent.color,
            showsControls: !model.isSearchPresented,
            recedesControls: showsListEditor,
            trailingControls: collectionToolbar
        ))
        .navigationBarTitleDisplayMode(isEditingList ? .inline : .large)
        .overlay(alignment: .top) {
            if isEditingList {
                InlineListEditor(model: model, list: model.selectedList)
                    .id(model.selectedListID)
                    .frame(height: model.isSearchPresented ? 0 : nil)
                    .opacity(model.isSearchPresented ? 0 : 1)
                    .allowsHitTesting(!model.isSearchPresented)
                    .accessibilityHidden(model.isSearchPresented)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? nil : ListEditorPresentation.animation(reduceMotion: false, isPresented: showsListEditor),
            value: showsListEditor
        )
        .onChange(of: model.editingListID) { _, id in
            if id != nil {
                model.isSearchPresented = false
                dismissComposerKeyboard()
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: model.selectedListID) {
            isReordering = false
            cancelInlineEdit()
            guard isSelecting else { return }
            endSelection()
        }
        .onChange(of: model.completionFilter) {
            model.haptics.invalidatePendingFeedback()
            if isSelecting {
                model.selectedSnipIDs.formIntersection(model.visibleSnips.map(\.id))
            }
        }
        .onChange(of: editMode) { _, mode in
            model.haptics.invalidatePendingFeedback()
            if !mode.isEditing { model.endSelectingSnips() }
            if mode.isEditing {
                isReordering = false
                cancelInlineEdit()
                model.selectedSnipID = nil
            }
        }
        .onChange(of: model.searchText) { model.haptics.invalidatePendingFeedback() }
        .onChange(of: model.isSearchPresented) { _, isPresented in
            model.haptics.invalidatePendingFeedback()
            if isPresented { isReordering = false }
        }
    }

    private var emptyTitle: String {
        if hasSearchQuery {
            return String(localized: "No Results")
        }
        return model.completionFilter.emptyStateTitle
    }

    @ViewBuilder
    private var collectionToolbar: some View {
        Group {
            if isReordering {
                Button("Done") {
                    model.haptics.invalidatePendingFeedback()
                    isReordering = false
                }
                .accessibilityIdentifier("finish-reordering")
            } else if isSelecting {
                WorkflowOptionsMenu(model: model)
                SelectionActionsMenu(model: model, copyShare: copyShare, endSelection: endSelection)
                    .disabled(model.selectedSnipIDs.isEmpty)
                Button("Finish Selecting", systemImage: "xmark", action: endSelection)
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("finish-selecting")
            } else {
                WorkflowOptionsMenu(model: model) {
                    model.haptics.invalidatePendingFeedback()
                    cancelInlineEdit()
                    dismissComposerKeyboard()
                    isReordering = true
                }
            }
            if let libraryActions, !isReordering, !isSelecting {
                libraryActions
            }
        }
    }

    private var hasSearchQuery: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptySystemImage: String {
        hasSearchQuery ? "magnifyingglass" : "text.page"
    }

    private var emptyDescription: String {
        if hasSearchQuery {
            return String(localized: "Try a different search.")
        }
        return model.completionFilter == .all
            ? String(localized: "Save text here when you want to keep it close.")
            : String(localized: "Change the filter to see other snips.")
    }

    private var compactEmptyState: some View {
        CollectionEmptyState(title: emptyTitle, systemImage: emptySystemImage, detail: emptyDescription)
            .accessibilityIdentifier("empty-snips")
    }

    private var inlineEditText: Binding<String> {
        Binding(
            get: { inlineEditSession?.text ?? "" },
            set: { value in
                guard var session = inlineEditSession else { return }
                model.haptics.invalidatePendingFeedback()
                session.text = value
                inlineEditSession = session
            }
        )
    }

    private func beginEditing(_ snip: Snip) {
        model.beginEditingSnip(snip.id)
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
        if inlineEditSession != nil { model.haptics.invalidatePendingFeedback() }
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
        model.haptics.invalidatePendingFeedback()
        Task { @MainActor in
            guard let url = await model.prepareAttachment(attachment.id, for: .preview) else {
                return
            }
            previewURLs = [url]
            selectedPreviewURL = url
        }
    }

    @ViewBuilder
    private func itemContextActions(for snip: Snip) -> some View {
        CopyShareActions(
            snips: [snip],
            model: model,
            coordinator: copyShare,
            identifierSuffix: "snip"
        )
        Divider()
        Button("Edit", systemImage: "pencil") {
            model.beginEditingSnip(snip.id)
            sheet = .editSnip(id: snip.id)
        }
        .accessibilityIdentifier("edit-snip")
        Button(snip.isPinned ? "Unpin" : "Pin", systemImage: snip.isPinned ? "pin.slash" : "pin") {
            Task { await model.togglePinned(id: snip.id) }
        }
        if !snip.isPinned {
        Button(
            SnipCompletionLanguage.menuActionTitle(isDone: snip.isDone),
            systemImage: snip.isDone ? "arrow.uturn.backward" : "checkmark"
        ) {
            Task { await model.toggleDone(id: snip.id) }
        }
        }
        if !isSelecting || model.lists.contains(where: { $0.id != snip.listID }) {
            Divider()
        }
        if !isSelecting {
            Button("Select", systemImage: "checkmark.circle") {
                cancelInlineEdit()
                dismissComposerKeyboard()
                isReordering = false
                model.selectSnips([snip.id])
                editMode = .active
            }
            .accessibilityIdentifier("select-snip")
        }
        MoveSnipMenu(model: model, snip: snip)
        Divider()
        Button(role: .destructive) {
            Task { await model.deleteSnip(id: snip.id) }
        } label: {
            Label {
                Text("Delete")
            } icon: {
                Image(systemName: "trash")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red)
            }
        }
        .tint(.red)
        .accessibilityIdentifier("delete-context-snip")
    }

    private func move(from source: IndexSet, to destination: Int) {
        var orderedIDs = model.visibleSnips.map(\.id)
        orderedIDs.move(fromOffsets: source, toOffset: destination)
        Task { _ = await model.placeVisibleSnips(orderedIDs) }
    }

    private func endSelection() {
        model.endSelectingSnips()
        editMode = .inactive
    }

    private var isSelecting: Bool {
        editMode.isEditing
    }

    private var selectedSnipIDs: Binding<Set<UUID>> {
        Binding(
            get: { model.selectedSnipIDs },
            set: { model.selectSnips($0) }
        )
    }
}

private struct CompactInlineSnipEditor: View {
    let snip: Snip
    let model: IOSAppModel
    @Binding var text: String
    let isSaving: Bool
    @FocusState.Binding var isFocused: Bool
    let previewAttachment: (SnipAttachment) -> Void
    let cancel: () -> Void
    let save: () -> Void
    let copy: () -> Void

    private var canSave: Bool {
        !isSaving
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !snip.attachments.isEmpty)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if snip.isPinned {
                SnipCopyControl(action: copy)
                .accessibilityLabel("Copy Snip")
            } else {
                Image(systemName: snip.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

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
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(isSaving)
                    .accessibilityLabel("Cancel Editing")
                    .accessibilityIdentifier("inline-snip-cancel")

                    AppProminentActionButton(action: save) {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.bold))
                            .frame(width: 46, height: 36)
                    }
                    .disabled(!canSave)
                    .accessibilityLabel("Save Snip")
                    .accessibilityIdentifier("inline-snip-save")
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct CollectionScreenPresentation<TrailingControls: View>: ViewModifier {
    let title: String
    var titleColor: Color = .primary
    var showsControls = true
    var recedesControls = false
    let trailingControls: TrailingControls

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .background {
                RoundedNavigationTitle(color: UIColor(titleColor))
                    .frame(width: 0, height: 0)
            }
            .toolbar {
                if showsControls {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        trailingControls
                            .tint(recedesControls ? Color.secondary : SnipSnapTheme.controlTint)
                    }
                    .sharedBackgroundVisibility(recedesControls ? .hidden : .automatic)
                }
            }
    }
}

/// Style this screen's native title while keeping its scroll and accessibility behavior.
private struct RoundedNavigationTitle: UIViewControllerRepresentable {
    let color: UIColor

    func makeUIViewController(context: Context) -> TitleController {
        TitleController()
    }

    func updateUIViewController(_ controller: TitleController, context: Context) {
        controller.titleColor = color
        controller.applyAppearance()
    }

    final class TitleController: UIViewController {
        var titleColor: UIColor = .label

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyAppearance()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyAppearance()
        }

        func applyAppearance() {
            guard let navigationController,
                  let item = navigationController.topViewController?.navigationItem else { return }
            let bar = navigationController.navigationBar
            func styled(_ source: UINavigationBarAppearance) -> UINavigationBarAppearance {
                let appearance = source.copy() as! UINavigationBarAppearance
                appearance.titleTextAttributes[.font] = UIFont.rounded(size: 17, weight: .semibold)
                appearance.largeTitleTextAttributes[.font] = UIFont.rounded(size: 34, weight: .bold)
                appearance.titleTextAttributes[.foregroundColor] = titleColor
                appearance.largeTitleTextAttributes[.foregroundColor] = titleColor
                return appearance
            }
            item.standardAppearance = styled(bar.standardAppearance)
            item.scrollEdgeAppearance = styled(bar.scrollEdgeAppearance ?? bar.standardAppearance)
            item.compactAppearance = styled(bar.compactAppearance ?? bar.standardAppearance)
        }
    }
}

struct CollectionEmptyState: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3.weight(.regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct SnipRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snip: Snip
    let model: IOSAppModel
    let isRecovered: Bool
    var showsStatusIcon = true
    @State private var isChangingCompletion = false
    var onPreviewAttachment: ((SnipAttachment) -> Void)? = nil
    var onCopy: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsStatusIcon {
                if snip.isPinned, let onCopy {
                    SnipCopyControl(action: onCopy)
                    .accessibilityLabel("Copy Snip")
                    .accessibilityIdentifier("copy-pinned-snip-\(snip.id)")
                } else {
                    Image(systemName: "circle").hidden().overlay {
                Button {
                    guard !isChangingCompletion else { return }
                    isChangingCompletion = true
                    Task { @MainActor in
                        _ = await model.toggleDone(id: snip.id)
                        isChangingCompletion = false
                    }
                } label: {
                    Image(systemName: snip.isDone ? "checkmark.circle.fill" : "circle")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: snip.isDone)
                        .font(.body)
                        .foregroundStyle(snip.isDone
                            ? AnyShapeStyle(model.selectedList.accent.color)
                            : AnyShapeStyle(.tertiary))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isChangingCompletion)
                .accessibilityLabel(SnipCompletionLanguage.menuActionTitle(isDone: snip.isDone))
                .accessibilityValue(SnipCompletionLanguage.stateTitle(isDone: snip.isDone))
                .accessibilityIdentifier("completion-\(snip.id)")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(SnipTextPreview.displayText(snip.content, lineLimit: 3))
                    .font(.body)
                    .foregroundStyle(snip.isDone ? .secondary : .primary)
                    .strikethrough(snip.isDone)
                    .lineLimit(3)
                SnipRowMetadata(date: snip.updatedAt, isPinned: snip.isPinned)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: onPreviewAttachment == nil ? .combine : .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            snip.isPinned ? String(localized: "Pinned") : SnipCompletionLanguage.stateTitle(isDone: snip.isDone)
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

// Keep the checkbox's layout footprint while allowing a full touch target.
struct SnipCopyControl: View {
    let action: () -> Void

    var body: some View {
        Image(systemName: "circle")
            .hidden()
            .overlay {
                Button(action: action) {
                    Image(systemName: "doc.on.doc")
                        .font(.subheadline)
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
    }
}

struct SnipRowMetadata: View {
    let date: Date
    let isPinned: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(date, format: .relative(presentation: .named))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct LibrarySearchView: View {
    let model: IOSAppModel
    let clipboard: IOSClipboardModel
    let copyShare: IOSCopyShareCoordinator
    @Binding var sheet: AppSheet?
    @State private var previewURL: URL?

    var body: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = LibrarySearchResults(
            query: query,
            snips: model.snips,
            lists: model.lists,
            clipboard: clipboard.entries,
            sortMode: model.sortMode,
            sourceLabel: { $0.displaySourceLabel }
        )
        Group {
            if query.isEmpty {
                CollectionEmptyState(
                    title: String(localized: "Search All"),
                    systemImage: "magnifyingglass",
                    detail: String(localized: "Find snips in every list and Clipboard.")
                )
                .accessibilityIdentifier("search-prompt")
            } else if results.isEmpty {
                CollectionEmptyState(
                    title: String(localized: "No Results"),
                    systemImage: "magnifyingglass",
                    detail: String(localized: "Try a different search.")
                )
                .accessibilityIdentifier("empty-search")
            } else {
                List {
                    ForEach(results.lists) { group in
                        Section {
                            ForEach(group.snips) { snip in
                                snipResult(snip)
                            }
                        } header: {
                            Label(group.list.displayName, systemImage: group.list.systemImage)
                                .foregroundStyle(group.list.accent.color)
                                .accessibilityIdentifier("search-section-\(group.list.id)")
                        }
                    }
                    if !results.clipboard.isEmpty {
                        Section {
                            ForEach(results.clipboard) { entry in
                                clipboardResult(entry)
                            }
                        } header: {
                            Label("Clipboard", systemImage: "clipboard")
                                .foregroundStyle(.primary)
                                .accessibilityIdentifier("search-section-clipboard")
                        }
                    }
                }
                .listStyle(.plain)
                .textCase(nil)
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("global-search-results")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .quickLookPreview($previewURL)
        .task { await clipboard.load() }
        .overlay(alignment: .bottom) {
            if clipboard.copied {
                Label("Copied", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        clipboard.copied = false
                    }
            }
        }
    }

    private func snipResult(_ snip: Snip) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SnipCopyControl {
                Task { await copyShare.copy(snips: [snip], model: model) }
            }
            .accessibilityLabel("Copy Snip")
            .accessibilityIdentifier("copy-search-snip-\(snip.id)")
            SnipRow(
                snip: snip,
                model: model,
                isRecovered: model.isRecoveredSnip(snip.id),
                showsStatusIcon: false,
                onPreviewAttachment: { attachment in
                    Task { previewURL = await model.prepareAttachment(attachment.id, for: .preview) }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture { sheet = .editSnip(id: snip.id) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Open snip")
            .accessibilityAction { sheet = .editSnip(id: snip.id) }
            .accessibilityIdentifier("search-snip-\(snip.id)")
        }
        .listRowSeparator(.hidden)
        .contextMenu {
            Button("Edit", systemImage: "pencil") { sheet = .editSnip(id: snip.id) }
            Button("Copy", systemImage: "doc.on.doc") {
                Task { await copyShare.copy(snips: [snip], model: model) }
            }
            MoveSnipMenu(model: model, snip: snip)
        }
    }

    private func clipboardResult(_ entry: ClipboardEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SnipCopyControl { clipboard.copy(entry) }
                .accessibilityLabel("Copy Clipboard Entry")
            VStack(alignment: .leading, spacing: 6) {
                if let image = entry.imageRepresentations.first.flatMap({ UIImage(data: $0.data) }) {
                    Image(uiImage: image)
                        .resizable().scaledToFit().frame(maxHeight: 120)
                }
                Text(clipboardTitle(entry))
                    .lineLimit(3)
                SnipRowMetadata(date: entry.capturedAt, isPinned: entry.isPinned)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("search-clipboard-\(entry.id)")
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { clipboard.copy(entry) }
            Button(entry.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                Task { await clipboard.togglePin(entry) }
            }
        }
    }

    private func clipboardTitle(_ entry: ClipboardEntry) -> String {
        if !entry.text.isEmpty { return entry.text }
        if !entry.ownedFiles.isEmpty { return entry.ownedFiles.map(\.name).joined(separator: ", ") }
        return entry.imageRepresentations.isEmpty ? String(localized: "Clipboard Entry") : String(localized: "Image")
    }

}
