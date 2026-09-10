import SnipSnapCore
import SwiftUI

enum PanelTabPage: Hashable {
    case clipboard
    case list(UUID)

    var listID: UUID? {
        if case .list(let id) = self { id } else { nil }
    }

    static func ordered(lists: [SnipList]) -> [Self] {
        [.clipboard] + lists.map { .list($0.id) }
    }

    func precedes(_ other: Self, in pages: [Self]) -> Bool {
        guard let source = pages.firstIndex(of: self),
              let destination = pages.firstIndex(of: other) else { return false }
        return source < destination
    }
}

/// Owns tab motion while the caller owns the contents and per-list drafts.
struct PanelTabPager<Page: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let selectedPage: PanelTabPage
    let pages: [PanelTabPage]
    var animatesChanges = true
    var onSelectionChange: () -> Void = {}
    @ViewBuilder let page: (PanelTabPage, Bool) -> Page

    @State private var displayedPages: [PanelTabPage] = []
    @State private var offsets: [PanelTabPage: CGFloat] = [:]
    @State private var opacities: [PanelTabPage: Double] = [:]
    @State private var movesForward = true
    @State private var isTransitioning = false
    @State private var transitionID = UUID()

    private var renderedPages: [PanelTabPage] {
        displayedPages.isEmpty ? [selectedPage] : displayedPages
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: movesForward ? .trailing : .leading),
            removal: .move(edge: movesForward ? .leading : .trailing)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(renderedPages, id: \.self) { identity in
                    page(identity, !isTransitioning && identity == selectedPage)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .offset(x: reduceMotion ? 0 : (offsets[identity] ?? 0) * geometry.size.width)
                        .opacity(opacities[identity] ?? 1)
                        .transition(transition)
                        .allowsHitTesting(!isTransitioning && identity == selectedPage)
                        .disabled(isTransitioning || identity != selectedPage)
                        .accessibilityHidden(identity != selectedPage)
                }
            }
        }
        .onAppear { displayedPages = [selectedPage] }
        .onChange(of: selectedPage) { source, target in
            guard source != target else { return }
            onSelectionChange()
            let request = UUID()
            transitionID = request
            guard animatesChanges, pages.contains(source), pages.contains(target) else {
                displayedPages = [target]
                offsets = [:]
                opacities = [:]
                isTransitioning = false
                return
            }
            movesForward = source.precedes(target, in: pages)
            isTransitioning = true
            let animation: Animation = reduceMotion
                ? .easeOut(duration: 0.16)
                : .easeInOut(duration: 0.24)
            withAnimation(animation, completionCriteria: .removed) {
                if !displayedPages.contains(target) { displayedPages.append(target) }
                for identity in displayedPages {
                    let side: CGFloat = identity.precedes(target, in: pages) ? -1 : 1
                    offsets[identity] = identity == target ? 0
                        : side * (layoutDirection == .rightToLeft ? -1 : 1)
                    opacities[identity] = reduceMotion && identity != target ? 0 : 1
                }
            } completion: {
                guard transitionID == request else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    displayedPages = [target]
                    offsets = [:]
                    opacities = [:]
                    isTransitioning = false
                }
            }
        }
        .onDisappear {
            transitionID = UUID()
            isTransitioning = false
        }
    }
}
