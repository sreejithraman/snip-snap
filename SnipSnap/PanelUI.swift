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
    static let compactControlLength: CGFloat = 32
    static let tabSelectionInset: CGFloat = 4
    static let compactSelectionWidth: CGFloat = 40
    static let compactSelectionHeight = floatingRowHeight - tabSelectionInset * 2
    static let inlineEntryInset = SnipSnapSpacing.relatedContent
    static let inlineEntryBaseHeight = floatingRowHeight + inlineEntryInset * 2
    static let sendButtonWidth: CGFloat = 34
    static let sendButtonHeight: CGFloat = 26
    static let sendButtonInset = (floatingRowHeight - sendButtonHeight) / 2
    static let expandedInputVerticalPadding = SnipSnapSpacing.relatedContent

    static let tabItemWidth = compactSelectionWidth + tabSelectionInset * 2
}

/// Shared gaps and insets for the custom panel surfaces. Ordinary SwiftUI
/// layouts should keep their system spacing unless two surfaces must align.
enum SnipSnapSpacing {
    static let relatedContent: CGFloat = 8
    static let controlContentInset: CGFloat = 10
    static let cardContentInset: CGFloat = 12
    static let paneContentInset: CGFloat = 16
}

enum PanelShapeMetrics {
    static let paneCornerRadius: CGFloat = 20
    static let listHeaderCornerRadius = paneCornerRadius
    static let expandedInputCornerRadius: CGFloat = 14
    static let contentCardCornerRadius: CGFloat = 14
}

enum PanelListMetrics {
    static let horizontalContentInset = SnipSnapSpacing.paneContentInset
    static let rowSpacing = SnipSnapSpacing.relatedContent
    static let listSpacing = SnipSnapSpacing.paneContentInset
    /// Lets isolated header glass sample past its visible edge without changing layout.
    static let headerGlassSamplingInset = SnipSnapSpacing.paneContentInset
    static let verticalContentInset: CGFloat = 12
    static let compactVerticalContentInset: CGFloat = 10

    static let rowInsets = EdgeInsets(
        top: 0,
        leading: relatedListInset,
        bottom: 0,
        trailing: relatedListInset
    )

    private static let relatedListInset = horizontalContentInset - SnipSnapSpacing.relatedContent
}

enum PanelComposerMetrics {
    static let minimumTextLines = 1
    static let maximumTextLines = 5
    static let textLineRange = minimumTextLines...maximumTextLines
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
    static func actionAlignment(isExpanded: Bool) -> VerticalAlignment {
        isExpanded ? .top : .center
    }

    static func isExpanded(fieldHeight: CGFloat) -> Bool {
        fieldHeight > PanelControlMetrics.floatingRowHeight
            + PanelGeometryChange.minimumMeaningfulChange
    }
}

struct PanelListHeader<Actions: View>: View {
    let title: String
    let isGlassElevated: Bool
    private let actions: Actions

    init(
        _ title: String,
        isGlassElevated: Bool,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.isGlassElevated = isGlassElevated
        self.actions = actions()
    }

    var body: some View {
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
            PanelDragRegion()
        }
        .panelListHeaderGlass(isElevated: isGlassElevated)
    }
}

extension PanelListHeader where Actions == EmptyView {
    init(_ title: String, isGlassElevated: Bool) {
        self.init(title, isGlassElevated: isGlassElevated) { EmptyView() }
    }
}

struct PanelListSectionHeader<Actions: View>: View {
    let title: String
    let hasScrolledFromTop: Bool
    private let actions: Actions

    @State private var isPinned = false

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
        PanelListHeader(
            title,
            isGlassElevated: PinnedListHeaderGlass.isVisible(
                isPinned: isPinned,
                hasScrolled: hasScrolledFromTop
            )
        ) {
            actions
        }
        .onGeometryChange(for: Bool.self) { proxy in
            PinnedListHeaderGlass.isPinned(
                frame: proxy.frame(in: .scrollView(axis: .vertical))
            )
        } action: { isPinned in
            self.isPinned = isPinned
        }
    }
}

extension PanelListSectionHeader where Actions == EmptyView {
    init(
        _ title: String,
        hasScrolledFromTop: Bool
    ) {
        self.init(title, hasScrolledFromTop: hasScrolledFromTop) { EmptyView() }
    }
}

enum PanelDropTargetStyle {
    static let expansion: CGFloat = 6
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

enum PanelGlassEdgeState: Equatable {
    case hidden
    case standard
    case emphasized
    case focused

    var style: PanelEdgeStyle {
        switch self {
        case .hidden:
            .hidden
        case .standard:
            PanelEdgeStyle(
                color: SnipSnapColors.glassEdge,
                width: PanelEdgeThickness.subtle
            )
        case .emphasized:
            PanelEdgeStyle(
                color: SnipSnapColors.emphasizedGlassEdge,
                width: PanelEdgeThickness.regular
            )
        case .focused:
            PanelEdgeStyle(
                color: SnipSnapColors.focusedGlassEdge,
                width: PanelEdgeThickness.strong
            )
        }
    }
}

extension View {
    func panelControlBaseline() -> some View {
        controlSize(.regular)
    }

    func panelInputStyle() -> some View {
        modifier(PanelInputModifier())
    }

    func panelInputSurface(
        minHeight: CGFloat = PanelControlMetrics.floatingRowHeight,
        expanded: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: expanded ? PanelShapeMetrics.expandedInputCornerRadius : minHeight / 2,
            style: .continuous
        )
        return frame(minHeight: minHeight)
            .panelGlassSurface(in: shape)
            .contentShape(shape)
    }

