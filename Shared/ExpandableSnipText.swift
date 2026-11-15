import SnipSnapCore
import SwiftUI

private enum SnipTextExpansion: Equatable {
    case closed
    case opening(UUID)
    case open
    case closing(UUID)

    var isExpanded: Bool {
        switch self {
        case .opening, .open: true
        case .closed, .closing: false
        }
    }

    /// iOS keeps the full text laid out until the collapse finishes, so it can clip it closed.
    var keepsFullText: Bool { self != .closed }
}

struct ExpandableSnipText: View {
    let content: SnipTextContent
    let lineLimit: Int
    var isDone = false
    var strikethroughColor: Color? = nil
    var lineSpacing: CGFloat = 0
    var allowsExpansion = true
    var accessibilityIdentifier = ""
    var onActivate: (_ isPointerClick: Bool) -> Bool = { _ in true }
    var onDoubleClick: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expansion = SnipTextExpansion.closed
    @State private var limitedHeight: CGFloat = 0
    @State private var previewHeight: CGFloat = 0

    var body: some View {
        let presentation = content.presentation(lineLimit: lineLimit)
        let canExpand = allowsExpansion && !presentation.isLoading
            && (presentation.isTruncated || previewHeight > limitedHeight + 1)
        let isExpanded = expansion.isExpanded
        Group {
            if canExpand || isExpanded {
                Button(action: { toggleExpansion(isPointerClick: false) }) {
#if os(iOS)
                    ExpandingSnipTextLayout(collapsedHeight: limitedHeight, expansion: isExpanded ? 1 : 0) {
                        snipText(expansion.keepsFullText ? presentation.fullText : presentation.preview)
                            .lineLimit(expansion.keepsFullText ? nil : lineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                            .transaction { $0.animation = nil }
                    }
                    .clipped()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
#else
                    snipText(isExpanded ? presentation.fullText : presentation.preview)
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
                .accessibilityLabel(Text(presentation.accessibilityText))
                .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
                .accessibilityHint(isExpanded ? Text("Collapse text") : Text("Show full text"))
                .accessibilityIdentifier(accessibilityIdentifier)
            } else {
                snipText(presentation.preview)
                    .lineLimit(lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(alignment: .topLeading) {
            // Both probes keep the same width and typography as the visible text.
            // Measuring the original could lay out megabytes of offscreen text.
            snipText(presentation.preview)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { limitedHeight = $0 }
                .overlay(alignment: .topLeading) {
                    snipText(presentation.preview)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                }
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onChange(of: content.source) { resetExpansion() }
        .onChange(of: allowsExpansion) { _, allowed in
            if !allowed { resetExpansion() }
        }
    }

    private func snipText(_ value: AttributedString) -> some View {
        let text = Text(value)
        return (isDone ? text.strikethrough(color: strikethroughColor) : text)
            .lineSpacing(lineSpacing)
    }

    // On iOS the full text swaps in inside this animated write. Its `.transaction`
    // drops the animation, so only the reveal height animates.
    private func toggleExpansion(isPointerClick: Bool) {
        guard onActivate(isPointerClick) else { return }
        let token = UUID()
        let phase: SnipTextExpansion = expansion.isExpanded ? .closing(token) : .opening(token)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18), completionCriteria: .removed) {
            expansion = phase
        } completion: {
            settleExpansion(after: phase)
        }
    }

    private func settleExpansion(after phase: SnipTextExpansion) {
        guard expansion == phase else { return }
        expansion = phase.isExpanded ? .open : .closed
    }

    private func resetExpansion() {
        expansion = .closed
    }
}

#if os(iOS)
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
