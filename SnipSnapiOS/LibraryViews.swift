import QuickLook
import SnipSnapCore
import SwiftUI

struct ListSidebarView: View {
    let model: IOSAppModel
    @Binding var sheet: AppSheet?
    var importBackup: () -> Void = {}

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedListID },
            set: { id in
                guard let id else { return }
                model.selectList(id)
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            if model.needsAttentionCount > 0 {
                Section {
                    Button {
                        sheet = .recoveryCenter
                    } label: {
                        Label("Needs Attention", systemImage: "exclamationmark.bubble")
                    }
                    .badge(model.needsAttentionCount)
                    .accessibilityIdentifier("needs-attention")
                }
            }
            ForEach(model.lists) { list in
                NavigationLink(value: list.id) {
                    Label(list.name, systemImage: list.systemImage)
                }
                .tag(list.id)
                .accessibilityIdentifier("list-\(list.name)")
                .contextMenu {
                    if list.id != SnipList.inboxID {
                        Button("Rename") { sheet = .editList(id: list.id) }
                        Button("Delete", role: .destructive) {
                            Task { await model.deleteList(id: list.id) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") {
                    sheet = .settings
                }
                .accessibilityIdentifier("settings")
            }
            ToolbarItem(placement: .secondaryAction) {
                LibraryActionsMenu(
                    model: model,
                    importBackup: importBackup,
                    editSelectedList: { sheet = .editList(id: model.selectedListID) }
                )
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New List", systemImage: "folder.badge.plus") {
                    sheet = .newList
                }
                .accessibilityIdentifier("new-list")
            }
            if model.hasCloudSync {
                ToolbarItemGroup(placement: .secondaryAction) {
                    CloudLibraryActions(model: model)
                }
            }
        }
    }
}

struct LibraryActionsMenu: View {
    let model: IOSAppModel
    let importBackup: () -> Void
    var includesCloudActions = false
    var editSelectedList: (() -> Void)?
    @State private var confirmsDeleteList = false

    var body: some View {
        Menu("Library Actions", systemImage: "ellipsis.circle") {
            Button(model.undoTitle, systemImage: "arrow.uturn.backward") {
                Task { await model.undo() }
            }
            .disabled(!model.canUndo)
            Button(model.redoTitle, systemImage: "arrow.uturn.forward") {
                Task { await model.redo() }
            }
            .disabled(!model.canRedo)
            Divider()
            Button("Import Backup…", systemImage: "square.and.arrow.down", action: importBackup)
            if model.selectedListID != SnipList.inboxID, let editSelectedList {
                Divider()
                Button("Rename List", systemImage: "pencil", action: editSelectedList)
                Button("Delete List", systemImage: "trash", role: .destructive) {
                    confirmsDeleteList = true
                }
            }
            if includesCloudActions, model.hasCloudSync {
                Divider()
                CloudLibraryActions(model: model)
            }
        }
        .accessibilityIdentifier("library-actions")
        .alert("Delete \(model.selectedList.name)?", isPresented: $confirmsDeleteList) {
            Button("Cancel", role: .cancel) {}
            Button("Delete List", role: .destructive) {
                Task { await model.deleteList(id: model.selectedListID) }
            }
        } message: {
            Text("The list will be removed. Its snips will move to Inbox.")
        }
    }
}

private struct CloudLibraryActions: View {
    let model: IOSAppModel

    var body: some View {
        Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
            Task { await model.syncWhenPossible() }
        }
        .accessibilityIdentifier("sync-icloud-now")
        Button("Clear Downloaded Files", systemImage: "icloud.and.arrow.down") {
            Task { await model.clearDownloadedFiles() }
        }
        .accessibilityIdentifier("clear-icloud-downloads")
    }
}

enum SnipCollectionLayout: Equatable {
    case splitView
    case compactStack
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
    var layout = SnipCollectionLayout.splitView
    @State private var editMode: EditMode = .inactive
    @State private var isSelecting = false
    @State private var inlineEditSession: CompactInlineEditSession?
    @FocusState private var isInlineEditorFocused: Bool

