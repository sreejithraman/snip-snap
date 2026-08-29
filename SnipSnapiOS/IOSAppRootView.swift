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
    private let cloudLifecycleHooks: SnipSnapCloudLifecycleHooks

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
        let graph = IOSAppGraph(
            library: library,
            recoveryScope: recoveryScope,
            shareImports: shareImports,
            initialSnapshot: initialSnapshot ?? SnipLibrarySnapshot(snips: [], lists: [.inbox]),
            startupError: startupError,
            shareImportOperation: shareImportOperation
        )
        if let cloudSyncSession {
            let reloadActiveLibrary: SyncedContentSettingsModel.DeleteCompletionAction = {
                let active = try await cloudSyncSession.activeLibrary()
                await graph.model.replaceLibrary(
                    active.library,
                    recoveryScope: active.recoveryScope
                )
            }
            settings.setEnableCompletionAction(reloadActiveLibrary)
            settings.setDeleteCompletionAction(reloadActiveLibrary)
        }
        cloudLifecycleHooks = SnipSnapCloudLifecycleHooks {
            await synchronizeCloudSession(
                cloudSyncSession,
                model: graph.model,
                settings: settings
            )
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
            await cloudLifecycleHooks.launch()
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
            guard phase == .active else { return }
            Task {
                await cloudLifecycleHooks.foreground()
                await appGraph.shareImporter?.importPendingAndReload()
            }
        }
    }

}

@MainActor
private func synchronizeCloudSession(
    _ session: SnipSnapCloudSyncSession?,
    model: IOSAppModel,
    settings: SyncedContentSettingsModel
) async {
    guard let session else { return }
    do {
        let result = try await session.synchronize()
        switch result {
        case .noChange:
            break
        case .contentUpdated:
            await model.load()
        case .libraryReplaced, .oldSyncedContentRemovalPending,
                .oldSyncedContentRemovalCompleted:
            let active = try await session.activeLibrary()
            await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
            if case .oldSyncedContentRemovalPending = result {
                settings.recordRemovalPending(true)
            } else if case .oldSyncedContentRemovalCompleted = result {
                settings.recordRemovalPending(false)
            }
        }
    } catch {
        model.errorMessage = error.localizedDescription
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
