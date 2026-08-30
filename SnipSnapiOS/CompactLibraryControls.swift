import QuickLook
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers

struct CompactLibraryControls: View {
    let model: IOSAppModel
    @Binding var sheet: AppSheet?

    @StateObject private var storage = CompactComposerStorage()
    @State private var draft = ComposerDraft()
    @State private var previewURL: URL?
    @State private var isImporting = false
    @State private var isSaving = false
    @State private var stagingTask: Task<Void, Never>?
    @FocusState private var isComposerFocused: Bool

    init(model: IOSAppModel, sheet: Binding<AppSheet?>) {
        self.model = model
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
            draft = storage.draftStore.draft(for: model.selectedListID)
        }
        .onChange(of: model.selectedListID) { _, listID in
            draft = storage.draftStore.draft(for: listID)
        }
        .onDisappear {
            stagingTask?.cancel()
            storage.draftStore.flushText()
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !draft.attachments.isEmpty {
                attachmentStrip
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: isStaging ? "hourglass" : "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(isSaving || isStaging)
                .accessibilityLabel("Add Attachments")
                .accessibilityIdentifier("composer-add-attachments")

                TextField("New snip", text: composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isComposerFocused)
                    .accessibilityIdentifier("composer-text")

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .frame(width: 36, height: 36)
                        .background(canSend ? Color.accentColor : Color.secondary.opacity(0.16))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send Snip")
                .accessibilityIdentifier("composer-send")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
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
        Binding(
            get: { draft.text },
            set: { value in
                draft.text = value
                storage.draftStore.setText(value, for: model.selectedListID)
            }
        )
    }

    private var canSend: Bool {
        AttachmentDraftLifecycle.allowsSaving(
            isSaving: isSaving,
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
        isSaving = true
        let saved = await model.createSnip(
            content: snapshot.draft.text,
            in: snapshot.listID,
            attachmentURLs: snapshot.draft.attachments,
            selectCreatedSnip: false
        )
        storage.draftStore.finishSave(snapshot, saved: saved)
        if model.selectedListID == snapshot.listID {
            draft = storage.draftStore.draft(for: snapshot.listID)
        }
        isSaving = false
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
private final class CompactComposerStorage: ObservableObject {
    let draftStore: ComposerDraftStore
    let stagingDirectory: URL

    init() {
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCompactDrafts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.stagingDirectory = stagingDirectory
        draftStore = ComposerDraftStore(
            textDefaultsKey: "snipsnap.ios.composer.text.v1",
            temporaryRootDirectory: stagingDirectory
        )
    }
}

private struct CompactListTabBar: View {
    let model: IOSAppModel
    @Binding var sheet: AppSheet?
    let deleteList: (UUID) async -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(model.lists) { list in
                            tab(for: list)
                                .id(list.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .scrollIndicators(.hidden)
                .onAppear { scrollToSelection(using: proxy) }
                .onChange(of: model.selectedListID) { _, _ in
                    scrollToSelection(using: proxy)
                }
                .onChange(of: model.lists) { _, _ in
                    scrollToSelection(using: proxy)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .glassEffect(.regular, in: Capsule())

            Button {
                sheet = .newList
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("New List")
            .accessibilityIdentifier("new-list")
        }
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
                .frame(width: 46, height: 46)
                .background(
                    selected ? Color.primary.opacity(0.1) : Color.clear,
                    in: Circle()
                )
                .contentShape(Circle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(list.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("list-tab-\(list.id.uuidString)")
        .contextMenu {
            if list.id != SnipList.inboxID {
                Button("Rename") { sheet = .editList(id: list.id) }
                Button("Delete", role: .destructive) {
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
            .accessibilityLabel("Preview \(url.lastPathComponent)")
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
            .accessibilityLabel("Remove \(url.lastPathComponent)")
            .accessibilityIdentifier("composer-remove-attachment-\(url.lastPathComponent)")
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
    }
}
