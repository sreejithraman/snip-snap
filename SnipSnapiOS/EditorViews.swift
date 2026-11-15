import Foundation
import Observation
import PhotosUI
import QuickLook
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class SnipEditorDraft {
    /// Where a picked file goes.
    private enum AttachmentTarget: Equatable {
        case append
        case replace(UUID)
    }

    /// Saving and staging both read the staging directory, so one runs at a time.
    private enum Work {
        case idle
        case staging(session: UUID, task: Task<Void, Never>)
        case saving(session: UUID)
    }

    /// A discarded draft keeps its staging directory until running work stops reading it.
    private enum Phase {
        case editing(Work)
        case discarded(finishing: Work)
    }

    /// Pickers and previews are modal, so one occupies the editor at a time.
    private enum Presentation: Equatable {
        case none
        case picker(AttachmentSource)
        case preparingPreview(session: UUID)
        case preview(URL)
    }

    let original: Snip
    var content: String
    private(set) var attachments: [AttachmentDraft]
    /// The Photos picker's selection, which the editor stages and clears.
    var selectedPhotos: [PhotosPickerItem] = []
    private var phase = Phase.editing(.idle)
    private var presentation = Presentation.none
    /// A picker's result can arrive after it closes.
    private var pendingPick: AttachmentTarget? = nil
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

    private var work: Work {
        switch phase {
        case .editing(let work), .discarded(finishing: let work): work
        }
    }

    var isSaving: Bool {
        if case .saving = work { true } else { false }
    }

    var isStaging: Bool {
        if case .staging = work { true } else { false }
    }

    var previewURL: URL? {
        if case .preview(let url) = presentation { url } else { nil }
    }

    var presentedPicker: AttachmentSource? {
        if case .picker(let source) = presentation { source } else { nil }
    }

    /// A replacing picker takes one item.
    var pickerReplacesAttachment: Bool {
        if case .some(.replace) = pendingPick { true } else { false }
    }

    private var isPreviewing: Bool {
        switch presentation {
        case .preparingPreview, .preview: true
        case .none, .picker: false
        }
    }

    var canDismiss: Bool {
        guard case .editing = phase else { return false }
        return AttachmentDraftLifecycle.allowsSaving(
            isSaving: isSaving,
            isStaging: isStaging,
            isImporting: presentedPicker == .files,
            isPickingMedia: presentedPicker == .photos || presentedPicker == .camera,
            isPreviewing: isPreviewing
        )
    }

    var canSave: Bool {
        canDismiss
            && (!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func save(using model: IOSAppModel) async -> Bool {
        guard canSave else { return false }
        let session = UUID()
        phase = .editing(.saving(session: session))
        let succeeded = await model.saveInlineSnipEdit(self)
        finishSaving(session, succeeded: succeeded)
        return succeeded
    }

    func stopImport() {
        if case .staging(session: _, task: let task) = work { task.cancel() }
    }

    func discard() {
        guard case .editing(let work) = phase else { return }
        phase = .discarded(finishing: work)
        presentation = .none
        pendingPick = nil
        switch work {
        case .idle: cleanStagingDirectory()
        case .staging(session: _, task: let task): task.cancel()
        case .saving: break
        }
    }

    func presentAttachmentPicker(_ source: AttachmentSource, replacing attachmentID: UUID? = nil) {
        presentation = .picker(source)
        pendingPick = attachmentID.map(AttachmentTarget.replace) ?? .append
    }

    /// The picker closed itself. Its pending pick waits for the result.
    func dismissAttachmentPicker(_ source: AttachmentSource) {
        guard presentation == .picker(source) else { return }
        presentation = .none
    }

    func finishCameraCapture(_ image: UIImage?, using model: IOSAppModel) {
        dismissAttachmentPicker(.camera)
        if let image {
            stageMedia(.camera(image), using: model)
        } else {
            pendingPick = nil
        }
    }

    func previewAttachment(_ attachment: AttachmentDraft, using model: IOSAppModel) {
        guard case .editing = phase, presentation == .none else { return }
        let session = UUID()
        presentation = .preparingPreview(session: session)
        Task {
            let url = await attachment.previewURL(prepareExisting: {
                await model.prepareAttachmentPreview($0)
            })
            guard presentation == .preparingPreview(session: session) else { return }
            presentation = preparedPreview(of: attachment, at: url, using: model)
        }
    }

    func pageAttachmentPreview(to url: URL) {
        guard case .preview = presentation else { return }
        presentation = .preview(url)
    }

    func dismissAttachmentPreview() {
        guard case .preview = presentation else { return }
        presentation = .none
    }

    func stage(_ result: Result<[URL], any Error>, using model: IOSAppModel) {
        switch result {
        case .success(let urls):
            stageMedia(.files(urls), using: model)
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                model.presentError(error, operation: "attachment.import_select")
            }
            pendingPick = nil
        }
    }

    func stageMedia(_ input: AttachmentMediaInput, using model: IOSAppModel) {
        guard case .editing(.idle) = phase else { return }
        let target = pendingPick ?? .append
        pendingPick = nil
        let selectedInput: AttachmentMediaInput
        if case .files(let urls) = input, case .replace = target {
            selectedInput = .files(Array(urls.prefix(1)))
        } else {
            selectedInput = input
        }
        let session = UUID()
        // The task runs on the main actor, so it starts only after `phase` is set.
        let task = Task {
            var staged: [StagedAttachment] = []
            defer { finishStaging(session) }
            do {
                staged = try await AttachmentMediaStager.stage(selectedInput, in: stagingDirectory)
                try Task.checkCancellation()
                guard case .editing = phase else {
                    AttachmentDraftStager.clean(staged)
                    return
                }
                applyStaged(staged, to: target)
            } catch is CancellationError {
                AttachmentDraftStager.clean(staged)
            } catch {
                model.presentError(error, operation: "attachment.import_stage")
            }
        }
        phase = .editing(.staging(session: session, task: task))
    }

    private func finishSaving(_ session: UUID, succeeded: Bool) {
        switch phase {
        case .editing(.saving(session: let current)) where current == session:
            phase = .editing(.idle)
            if succeeded { cleanStagingDirectory() }
        case .discarded(finishing: .saving(session: let current)) where current == session:
            finishDiscardedWork()
        default:
            break
        }
    }

    private func finishStaging(_ session: UUID) {
        switch phase {
        case .editing(.staging(session: let current, task: _)) where current == session:
            phase = .editing(.idle)
        case .discarded(finishing: .staging(session: let current, task: _)) where current == session:
            finishDiscardedWork()
        default:
            break
        }
    }

    /// Running work no longer reads the discarded draft's staged files.
    private func finishDiscardedWork() {
        phase = .discarded(finishing: .idle)
        cleanStagingDirectory()
    }

    private func preparedPreview(
        of attachment: AttachmentDraft, at url: URL?, using model: IOSAppModel
    ) -> Presentation {
        guard let url, attachments.first(where: { $0.id == attachment.id }) == attachment else { return .none }
        if case .existing = attachment.source {
            return .preview(model.usableAttachmentURL(for: attachment.id) ?? url)
        }
        return .preview(url)
    }

    private func applyStaged(_ staged: [StagedAttachment], to target: AttachmentTarget) {
        if case .replace(let targetID) = target, let replacement = staged.first {
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
                            draft.presentAttachmentPicker(source, replacing: attachment.id)
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

                IOSInlineFailureView(model: model, operations: ["snip.update", "snip.edit_attachments", "attachment."])

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
            isPresented: pickerBinding(.files),
            allowedContentTypes: [.data],
            allowsMultipleSelection: !draft.pickerReplacesAttachment,
            onCompletion: { draft.stage($0, using: model) }
        )
        .photosPicker(
            isPresented: pickerBinding(.photos),
            selection: $draft.selectedPhotos,
            maxSelectionCount: draft.pickerReplacesAttachment ? 1 : nil,
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: draft.selectedPhotos) { _, items in
            guard ownsPresentation, !items.isEmpty else { return }
            draft.selectedPhotos = []
            draft.stageMedia(.photos(items), using: model)
        }
        .fullScreenCover(isPresented: pickerBinding(.camera)) {
            AttachmentCameraPicker { draft.finishCameraCapture($0, using: model) }
        }
        .attachmentPreview(previewBinding, in: draft.attachments.compactMap { attachment in
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

    private func pickerBinding(_ source: AttachmentSource) -> Binding<Bool> {
        Binding(
            get: { ownsPresentation && draft.presentedPicker == source },
            set: { isPresented in
                guard ownsPresentation, !isPresented else { return }
                draft.dismissAttachmentPicker(source)
            }
        )
    }

    private var previewBinding: Binding<URL?> {
        Binding(
            get: { ownsPresentation ? draft.previewURL : nil },
            set: { url in
                guard ownsPresentation else { return }
                if let url {
                    draft.pageAttachmentPreview(to: url)
                } else {
                    draft.dismissAttachmentPreview()
                }
            }
        )
    }

    private var addAttachmentButton: some View {
        AttachmentSourceMenu(choose: { draft.presentAttachmentPicker($0) }) {
            EditorSecondaryActionIcon(systemName: "plus")
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
            EditorSecondaryActionIcon(systemName: "xmark")
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
}

enum ListEditorPresentation {
    static func animation(reduceMotion: Bool, isPresented: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(duration: isPresented ? 0.3 : 0.22, bounce: 0)
    }
}

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
    let model: IOSAppModel
    let list: SnipList
    let cancelNewList: (UUID) async -> Bool
    @Bindable private var draft: InlineListDraft
    @State private var didReceiveInitialFocus = false
    @FocusState private var focusedField: ListAppearanceField?
    @ScaledMetric(relativeTo: .body) private var actionSymbolSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var actionLabelSize: CGFloat = 20
    @Environment(\.self) private var environment
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

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
                    // Keep editor controls outside the lazy icon section during keyboard layout changes.
                    VStack(spacing: 0) {
                        editorHeader
                        switch draft.appearanceTab {
                        case .icon:
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                Section {
                                    ListIconGrid(selection: $draft.systemImage, query: draft.iconQuery)
                                        .padding(.horizontal, SnipSnapSpacing.paneContentInset)
                                } header: {
                                    ListIconSearchField(query: $draft.iconQuery, focus: $focusedField, usesGlassBackground: true)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, SnipSnapSpacing.paneContentInset)
                                        .padding(.bottom, SnipSnapSpacing.relatedContent)
                                }
                            }
                        case .color:
                            SnipListColorPicker(selection: $draft.color, automatic: SnipList.automaticColor(for: list.id), showsTitle: false)
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
        // Bar hosting drops field focus updates on iOS 26.5.
        .safeAreaInset(edge: .bottom, spacing: 0) { editorFooter }
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
        .task(id: isEnabled) {
            guard isEnabled, !didReceiveInitialFocus,
                  model.newListID == list.id, !model.isSearchPresented else { return }
            focusedField = .name
        }
        .onChange(of: focusedField) { _, new in
            // Page entrance can disable the field before a request takes effect.
            if new != nil { didReceiveInitialFocus = true }
        }
        .onChange(of: model.isSearchPresented) { _, presented in
            if presented {
                focusedField = nil
            }
        }
    }

    private var appearancePicker: some View {
        Group {
            switch draft.appearanceTab {
            case .icon:
                InlineListIconPicker(selection: $draft.systemImage, query: $draft.iconQuery, searchFocus: $focusedField)
            case .color:
                ScrollView {
                    SnipListColorPicker(selection: $draft.color, automatic: SnipList.automaticColor(for: list.id), showsTitle: false)
                        .padding(.vertical, SnipSnapSpacing.relatedContent)
                }
                .scrollBounceBehavior(.basedOnSize)
                .padding(.horizontal, SnipSnapSpacing.paneContentInset)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var appearanceSelection: Binding<InlineListDraft.AppearanceTab> {
        Binding(get: { draft.appearanceTab }, set: { tab in
            let keepsKeyboard = focusedField != nil
            draft.appearanceTab = tab
            if keepsKeyboard {
                focusedField = tab == .color ? .name : .iconSearch
            }
        })
    }

    /// The list as it will look once saved.
    private var draftPreview: SnipList {
        var preview = list
        if !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { preview.name = draft.name }
        preview.systemImage = draft.systemImage
        preview.color = draft.color
        return preview
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            HStack(spacing: 12) {
                SnipListMarkView(list: draftPreview, diameter: 40)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel(
                        draftPreview.icon.map { "List icon: \(SnipListIconOptions.title(for: $0))" } ?? String(localized: "No icon")
                    )
                    .accessibilityIdentifier("list-icon-preview")

                TextField(list.displayName, text: $draft.name)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(draftPreview.accent.color)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
                    .accessibilityLabel("List name")
                    .accessibilityIdentifier("list-name")

            }
            IOSInlineFailureView(model: model, operations: ["list."])
            Picker("List appearance", selection: appearanceSelection) {
                Text("Icon").tag(InlineListDraft.AppearanceTab.icon)
                Text("Color").tag(InlineListDraft.AppearanceTab.color)
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
            .controlSize(.large)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(model.newListID == list.id ? "Cancel new list" : "Cancel list editing")
            .accessibilityIdentifier(model.newListID == list.id ? "cancel-new-list" : "cancel-list-editing")

            Button {
                Task { await save() }
            } label: {
                Group {
                    if draft.isSaving {
                        ProgressView()
                            .tint(draftPreview.accent.filledControlLabel(in: environment))
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: actionSymbolSize, weight: .semibold))
                    }
                }
                .frame(width: actionLabelSize, height: actionLabelSize)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(draftPreview.accent.controlTint)
            .foregroundStyle(draftPreview.accent.filledControlLabel(in: environment))
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
        if await model.saveListDraft(id: list.id) {
            focusedField = nil
        }
    }

    private func cancelNewList() async {
        _ = await cancelNewList(list.id)
    }

}

struct IOSInlineFailureView: View {
    let model: IOSAppModel
    let operations: [String]
    var includesProtectedUndoFailure = false

    var body: some View {
        if let failure = model.inlineFailure,
           failure.surface == .inline || includesProtectedUndoFailure,
           operations.contains(where: { failure.operation.hasPrefix($0) }) {
            VStack(alignment: .leading, spacing: 6) {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Details") { model.showErrorDetails(failure) }
                    Button("Dismiss") { model.dismissError() }
                }
                .font(.subheadline)
            }
            .accessibilityIdentifier("inline-operation-error")
        }
    }
}
