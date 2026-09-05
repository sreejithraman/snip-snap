import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum PanelControlMetrics {
    static let floatingRowHeight: CGFloat = 40
    static let floatingIconLength: CGFloat = 18
    static let regularControlLength: CGFloat = 32
    static let compactComposerHeight = regularControlLength
    static let compactControlLength = regularControlLength
    static let tabSelectionInset: CGFloat = 4
    static let compactSelectionWidth: CGFloat = 40
    static let compactSelectionHeight = floatingRowHeight - tabSelectionInset * 2
    static let actionIconLength: CGFloat = 12
    static let sendInset: CGFloat = 4
    static let actionHeight = compactComposerHeight - sendInset * 2
    static let actionWidth = actionHeight + actionIconLength
    static let inlineEntryInset: CGFloat = 4
    static let inlineEntryBaseHeight = compactComposerHeight + inlineEntryInset * 2
    static let expandedInputVerticalPadding = SnipSnapSpacing.relatedContent

    static let tabItemWidth = compactSelectionWidth + tabSelectionInset * 2
}

enum PanelShapeMetrics {
    static let paneCornerRadius: CGFloat = 20
    static let listHeaderCornerRadius = paneCornerRadius
    static let expandedInputCornerRadius: CGFloat = 14
}

enum PanelListMetrics {
    static let horizontalContentInset = SnipSnapSpacing.paneContentInset
    static let rowSpacing = SnipSnapSpacing.relatedContent
    static let listSpacing = SnipSnapSpacing.paneContentInset
    static let verticalContentInset: CGFloat = 12
    static let compactVerticalContentInset: CGFloat = 10

    static let rowInsets = EdgeInsets(
        top: 0,
        leading: horizontalContentInset,
        bottom: 0,
        trailing: horizontalContentInset
    )

}

enum PanelComposerMetrics {
    static let minimumTextLines = 1
    static let maximumTextLines = 5
    static let textLineRange = minimumTextLines...maximumTextLines
    static let textLineSpacing: CGFloat = 0
    static let maximumTextInputHeight = PanelTextInputLayout.maximumHeight(
        lineRange: textLineRange,
        lineSpacing: textLineSpacing
    )
    static let maximumTextRowHeight = maximumTextInputHeight
        + PanelControlMetrics.expandedInputVerticalPadding * 2
    static let maximumAttachmentRowHeight = AttachmentPreviewMetrics.side
        + AttachmentPreviewMetrics.removeButtonOverflow * 2
        + PanelControlMetrics.expandedInputVerticalPadding
    static let maximumInlineEntryHeight = maximumTextRowHeight
        + maximumAttachmentRowHeight
        + SnipSnapSpacing.relatedContent
        + PanelControlMetrics.inlineEntryInset * 2
}

enum PanelInlineEditMetrics {
    static let minimumTextLines = 2
    static let maximumTextLines = PanelComposerMetrics.maximumTextLines
    static let textLineRange = minimumTextLines...maximumTextLines
}

enum PanelOverlayLayout {
    static let listBaseBottomPadding: CGFloat = 10

    static func listBottomPadding(composerHeight: CGFloat) -> CGFloat {
        listBaseBottomPadding + max(composerHeight, 0)
    }
}

enum PanelGeometryChange {
    static let minimumMeaningfulChange: CGFloat = 0.5

    static func shouldApply(current: CGFloat, proposed: CGFloat) -> Bool {
        abs(current - proposed) >= minimumMeaningfulChange
    }
}

enum PanelComposerLayout {
    static func clampedEntryHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return PanelControlMetrics.inlineEntryBaseHeight }
        return min(max(height, 0), PanelComposerMetrics.maximumInlineEntryHeight)
    }

    static func actionAlignment(isExpanded: Bool) -> VerticalAlignment {
        isExpanded ? .top : .center
    }

    static func isExpanded(fieldHeight: CGFloat) -> Bool {
        fieldHeight > PanelControlMetrics.compactComposerHeight
            + PanelGeometryChange.minimumMeaningfulChange
    }
}

