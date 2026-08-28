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

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedSnipID },
            set: { model.selectedSnipID = $0 }
        )
    }

    var body: some View {
        Group {
            if model.visibleSnips.isEmpty {
                ContentUnavailableView(
                    "No Snips",
                    systemImage: "text.page",
                    description: Text("Save text here when you want to keep it close.")
                )
                .accessibilityIdentifier("empty-snips")
            } else {
                List(selection: selection) {
                    ForEach(model.visibleSnips) { snip in
                        NavigationLink(value: snip.id) {
                            SnipRow(snip: snip, model: model)
                        }
                        .tag(snip.id)
                        .accessibilityIdentifier("snip-\(snip.id)")
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                Task { await model.deleteSnip(id: snip.id) }
                            }
                            .accessibilityIdentifier("delete-snip")
                        }
                        .contextMenu {
                            Button("Edit") { sheet = .editSnip(id: snip.id) }
                            MoveSnipMenu(model: model, snip: snip)
                            Button("Delete", role: .destructive) {
                                Task { await model.deleteSnip(id: snip.id) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(model.selectedList.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Snip", systemImage: "square.and.pencil") {
                    sheet = .newSnip(listID: model.selectedListID)
                }
                .accessibilityIdentifier("new-snip")
            }
        }
    }
}

private struct SnipRow: View {
    let snip: Snip
    let model: IOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snip.content)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Text(snip.updatedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
            let attachmentItems = snip.attachments.compactMap { attachment -> AttachmentPreviewItem? in
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
        .padding(.vertical, 4)
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
                    LabeledContent("List", value: model.selectedList.name)
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
