import Observation
import QuickLook
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers

struct CompactLibraryControls: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: IOSAppModel
    let storage: CompactComposerStorage
    @Binding var sheet: AppSheet?

    @State private var draft = ComposerDraft()
    @State private var previewURL: URL?
    @State private var isImporting = false
    @State private var composerFieldID = UUID()
    @State private var stagingTask: Task<Void, Never>?
    @FocusState.Binding private var isComposerFocused: Bool

    init(
        model: IOSAppModel,
        storage: CompactComposerStorage,
        isComposerFocused: FocusState<Bool>.Binding,
        sheet: Binding<AppSheet?>
    ) {
        self.model = model
        self.storage = storage
        _isComposerFocused = isComposerFocused
        _sheet = sheet
    }

    private var isStaging: Bool { stagingTask != nil }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                composer
                if !isComposerFocused {
                    CompactListTabBar(
                        model: model,
                        sheet: $sheet,
                        deleteList: deleteList
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.18), value: isComposerFocused)
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
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                isImporting = true
            } label: {
                Image(systemName: isStaging ? "hourglass" : "plus")
                    .font(.title3.weight(.medium))
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .overlay {
                        Circle().strokeBorder(
                            SnipSnapTheme.glassEdge,
                            lineWidth: 0.5
                        )
                    }
            }
            .buttonStyle(.plain)
            .disabled(storage.isSaving || isStaging)
            .accessibilityLabel(.addAttachments)
            .accessibilityIdentifier("composer-add-attachments")

            VStack(spacing: 8) {
                if !draft.attachments.isEmpty {
                    attachmentStrip
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                }

                HStack(alignment: .bottom, spacing: 8) {
                    TextField(.fieldNewSnipPlaceholder, text: composerText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isComposerFocused)
                        .disabled(storage.isSaving)
                        .padding(.leading, 16)
                        .padding(.vertical, 15)
                        .accessibilityIdentifier("composer-text")

                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .foregroundStyle(
                                canSend
                                    ? SnipSnapTheme.primaryActionLabel(for: colorScheme)
                                    : SnipSnapTheme.disabledPrimaryActionLabel(for: colorScheme)
                            )
                            .frame(width: 46, height: 36)
                            .background {
                                Capsule(style: .continuous).fill(
                                    canSend
                                        ? SnipSnapTheme.primaryActionTint(for: colorScheme)
                                        : SnipSnapTheme.disabledPrimaryActionTint(for: colorScheme)
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                    .accessibilityLabel(.sendSnip)
                    .accessibilityIdentifier("composer-send")
                }
                .id(composerFieldID)
            }
            .frame(minHeight: 52)
            .glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
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
    let model: IOSAppModel
    @Binding var sheet: AppSheet?
    let deleteList: (UUID) async -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tabStrip
                    .fixedSize(horizontal: true, vertical: false)
                newListButton
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 8) {
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
            .frame(height: 56)
            .glassEffect(.regular, in: Capsule())
    }

    private var scrollingTabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                tabItems
                    .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)
            .frame(height: 56)
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
        Button {
            sheet = .newList
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(.screenNewListTitle)
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
                .frame(width: 44, height: 36)
                .background(
                    selected ? SnipSnapTheme.compactSelectionFill : Color.clear,
                    in: Capsule(style: .continuous)
                )
                .frame(width: 52, height: 56)
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
                Button(.rename) { sheet = .editList(id: list.id) }
                Button(.delete, role: .destructive) {
                    Task { await deleteList(list.id) }
                }
            }
        }
    }

    private func scrollToSelection(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(model.selectedListID, anchor: .center)
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
            .accessibilityLabel(.preview(url.lastPathComponent))
            .accessibilityIdentifier("composer-attachment-\(url.lastPathComponent)")

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 22)
                    .background(.thickMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .accessibilityLabel(.remove(url.lastPathComponent))
            .accessibilityIdentifier("composer-remove-attachment-\(url.lastPathComponent)")
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
    }
}
