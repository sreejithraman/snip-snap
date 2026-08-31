import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum IOSBackupImportPickerPolicy {
    static let allowedContentTypes: [UTType] = [.folder, .json]
    static let message = String(localized: "Choose a backup folder to include attachments. A plain JSON file can contain text and metadata only.")
}

@MainActor
final class IOSAppGraph {
    let model: IOSAppModel
    let shareImporter: IOSShareImportCoordinator?

    init(
        library: any SnipLibrary,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsRebinder: SnipLibraryUserActionsRebinder = .direct,
        recoveryScope: SnipRecoveryScope? = nil,
        shareImports: ShareImportStore?,
        initialSnapshot: SnipLibrarySnapshot,
        startupError: String?,
        shareImportOperation: (@Sendable () async -> Int)? = nil,
        syncOperation: (@MainActor @Sendable () async throws -> Void)? = nil,
        syncOperationFactory: (@MainActor @Sendable (
            IOSAppModel
        ) -> @MainActor @Sendable () async throws -> Void)? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil
    ) {
        let model = IOSAppModel(
            library: library,
            userActions: userActions,
            userActionsRebinder: userActionsRebinder,
            recoveryScope: recoveryScope,
            initialSnapshot: initialSnapshot,
            startupError: startupError,
            cloudSyncHandler: cloudSyncHandler
        )
        self.model = model
        let noSync: @MainActor @Sendable () async throws -> Void = {}
        let resolvedSyncOperation = syncOperation
            ?? syncOperationFactory?(model)
            ?? noSync
        if let shareImportOperation {
            shareImporter = IOSShareImportCoordinator(
                model: model,
                importOperation: shareImportOperation,
                syncOperation: resolvedSyncOperation
            )
        } else if let shareImports {
            shareImporter = IOSShareImportCoordinator(
                library: library,
                imports: shareImports,
                model: model,
                syncOperation: resolvedSyncOperation
            )
        } else {
            shareImporter = nil
        }
    }
}

@MainActor
final class IOSShareImportCoordinator {
    private struct PassResult: Sendable {
        let importFailures: Int
        let syncFailed: Bool
    }

    private let model: IOSAppModel
    private let importOperation: @Sendable () async -> Int
    private let syncOperation: @MainActor @Sendable () async throws -> Void
    private var inFlight: Task<PassResult, Never>?
    private var needsTrailingPass = false

    convenience init(
        library: any SnipLibrary,
        imports: ShareImportStore,
        model: IOSAppModel,
        syncOperation: @escaping @MainActor @Sendable () async throws -> Void = {}
    ) {
        self.init(
            model: model,
            importOperation: {
                await imports.importPending(into: library).failed
            },
            syncOperation: syncOperation
        )
    }

    init(
        model: IOSAppModel,
        importOperation: @escaping @Sendable () async -> Int,
        syncOperation: @escaping @MainActor @Sendable () async throws -> Void = {}
    ) {
        self.model = model
        self.importOperation = importOperation
        self.syncOperation = syncOperation
    }

    func importPendingAndReload() async {
        if let inFlight {
            needsTrailingPass = true
            _ = await inFlight.value
            return
        }
        let task = Task { [self] in
            var importFailures = 0
            var syncFailed = false
            repeat {
                needsTrailingPass = false
                let result = await runPass()
                importFailures += result.importFailures
                syncFailed = syncFailed || result.syncFailed
            } while needsTrailingPass
            // Clear this before completing the task. A later trigger will either mark the
            // current pass dirty or become the sole owner of a new pass.
            inFlight = nil
            return PassResult(importFailures: importFailures, syncFailed: syncFailed)
        }
        inFlight = task
        let result = await task.value
        report(result)
    }

    private func runPass() async -> PassResult {
        let failed = await importOperation()
        await model.load()
        // A prior launch can commit the request ledger, then stop before sync. Always ask
        // the one active sync driver to compare the local rows with its accepted shadow,
        // even when this pass finds only a duplicate request or no pending directory.
        do {
            try await syncOperation()
            return PassResult(importFailures: failed, syncFailed: false)
        } catch {
            return PassResult(importFailures: failed, syncFailed: true)
        }
    }

    private func report(_ result: PassResult) {
        if result.importFailures > 0 {
            model.errorMessage = String(
                localized: "One or more shared items could not be added yet. Snip Snap will try again next time."
            )
        } else if result.syncFailed {
            model.errorMessage = String(
                localized: "The shared item is saved on this device. iCloud sync will try again later."
            )
        }
    }
}

