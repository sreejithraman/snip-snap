import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import SwiftUI
import UIKit

struct IOSAppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appGraph: IOSAppGraph
    @State private var sheet: AppSheet?
    @State private var accountNoticeModel: AppleAccountNoticeModel?
    @State private var copyShare = IOSCopyShareCoordinator()
    private let uiTestAttachmentURLs: [URL]
    private let seedsCopyShareFixtures: Bool
    private let syncedContentSettings: SyncedContentSettingsModel
    private let cloudLifecycleHooks: SnipSnapCloudLifecycleHooks

    init(
        library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope? = nil,
        shareImports: ShareImportStore? = nil,
        initialSnapshot: SnipLibrarySnapshot? = nil,
        startupError: String? = nil,
        uiTestAttachmentURLs: [URL] = [],
        seedsCopyShareFixtures: Bool = false,
        syncedContentSettings: SyncedContentSettingsModel? = nil,
        cloudSyncSession: SnipSnapCloudSyncSession? = nil,
        shareImportOperation: (@Sendable () async -> Int)? = nil,
        accountNoticeModel: AppleAccountNoticeModel? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil
    ) {
        self.uiTestAttachmentURLs = uiTestAttachmentURLs
        self.seedsCopyShareFixtures = seedsCopyShareFixtures
        let settings = syncedContentSettings
            ?? SyncedContentSettingsModel(mode: .localOnly)
        self.syncedContentSettings = settings
        let graph = IOSAppGraph(
            library: library,
            recoveryScope: recoveryScope,
            shareImports: shareImports,
            initialSnapshot: initialSnapshot ?? SnipLibrarySnapshot(snips: [], lists: [.inbox]),
            startupError: startupError,
            shareImportOperation: shareImportOperation,
            cloudSyncHandler: cloudSyncHandler
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
            settings.setEncryptedDataResetCompletionAction(reloadActiveLibrary)
        }
        cloudLifecycleHooks = SnipSnapCloudLifecycleHooks {
            await synchronizeCloudSession(
                cloudSyncSession,
                model: graph.model,
                settings: settings
            )
        }
        _appGraph = State(initialValue: graph)
        _accountNoticeModel = State(initialValue: accountNoticeModel)
    }

    private var model: IOSAppModel { appGraph.model }

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
        .safeAreaInset(edge: .top, spacing: 0) {
            if let accountNoticeModel, accountNoticeModel.notice != nil {
                AppleAccountNoticeBanner(model: accountNoticeModel)
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
            await cloudLifecycleHooks.launch()
            if let shareImporter = appGraph.shareImporter {
                await shareImporter.importPendingAndReload()
            } else {
                await model.load()
            }
            if seedsCopyShareFixtures, model.snips.isEmpty {
                await seedCopyShareFixtures()
            } else if !uiTestAttachmentURLs.isEmpty, model.snips.isEmpty {
                _ = await model.createSnip(
                    content: "Attachment fixture",
                    in: SnipList.inboxID,
                    attachmentURLs: uiTestAttachmentURLs
                )
            }
            await accountNoticeModel?.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await cloudLifecycleHooks.foreground()
                    if let shareImporter = appGraph.shareImporter {
                        await shareImporter.importPendingAndReload()
                    }
                    await accountNoticeModel?.refresh()
                }
            case .background:
                let lease = IOSBackgroundSyncLease()
                Task {
                    await cloudLifecycleHooks.foreground()
                    lease.finish()
                }
            default:
                break
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
                .oldSyncedContentRemovalCompleted, .encryptedDataResetRequiresChoice,
                .syncKeptOff:
            let active = try await session.activeLibrary()
            await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
            if case .oldSyncedContentRemovalPending = result {
                settings.recordRemovalPending(true)
            } else if case .oldSyncedContentRemovalCompleted = result {
                settings.recordRemovalPending(false)
            } else if case .encryptedDataResetRequiresChoice = result {
                settings.recordEncryptedDataReset()
            }
        }
    } catch {
        model.errorMessage = error.localizedDescription
    }
}

@MainActor
private final class IOSBackgroundSyncLease {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.finish()
        }
    }

    func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

private struct AppleAccountNoticeBanner: View {
    let model: AppleAccountNoticeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title)
                        .font(.headline)
                        .accessibilityIdentifier("apple-account-notice")
                    Text(model.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if model.showsResolutionActions {
                HStack(spacing: 12) {
                    Button("Keep Local Copy") {
                        Task { await model.resolve(.keepLocalCopy) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("keep-account-cache")
                    Button("Remove", role: .destructive) {
                        Task { await model.resolve(.remove) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("remove-account-cache")
                }
                .disabled(model.isResolving)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var iconName: String {
        model.notice == .paused ? "icloud.slash" : "person.crop.circle.badge.exclamationmark"
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
