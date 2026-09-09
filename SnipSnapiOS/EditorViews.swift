import Foundation
import QuickLook
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers

struct SnipEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let model: IOSAppModel
    let snipID: UUID
    @State private var content = ""
    @State private var attachments: [AttachmentDraft] = []
    @State private var previewURL: URL?
    @State private var isImporting = false
    @State private var replacementID: UUID?
    @State private var stagingTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var didLoad = false
    @State private var stagingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnipSnapAttachmentDrafts", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    private var isStaging: Bool { stagingTask != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextEditor(text: $content)
                        .frame(minHeight: 180)
                        .accessibilityIdentifier("snip-text")
                }

                AttachmentEditorSection(
                    attachments: attachments,
                    isStaging: isStaging,
                    isDisabled: isSaving || isStaging,
                    preview: { previewAttachment($0) },
                    replace: {
                        replacementID = $0.id
                        isImporting = true
                    },
                    remove: { removeAttachment(id: $0.id) },
                    add: {
                        replacementID = nil
                        isImporting = true
                    }
                )
            }
            .disabled(isSaving || isStaging)
            .navigationTitle("Edit Snip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cleanStagingDirectory()
                        dismiss()
                    }
                    .disabled(
                        !AttachmentDraftLifecycle.allowsDismissal(
                            isSaving: isSaving,
                            isStaging: isStaging
                        )
                    )
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(
                        !AttachmentDraftLifecycle.allowsSaving(
                            isSaving: isSaving,
                            isStaging: isStaging,
                            isImporting: isImporting,
                            isPreviewing: previewURL != nil
                        )
                            || (content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && attachments.isEmpty)
                    )
                    .accessibilityIdentifier("save-snip")
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                guard let snip = model.snips.first(where: { $0.id == snipID }) else { return }
                content = snip.content
                attachments = snip.attachments.map { attachment in
                    AttachmentDraft(
                        id: attachment.id,
                        fileName: attachment.fileName,
                        byteCount: attachment.byteCount,
                        url: model.attachmentURL(for: attachment.id),
                        source: .existing(attachmentID: attachment.id)
                    )
                }
            }
            .onDisappear {
                if AttachmentDraftLifecycle.allowsSaving(
                    isSaving: isSaving,
                    isStaging: isStaging,
                    isImporting: isImporting,
                    isPreviewing: previewURL != nil
                ) {
                    cleanStagingDirectory()
                }
            }
            .interactiveDismissDisabled(
                !AttachmentDraftLifecycle.allowsDismissal(
                    isSaving: isSaving,
                    isStaging: isStaging
                )
            )
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.data],
                allowsMultipleSelection: replacementID == nil
            ) { result in
                stage(result)
            }
            .quickLookPreview($previewURL, in: attachments.compactMap(\.url))
        }
    }

    private func save() async {
        guard AttachmentDraftLifecycle.allowsSaving(
            isSaving: isSaving,
            isStaging: isStaging,
            isImporting: isImporting,
            isPreviewing: previewURL != nil
        ) else { return }
        isSaving = true
        guard let snip = model.snips.first(where: { $0.id == snipID }) else {
            isSaving = false
            return
        }
        let succeeded = await model.editSnip(
            snip,
            content: content,
            attachmentEdits: attachments.compactMap(\.libraryEdit)
        )
        isSaving = false
        if succeeded {
            cleanStagingDirectory()
            dismiss()
        }
    }

    private func previewAttachment(_ attachment: AttachmentDraft) {
        Task {
            guard let url = await attachment.previewURL(prepareExisting: {
                await model.prepareAttachment($0, for: .preview)
            }),
                  let index = attachments.firstIndex(where: { $0.id == attachment.id })
            else { return }
            let current = attachments[index]
            guard let prepared = current.applyingPreparedURL(
                url,
                requestedDraft: attachment
            ) else { return }
            attachments[index] = prepared
            previewURL = url
        }
    }

    private func stage(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
            replacementID = nil
            return
        }
        guard stagingTask == nil else { return }
        let targetID = replacementID
        replacementID = nil
        stagingTask = Task {
            do {
                let staged = try await AttachmentDraftStager.stage(
                    targetID == nil ? urls : Array(urls.prefix(1)),
                    in: stagingDirectory
                )
                if let targetID, let replacement = staged.first {
                    replaceAttachment(id: targetID, with: replacement)
                } else {
                    attachments.append(contentsOf: staged.map(AttachmentDraft.added))
                }
            } catch {
                model.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            stagingTask = nil
        }
    }

    private func replaceAttachment(id: UUID, with file: StagedAttachment) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let originalID = attachments[index].source.originalAttachmentID
        removeStagedFile(for: attachments[index])
        let source: AttachmentDraft.Source
        if let originalID {
            source = .replacement(attachmentID: originalID)
        } else {
            source = .added
        }
        attachments[index] = AttachmentDraft(
            id: id,
            fileName: file.fileName,
            byteCount: file.byteCount,
            url: file.url,
            source: source
        )
    }

    private func removeAttachment(id: UUID) {
        guard let attachment = attachments.first(where: { $0.id == id }) else { return }
        removeStagedFile(for: attachment)
        attachments.removeAll { $0.id == id }
    }

    private func removeStagedFile(for attachment: AttachmentDraft) {
        guard attachment.source.isStaged, let url = attachment.url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func cleanStagingDirectory() {
        AttachmentDraftStager.clean(stagingDirectory)
    }
}

/// Edits the selected list without leaving its snips or composer.
struct InlineListEditor: View {
    let model: IOSAppModel
    let list: SnipList
    @State private var name: String
    @State private var systemImage: String
    @State private var color: SnipListColor?
    @State private var isSaving = false
    @State private var showsAppearance = false
    @State private var showsIcons = false
    @FocusState private var isNameFocused: Bool

    init(model: IOSAppModel, list: SnipList) {
        self.model = model
        self.list = list
        _name = State(initialValue: model.newListID == list.id ? "" : list.name)
        _systemImage = State(initialValue: list.systemImage)
        _color = State(initialValue: list.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            HStack(spacing: 12) {
                Button {
                    isNameFocused = false
                    showsIcons.toggle()
                    showsAppearance = false
                } label: {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(SnipListAppearance(pair: color).color)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Choose list icon, current: \(SnipListIconOptions.title(for: systemImage))")
                .accessibilityIdentifier("choose-list-icon")

                TextField(list.displayName, text: $name)
                    .font(.title.bold())
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .textInputAutocapitalization(.words)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
                    .accessibilityLabel("List name")
                    .accessibilityIdentifier("list-name")

                Button {
                    Task { await save() }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(isSaving)
                .accessibilityLabel("Done")
                .accessibilityIdentifier("save-list")
            }
            Button {
                isNameFocused = false
                showsAppearance.toggle()
                showsIcons = false
            } label: {
                Label("List color", systemImage: "paintpalette")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("list-appearance")
            if showsIcons {
                InlineListIconPicker(selection: $systemImage)
            }
            if showsAppearance {
                SnipListColorPicker(selection: $color)
            }
        }
        .disabled(isSaving)
        .padding(.horizontal, SnipSnapSpacing.paneContentInset)
        .padding(.bottom, SnipSnapSpacing.relatedContent)
        .task { isNameFocused = true }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded = await model.renameList(
            list,
            name: cleaned.isEmpty ? list.name : cleaned,
            systemImage: systemImage,
            color: .set(color)
        )
        isSaving = false
        if succeeded, model.editingListID == list.id {
            isNameFocused = false
            model.editingListID = nil
            model.newListID = nil
        }
    }
}