struct IOSAppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appGraph: IOSAppGraph
    @State private var sheet: AppSheet?
    @State private var accountNoticeModel: AppleAccountNoticeModel?
    @State private var copyShare = IOSCopyShareCoordinator()
    @State private var compactComposerStorage = CompactComposerStorage()
    @State private var isImportingBackup = false
    @State private var isExplainingBackupImport = false
    @FocusState private var isCompactComposerFocused: Bool
    private let uiTestAttachmentURLs: [URL]
    private let seedsCopyShareFixtures: Bool
    private let shareProcessToken: String?
    private let syncedContentSettings: SyncedContentSettingsModel
    private let cloudLifecycleHooks: SnipSnapCloudLifecycleHooks

    init(
        library: any SnipLibrary,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsRebinder: SnipLibraryUserActionsRebinder = .direct,
        recoveryScope: SnipRecoveryScope? = nil,
        shareImports: ShareImportStore? = nil,
        initialSnapshot: SnipLibrarySnapshot? = nil,
        startupError: String? = nil,
        uiTestAttachmentURLs: [URL] = [],
        seedsCopyShareFixtures: Bool = false,
        shareProcessToken: String? = nil,
        syncedContentSettings: SyncedContentSettingsModel? = nil,
        cloudSyncSession: SnipSnapCloudSyncSession? = nil,
        shareImportOperation: (@Sendable () async -> Int)? = nil,
        accountNoticeModel: AppleAccountNoticeModel? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil
    ) {
        self.uiTestAttachmentURLs = uiTestAttachmentURLs
        self.seedsCopyShareFixtures = seedsCopyShareFixtures
        self.shareProcessToken = shareProcessToken
        let settings = syncedContentSettings
            ?? SyncedContentSettingsModel(mode: .localOnly)
        self.syncedContentSettings = settings
        let activeShareImportOperation = shareImportOperation ?? shareImports.map { imports in
            { @Sendable in
                if let cloudSyncSession {
                    guard let active = try? await cloudSyncSession.activeLibrary() else {
                        return 1
                    }
                    return await imports.importPending(into: active.library).failed
                }
                return await imports.importPending(into: library).failed
            }
        }
        let graph = IOSAppGraph(
            library: library,
            userActions: userActions,
            userActionsRebinder: userActionsRebinder,
            recoveryScope: recoveryScope,
            shareImports: shareImports,
            initialSnapshot: initialSnapshot ?? SnipLibrarySnapshot(snips: [], lists: [.inbox]),
            startupError: startupError,
            shareImportOperation: activeShareImportOperation,
            syncOperationFactory: { model in
                {
                    try await synchronizeCloudSessionOrThrow(
                        cloudSyncSession,
                        model: model,
                        settings: settings
                    )
                }
            },
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
            settings.setDisableCompletionAction(reloadActiveLibrary)
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
        accountNoticeModel?.setActiveLibraryChangeAction {
            guard let cloudSyncSession else { return }
            let active = try await cloudSyncSession.activeLibrary()
            await graph.model.replaceLibrary(
                active.library,
                recoveryScope: active.recoveryScope
            )
        }
        _appGraph = State(initialValue: graph)
        _accountNoticeModel = State(initialValue: accountNoticeModel)
    }

    private var model: IOSAppModel { appGraph.model }

    var body: some View {
        appNavigation
        .tint(SnipSnapTheme.controlTint)
        .background {
            IOSShareSheetPresenter(request: $copyShare.shareRequest)
                .frame(width: 0, height: 0)
        }
#if DEBUG
        .overlay(alignment: .topLeading) {
            if let shareProcessToken {
                Text(
                    String(model.snips.filter { $0.content.contains(shareProcessToken) }.count)
                )
                .font(.caption2)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("share-process-count")
            }
        }
#endif
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
            Text(model.errorMessage ?? String(localized: "Please try again."))
        }
        .alert(
            "Some Files Are Unavailable",
            isPresented: Binding(
                get: { copyShare.unavailableFilesNotice != nil },
                set: { if !$0 { copyShare.cancelUnavailableFilesNotice() } }
            )
        ) {
            Button("Copy Text Only") { copyShare.copyTextFromNotice(model: model) }
            Button("Cancel", role: .cancel) { copyShare.cancelUnavailableFilesNotice() }
        } message: {
            Text(copyShare.unavailableFilesNotice?.message
                ?? String(localized: "One or more files could not be read."))
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
            Text(copyShare.errorMessage ?? String(localized: "Please try again."))
        }
        .confirmationDialog(
            "Choose a backup",
            isPresented: $isExplainingBackupImport,
            titleVisibility: .visible
        ) {
            Button("Choose Backup") { isImportingBackup = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(IOSBackupImportPickerPolicy.message)
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: IOSBackupImportPickerPolicy.allowedContentTypes,
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

    @ViewBuilder
    private var appNavigation: some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            NavigationStack {
                SnipCollectionView(
                    model: model,
                    copyShare: copyShare,
                    sheet: $sheet,
                    layout: .compactStack,
                    dismissComposerKeyboard: {
                        isCompactComposerFocused = false
                    }
                )
                .libraryToast(model: model)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    CompactLibraryControls(
                        model: model,
                        storage: compactComposerStorage,
                        isComposerFocused: $isCompactComposerFocused,
                        sheet: $sheet
                    )
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") {
                            sheet = .settings
                        }
                        .accessibilityIdentifier("settings")
                        LibraryActionsMenu(
                            model: model,
                            importBackup: { isExplainingBackupImport = true },
                            includesCloudActions: true,
                            reviewRecoveredEdits: model.needsAttentionCount > 0
                                ? { sheet = .recoveryCenter }
                                : nil,
                            editSelectedList: model.selectedListID == SnipList.inboxID
                                ? nil : { sheet = .editList(id: model.selectedListID) }
                        )
                    }
                }
            }
        } else {
            NavigationSplitView {
                ListSidebarView(
                    model: model,
                    sheet: $sheet,
                    importBackup: { isExplainingBackupImport = true }
                )
            } detail: {
                NavigationStack {
                    SnipCollectionView(
                        model: model,
                        copyShare: copyShare,
                        sheet: $sheet,
                        layout: .inlineList
                    )
                }
            }
            .libraryToast(model: model)
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
    do {
        try await synchronizeCloudSessionOrThrow(
            session,
            model: model,
            settings: settings
        )
    } catch {
        model.errorMessage = error.localizedDescription
    }
}

@MainActor
private func synchronizeCloudSessionOrThrow(
    _ session: SnipSnapCloudSyncSession?,
    model: IOSAppModel,
    settings: SyncedContentSettingsModel
) async throws {
    guard let session else { return }
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

private extension View {
    func libraryToast(model: IOSAppModel) -> some View {
        appToast(
            Binding(
                get: { model.toast },
                set: { model.toast = $0 }
            ),
            alignment: .bottom,
            edge: .bottom,
            onAction: model.performToastAction,
            onDismiss: model.dismissToast
        )
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
