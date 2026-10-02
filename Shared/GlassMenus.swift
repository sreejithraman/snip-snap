import Observation
import SwiftUI

/// The feature owns its intent and actions; the host owns the floating presentation.
enum GlassMenuLayout {
    case attached
    case expanding(preferredSize: CGSize)
}

@Observable
final class GlassMenuPresentation {
    private(set) var activeID: UUID?
    @ObservationIgnored private var cancelActive: (() -> Void)?

    var isPresented: Bool { activeID != nil }

    func present(id: UUID, cancel: @escaping () -> Void) {
        let previous = activeID == id ? nil : cancelActive
        activeID = id
        cancelActive = cancel
        previous?()
    }

    func finish(id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        cancelActive = nil
    }

    func dismiss() {
        // Keep the backdrop and accessibility isolation until the matching surface closes.
        cancelActive?()
    }
}

private struct GlassMenuPresentationKey: EnvironmentKey {
    static var defaultValue: GlassMenuPresentation? { nil }
}

extension EnvironmentValues {
    var glassMenuPresentation: GlassMenuPresentation? {
        get { self[GlassMenuPresentationKey.self] }
        set { self[GlassMenuPresentationKey.self] = newValue }
    }
}

private struct GlassMenuAnchor {
    let id: UUID
    let bounds: Anchor<CGRect>
    let layout: GlassMenuLayout
    let label: String
    let identifier: String
    let isPresented: Bool
    let cancel: () -> Void
    let projectedControl: AnyView?
    let sizeProbe: AnyView?
    let menu: (Bool) -> AnyView
}

private struct GlassMenuAnchorKey: PreferenceKey {
    static var defaultValue: [GlassMenuAnchor] { [] }
    static func reduce(value: inout [GlassMenuAnchor], nextValue: () -> [GlassMenuAnchor]) {
        value += nextValue()
    }
}

private struct GlassMenuSource<MenuContent: View>: ViewModifier {
    @Environment(\.glassMenuPresentation) private var presentation
    @State private var localID = UUID()
    @AccessibilityFocusState private var sourceIsFocused: Bool
    let sourceID: UUID?
    @Binding var isPresented: Bool
    let layout: GlassMenuLayout
    let label: String
    let identifier: String
    let isAvailable: Bool
    let projectedControl: AnyView?
    let sizeProbe: AnyView?
    let sourceFocus: ((Bool) -> Void)?
    @ViewBuilder let menu: (Bool) -> MenuContent

    private var id: UUID { sourceID ?? localID }

    func body(content: Content) -> some View {
        Group {
            if sourceFocus == nil { content.accessibilityFocused($sourceIsFocused) }
            else { content }
        }
        .anchorPreference(key: GlassMenuAnchorKey.self, value: .bounds) { bounds in
            guard isAvailable else { return [] }
            return [GlassMenuAnchor(
                id: id, bounds: bounds, layout: layout, label: label, identifier: identifier,
                isPresented: isPresented, cancel: { isPresented = false },
                projectedControl: projectedControl, sizeProbe: sizeProbe, menu: { AnyView(menu($0)) }
            )]
        }
        .onChange(of: isPresented, initial: true) { _, presented in
            if presented {
                setSourceFocus(false)
                guard isAvailable else { isPresented = false; return }
                presentation?.present(id: id, cancel: { isPresented = false })
            }
        }
        .onChange(of: presentation?.activeID) { previous, active in
            if active != nil {
                setSourceFocus(false)
            } else if previous == id && !isPresented && isAvailable {
                setSourceFocus(true)
            }
        }
        .onChange(of: isAvailable) { _, available in
            if !available {
                isPresented = false
                presentation?.finish(id: id)
            }
        }
        .onDisappear {
            isPresented = false
            presentation?.finish(id: id)
        }
    }

    private func setSourceFocus(_ focused: Bool) {
        if let sourceFocus { sourceFocus(focused) }
        else { sourceIsFocused = focused }
    }
}

