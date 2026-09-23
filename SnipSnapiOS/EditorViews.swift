import Foundation
import PhotosUI
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
    @State private var isPickingPhotos = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isTakingPhoto = false
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
                    model: model,
                    isStaging: isStaging,
                    isDisabled: isSaving || isStaging,
                    preview: { previewAttachment($0) },
                    replace: { attachment, source in
                        replacementID = attachment.id
                        presentAttachmentSource(source)
                    },
                    remove: { removeAttachment(id: $0.id) },
                    add: { source in
                        replacementID = nil
                        presentAttachmentSource(source)
                    }
                )
            }
            .disabled(isSaving || isStaging)
            .navigationTitle("Edit Snip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isStaging ? "Stop Import" : "Cancel") {
                        if isStaging {
                            stagingTask?.cancel()
                        } else {
                            cleanStagingDirectory()
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier(isStaging ? "cancel-attachment-import" : "cancel-editor")
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
                            isPickingMedia: isPickingPhotos || isTakingPhoto,
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
                        url: nil,
                        source: .existing(attachmentID: attachment.id),
                        contentType: attachment.contentType
                    )
                }
            }
            .onDisappear {
                if AttachmentDraftLifecycle.allowsSaving(
                    isSaving: isSaving,
                    isStaging: isStaging,
                    isImporting: isImporting,
                    isPickingMedia: isPickingPhotos || isTakingPhoto,
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
            .photosPicker(
                isPresented: $isPickingPhotos,
                selection: $selectedPhotos,
                maxSelectionCount: replacementID == nil ? nil : 1,
                matching: .images
            )
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                selectedPhotos = []
                stageMedia(.photos(items))
            }
            .fullScreenCover(isPresented: $isTakingPhoto) {
                AttachmentCameraPicker { image in
                    isTakingPhoto = false
                    if let image { stageMedia(.camera(image)) } else { replacementID = nil }
                }
            }
            .attachmentPreview($previewURL, in: attachments.compactMap { attachment in
                if case .existing = attachment.source {
                    return model.usableAttachmentURL(for: attachment.id)
                }
                return attachment.url
            })
        }
    }

    private func save() async {
        guard AttachmentDraftLifecycle.allowsSaving(
            isSaving: isSaving,
            isStaging: isStaging,
            isImporting: isImporting,
            isPickingMedia: isPickingPhotos || isTakingPhoto,
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
            guard current == attachment else { return }
            if case .existing = current.source {
                previewURL = model.usableAttachmentURL(for: attachment.id) ?? url
            } else {
                previewURL = url
            }
        }
    }

    private func presentAttachmentSource(_ source: AttachmentSource) {
        switch source {
        case .files: isImporting = true
        case .photos: isPickingPhotos = true
        case .camera: isTakingPhoto = true
        }
    }

    private func stage(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                    model.presentError(error, operation: "attachment.import_select")
                }
            }
            replacementID = nil
            return
        }
        stageMedia(.files(urls))
    }

    private func stageMedia(_ input: AttachmentMediaInput) {
        guard stagingTask == nil else { return }
        let targetID = replacementID
        replacementID = nil
        let selectedInput: AttachmentMediaInput
        if case .files(let urls) = input, targetID != nil {
            selectedInput = .files(Array(urls.prefix(1)))
        } else {
            selectedInput = input
        }
        stagingTask = Task {
            var staged: [StagedAttachment] = []
            defer { stagingTask = nil }
            do {
                staged = try await AttachmentMediaStager.stage(selectedInput, in: stagingDirectory)
                try Task.checkCancellation()
                applyStaged(staged, replacing: targetID)
            } catch is CancellationError {
                AttachmentDraftStager.clean(staged)
            } catch {
                model.presentError(error, operation: "attachment.import_stage")
            }
        }
    }

    private func applyStaged(_ staged: [StagedAttachment], replacing targetID: UUID?) {
        if let targetID, let replacement = staged.first {
            replaceAttachment(id: targetID, with: replacement)
        } else {
            attachments.append(contentsOf: staged.map(AttachmentDraft.added))
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

enum ListEditorPresentation {
    static func animation(reduceMotion: Bool, isPresented: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(duration: isPresented ? 0.3 : 0.22, bounce: 0)
    }
}

/// Keeps nearby content available while the list editor has focus.
struct ListEditorRecession: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? (contrast == .increased ? 0.7 : 0.4) : 1)
            .animation(
                ListEditorPresentation.animation(reduceMotion: reduceMotion, isPresented: isActive),
                value: isActive
            )
    }
}

/// Edits the selected list in a glass panel above its snips.
struct InlineListEditor: View {
    let model: IOSAppModel
    let list: SnipList
    @Bindable private var draft: InlineListDraft
    @State private var showsIcons = false
    @State private var contentHeight: CGFloat?
    @FocusState private var isNameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    init(model: IOSAppModel, list: SnipList) {
        self.model = model
        self.list = list
        draft = model.listDraft(for: list)
    }

    var body: some View {
        ScrollView {
            editorContent
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: contentHeight, alignment: .top)
        .background {
            let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
            if reduceTransparency || contrast == .increased {
                shape.fill(Color(uiColor: .secondarySystemBackground))
                    .overlay { shape.strokeBorder(SnipSnapTheme.emphasizedGlassEdge) }
            } else {
                GlassEffectContainer {
                    Color.clear
                        .glassEffect(.regular.tint(SnipSnapTheme.listEditorGlassTint), in: shape)
                }
            }
        }
        .padding(.horizontal, SnipSnapSpacing.paneContentInset)
        .padding(.top, SnipSnapSpacing.relatedContent)
        .padding(.bottom, SnipSnapSpacing.relatedContent)
        .task { isNameFocused = model.newListID == list.id && !model.isSearchPresented }
        .onChange(of: model.isSearchPresented) { _, presented in
            if presented { isNameFocused = false }
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            HStack(spacing: 12) {
                Button {
                    isNameFocused = false
                    withAnimation(reduceMotion ? nil : ListEditorPresentation.animation(
                        reduceMotion: false,
                        isPresented: !showsIcons
                    )) {
                        showsIcons.toggle()
                    }
                } label: {
                    Image(systemName: draft.systemImage)
                        .font(.title3.weight(.semibold))
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .foregroundStyle(SnipListAppearance(preset: draft.color).color)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Choose list icon, current: \(SnipListIconOptions.title(for: draft.systemImage))")
                .accessibilityIdentifier("choose-list-icon")

                TextField(list.displayName, text: $draft.name)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(SnipListAppearance(preset: draft.color).color)
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
                .accessibilityLabel("Done")
                .accessibilityIdentifier("save-list")
            }
            SnipListColorPicker(selection: $draft.color)
                .padding(.top, SnipSnapSpacing.relatedContent)
                .onChange(of: draft.color) { isNameFocused = false }
            if showsIcons {
                InlineListIconPicker(selection: $draft.systemImage)
                    .padding(.top, SnipSnapSpacing.relatedContent)
                    .transition(.opacity)
            }
        }
        .disabled(draft.isSaving)
        .padding(SnipSnapSpacing.paneContentInset)
    }

    private func save() async {
        guard !draft.isSaving else { return }
        draft.isSaving = true
        let cleaned = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded = await model.renameList(
            list,
            name: cleaned.isEmpty ? list.name : cleaned,
            systemImage: draft.systemImage,
            color: .set(draft.color)
        )
        draft.isSaving = false
        if succeeded {
            isNameFocused = false
            model.finishListEditing(id: list.id)
        }
    }
}
