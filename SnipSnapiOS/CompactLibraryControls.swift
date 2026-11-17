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

/// The draft the mounted composer shows, and the list it belongs to.
private struct ShownDraft {
    var listID: UUID?
    var draft = ComposerDraft()
}

struct CompactLibraryControls: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.prefersSideButtons) private var prefersSideButtons
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
    @State private var shownDraft = ShownDraft()
    @State private var toolbarWidth: CGFloat = 320
    @State private var composerHeights: [LibraryPage: CGFloat] = [:]
    @State private var composerFieldID = UUID()
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

    private var previewURL: URL? { storage.attachmentPreview?.url }

    /// The keyboard yields to a presented picker or preview, and focus returns when it closes. Layout
    /// keeps following `isComposerFocused`, so nothing under the presentation changes or flickers.
    /// A resign caused by the presentation must not clear the user's focus.
    private var composerKeyboardFocus: Binding<Bool> {
        Binding(
            get: { isComposerFocused && !storage.isPresentingAttachment },
            set: { focused in
                guard !storage.isPresentingAttachment else { return }
                isComposerFocused = focused
            }
        )
    }
    private var isClipboardSelected: Bool { model.selectedPage == .clipboard }

    private var showsComposerPages: Bool {
        !model.isSearchPresented && !isSelecting && !showsListEditor
    }

    private var showsComposer: Bool { showsComposerPages && !isClipboardSelected }

    private var showsListEditor: Bool {
        !isClipboardSelected && !model.isSearchPresented
            && model.editingListID == model.lastSelectedListID
    }

    private var showsNavigation: Bool {
        !model.isSearchPresented && !showsListEditor && !isComposerFocused
    }

    var body: some View {
        VStack(spacing: SnipSnapSpacing.relatedContent) {
            if showsComposer {
                IOSInlineFailureView(model: model, operations: ["snip.add", "snip.paste_save", "list.create", "composer.", "attachment.import_"])
            }
            if showsComposerPages {
                GlassEffectContainer(spacing: SnipSnapSpacing.relatedContent) {
                    composerPages
                }
            }

            if showsListTabs && showsNavigation {
                navigationControls
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SnipSnapSpacing.cardContentInset)
        .padding(.top, showsListEditor ? 0 : SnipSnapSpacing.relatedContent)
        .padding(.bottom, showsListEditor ? 0 : 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }
        .toolbar {
            if prefersSideButtons {
                // Declaring Search right after Paste puts the two in one capsule, Paste on top,
                // apart from the library actions.
                ToolbarSpacer(.flexible, placement: .topBarTrailing)
                    .sideButton()
                if !model.isSearchPresented {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(pasteLabel, systemImage: "doc.on.clipboard", action: paste)
                            .disabled(isToolbarPasteDisabled)
                            .accessibilityIdentifier("paste-to-clipboard")
                    }
                    .sideButton()
                }
                DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                    .sideButton()
            } else if !showsListTabs && !model.isSearchPresented {
                // Paste draws its own glass circle because the system folds the Search item into
                // the shared background of the item before it. Placing Search explicitly instead
                // turns it into a full search field on iPad.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    CompactGlassCircleButton(length: Self.toolbarCircleLength, action: paste) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 18))
                            .imageScale(.medium)
                    }
                    .disabled(isToolbarPasteDisabled)
                    .accessibilityLabel(pasteLabel)
                    .accessibilityShowsLargeContentViewer {
                        Label(pasteLabel, systemImage: "doc.on.clipboard")
                    }
                    .accessibilityIdentifier("paste-to-clipboard")
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
        }
        .onAppear {
            shownDraft.listID = model.lastSelectedListID
            if storage.savingListID != model.lastSelectedListID {
                shownDraft.draft = storage.draftStore.draft(for: model.lastSelectedListID)
            }
        }
        .onChange(of: model.lastSelectedListID) { _, listID in
            sendDestination = nil
            replaceComposerField()
            shownDraft = ShownDraft(
                listID: listID,
                draft: storage.savingListID == listID ? ComposerDraft() : storage.draftStore.draft(for: listID)
            )
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
        .onChange(of: storage.draftRevision) { _, _ in
            let listID = model.lastSelectedListID
            guard shownDraft.listID == listID, storage.savingListID != listID else { return }
            shownDraft.draft = storage.draftStore.draft(for: listID)
        }
        .onDisappear {
            sendDestination = nil
            storage.draftStore.flushText()
        }
    }

    // Matches the system's glass circles in the navigation bar.
    private static let toolbarCircleLength: CGFloat = 44

    // Paste and Save disables the composer while it saves, which would end
    // editing mid-sentence. Compact hides Paste while typing instead.
    private var isToolbarPasteDisabled: Bool { isPasteDisabled || isComposerFocused }

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
                    .allowsHitTesting(!frame.isMoving)
                    .accessibilityHidden(frame.isMoving)

                Spacer(minLength: 0)

                CompactGlassCircleButton(length: length) {
                    model.isSearchPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: length * 22 / 48, weight: .medium))
                }
                .accessibilityLabel("Search")
                .offset(x: travel)
                .allowsHitTesting(!frame.isMoving)
                .accessibilityHidden(frame.isMoving)
            }
            .opacity(1 - progress)
        }
        .frame(width: navigationWidth, height: length + 8)
        .animation(motion.isDragging || reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12), value: motion.dragDistance)
    }

    private var pasteButton: some View {
        CompactGlassCircleButton(length: navigationControlLength, action: paste) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: navigationControlLength * 20 / 48, weight: .medium))
        }
        .disabled(isPasteDisabled)
        .accessibilityLabel(pasteLabel)
        .accessibilityIdentifier("paste-to-clipboard")
        .glassEffectID("paste", in: composerGlass)
        .glassEffectTransition(.materialize)
    }

    private var pasteLabel: String { isClipboardSelected ? "Paste" : "Paste and Save" }

    private var isPasteDisabled: Bool {
        isClipboardSelected
            ? clipboard.isPasting
            : !showsComposer || storage.isSaving || storage.isStaging
    }

    private func paste() {
        guard !frame.isMoving else { return }
        if isClipboardSelected {
            let providers = UIPasteboard.general.itemProviders
            Task { await clipboard.capture(providers) }
        } else {
            pasteAndSave()
        }
    }

    private func pasteAndSave() {
        guard showsComposer, !storage.isSaving, !storage.isStaging else { return }
        model.haptics.invalidatePendingFeedback()
        let listID = model.lastSelectedListID
        storage.pasteAndSave {
            var stagedFiles: [StagedAttachment] = []
            defer { AttachmentDraftStager.clean(stagedFiles) }
            do {
                let pasted = try await ComposerPasteboard.stageForSaving(from: .general, in: storage.stagingDirectory)
                stagedFiles = pasted.files
                await model.createSnip(
                    content: pasted.text,
                    in: listID,
                    attachmentURLs: stagedFiles.map(\.url),
                    selectCreatedSnip: false
                )
            } catch {
                presentPasteFailure(error)
            }
        }
    }

    private func presentPasteFailure(_ error: any Error) {
        if let failure = error as? ComposerPasteFailure {
            model.presentError(failure.message, operation: "snip.paste_read", diagnosticCode: failure.diagnosticCode)
        } else {
            model.presentError(error, operation: "snip.paste_save")
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
    }

    private func composer(for list: SnipList, draft: ComposerDraft, isPreview: Bool) -> some View {
        HStack(alignment: .bottom, spacing: SnipSnapSpacing.relatedContent) {
            AttachmentSourceMenu(choose: { source in
                guard !isPreview else { return }
                model.haptics.invalidatePendingFeedback()
                storage.presentAttachmentPicker(ComposerAttachmentPickerRequest(
                    source: source, listID: model.lastSelectedListID
                ))
            }) {
                Image(systemName: isPreview ? "plus" : (storage.isStaging ? "hourglass" : "plus"))
                    .appFont(.title3, weight: .medium)
                    .frame(width: controlLength, height: controlLength)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .disabled(storage.isSaving || storage.isStaging)
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
                            isFocused: isPreview ? .constant(false) : composerKeyboardFocus,
                            isEnabled: !isPreview && !storage.isSaving,
                            isPasteEnabled: !storage.isStaging,
                            isTextInputEnabled: !storage.isStagingPaste,
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
                    // Keep the native field alive when a preview becomes the active page.
                    .id(composerFieldID.uuidString)
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
                            storage.presentAttachmentPreview(ComposerAttachmentPreviewRequest(
                                url: url, listID: model.lastSelectedListID
                            ))
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
        if shownDraft.listID == listID { return shownDraft.draft }
        return storage.savingListID == listID ? ComposerDraft() : storage.draftStore.draft(for: listID)
    }

    private func composerText(for listID: UUID) -> Binding<String> {
        let fieldID = composerFieldID
        return Binding(
            get: { draft(for: listID).text },
            set: { value in
                guard fieldID == composerFieldID, listID == model.lastSelectedListID,
                      shownDraft.listID == listID else { return }
                model.haptics.invalidatePendingFeedback()
                guard storage.savingListID != listID else {
                    shownDraft.draft.text = ""
                    return
                }
                if let pasted = LargePastedText.largeInsertion(from: shownDraft.draft.text, to: value) {
                    stagePastedText(pasted)
                    return
                }
                shownDraft.draft.text = value
                storage.draftStore.setText(value, for: listID)
            }
        )
    }

    /// A new field identity ends editing in the old field; keep the keyboard decision explicit.
    private func replaceComposerField() {
        composerFieldID = UUID()
        isComposerFocused = false
    }

    private func canSend(draft: ComposerDraft) -> Bool {
        AttachmentDraftLifecycle.allowsSaving(
            isSaving: storage.isSaving,
            isStaging: storage.isStaging,
            isImporting: storage.attachmentPicker?.source == .files,
            isPickingMedia: storage.attachmentPicker.map { $0.source != .files } ?? false,
            isPreviewing: previewURL != nil
        )
            && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draft.attachments.isEmpty)
    }

    private func send(
        from sourceID: UUID, to destinationID: UUID, expectedLibraryRevision: UUID
    ) async {
        guard expectedLibraryRevision == model.libraryRevision,
              !frame.isMoving, sourceID == model.lastSelectedListID,
              model.lists.contains(where: { $0.id == destinationID }),
              canSend(draft: draft(for: sourceID)) else { return }
        replaceComposerField()
        shownDraft.draft = ComposerDraft()
        let saved = await storage.save(listID: sourceID) { saving in
            await model.createSnip(
                content: saving.text,
                in: destinationID,
                attachmentURLs: saving.attachments,
                selectCreatedSnip: false,
                expectedLibraryRevision: expectedLibraryRevision, expectedSourceListID: sourceID
            )
        }
        if !saved {
            replaceComposerField()
        }
    }

    private func stagePastedAttachments(_ providers: [NSItemProvider], at selection: NSRange, to listID: UUID) {
        guard !storage.isStaging, !storage.isSaving else { return }
        let body = storage.draftStore.draft(for: listID).text
        let scope = storage.draftStore.scope
        storage.stage(blocksTyping: true) {
            do {
                let pasted = try await ComposerPasteboard.stage(providers, in: storage.stagingDirectory)
                guard storage.draftStore.scope == scope,
                      model.lists.contains(where: { $0.id == listID }) else {
                    AttachmentDraftStager.clean(pasted.files)
                    return
                }
                storage.draftStore.setText(pasted.inserting(into: body, at: selection), for: listID)
                storage.addStagedAttachments(pasted.files.map(\.url), to: listID)
            } catch {
                model.presentError(error, operation: "composer.paste_stage")
            }
        }
    }

    private func stagePastedText(_ text: String) {
        guard !storage.isStaging else { return }
        let listID = model.lastSelectedListID
        storage.stage {
            var unclaimedURL: URL?
            defer { if let unclaimedURL { try? FileManager.default.removeItem(at: unclaimedURL) } }
            do {
                let url = try LargePastedText.write(text, to: storage.stagingDirectory)
                unclaimedURL = url
                guard model.lists.contains(where: { $0.id == listID }) else { return }
                storage.addStagedAttachments([url], to: listID)
                unclaimedURL = nil
            } catch {
                model.presentError(
                    String(localized: "Couldn’t prepare pasted text. Try again."),
                    operation: "composer.paste_stage",
                    diagnosticCode: diagnosticErrorCode(error)
                )
            }
        }
    }

    private func removeAttachment(_ url: URL) {
        model.haptics.invalidatePendingFeedback()
        storage.draftStore.remove(url, from: model.lastSelectedListID)
        shownDraft.draft = storage.draftStore.draft(for: model.lastSelectedListID)
    }

}

private struct ComposerAccessibility: ViewModifier {
    let isPreview: Bool
    let identifier: String

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(isPreview ? "" : identifier)
            .accessibilityHidden(isPreview)
    }
}

