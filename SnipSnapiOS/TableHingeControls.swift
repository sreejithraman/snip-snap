import SwiftUI

extension View {
    /// Places controls in the bottom safe area. When a horizontal hinge divides the view,
    /// as in a partly folded device's table pose, the view ends above the hinge and the
    /// controls start below it. Pass `splitsAtHinge: false` when the controls have nothing
    /// to show below the hinge, so the view fills the window as it does unfolded.
    func tableHingeControls<Controls: View>(
        splitsAtHinge: Bool = true,
        @ViewBuilder _ controls: () -> Controls
    ) -> some View {
        modifier(TableHingeControls(splitsAtHinge: splitsAtHinge, controls: controls()))
    }
}

/// Where a horizontal hinge splits a view, in that view's local coordinates.
private struct TableHinge: Equatable {
    /// The page's safe area ends here, at the hinge's top edge.
    let pageBottom: CGFloat
    /// The controls start here, at the hinge's bottom edge.
    let controlsTop: CGFloat
    /// The view's height.
    let height: CGFloat

    /// Returns nil unless `division` is a horizontal band that lies inside the view.
    /// The Duo reports a division's margins inside its frame (20 + 20 pt on a 40-pt frame),
    /// so the frame alone bounds the fold.
    init?(division: CGRect, height: CGFloat) {
        guard division.width > division.height,
              division.minY > 0, division.maxY < height else { return nil }
        pageBottom = division.minY
        controlsTop = division.maxY
        self.height = height
    }

    var insetHeight: CGFloat { height - pageBottom }
}

private struct TableHingeControls<Controls: View>: ViewModifier {
    let splitsAtHinge: Bool
    let controls: Controls
    @State private var hinge: TableHinge?

    // Gated here rather than in the geometry read, which reruns on geometry changes, not when
    // only `splitsAtHinge` changes.
    private var activeHinge: TableHinge? { splitsAtHinge ? hinge : nil }

    func body(content: Content) -> some View {
        // The controls keep one place in the tree in every pose, so a fold moves them
        // without rebuilding them or dismissing what they present.
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controls
                    .padding(.top, activeHinge.map { $0.controlsTop - $0.pageBottom } ?? 0)
                    .frame(height: activeHinge?.insetHeight, alignment: .top)
                    .background {
                        // Page rows scroll under the inset; keep them off the hinge and the bottom half.
                        Rectangle()
                            .fill(.background)
                            .ignoresSafeArea(edges: .bottom)
                            .opacity(activeHinge == nil ? 0 : 1)
                            .allowsHitTesting(activeHinge != nil)
                            .accessibilityHidden(true)
                    }
            }
            .onGeometryChange(for: TableHinge?.self) { proxy in
                guard #available(iOS 27.1, *) else { return nil }
                return proxy.reservedRegions(kind: .division).lazy
                    .compactMap { TableHinge(division: $0.frame, height: proxy.size.height) }
                    .first
            } action: { hinge = $0 }
            // In the table pose the keyboard rises over the bottom half and the controls stay
            // under the hinge. The read above sits inside this, so it measures the same
            // keyboard-free frame the inset is laid out in.
            .ignoresSafeArea(.keyboard, edges: activeHinge == nil ? [] : .all)
    }
}
