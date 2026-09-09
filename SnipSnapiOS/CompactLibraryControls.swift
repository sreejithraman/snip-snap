import Observation
import QuickLook
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum CompactControlMetrics {
    static let minimumInteractiveLength: CGFloat = 44
    static let selectorTransitionDuration: TimeInterval = 0.2
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
    let model: IOSAppModel
    let clipboard: IOSClipboardModel
    let storage: CompactComposerStorage
    let showsListTabs: Bool
    let isSelecting: Bool
    @Namespace private var composerGlass
    @Binding var sheet: AppSheet?

    @State private var draft = ComposerDraft()
    @State private var clipboardHasContent = false
    @State private var isBrowsingLists = false
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
        sheet: Binding<AppSheet?>
    ) {
        self.model = model
        self.clipboard = clipboard
        self.storage = storage
        self.showsListTabs = showsListTabs
        self.isSelecting = isSelecting
        _isComposerFocused = isComposerFocused
        _sheet = sheet
    }

    private var isStaging: Bool { stagingTask != nil }

    private var showsComposer: Bool { !model.showsClipboard && !isSelecting }

    private var contentTransition: Animation? {
        reduceMotion ? nil : .easeInOut(duration: CompactControlMetrics.contentTransitionDuration)
    }

    var body: some View {
        VStack(spacing: SnipSnapSpacing.relatedContent) {
            GlassEffectContainer(spacing: SnipSnapSpacing.relatedContent) {
                if showsComposer {
                    composer
                        .transition(reduceMotion ? .opacity : .offset(y: 8).combined(with: .opacity))
                }
            }
            .animation(contentTransition, value: showsComposer)
            if showsListTabs {
                selectorRow
            } else {
                GlassEffectContainer {
                    if model.showsClipboard {
                        pasteButton
                            .transition(.opacity)
                    }
                }
            }
        }
        .animation(contentTransition, value: model.showsClipboard)
        .padding(.horizontal, SnipSnapSpacing.cardContentInset)
        .padding(.top, SnipSnapSpacing.relatedContent)
        .padding(.bottom, 6)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            stage(result)
        }
        .quickLookPreview($previewURL, in: draft.attachments)
        .onAppear {
            updatePasteAvailability()
            if storage.savingListID != model.selectedListID {
                draft = storage.draftStore.draft(for: model.selectedListID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            updatePasteAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            updatePasteAvailability()
        }
        .onChange(of: model.selectedListID) { _, listID in
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

    private var selectorRow: some View {
        GeometryReader { proxy in
            let actionLength = max(48, controlLength)
            let restingWidth = max(64, min(256, proxy.size.width - 2 * (actionLength + SnipSnapSpacing.relatedContent)))
            ZStack {
                ListSelector(
                    model: model,
                    controlLength: controlLength,
                    sheet: $sheet,
                    deleteList: deleteList,
                    labelViewport: restingWidth,
                    browsingChanged: { isBrowsingLists = $0 }
                )
                .frame(width: isBrowsingLists ? proxy.size.width : restingWidth)
                .frame(maxWidth: .infinity)

                GlassEffectContainer {
                    HStack {
                        Spacer()
                        if showsPasteAction {
                            pasteButton
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                }
                .animation(pasteBrowsingTransition, value: isBrowsingLists)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: CompactControlMetrics.selectorTransitionDuration), value: isBrowsingLists)
        }
        .frame(height: max(48, controlLength) + 8)
    }

    private var pasteBrowsingTransition: Animation? {
        guard !reduceMotion else { return nil }
        let collapseDuration = CompactControlMetrics.selectorTransitionDuration
        if isBrowsingLists {
            return .easeInOut(duration: collapseDuration)
        }
        // Finish alongside the input after the strip has made room for Paste.
        return .easeInOut(duration: CompactControlMetrics.contentTransitionDuration - collapseDuration)
            .delay(collapseDuration)
    }

    private var showsPasteAction: Bool { model.showsClipboard && !isBrowsingLists }

    private var pasteButton: some View {
        CompactGlassCircleButton(length: max(48, controlLength)) {
            let providers = UIPasteboard.general.itemProviders
            Task { await clipboard.capture(providers) }
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(.title3.weight(.medium))
        }
        .disabled(!clipboardHasContent)
        .accessibilityLabel("Paste")
        .accessibilityIdentifier("paste-to-clipboard")
        .glassEffectID("paste", in: composerGlass)
        .glassEffectTransition(.materialize)
    }

    private func updatePasteAvailability() {
        let pasteboard = UIPasteboard.general
        clipboardHasContent = pasteboard.hasStrings || pasteboard.hasURLs || pasteboard.hasImages
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: SnipSnapSpacing.relatedContent) {
            CompactGlassCircleButton(
                length: controlLength,
                action: {
                    model.haptics.invalidatePendingFeedback()
                    isImporting = true
                }
            ) {
                Image(systemName: isStaging ? "hourglass" : "plus")
                    .font(.title3.weight(.medium))
            }
            .disabled(storage.isSaving || isStaging)
            .accessibilityLabel("Add Attachments")
            .accessibilityIdentifier("composer-add-attachments")
            .glassEffectID("attachments", in: composerGlass)
            .glassEffectTransition(.materialize)

            GlassEffectContainer {
                VStack(spacing: SnipSnapSpacing.relatedContent) {
                    if !draft.attachments.isEmpty {
                        attachmentStrip
                            .padding(.horizontal, SnipSnapSpacing.cardContentInset)
                            .padding(.top, 10)
                    }

                    HStack(alignment: .bottom, spacing: SnipSnapSpacing.relatedContent) {
                        TextField(
                            "Add to \(model.selectedList.displayName)…",
                            text: composerText,
                            axis: .vertical
                        )
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                            .focused($isComposerFocused)
                            .disabled(storage.isSaving)
                            .padding(SnipSnapSpacing.relatedContent)
                            .frame(minHeight: controlLength, alignment: .center)
                            .accessibilityIdentifier("composer-text")

                        Color.clear
                            .frame(width: controlLength, height: controlLength)
                            .allowsHitTesting(false)
                    }
                    .padding(.leading, SnipSnapSpacing.relatedContent / 2)
                    .padding(.trailing, SnipSnapSpacing.relatedContent)
                    .id(composerFieldID)
                }
                .frame(minHeight: controlLength)
                .glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            isComposerFocused
                                ? SnipSnapTheme.focusedGlassEdge
                                : SnipSnapTheme.emphasizedGlassEdge,
                            lineWidth: isComposerFocused ? 1 : 0.75
                        )
                }
                .glassEffectID("input", in: composerGlass)
                .glassEffectTransition(.materialize)
            }
            // Keep Send outside the input's interactive glass subtree.
            .overlay(alignment: .bottomTrailing) {
                GlassEffectContainer {
                    AppTintedGlassActionButton(
                        isEnabled: canSend,
                        tint: model.selectedList.accent.color,
                        labelColor: model.selectedList.accent.sendIconColor(in: colorScheme),
                        action: { Task { await send() } }
                    ) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: sendIconLength, weight: .semibold))
                            .frame(width: sendIconLength, height: sendIconLength)
                    }
                    .frame(width: controlLength, height: controlLength, alignment: .trailing)
                    .contentShape(Rectangle())
                    .controlSize(.regular)
                    .accessibilityLabel("Send Snip")
                    .accessibilityIdentifier("composer-send")
                    .padding(.trailing, SnipSnapSpacing.relatedContent)
                }
            }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.attachments, id: \.self) { url in
                    CompactDraftAttachment(
                        url: url,
                        preview: {
                            model.haptics.invalidatePendingFeedback()
                            previewURL = url
                        },
                        remove: { removeAttachment(url) }
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var composerText: Binding<String> {
        let fieldID = composerFieldID
        return Binding(
            get: { draft.text },
            set: { value in
                guard fieldID == composerFieldID else { return }
                model.haptics.invalidatePendingFeedback()
                guard storage.savingListID != model.selectedListID else {
                    draft.text = ""
                    return
                }
                if let pasted = LargePastedText.largeInsertion(from: draft.text, to: value) {
                    stagePastedText(pasted)
                    return
                }
                draft.text = value
                storage.draftStore.setText(value, for: model.selectedListID)
            }
        )
    }

    private var canSend: Bool {
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
        guard canSend else { return }
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