    private var singleSelection: Binding<UUID?> {
        Binding(
            get: { model.selectedSnipID },
            set: { model.selectedSnipID = $0 }
        )
    }

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
                List(selection: isSelecting ? nil : singleSelection) {
                    ForEach(model.pendingRecoveredSnips.filter { recovery in
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
                                                    ? Color.accentColor : Color.secondary
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
                            } else if layout == .compactStack {
                                if inlineEditSession?.original.id == snip.id {
                                    CompactInlineSnipEditor(
                                        snip: snip,
                                        model: model,
                                        text: inlineEditText,
                                        isSaving: inlineEditSession?.isSaving == true,
                                        isFocused: $isInlineEditorFocused,
                                        cancel: cancelInlineEdit,
                                        save: saveInlineEdit
                                    )
                                } else {
                                    Button {
                                        model.selectedSnipID = snip.id
                                    } label: {
                                        SnipRow(
                                            snip: snip,
                                            model: model,
                                            isRecovered: model.isRecoveredSnip(snip.id)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .highPriorityGesture(
                                        TapGesture(count: 2).onEnded {
                                            beginEditing(snip)
                                        }
                                    )
                                    .accessibilityHint("Double tap to edit. Touch and hold for actions.")
                                    .accessibilityAction(named: "Edit") {
                                        beginEditing(snip)
                                    }
                                    .accessibilityIdentifier("snip-\(snip.id)")
                                    .listRowBackground(
                                        model.selectedSnipID == snip.id
                                            ? SnipSnapTheme.selectionFill : Color.clear
                                    )
                                }
                            } else {
                                NavigationLink(value: snip.id) {
                                    SnipRow(
                                        snip: snip,
                                        model: model,
                                        isRecovered: model.isRecoveredSnip(snip.id)
                                    )
                                }
                                .accessibilityIdentifier("snip-\(snip.id)")
                            }
                        }
                        .tag(snip.id)
                        .swipeActions(edge: .leading) {
                            Button(snip.isDone ? "Mark Not Done" : "Mark Done") {
                                Task { await model.toggleDone(id: snip.id) }
                            }
                            .tint(snip.isDone ? .secondary : .green)
                            .accessibilityIdentifier(snip.isDone ? "mark-not-done" : "mark-done")
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                Task { await model.deleteSnip(id: snip.id) }
                            }
                            .accessibilityIdentifier("delete-snip")
                        }
                        .contextMenu {
                            Button(snip.isDone ? "Mark Not Done" : "Mark Done") {
                                Task { await model.toggleDone(id: snip.id) }
                            }
                            Button("Edit") { beginEditing(snip) }
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
            }
        }
        .navigationTitle(model.selectedList.name)
        .modifier(PhoneAwareSearchModifier(
            isEnabled: layout == .splitView,
            text: Binding(
                get: { model.searchText },
                set: { model.searchText = $0 }
            )
        ))
        .environment(\.editMode, $editMode)
        .toolbar {
            if layout == .splitView {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.undoTitle, systemImage: "arrow.uturn.backward") {
                        Task { _ = await model.undo() }
                    }
                    .disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .accessibilityIdentifier("undo-change")
                }
            }
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
                if !isSelecting && layout == .splitView {
                    Button("New Snip", systemImage: "square.and.pencil") {
                        sheet = .newSnip(listID: model.selectedListID)
                    }
                    .accessibilityIdentifier("new-snip")
                }
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
            return "No Results"
        }
        return model.completionFilter.emptyStateTitle
    }

    private var emptySystemImage: String {
        model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "text.page" : "magnifyingglass"
    }

    private var emptyDescription: String {
        if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try a different search."
        }
        return model.completionFilter == .all
            ? "Save text here when you want to keep it close."
            : "Change the filter to see other snips."
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
        guard layout == .compactStack else {
            sheet = .editSnip(id: snip.id)
            return
        }
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
                            AttachmentStatusThumbnail(attachment: attachment, model: model)
                                .frame(width: 48, height: 48)
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
                prompt: "Search Snips"
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
                            AttachmentStatusThumbnail(attachment: attachment, model: model)
                                .frame(width: 48, height: 48)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(snip.isDone ? "Done" : "Not Done")
    }

    private var accessibilityLabel: String {
        let text = snip.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = snip.attachments.map(\.fileName).joined(separator: ", ")
        return [
            text.isEmpty ? nil : text,
            attachments.isEmpty ? nil : "Attachments: \(attachments)",
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private struct RecoveredSnipRow: View {
    let recovery: RecoveredSnip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recovery.recovered.content.isEmpty ? "Recovered edit" : recovery.recovered.content)
                .lineLimit(3)
                .foregroundStyle(.primary)
            Label("Recovered", systemImage: "arrow.uturn.backward.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 4)
    }
}

struct RecoveryCenterView: View {
    @Environment(\.dismiss) private var dismiss
    let model: IOSAppModel
    @Binding var sheet: AppSheet?

    var body: some View {
        NavigationStack {
            List {
                if !model.pendingRecoveredSnips.isEmpty {
                    Section("Recovered Snips") {
                        ForEach(model.pendingRecoveredSnips) { recovery in
                            NavigationLink {
                                RecoveredSnipReviewView(model: model, recoveryID: recovery.id)
                            } label: {
                                RecoveredSnipRow(recovery: recovery)
                            }
                        }
                    }
                }
                if !model.pendingRecoveredLists.isEmpty {
                    Section("Recovered List Edits") {
                        ForEach(model.pendingRecoveredLists) { recovery in
                            NavigationLink {
                                RecoveredListReviewView(model: model, recoveryID: recovery.id)
                            } label: {
                                Label(recovery.recovered.name, systemImage: recovery.recovered.systemImage)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Needs Attention")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct RecoveredSnipReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let model: IOSAppModel
    let recoveryID: UUID
    @State private var edited: Snip?
    @State private var isResolving = false

    private var recovery: RecoveredSnip? {
        model.pendingRecoveredSnips.first { $0.id == recoveryID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let recovery, let current = model.currentSnip(for: recovery) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            recoverySnipCard("Current", snip: current, fields: recovery.conflictingFields)
                            recoverySnipCard(
                                "Recovered Edit",
                                snip: recovery.recovered,
                                fields: recovery.conflictingFields
                            )
                            editSnipFields(recovery)
                        }
                        .padding(24)
                    }
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 12) {
                            HStack {
                                Button("Keep Current") { resolve(.keepCurrent) }
                                Spacer()
                                Button("Use Recovered") { resolve(.useRecovered) }
                                    .buttonStyle(.borderedProminent)
                            }
                            HStack {
                                Button("Keep Both") { resolve(.keepBoth) }
                                Spacer()
                                Button("Edit") {
                                    if let edited { resolve(.editSnip(edited)) }
                                }
                            }
                        }
                        .padding(16)
                        .background(.regularMaterial)
                    }
                    .disabled(isResolving)
                    .onAppear { if edited == nil { edited = recovery.recovered } }
                } else {
                    ContentUnavailableView("Recovered Edit Is Gone", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Recovered Snip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    await model.load()
                }
            }
        }
    }

    private func recoverySnipCard(
        _ title: String,
        snip: Snip,
        fields: Set<RecoveredSnipField>
    ) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 12) {
                if fields.contains(.text) { LabeledContent("Text", value: snip.content) }
                if fields.contains(.source) {
                    LabeledContent("Source", value: snip.source?.conciseLabel ?? "None")
                }
                if fields.contains(.done) {
                    LabeledContent("State", value: snip.isDone ? "Done" : "Not Done")
                }
                if fields.contains(.placement) {
                    LabeledContent(
                        "List",
                        value: model.lists.first { $0.id == snip.listID }?.name ?? "Inbox"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func editSnipFields(_ recovery: RecoveredSnip) -> some View {
        if let binding = Binding($edited) {
            GroupBox("Edit Conflicting Fields") {
                VStack(alignment: .leading, spacing: 12) {
                    if recovery.conflictingFields.contains(.text) {
                        TextField("Text", text: binding.content, axis: .vertical)
                            .lineLimit(3...8)
                    }
                    if recovery.conflictingFields.contains(.source) {
                        TextField(
                            "Source app",
                            text: Binding(
                                get: { binding.wrappedValue.source?.applicationName ?? "" },
                                set: { value in
                                    var source = binding.wrappedValue.source
                                        ?? SnipSource(applicationName: "")
                                    source.applicationName = value
                                    binding.wrappedValue.source = cleaned(source)
                                }
                            )
                        )
                        sourceField("Window", keyPath: \.windowTitle, snip: binding)
                        sourceField("URL", keyPath: \.url, snip: binding)
                    }
                    if recovery.conflictingFields.contains(.done) {
                        Toggle("Done", isOn: binding.isDone)
                    }
                    if recovery.conflictingFields.contains(.placement) {
                        Picker("List", selection: binding.listID) {
                            ForEach(model.lists) { Text($0.name).tag($0.id) }
                        }
                    }
                }
            }
        }
    }

    private func sourceField(
        _ title: String,
        keyPath: WritableKeyPath<SnipSource, String?>,
        snip: Binding<Snip>
    ) -> some View {
        TextField(
            title,
            text: Binding(
                get: { snip.wrappedValue.source?[keyPath: keyPath] ?? "" },
                set: { value in
                    var source = snip.wrappedValue.source ?? SnipSource(applicationName: "")
                    source[keyPath: keyPath] = value.isEmpty ? nil : value
                    snip.wrappedValue.source = cleaned(source)
                }
            )
        )
    }

    private func cleaned(_ source: SnipSource) -> SnipSource? {
        source.applicationName.isEmpty && source.windowTitle == nil && source.url == nil
            ? nil : source
    }

    private func resolve(_ choice: SnipRecoveryChoice) {
        isResolving = true
        Task {
            if await model.resolveRecovery(recoveryID, choice: choice) { dismiss() }
            isResolving = false
        }
    }
}

struct RecoveredListReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let model: IOSAppModel
    let recoveryID: UUID
    @State private var edited: SnipList?
    @State private var isResolving = false

    private var recovery: RecoveredListEdit? {
        model.pendingRecoveredLists.first { $0.id == recoveryID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let recovery, let current = model.currentList(for: recovery) {
                    Form {
                        Section("Current List") { listValues(current, fields: recovery.conflictingFields) }
                        Section("Recovered Edit") {
                            listValues(recovery.recovered, fields: recovery.conflictingFields)
                        }
                        if let binding = Binding($edited) {
                            Section("Edit Conflicting Fields") {
                                if recovery.conflictingFields.contains(.name) {
                                    TextField("Name", text: binding.name)
                                }
                                if recovery.conflictingFields.contains(.icon) {
                                    TextField("Symbol", text: binding.systemImage)
                                }
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Button("Keep Current") { resolve(.keepCurrent) }
                            Spacer()
                            Button("Use Recovered") { resolve(.useRecovered) }
                                .buttonStyle(.borderedProminent)
                            Button("Edit") {
                                if let edited { resolve(.editList(edited)) }
                            }
                        }
                        .padding(16)
                        .background(.regularMaterial)
                    }
                    .disabled(isResolving)
                    .onAppear { if edited == nil { edited = recovery.recovered } }
                } else {
                    ContentUnavailableView("Recovered Edit Is Gone", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Recovered List Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    await model.load()
                }
            }
        }
    }

    @ViewBuilder
    private func listValues(_ list: SnipList, fields: Set<RecoveredListField>) -> some View {
        if fields.contains(.name) { LabeledContent("Name", value: list.name) }
        if fields.contains(.icon) { Label(list.systemImage, systemImage: list.systemImage) }
    }

    private func resolve(_ choice: SnipRecoveryChoice) {
        isResolving = true
        Task {
            if await model.resolveRecovery(recoveryID, choice: choice) { dismiss() }
            isResolving = false
        }
    }
}

struct SnipDetailView: View {
    let model: IOSAppModel
    let copyShare: IOSCopyShareCoordinator
    @Binding var sheet: AppSheet?
    @State private var previewURL: URL?

    private var attachmentItems: [AttachmentPreviewItem] {
        guard let snip = model.selectedSnip else { return [] }
        return snip.attachments.compactMap { attachment in
            guard let url = model.attachmentURL(for: attachment.id) else { return nil }
            return AttachmentPreviewItem(
                id: attachment.id,
                fileName: attachment.fileName,
                byteCount: attachment.byteCount,
                url: url
            )
        }
    }

    var body: some View {
        if let snip = model.selectedSnip {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(snip.content)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !snip.attachments.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Attachments")
                                .font(.headline)
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 144), spacing: 12)],
                                spacing: 12
                            ) {
                                ForEach(snip.attachments) { attachment in
                                    SyncedAttachmentTile(attachment: attachment, model: model) {
                                        Task {
                                            previewURL = await model.prepareAttachment(
                                                attachment.id,
                                                for: .preview
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    LabeledContent("Saved", value: snip.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent(
                        "List",
                        value: model.lists.first(where: { $0.id == snip.listID })?.name ?? "Inbox"
                    )
                }
                .padding(24)
            }
            .navigationTitle("Snip")
            .quickLookPreview($previewURL, in: attachmentItems.map(\.url))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu("Copy and Share", systemImage: "square.and.arrow.up") {
                        CopyShareActions(
                            snips: [snip],
                            model: model,
                            coordinator: copyShare,
                            identifierSuffix: "snip"
                        )
                    }
                    .accessibilityIdentifier("copy-share-snip")
                    MoveSnipMenu(model: model, snip: snip)
                    Button("Edit", systemImage: "pencil") {
                        sheet = .editSnip(id: snip.id)
                    }
                    .accessibilityIdentifier("edit-snip")
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await model.deleteSnip(id: snip.id) }
                    }
                    .accessibilityIdentifier("delete-snip-detail")
                }
            }
        } else {
            ContentUnavailableView(
                "Choose a Snip",
                systemImage: "text.page",
                description: Text("Select a saved snip to read or edit it.")
            )
        }
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
        case .waiting: "waiting for iCloud"
        case .syncing: "syncing"
        case .failed: "failed"
        case .available: "available"
        }
    }
}

