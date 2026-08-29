import SnipSnapCore
import SnipSnapPersistence
import SwiftUI
import UniformTypeIdentifiers

struct IOSAppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appGraph: IOSAppGraph
    @State private var sheet: AppSheet?
    @State private var isImportingBackup = false
    private let uiTestAttachmentURLs: [URL]

    init(
        library: any SnipLibrary,
        userActions: (any SnipLibraryUserActions)? = nil,
        recoveryScope: SnipRecoveryScope? = nil,
        shareImports: ShareImportStore? = nil,
        initialSnapshot: SnipLibrarySnapshot? = nil,
        startupError: String? = nil,
        uiTestAttachmentURLs: [URL] = [],
        shareImportOperation: (@Sendable () async -> Int)? = nil
    ) {
        self.uiTestAttachmentURLs = uiTestAttachmentURLs
        _appGraph = State(initialValue: IOSAppGraph(
            library: library,
            userActions: userActions,
            recoveryScope: recoveryScope,
            shareImports: shareImports,
            initialSnapshot: initialSnapshot ?? SnipLibrarySnapshot(snips: [], lists: [.inbox]),
            startupError: startupError,
            shareImportOperation: shareImportOperation
        ))
    }

    private var model: IOSAppModel { appGraph.model }

    var body: some View {
        NavigationSplitView {
            ListSidebarView(
                model: model,
                sheet: $sheet,
                importBackup: { isImportingBackup = true }
            )
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
            case .recoveryCenter:
                RecoveryCenterView(model: model, sheet: $sheet)
            case .recoverSnip(let id):
                RecoveredSnipReviewView(model: model, recoveryID: id)
            case .recoverList(let id):
                RecoveredListReviewView(model: model, recoveryID: id)
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
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await model.previewBackupImport(from: url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    model.errorMessage = error.localizedDescription
                }
            }
        }
        .confirmationDialog(
            "Import this backup?",
            isPresented: Binding(
                get: { model.pendingImportPreview != nil },
                set: { if !$0 { model.cancelBackupImport() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Import Backup") { Task { await model.confirmBackupImport() } }
            Button("Cancel", role: .cancel) { model.cancelBackupImport() }
        } message: {
            Text("Review: \(model.importPreviewSummary). Snip Snap will merge these records with your saved snips.")
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
