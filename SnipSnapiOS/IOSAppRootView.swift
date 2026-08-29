import SnipSnapCore
import SnipSnapPersistence
import SwiftUI
import UIKit

struct IOSAppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appGraph: IOSAppGraph
    @State private var sheet: AppSheet?
    @State private var accountNoticeModel: AppleAccountNoticeModel?
    private let uiTestAttachmentURLs: [URL]

    init(
        library: any SnipLibrary,
        shareImports: ShareImportStore? = nil,
        initialSnapshot: SnipLibrarySnapshot? = nil,
        startupError: String? = nil,
        uiTestAttachmentURLs: [URL] = [],
        shareImportOperation: (@Sendable () async -> Int)? = nil,
        accountNoticeModel: AppleAccountNoticeModel? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil
    ) {
        self.uiTestAttachmentURLs = uiTestAttachmentURLs
        _appGraph = State(initialValue: IOSAppGraph(
            library: library,
            shareImports: shareImports,
            initialSnapshot: initialSnapshot ?? SnipLibrarySnapshot(snips: [], lists: [.inbox]),
            startupError: startupError,
            shareImportOperation: shareImportOperation,
            cloudSyncHandler: cloudSyncHandler
        ))
        _accountNoticeModel = State(initialValue: accountNoticeModel)
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
            await accountNoticeModel?.refresh()
            await model.syncWhenPossible()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    if let shareImporter = appGraph.shareImporter {
                        await shareImporter.importPendingAndReload()
                    }
                    await accountNoticeModel?.refresh()
                    await model.syncWhenPossible()
                }
            case .background:
                let lease = IOSBackgroundSyncLease()
                Task {
                    await model.syncWhenPossible()
                    lease.finish()
                }
            default:
                break
            }
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

#Preview("iPad Library") {
    IOSAppRootView(
        library: PreviewSnipLibrary.snapshot,
        initialSnapshot: .preview
    )
}

#Preview("Empty iPhone") {
    IOSAppRootView(library: PreviewSnipLibrary.empty)
}
