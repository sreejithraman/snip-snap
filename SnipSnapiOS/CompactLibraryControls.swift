import Observation
import PhotosUI
import QuickLook
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum CompactControlMetrics {
    static let minimumInteractiveLength: CGFloat = 44
}

private struct CompactGlassCircleButton<Label: View>: View {
    let length: CGFloat
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: length, height: length)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
    }
}

private struct SendDestinationRequest {
    let sourceID: UUID
    let libraryRevision: UUID
}

struct CompactLibraryControls: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let model: IOSAppModel
    let clipboard: IOSClipboardModel
    let storage: CompactComposerStorage
    let showsListTabs: Bool
    let isSelecting: Bool
    @Binding var motion: ListPageMotion
    let pageFrame: ListPageFrame?
    let pageWidth: CGFloat
    let deleteList: (UUID) async -> Void
    let createList: (LibraryPage, [LibraryPage]) async -> Void
    @Namespace private var composerGlass
    @Binding var sheet: AppSheet?

    @State private var sendDestination: SendDestinationRequest?
    @State private var draft = ComposerDraft()
    @State private var draftListID: UUID?
    @State private var toolbarWidth: CGFloat = 320
    @State private var composerHeights: [LibraryPage: CGFloat] = [:]
    @State private var previewURL: URL?
    @State private var isImporting = false
    @State private var isPickingPhotos = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isTakingPhoto = false
    @State private var composerFieldID = UUID()
    @State private var stagingTask: Task<Void, Never>?
    @State private var isStagingPaste = false
    @Binding private var isComposerFocused: Bool
    @ScaledMetric(relativeTo: .body) private var scaledControlLength =
        CompactControlMetrics.minimumInteractiveLength
    @ScaledMetric(relativeTo: .body) private var sendIconLength: CGFloat = 16

    private var controlLength: CGFloat {
        max(CompactControlMetrics.minimumInteractiveLength, scaledControlLength)
    }

    private var sendSize: CGSize {
        let height = controlLength - 12
        return CGSize(width: height + sendIconLength, height: height)
    }

    init(
        model: IOSAppModel,
        clipboard: IOSClipboardModel,
        storage: CompactComposerStorage,
        isComposerFocused: Binding<Bool>,
        showsListTabs: Bool = true,
        isSelecting: Bool = false,
        sheet: Binding<AppSheet?>,
        motion: Binding<ListPageMotion> = .constant(ListPageMotion()),
        pageFrame: ListPageFrame? = nil,
        pageWidth: CGFloat = 0,
        deleteList: @escaping (UUID) async -> Void,
        createList: @escaping (LibraryPage, [LibraryPage]) async -> Void
    ) {
        self.model = model
        self.clipboard = clipboard
        self.storage = storage
        self.showsListTabs = showsListTabs
        self.isSelecting = isSelecting
        _motion = motion
        self.pageFrame = pageFrame
        self.pageWidth = pageWidth
        self.deleteList = deleteList
        self.createList = createList
        _isComposerFocused = isComposerFocused
        _sheet = sheet
    }

    private var isStaging: Bool { stagingTask != nil }
    private var isClipboardSelected: Bool { model.selectedPage == .clipboard }

    private var showsComposerPages: Bool {
        !model.isSearchPresented && !isSelecting && !showsListEditor
    }

    private var showsComposer: Bool { showsComposerPages && !isClipboardSelected }

    private var showsListEditor: Bool {
        !isClipboardSelected && !model.isSearchPresented
            && model.editingListID == model.selectedListID
    }

    // Navigation belongs to the resting library, rather than the keyboard's input controls.
    private var showsNavigation: Bool {
        !model.isSearchPresented && !showsListEditor && !isComposerFocused
    }

    var body: some View {
        VStack(spacing: SnipSnapSpacing.relatedContent) {
            if showsComposerPages {
                GlassEffectContainer(spacing: SnipSnapSpacing.relatedContent) {
                    composerPages
                }
            }

            if !showsListTabs && showsNavigation {
                GlassEffectContainer {
                    pasteButton
                }
            } else if showsNavigation {
                navigationControls
            }
        }

        .frame(maxWidth: .infinity)
        .padding(.horizontal, SnipSnapSpacing.cardContentInset)
        .padding(.top, showsListEditor ? 0 : SnipSnapSpacing.relatedContent)
        .padding(.bottom, showsListEditor ? 0 : 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            stage(result)
        }
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $selectedPhotos,
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
                if let image { stageMedia(.camera(image)) }
            }
        }
        .attachmentPreview($previewURL, in: draft.attachments)
        .onAppear {
            draftListID = model.selectedListID
            if storage.savingListID != model.selectedListID {
                draft = storage.draftStore.draft(for: model.selectedListID)
            }
        }
        .onChange(of: model.selectedListID) { _, listID in
            sendDestination = nil
            composerFieldID = UUID()
            draftListID = listID
            draft = storage.savingListID == listID
                ? ComposerDraft()
                : storage.draftStore.draft(for: listID)
        }
        .onChange(of: model.libraryRevision) { _, _ in sendDestination = nil }
        .onChange(of: showsComposer) { _, visible in
            if !visible { isComposerFocused = false; sendDestination = nil }
        }
        .onChange(of: previewURL) { _, url in
            if url != nil { sendDestination = nil }
        }
        .onChange(of: model.isManagingLists) { _, presented in
            if presented { isComposerFocused = false; sendDestination = nil }
        }
        .onChange(of: sheet) { _, sheet in
            if sheet != nil { sendDestination = nil }
        }
        .onDisappear {
            sendDestination = nil
            stagingTask?.cancel()
            storage.draftStore.flushText()
        }
    }

    private var navigationWidth: CGFloat { max(0, toolbarWidth - 32) }

    private var navigationControlLength: CGFloat {
        // Let icon buttons grow into the margins without shrinking tab labels.
        max(48, min(controlLength, (navigationWidth - listToolbarWidth) / 2 - 8))
    }

    private var listToolbarWidth: CGFloat {
        // Reserve the same space on both sides for Paste and Search.
        max(120, min(256, toolbarWidth - 168))
    }

    private var navigationControls: some View {
        let length = navigationControlLength
        let progress = min(1, motion.dragDistance / length)
        let selectorWidth = listToolbarWidth + (navigationWidth - listToolbarWidth) * progress
        let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
        let travel = reduceMotion ? 0 : (length + 24) * progress * direction

        return ZStack {
            ListSelector(
                model: model,
                controlLength: length,
                pageWidth: pageWidth,
                sheet: $sheet,
                deleteList: deleteList,
                createList: createList,
                labelViewport: listToolbarWidth,
                motion: $motion,
                pageFrame: frame
            )
            .frame(width: selectorWidth, height: length + 8)

            HStack {
                pasteButton
                    .offset(x: -travel)
                    .allowsHitTesting(!motion.isDragging)
                    .accessibilityHidden(motion.isDragging)

                Spacer(minLength: 0)

                CompactGlassCircleButton(length: length) {
                    model.isSearchPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: length * 22 / 48, weight: .medium))
                }
                .accessibilityLabel("Search")
                .offset(x: travel)
                .allowsHitTesting(!motion.isDragging)
                .accessibilityHidden(motion.isDragging)
            }
            .opacity(1 - progress)
        }
        .frame(width: navigationWidth, height: length + 8)
        .animation(motion.isDragging || reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12), value: motion.dragDistance)
    }

    private var pasteButton: some View {
        CompactGlassCircleButton(length: showsListTabs ? navigationControlLength : max(48, controlLength)) {
            if isClipboardSelected {
                let providers = UIPasteboard.general.itemProviders
                Task { await clipboard.capture(providers) }
            } else {
                pasteAndSave()
            }
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(showsListTabs ? .system(size: navigationControlLength * 20 / 48, weight: .medium) : .title3.weight(.medium))
        }
        .disabled(motion.isDragging || (isClipboardSelected
            ? clipboard.isPasting
            : !showsComposer || storage.isSaving || isStaging))
        .accessibilityLabel(isClipboardSelected ? "Paste" : "Paste and Save")
        .accessibilityIdentifier("paste-to-clipboard")
        .glassEffectID("paste", in: composerGlass)
        .glassEffectTransition(.materialize)
    }

    private func pasteAndSave() {
        guard showsComposer, !storage.isSaving, !isStaging else { return }
        model.haptics.invalidatePendingFeedback()
        let listID = model.selectedListID
        let pasteboard = UIPasteboard.general
        let text = pasteboard.string ?? ""
        let image = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? pasteboard.image : nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil else {
            model.presentError(
                String(localized: "There’s nothing to paste. Copy text or an image, then try again."),
                operation: "snip.paste_read",
                diagnosticCode: "snip.emptyClipboard"
            )
            return
        }
        storage.isSaving = true
        Task {
            var stagedFiles: [StagedAttachment] = []
            defer {
                AttachmentDraftStager.clean(stagedFiles)
                storage.isSaving = false
            }
            do {
                if let image {
                    stagedFiles = try await AttachmentMediaStager.stage(
                        .camera(image), in: storage.stagingDirectory
                    )
                }
                await model.createSnip(
                    content: text,
                    in: listID,
                    attachmentURLs: stagedFiles.map(\.url),
                    selectCreatedSnip: false
                )
            } catch {
                model.presentError(error, operation: "snip.paste_save")
            }
        }
    }

    private var frame: ListPageFrame {
        pageFrame ?? ListPageFrame(
            pages: [model.selectedPage], position: 0,
            retainedPages: [model.selectedPage], isMoving: false
        )
    }

    private var visibleComposerPages: [LibraryPage] {
        guard showsComposerPages else { return [] }
        return frame.retainedPages.filter { if case .list = $0 { true } else { false } }
    }

    private var composerHeight: CGFloat {
        guard showsComposerPages else { return 0 }
        // Interpolate the occupied height as Clipboard (which has no composer)
        // enters, keeping the last frame identical to the resting layout.
        return frame.retainedPages.reduce(0) { result, page in
            guard case .list = page else { return result }
            let weight = frame.weight(for: page)
            return result + weight * (composerHeights[page] ?? controlLength)
        }
    }

    private var composerPages: some View {
        ZStack(alignment: .bottom) {
            ForEach(visibleComposerPages, id: \.self) { page in
                if case .list(let id) = page,
                   let list = model.lists.first(where: { $0.id == id }) {
                    let isPreview = page != model.selectedPage
                    composer(
                        for: list,
                        draft: draft(for: id),
                        isPreview: isPreview
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(ListEditorRecession(isActive: model.editingListID == id && !isComposerFocused))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeights[page] = $0 }
                    .offset(x: frame.offset(
                        for: page, width: pageWidth > 0 ? pageWidth : toolbarWidth,
                        layoutDirection: layoutDirection, reduceMotion: reduceMotion
                    ))
                    .opacity(frame.opacity(for: page, reduceMotion: reduceMotion))
                    .accessibilityHidden(isPreview || frame.isMoving)
                    .allowsHitTesting(!isPreview && !frame.isMoving)
                }
            }
        }
        .frame(height: composerHeight, alignment: .bottom)
        .clipped()
    }

    private func composer(for list: SnipList, draft: ComposerDraft, isPreview: Bool) -> some View {
        HStack(alignment: .bottom, spacing: SnipSnapSpacing.relatedContent) {
            AttachmentSourceMenu(choose: { source in
                guard !isPreview else { return }
                model.haptics.invalidatePendingFeedback()
                switch source {
                case .files: isImporting = true
                case .photos: isPickingPhotos = true
                case .camera: isTakingPhoto = true
                }
            }) {
                Image(systemName: isPreview ? "plus" : (isStaging ? "hourglass" : "plus"))
                    .font(.title3.weight(.medium))
                    .frame(width: controlLength, height: controlLength)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .disabled(storage.isSaving || isStaging)
            .accessibilityLabel("Add Attachments")
            .modifier(ComposerAccessibility(isPreview: isPreview, identifier: "composer-add-attachments"))
            .modifier(ComposerGlassID(isPreview: isPreview, id: "attachments", namespace: composerGlass))

            GlassEffectContainer {
                VStack(spacing: SnipSnapSpacing.relatedContent) {
                    if !draft.attachments.isEmpty {
                        attachmentStrip(for: draft, isPreview: isPreview)
                            .padding(.horizontal, SnipSnapSpacing.cardContentInset)
                            .padding(.top, 10)
                    }

                    HStack(alignment: .bottom, spacing: SnipSnapSpacing.relatedContent) {
                        ComposerTextInput(
                            prompt: "Add to \(list.displayName)…",
                            text: isPreview ? .constant(draft.text) : composerText(for: list.id),
                            isFocused: isPreview ? .constant(false) : $isComposerFocused,
                            isEnabled: !isPreview && !storage.isSaving,
                            isPasteEnabled: !isStaging,
                            isTextInputEnabled: !isStagingPaste,
                            onPasteAttachments: { providers, selection in
                                if !isPreview { stagePastedAttachments(providers, at: selection, to: list.id) }
                            }
                        )
                            .padding(SnipSnapSpacing.relatedContent)
                            .frame(minHeight: controlLength, alignment: .center)
                            .modifier(ComposerAccessibility(isPreview: isPreview, identifier: "composer-text"))

                        Color.clear
                            .frame(width: sendSize.width, height: controlLength)
                            .allowsHitTesting(false)
                    }
                    .padding(.leading, SnipSnapSpacing.relatedContent / 2)
                    .padding(.trailing, SnipSnapSpacing.relatedContent)
                    .id(isPreview ? "preview-\(list.id.uuidString)" : composerFieldID.uuidString)
                }
                .frame(minHeight: controlLength)
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            !isPreview && isComposerFocused
                                ? SnipSnapTheme.focusedGlassEdge
                                : SnipSnapTheme.emphasizedGlassEdge,
                            lineWidth: !isPreview && isComposerFocused ? 1 : 0.75
                        )
                }
                .modifier(ComposerGlassID(isPreview: isPreview, id: "input", namespace: composerGlass))
            }
            // Keep Send's glass separate, with its visible capsule inset in the input.
            .overlay(alignment: .bottomTrailing) {
                GlassEffectContainer {
                    let colors = list.accent.sendColors(in: colorScheme, chrome: .glass)
                    AppMorphingSendControl(
                        sourceID: list.id, isEnabled: !isPreview && canSend(draft: draft),
                        usesRootSurface: !frame.isMoving,
                        projectsClosedButton: false,
                        tint: colors.tint, labelColor: colors.label,
                        size: sendSize, minimumHitHeight: controlLength, iconLength: sendIconLength,
                        destinations: model.lists,
                        isPresented: Binding(
                            get: { !isPreview && sendDestination?.sourceID == list.id },
                            set: { sendDestination = $0 ? SendDestinationRequest(
                                sourceID: list.id, libraryRevision: model.libraryRevision
                            ) : nil }
                        ),
                        send: {
                            guard !isPreview else { return }
                            let revision = model.libraryRevision
                            Task { await send(from: list.id, to: list.id, expectedLibraryRevision: revision) }
                        },
                        choose: { destinationID in
                            guard let request = sendDestination, request.sourceID == list.id else { return }
                            sendDestination = nil
                            Task { await send(
                                from: request.sourceID, to: destinationID,
                                expectedLibraryRevision: request.libraryRevision
                            ) }
                        }
                    )
                    .accessibilityHidden(isPreview)
                    .padding(.trailing, SnipSnapSpacing.relatedContent)
                }
            }
        }
    }

    private func attachmentStrip(for draft: ComposerDraft, isPreview: Bool) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.attachments, id: \.self) { url in
                    CompactDraftAttachment(
                        url: url,
                        preview: {
                            guard !isPreview else { return }
                            model.haptics.invalidatePendingFeedback()
                            previewURL = url
                        },
                        remove: {
                            guard !isPreview else { return }
                            removeAttachment(url)
                        }
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func draft(for listID: UUID) -> ComposerDraft {
        if draftListID == listID { return draft }
        return storage.savingListID == listID ? ComposerDraft() : storage.draftStore.draft(for: listID)
    }

    private func composerText(for listID: UUID) -> Binding<String> {
        let fieldID = composerFieldID
        return Binding(
            get: { draft(for: listID).text },
            set: { value in
                guard fieldID == composerFieldID, listID == model.selectedListID,
                      draftListID == listID else { return }
                model.haptics.invalidatePendingFeedback()
                guard storage.savingListID != listID else {
                    draft.text = ""
                    return
                }
                if let pasted = LargePastedText.largeInsertion(from: draft.text, to: value) {
                    stagePastedText(pasted)
                    return
                }
                draft.text = value
                storage.draftStore.setText(value, for: listID)
            }
        )
    }

    private func canSend(draft: ComposerDraft) -> Bool {
        AttachmentDraftLifecycle.allowsSaving(
            isSaving: storage.isSaving,
            isStaging: isStaging,
            isImporting: isImporting,
            isPickingMedia: isPickingPhotos || isTakingPhoto,
            isPreviewing: previewURL != nil
        )
            && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draft.attachments.isEmpty)
    }

    private func send(
        from sourceID: UUID, to destinationID: UUID, expectedLibraryRevision: UUID
    ) async {
        guard expectedLibraryRevision == model.libraryRevision,
              !frame.isMoving, sourceID == model.selectedListID,
              model.lists.contains(where: { $0.id == destinationID }),
              canSend(draft: draft(for: sourceID)) else { return }
        let snapshot = storage.draftStore.beginSave(listID: sourceID)
        storage.savingListID = snapshot.listID
        storage.isSaving = true
        composerFieldID = UUID()
        draft = ComposerDraft()
        let saved = await model.createSnip(
            content: snapshot.draft.text,
            in: destinationID,
            attachmentURLs: snapshot.draft.attachments,
            selectCreatedSnip: false,
            expectedLibraryRevision: expectedLibraryRevision, expectedSourceListID: sourceID
        )
        storage.draftStore.finishSave(snapshot, saved: saved)
        if saved {
            storage.draftStore.flushText()
        }
        storage.savingListID = nil
        storage.isSaving = false
        if model.selectedListID == snapshot.listID {
            draft = storage.draftStore.draft(for: snapshot.listID)
        }
        if !saved {
            composerFieldID = UUID()
        }
    }

    private func stagePastedAttachments(_ providers: [NSItemProvider], at selection: NSRange, to listID: UUID) {
        guard !isStaging, !storage.isSaving else { return }
        let body = storage.draftStore.draft(for: listID).text
        let scope = storage.draftStore.scope
        isStagingPaste = true
        stagingTask = Task {
            var files: [StagedAttachment] = []
            defer {
                stagingTask = nil
                isStagingPaste = false
            }
            do {
                let pasted = try await ComposerPasteboard.stage(providers, in: storage.stagingDirectory)
                files = pasted.files
                try Task.checkCancellation()
                guard storage.draftStore.scope == scope,
                      model.lists.contains(where: { $0.id == listID }) else {
                    AttachmentDraftStager.clean(files)
                    return
                }
                storage.draftStore.setText(pasted.inserting(into: body, at: selection), for: listID)
                addStagedFiles(files, to: listID)
            } catch is CancellationError {
                AttachmentDraftStager.clean(files)
            } catch {
                model.presentError(error, operation: "composer.paste_stage")
            }
        }
    }

    private func stagePastedText(_ text: String) {
        guard stagingTask == nil else { return }
        let listID = model.selectedListID
        stagingTask = Task {
            var unclaimedURL: URL?
            defer {
                if let unclaimedURL { try? FileManager.default.removeItem(at: unclaimedURL) }
                stagingTask = nil
            }
            do {
                let url = try LargePastedText.write(text, to: storage.stagingDirectory)
                unclaimedURL = url
                try Task.checkCancellation()
                guard model.lists.contains(where: { $0.id == listID }) else { return }
                storage.draftStore.addTemporary(url, to: listID)
                unclaimedURL = nil
                if model.selectedListID == listID {
                    draft = storage.draftStore.draft(for: listID)
                }
            } catch is CancellationError {
                return
            } catch {
                model.presentError(
                    String(localized: "Couldn’t prepare pasted text. Try again."),
                    operation: "composer.paste_stage",
                    diagnosticCode: diagnosticErrorCode(error)
                )
            }
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
            return
        }
        stageMedia(.files(urls))
    }

    private func stageMedia(_ input: AttachmentMediaInput) {
        guard stagingTask == nil else { return }
        let listID = model.selectedListID
        stagingTask = Task {
            var stagedFiles: [StagedAttachment] = []
            defer { stagingTask = nil }
            do {
                stagedFiles = try await AttachmentMediaStager.stage(
                    input, in: storage.stagingDirectory
                )
                try Task.checkCancellation()
                if !model.lists.contains(where: { $0.id == listID }) {
                    AttachmentDraftStager.clean(stagedFiles)
                    return
                }
                addStagedFiles(stagedFiles, to: listID)
            } catch is CancellationError {
                AttachmentDraftStager.clean(stagedFiles)
            } catch {
                model.presentError(error, operation: "attachment.import_stage")
            }
        }
    }

    private func addStagedFiles(_ files: [StagedAttachment], to listID: UUID) {
        for file in files {
            storage.draftStore.addTemporary(file.url, to: listID)
        }
        if model.selectedListID == listID {
            draft = storage.draftStore.draft(for: listID)
        }
    }

    private func removeAttachment(_ url: URL) {
        model.haptics.invalidatePendingFeedback()
        storage.draftStore.remove(url, from: model.selectedListID)
        draft = storage.draftStore.draft(for: model.selectedListID)
    }

}