enum PinnedListHeaderSurface {
    static func isVisible(hasScrolledFromTop: Bool, headerMinY: CGFloat) -> Bool {
        hasScrolledFromTop
            && headerMinY <= PanelGeometryChange.minimumMeaningfulChange
    }
}

struct PanelListHeader<Actions: View>: View {
    let title: String
    let hasScrolledFromTop: Bool
    private let actions: Actions

    private var backgroundShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: PanelShapeMetrics.listHeaderCornerRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: PanelShapeMetrics.listHeaderCornerRadius,
            style: .continuous
        )
    }

    init(
        _ title: String,
        hasScrolledFromTop: Bool,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.hasScrolledFromTop = hasScrolledFromTop
        self.actions = actions()
    }

    var body: some View {
        let showsPinnedSurface = hasScrolledFromTop
        HStack(spacing: SnipSnapSpacing.relatedContent) {
            Text(title)
                .font(.headline)
                .foregroundStyle(SnipSnapColors.textPrimary)
            Spacer(minLength: SnipSnapSpacing.relatedContent)
            actions
        }
        .buttonStyle(.borderless)
        .padding(
            .horizontal,
            PanelListMetrics.horizontalContentInset + SnipSnapSpacing.relatedContent
        )
        .frame(
            maxWidth: .infinity,
            minHeight: PanelControlMetrics.floatingRowHeight,
            alignment: .leading
        )
        .background {
            backgroundShape
                .fill(.clear)
                .glassEffect(
                    .regular.tint(SnipSnapColors.nestedGlassTint),
                    in: backgroundShape
                )
                .visualEffect { content, proxy in
                    content.opacity(
                        PinnedListHeaderSurface.isVisible(
                            hasScrolledFromTop: showsPinnedSurface,
                            headerMinY: proxy.frame(
                                in: .scrollView(axis: .vertical)
                            ).minY
                        ) ? 1 : 0
                    )
                }
                .allowsHitTesting(false)
            PanelDragRegion()
        }
    }
}

extension PanelListHeader where Actions == EmptyView {
    init(_ title: String, hasScrolledFromTop: Bool) {
        self.init(title, hasScrolledFromTop: hasScrolledFromTop) { EmptyView() }
    }
}

enum PanelEdgeThickness {
    static let subtle: CGFloat = 0.5
    static let regular: CGFloat = 0.75
    static let strong: CGFloat = 1
    static let prominent: CGFloat = 1.5
}

struct PanelEdgeStyle: Equatable {
    let color: Color
    let width: CGFloat

    static let hidden = PanelEdgeStyle(color: .clear, width: 0)
    static let content = PanelEdgeStyle(
        color: SnipSnapColors.contentCardEdge,
        width: PanelEdgeThickness.regular
    )
    static let media = PanelEdgeStyle(
        color: SnipSnapColors.attachmentEdge,
        width: PanelEdgeThickness.regular
    )
    static let selected = PanelEdgeStyle(
        color: SnipSnapColors.selectionEdge,
        width: PanelEdgeThickness.strong
    )
    static let dropTarget = PanelEdgeStyle(
        color: SnipSnapColors.dropTargetEdge,
        width: PanelEdgeThickness.prominent
    )
}

extension View {
    func panelControlBaseline() -> some View {
        controlSize(.regular)
    }

    func panelInputStyle() -> some View {
        modifier(PanelInputModifier())
    }

