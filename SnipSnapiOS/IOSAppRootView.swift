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
    @State private var diagnosticSettings = AppDiagnosticSettingsModel()
    @State private var newMoveListName = ""
    @FocusState private var isMoveListNameFocused: Bool
    @State private var copyShare = IOSCopyShareCoordinator()
    @State private var compactComposerStorage: CompactComposerStorage
    @State private var listPageMotionState = ListPageMotionState()
    @State private var edgeCreation = ListEdgeCreationRequest()
    @State private var clipboardViewState = ClipboardViewState()
    @State private var isCompactComposerFocused = false
#if DEBUG
    @State private var isUITestStartupComplete = false
#endif
    private let uiTestAttachmentURLs: [URL]
    private let seedsCopyShareFixtures: Bool
    private let shareProcessToken: String?
    private let sidebarDefaults = LibrarySidebarDefaults.current
    init(
        session: IOSAppSession,
        uiTestAttachmentURLs: [URL] = [],
        seedsCopyShareFixtures: Bool = false,
        shareProcessToken: String? = nil,
        composerStorage: CompactComposerStorage = CompactComposerStorage()
    ) {
#if DEBUG
        if let store = ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_STORE"] {
            _savedSortMode = AppStorage(wrappedValue: SnipSortMode.chronological.rawValue, "snip-sort-mode-\(store)")
        }
