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
                    snipText(isExpanded ? text : preview)
                        .lineLimit(isExpanded ? nil : lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
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
        .onChange(of: text) { isExpanded = false }
        .onChange(of: allowsExpansion) { _, allowed in
            if !allowed { isExpanded = false }
        }
    }

    private func snipText(_ value: String) -> some View {
        Text(value)
            .strikethrough(isDone, color: strikethroughColor)
            .lineSpacing(lineSpacing)
    }

    private func toggleExpansion(isPointerClick: Bool) {
        guard onActivate(isPointerClick) else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
            isExpanded.toggle()
        }
    }
}
