import SnipSnapCore
import SwiftUI
import UIKit

enum ListEdgeCueLayout {
    enum Kind { case add, cancel }

    static func stretch(progress: CGFloat) -> CGFloat {
        32 * sin(.pi * progress)
    }

    static func centerX(
        for kind: Kind, in width: CGFloat, progress: CGFloat,
        layoutDirection: LayoutDirection
    ) -> CGFloat {
        let atLeadingEdge = kind == .cancel
        let edgeInset = ListAddCueLayout.edgeInset + stretch(progress: progress) / 2
        let inset = -edgeInset
        return (layoutDirection == .rightToLeft) == atLeadingEdge ? width - inset : inset
    }
}

struct CompactLibraryPageStack: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.glassMenuPresentation) private var glassMenuPresentation
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var visitedPages: Set<LibraryPage> = []
    @State private var swipeBlockingPages: Set<LibraryPage> = []
    @State private var interactionState = PageInteractionState()
    @State private var pageTranslationRegistry = PageLayerTranslationRegistry()

    private final class PageInteractionState {
        var selectionDock = CGRect.zero
        // Gesture bookkeeping does not affect rendering or invalidate mounted pages.
        var pagePanMayStart = false
    }
    let model: IOSAppModel
    let clipboard: IOSClipboardModel
    let clipboardViewState: ClipboardViewState
    let copyShare: IOSCopyShareCoordinator
    @Binding var sheet: AppSheet?
    @Binding var editMode: EditMode
    let motionState: ListPageMotionState
    let isComposerFocused: Bool
    let dismissComposerKeyboard: () -> Void
    let cancelNewList: (UUID) async -> Bool
    let libraryActions: LibraryActionsMenu

    // Native scroll and navigation state survives only while the page stays mounted.
    // Motion decides visibility; the current library bounds the retained lifetime.
    private var mountedPages: [LibraryPage] {
        model.pages.filter { visitedPages.contains($0) || $0 == model.selectedPage }
    }

    var body: some View {
        GeometryReader { safeArea in
            let pageSafeArea = EdgeInsets(
                top: 0, leading: safeArea.safeAreaInsets.leading,
                bottom: 0, trailing: safeArea.safeAreaInsets.trailing
            )
            // Pages span the screen edges, keeping side toolbars inside the clip and rows
            // behind the bottom glass. Each page restores the insets for its native layout.
            GeometryReader { proxy in
                ListPageMotionStage(
                    state: motionState, pages: model.pages, selectedPage: model.selectedPage,
                    width: proxy.size.width,
                    safeArea: pageSafeArea,
                    translationRegistry: pageTranslationRegistry,
                    content: mountedPages.map { page in
                        MountedListPage(
                            id: page,
                            content: libraryPage(
                                page, isActivePage: page == model.selectedPage,
                                bottomSafeArea: safeArea.safeAreaInsets.bottom
                            )
                                .safeAreaPadding(pageSafeArea)
                        )
                    },
                    retainedPagesChanged: { pages in
                        visitedPages.formUnion(pages)
                        visitedPages.formIntersection(model.pages)
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .background {
                    ListPagePanObserver(
                        canBegin: { direction in canPanPage(direction: direction) },
                        canBeginAt: { point in
                            !model.isSelectingSnips || !interactionState.selectionDock.contains(point)
                        },
                        onPan: { direction, translation, predictedTranslation, phase in
                            handlePagePan(
                                direction: direction,
                                translation: translation,
                                predictedTranslation: predictedTranslation,
                                phase: phase,
                                pageWidth: proxy.size.width
                            )
                        }
                    )
                }
            }
            .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        }
        .onChange(of: model.pages) { _, pages in
            visitedPages.formIntersection(pages)
            swipeBlockingPages.formIntersection(pages)
            pageTranslationRegistry.prune(keeping: Set(pages))
        }
    }

    private func libraryPage(_ page: LibraryPage, isActivePage: Bool, bottomSafeArea: CGFloat) -> some View {
        NavigationStack {
            GeometryReader { geometry in
                Group {
                    switch page {
                    case .clipboard:
                        IOSClipboardView(
                            model: clipboard,
                            libraryModel: model,
                            copyShare: copyShare,
                            syncedContentSettings: libraryActions.syncedContentSettings,
                            syncNow: libraryActions.syncNow,
                            sheet: $sheet,
                            settings: { sheet = .settings },
                            isActivePage: isActivePage,
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
                            cancelNewList: cancelNewList,
                            blocksPageSwipe: swipeBlockedBinding(for: page),
                            selectionDockFrameChanged: { interactionState.selectionDock = $0 },
                            dismissComposerKeyboard: dismissComposerKeyboard,
                            libraryActions: libraryActions
                        )
                    }
                }
                // NavigationStack resets ancestor bottom insets; preserve its own bar clearance.
                .safeAreaPadding(.bottom, max(0, bottomSafeArea - geometry.safeAreaInsets.bottom))
                .background {
                    PageLayerTranslationAnchor(page: page, registry: pageTranslationRegistry)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
                #if DEBUG
                .background {
                    if ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_PAGE_LAYOUT"] == "1",
                       case .list(let id) = page,
                       let list = model.lists.first(where: { $0.id == id }) {
                        PageLayoutUITestProbe(name: list.name)
                            .frame(width: 1, height: 1)
                            .opacity(0.01)
                            .allowsHitTesting(false)
                    }
                }
                #endif
                .libraryToast(
                    model: model,
                    isHidden: !isActivePage || !model.isSearchPresented || sheet != nil
                        || model.newListMoveRequest != nil || model.errorDetails != nil
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

    private var motion: ListPageMotion {
        get { motionState.value }
        nonmutating set { motionState.value = newValue }
    }

    private func handlePagePan(
        direction: ListPagePanDirection,
        translation: CGSize,
        predictedTranslation: CGSize?,
        phase: UIGestureRecognizer.State,
        pageWidth: CGFloat
    ) {
        guard canPanPage(direction: direction) else {
            if phase != .began {
                interactionState.pagePanMayStart = false
                motion.cancelPageDrag(reduceMotion: reduceMotion, at: Date())
            }
            return
        }
        let inwardTranslation = direction.clamped(translation)
        let cancelTarget = newListSwipeBackTarget(for: direction)
        switch phase {
        case .began, .changed:
            if phase == .began {
                interactionState.pagePanMayStart = true
                if cancelTarget != nil {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
            }
            let previousCreationProgress = motion.pageCreationProgress
            let previousCancelProgress = motion.newListCancelProgress
            motion.updatePageDrag(
                translation: inwardTranslation,
                selectedPage: model.selectedPage,
                pages: model.pages,
                pageWidth: pageWidth,
                layoutDirection: layoutDirection,
                // The .began event may have no translation; start on its first horizontal update.
                isStart: interactionState.pagePanMayStart,
                cancelTo: cancelTarget,
                at: Date()
            )
            if motion.isDragging { interactionState.pagePanMayStart = false }
            if previousCreationProgress < 1, motion.pageCreationProgress >= 1 {
                model.haptics.emit(.snap, for: model.haptics.beginInteraction())
            }
            if previousCancelProgress < 1, motion.newListCancelProgress >= 1 {
                model.haptics.emit(.snap, for: model.haptics.beginInteraction())
            }
        case .ended:
            interactionState.pagePanMayStart = false
            guard let dragPages = motion.transition?.pages, dragPages == model.pages else {
                motion.interrupt()
                return
            }
            guard let release = motion.releasePageDrag(
                translation: inwardTranslation,
                predictedEndTranslation: direction.clamped(predictedTranslation ?? translation),
                reduceMotion: reduceMotion,
                at: Date()
            ) else { return }
            switch release {
            case .createList:
                break // The completed settlement starts creation in the root view.
            case .cancelNewList:
                break // Cancel after the reverse page settlement finishes.
            case .select(let destination):
                guard dragPages.indices.contains(destination), dragPages[destination] != model.selectedPage else { return }
                model.selectPage(dragPages[destination])
                model.haptics.emit(.selection, for: model.haptics.beginInteraction())
            }
        default:
            interactionState.pagePanMayStart = false
            motion.cancelPageDrag(reduceMotion: reduceMotion, at: Date())
        }
    }

    private func newListSwipeBackTarget(for direction: ListPagePanDirection) -> LibraryPage? {
        let backDirection: ListPagePanDirection = layoutDirection == .rightToLeft ? .left : .right
        let destination = model.newListCancellationPage
        guard direction == backDirection,
              let id = model.newListID,
              model.editingListID == id,
              !model.isListDraftSaving(id: id),
              model.selectedPage == .list(id),
              destination != .list(id), model.pages.contains(destination) else { return nil }
        return destination
    }

    private func canPanPage(direction: ListPagePanDirection) -> Bool {
        let isEditingVisiblePage = model.editingListID.map { $0 == model.selectedPage.listID } ?? false
        guard !(glassMenuPresentation?.isPresented ?? false), !model.isManagingLists, !model.isSearchPresented, sheet == nil,
              (!editMode.isEditing || model.isSelectingSnips),
              !isComposerFocused,
              motion.transition?.settlement == nil,
              !motion.isCreatingFromEdge,
              !motion.isSelectorDragging,
              !swipeBlockingPages.contains(model.selectedPage) else { return false }
        if isEditingVisiblePage { return newListSwipeBackTarget(for: direction) != nil }
        return model.pages.count > 1 && model.pages.contains(model.selectedPage)
    }

}

// Construct content above the motion reader so drag samples update its transform
// without rebuilding the navigation, collection, and action closures inside it.
private struct MountedListPage<Content: View>: Identifiable {
    let id: LibraryPage
    let content: Content
}

/// Translates each page's navigation sublayers without moving its UIView frame,
/// keeping UIKit safe-area insets and large-title layout invariant during swipes.
@MainActor
private final class PageLayerTranslationRegistry {
    private var offsets: [LibraryPage: CGFloat] = [:]
    private var controllers: [LibraryPage: WeakNavigationController] = [:]

    private final class WeakNavigationController {
        weak var value: UINavigationController?
        init(_ value: UINavigationController) { self.value = value }
    }

    func register(_ navigationController: UINavigationController, for page: LibraryPage) {
        if controllers[page]?.value !== navigationController {
            geometryAnnouncedOffsets.removeValue(forKey: page)
        }
        controllers[page] = WeakNavigationController(navigationController)
        apply(offset: offsets[page] ?? 0, to: navigationController)
    }

    func unregister(_ navigationController: UINavigationController?, for page: LibraryPage) {
        guard let navigationController else { return }
        if controllers[page]?.value === navigationController {
            controllers.removeValue(forKey: page)
        }
    }

    func setOffset(_ x: CGFloat, for page: LibraryPage, isSettled: Bool) {
        guard let controller = controllers[page]?.value else {
            offsets[page] = x
            return
        }
        if offsets[page] != x || abs(controller.view.layer.sublayerTransform.m41 - x) >= 0.001 {
            offsets[page] = x
            apply(offset: x, to: controller)
        }
        if isSettled, geometryAnnouncedOffsets[page] != x {
            geometryAnnouncedOffsets[page] = x
            announceGeometryChange(of: controller)
        }
    }

    func prune(keeping pages: Set<LibraryPage>) {
        offsets = offsets.filter { pages.contains($0.key) }
        geometryAnnouncedOffsets = geometryAnnouncedOffsets.filter { pages.contains($0.key) }
        controllers = controllers.filter { pages.contains($0.key) && $0.value.value != nil }
    }

    /// Offsets whose layer translation UIKit has reported as a geometry change.
    private var geometryAnnouncedOffsets: [LibraryPage: CGFloat] = [:]

    /// A sublayer transform moves the page without a UIKit geometry change, so hosted
    /// SwiftUI rows keep the accessibility frames of their last reported position.
    /// Restoring the view's own transform reports the change without moving the view.
    private func announceGeometryChange(of navigationController: UINavigationController) {
        let view: UIView = navigationController.view
        let transform = view.transform
        UIView.performWithoutAnimation {
            view.transform = transform.translatedBy(x: 1, y: 0)
            view.transform = transform
        }
    }

    private func apply(offset x: CGFloat, to navigationController: UINavigationController) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        navigationController.view.layer.sublayerTransform = x == 0
            ? CATransform3DIdentity
            : CATransform3DMakeTranslation(x, 0, 0)
        CATransaction.commit()
    }
}

private struct PageLayerTranslationAnchor: UIViewControllerRepresentable {
    let page: LibraryPage
    let registry: PageLayerTranslationRegistry

    func makeUIViewController(context: Context) -> Controller {
        Controller(page: page, registry: registry)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(page: page, registry: registry)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.detach()
    }

    final class Controller: UIViewController {
        private var page: LibraryPage
        private var registry: PageLayerTranslationRegistry
        private weak var registeredController: UINavigationController?

        init(page: LibraryPage, registry: PageLayerTranslationRegistry) {
            self.page = page
            self.registry = registry
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            sync()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            sync()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            sync()
        }

        func update(page: LibraryPage, registry: PageLayerTranslationRegistry) {
            if self.page != page {
                detach()
                self.page = page
            }
            self.registry = registry
            sync()
        }

        func detach() {
            if let registeredController {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                registeredController.view.layer.sublayerTransform = CATransform3DIdentity
                CATransaction.commit()
            }
            registry.unregister(registeredController, for: page)
            registeredController = nil
        }

        private func sync() {
            guard let navigationController else { return }
            registeredController = navigationController
            registry.register(navigationController, for: page)
        }
    }
}

private struct PageLayerTranslationDriver: UIViewRepresentable {
    let page: LibraryPage
    let x: CGFloat
    let isSettled: Bool
    let registry: PageLayerTranslationRegistry

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        registry.setOffset(x, for: page, isSettled: isSettled)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        registry.setOffset(x, for: page, isSettled: isSettled)
    }
}

private struct ListPageMotionStage<PageContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let state: ListPageMotionState
    let pages: [LibraryPage]
    let selectedPage: LibraryPage
    let width: CGFloat
    let safeArea: EdgeInsets
    let translationRegistry: PageLayerTranslationRegistry
    let content: [MountedListPage<PageContent>]
    let retainedPagesChanged: ([LibraryPage]) -> Void

    var body: some View {
        ListPageFrameReader(state: state, pages: pages, selectedPage: selectedPage) { frame in
            let motion = state.value
            let creationCueProgress = frame.creationProgress(
                dragProgress: motion.pageCreationProgress,
                holdsAtAdd: motion.isCreatingFromEdge || motion.transition?.settlement?.createsList == true
            )
            let cancelSource = frame.directEntrance?.source ?? frame.pages.last
            // Layers: destination, cancel source, then cues. Cues draw over their page's
            // safe-area margin, which a full-width page covers.
            ZStack {
                if !reduceMotion, creationCueProgress > 0, frame.directEntrance == nil {
                    edgeCue(kind: .add, progress: creationCueProgress, offset: frame.pages.last.map {
                        frame.offset(for: $0, width: width, layoutDirection: layoutDirection, reduceMotion: reduceMotion)
                    } ?? 0)
                    .zIndex(2)
                }
                if !reduceMotion, frame.edgeCancelProgress > 0 {
                    edgeCue(kind: .cancel, progress: frame.edgeCancelProgress, offset: cancelSource.map {
                        frame.offset(for: $0, width: width, layoutDirection: layoutDirection, reduceMotion: reduceMotion)
                    } ?? 0)
                    .zIndex(2)
                }
                ForEach(content) { page in
                    let isRetained = frame.retainedPages.contains(page.id)
                    let pageOffset = isRetained ? frame.offset(
                        for: page.id, width: width,
                        layoutDirection: layoutDirection, reduceMotion: reduceMotion
                    ) : width * 2
                    page.content
                        .background {
                            PageLayerTranslationDriver(
                                page: page.id, x: pageOffset, isSettled: !frame.isMoving,
                                registry: translationRegistry
                            )
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                        }
                        .opacity(isRetained ? frame.opacity(for: page.id, reduceMotion: reduceMotion) : 0)
                        .accessibilityHidden(frame.isMoving || page.id != selectedPage)
                        // Native bars reach outside the page clip. Keep their slots mounted,
                        // but hide the controls until the selected page has settled.
                        .environment(
                            \.showsPageToolbar,
                            !frame.isMoving && page.id == selectedPage
                        )
                        .disabled(!isRetained)
                        .allowsHitTesting(!frame.isMoving && page.id == selectedPage)
                        .zIndex(!reduceMotion && frame.edgeCancelProgress > 0 && page.id == cancelSource ? 1 : 0)
                }
            }
            .onChange(of: frame.retainedPages, initial: true) { _, pages in
                retainedPagesChanged(pages)
            }
        }
    }

    private func edgeCue(kind: ListEdgeCueLayout.Kind, progress: CGFloat, offset: CGFloat) -> some View {
        let stretch = ListEdgeCueLayout.stretch(progress: progress)
        let armed = progress >= 1
        return GeometryReader { proxy in
            Image(systemName: kind == .add ? "plus" : "xmark")
                .font(.system(size: 30, weight: .semibold))
                .frame(width: ListAddCueLayout.diameter + stretch, height: ListAddCueLayout.diameter)
                .background(Color.primary.opacity(0.10), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                .scaleEffect(armed ? ListAddCueLayout.armedScale : 1)
                .animation(.spring(duration: 0.24, bounce: 0.22), value: armed)
                .opacity(Double(min(1, progress * 1.5)))
                .position(
                    x: ListEdgeCueLayout.centerX(
                        for: kind, in: proxy.size.width, progress: progress,
                        layoutDirection: layoutDirection
                    ),
                    y: proxy.size.height / 2
                )
        }
        // Anchor and clip to the fixed safe rectangle, so a cue slides in from the safe edge
        // as it does from a zero-inset screen edge. `position` ignores the safe area.
        .offset(x: offset)
        .clipped()
        .padding(safeArea)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

}
