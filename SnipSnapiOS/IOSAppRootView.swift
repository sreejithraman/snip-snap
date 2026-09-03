import SnipSnapCloud
import SnipSnapCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct IOSAppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let session: IOSAppSession
    @State private var sheet: AppSheet?
    @State private var copyShare = IOSCopyShareCoordinator()
    @State private var compactComposerStorage = CompactComposerStorage()
    @State private var collectionEditMode: EditMode = .inactive
    @State private var isImportingBackup = false
    @State private var isExplainingBackupImport = false
    @FocusState private var isCompactComposerFocused: Bool
    private let uiTestAttachmentURLs: [URL]
    private let seedsCopyShareFixtures: Bool
    private let shareProcessToken: String?
    init(
        session: IOSAppSession,
        uiTestAttachmentURLs: [URL] = [],
        seedsCopyShareFixtures: Bool = false,
        shareProcessToken: String? = nil
    ) {
        self.session = session
        self.uiTestAttachmentURLs = uiTestAttachmentURLs
        self.seedsCopyShareFixtures = seedsCopyShareFixtures
        self.shareProcessToken = shareProcessToken
    }

    private var model: IOSAppModel { session.model }

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
            if let accountNoticeModel = session.accountNoticeModel,
               accountNoticeModel.notice != nil
            {
                AppleAccountNoticeBanner(model: accountNoticeModel)
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .editSnip(let id):
                SnipEditorView(model: model, snipID: id)
            case .newList:
                ListEditorView(model: model, mode: .create)
            case .editList(let id):
                ListEditorView(model: model, mode: .edit(id: id))
            case .settings:
                SyncedContentSettingsView(
                    model: session.syncedContentSettings,
                    retryAction: {
                        if session.syncedContentSettings.mode == .localOnly {
                            await session.syncedContentSettings.enableICloudSync()
                        } else {
                            await session.retrySyncWhenPossible()
                        }
                    }
                )
            case .recoveryCenter:
                RecoveryCenterView(model: model)
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
            Text("Choose a backup folder to include attachments. A plain JSON file can contain text and metadata only.")
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.folder, .json],
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
            Text("Review: \(model.pendingImportPreview?.localizedSummary ?? ""). Snip Snap will merge these records with your saved snips.")
        }
        .task {
            await session.launch()
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
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: SnipSnapCloudNotifications.accountChanged
            ) {
                await session.foreground()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await session.foreground()
                }
            case .background, .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private var appNavigation: some View {
        if horizontalSizeClass == .compact {
            NavigationStack {
                SnipCollectionView(
                    model: model,
                    copyShare: copyShare,
                    sheet: $sheet,
                    layout: .compactStack,
                    editMode: $collectionEditMode,
                    dismissComposerKeyboard: {
                        isCompactComposerFocused = false
                    },
                    libraryActions: LibraryActionsMenu(
                        model: model,
                        importBackup: { isExplainingBackupImport = true },
                        settings: { sheet = .settings },
                        editMode: $collectionEditMode,
                        includesCloudActions: true,
                        reviewRecoveredEdits: model.recoverySnapshot.needsAttentionCount > 0
                            ? { sheet = .recoveryCenter }
                            : nil,
                        editSelectedList: model.selectedListID == SnipList.inboxID
                            ? nil : { sheet = .editList(id: model.selectedListID) }
                    )
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
            }
        } else {
            NavigationSplitView {
                ListSidebarView(
                    model: model,
                    sheet: $sheet,
                    editMode: $collectionEditMode,
                    importBackup: { isExplainingBackupImport = true }
                )
            } detail: {
                NavigationStack {
                    SnipCollectionView(
                        model: model,
                        copyShare: copyShare,
                        sheet: $sheet,
                        layout: .inlineList,
                        editMode: $collectionEditMode,
                        dismissComposerKeyboard: {
                            isCompactComposerFocused = false
                        }
                    )
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        CompactLibraryControls(
                            model: model,
                            storage: compactComposerStorage,
                            isComposerFocused: $isCompactComposerFocused,
                            showsListTabs: false,
                            sheet: $sheet
                        )
                    }
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

private struct AppleAccountNoticeBanner: View {
    let model: AppleAccountNoticeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.systemImage)
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
        session: IOSAppSession(
            library: PreviewSnipLibrary.snapshot,
            initialSnapshot: .preview
        )
    )
}

#Preview("Empty iPhone") {
    IOSAppRootView(session: IOSAppSession(library: PreviewSnipLibrary.empty))
}