private struct ComposerGlassID: ViewModifier {
    let isPreview: Bool
    let id: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        content
            .glassEffectID(isPreview ? nil : id, in: namespace)
            .glassEffectTransition(.materialize)
    }
}

@MainActor
@Observable
final class CompactComposerStorage {
    /// A draft save and Paste and Save each hold the composer busy; only one runs at a time.
    private enum Save: Equatable {
        case idle
        case draft(listID: UUID, session: UUID)
        case pasteboard(session: UUID)
    }

    private enum Staging {
        case idle
        case active(session: UUID, task: Task<Void, Never>, blocksTyping: Bool)
    }

    /// The picker and preview share one modal slot.
    private enum AttachmentPresentation: Equatable {
        case idle
        case picker(ComposerAttachmentPickerRequest)
        case preview(ComposerAttachmentPreviewRequest)
    }

    let draftStore: ComposerDraftStore
    let stagingDirectory: URL
    private var saving = Save.idle
    /// Staging outlives a composer that a size-class change replaces, such as opening an iPhone Duo.
    private var staging = Staging.idle
    /// The root presents the picker and preview, so a fold that replaces the composer leaves Files,
    /// Photos, or a preview open.
    private var attachmentPresentation = AttachmentPresentation.idle
    /// Changes when storage changes a draft outside the mounted composer, so the composer reloads it.
    private(set) var draftRevision = 0

