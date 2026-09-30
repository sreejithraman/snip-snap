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
            let lastPageOffset = frame.pages.last.map {
                frame.offset(for: $0, width: proxy.size.width,
                             layoutDirection: layoutDirection, reduceMotion: reduceMotion)
            } ?? 0
            let cancelSource = frame.directEntrance?.source ?? frame.pages.last
            let cancelSourceOffset = cancelSource.map {
                frame.offset(for: $0, width: proxy.size.width,
                             layoutDirection: layoutDirection, reduceMotion: reduceMotion)
            } ?? 0
            ZStack {
                // The incoming page covers this space during a direct entrance.
                if !reduceMotion, creationCueProgress > 0, frame.directEntrance == nil {
                    edgeCue(kind: .add, progress: creationCueProgress)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .offset(x: lastPageOffset)
                }
                if !reduceMotion, frame.edgeCancelProgress > 0 {
                    edgeCue(kind: .cancel, progress: frame.edgeCancelProgress)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .offset(x: cancelSourceOffset)
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
                        .zIndex(!reduceMotion && frame.edgeCancelProgress > 0 && page == cancelSource ? 2 : 0)
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

    private func edgeCue(kind: ListEdgeCueLayout.Kind, progress: CGFloat) -> some View {
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
                        syncedContentSettings: libraryActions.syncedContentSettings,
                        syncNow: libraryActions.syncNow,
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