private struct GlassMenuHost: ViewModifier {
    @State private var presentation = GlassMenuPresentation()
    @Environment(\.scenePhase) private var scenePhase
    let isBlocked: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.glassMenuPresentation, presentation)
            .overlayPreferenceValue(GlassMenuAnchorKey.self) { anchors in
                GeometryReader { geometry in
                    ZStack {
                        if presentation.isPresented {
                            dismissalBackdrop
                                .ignoresSafeArea()
                                .contentShape(Rectangle())
                                .onTapGesture { presentation.dismiss() }
                                .accessibilityHidden(true)
                                .zIndex(1)
                        }
                        ForEach(anchors, id: \.id) { anchor in
                            let presented = anchor.isPresented && anchor.id == presentation.activeID
                            ZStack {
                                GlassMenuSurface(
                                    anchor: anchor, source: geometry[anchor.bounds],
                                    availableSize: geometry.size, isPresented: presented,
                                    finishPresentation: { presentation.finish(id: anchor.id) }
                                )
                                projectedControl(anchor, in: geometry)
                            }
                            .allowsHitTesting(!presentation.isPresented || presented)
                            .accessibilityHidden(
                                (presentation.isPresented && !presented)
                                    || (!presented && anchor.projectedControl == nil)
                            )
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(anchor.id == presentation.activeID ? .isModal : [])
                            .accessibilityRemoveTraits(anchor.id == presentation.activeID ? [] : .isModal)
                            .zIndex(anchor.id == presentation.activeID ? 2 : 0)
                        }
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { presentation.dismiss() }
            }
            .onChange(of: isBlocked) { _, blocked in
                if blocked { presentation.dismiss() }
            }
    }

    private func projectedControl(_ anchor: GlassMenuAnchor, in geometry: GeometryProxy) -> some View {
        let source = geometry[anchor.bounds]
        return anchor.projectedControl
            .frame(width: source.width, height: source.height)
            .position(x: source.midX, y: source.midY)
    }

    private var dismissalBackdrop: Color {
        #if os(macOS)
        // The floating window has a transparent effect gutter. Keep the
        // dismissal shield invisible so it does not darken the desktop.
        .clear
        #else
        .black.opacity(0.10)
        #endif
    }
}

/// One material and motion treatment, with steady content inside a growing mask.
private struct GlassMenuSurface: View {
    let anchor: GlassMenuAnchor
    let source: CGRect
    let availableSize: CGSize
    let isPresented: Bool
    let finishPresentation: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isMounted = false
    @State private var isExpanded = false
    @State private var isInteractive = false
    @State private var transitionID = UUID()
    @AccessibilityFocusState private var menuIsFocused: Bool

    private let edgeInset: CGFloat = 12
    private let menuGap: CGFloat = 8
    private let cornerRadius: CGFloat = 24

    private var maximumSize: CGSize {
        switch anchor.layout {
        case .attached:
            let above = max(0, source.minY - menuGap - edgeInset)
            let below = max(0, availableSize.height - source.maxY - menuGap - edgeInset)
            return CGSize(width: min(264, max(0, availableSize.width - edgeInset * 2)),
                          height: min(360, max(above, below)))
        case .expanding(let preferred):
            return CGSize(width: min(preferred.width, max(0, availableSize.width - edgeInset * 2)),
                          height: min(preferred.height, max(0, source.maxY - edgeInset)))
        }
    }

    var body: some View {
        GlassMenuPositionLayout(
            source: source, availableSize: availableSize, layout: anchor.layout,
            layoutDirection: layoutDirection
        ) {
            if isPresented || isMounted {
                Group {
                    switch anchor.layout {
                    case .attached:
                        GlassMenuContentLayout(maximumSize: maximumSize) {
                            (anchor.sizeProbe ?? anchor.menu(false)).hidden().accessibilityHidden(true)
                            if anchor.sizeProbe != nil {
                                anchor.menu(isInteractive)
                            } else {
                                ScrollView { anchor.menu(isInteractive) }
                                    .scrollIndicators(.hidden)
                            }
                        }
                    case .expanding:
                        anchor.menu(isInteractive)
                            .frame(width: maximumSize.width, height: maximumSize.height)
                    }
                }
                .modifier(GlassMenuReveal(
                    isExpanded: isExpanded, reduceMotion: reduceMotion,
                    reduceTransparency: reduceTransparency, source: source, layout: anchor.layout,
                    layoutDirection: layoutDirection, cornerRadius: cornerRadius
                ))
                .opacity(isPresented || isExpanded ? 1 : 0)
                .allowsHitTesting(isPresented && isInteractive)
                .accessibilityHidden(!isPresented || !isInteractive)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(anchor.label)
                .accessibilityIdentifier(isPresented ? anchor.identifier : "")
                .accessibilityFocused($menuIsFocused)
                .accessibilityAction(.escape, anchor.cancel)
            }
        }
        .onChange(of: isPresented, initial: true) { _, presented in
            animatePresentation(presented)
        }
        .onDisappear(perform: finishPresentation)
        .onChange(of: reduceMotion) { _, _ in
            transitionID = UUID()
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isExpanded = isPresented
                isMounted = isPresented
                isInteractive = isPresented
                menuIsFocused = isPresented
            }
            if !isPresented { finishPresentation() }
        }
    }

    private func animatePresentation(_ presented: Bool) {
        guard presented || isExpanded else { return }
        if presented { isMounted = true }
        isInteractive = false
        if !presented { menuIsFocused = false }
        let id = UUID()
        transitionID = id
        withAnimation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.06), completionCriteria: .removed) {
            isExpanded = presented
        } completion: {
            guard transitionID == id else { return }
            isInteractive = presented
            if presented { menuIsFocused = true }
            else {
                isMounted = false
                finishPresentation()
            }
        }
    }
}