    func panelStandaloneActionControl(
        edge: PanelGlassEdgeState = .standard
    ) -> some View {
        let shape = Circle()
        return frame(
            width: PanelControlMetrics.floatingRowHeight,
            height: PanelControlMetrics.floatingRowHeight
        )
        .background {
            shape
                .fill(SnipSnapColors.standaloneActionFill)
        }
        .panelGlassSurface(
            in: shape,
            interactive: true,
            edge: edge
        )
        .contentShape(shape)
    }

    func panelEmbeddedActionControl() -> some View {
        let shape = Circle()
        return frame(
            width: PanelControlMetrics.compactControlLength,
            height: PanelControlMetrics.compactControlLength
        )
        .panelGlassSurface(
            in: shape,
            interactive: true,
            edge: .hidden
        )
        .contentShape(shape)
    }

    func panelEmbeddedProminentActionControl() -> some View {
        modifier(PanelAdaptiveProminentActionModifier())
    }

    func panelEmbeddedInputSurface(
        minHeight: CGFloat = PanelControlMetrics.floatingRowHeight,
        expanded: Bool = false,
        isFocused: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: expanded ? PanelShapeMetrics.expandedInputCornerRadius : minHeight / 2,
            style: .continuous
        )
        return frame(minHeight: minHeight)
            .panelGlassSurface(
                in: shape,
                edge: isFocused ? .focused : .emphasized
            )
            .contentShape(shape)
    }

    func panelGlassSurface<S: InsettableShape>(
        in shape: S,
        interactive: Bool = false,
        edge: PanelGlassEdgeState = .standard
    ) -> some View {
        modifier(
            PanelGlassSurfaceModifier(
                shape: shape,
                interactive: interactive,
                edge: edge
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

    func panelListHeaderGlass(isElevated: Bool) -> some View {
        modifier(PanelListHeaderGlassModifier(isElevated: isElevated))
    }

    func panelContentCardSurface(
        isSelected: Bool = false,
        isDone: Bool = false
    ) -> some View {
        modifier(
            PanelContentCardSurfaceModifier(
                isSelected: isSelected,
                isDone: isDone
            )
        )
    }

    func panelCompactStateSurface(
        isEmphasized: Bool,
        isSubdued: Bool = false
    ) -> some View {
        modifier(
            PanelCompactStateSurfaceModifier(
                isEmphasized: isEmphasized,
                isSubdued: isSubdued
            )
        )
    }

}

private struct PanelAdaptiveProminentActionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(PanelSlimProminentActionStyle())
    }
}

private struct PanelSlimProminentActionStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                isEnabled
                    ? SnipSnapColors.primaryActionLabel(for: colorScheme)
                    : SnipSnapColors.disabledPrimaryActionLabel(for: colorScheme)
            )
            .frame(
                width: PanelControlMetrics.sendButtonWidth,
                height: PanelControlMetrics.sendButtonHeight
            )
            .background {
                Capsule(style: .continuous)
                    .fill(
                        isEnabled
                            ? SnipSnapColors.primaryActionTint(for: colorScheme)
                            : SnipSnapColors.disabledPrimaryActionTint(for: colorScheme)
                    )
            }
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed && isEnabled ? 0.78 : 1)
    }
}

private struct PanelCompactStateSurfaceModifier: ViewModifier {
    let isEmphasized: Bool
    let isSubdued: Bool

    func body(content: Content) -> some View {
        content
            .background {
                Capsule(style: .continuous)
                    .fill(
                        isEmphasized
                            ? SnipSnapColors.compactSelectionFill
                            : isSubdued
                                ? SnipSnapColors.compactSubduedFill
                                : .clear
                    )
            }
    }
}

private struct PanelListHeaderGlassModifier: ViewModifier {
    let isElevated: Bool

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: PanelShapeMetrics.listHeaderCornerRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: PanelShapeMetrics.listHeaderCornerRadius,
            style: .continuous
        )
    }

    func body(content: Content) -> some View {
        let edge = PanelGlassEdgeState.standard.style
        GlassEffectContainer(spacing: 0) {
            content
                .glassEffect(
                    isElevated
                        ? .clear.tint(SnipSnapColors.elevatedListHeaderGlassTint)
                        : .identity,
                    in: shape
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(edge.color)
                        .frame(height: edge.width)
                        .opacity(isElevated ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .padding(PanelListMetrics.headerGlassSamplingInset)
        }
        .padding(-PanelListMetrics.headerGlassSamplingInset)
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

    var body: some View {
        let blankHeight = max(viewportHeight - contentHeight, 0)
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
    let edge: PanelGlassEdgeState

    func body(content: Content) -> some View {
        let glass: Glass = interactive ? .regular.interactive() : .regular
        let style = edge.style
        content
            .glassEffect(glass, in: shape)
            .overlay {
                if edge != .hidden {
                    shape
                        .strokeBorder(
                            style.color,
                            lineWidth: style.width
                        )
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct PanelContentCardSurfaceModifier: ViewModifier {
    let isSelected: Bool
    let isDone: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: PanelShapeMetrics.contentCardCornerRadius,
            style: .continuous
        )
        let edge = isSelected ? PanelEdgeStyle.selected : .content
        content
            .background {
                shape
                    .fill(.regularMaterial)
                    .overlay {
                        if isSelected {
                            shape.fill(SnipSnapColors.selectionFill)
                        }
                    }
                    .overlay {
                        shape.strokeBorder(
                            edge.color,
                            lineWidth: edge.width
                        )
                    }
                    .shadow(
                        color: SnipSnapColors.contentCardShadow(isSelected: isSelected),
                        radius: isSelected ? 8 : 7,
                        y: 3
                    )
            }
            .contentShape(shape)
            .opacity(isDone ? SnipSnapColors.doneCardOpacity : 1)
    }
}
