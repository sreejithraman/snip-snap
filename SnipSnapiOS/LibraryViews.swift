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
                        NavigationLink(value: snip.id) {
                            SnipRow(
                                snip: snip,
                                model: model,
                                isRecovered: model.isRecoveredSnip(snip.id)
                            )
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
    let isRecovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snip.content)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Text(snip.updatedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
            if isRecovered {
                Label("Recovered", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
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