private struct GlassMenuPositionLayout: Layout {
    let source: CGRect
    let availableSize: CGSize
    let layout: GlassMenuLayout
    let layoutDirection: LayoutDirection

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        availableSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let surface = subviews.first else { return }
        let size = surface.sizeThatFits(.unspecified)
        let proposedX: CGFloat
        let bottom: CGFloat
        switch layout {
        case .attached:
            proposedX = layoutDirection == .rightToLeft ? source.minX + size.width / 2 : source.maxX - size.width / 2
            let fitsAbove = source.minY - 8 - size.height >= 12
            bottom = fitsAbove ? source.minY - 8 : source.maxY + 8 + size.height
        case .expanding:
            proposedX = source.midX
            bottom = source.maxY
        }
        let x = min(max(proposedX, size.width / 2 + 12), availableSize.width - size.width / 2 - 12)
        surface.place(at: CGPoint(x: bounds.minX + x - size.width / 2, y: bounds.minY + bottom - size.height),
                      proposal: ProposedViewSize(size))
    }
}

private struct GlassMenuReveal: ViewModifier {
    let isExpanded: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let source: CGRect
    let layout: GlassMenuLayout
    let layoutDirection: LayoutDirection
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(isExpanded ? 1 : 0)
            .background {
                GeometryReader { geometry in
                    let alignment = revealAlignment(height: geometry.size.height)
                    let size = isExpanded || reduceMotion ? geometry.size : source.size
                    let shape = RoundedRectangle(cornerRadius: isExpanded ? cornerRadius : source.size.height / 2)
                    Group {
                        if reduceTransparency {
#if os(macOS)
                            shape.fill(Color(nsColor: .windowBackgroundColor))
#else
                            shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
#endif
                        } else {
                            Color.clear.glassEffect(.regular, in: shape)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                }
            }
            .mask {
                GeometryReader { geometry in
                    let alignment = revealAlignment(height: geometry.size.height)
                    RoundedRectangle(cornerRadius: isExpanded ? cornerRadius : source.size.height / 2)
                        .frame(width: isExpanded || reduceMotion ? geometry.size.width : source.size.width,
                               height: isExpanded || reduceMotion ? geometry.size.height : source.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                }
            }
    }

    private func revealAlignment(height: CGFloat) -> Alignment {
        switch layout {
        case .expanding: return .bottom
        case .attached:
            let above = source.minY - 8 - height >= 12
            if layoutDirection == .rightToLeft { return above ? .bottomLeading : .topLeading }
            return above ? .bottomTrailing : .topTrailing
        }
    }
}

/// Measure unsqueezed rows before placing the scrollable instance at its final size.
private struct GlassMenuContentLayout: Layout {
    let maximumSize: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let probe = subviews.first else { return .zero }
        let width = min(maximumSize.width, max(180, probe.sizeThatFits(.unspecified).width))
        let height = min(maximumSize.height, probe.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.last?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

struct GlassMenuActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isHighlighted = false

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 0)
        }
        .font(.body)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .foregroundStyle(!isEnabled ? Color.secondary : configuration.role == .destructive ? Color.red : Color.primary)
        .background(configuration.isPressed || isHighlighted ? SnipSnapTheme.selectionFill : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

extension View {
    func glassMenuHost(isBlocked: Bool = false) -> some View {
        modifier(GlassMenuHost(isBlocked: isBlocked))
    }

    func glassMenu<MenuContent: View>(
        sourceID: UUID? = nil, isPresented: Binding<Bool>, layout: GlassMenuLayout = .attached,
        label: String, identifier: String, isAvailable: Bool = true,
        projectedControl: AnyView? = nil, sizeProbe: AnyView? = nil,
        sourceFocus: ((Bool) -> Void)? = nil, @ViewBuilder menu: @escaping (Bool) -> MenuContent
    ) -> some View {
        modifier(GlassMenuSource(
            sourceID: sourceID, isPresented: isPresented, layout: layout, label: label,
            identifier: identifier, isAvailable: isAvailable, projectedControl: projectedControl, sizeProbe: sizeProbe,
            sourceFocus: sourceFocus, menu: menu
        ))
    }
}
