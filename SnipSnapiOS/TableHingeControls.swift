import SwiftUI

extension View {
    /// Places controls in the bottom safe area. When a horizontal hinge divides the view,
    /// as in a partly folded device's table pose, the view stays above the hinge and the
    /// controls move below it.
    func tableHingeControls<Controls: View>(
        @ViewBuilder _ controls: () -> Controls
    ) -> some View {
        modifier(TableHingeControls(controls: controls()))
    }
}

private struct TableHingeControls<Controls: View>: ViewModifier {
    let controls: Controls
    @State private var isTablePose = false

    private var splitAxes: Axis.Set { isTablePose ? .vertical : [] }

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            // The split style halves the space even without a hinge, so it splits only
            // across an active horizontal division. The arrangement stays in place either
            // way, so the page keeps its identity across folds.
            ArrangementView {
                content.safeAreaInset(edge: .bottom, spacing: 0) {
                    if !isTablePose { controls }
                }
            } secondary: {
                if isTablePose { controls }
            }
            .arrangementViewStyle(SplitArrangementViewStyle().axes(splitAxes))
            // Keyboard avoidance re-arranges the split and ends editing, so in the table pose
            // the keyboard rises over the bottom half and the controls stay under the hinge.
            .ignoresSafeArea(.keyboard, edges: isTablePose ? .all : [])
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.reservedRegions(kind: .division).contains { $0.frame.width > $0.frame.height }
            } action: { isTablePose = $0 }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) { controls }
        }
    }
}
