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
                        .foregroundStyle(SnipListAppearance(pair: draft.color).color)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Choose list icon, current: \(SnipListIconOptions.title(for: draft.systemImage))")
                .accessibilityIdentifier("choose-list-icon")

                TextField(list.displayName, text: $draft.name)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(SnipListAppearance(pair: draft.color).color)
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