private struct ComposerAccessibility: ViewModifier {
    let isPreview: Bool
    let identifier: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPreview {
            content.accessibilityHidden(true)
        } else {
            content.accessibilityIdentifier(identifier)
        }
    }
}

private struct ComposerGlassID: ViewModifier {
    let isPreview: Bool
    let id: String
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPreview {
            content
        } else {
            content
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(.materialize)
        }
    }
}

@MainActor
@Observable
final class CompactComposerStorage {
    let draftStore: ComposerDraftStore
    let stagingDirectory: URL
    var isSaving = false
    var savingListID: UUID?

    init() {
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCompactDrafts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let textDefaultsKey: String
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["SNIP_SNAP_UI_TESTING"] == "1",
           let storeName = environment["SNIP_SNAP_UI_TEST_STORE"]
        {
            textDefaultsKey = "snipsnap.ios.composer.text.v1.ui-test.\(storeName)"
        } else {
            textDefaultsKey = "snipsnap.ios.composer.text.v1"
        }
#else
        textDefaultsKey = "snipsnap.ios.composer.text.v1"
#endif
        self.stagingDirectory = stagingDirectory
        draftStore = ComposerDraftStore(
            textDefaultsKey: textDefaultsKey,
            temporaryRootDirectory: stagingDirectory
        )
    }
}


private struct CompactDraftAttachment: View {
    let url: URL
    let preview: () -> Void
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: preview) {
                AttachmentThumbnail(url: url)
                    .frame(width: 62, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(url.lastPathComponent)")
            .accessibilityIdentifier("composer-attachment-\(url.lastPathComponent)")

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 22)
                    .background(.thickMaterial, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 16, y: -16)
            .accessibilityLabel("Remove \(url.lastPathComponent)")
            .accessibilityIdentifier("composer-remove-attachment-\(url.lastPathComponent)")
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
    }
}
