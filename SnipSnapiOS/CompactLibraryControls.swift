import Observation
import QuickLook
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers

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

struct CompactLibraryControls: View {
    let model: IOSAppModel
    let storage: CompactComposerStorage
    let showsListTabs: Bool
    @Binding var sheet: AppSheet?

    @State private var draft = ComposerDraft()
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
        storage: CompactComposerStorage,
        isComposerFocused: FocusState<Bool>.Binding,
        showsListTabs: Bool = true,
        sheet: Binding<AppSheet?>
    ) {
        self.model = model
        self.storage = storage
        self.showsListTabs = showsListTabs
        _isComposerFocused = isComposerFocused
        _sheet = sheet
    }

    private var isStaging: Bool { stagingTask != nil }

    var body: some View {
        GlassEffectContainer(spacing: SnipSnapSpacing.relatedContent) {
            VStack(spacing: SnipSnapSpacing.relatedContent) {
                composer
                if showsListTabs {
                    CompactListTabBar(
                        model: model,
                        controlLength: controlLength,
                        sheet: $sheet,
                        deleteList: deleteList
                    )
                }
            }
        }
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
            if storage.savingListID != model.selectedListID {
                draft = storage.draftStore.draft(for: model.selectedListID)
            }
        }
        .onChange(of: model.selectedListID) { _, listID in
            draft = storage.savingListID == listID
                ? ComposerDraft()
                : storage.draftStore.draft(for: listID)
        }
        .onDisappear {
            stagingTask?.cancel()
            storage.draftStore.flushText()
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: SnipSnapSpacing.relatedContent) {
            CompactGlassCircleButton(
                length: controlLength,
                action: { isImporting = true }
            ) {
                Image(systemName: isStaging ? "hourglass" : "plus")
                    .font(.title3.weight(.medium))
            }
            .disabled(storage.isSaving || isStaging)
            .accessibilityLabel("Add Attachments")
            .accessibilityIdentifier("composer-add-attachments")

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

                    AppTintedGlassActionButton(
                        isEnabled: canSend,
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
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.attachments, id: \.self) { url in
                    CompactDraftAttachment(
                        url: url,
                        preview: { previewURL = url },
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

private struct CompactListTabBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let model: IOSAppModel
    let controlLength: CGFloat
    @Binding var sheet: AppSheet?
    let deleteList: (UUID) async -> Void

    private var stripHeight: CGFloat {
        controlLength + SnipSnapSpacing.cardContentInset
    }

    private var selectionHeight: CGFloat {
        controlLength - SnipSnapSpacing.relatedContent
    }

    private var itemWidth: CGFloat {
        controlLength + SnipSnapSpacing.relatedContent
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SnipSnapSpacing.relatedContent) {
                tabStrip
                    .fixedSize(horizontal: true, vertical: false)
                newListButton
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: SnipSnapSpacing.relatedContent) {
                scrollingTabStrip
                    .frame(maxWidth: .infinity, alignment: .leading)
                newListButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabStrip: some View {
        tabItems
            .padding(.horizontal, 6)
            .frame(height: stripHeight)
            .glassEffect(.regular, in: Capsule())
    }

    private var scrollingTabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                tabItems
                    .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)
            .frame(height: stripHeight)
            .glassEffect(.regular, in: Capsule())
            .onAppear { scrollToSelection(using: proxy) }
            .onChange(of: model.selectedListID) { _, _ in
                scrollToSelection(using: proxy)
            }
            .onChange(of: model.lists) { _, _ in
                scrollToSelection(using: proxy)
            }
        }
    }

    private var tabItems: some View {
        HStack(spacing: 0) {
            ForEach(model.lists) { list in
                tab(for: list)
                    .id(list.id)
            }
        }
    }

    private var newListButton: some View {
        CompactGlassCircleButton(
            length: controlLength,
            action: { sheet = .newList }
        ) {
            Image(systemName: "plus")
                .font(.title3.weight(.semibold))
        }
        .accessibilityLabel("New List")
        .accessibilityIdentifier("new-list")
    }

    private func tab(for list: SnipList) -> some View {
        let selected = model.selectedListID == list.id
        return Button {
            model.selectList(list.id)
        } label: {
            Image(systemName: list.systemImage)
                .symbolVariant(selected ? .fill : .none)
                .font(.title3.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(
                    width: controlLength,
                    height: selectionHeight
                )
                .background(
                    selected ? SnipSnapTheme.compactSelectionFill : Color.clear,
                    in: Capsule(style: .continuous)
                )
                .frame(
                    width: itemWidth,
                    height: stripHeight
                )
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(list.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("list-tab-\(list.id.uuidString)")
        .contextMenu {
            if list.id != SnipList.inboxID {
                Button("Edit List") { sheet = .editList(id: list.id) }
                Button("Delete", role: .destructive) {
                    Task { await deleteList(list.id) }
                }
            }
        }
    }

    private func scrollToSelection(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            if reduceMotion {
                proxy.scrollTo(model.selectedListID, anchor: .center)
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(model.selectedListID, anchor: .center)
                }
            }
        }
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
