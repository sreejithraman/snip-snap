import QuickLook
import SnipSnapCore
import SwiftUI

struct ListSidebarView: View {
    let model: IOSAppModel
    @Binding var sheet: AppSheet?

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedListID },
            set: { id in
                guard let id else { return }
                model.selectedListID = id
                model.selectedSnipID = nil
                model.selectedSnipIDs = []
            }
        )
    }

    var body: some View {
        List(selection: selection) {
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
            ToolbarItem(placement: .primaryAction) {
                Button("New List", systemImage: "folder.badge.plus") {
                    sheet = .newList
                }
                .accessibilityIdentifier("new-list")
            }
        }
    }
}

struct SnipCollectionView: View {
    let model: IOSAppModel
    @Binding var sheet: AppSheet?
    @State private var editMode: EditMode = .inactive
    @State private var isSelecting = false

    private var singleSelection: Binding<UUID?> {
        Binding(
            get: { model.selectedSnipID },
            set: { model.selectedSnipID = $0 }
        )
    }

    var body: some View {
        Group {
            if model.visibleSnips.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
                .accessibilityIdentifier("empty-snips")
            } else {
                List(selection: isSelecting ? nil : singleSelection) {
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
                                            showsStatusIcon: false
                                        )
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(
                                    model.selectedSnipIDs.contains(snip.id) ? .isSelected : []
                                )
                            } else {
                                NavigationLink(value: snip.id) {
                                    SnipRow(snip: snip, model: model)
                                }
                            }
                        }
                        .tag(snip.id)
                        .accessibilityIdentifier("snip-\(snip.id)")
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
                            Button("Edit") { sheet = .editSnip(id: snip.id) }
                            MoveSnipMenu(model: model, snip: snip)
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
        .searchable(
            text: Binding(
                get: { model.searchText },
                set: { model.searchText = $0 }
            ),
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search Snips"
        )
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(model.undoTitle, systemImage: "arrow.uturn.backward") {
                    Task { _ = await model.undo() }
                }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier("undo-change")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if isSelecting {
                    SelectionActionsMenu(model: model, endSelection: endSelection)
                        .disabled(model.selectedSnipIDs.isEmpty)
                } else {
                    WorkflowOptionsMenu(model: model)
                }
                Button(isSelecting ? "Done" : "Edit") {
                    setSelecting(!isSelecting)
                }
                    .disabled(model.visibleSnips.isEmpty)
                    .accessibilityIdentifier("select-snips")
                if !isSelecting {
                    Button("New Snip", systemImage: "square.and.pencil") {
                        sheet = .newSnip(listID: model.selectedListID)
                    }
                    .accessibilityIdentifier("new-snip")
                }
            }
        }
        .onChange(of: model.selectedListID) {
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
        isSelecting = selecting
        editMode = selecting ? .active : .inactive
        model.selectedSnipIDs = []
        if selecting { model.selectedSnipID = nil }
    }
}

private struct SnipRow: View {
    let snip: Snip
    let model: IOSAppModel
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
                let attachmentItems = snip.attachments.compactMap {
                    attachment -> AttachmentPreviewItem? in
                    guard let url = model.attachmentURL(for: attachment.id) else { return nil }
                    return AttachmentPreviewItem(
                        id: attachment.id,
                        fileName: attachment.fileName,
                        byteCount: attachment.byteCount,
                        url: url
                    )
                }
                if !attachmentItems.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(attachmentItems.prefix(3)) { attachment in
                            AttachmentThumbnail(url: attachment.url)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel(attachment.fileName)
                        }
                        if attachmentItems.count > 3 {
                            Text("+\(attachmentItems.count - 3)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(snip.isDone ? "Done" : "Not Done")
    }
}

struct SnipDetailView: View {
    let model: IOSAppModel
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

                    if !attachmentItems.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Attachments")
                                .font(.headline)
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 144), spacing: 12)],
                                spacing: 12
                            ) {
                                ForEach(attachmentItems) { attachment in
                                    AttachmentPreviewTile(item: attachment) {
                                        previewURL = attachment.url
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
