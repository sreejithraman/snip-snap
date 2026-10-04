import SwiftUI

private enum PanelContentCardMetrics {
    static let cornerRadius: CGFloat = 14
}

enum PanelCardLeadingMetrics {
    static let side: CGFloat = 24
    static let controlSide: CGFloat = 20
}

/// Filled chip chrome shared by every control in a card's leading slot, so the
/// slot keeps one look when its control swaps between copy and a command number.
struct PanelLeadingChip<Content: View>: View {
    @Environment(\.self) private var environment
    private let appearance: SnipListAppearance?
    private let content: Content

    init(appearance: SnipListAppearance? = nil, @ViewBuilder content: () -> Content) {
        self.appearance = appearance
        self.content = content()
    }

    var body: some View {
        ZStack {
            shape.fill(appearance?.controlTint ?? SnipSnapTheme.compactActionFill)
            content.foregroundStyle(appearance.map { AnyShapeStyle($0.filledControlLabel(in: environment)) } ?? SnipSnapColors.textPrimary)
        }
        .frame(
            width: PanelCardLeadingMetrics.side,
            height: PanelCardLeadingMetrics.side
        )
        .contentShape(shape)
        .clipShape(shape)
    }

    private var shape: Circle {
        Circle()
    }
}

struct PanelCopyButton: View {
    let isCopied: Bool
    var isPinned = false
    var appearance: SnipListAppearance? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isPinned, let appearance {
                Image(systemName: isCopied ? "checkmark.circle.fill" : "pin.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(appearance.controlTint)
                    .frame(width: PanelCardLeadingMetrics.side, height: PanelCardLeadingMetrics.side)
                    .contentShape(Circle())
            } else {
                PanelLeadingChip(appearance: appearance) {
                    Image(systemName: isCopied ? "checkmark" : (isPinned ? "pin.fill" : "doc.on.doc"))
                        .font(.system(size: 10, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(isCopied ? "Copied" : (isPinned ? "Copy Pinned Snip" : "Copy"))
        .accessibilityLabel(isCopied ? "Copied" : (isPinned ? "Copy Pinned Snip" : "Copy"))
    }
}

struct PanelCommandNumberButton: View {
    let number: Int
    var isPinned = false
    var appearance: SnipListAppearance? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelLeadingChip(appearance: appearance) {
                Text(String(number))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .overlay(alignment: .bottomTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7, weight: .semibold))
                        .padding(2)
                        .background(.background, in: Circle())
                        .offset(x: 3, y: 3)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPinned
            ? String(localized: "Copy Pinned Snip \(number)")
            : String(localized: "Copy \(number)"))
    }
}

/// The copy chip and its command-number stand-in, swapping in one leading slot.
/// A running copy confirmation keeps the chip visible and stands the number down.
struct PanelCopySlot: View {
    let isCopied: Bool
    var isPinned = false
    var appearance: SnipListAppearance? = nil
    let commandNumber: Int?
    let copy: () -> Void
    let onPickCommandNumber: () -> Void

    var body: some View {
        if let commandNumber, !isCopied {
            PanelCommandNumberButton(
                number: commandNumber,
                isPinned: isPinned,
                appearance: appearance,
                action: onPickCommandNumber
            )
        } else {
            PanelCopyButton(isCopied: isCopied, isPinned: isPinned, appearance: appearance, action: copy)
        }
    }
}

struct PanelContentCardState: Equatable {
    var isSelected = false
    var isSubdued = false
}

struct PanelContentCard<Leading: View, Main: View>: View {
    let state: PanelContentCardState
    let alignment: VerticalAlignment
    private let hasLeading: Bool
    private let leading: Leading
    private let main: Main

    init(
        state: PanelContentCardState = .init(),
        alignment: VerticalAlignment = .top,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder main: () -> Main
    ) {
        self.state = state
        self.alignment = alignment
        hasLeading = true
        self.leading = leading()
        self.main = main()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: SnipSnapSpacing.relatedContent) {
            if hasLeading {
                leading
                    .frame(
                        width: PanelCardLeadingMetrics.side,
                        height: PanelCardLeadingMetrics.side,
                        alignment: .center
                    )
            }

            main
                .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(SnipSnapSpacing.cardContentInset)
        .background {
            shape
                .fill(.regularMaterial)
                .overlay {
                    if state.isSelected {
                        shape.fill(SnipSnapTheme.selectionFill)
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        edge.color,
                        lineWidth: edge.width
                    )
                }
                .shadow(
                    color: SnipSnapColors.contentCardShadow(isSelected: state.isSelected),
                    radius: state.isSelected ? 8 : 7,
                    y: 3
                )
        }
        .contentShape(shape)
        .opacity(state.isSubdued ? SnipSnapColors.doneCardOpacity : 1)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PanelContentCardMetrics.cornerRadius,
            style: .continuous
        )
    }

    private var edge: PanelEdgeStyle {
        state.isSelected ? .selected : .content
    }
}

extension PanelContentCard where Leading == EmptyView {
    init(
        state: PanelContentCardState = .init(),
        alignment: VerticalAlignment = .top,
        @ViewBuilder main: () -> Main
    ) {
        self.state = state
        self.alignment = alignment
        hasLeading = false
        leading = EmptyView()
        self.main = main()
    }
}
