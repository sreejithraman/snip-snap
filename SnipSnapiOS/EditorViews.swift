import Foundation
import Observation
import PhotosUI
import QuickLook
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers

/// One session follows the snip between collection and search rows.
@Observable @MainActor
final class SnipEditorDraft {
    let original: Snip
    var content: String
    var attachments: [AttachmentDraft]
    var previewURL: URL?
    var isImporting = false
    var isPickingPhotos = false
    var selectedPhotos: [PhotosPickerItem] = []
    var isTakingPhoto = false
    var replacementID: UUID?
    private var stagingTask: Task<Void, Never>?
    private(set) var isSaving = false
    private(set) var isPreparingPreview = false
    private var isDiscarded = false
    private let stagingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnipSnapAttachmentDrafts", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    init(snip: Snip) {
        original = snip
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

    var isStaging: Bool { stagingTask != nil }
    var canDismiss: Bool {
        !isDiscarded && AttachmentDraftLifecycle.allowsSaving(
            isSaving: isSaving,
            isStaging: isStaging,
            isImporting: isImporting,
            isPickingMedia: isPickingPhotos || isTakingPhoto,
            isPreviewing: previewURL != nil || isPreparingPreview
        )
    }
    var canSave: Bool {
        !isDiscarded && canDismiss
            && (!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func save(using model: IOSAppModel) async -> Bool {
        guard canSave else { return false }
        isSaving = true
        let succeeded = await model.saveInlineSnipEdit(self)
        isSaving = false
        if succeeded || isDiscarded { cleanStagingDirectory() }
        return succeeded
    }

    func stopImport() { stagingTask?.cancel() }

    func discard() {
        isDiscarded = true
        stagingTask?.cancel()
        // A save or cancelled importer may still be reading staged files.
        if !isSaving && !isStaging { cleanStagingDirectory() }
    }

    func previewAttachment(_ attachment: AttachmentDraft, using model: IOSAppModel) {
        guard !isPreparingPreview else { return }
        isPreparingPreview = true
        Task {
            defer { isPreparingPreview = false }
            guard let url = await attachment.previewURL(prepareExisting: {
                await model.prepareAttachmentPreview($0)
            }),
                  !isDiscarded,
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

    func presentAttachmentSource(_ source: AttachmentSource) {
        switch source {
        case .files: isImporting = true
        case .photos: isPickingPhotos = true
        case .camera: isTakingPhoto = true
        }
    }

    func stage(_ result: Result<[URL], any Error>, using model: IOSAppModel) {
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
        stageMedia(.files(urls), using: model)
    }

    func stageMedia(_ input: AttachmentMediaInput, using model: IOSAppModel) {
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
            defer {
                stagingTask = nil
                if isDiscarded { cleanStagingDirectory() }
            }
            do {
                staged = try await AttachmentMediaStager.stage(selectedInput, in: stagingDirectory)
                try Task.checkCancellation()
                guard !isDiscarded else {
                    AttachmentDraftStager.clean(staged)
                    return
                }
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

    func removeAttachment(id: UUID) {
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

struct InlineSnipEditor: View {
    @Bindable var draft: SnipEditorDraft
    let model: IOSAppModel
    @FocusState.Binding var isFocused: Bool
    var isSearchResult = false
    var sourceListID: UUID? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: SnipSnapSpacing.relatedContent) {
            if draft.original.isPinned {
                SnipCopyControl(
                    appearance: listAppearance(for: draft.original, in: model.lists),
                    isPinned: true,
                    action: {}
                )
                .disabled(true)
                .opacity(0.5)
                .accessibilityLabel("Copy Pinned Snip")
            } else {
                Image(systemName: draft.original.isDone ? "checkmark.circle.fill" : "circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
                if !draft.attachments.isEmpty {
                    AttachmentEditorControls(
                        attachments: draft.attachments,
                        model: model,
                        isDisabled: !draft.canDismiss,
                        preview: { draft.previewAttachment($0, using: model) },
                        replace: { attachment, source in
                            draft.replacementID = attachment.id
                            draft.presentAttachmentSource(source)
                        },
                        remove: { draft.removeAttachment(id: $0.id) }
                    )
                }

                TextField("Snip text", text: $draft.content, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...8)
                    .focused($isFocused)
                    .disabled(!ownsPresentation || !draft.canDismiss)
                    .accessibilityIdentifier(ownsPresentation ? "inline-snip-text" : "inactive-inline-snip-text")

                if draft.isStaging {
                    HStack {
                        ProgressView()
                        Text("Adding files…").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("copying-attachments")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        addAttachmentButton
                        Spacer(minLength: SnipSnapSpacing.relatedContent)
                        cancelButton
                        saveButton
                    }
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack {
                            addAttachmentButton
                            Spacer()
                        }
                        HStack(spacing: 4) {
                            cancelButton
                            saveButton
                        }
                    }
                }
            }
        }
        .padding(SnipSnapSpacing.cardContentInset)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            if reduceTransparency {
                shape.fill(Color(uiColor: .secondarySystemBackground))
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(uiColor: .separator), lineWidth: contrast == .increased ? 1.5 : 0.5)
                .allowsHitTesting(false)
        }
        .padding(.vertical, SnipSnapSpacing.relatedContent)
        .onChange(of: draft.content) {
            if ownsPresentation { model.haptics.invalidatePendingFeedback() }
        }
        .fileImporter(
            isPresented: presentationBinding(\.isImporting, inactiveValue: false),
            allowedContentTypes: [.data],
            allowsMultipleSelection: draft.replacementID == nil,
            onCompletion: { draft.stage($0, using: model) }
        )
        .photosPicker(
            isPresented: presentationBinding(\.isPickingPhotos, inactiveValue: false),
            selection: $draft.selectedPhotos,
            maxSelectionCount: draft.replacementID == nil ? nil : 1,
            matching: .images
        )
        .onChange(of: draft.selectedPhotos) { _, items in
            guard ownsPresentation, !items.isEmpty else { return }
            draft.selectedPhotos = []
            draft.stageMedia(.photos(items), using: model)
        }
        .fullScreenCover(isPresented: presentationBinding(\.isTakingPhoto, inactiveValue: false)) {
            AttachmentCameraPicker { image in
                draft.isTakingPhoto = false
                if let image { draft.stageMedia(.camera(image), using: model) } else { draft.replacementID = nil }
            }
        }
        .attachmentPreview(presentationBinding(\.previewURL, inactiveValue: nil), in: draft.attachments.compactMap { attachment in
            if case .existing = attachment.source {
                return model.usableAttachmentURL(for: attachment.id)
            }
            return attachment.url
        })
    }

    // A native List may keep cached cells while its source sits behind search.
    // Read ownership when the binding is accessed, rather than capturing visibility.
    private var ownsPresentation: Bool {
        guard model.snipEditorDraft === draft,
              isSearchResult == model.isSearchPresented else { return false }
        if isSearchResult { return true }
        guard let sourceListID else { return false }
        return model.selectedPage == .list(sourceListID)
    }

    private func presentationBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<SnipEditorDraft, Value>, inactiveValue: Value
    ) -> Binding<Value> {
        Binding(
            get: { ownsPresentation ? draft[keyPath: keyPath] : inactiveValue },
            set: { value in
                guard ownsPresentation else { return }
                draft[keyPath: keyPath] = value
            }
        )
    }

    private var addAttachmentButton: some View {
        AttachmentSourceMenu(choose: { source in
            draft.replacementID = nil
            draft.presentAttachmentSource(source)
        }) {
            secondaryActionIcon("plus")
        }
        .buttonStyle(.plain)
        .disabled(!draft.canDismiss)
        .accessibilityLabel("Add attachments")
        .accessibilityIdentifier("add-attachments")
    }

    private var cancelButton: some View {
        Button {
            if draft.isStaging {
                draft.stopImport()
            } else {
                isFocused = false
                model.cancelInlineSnipEdit()
            }
        } label: {
            secondaryActionIcon("xmark")
        }
        .buttonStyle(.plain)
        .disabled(!draft.canDismiss && !draft.isStaging)
        .accessibilityLabel(draft.isStaging ? "Stop Import" : "Cancel Editing")
        .accessibilityIdentifier(draft.isStaging ? "cancel-attachment-import" : "inline-snip-cancel")
    }

    private var saveButton: some View {
        return Button {
            Task { @MainActor in
                if await draft.save(using: model) {
                    isFocused = false
                    model.finishInlineSnipEdit(draft)
                }
            }
        } label: {
            EditorConfirmActionIcon(
                appearance: listAppearance(for: draft.original, in: model.lists),
                isEnabled: draft.canSave,
                isSaving: draft.isSaving
            )
        }
        .buttonStyle(.plain)
        .disabled(!draft.canSave)
        .accessibilityLabel(draft.isSaving ? "Saving…" : "Save")
        .accessibilityIdentifier("inline-snip-save")
    }

    private func secondaryActionIcon(_ systemName: String) -> some View {
        EditorSecondaryActionIcon(systemName: systemName)
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

/// Compact controls for inline snip editing.
private struct EditorSecondaryActionIcon: View {
    let systemName: String
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 14

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: symbolSize, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: diameter, height: diameter)
            .background(SnipSnapTheme.compactActionFill, in: Circle())
            .overlay { Circle().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5) }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

private struct EditorConfirmActionIcon: View {
    let appearance: SnipListAppearance
    var isEnabled = true
    var isSaving = false
    @Environment(\.self) private var environment
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 14

    var body: some View {
        let labelColor = isEnabled
            ? appearance.filledControlLabel(in: environment) : SnipSnapTheme.disabledActionGlassLabel
        Group {
            if isSaving {
                ProgressView().tint(labelColor)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: symbolSize, weight: .semibold))
            }
        }
        .foregroundStyle(labelColor)
        .frame(width: diameter, height: diameter)
        .background(isEnabled ? appearance.controlTint : SnipSnapTheme.disabledActionGlassTint, in: Circle())
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}

struct InlineListEditor: View {
    private enum AppearanceTab { case icon, color }

    let model: IOSAppModel
    let list: SnipList
    let cancelNewList: (UUID) async -> Bool
    @Bindable private var draft: InlineListDraft
    @State private var appearanceTab: AppearanceTab = .color
    @State private var iconQuery = ""
    @FocusState private var focusedField: ListAppearanceField?
    @ScaledMetric(relativeTo: .body) private var actionSymbolSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var actionLabelSize: CGFloat = 20
    @Environment(\.self) private var environment
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    init(model: IOSAppModel, list: SnipList, cancelNewList: @escaping (UUID) async -> Bool) {
        self.model = model
        self.list = list
        self.cancelNewList = cancelNewList
        draft = model.listDraft(for: list)
    }

    var body: some View {
        VStack(spacing: 0) {
            if verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        editorHeader
                        switch appearanceTab {
                        case .icon:
                            Section {
                                ListIconGrid(selection: $draft.systemImage, query: iconQuery)
                                    .padding(.horizontal, SnipSnapSpacing.paneContentInset)
                            } header: {
                                ListIconSearchField(query: $iconQuery, focus: $focusedField, usesGlassBackground: true)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, SnipSnapSpacing.paneContentInset)
                                    .padding(.bottom, SnipSnapSpacing.relatedContent)
                            }
                        case .color:
                            SnipListColorPicker(selection: $draft.color, showsTitle: false)
                                .padding(SnipSnapSpacing.paneContentInset)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("list-icon-results")
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
            } else {
                editorHeader
                    .fixedSize(horizontal: false, vertical: true)
                appearancePicker
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) { editorFooter }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .disabled(draft.isSaving)
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
        .padding(.horizontal, SnipSnapSpacing.relatedContent)
        .padding(.top, SnipSnapSpacing.relatedContent)
        .padding(.bottom, SnipSnapSpacing.relatedContent)
        .task { focusedField = model.newListID == list.id && !model.isSearchPresented ? .name : nil }
        .onChange(of: model.isSearchPresented) { _, presented in
            if presented {
                focusedField = nil
            }
        }
    }

    private var appearancePicker: some View {
        Group {
            switch appearanceTab {
            case .icon:
                InlineListIconPicker(selection: $draft.systemImage, query: $iconQuery, searchFocus: $focusedField)
            case .color:
                ScrollView {
                    SnipListColorPicker(selection: $draft.color, showsTitle: false)
                        .padding(.vertical, SnipSnapSpacing.relatedContent)
                }
                .scrollBounceBehavior(.basedOnSize)
                .padding(.horizontal, SnipSnapSpacing.paneContentInset)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var appearanceSelection: Binding<AppearanceTab> {
        Binding(get: { appearanceTab }, set: { tab in
            let keepsKeyboard = focusedField != nil
            appearanceTab = tab
            if keepsKeyboard {
                focusedField = tab == .color ? .name : .iconSearch
            }
        })
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            HStack(spacing: 12) {
                Image(systemName: ListIconSymbol.supportedName(draft.systemImage))
                    .font(.title3.weight(.semibold))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .foregroundStyle(SnipListAppearance(preset: draft.color).color)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("List icon: \(SnipListIconOptions.title(for: draft.systemImage))")
                    .accessibilityIdentifier("list-icon-preview")

                TextField(list.displayName, text: $draft.name)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(SnipListAppearance(preset: draft.color).color)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
                    .accessibilityLabel("List name")
                    .accessibilityIdentifier("list-name")

            }
            Picker("List appearance", selection: appearanceSelection) {
                Text("Icon").tag(AppearanceTab.icon)
                Text("Color").tag(AppearanceTab.color)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("list-appearance-picker")
        }
        .padding(SnipSnapSpacing.paneContentInset)
    }

    private var editorFooter: some View {
        HStack(spacing: SnipSnapSpacing.relatedContent) {
            Button(role: .cancel) {
                if model.newListID == list.id {
                    Task { await cancelNewList() }
                } else {
                    focusedField = nil
                    model.finishListEditing(id: list.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: actionSymbolSize, weight: .medium))
                    .frame(width: actionLabelSize, height: actionLabelSize)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(model.newListID == list.id ? "Cancel new list" : "Cancel list editing")
            .accessibilityIdentifier(model.newListID == list.id ? "cancel-new-list" : "cancel-list-editing")

            Button {
                Task { await save() }
            } label: {
                Group {
                    if draft.isSaving {
                        ProgressView()
                            .tint(SnipListAppearance(preset: draft.color).filledControlLabel(in: environment))
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: actionSymbolSize, weight: .semibold))
                    }
                }
                .frame(width: actionLabelSize, height: actionLabelSize)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(SnipListAppearance(preset: draft.color).controlTint)
            .foregroundStyle(SnipListAppearance(preset: draft.color).filledControlLabel(in: environment))
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(draft.isSaving ? "Saving…" : model.newListID == list.id ? "Create list" : "Save list")
            .accessibilityIdentifier("save-list")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, SnipSnapSpacing.paneContentInset)
        .padding(.vertical, SnipSnapSpacing.relatedContent)
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
            focusedField = nil
            model.finishListEditing(id: list.id)
        }
    }

    private func cancelNewList() async {
        guard !draft.isSaving else { return }
        draft.isCancelling = true
        draft.isSaving = true
        let cancelled = await cancelNewList(list.id)
        if !cancelled {
            draft.isSaving = false
            draft.isCancelling = false
        }
    }

}
