import SnipSnapCloud
import SnipSnapCore
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct IOSAppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let session: IOSAppSession
    @AppStorage("snip-sort-mode") private var savedSortMode = SnipSortMode.chronological.rawValue
    @State private var sheet: AppSheet?
    @State private var settingsBackupLifetime = IOSSettingsBackupLifetime()
    @State private var newMoveListName = ""
    @State private var copyShare = IOSCopyShareCoordinator()
    @State private var compactComposerStorage = CompactComposerStorage()
    @State private var listPageMotion = ListPageMotion()
    @State private var edgeCreationTask: Task<Void, Never>?
    @State private var edgeCreationTaskID: UUID?
    @State private var clipboardViewState = ClipboardViewState()
    @State private var isCompactComposerFocused = false
    private let uiTestAttachmentURLs: [URL]
    private let seedsCopyShareFixtures: Bool
    private let shareProcessToken: String?
    init(
        session: IOSAppSession,
        uiTestAttachmentURLs: [URL] = [],
        seedsCopyShareFixtures: Bool = false,
        shareProcessToken: String? = nil
    ) {
#if DEBUG
        if let store = ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_STORE"] {
            _savedSortMode = AppStorage(wrappedValue: SnipSortMode.chronological.rawValue, "snip-sort-mode-\(store)")
        }
