import SnipSnapCore
import SnipSnapPersistence
import SwiftUI

struct IOSAppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appGraph: IOSAppGraph
    @State private var sheet: AppSheet?
    private let uiTestAttachmentURLs: [URL]

    init(
        library: any SnipLibrary,
        shareImports: ShareImportStore? = nil,
        initialSnapshot: SnipLibrarySnapshot? = nil,
        startupError: String? = nil,
        uiTestAttachmentURLs: [URL] = [],
        shareImportOperation: (@Sendable () async -> Int)? = nil
    ) {
        self.uiTestAttachmentURLs = uiTestAttachmentURLs
        _appGraph = State(initialValue: IOSAppGraph(
            library: library,
            shareImports: shareImports,
            initialSnapshot: initialSnapshot ?? SnipLibrarySnapshot(snips: [], lists: [.inbox]),
            startupError: startupError,
            shareImportOperation: shareImportOperation
        ))
    }

    private var model: IOSAppModel { appGraph.model }

    var body: some View {
        NavigationSplitView {
            ListSidebarView(model: model, sheet: $sheet)
        } content: {
            SnipCollectionView(model: model, sheet: $sheet)
        } detail: {
            SnipDetailView(model: model, sheet: $sheet)
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
        .task {
            if let shareImporter = appGraph.shareImporter {
                await shareImporter.importPendingAndReload()
            } else {
                await model.load()
            }
            if !uiTestAttachmentURLs.isEmpty, model.snips.isEmpty {
                _ = await model.createSnip(
                    content: "Attachment fixture",
                    in: SnipList.inboxID,
                    attachmentURLs: uiTestAttachmentURLs
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let shareImporter = appGraph.shareImporter else { return }
            Task { await shareImporter.importPendingAndReload() }
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
