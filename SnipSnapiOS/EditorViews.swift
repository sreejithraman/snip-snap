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
                if AttachmentDraftLifecycle.shouldClean(
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

enum ListEditorMode {
    case create
    case edit(id: UUID)
}

struct ListEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let model: IOSAppModel
    let mode: ListEditorMode
    @State private var name = ""
    @State private var isSaving = false

    private var title: String {
        switch mode {
        case .create: String(localized: "New List")
        case .edit: String(localized: "Rename List")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("List name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("list-name")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-list")
                }
            }
            .onAppear {
                if case .edit(let id) = mode {
                    name = model.lists.first(where: { $0.id == id })?.name ?? ""
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        let succeeded: Bool
        switch mode {
        case .create:
            succeeded = await model.createList(name: name)
        case .edit(let id):
            guard let list = model.lists.first(where: { $0.id == id }) else {
                isSaving = false
                return
            }
            succeeded = await model.renameList(list, name: name)
        }
        isSaving = false
        if succeeded { dismiss() }
    }
}