    var isSaving: Bool { saving != .idle }

    var savingListID: UUID? {
        if case .draft(let listID, _) = saving { listID } else { nil }
    }

    var stagingTask: Task<Void, Never>? {
        if case .active(_, let task, _) = staging { task } else { nil }
    }

    var isStaging: Bool { stagingTask != nil }

    /// Pasted attachments rewrite the draft's text when they finish, so typing waits for them.
    var isStagingPaste: Bool {
        if case .active(_, _, let blocksTyping) = staging { blocksTyping } else { false }
    }

    var attachmentPicker: ComposerAttachmentPickerRequest? {
        if case .picker(let request) = attachmentPresentation { request } else { nil }
    }

    var attachmentPreview: ComposerAttachmentPreviewRequest? {
        if case .preview(let request) = attachmentPresentation { request } else { nil }
    }

    var isPresentingAttachment: Bool { attachmentPresentation != .idle }

    init(defaults: UserDefaults = .standard) {
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
            defaults: defaults,
            textDefaultsKey: textDefaultsKey,
            temporaryRootDirectory: stagingDirectory
        )
    }

    func addStagedAttachments(_ urls: [URL], to listID: UUID) {
        for url in urls {
            draftStore.addTemporary(url, to: listID)
        }
        draftRevision += 1
    }

    /// Runs `work` unless another staging is running.
    func stage(blocksTyping: Bool = false, _ work: @escaping @MainActor () async -> Void) {
        guard case .idle = staging else { return }
        let session = UUID()
        // The task runs on the main actor, so it starts only after `staging` is set.
        let task = Task { [self] in
            await work()
            finishStaging(session)
        }
        staging = .active(session: session, task: task, blocksTyping: blocksTyping)
    }

    /// Stages into the list that opened the picker, which may no longer be the selected one.
    func stagePickedMedia(
        _ result: Result<AttachmentMediaInput, any Error>, to listID: UUID, model: IOSAppModel
    ) {
        dismissAttachmentPicker()
        let input: AttachmentMediaInput
        switch result {
        case .success(let picked):
            input = picked
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                model.presentError(error, operation: "attachment.import_select")
            }
            return
        }
        stage { [self] in
            do {
                let stagedFiles = try await AttachmentMediaStager.stage(input, in: stagingDirectory)
                guard model.lists.contains(where: { $0.id == listID }) else {
                    AttachmentDraftStager.clean(stagedFiles)
                    return
                }
                addStagedAttachments(stagedFiles.map(\.url), to: listID)
            } catch {
                model.presentError(error, operation: "attachment.import_stage")
            }
        }
    }

    /// Saves the list's draft through `create`, which returns whether it saved. Returns `false` without
    /// calling `create` while another save runs.
    func save(listID: UUID, create: @MainActor (ComposerDraft) async -> Bool) async -> Bool {
        guard saving == .idle else { return false }
        let admitted = Save.draft(listID: listID, session: UUID())
        let snapshot = draftStore.beginSave(listID: listID)
        saving = admitted
        let saved = await create(snapshot.draft)
        draftStore.finishSave(snapshot, saved: saved)
        if saved {
            draftStore.flushText()
        }
        finishSaving(admitted)
        return saved
    }

    /// Holds the composer busy from the tap while `work` reads the pasteboard and saves it.
    func pasteAndSave(_ work: @escaping @MainActor () async -> Void) {
        guard saving == .idle else { return }
        let admitted = Save.pasteboard(session: UUID())
        saving = admitted
        Task { [self] in
            await work()
            if saving == admitted { saving = .idle }
        }
    }

    func presentAttachmentPicker(_ request: ComposerAttachmentPickerRequest) {
        attachmentPresentation = .picker(request)
    }

    /// With a `source`, closes the picker only if it shows that source, as a presenter's own dismissal does.
    func dismissAttachmentPicker(_ source: AttachmentSource? = nil) {
        guard let picker = attachmentPicker, source == nil || picker.source == source else { return }
        attachmentPresentation = .idle
    }

    func presentAttachmentPreview(_ request: ComposerAttachmentPreviewRequest) {
        attachmentPresentation = .preview(request)
    }

    func pageAttachmentPreview(to url: URL) {
        guard let preview = attachmentPreview else { return }
        attachmentPresentation = .preview(ComposerAttachmentPreviewRequest(url: url, listID: preview.listID))
    }

    func dismissAttachmentPreview() {
        guard attachmentPreview != nil else { return }
        attachmentPresentation = .idle
    }

    /// The root calls this when it swaps its compact and regular trees. The camera can't redraw for the
    /// new size, and on a closed iPhone Duo it can't be cancelled, so it closes. An unconfirmed photo is
    /// discarded; the draft stays.
    func layoutDidSwap() {
        if attachmentPicker?.source == .camera { attachmentPresentation = .idle }
    }

    private func finishStaging(_ session: UUID) {
        guard case .active(let current, _, _) = staging, current == session else { return }
        staging = .idle
    }

    /// A composer mounted mid-save, as when an iPhone Duo folds, skipped loading the draft; the revision reloads it.
    private func finishSaving(_ admitted: Save) {
        guard saving == admitted else { return }
        saving = .idle
        draftRevision += 1
    }
}

