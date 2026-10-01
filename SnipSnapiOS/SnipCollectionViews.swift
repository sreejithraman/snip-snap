import QuickLook
import SnipSnapCore
import SwiftUI
import UIKit

enum SnipCollectionLayout: Equatable {
    case compactStack
    case inlineList
}

func listAppearance(for snip: Snip, in lists: [SnipList]) -> SnipListAppearance {
    (lists.first { $0.id == snip.listID } ?? .inbox).accent
}

struct SnipCollectionView: View {
    let model: IOSAppModel
    let clipboard: IOSClipboardModel
    let copyShare: IOSCopyShareCoordinator
    @Binding var sheet: AppSheet?
    let layout: SnipCollectionLayout
    var listID: UUID? = nil
    var isActivePage = true
    @Binding var editMode: EditMode
    let cancelNewList: (UUID) async -> Bool
    var blocksPageSwipe: Binding<Bool> = .constant(false)
    var dismissComposerKeyboard: () -> Void = {}
    var libraryActions: LibraryActionsMenu?
    @State private var isReordering = false
    private var inlineEditDraft: SnipEditorDraft? { model.snipEditorDraft }
    @State private var previewURLs: [URL] = []
    @State private var selectedPreviewURL: URL?
    @FocusState private var isInlineEditorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayedListID: UUID { listID ?? model.selectedListID }
    private var displayedList: SnipList {
        model.lists.first(where: { $0.id == displayedListID }) ?? .inbox
    }
    private var displayedSnips: [Snip] { model.visibleSnips(in: displayedListID) }
    private var isEditingList: Bool {
        model.editingListID == displayedListID
    }
    private var showsListEditor: Bool { isEditingList && !model.isSearchPresented }