    func panelInputSurface(
        height: CGFloat = PanelControlMetrics.regularControlLength,
        expanded: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: expanded ? PanelShapeMetrics.expandedInputCornerRadius : height / 2,
            style: .continuous
        )
        return frame(height: height)
            .panelGlassSurface(in: shape)
            .contentShape(shape)
    }

    func panelStandaloneActionControl(
        length: CGFloat = PanelControlMetrics.compactControlLength
    ) -> some View {
        let shape = Circle()
        return frame(
            width: length,
            height: length
        )
        .panelGlassSurface(
            in: shape,
            interactive: true,
            tint: SnipSnapColors.nestedGlassTint
        )
        .contentShape(shape)
    }

    func panelEmbeddedInputSurface(
        minHeight: CGFloat = PanelControlMetrics.floatingRowHeight,
        expanded: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: expanded ? PanelShapeMetrics.expandedInputCornerRadius : minHeight / 2,
            style: .continuous
        )
        return frame(minHeight: minHeight)
            .panelGlassSurface(
                in: shape,
                interactive: true
            )
            .contentShape(shape)
    }

    func panelGlassSurface<S: InsettableShape>(
        in shape: S,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(
            PanelGlassSurfaceModifier(
                shape: shape,
                interactive: interactive,
                tint: tint
            )
        )
    }

    func panelDropTargetState<S: InsettableShape>(
        in shape: S,
        isTargeted: Bool
    ) -> some View {
        overlay {
            if isTargeted {
                let edge = PanelEdgeStyle.dropTarget
                shape
                    .fill(SnipSnapColors.dropTargetFill)
                    .overlay {
                        shape.strokeBorder(
                            edge.color,
                            lineWidth: edge.width
                        )
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    func panelCompactStateSurface(
        isEmphasized: Bool,
        isSubdued: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(
            PanelCompactStateSurfaceModifier(
                isEmphasized: isEmphasized,
                isSubdued: isSubdued,
                tint: tint
            )
        )
    }

    func panelMeasuredHeight(_ height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { proposed in
            guard PanelGeometryChange.shouldApply(
                current: height.wrappedValue,
                proposed: proposed
            ) else { return }
            height.wrappedValue = proposed
        }
    }

    func panelBlankDragOverlay(
        viewportHeight: Binding<CGFloat>,
        contentHeight: CGFloat
    ) -> some View {
        panelMeasuredHeight(viewportHeight)
            .overlay(alignment: .bottom) {
                PanelBlankDragRegion(
                    viewportHeight: viewportHeight.wrappedValue,
                    contentHeight: contentHeight
                )
            }
    }

}

private struct PanelCompactStateSurfaceModifier: ViewModifier {
    let isEmphasized: Bool
    let isSubdued: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .background {
                Capsule(style: .continuous)
                    .fill(
                        isEmphasized
                            ? (tint?.opacity(0.18) ?? SnipSnapColors.compactSelectionFill)
                            : isSubdued
                                ? SnipSnapColors.compactSubduedFill
                                : .clear
                    )
            }
    }
}

private struct PanelInputModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(SnipSnapColors.textPrimary)
    }
}

struct PanelDragRegion: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents()
            .accessibilityHidden(true)
    }
}

struct PanelBlankDragRegion: View {
    let viewportHeight: CGFloat
    let contentHeight: CGFloat

    static func height(viewportHeight: CGFloat, contentHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0, contentHeight > 0 else { return 0 }
        return max(viewportHeight - contentHeight, 0)
    }

    var body: some View {
        let blankHeight = Self.height(
            viewportHeight: viewportHeight,
            contentHeight: contentHeight
        )
        if blankHeight > 0 {
            PanelDragRegion()
                .frame(maxWidth: .infinity)
                .frame(height: blankHeight)
        }
    }
}

private struct PanelGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        let glass = Glass.regular.tint(tint)
        content
            .glassEffect(interactive ? glass.interactive() : glass, in: shape)
    }
}

struct PanelGlassActionButton: View {
    let systemImage: String
    let isEnabled: Bool
    var tint: Color = SnipSnapTheme.actionGlassTint
    var labelColor: Color = SnipSnapTheme.actionGlassLabel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(PanelGlassActionButtonStyle(tint: tint, labelColor: labelColor))
        .disabled(!isEnabled)
    }
}

private struct PanelGlassActionButtonStyle: ButtonStyle {
    let tint: Color
    let labelColor: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: PanelControlMetrics.actionIconLength, weight: .semibold))
            .foregroundStyle(
                isEnabled
                    ? labelColor
                    : SnipSnapColors.idleActionLabel
            )
            .frame(
                width: PanelControlMetrics.actionWidth,
                height: PanelControlMetrics.actionHeight
            )
            .panelGlassSurface(
                in: Capsule(),
                interactive: isEnabled,
                tint: isEnabled
                    ? tint
                    : SnipSnapColors.idleActionGlassTint
            )
            .contentShape(Capsule())
    }
}
