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
            if model.hasCloudSync {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.syncWhenPossible() }
                    }
                    .accessibilityIdentifier("sync-icloud-now")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Clear Downloaded Files", systemImage: "icloud.and.arrow.down") {
                        Task { await model.clearDownloadedFiles() }
                    }
                    .accessibilityIdentifier("clear-icloud-downloads")
                }
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