#endif
        self.session = session
        _compactComposerStorage = State(initialValue: composerStorage)
        self.uiTestAttachmentURLs = uiTestAttachmentURLs
        self.seedsCopyShareFixtures = seedsCopyShareFixtures
        self.shareProcessToken = shareProcessToken
    }

    private var listPageMotion: ListPageMotion {
        get { listPageMotionState.value }
        nonmutating set { listPageMotionState.value = newValue }
    }

    private var pageMotionBinding: Binding<ListPageMotion> {
        Binding(get: { listPageMotionState.value }, set: { listPageMotionState.value = $0 })
    }

    private var model: IOSAppModel { session.model }

    private var collectionEditMode: EditMode {
        get { model.isSelectingSnips ? .active : .inactive }
        nonmutating set {
            if newValue.isEditing { model.beginSelectingSnips() }
            else if model.isSelectingSnips { model.endSelectingSnips() }
        }
    }

    private var collectionEditModeBinding: Binding<EditMode> {
        Binding(get: { collectionEditMode }, set: { collectionEditMode = $0 })
    }

    private var searchNavigation: some View {
        appNavigation
        .background { Color.clear.frame(width: 0, height: 0).modifier(ComposerAttachmentPresentations(model: model, storage: compactComposerStorage)) }
        .onChange(of: usesCompactLayout) { compactComposerStorage.layoutDidSwap() }
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

    private var appPresentation: some View {
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
            IOSShareSheetPresenter(request: copyShare.shareSheetRequest)
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
                        .font(AppTypography.font(size: 9, weight: .bold))
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
                    .appFont(.caption2)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("haptic-event")
            }
        }
        .overlay(alignment: .topLeading) {
            if (ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TESTING"] == "1" || shareProcessToken != nil),
               isUITestStartupComplete {
                Text(verbatim: "UI test startup complete")
                    .appFont(.caption2)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("ui-test-startup-complete")
            }
            if let shareProcessToken {
                Text(
                    String(model.snips.filter { $0.content.contains(shareProcessToken) }.count)
                )
                .appFont(.caption2)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("share-process-count")
            }
        }
#endif
        .glassMenuHost(isBlocked: sheet != nil || model.newListMoveRequest != nil || model.isSearchPresented || copyShare.shareRequest != nil)
        .sheet(item: $sheet, onDismiss: {
            settingsBackupLifetime.end(library: model)
        }) { destination in
            Group {
                switch destination {
                case .settings:
                    SyncedContentSettingsView(
                        model: session.syncedContentSettings,
                        clipboard: session.clipboard,
                        haptics: model.haptics,
                        library: model,
                        backupLifetime: settingsBackupLifetime,
                        diagnostics: diagnosticSettings,
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
            .libraryToast(model: model, isHidden: model.errorDetails != nil, usesFixedExpiry: true)
            .modifier(IOSFailurePresentation(model: model))
        }
        .sheet(
            isPresented: Binding(
                get: { model.newListMoveRequest != nil },
                set: { if !$0 { model.dismissNewListMove() } }
            ),
            onDismiss: { model.clearFailure(for: "list.create") }
        ) {
            if let request = model.newListMoveRequest {
                NavigationStack {
                    Form {
                        TextField("List name", text: $newMoveListName)
                            .accessibilityIdentifier("move-new-list-name")
                            .focused($isMoveListNameFocused)
                            .onAppear { isMoveListNameFocused = true }
                        IOSInlineFailureView(model: model, operations: ["list.create"])
                        Text("Selected items will move into the new list.")
                            .foregroundStyle(.secondary)
                    }
                    .navigationTitle("Add List")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { model.dismissNewListMove() }
                                .disabled(model.isPerformingGatheredAction)
                                .accessibilityIdentifier("cancel-create-move")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Create and Move") {
                                let name = newMoveListName.trimmingCharacters(in: .whitespacesAndNewlines)
                                Task { @MainActor in await model.createListAndMove(request, name: name) }
                            }
                            .disabled(newMoveListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || model.isPerformingGatheredAction)
                            .accessibilityIdentifier("create-and-move")
                        }
                    }
                    .disabled(model.isPerformingGatheredAction)
                }
                .interactiveDismissDisabled(model.isPerformingGatheredAction)
                .libraryToast(model: model, isHidden: model.errorDetails != nil, usesFixedExpiry: true)
                .modifier(IOSFailurePresentation(model: model))
            }
        }
        .onChange(of: model.newListMoveRequest != nil) { _, presented in
            if presented { newMoveListName = "" }
        }

    }

    var body: some View {
        appPresentation
        .modifier(IOSFailurePresentation(model: model, isActive: sheet == nil && model.newListMoveRequest == nil))
        .onChange(of: session.clipboard.operationFailure?.id) { previousID, _ in
            if let previousID { model.clearFailure(id: previousID) }
            if let failure = session.clipboard.operationFailure { model.presentFailure(failure) }
        }
        .alert(
            "Some Files Are Unavailable",
            isPresented: Binding(
                get: { copyShare.unavailableFilesNotice != nil },
                set: { if !$0 { copyShare.cancelUnavailableFilesNotice() } }
            ),
            presenting: copyShare.unavailableFilesNotice
        ) { notice in
            Button("Copy Text Only") {
                Task { await copyShare.copyTextFromNotice(notice, model: model) }
            }
            Button("Cancel", role: .cancel) { copyShare.cancelUnavailableFilesNotice() }
        } message: { notice in
            Text(notice.message)
        }
        .onChange(of: model.sortMode) { _, mode in
            savedSortMode = mode.rawValue
        }
        .task {
            model.sortMode = SnipSortMode(rawValue: savedSortMode) ?? .chronological
            await session.launch()
#if DEBUG
            await model.seedAgentSnipsUITestFixtureIfRequested()
            await seedGatheringFixtureIfRequested()
            await seedLongListFixtureIfRequested()
            await seedClipboardFixtureIfRequested()
            await seedRailListsFixtureIfRequested()
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
#if DEBUG
            if ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TESTING"] == "1" || shareProcessToken != nil {
                isUITestStartupComplete = true
            }
#endif
        }
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: SnipSnapCloudNotifications.accountChanged
            ) {
                await session.syncWhenPossible()
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

    private func finishListPageSettlement(_ id: UUID) async {
        guard let settlement = listPageMotion.transition?.settlement, settlement.id == id else { return }
        if case .cancelNewList = settlement.completion {
            guard let transition = listPageMotion.transition,
                  case .list(let id) = transition.source,
                  model.newListID == id,
                  model.editingListID == id,
                  model.selectedPage == .list(id) else {
                listPageMotion.finishSettlement(settlement.id)
                return
            }
            _ = await cancelNewList(id) {
                do { try await Task.sleep(for: .seconds(settlement.duration)) }
                catch { return false }
                guard listPageMotion.transition?.settlement?.id == settlement.id,
                      scenePhase == .active, sheet == nil,
                      !model.isSearchPresented,
                      model.newListID == id,
                      model.editingListID == id,
                      model.selectedPage == .list(id) else { return false }
                return true
            }
            if listPageMotion.transition?.settlement?.id == settlement.id {
                listPageMotion.interrupt()
            }
            return
        }
        do { try await Task.sleep(for: .seconds(settlement.duration)) }
        catch { return }
        guard let transition = listPageMotion.transition,
              transition.settlement?.id == settlement.id else { return }
        switch settlement.completion {
        case .cancelNewList, .cancelNewListFromButton:
            break // Their owning tasks finish cancellation.
        case .createList:
            await createListFromEdge(
                transition.source, pages: transition.pages, settlementID: settlement.id
            )
        case .navigate:
            listPageMotion.finishSettlement(settlement.id)
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

    /// Picks the compact or regular tree; a change, such as folding an iPhone Duo, swaps them.
    private var usesCompactLayout: Bool { horizontalSizeClass == .compact }

    @ViewBuilder
    private var appNavigation: some View {
        if usesCompactLayout {
            GeometryReader { proxy in
                CompactLibraryPageStack(
                    model: model,
                    clipboard: session.clipboard,
                    clipboardViewState: clipboardViewState,
                    copyShare: copyShare,
                    sheet: $sheet,
                    editMode: collectionEditModeBinding,
                    motionState: listPageMotionState,
                    isComposerFocused: isCompactComposerFocused,
                    dismissComposerKeyboard: { isCompactComposerFocused = false },
                    cancelNewList: requestCancelNewList,
                    libraryActions: libraryActionsMenu(anchorsDevelopmentBadge: true)
                )
                .libraryToast(
                    model: model,
                    isHidden: model.isSearchPresented || sheet != nil || model.newListMoveRequest != nil || model.errorDetails != nil,
                    usesFixedExpiry: true
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ListPageFrameReader(
                        state: listPageMotionState, pages: model.pages, selectedPage: model.selectedPage
                    ) { frame in
                        libraryControls(
                            pageFrame: frame,
                            pageWidth: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
                        )
                    }
                }
            }
            .modifier(ListPageSettlementObserver(
                state: listPageMotionState, complete: finishListPageSettlement
            ))
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
            HStack(spacing: 0) {
                LibraryRailView(model: model, sheet: $sheet, defaults: sidebarDefaults, deleteList: deleteList)
                    .ignoresSafeArea(.keyboard)
                    // Its resize handle straddles the card's leading edge.
                    .zIndex(1)
                regularDetail(libraryActions: libraryActionsMenu(anchorsDevelopmentBadge: false))
                    .librarySearchable(model: model)
                    .sideButtonsWhereVerticalBar()
                    .background { railCardShape.fill(Color(.systemBackground)).ignoresSafeArea() }
                    .mask { railCardShape.ignoresSafeArea() }
            }
            .librarySidebarContainer(sidebarDefaults)
            .background(Color(.secondarySystemBackground).ignoresSafeArea())
        }
    }

    /// The page card beside the rail. It runs under the bars, and its leading corners stay round.
    private var railCardShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 26, bottomLeadingRadius: 26, style: .continuous)
    }

    private func regularDetail(libraryActions: LibraryActionsMenu) -> some View {
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
                        cancelNewList: { await cancelNewList($0) },
                        dismissComposerKeyboard: {
                            isCompactComposerFocused = false
                        },
                        libraryActions: libraryActions
                    )
                }
            }
            .libraryToast(model: model, isHidden: sheet != nil || model.newListMoveRequest != nil || model.errorDetails != nil,
                          usesFixedExpiry: true)
            // Bar hosting drops field focus updates on iOS 26.5.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                libraryControls(showsListTabs: false)
                    .background {
                        if !model.isSearchPresented { regularControlsFade }
                    }
            }
        }
    }

    private func cancelNewList(
        _ id: UUID,
        beforeDeletion: @MainActor () async -> Bool = { true }
    ) async -> Bool {
        let cancelled = await model.cancelNewList(id: id, beforeDeletion: beforeDeletion)
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
        var settlementID: UUID?
        defer {
            if let settlementID, listPageMotion.transition?.settlement?.id == settlementID {
                listPageMotion.interrupt()
            }
        }
        return await cancelNewList(id) {
            guard listPageMotion.beginNewListCancellation(
                from: .list(id), to: model.newListCancellationPage, pages: model.pages,
                reduceMotion: reduceMotion, at: Date()
            ), let settlement = listPageMotion.transition?.settlement else {
                return true
            }
            settlementID = settlement.id
            do {
                try await Task.sleep(for: .seconds(settlement.duration))
            } catch {
                return false
            }
            guard listPageMotion.transition?.settlement?.id == settlement.id,
                  scenePhase == .active, sheet == nil, !model.isSearchPresented,
                  model.newListID == id,
                  model.editingListID == id, model.selectedPage == .list(id) else { return false }
            return true
        }
    }

    private func cancelEdgeCreation() {
        edgeCreation.cancel()
    }

    private func deleteList(_ id: UUID) async {
        if await model.deleteList(id: id) {
            compactComposerStorage.draftStore.clear(listID: id)
        }
    }

    private func libraryActionsMenu(anchorsDevelopmentBadge: Bool) -> LibraryActionsMenu {
        LibraryActionsMenu(
            model: model,
            settings: { sheet = .settings },
            editMode: collectionEditModeBinding,
            syncedContentSettings: session.syncedContentSettings,
            syncNow: { await session.retrySyncWhenPossible() },
            reviewRecoveredEdits: model.recoverySnapshot.needsAttentionCount > 0
                ? { sheet = .recoveryCenter }
                : nil,
            editSelectedList: model.lastSelectedListID == SnipList.inboxID
                ? nil : { model.editListInline(id: model.lastSelectedListID) },
            deleteList: deleteList,
            anchorsDevelopmentBadge: anchorsDevelopmentBadge
        )
    }

    // A plain safe-area inset gets no scroll-edge effect, so rows fade out under the controls here.
    private var regularControlsFade: some View {
        Rectangle()
            .fill(.background)
            .mask {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
            motion: pageMotionBinding,
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
        let requestID = UUID()
        let task = Task { @MainActor in
            defer { edgeCreation.finish(requestID) }
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
            guard !Task.isCancelled, edgeCreation.isCurrent(requestID),
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
        edgeCreation.begin(requestID, task: task)
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
        await seedListHistoryUITestFixture(in: model)
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

    /// Lists without an icon show letters; the others keep their icon.
    private func seedRailListsFixtureIfRequested() async {
        guard ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_RAIL_LISTS"] == "1",
              model.snips.isEmpty else { return }
        for content in ["Pick up the dry cleaning", "Call the dentist", "Draft the trip plan"] {
            _ = await model.createSnip(content: content, in: SnipList.inboxID)
        }
        for name in ["Groceries", "Work", "Reading list"] {
            _ = await model.createList(name: name)
        }
        _ = await model.createList(name: "Travel", systemImage: "airplane", color: .blue)
        _ = await model.createList(name: "Ideas", color: .orange)
        // Older builds saved this symbol on every new list.
        _ = await model.createList(name: "Archive", systemImage: "list.bullet")
        model.selectList(SnipList.inboxID)
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

extension View {
    func librarySearchable(model: IOSAppModel) -> some View {
        searchable(
            text: Binding(get: { model.searchText }, set: { model.searchText = $0 }),
            isPresented: Binding(get: { model.isSearchPresented }, set: { model.isSearchPresented = $0 }),
            prompt: "Search"
        )
        .searchToolbarBehavior(.minimize)
    }

    func libraryToast(
        model: IOSAppModel,
        isHidden: Bool = false,
        usesFixedExpiry: Bool = false
    ) -> some View {
        appToast(
            showing: model.toast,
            close: model.closeSnackbar,
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

private struct IOSFailurePresentation: ViewModifier {
    let model: IOSAppModel
    var isActive = true

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                if isActive {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.hasGlobalInlineFailure {
                            IOSInlineFailureView(model: model, operations: [""], includesProtectedUndoFailure: true)
                                .padding()
                        }
                        if let failure = model.pendingUndoFailure {
                            AppUndoRecoveryView(
                                failure: failure,
                                onRetry: { model.retryPendingUndo(failure) },
                                onDetails: { model.showErrorDetails(failure) }
                            )
                        }
                    }
                }
            }
            .sheet(item: Binding<AppFailure?>(
                get: { isActive ? model.errorDetails : nil },
                set: { selected in
                    if let selected { model.showErrorDetails(selected) }
                    else { model.dismissErrorDetails() }
                }
            )) { failure in
                AppErrorDetailsView(
                    failure: failure,
                    onClose: model.dismissErrorDetails,
                    onRetry: model.canRetryFailure(failure) ? { model.retryFailure(failure) } : nil
                )
                .libraryToast(model: model, isHidden: model.toast?.action == .showErrorDetails(failure.id),
                              usesFixedExpiry: true)
            }
            .alert(model.errorTitle, isPresented: Binding(
                get: { isActive && model.failure?.surface == .dialog && model.errorDetails == nil },
                set: { if !$0 && model.errorDetails == nil { model.dismissError() } }
            )) {
                if let failure = model.failure, model.canRetryFailure(failure) {
                    Button("Retry") { model.retryFailure(failure) }
                }
                Button("Details", action: model.showLatestErrorDetails)
                Button("OK", action: model.dismissError)
            } message: {
                Text(model.errorMessage ?? String(localized: "Try again."))
            }
    }
}
