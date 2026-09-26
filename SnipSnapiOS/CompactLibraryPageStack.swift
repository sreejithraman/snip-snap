import SnipSnapCore
import SwiftUI
import UIKit

struct CompactLibraryPageStack: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var swipeBlockingPages: Set<LibraryPage> = []
    @State private var pagePanMayStart = false
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
    let cancelNewList: (UUID) async -> Bool
    let libraryActions: LibraryActionsMenu

    var body: some View {
        GeometryReader { proxy in
            let creationCueProgress = frame.creationProgress(
                dragProgress: motion.pageCreationProgress,
                holdsAtAdd: motion.isCreatingFromEdge || motion.transition?.settlement?.createsList == true
            )
            ZStack {
                if creationCueProgress > 0,
                   (frame.directEntrance?.showsAddCue == true
                    || frame.pages.last.map({ frame.weight(for: $0) > 0.95 }) == true) {
                    edgeCue(systemImage: "plus", progress: creationCueProgress, atLeadingEdge: false)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .zIndex(1)
                }
                if frame.edgeCancelProgress > 0 {
                    edgeCue(systemImage: "xmark", progress: frame.edgeCancelProgress, atLeadingEdge: true)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .zIndex(1)
                }
                ForEach(frame.retainedPages, id: \.self) { page in
                    libraryPage(page, isActivePage: page == model.selectedPage)
                        .offset(x: frame.offset(
                            for: page, width: proxy.size.width,
                            layoutDirection: layoutDirection, reduceMotion: reduceMotion
                        ))
                        .opacity(frame.opacity(for: page, reduceMotion: reduceMotion))
                        .accessibilityHidden(page != model.selectedPage)
                        .disabled(frame.isMoving || page != model.selectedPage)
                        .allowsHitTesting(!frame.isMoving && page == model.selectedPage)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .background {
                ListPagePanObserver(
                    canBegin: { direction in canPanPage(direction: direction) },
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
    }

    private func edgeCue(systemImage: String, progress: CGFloat, atLeadingEdge: Bool) -> some View {
        let stretch = reduceMotion ? 0 : 32 * sin(.pi * progress)
        let edgeInset = 42 + stretch / 2
        let armed = progress >= 1
        return GeometryReader { proxy in
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 56 + stretch, height: 56)
                .background(Color.primary.opacity(0.10), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                .scaleEffect(reduceMotion ? 1 : armed ? 1.06 : 1)
                .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.22), value: armed)
                .opacity(Double(min(1, progress * 1.5)))
                .position(
                    x: (layoutDirection == .rightToLeft) == atLeadingEdge
                        ? proxy.size.width - edgeInset : edgeInset,
                    y: proxy.size.height / 2
                )
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
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
                        cancelNewList: cancelNewList,
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

    private func handlePagePan(
        direction: ListPagePanDirection,
        translation: CGSize,
        predictedTranslation: CGSize?,
        phase: UIGestureRecognizer.State,
        pageWidth: CGFloat
    ) {
        guard canPanPage(direction: direction) else {
            if phase != .began {
                pagePanMayStart = false
                motion.cancelPageDrag(reduceMotion: reduceMotion, at: Date())
            }
            return
        }
        let inwardTranslation = direction.clamped(translation)
        let cancelTarget = newListSwipeBackTarget(for: direction)
        switch phase {
        case .began, .changed:
            if phase == .began {
                pagePanMayStart = true
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
                isStart: pagePanMayStart,
                cancelTo: cancelTarget,
                at: Date()
            )
            if motion.isDragging { pagePanMayStart = false }
            if previousCreationProgress < 1, motion.pageCreationProgress >= 1 {
                model.haptics.emit(.snap, for: model.haptics.beginInteraction())
            }
            if previousCancelProgress < 1, motion.newListCancelProgress >= 1 {
                model.haptics.emit(.snap, for: model.haptics.beginInteraction())
            }
        case .ended:
            pagePanMayStart = false
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
            pagePanMayStart = false
            motion.cancelPageDrag(reduceMotion: reduceMotion, at: Date())
        }
    }

    private func newListSwipeBackTarget(for direction: ListPagePanDirection) -> LibraryPage? {
        let backDirection: ListPagePanDirection = layoutDirection == .rightToLeft ? .left : .right
        guard direction == backDirection,
              let id = model.newListID,
              model.editingListID == id,
              !model.isListDraftSaving(id: id),
              model.selectedPage == .list(id),
              let origin = model.newListOriginPage,
              origin != .list(id), model.pages.contains(origin) else { return nil }
        return origin
    }

    private func canPanPage(direction: ListPagePanDirection) -> Bool {
        let isEditingVisiblePage = model.editingListID.map { $0 == model.selectedPage.listID } ?? false
        guard !model.isSearchPresented, sheet == nil, !editMode.isEditing,
              !isComposerFocused,
              motion.transition?.settlement == nil,
              !motion.isCreatingFromEdge,
              !motion.isSelectorDragging,
              !swipeBlockingPages.contains(model.selectedPage) else { return false }
        if isEditingVisiblePage { return newListSwipeBackTarget(for: direction) != nil }
        return model.pages.count > 1 && model.pages.contains(model.selectedPage)
    }

}
