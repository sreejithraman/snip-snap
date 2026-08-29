import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import SwiftUI

struct IOSAppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appGraph: IOSAppGraph
    @State private var sheet: AppSheet?
    private let uiTestAttachmentURLs: [URL]
    private let syncedContentSettings: SyncedContentSettingsModel
    private let cloudSyncSession: SnipSnapCloudSyncSession?

    init(
        library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope? = nil,
        shareImports: ShareImportStore? = nil,
        initialSnapshot: SnipLibrarySnapshot? = nil,
        startupError: String? = nil,
        uiTestAttachmentURLs: [URL] = [],
        syncedContentSettings: SyncedContentSettingsModel? = nil,
        cloudSyncSession: SnipSnapCloudSyncSession? = nil,
        shareImportOperation: (@Sendable () async -> Int)? = nil
    ) {
        self.uiTestAttachmentURLs = uiTestAttachmentURLs
        let settings = syncedContentSettings
            ?? SyncedContentSettingsModel(mode: .localOnly)
        self.syncedContentSettings = settings
        self.cloudSyncSession = cloudSyncSession
        let graph = IOSAppGraph(
            library: library,
            recoveryScope: recoveryScope,
            shareImports: shareImports,
            initialSnapshot: initialSnapshot ?? SnipLibrarySnapshot(snips: [], lists: [.inbox]),
            startupError: startupError,
            shareImportOperation: shareImportOperation
        )
        if let cloudSyncSession {
            settings.setDeleteCompletionAction {
                let active = try await cloudSyncSession.activeLibrary()
                await graph.model.replaceLibrary(
                    active.library,
                    recoveryScope: active.recoveryScope
                )
            }
        }
        _appGraph = State(initialValue: graph)
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
            case .settings:
                SyncedContentSettingsView(model: syncedContentSettings)
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
        .task {
            await synchronizeAndReloadLibrary()
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

    private func synchronizeAndReloadLibrary() async {
        guard let cloudSyncSession else { return }
        do {
            switch try await cloudSyncSession.synchronize() {
            case .noChange:
                break
            case .contentUpdated:
                await model.load()
            case .libraryReplaced:
                await reloadActiveLibrary()
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func reloadActiveLibrary() async {
        guard let cloudSyncSession else { return }
        do {
            let active = try await cloudSyncSession.activeLibrary()
            await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
        } catch {
            model.errorMessage = error.localizedDescription
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
