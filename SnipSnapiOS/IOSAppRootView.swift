import SnipSnapCore
import SwiftUI

struct IOSAppRootView: View {
    @State private var model: IOSAppModel
    @State private var sheet: AppSheet?
    @State private var copyShare = IOSCopyShareCoordinator()
    private let uiTestAttachmentURLs: [URL]
    private let seedsCopyShareFixtures: Bool

    init(
        library: any SnipLibrary,
        initialSnapshot: SnipLibrarySnapshot? = nil,
        startupError: String? = nil,
        uiTestAttachmentURLs: [URL] = [],
        seedsCopyShareFixtures: Bool = false
    ) {
        self.uiTestAttachmentURLs = uiTestAttachmentURLs
        self.seedsCopyShareFixtures = seedsCopyShareFixtures
        _model = State(
            initialValue: IOSAppModel(
                library: library,
                initialSnapshot: initialSnapshot ?? SnipLibrarySnapshot(snips: [], lists: [.inbox]),
                startupError: startupError
            )
        )
    }

    var body: some View {
        NavigationSplitView {
            ListSidebarView(model: model, sheet: $sheet)
        } content: {
            SnipCollectionView(model: model, copyShare: copyShare, sheet: $sheet)
        } detail: {
            SnipDetailView(model: model, copyShare: copyShare, sheet: $sheet)
        }
        .background {
            IOSShareSheetPresenter(request: $copyShare.shareRequest)
                .frame(width: 0, height: 0)
        }
        .overlay(alignment: .bottom) {
            if let status = copyShare.statusMessage {
                Text(status)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("copy-status")
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .newSnip(let listID):
                SnipEditorView(model: model, mode: .create(listID: listID))
            case .editSnip(let id):
                SnipEditorView(model: model, mode: .edit(id: id))
            case .newList:
                ListEditorView(model: model, mode: .create)
            case .editList(let id):
                ListEditorView(model: model, mode: .edit(id: id))
            }
        }
        .alert(
            "Snip Snap Needs Attention",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Please try again.")
        }
        .alert(
            "Some Files Are Unavailable",
            isPresented: Binding(
                get: { copyShare.unavailableFilesNotice != nil },
                set: { if !$0 { copyShare.cancelUnavailableFilesNotice() } }
            )
        ) {
            Button("Copy Text Only") { copyShare.copyTextFromNotice() }
            Button("Cancel", role: .cancel) { copyShare.cancelUnavailableFilesNotice() }
        } message: {
            Text(copyShare.unavailableFilesNotice?.message ?? "One or more files could not be read.")
        }
        .alert(
            "Copy Failed",
            isPresented: Binding(
                get: { copyShare.errorMessage != nil },
                set: { if !$0 { copyShare.errorMessage = nil } }
            )
        ) {
            Button("OK") { copyShare.errorMessage = nil }
        } message: {
            Text(copyShare.errorMessage ?? "Please try again.")
        }
        .task {
            await model.load()
            if seedsCopyShareFixtures, model.snips.isEmpty {
                await seedCopyShareFixtures()
            } else if !uiTestAttachmentURLs.isEmpty, model.snips.isEmpty {
                _ = await model.createSnip(
                    content: "Attachment fixture",
                    in: SnipList.inboxID,
                    attachmentURLs: uiTestAttachmentURLs
                )
            }
        }
    }

    private func seedCopyShareFixtures() async {
        _ = await model.createSnip(
            content: "Copy text fixture",
            in: SnipList.inboxID
        )
        if let textURL = uiTestAttachmentURLs.first(where: { $0.pathExtension == "txt" }) {
            _ = await model.createSnip(
                content: "",
                in: SnipList.inboxID,
                attachmentURLs: [textURL]
            )
        }
        if let imageURL = uiTestAttachmentURLs.first(where: { $0.pathExtension == "png" }) {
            _ = await model.createSnip(
                content: "Copy mixed fixture",
                in: SnipList.inboxID,
                attachmentURLs: [imageURL]
            )
            _ = await model.createSnip(
                content: "Copy unavailable fixture",
                in: SnipList.inboxID,
                attachmentURLs: [imageURL]
            )
            if let attachmentID = model.selectedSnip?.attachments.first?.id,
                let storedURL = model.attachmentURL(for: attachmentID)
            {
                try? FileManager.default.removeItem(at: storedURL)
            }
        }
    }
}

#Preview("iPad Library") {
    IOSAppRootView(
        library: PreviewSnipLibrary.snapshot,
        initialSnapshot: .preview
    )
}

#Preview("Empty iPhone") {
    IOSAppRootView(library: PreviewSnipLibrary.empty)
}