private struct SyncedAttachmentTile: View {
    let attachment: SnipAttachment
    let model: IOSAppModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                AttachmentStatusThumbnail(attachment: attachment, model: model)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                Text(attachment.fileName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(state == .failed ? .red : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(state == .syncing && model.attachmentURL(for: attachment.id) == nil)
        .accessibilityIdentifier("attachment-preview-\(attachment.fileName)")
    }

    private var state: SyncedAttachmentTransferState {
        model.attachmentTransferState(for: attachment.id)
    }

    private var statusLabel: String {
        if model.attachmentURL(for: attachment.id) != nil {
            return switch state {
            case .waiting: "Available Offline — Waiting for iCloud"
            case .syncing: "Available Offline — Syncing"
            case .failed: "Available Offline — Sync Failed"
            case .available: "Available Offline"
            }
        }
        return switch state {
        case .waiting: "Waiting for iCloud"
        case .syncing: "Downloading…"
        case .failed: "Download Failed — Tap to Retry"
        case .available: "Ready to Download"
        }
    }
}

struct MoveSnipMenu: View {
    let model: IOSAppModel
    let snip: Snip

    var body: some View {
        Menu("Move", systemImage: "folder") {
            ForEach(model.lists.filter { $0.id != snip.listID }) { list in
                Button(list.name) {
                    Task { await model.moveSnip(id: snip.id, to: list.id) }
                }
                .accessibilityIdentifier("move-to-\(list.name)")
            }
        }
        .accessibilityIdentifier("move-snip")
    }
}
