import Observation
import QuickLook
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum CompactControlMetrics {
    static let minimumInteractiveLength: CGFloat = 44
    static let contentTransitionDuration: TimeInterval = 0.35
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
    @Namespace private var composerGlass
    @Binding var sheet: AppSheet?

    @State private var draft = ComposerDraft()
    @State private var draftListID: UUID?
    @State private var toolbarWidth: CGFloat = 320
    @State private var composerHeights: [LibraryPage: CGFloat] = [:]
    @State private var previewURL: URL?
    @State private var isImporting = false
    @State private var composerFieldID = UUID()
    @State private var stagingTask: Task<Void, Never>?
    @FocusState.Binding private var isComposerFocused: Bool
    @ScaledMetric(relativeTo: .body) private var scaledControlLength =
        CompactControlMetrics.minimumInteractiveLength
    @ScaledMetric(relativeTo: .body) private var sendIconLength: CGFloat = 16

    private var controlLength: CGFloat {
        max(CompactControlMetrics.minimumInteractiveLength, scaledControlLength)
    }

    init(
        model: IOSAppModel,
        clipboard: IOSClipboardModel,
        storage: CompactComposerStorage,
        isComposerFocused: FocusState<Bool>.Binding,
        showsListTabs: Bool = true,
        isSelecting: Bool = false,
        sheet: Binding<AppSheet?>,
        motion: Binding<ListPageMotion> = .constant(ListPageMotion()),
        pageFrame: ListPageFrame? = nil,
        pageWidth: CGFloat = 0
    ) {
        self.model = model
        self.clipboard = clipboard
        self.storage = storage
        self.showsListTabs = showsListTabs
        self.isSelecting = isSelecting
        _motion = motion
        self.pageFrame = pageFrame
        self.pageWidth = pageWidth
        _isComposerFocused = isComposerFocused
        _sheet = sheet
    }

    private var isStaging: Bool { stagingTask != nil }

    private var showsComposer: Bool { !model.isSearchPresented && !model.showsClipboard && !isSelecting }

    private var showsListEditor: Bool {
        !model.showsClipboard && !model.isSearchPresented
            && model.editingListID == model.selectedListID
    }

    var body: some View {
        VStack(spacing: SnipSnapSpacing.relatedContent) {
            GlassEffectContainer(spacing: SnipSnapSpacing.relatedContent) {
                composerPages
            }

            if !showsListTabs {
                GlassEffectContainer {
                    if model.showsClipboard {
                        pasteButton
                            .transition(.opacity)
                    }
                }
            } else if !model.isSearchPresented {
                navigationControls
                    .modifier(ListEditorRecession(isActive: showsListEditor))
            }
        }

        .frame(maxWidth: .infinity)
        .padding(.horizontal, SnipSnapSpacing.cardContentInset)
        .padding(.top, SnipSnapSpacing.relatedContent)
        .padding(.bottom, 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            stage(result)
        }
        .quickLookPreview($previewURL, in: draft.attachments)
        .onAppear {
            draftListID = model.selectedListID
            if storage.savingListID != model.selectedListID {
                draft = storage.draftStore.draft(for: model.selectedListID)
            }
        }
        .onChange(of: model.selectedListID) { _, listID in
            composerFieldID = UUID()
            draftListID = listID
            draft = storage.savingListID == listID
                ? ComposerDraft()
                : storage.draftStore.draft(for: listID)
        }
        .onChange(of: showsComposer) { _, visible in
            if !visible { isComposerFocused = false }
        }
        .onDisappear {
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
        // Reserve the same space on both sides, including when Paste is absent.
        max(120, min(256, toolbarWidth - 168))
    }

    private var contentTransition: Animation? {
        reduceMotion ? nil : .easeInOut(duration: CompactControlMetrics.contentTransitionDuration)
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
                sheet: $sheet,
                deleteList: deleteList,
                labelViewport: listToolbarWidth,
                motion: $motion,
                pageFrame: frame
            )
            .frame(width: selectorWidth, height: length + 8)

            HStack {
                pasteButton
                    .opacity(model.showsClipboard ? 1 : 0)
                    .animation(model.showsClipboard ? contentTransition : nil, value: model.showsClipboard)
                    .offset(x: -travel)
                    .allowsHitTesting(model.showsClipboard && !motion.isDragging)
                    .accessibilityHidden(!model.showsClipboard || motion.isDragging)

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
            let providers = UIPasteboard.general.itemProviders
            Task { await clipboard.capture(providers) }
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(showsListTabs ? .system(size: navigationControlLength * 20 / 48, weight: .medium) : .title3.weight(.medium))
        }
        .disabled(clipboard.isPasting || !model.showsClipboard || motion.isDragging)
        .accessibilityLabel("Paste")
        .accessibilityIdentifier("paste-to-clipboard")
        .glassEffectID("paste", in: composerGlass)
        .glassEffectTransition(.materialize)
    }

    private var currentPage: LibraryPage {
        model.showsClipboard ? .clipboard : .list(model.selectedListID)
    }

    private var frame: ListPageFrame {
        pageFrame ?? ListPageFrame(
            pages: [currentPage], position: 0, retainedPages: [currentPage], isMoving: false
        )
    }

    private var visibleComposerPages: [LibraryPage] {
        guard !model.isSearchPresented, !isSelecting else { return [] }
        return frame.retainedPages.filter { if case .list = $0 { true } else { false } }
    }

    private var composerHeight: CGFloat {
        guard !model.isSearchPresented, !isSelecting else { return 0 }
        // Interpolate the occupied height as Clipboard (which has no composer)
        // enters, keeping the last frame identical to the resting layout.
        return frame.pages.enumerated().reduce(0) { result, element in
            let (index, page) = element
            guard case .list = page else { return result }
            let weight = max(0, 1 - abs(CGFloat(index) - frame.position))
            return result + weight * (composerHeights[page] ?? controlLength)
        }
    }

    private var composerPages: some View {
        ZStack(alignment: .bottom) {
            ForEach(visibleComposerPages, id: \.self) { page in
                if case .list(let id) = page,
                   let list = model.lists.first(where: { $0.id == id }) {
                    let isPreview = page != currentPage
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
            CompactGlassCircleButton(
                length: controlLength,
                action: {
                    guard !isPreview else { return }
                    model.haptics.invalidatePendingFeedback()
                    isImporting = true
                }
            ) {
                Image(systemName: isPreview ? "plus" : (isStaging ? "hourglass" : "plus"))
                    .font(.title3.weight(.medium))
            }
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
                        TextField(
                            "Add to \(list.displayName)…",
                            text: isPreview ? .constant(draft.text) : composerText(for: list.id),
                            axis: .vertical
                        )
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                            .modifier(ComposerFieldFocus(isPreview: isPreview, isFocused: $isComposerFocused))
                            .disabled(storage.isSaving)
                            .padding(SnipSnapSpacing.relatedContent)
                            .frame(minHeight: controlLength, alignment: .center)
                            .modifier(ComposerAccessibility(isPreview: isPreview, identifier: "composer-text"))

                        Color.clear
                            .frame(width: controlLength, height: controlLength)
                            .allowsHitTesting(false)
                    }
                    .padding(.leading, SnipSnapSpacing.relatedContent / 2)
                    .padding(.trailing, SnipSnapSpacing.relatedContent)
                    .id(isPreview ? "preview-\(list.id.uuidString)" : composerFieldID.uuidString)
                }
                .frame(minHeight: controlLength)
                .glassEffect(
                    .regular.interactive(),
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
            // Keep Send outside the input's interactive glass subtree.
            .overlay(alignment: .bottomTrailing) {
                GlassEffectContainer {
                    AppTintedGlassActionButton(
                        isEnabled: canSend(draft: draft),
                        tint: list.accent.color,
                        labelColor: list.accent.sendIconColor(in: colorScheme),
                        action: { if !isPreview { Task { await send() } } }
                    ) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: sendIconLength, weight: .semibold))
                            .frame(width: sendIconLength, height: sendIconLength)
                    }
                    .frame(width: controlLength, height: controlLength, alignment: .trailing)
                    .contentShape(Rectangle())
                    .controlSize(.regular)
                    .accessibilityLabel("Send Snip")
                    .modifier(ComposerAccessibility(isPreview: isPreview, identifier: "composer-send"))
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
            isPreviewing: previewURL != nil
        )
            && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draft.attachments.isEmpty)
    }

    private func send() async {
        guard canSend(draft: draft(for: model.selectedListID)) else { return }
        let snapshot = storage.draftStore.beginSave(listID: model.selectedListID)
        storage.savingListID = snapshot.listID
        storage.isSaving = true
        composerFieldID = UUID()
        draft = ComposerDraft()
        let saved = await model.createSnip(
            content: snapshot.draft.text,
            in: snapshot.listID,
            attachmentURLs: snapshot.draft.attachments,
            selectCreatedSnip: false
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

    private func stagePastedText(_ text: String) {
        guard stagingTask == nil else { return }
        let listID = model.selectedListID
        stagingTask = Task {
            defer { stagingTask = nil }
            do {
                let url = try LargePastedText.write(text, to: storage.stagingDirectory)
                try Task.checkCancellation()
                storage.draftStore.addTemporary(url, to: listID)
                if model.selectedListID == listID {
                    draft = storage.draftStore.draft(for: listID)
                }
            } catch is CancellationError {
                return
            } catch {
                model.errorMessage = String(
                    localized: "Snip Snap could not prepare the pasted text."
                )
            }
        }
    }

    private func stage(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result,
                (error as NSError).code != NSUserCancelledError
            {
                model.errorMessage = error.localizedDescription
            }
            return
        }
        guard stagingTask == nil else { return }
        let listID = model.selectedListID
        stagingTask = Task {
            var stagedFiles: [StagedAttachment] = []
            defer { stagingTask = nil }
            do {
                stagedFiles = try await AttachmentDraftStager.stage(
                    urls,
                    in: storage.stagingDirectory
                )
                try Task.checkCancellation()
                for file in stagedFiles {
                    storage.draftStore.addTemporary(file.url, to: listID)
                }
                if model.selectedListID == listID {
                    draft = storage.draftStore.draft(for: listID)
                }
            } catch is CancellationError {
                AttachmentDraftStager.clean(stagedFiles)
                return
            } catch {
                model.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func removeAttachment(_ url: URL) {
        model.haptics.invalidatePendingFeedback()
        storage.draftStore.remove(url, from: model.selectedListID)
        draft = storage.draftStore.draft(for: model.selectedListID)
    }

    private func deleteList(_ listID: UUID) async {
        if await model.deleteList(id: listID) {
            storage.draftStore.clear(listID: listID)
        }
    }
}

private struct ComposerFieldFocus: ViewModifier {
    let isPreview: Bool
    @FocusState.Binding var isFocused: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPreview {
            content
        } else {
            content.focused($isFocused)
        }
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