#endif
        self.session = session
        self.uiTestAttachmentURLs = uiTestAttachmentURLs
        self.seedsCopyShareFixtures = seedsCopyShareFixtures
        self.shareProcessToken = shareProcessToken
    }

    private var model: IOSAppModel { session.model }

    private var collectionEditMode: EditMode {
        get { model.isSelectingSnips ? .active : .inactive }
        nonmutating set {
            if newValue.isEditing { model.isSelectingSnips = true }
            else if model.isSelectingSnips { model.endSelectingSnips() }
        }
    }

    private var collectionEditModeBinding: Binding<EditMode> {
        Binding(get: { collectionEditMode }, set: { collectionEditMode = $0 })
    }

    private var searchNavigation: some View {
        appNavigation
        .onChange(of: model.isSearchPresented) { _, presented in
            if presented {
                isCompactComposerFocused = false
            } else {
                model.searchText = ""
            }
        }
        .onChange(of: model.snipEditorDraft?.original.id) { _, id in
            if id != nil { collectionEditMode = .inactive }
        }
        .onChange(of: model.selectedPage) {
            model.isSearchPresented = false
            model.searchText = ""
            if model.selectedPage == .clipboard { collectionEditMode = .inactive }
        }
    }

    var body: some View {
        searchNavigation
        .tint(SnipSnapTheme.controlTint)
        .modifier(IOSHapticFeedbackModifier(feedback: model.haptics))
        .onChange(of: sheet) { _, destination in
            model.haptics.invalidatePendingFeedback()
            if destination == .settings {
                settingsBackupLifetime = IOSSettingsBackupLifetime()
                settingsBackupLifetime.begin()
            }
        }
        .onChange(of: model.selectedPage) { model.haptics.invalidatePendingFeedback() }
        .background {
            IOSShareSheetPresenter(request: $copyShare.shareRequest)
                .frame(width: 0, height: 0)
        }
#if DEBUG
        .overlayPreferenceValue(DevelopmentMenuBoundsKey.self) { anchor in
            if let anchor,
               let bundleID = Bundle.main.bundleIdentifier,
               let suffix = bundleID.components(separatedBy: ".dev").last,
               bundleID.contains(".dev"), let slot = Int(suffix) {
                GeometryReader { geometry in
                    let bounds = geometry[anchor]
                    Text(verbatim: "DEV \(slot)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.yellow, in: Capsule())
                        .foregroundStyle(.black)
                        .fixedSize()
                        .position(x: bounds.maxX - 4, y: bounds.minY)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_HAPTICS"] == "1" {
                Text(verbatim: model.haptics.event.map {
                    "\($0.kind):\($0.id)"
                } ?? "none")
                    .font(.caption2)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("haptic-event")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if UIDevice.current.userInterfaceIdiom != .phone,
               let bundleID = Bundle.main.bundleIdentifier,
               let suffix = bundleID.components(separatedBy: ".dev").last,
               bundleID.contains(".dev"), let slot = Int(suffix) {
                Text(verbatim: "DEV \(slot)")
                    .font(.caption2.bold())
                    .padding(4)
                    .background(.yellow, in: Capsule())
                    .foregroundStyle(.black)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
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
        .sheet(item: $sheet, onDismiss: {
            settingsBackupLifetime.end(library: model)
        }) { destination in
            switch destination {
            case .settings:
                SyncedContentSettingsView(
                    model: session.syncedContentSettings,
                    clipboard: session.clipboard,
                    haptics: model.haptics,
                    library: model,
                    backupLifetime: settingsBackupLifetime,
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
            "Add List",
            isPresented: Binding(
                get: { model.newListMoveRequest != nil },
                set: { if !$0 { model.newListMoveRequest = nil } }
            ),
            presenting: model.newListMoveRequest
        ) { request in
            TextField("List name", text: $newMoveListName)
                .accessibilityIdentifier("move-new-list-name")
            Button("Create and Move") {
                let name = newMoveListName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor in
                    if await model.createListAndMove(request, name: name),
                       request.selectionSessionID == model.gatheringSessionID,
                       model.selectedSnipIDs.isEmpty {
                        model.endSelectingSnips()
                        collectionEditMode = .inactive
                    }
                }
            }
            .disabled(newMoveListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Selected items will move into the new list.")
        }
        .onChange(of: model.newListMoveRequest != nil) { _, presented in
            if presented { newMoveListName = "" }
        }
        .alert(
            model.errorTitle,
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? String(localized: "Try again."))
        }
        .alert(
            "Some Files Are Unavailable",
            isPresented: Binding(
                get: { copyShare.unavailableFilesNotice != nil },
                set: { if !$0 { copyShare.cancelUnavailableFilesNotice() } }
            )
        ) {
            Button("Copy Text Only") {
                Task { await copyShare.copyTextFromNotice(model: model) }
            }
            Button("Cancel", role: .cancel) { copyShare.cancelUnavailableFilesNotice() }
        } message: {
            Text(copyShare.unavailableFilesNotice?.message
                ?? String(localized: "Snip Snap couldn’t read one or more files."))
        }
        .alert(
            "Couldn’t Copy",
            isPresented: Binding(
                get: { copyShare.errorMessage != nil },
                set: { if !$0 { copyShare.errorMessage = nil } }
            )
        ) {
            Button("OK") { copyShare.errorMessage = nil }
        } message: {
            Text(copyShare.errorMessage ?? String(localized: "Try again."))
        }
        .onChange(of: model.sortMode) { _, mode in
            savedSortMode = mode.rawValue
        }
        .task {
            model.sortMode = SnipSortMode(rawValue: savedSortMode) ?? .chronological
            await session.launch()
#if DEBUG
            await seedGatheringFixtureIfRequested()
            await seedLongListFixtureIfRequested()
            await seedClipboardFixtureIfRequested()
#endif
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
        .task(id: scenePhase) { await pollClipboardWhileActive() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await session.foreground()
                }
            case .background, .inactive:
                session.clipboard.stop()
            @unknown default:
                break
            }
        }
    }

    private func pollClipboardWhileActive() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await session.clipboard.synchronize()
        }
    }

    @ViewBuilder
    private var appNavigation: some View {
        if horizontalSizeClass == .compact {
            TimelineView(.animation(paused: listPageMotion.transition?.settlement == nil)) { context in
                let frame = listPageMotion.frame(
                    pages: model.pages,
                    selectedPage: model.selectedPage,
                    at: context.date
                )
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        CompactLibraryPageStack(
                            model: model,
                            clipboard: session.clipboard,
                            clipboardViewState: clipboardViewState,
                            copyShare: copyShare,
                            sheet: $sheet,
                            editMode: collectionEditModeBinding,
                            motion: $listPageMotion,
                            frame: frame,
                            isComposerFocused: isCompactComposerFocused,
                            dismissComposerKeyboard: { isCompactComposerFocused = false },
                            cancelNewList: requestCancelNewList,
                            libraryActions: compactLibraryActions
                        )
                        .libraryToast(
                            model: model,
                            isHidden: model.isSearchPresented,
                            usesFixedExpiry: true
                        )
                        .frame(maxHeight: .infinity)

                        libraryControls(pageFrame: frame, pageWidth: proxy.size.width)
                    }
                }
            }
            .task(id: listPageMotion.transition?.settlement?.id) {
                guard let settlement = listPageMotion.transition?.settlement else { return }
                do { try await Task.sleep(for: .seconds(settlement.duration)) }
                catch { return }
                guard let transition = listPageMotion.transition,
                      transition.settlement?.id == settlement.id else { return }
                switch settlement.completion {
                case .cancelNewList:
                    guard case .list(let id) = transition.source,
                          model.newListID == id,
                          model.editingListID == id,
                          model.selectedPage == .list(id) else {
                        listPageMotion.finishSettlement(settlement.id)
                        return
                    }
                    Task { @MainActor in
                        guard listPageMotion.transition?.settlement?.id == settlement.id,
                              scenePhase == .active, sheet == nil,
                              !model.isSearchPresented,
                              model.newListID == id,
                              model.editingListID == id,
                              model.selectedPage == .list(id) else {
                            if listPageMotion.transition?.settlement?.id == settlement.id {
                                listPageMotion.interrupt()
                            }
                            return
                        }
                        _ = await cancelNewList(id)
                        if listPageMotion.transition?.settlement?.id == settlement.id {
                            listPageMotion.interrupt()
                        }
                    }
                case .cancelNewListFromButton:
                    break // The button task finishes deletion and reports its result to the editor.
                case .createList:
                    await createListFromEdge(
                        transition.source, pages: transition.pages, settlementID: settlement.id
                    )
                case .navigate:
                    listPageMotion.finishSettlement(settlement.id)
                }
            }
            .onChange(of: model.selectedPage) { _, page in
                guard let transition = listPageMotion.transition else { return }
                if listPageMotion.isCreatingFromEdge,
                   let newListID = model.newListID,
                   page == .list(newListID) { return }
                let destination = transition.settlement.map { Int($0.destination) }
                guard let destination, transition.pages.indices.contains(destination),
                      transition.pages[destination] == page else {
                    cancelEdgeCreation()
                    listPageMotion.interrupt()
                    return
                }
            }
            .onChange(of: model.pages) { _, pages in
                if listPageMotion.isCreatingFromEdge,
                   let newListID = model.newListID,
                   pages.last == .list(newListID) { return }
                if listPageMotion.transition?.pages != pages {
                    cancelEdgeCreation()
                    listPageMotion.interrupt()
                }
            }
            .onChange(of: model.newListID) { _, id in
                guard let id,
                      model.selectedPage == .list(id),
                      model.pages.last == .list(id),
                      let origin = model.newListOriginPage,
                      model.pages.contains(origin),
                      scenePhase == .active, sheet == nil,
                      !model.isSearchPresented else { return }
                listPageMotion.beginNewListEntrance(
                    pages: model.pages, cancellationOrigin: origin,
                    reduceMotion: reduceMotion, at: Date()
                )
            }
            .onChange(of: sheet) { _, _ in
                cancelEdgeCreation()
                listPageMotion.interrupt()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    cancelEdgeCreation()
                    listPageMotion.interrupt()
                }
            }
            .onChange(of: model.isSearchPresented) { _, isPresented in
                if isPresented {
                    cancelEdgeCreation()
                    listPageMotion.interrupt()
                }
            }
            .onDisappear {
                cancelEdgeCreation()
                listPageMotion.interrupt()
            }
        } else {
            NavigationSplitView {
                ListSidebarView(
                    model: model,
                    sheet: $sheet,
                    editMode: collectionEditModeBinding,
                    syncedContentSettings: session.syncedContentSettings,
                    syncNow: { await session.retrySyncWhenPossible() },
                    deleteList: deleteList
                )
            } detail: {
                NavigationStack {
                    ZStack {
                        if model.selectedPage == .clipboard {
                            IOSClipboardView(
                                model: session.clipboard,
                                libraryModel: model,
                                copyShare: copyShare,
                                syncedContentSettings: session.syncedContentSettings,
                                syncNow: { await session.retrySyncWhenPossible() },
                                sheet: $sheet,
                                settings: { sheet = .settings }
                            )
                        } else {
                        SnipCollectionView(
                            model: model,
                            clipboard: session.clipboard,
                            copyShare: copyShare,
                            sheet: $sheet,
                            layout: .inlineList,
                            editMode: collectionEditModeBinding,
                            cancelNewList: cancelNewList,
                            dismissComposerKeyboard: {
                                isCompactComposerFocused = false
                            }
                        )
                        }
                    }
                    .libraryToast(model: model)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        libraryControls(showsListTabs: false)
                    }
                }
            }
            .searchable(
                text: Binding(get: { model.searchText }, set: { model.searchText = $0 }),
                isPresented: Binding(get: { model.isSearchPresented }, set: { model.isSearchPresented = $0 }),
                prompt: "Search"
            )
            .searchToolbarBehavior(.minimize)
        }
    }

    private func cancelNewList(_ id: UUID) async -> Bool {
        let cancelled = await model.cancelNewList(id: id)
        if cancelled {
            compactComposerStorage.draftStore.clear(listID: id)
        }
        return cancelled
    }

    private func requestCancelNewList(_ id: UUID) async -> Bool {
        guard model.newListID == id,
              model.editingListID == id,
              model.selectedPage == .list(id) else { return false }
        guard listPageMotion.transition?.settlement?.cancelsNewList != true else { return false }
        guard listPageMotion.beginNewListCancellation(
            from: .list(id), to: model.newListCancellationPage, pages: model.pages,
            reduceMotion: reduceMotion, at: Date()
        ), let settlement = listPageMotion.transition?.settlement else {
            return await cancelNewList(id)
        }
        defer {
            if listPageMotion.transition?.settlement?.id == settlement.id {
                listPageMotion.interrupt()
            }
        }
        do {
            try await Task.sleep(for: .seconds(settlement.duration))
        } catch {
            return false
        }
        guard listPageMotion.transition?.settlement?.id == settlement.id else { return false }
        guard model.newListID == id else { return true }
        guard model.editingListID == id, model.selectedPage == .list(id) else { return false }
        return await cancelNewList(id)
    }

    private func cancelEdgeCreation() {
        edgeCreationTask?.cancel()
        edgeCreationTask = nil
        edgeCreationTaskID = nil
    }

    private func deleteList(_ id: UUID) async {
        if await model.deleteList(id: id) {
            compactComposerStorage.draftStore.clear(listID: id)
        }
    }

    private var compactLibraryActions: LibraryActionsMenu {
        LibraryActionsMenu(
            model: model,
            settings: { sheet = .settings },
            editMode: collectionEditModeBinding,
            syncedContentSettings: session.syncedContentSettings,
            syncNow: { await session.retrySyncWhenPossible() },
            reviewRecoveredEdits: model.recoverySnapshot.needsAttentionCount > 0
                ? { sheet = .recoveryCenter }
                : nil,
            editSelectedList: model.selectedListID == SnipList.inboxID
                ? nil : { model.editListInline(id: model.selectedListID) },
            deleteList: deleteList
        )
    }

    private func libraryControls(
        showsListTabs: Bool = true,
        pageFrame: ListPageFrame? = nil,
        pageWidth: CGFloat = 0
    ) -> some View {
        CompactLibraryControls(
            model: model,
            clipboard: session.clipboard,
            storage: compactComposerStorage,
            isComposerFocused: $isCompactComposerFocused,
            showsListTabs: showsListTabs,
            isSelecting: collectionEditMode.isEditing,
            sheet: $sheet,
            motion: $listPageMotion,
            pageFrame: pageFrame,
            pageWidth: pageWidth,
            deleteList: deleteList,
            createList: { sourcePage, pages in
                await createListFromEdge(sourcePage, pages: pages)
            }
        )
        .frame(height: model.isSearchPresented ? 0 : nil)
        .clipped()
        .allowsHitTesting(!model.isSearchPresented)
        .accessibilityHidden(model.isSearchPresented)
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

    private func canCreateListFromEdge(_ sourcePage: LibraryPage?, pages: [LibraryPage]?) -> Bool {
        guard let sourcePage, sourcePage == model.selectedPage,
              pages == model.pages, scenePhase == .active, sheet == nil,
              !model.isSearchPresented else { return false }
        return model.editingListID == nil || model.editingListID != sourcePage.listID
    }

    private func createListFromEdge(
        _ sourcePage: LibraryPage, pages: [LibraryPage], settlementID: UUID? = nil
    ) async {
        guard canCreateListFromEdge(sourcePage, pages: pages) else {
            if settlementID != nil {
                listPageMotion.returnFromCommittedCreation(reduceMotion: reduceMotion, at: Date())
            } else {
                listPageMotion.interrupt()
            }
            return
        }
        cancelEdgeCreation()
        let requestID = UUID()
        edgeCreationTaskID = requestID
        let task = Task { @MainActor in
            defer {
                if edgeCreationTaskID == requestID {
                    edgeCreationTask = nil
                    edgeCreationTaskID = nil
                }
            }
            guard !Task.isCancelled,
                  settlementID.map({ listPageMotion.transition?.settlement?.id == $0 }) ?? true,
                  canCreateListFromEdge(sourcePage, pages: pages) else {
                if settlementID != nil {
                    listPageMotion.returnFromCommittedCreation(reduceMotion: reduceMotion, at: Date())
                } else {
                    listPageMotion.interrupt()
                }
                return
            }
            let pendingListID = model.newListID
            await model.openNewList(ifSelectedPageIs: sourcePage)
            guard !Task.isCancelled, edgeCreationTaskID == requestID,
                  settlementID.map({ listPageMotion.transition?.settlement?.id == $0 }) ?? true,
                  model.newListID == pendingListID else { return }
            if let pendingListID, !model.isSearchPresented,
               model.selectedPage == .list(pendingListID) {
                listPageMotion.returnFromAdd(
                    to: .list(pendingListID), pages: model.pages,
                    reduceMotion: reduceMotion, at: Date()
                )
            } else if settlementID != nil {
                listPageMotion.returnFromCommittedCreation(reduceMotion: reduceMotion, at: Date())
            } else {
                listPageMotion.interrupt()
            }
        }
        edgeCreationTask = task
        await task.value
    }

#if DEBUG
    private func seedGatheringFixtureIfRequested() async {
        guard ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_GATHERING"] == "1",
              model.snips.isEmpty else { return }
        for content in ["Sketch a simpler selection flow", "Try the stack interaction on iPhone"] {
            _ = await model.createSnip(content: content, in: SnipList.inboxID)
        }
        for name in ["Work", "Ideas", "Reading", "Project reference library", "Weekend plans", "Archive"] {
            _ = await model.createList(name: name)
        }
        model.selectList(SnipList.inboxID)
    }

    private func seedLongListFixtureIfRequested() async {
        guard ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_LONG_LIST"] == "1",
              model.snips.isEmpty else { return }
        for index in 0..<24 {
            let content = index == 0 ? "Fixture oldest" : "Fixture \(index)"
            _ = await model.createSnip(
                content: content,
                in: SnipList.inboxID,
                attachmentURLs: uiTestAttachmentURLs
            )
        }
    }

    private func seedClipboardFixtureIfRequested() async {
        guard ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_CLIPBOARD_ENTRY"] == "1",
              session.clipboard.entries.isEmpty else { return }
        await session.clipboard.capture([NSItemProvider(object: "Clipboard swipe fixture" as NSString)])
    }
#endif

}

// Scope the native search host to the background so opening it keeps screen state alive.
struct CompactLibrarySearchHost: View {
    let model: IOSAppModel
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .searchable(
                text: Binding(get: { model.searchText }, set: { model.searchText = $0 }),
                isPresented: $isPresented,
                prompt: "Search"
            )
            .task {
                await Task.yield()
                guard !Task.isCancelled, model.isSearchPresented else { return }
                isPresented = true
            }
            .onChange(of: isPresented) { _, presented in
                if !presented { model.isSearchPresented = false }
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
                    AppPrimaryActionButton {
                        Task { await model.resolve(.keepLocalCopy) }
                    } label: {
                        Text("Keep on this device")
                    }
                    .accessibilityIdentifier("keep-account-cache")
                    Button("Remove from this device", role: .destructive) {
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

extension View {
    func libraryToast(
        model: IOSAppModel,
        isHidden: Bool = false,
        usesFixedExpiry: Bool = false
    ) -> some View {
        appToast(
            Binding(
                get: { model.toast },
                set: { model.toast = $0 }
            ),
            alignment: .bottom,
            edge: .bottom,
            isHidden: isHidden,
            reservesSpace: true,
            usesFixedExpiry: usesFixedExpiry,
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