    var body: some View {
        Group {
            if model.isSearchPresented {
                LibrarySearchView(model: model, clipboard: clipboard, copyShare: copyShare)
            } else if displayedSnips.isEmpty {
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
                        recovery.recovered.listID == displayedListID
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
                    ForEach(displayedSnips) { snip in
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
                                .accessibilityAction(named: Text(snip.isPinned ? "Unpin" : "Pin")) {
                                    Task { await model.togglePinned(id: snip.id) }
                                }
                                .accessibilityAction(named: "Delete") {
                                    Task { await model.deleteSnip(id: snip.id) }
                                }
                                .accessibilityIdentifier("snip-\(snip.id)")
                            } else {
                                if let draft = inlineEditDraft, draft.original.id == snip.id {
                                    InlineSnipEditor(
                                        draft: draft,
                                        model: model,
                                        isFocused: $isInlineEditorFocused
                                    )
                                } else {
                                    SnipRow(
                                        snip: snip,
                                        model: model,
                                        isRecovered: model.isRecoveredSnip(snip.id),
                                        isReordering: isReordering,
                                        onPreviewAttachment: previewAttachment,
                                        onCopy: { Task { await copyShare.copy(snips: [snip], model: model) } },
                                        onToggleDone: {
                                            await copyShare.toggleDone(snip: snip, model: model)
                                        }
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
                                    .accessibilityAction(named: "Delete") {
                                        Task { await model.deleteSnip(id: snip.id) }
                                    }
                                    .accessibilityActions {
                                        if snip.isPinned {
                                            Button("Copy") {
                                                Task { await copyShare.copy(snips: [snip], model: model) }
                                            }
                                        } else {
                                            Button(SnipCompletionLanguage.actionTitle(isDone: snip.isDone)) {
                                                Task { await copyShare.toggleDone(snip: snip, model: model) }
                                            }
                                        }
                                    }
                                    .accessibilityIdentifier("snip-\(snip.id)")
                                }
                            }
                        }
                        .tag(snip.id)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            if inlineEditDraft == nil { itemContextActions(for: snip) }
                        }
                        .moveDisabled(snip.isPinned || !model.canReorderVisibleSnips || inlineEditDraft != nil)
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
        .attachmentPreview($selectedPreviewURL, in: previewURLs)
        .modifier(CollectionScreenPresentation(
            title: isEditingList ? "" : displayedList.name,
            titleColor: displayedList.accent.color,
            showsControls: !model.isSearchPresented,
            recedesControls: showsListEditor,
            trailingControls: collectionToolbar
        ))
        .overlay(alignment: .top) {
            if isEditingList {
                InlineListEditor(model: model, list: displayedList, cancelNewList: cancelNewList)
                    .id(displayedListID)
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
            if isActivePage && id != nil {
                model.isSearchPresented = false
                dismissComposerKeyboard()
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: isActivePage) { _, isActive in
            if !isActive { isInlineEditorFocused = false }
        }
        .onChange(of: isReordering || inlineEditDraft != nil, initial: true) { _, blocked in
            blocksPageSwipe.wrappedValue = blocked
        }
        .onAppear {
            blocksPageSwipe.wrappedValue = isReordering || inlineEditDraft != nil
        }
        .onDisappear { blocksPageSwipe.wrappedValue = false }
        .onChange(of: model.selectedListID) {
            guard isActivePage else { return }
            isReordering = false
            isInlineEditorFocused = false
        }
        .onChange(of: model.completionFilter) {
            model.haptics.invalidatePendingFeedback()
            if isActivePage && isSelecting {
                model.selectedSnipIDs.formIntersection(displayedSnips.map(\.id))
            }
        }
        .onChange(of: editMode) { _, mode in
            guard isActivePage else { return }
            model.haptics.invalidatePendingFeedback()
            if !mode.isEditing { model.endSelectingSnips() }
            if mode.isEditing {
                guard inlineEditDraft == nil else {
                    editMode = .inactive
                    return
                }
                isReordering = false
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
            return String(localized: "No results")
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
                    guard inlineEditDraft == nil else { return }
                    model.haptics.invalidatePendingFeedback()
                    dismissComposerKeyboard()
                    isReordering = true
                }
                .disabled(inlineEditDraft?.canDismiss == false)
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
            ? String(localized: "Type or paste text below.")
            : String(localized: "Change the filter to see other snips.")
    }

    private var compactEmptyState: some View {
        CollectionEmptyState(title: emptyTitle, systemImage: emptySystemImage, detail: emptyDescription)
            .accessibilityIdentifier("empty-snips")
    }

    private func beginEditing(_ snip: Snip) {
        guard model.beginInlineSnipEdit(snip) else { return }
        dismissComposerKeyboard()
        isReordering = false
        if isSelecting { endSelection() }
        Task { @MainActor in
            await Task.yield()
            guard inlineEditDraft?.original.id == snip.id else { return }
            isInlineEditorFocused = true
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
            beginEditing(snip)
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
            Task { await copyShare.toggleDone(snip: snip, model: model) }
        }
        }
        if !isSelecting || model.lists.contains(where: { $0.id != snip.listID }) {
            Divider()
        }
        if !isSelecting {
            Button("Select", systemImage: "checkmark.circle") {
                guard inlineEditDraft == nil else { return }
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
        var orderedIDs = displayedSnips.map(\.id)
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
    let snip: Snip
    let model: IOSAppModel
    let isRecovered: Bool
    var showsStatusIcon = true
    var isReordering = false
    @State private var isChangingCompletion = false
    var onPreviewAttachment: ((SnipAttachment) -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onToggleDone: (() async -> Bool)? = nil

    private var appearance: SnipListAppearance {
        listAppearance(for: snip, in: model.lists)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsStatusIcon {
                if snip.isPinned, let onCopy {
                    SnipCopyControl(appearance: appearance, action: onCopy)
                    .accessibilityLabel("Copy Snip")
                    .accessibilityIdentifier("copy-pinned-snip-\(snip.id)")
                } else {
                    Button {
                        guard !isChangingCompletion else { return }
                        isChangingCompletion = true
                        Task { @MainActor in
                            if let onToggleDone {
                                _ = await onToggleDone()
                            } else {
                                _ = await model.toggleDone(id: snip.id)
                            }
                            isChangingCompletion = false
                        }
                    } label: {
                        SnipCompletionIcon(isDone: snip.isDone, appearance: appearance)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isChangingCompletion)
                    .accessibilityLabel(SnipCompletionLanguage.menuActionTitle(isDone: snip.isDone))
                    .accessibilityValue(SnipCompletionLanguage.stateTitle(isDone: snip.isDone))
                    .accessibilityIdentifier("completion-\(snip.id)")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if hasVisibleText {
                    Text(SnipTextPreview.displayText(snip.content, lineLimit: 3))
                        .font(.body)
                        .foregroundStyle(snip.isDone ? .secondary : .primary)
                        .strikethrough(snip.isDone)
                        .lineLimit(3)
                } else {
                    attachmentPreviews
                }
                SnipRowMetadata(
                    date: snip.updatedAt,
                    isPinned: snip.isPinned,
                    isAgent: snip.origin == .agent,
                    agentContextLabel: snip.agentContextLabel
                )
                if isRecovered {
                    Label("Recovered", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if hasVisibleText {
                    attachmentPreviews
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        // Give the native reorder handle the snip's name.
        .accessibilityElement(children: isReordering ? .ignore : (onPreviewAttachment == nil ? .combine : .contain))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            snip.isPinned ? String(localized: "Pinned") : SnipCompletionLanguage.stateTitle(isDone: snip.isDone)
        )
    }

    private var hasVisibleText: Bool {
        !snip.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var attachmentPreviews: some View {
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
                            .frame(width: 64, height: 64)
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

    private var accessibilityLabel: String {
        let text = snip.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = snip.attachments.map(\.fileName).joined(separator: ", ")
        return [
            text.isEmpty ? nil : text,
            snip.origin == .agent
                ? AgentSnipContextLanguage.accessibilityLabel(snip.agentContextLabel)
                : nil,
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
                .frame(width: 64, height: 64)
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
            if let url = model.usableAttachmentURL(for: attachment.id) {
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
        .modifier(VisibleAttachmentPreparation(
            attachmentID: attachment.id,
            fileName: attachment.fileName,
            contentType: attachment.contentType,
            model: model
        ))
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

struct SnipCompletionIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 28
    let isDone: Bool
    let appearance: SnipListAppearance

    var body: some View {
        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDone)
            .font(.system(size: diameter))
            .foregroundStyle(appearance.controlTint)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct SnipCopyControl: View {
    @ScaledMetric(relativeTo: .body) private var controlDiameter: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 13
    let appearance: SnipListAppearance
    let action: () -> Void

    init(appearance: SnipListAppearance = SnipListAppearance(preset: nil), action: @escaping () -> Void) {
        self.appearance = appearance
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(appearance.controlTint)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
            }
                .frame(width: controlDiameter, height: controlDiameter)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

struct SnipRowMetadata: View {
    let date: Date
    let isPinned: Bool
    var isAgent = false
    var agentContextLabel: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(date, format: .relative(presentation: .named))
            if isAgent {
                AgentSnipContextLabel(contextLabel: agentContextLabel)
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct LibrarySearchView: View {
    let model: IOSAppModel
    let clipboard: IOSClipboardModel
    let copyShare: IOSCopyShareCoordinator
    @State private var previewURL: URL?
    private var inlineEditDraft: SnipEditorDraft? { model.snipEditorDraft }
    @FocusState private var isInlineEditorFocused: Bool

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
                    title: String(localized: "Search"),
                    systemImage: "magnifyingglass",
                    detail: String(localized: "Search every list and Clipboard.")
                )
                .accessibilityIdentifier("search-prompt")
            } else if results.isEmpty {
                CollectionEmptyState(
                    title: String(localized: "No results"),
                    systemImage: "magnifyingglass",
                    detail: String(localized: "Try another search.")
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
                .scrollDismissesKeyboard(.immediately)
                .accessibilityIdentifier("global-search-results")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .attachmentPreview($previewURL)
        .task { await clipboard.load() }
        .onDisappear { isInlineEditorFocused = false }
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
        Group {
            if let draft = inlineEditDraft, draft.original.id == snip.id {
                InlineSnipEditor(
                    draft: draft,
                    model: model,
                    isFocused: $isInlineEditorFocused
                )
            } else {
                HStack(alignment: .top, spacing: 12) {
                    SnipCopyControl(appearance: listAppearance(for: snip, in: model.lists)) {
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
                    .onTapGesture { beginEditing(snip) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Edit inline")
                    .accessibilityAction { beginEditing(snip) }
                    .accessibilityIdentifier("search-snip-\(snip.id)")
                }
            }
        }
        .listRowSeparator(.hidden)
        .contextMenu {
            if inlineEditDraft == nil {
                Button("Edit", systemImage: "pencil") { beginEditing(snip) }
                    .accessibilityIdentifier("edit-snip")
                Button("Copy", systemImage: "doc.on.doc") {
                    Task { await copyShare.copy(snips: [snip], model: model) }
                }
                MoveSnipMenu(model: model, snip: snip)
            }
        }
    }

    private func beginEditing(_ snip: Snip) {
        guard model.beginInlineSnipEdit(snip) else { return }
        Task { @MainActor in
            await Task.yield()
            guard inlineEditDraft?.original.id == snip.id else { return }
            isInlineEditorFocused = true
        }
    }

    private func clipboardResult(_ entry: ClipboardEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SnipCopyControl { copyShare.copyClipboardEntry(entry, clipboard: clipboard) }
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
            Button("Copy", systemImage: "doc.on.doc") {
                copyShare.copyClipboardEntry(entry, clipboard: clipboard)
            }
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
