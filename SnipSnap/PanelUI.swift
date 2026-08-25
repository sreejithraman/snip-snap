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
    static let expandedInputCornerRadius: CGFloat = 14
    static let contentCardCornerRadius: CGFloat = 14
}

enum PanelListMetrics {
    static let horizontalContentInset = SnipSnapSpacing.paneContentInset
    static let rowSpacing = SnipSnapSpacing.relatedContent
    static let sectionSpacing = SnipSnapSpacing.paneContentInset
    static let verticalContentInset: CGFloat = 12
    static let compactVerticalContentInset: CGFloat = 10
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
}

struct PanelListHeader<Actions: View>: View {
    let title: String
    let showsGlass: Bool
    private let actions: Actions

    init(
        _ title: String,
        showsGlass: Bool,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.showsGlass = showsGlass
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
        .padding(.horizontal, PanelListMetrics.horizontalContentInset)
        .frame(
            maxWidth: .infinity,
            minHeight: PanelControlMetrics.compactControlLength,
            alignment: .leading
        )
        .panelPinnedHeaderSurface(isVisible: showsGlass)
        .contentShape(Rectangle())
    }
}

extension PanelListHeader where Actions == EmptyView {
    init(_ title: String, showsGlass: Bool) {
        self.init(title, showsGlass: showsGlass) { EmptyView() }
    }
}

enum PanelDropTargetStyle {
    static let edgeWidth: CGFloat = 1.5
    static let expansion: CGFloat = 6
}

enum PanelSurfaceStyle {
    static let glassEdgeWidth: CGFloat = 0.5
}

enum PanelGlassEdgeState: Equatable {
    case hidden
    case standard
    case focused

    var color: Color {
        switch self {
        case .hidden: .clear
        case .standard: SnipSnapColors.glassEdge
        case .focused: SnipSnapColors.focusedGlassEdge
        }
    }

    var width: CGFloat {
        switch self {
        case .hidden: 0
        case .standard: PanelSurfaceStyle.glassEdgeWidth
        case .focused: 0.75
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

    func panelStandaloneActionControl() -> some View {
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
            interactive: true
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
                edge: isFocused ? .focused : .standard
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
                shape
                    .fill(SnipSnapColors.dropTargetFill)
                    .overlay {
                        shape.strokeBorder(
                            SnipSnapColors.dropTargetEdge,
                            lineWidth: PanelDropTargetStyle.edgeWidth
                        )
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    func panelPinnedHeaderSurface(isVisible: Bool) -> some View {
        modifier(PanelPinnedHeaderSurfaceModifier(isVisible: isVisible))
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
            .foregroundStyle(SnipSnapColors.primaryActionLabel(for: colorScheme))
            .frame(
                width: PanelControlMetrics.sendButtonWidth,
                height: PanelControlMetrics.sendButtonHeight
            )
            .background {
                Capsule(style: .continuous)
                    .fill(SnipSnapColors.primaryActionTint(for: colorScheme))
            }
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.28)
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

private struct PanelPinnedHeaderSurfaceModifier: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if isVisible {
                    Rectangle()
                        .fill(.regularMaterial)
                        .allowsHitTesting(false)
                }
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
        content
            .glassEffect(glass, in: shape)
            .overlay {
                if edge != .hidden {
                    shape
                        .strokeBorder(
                            edge.color,
                            lineWidth: edge.width
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
                        shape.stroke(
                            isSelected
                                ? SnipSnapColors.selectionEdge
                                : SnipSnapColors.contentCardEdge,
                            lineWidth: isSelected ? 1 : 0.75
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