struct ComposerAttachmentPickerRequest: Equatable {
    let source: AttachmentSource
    let listID: UUID
}

struct ComposerAttachmentPreviewRequest: Equatable {
    let url: URL
    let listID: UUID
}

/// Applied beside the root's compact and regular trees, so a fold doesn't dismiss Files, Photos, or a preview.
/// It sits in a sibling background, so the inline editor's own pickers aren't nested under it.
struct ComposerAttachmentPresentations: ViewModifier {
    let model: IOSAppModel
    let storage: CompactComposerStorage
    @State private var selectedPhotos: [PhotosPickerItem] = []
    /// A picker can deliver its result after its dismissal clears the request.
    @State private var listID: UUID?

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: isPresenting(.files),
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                stage(result.map(AttachmentMediaInput.files))
            }
            .photosPicker(
                isPresented: isPresenting(.photos),
                selection: $selectedPhotos,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                selectedPhotos = []
                stage(.success(.photos(items)))
            }
            .fullScreenCover(isPresented: isPresenting(.camera)) {
                AttachmentCameraPicker { image in
                    if let image {
                        stage(.success(.camera(image)))
                    } else {
                        stage(.failure(CocoaError(.userCancelled)))
                    }
                }
            }
            .onChange(of: storage.attachmentPicker, initial: true) { _, request in
                if let request { listID = request.listID }
            }
            .attachmentPreview(previewURL, in: previewAttachments)
    }

    /// Quick Look can page to another of the list's attachments, so keep the list when the URL changes.
    private var previewURL: Binding<URL?> {
        Binding(
            get: { storage.attachmentPreview?.url },
            set: { url in
                if let url { storage.pageAttachmentPreview(to: url) } else { storage.dismissAttachmentPreview() }
            }
        )
    }

    private var previewAttachments: [URL] {
        storage.attachmentPreview.map { storage.draftStore.draft(for: $0.listID).attachments } ?? []
    }

    private func isPresenting(_ source: AttachmentSource) -> Binding<Bool> {
        Binding(
            get: { storage.attachmentPicker?.source == source },
            set: { presented in
                if !presented { storage.dismissAttachmentPicker(source) }
            }
        )
    }

    private func stage(_ result: Result<AttachmentMediaInput, any Error>) {
        guard let listID else {
            storage.dismissAttachmentPicker()
            return
        }
        storage.stagePickedMedia(result, to: listID, model: model)
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
                    .appFont(.caption2, weight: .bold)
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
