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
    @State private var copyShare = IOSCopyShareCoordinator()
    @State private var compactComposerStorage = CompactComposerStorage()
    @State private var collectionEditMode: EditMode = .inactive
    @State private var listPageMotion = ListPageMotion()
    @State private var clipboardViewState = ClipboardViewState()
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

    private func beginBackupImport() {
        model.haptics.invalidatePendingFeedback()
        isExplainingBackupImport = true
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
        .onChange(of: model.selectedListID) {
            model.isSearchPresented = false
            model.searchText = ""
        }
        .onChange(of: model.showsClipboard) {
            model.isSearchPresented = false
            model.searchText = ""
        }
        .onChange(of: currentPage) {
            guard collectionEditMode.isEditing else { return }
            model.endSelectingSnips()
            collectionEditMode = .inactive
        }
    }

    var body: some View {
        searchNavigation
        .tint(SnipSnapTheme.controlTint)
        .modifier(IOSHapticFeedbackModifier(feedback: model.haptics))
        .onChange(of: sheet) { model.haptics.invalidatePendingFeedback() }
        .onChange(of: model.selectedListID) { model.haptics.invalidatePendingFeedback() }
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
        .sheet(item: $sheet) { destination in
            switch destination {
            case .editSnip(let id):
                SnipEditorView(model: model, snipID: id)
            case .settings:
                SyncedContentSettingsView(
                    model: session.syncedContentSettings,
                    clipboard: session.clipboard,
                    haptics: model.haptics,
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
        .confirmationDialog(
            "Choose a backup",
            isPresented: $isExplainingBackupImport,
            titleVisibility: .visible
        ) {
            Button("Choose backup") { isImportingBackup = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a backup folder that includes attachments, or a JSON file without attachments.")
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
                    model.presentError(error, operation: "backup.import_select")
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
            Button("Import backup") { Task { await model.confirmBackupImport() } }
            Button("Cancel", role: .cancel) { model.cancelBackupImport() }
        } message: {
            Text("Merge this backup with your library.\n\n\(model.pendingImportPreview?.localizedSummary ?? "")")
        }
        .onChange(of: model.sortMode) { _, mode in
            savedSortMode = mode.rawValue
        }
        .task {
            model.sortMode = SnipSortMode(rawValue: savedSortMode) ?? .chronological
            await session.launch()
#if DEBUG
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
                    pages: [.clipboard] + model.lists.map { .list($0.id) },
                    selectedPage: currentPage,
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
                            editMode: $collectionEditMode,
                            motion: $listPageMotion,
                            frame: frame,
                            isComposerFocused: isCompactComposerFocused,
                            dismissComposerKeyboard: { isCompactComposerFocused = false },
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
                listPageMotion.finishSettlement(settlement.id)
            }
            .onChange(of: currentPage) { _, page in
                guard let transition = listPageMotion.transition else { return }
                let destination = transition.settlement.map { Int($0.destination) }
                guard let destination, transition.pages.indices.contains(destination),
                      transition.pages[destination] == page else {
                    listPageMotion.interrupt()
                    return
                }
            }
            .onChange(of: sheet) { _, _ in listPageMotion.interrupt() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { listPageMotion.interrupt() }
            }
            .onChange(of: model.isSearchPresented) { _, isPresented in
                if isPresented { listPageMotion.interrupt() }
            }
        } else {
            NavigationSplitView {
                ListSidebarView(
                    model: model,
                    sheet: $sheet,
                    editMode: $collectionEditMode,
                    importBackup: beginBackupImport
                )
            } detail: {
                NavigationStack {
                    ZStack {
                        if model.showsClipboard {
                            IOSClipboardView(
                            model: session.clipboard,
                            libraryModel: model,
                            copyShare: copyShare,
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
                            editMode: $collectionEditMode,
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

    private var compactLibraryActions: LibraryActionsMenu {
        LibraryActionsMenu(
            model: model,
            importBackup: beginBackupImport,
            settings: { sheet = .settings },
            editMode: $collectionEditMode,
            includesCloudActions: true,
            reviewRecoveredEdits: model.recoverySnapshot.needsAttentionCount > 0
                ? { sheet = .recoveryCenter }
                : nil,
            editSelectedList: model.selectedListID == SnipList.inboxID
                ? nil : { model.editListInline(id: model.selectedListID) }
        )
    }

    private var currentPage: LibraryPage {
        model.showsClipboard ? .clipboard : .list(model.selectedListID)
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
            pageWidth: pageWidth
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

#if DEBUG
    private func seedLongListFixtureIfRequested() async {
        guard ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_LONG_LIST"] == "1",
              model.snips.isEmpty else { return }
        for index in 0..<24 {
            let content = index == 0 ? "Fixture oldest" : "Fixture \(index)"
            _ = await model.createSnip(content: content, in: SnipList.inboxID)
        }
    }

    private func seedClipboardFixtureIfRequested() async {
        guard ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_CLIPBOARD_ENTRY"] == "1",
              session.clipboard.entries.isEmpty else { return }
        await session.clipboard.capture([NSItemProvider(object: "Clipboard swipe fixture" as NSString)])
    }
#endif

}

private struct CompactLibraryPageStack: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var swipeBlockingPages: Set<LibraryPage> = []
    let model: IOSAppModel
    let clipboard: IOSClipboardModel
    let clipboardViewState: ClipboardViewState
    let copyShare: IOSCopyShareCoordinator
    @Binding var sheet: AppSheet?
    @Binding var editMode: EditMode
    @Binding var motion: ListPageMotion
    let frame: ListPageFrame
    let isComposerFocused: Bool
    let dismissComposerKeyboard: () -> Void
    let libraryActions: LibraryActionsMenu

    private var currentPage: LibraryPage {
        model.showsClipboard ? .clipboard : .list(model.selectedListID)
    }

    private enum EdgeSwipeSide {
        case leading, trailing
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(frame.retainedPages, id: \.self) { page in
                    libraryPage(page, isActivePage: page == currentPage)
                        .offset(x: frame.offset(
                            for: page, width: proxy.size.width,
                            layoutDirection: layoutDirection, reduceMotion: reduceMotion
                        ))
                        .opacity(frame.opacity(for: page, reduceMotion: reduceMotion))
                        .accessibilityHidden(page != currentPage)
                        .disabled(frame.isMoving || page != currentPage)
                        .allowsHitTesting(!frame.isMoving && page == currentPage)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .background {
                ScreenEdgePanObserver(
                    canBegin: { canSwipeFromEdge(side(for: $0)) },
                    onPan: { physicalEdge, translation, predictedTranslation, phase in
                        handleEdgePan(
                            physicalEdge: physicalEdge,
                            translation: translation,
                            predictedTranslation: predictedTranslation,
                            phase: phase,
                            pageWidth: proxy.size.width
                        )
                    }
                )
            }
        }
    }

    private func libraryPage(_ page: LibraryPage, isActivePage: Bool) -> some View {
        NavigationStack {
            Group {
                switch page {
                case .clipboard:
                    IOSClipboardView(
                        model: clipboard,
                        libraryModel: model,
                        copyShare: copyShare,
                        sheet: $sheet,
                        settings: { sheet = .settings },
                        viewState: clipboardViewState
                    )
                case .list(let listID):
                    SnipCollectionView(
                        model: model,
                        clipboard: clipboard,
                        copyShare: copyShare,
                        sheet: $sheet,
                        layout: .compactStack,
                        listID: listID,
                        isActivePage: isActivePage,
                        editMode: $editMode,
                        blocksPageSwipe: swipeBlockedBinding(for: page),
                        dismissComposerKeyboard: dismissComposerKeyboard,
                        libraryActions: libraryActions
                    )
                }
            }
            .libraryToast(
                model: model,
                isHidden: !isActivePage || !model.isSearchPresented,
                usesFixedExpiry: true
            )
            .background {
                if isActivePage && model.isSearchPresented {
                    CompactLibrarySearchHost(model: model)
                }
            }
            .toolbar {
                if isActivePage && model.isSearchPresented {
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                }
            }
        }
    }

    private var pages: [LibraryPage] {
        [.clipboard] + model.lists.map { .list($0.id) }
    }

    private func swipeBlockedBinding(for page: LibraryPage) -> Binding<Bool> {
        Binding(
            get: { swipeBlockingPages.contains(page) },
            set: { blocked in
                if blocked {
                    swipeBlockingPages.insert(page)
                } else {
                    swipeBlockingPages.remove(page)
                }
            }
        )
    }

    private func handleEdgePan(
        physicalEdge: UIRectEdge,
        translation: CGSize,
        predictedTranslation: CGSize?,
        phase: UIGestureRecognizer.State,
        pageWidth: CGFloat
    ) {
        guard abs(translation.height) <= max(30, abs(translation.width) * 1.2) else {
            motion.cancelEdgeDrag(reduceMotion: reduceMotion, at: Date())
            return
        }
        let side = side(for: physicalEdge)
        guard canSwipeFromEdge(side),
              (phase != .began || isInward(translation.width, from: side)) else {
            if phase != .began { motion.cancelEdgeDrag(reduceMotion: reduceMotion, at: Date()) }
            return
        }
        let inwardTranslation = clampedInward(translation, from: physicalEdge)
        switch phase {
        case .began, .changed:
            motion.updateEdgeDrag(
                translation: inwardTranslation,
                selectedPage: currentPage,
                pages: pages,
                pageWidth: pageWidth,
                layoutDirection: layoutDirection,
                isStart: phase == .began,
                at: Date()
            )
        case .ended:
            guard let dragPages = motion.transition?.pages, dragPages == pages else {
                motion.interrupt()
                return
            }
            guard let destination = motion.releaseEdgeDrag(
                translation: inwardTranslation,
                predictedEndTranslation: clampedInward(
                    predictedTranslation ?? translation, from: physicalEdge
                ),
                reduceMotion: reduceMotion,
                at: Date()
            ), dragPages.indices.contains(destination), dragPages[destination] != currentPage else { return }
            if case .list(let listID) = dragPages[destination] {
                model.selectList(listID)
                model.haptics.emit(.selection, for: model.haptics.beginInteraction())
            }
        default:
            motion.cancelEdgeDrag(reduceMotion: reduceMotion, at: Date())
        }
    }

    private func side(for physicalEdge: UIRectEdge) -> EdgeSwipeSide {
        return switch (physicalEdge, layoutDirection) {
        case (.left, .leftToRight), (.right, .rightToLeft): .leading
        default: .trailing
        }
    }

    private func canSwipeFromEdge(_ side: EdgeSwipeSide) -> Bool {
        guard !model.isSearchPresented, sheet == nil, !editMode.isEditing,
              !isComposerFocused,
              model.editingListID == nil,
              motion.transition?.settlement == nil,
              !motion.isSelectorDragging,
              !swipeBlockingPages.contains(currentPage),
              case .list = currentPage else { return false }
        guard let index = pages.firstIndex(of: currentPage) else { return false }
        switch side {
        case .leading: return index > 1
        case .trailing: return index < pages.count - 1
        }
    }

    private func isInward(_ translation: CGFloat, from side: EdgeSwipeSide) -> Bool {
        let logicalTranslation = translation * (layoutDirection == .rightToLeft ? -1 : 1)
        return switch side {
        case .leading: logicalTranslation > 0
        case .trailing: logicalTranslation < 0
        }
    }

    private func clampedInward(_ translation: CGSize, from physicalEdge: UIRectEdge) -> CGSize {
        CGSize(
            width: physicalEdge == .left ? max(0, translation.width) : min(0, translation.width),
            height: translation.height
        )
    }

}

// Scope the native search host to the background so opening it keeps screen state alive.
private struct CompactLibrarySearchHost: View {
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

private extension View {
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
