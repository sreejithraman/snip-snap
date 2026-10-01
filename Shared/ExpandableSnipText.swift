import SnipSnapCore
import SwiftUI

/// Measures only the bounded preview until the reader asks for the full snip.
struct ExpandableSnipText: View {
    let text: String
    let lineLimit: Int
    var isDone = false
    var strikethroughColor: Color? = nil
    var lineSpacing: CGFloat = 0
    var allowsExpansion = true
    var accessibilityIdentifier = ""
    var onActivate: (_ isPointerClick: Bool) -> Bool = { _ in true }
    var onDoubleClick: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var limitedHeight: CGFloat = 0
    @State private var previewHeight: CGFloat = 0
#if os(iOS)
    @State private var keepsFullText = false
    @State private var expansionID = UUID()
#endif

    private var preview: String {
        let boundedText = SnipTextPreview.displayText(text, lineLimit: lineLimit)
        return boundedText == text ? boundedText : boundedText + "…"
    }

    private var canExpand: Bool {
        allowsExpansion && (preview != text || previewHeight > limitedHeight + 1)
    }

    var body: some View {
        Group {
            if canExpand || isExpanded {
                Button(action: { toggleExpansion(isPointerClick: false) }) {
#if os(iOS)
                    ExpandingSnipTextLayout(collapsedHeight: limitedHeight, expansion: isExpanded ? 1 : 0) {
                        snipText(keepsFullText ? text : preview)
                            .lineLimit(keepsFullText ? nil : lineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                            .transaction { $0.animation = nil }
                    }
                    .clipped()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
#else
                    snipText(isExpanded ? text : preview)
                        .lineLimit(isExpanded ? nil : lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
#endif
                }
                .buttonStyle(.plain)
#if os(macOS)
                // The card also selects on click; text clicks belong to this control.
                .highPriorityGesture(
                    TapGesture(count: 2).onEnded { onDoubleClick?() }
                        .exclusively(before: TapGesture().onEnded { toggleExpansion(isPointerClick: true) })
                )
#endif
                .accessibilityLabel(text)
                .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
                .accessibilityHint(isExpanded ? Text("Collapse snip") : Text("Show full snip"))
                .accessibilityIdentifier(accessibilityIdentifier)
            } else {
                snipText(preview)
                    .lineLimit(lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(alignment: .topLeading) {
            // Both probes keep the same width and typography as the visible text.
            // Measuring the original could lay out megabytes of offscreen text.
            snipText(preview)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { limitedHeight = $0 }
                .overlay(alignment: .topLeading) {
                    snipText(preview)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                }
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onChange(of: text) { resetExpansion() }
        .onChange(of: allowsExpansion) { _, allowed in
            if !allowed { resetExpansion() }
        }
    }

    private func snipText(_ value: String) -> some View {
        Text(value)
            .strikethrough(isDone, color: strikethroughColor)
            .lineSpacing(lineSpacing)
    }

    private func toggleExpansion(isPointerClick: Bool) {
        guard onActivate(isPointerClick) else { return }
#if os(iOS)
        let currentExpansionID = UUID()
        expansionID = currentExpansionID
        keepsFullText = true
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18), completionCriteria: .removed) {
            isExpanded.toggle()
        } completion: {
            guard expansionID == currentExpansionID, !isExpanded else { return }
            keepsFullText = false
        }
#else
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
            isExpanded.toggle()
        }
#endif
    }

    private func resetExpansion() {
        isExpanded = false
#if os(iOS)
        expansionID = UUID()
        keepsFullText = false
#endif
    }
}

#if os(iOS)
/// Interpolate the row's height instead of replacing two intrinsic text sizes.
/// The text stays at the top, and full text is retained until collapse finishes.
private struct ExpandingSnipTextLayout: Layout {
    let collapsedHeight: CGFloat
    var expansion: CGFloat

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let size = text.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        guard collapsedHeight > 0 else { return size }
        let height = collapsedHeight + max(0, size.height - collapsedHeight) * min(max(expansion, 0), 1)
        return CGSize(width: size.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}
#endif
