import SnipSnapCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Send offers every list; Move omits a destination only when all sources already belong to it.
enum ListDestinationPurpose {
    case send
    case move(sourceListIDs: Set<UUID>)

    var title: String {
        switch self {
        case .send: String(localized: "Send to List")
        case .move: String(localized: "Move to List")
        }
    }

    func destinations(in lists: [SnipList]) -> [SnipList] {
        switch self {
        case .send: lists
        case .move(let sourceListIDs):
            lists.filter { list in
                !sourceListIDs.isEmpty && !sourceListIDs.allSatisfy { $0 == list.id }
            }
        }
    }
}

/// The same list identity, name and icon in the anchored picker and native menus.
struct ListDestinationLabel: View {
    let list: SnipList

    var body: some View {
        Label {
            Text(list.displayName)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: list.systemImage)
                .foregroundStyle(list.accent.color)
                .frame(width: 24)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// Native menus retain their platform's selection, keyboard and dismissal behavior.
struct ListDestinationMenu: View {
    let lists: [SnipList]
    let purpose: ListDestinationPurpose
    let identifierPrefix: String
    let choose: (UUID) -> Void

    var body: some View {
        let destinations = purpose.destinations(in: lists)
        if !destinations.isEmpty {
            Menu(purpose.title, systemImage: "folder") {
                ForEach(destinations) { list in
                    Button { choose(list.id) } label: { ListDestinationLabel(list: list) }
                        .accessibilityIdentifier("\(identifierPrefix)\(list.name)")
                }
            }
        }
    }
}

private struct SendPickerAnchor {
    let id: UUID
    let bounds: Anchor<CGRect>
    let size: CGSize
    let button: AnyView?
    let isPresented: Bool
    let destinations: [SnipList]
    let choose: (UUID) -> Void
    let cancel: () -> Void
}

private struct SendPickerAnchorKey: PreferenceKey {
    static var defaultValue: [SendPickerAnchor] { [] }
    static func reduce(value: inout [SendPickerAnchor], nextValue: () -> [SendPickerAnchor]) {
        value += nextValue()
    }
}

/// One send surface on both platforms, with platform-specific activation paths.
struct AppMorphingSendControl: View {
    let sourceID: UUID
    let isEnabled: Bool
    var usesRootSurface = true
    var projectsClosedButton = true
    let tint: Color
    let labelColor: Color
    let size: CGSize
    var minimumHitHeight: CGFloat = 0
    let iconLength: CGFloat
    let destinations: [SnipList]
    @Binding var isPresented: Bool
    let send: () -> Void
    let choose: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isInteractionEnabled
    @AccessibilityFocusState private var sendIsAccessibilityFocused: Bool

    private var projectsButton: Bool {
        isEnabled && isInteractionEnabled && usesRootSurface
            && (projectsClosedButton || isPresented)
    }

    private var controlSize: CGSize {
        CGSize(width: size.width, height: max(size.height, minimumHitHeight))
    }

    var body: some View {
        Group {
            if projectsButton {
                // Keep the live button and menu outside the input's clipping,
                // while reserving the button's original composer slot.
                Color.clear
            } else {
                button
            }
        }
        .frame(width: controlSize.width, height: controlSize.height)
        .anchorPreference(key: SendPickerAnchorKey.self, value: .bounds) { bounds in
            guard isEnabled && isInteractionEnabled && usesRootSurface else { return [] }
            return [SendPickerAnchor(
                id: sourceID, bounds: bounds, size: controlSize,
                button: projectsButton ? AnyView(button) : nil, isPresented: isPresented,
                destinations: ListDestinationPurpose.send.destinations(in: destinations), choose: choose, cancel: { isPresented = false }
            )]
        }
        .onChange(of: isEnabled) { _, enabled in if !enabled { isPresented = false } }
        .onChange(of: isInteractionEnabled) { _, enabled in if !enabled { isPresented = false } }
        .onChange(of: usesRootSurface) { _, available in if !available { isPresented = false } }
        .onChange(of: destinations.map(\.id)) { _, ids in if ids.isEmpty { isPresented = false } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { isPresented = false } }
        .onChange(of: isPresented) { _, presented in
            if !presented { sendIsAccessibilityFocused = true }
        }
    }

    private var button: some View {
        Button(action: activate) {
            Image(systemName: isPresented ? "xmark" : "arrow.up")
                .font(.system(size: iconLength, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isPresented)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? labelColor : SnipSnapTheme.disabledActionGlassLabel)
        .glassEffect(.regular.tint(isEnabled ? tint : SnipSnapTheme.disabledActionGlassTint), in: Capsule())
        // Keep the visible capsule inset while retaining the full touch target.
        .frame(width: controlSize.width, height: controlSize.height)
        .contentShape(Rectangle())
        .disabled(!isEnabled)
        .accessibilityLabel(isPresented ? "Cancel Send to List" : "Send Snip")
        .accessibilityIdentifier(isPresented ? "composer-send-dismiss" : "composer-send")
        .accessibilityFocused($sendIsAccessibilityFocused)
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.45)
                .exclusively(before: TapGesture())
                .onEnded { result in
                    switch result {
                    case .first: open()
                    case .second: send()
                    }
                },
            including: isPresented ? .subviews : .all
        )
        .accessibilityHint("Press and hold to send to another list", isEnabled: !isPresented && !destinations.isEmpty)
        .accessibilityActions {
            if !isPresented && !destinations.isEmpty { Button("Send to List", action: open) }
        }
#if os(macOS)
        .help(isPresented ? "Cancel Send to List (Escape)" : "Send Snip (Return); hold or press ⌘Return to choose a list")
#endif
    }

    private func activate() {
        if isPresented { isPresented = false } else { send() }
    }

    private func open() {
        guard isEnabled, isInteractionEnabled, usesRootSurface, !destinations.isEmpty else { return }
        isPresented = true
    }
}

private struct SendPickerHost: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(SendPickerAnchorKey.self) { anchors in
            GeometryReader { geometry in
                ZStack {
                    if let presented = anchors.first(where: \.isPresented) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: presented.cancel)
                            .accessibilityHidden(true)
                    }
                    ForEach(anchors.filter { $0.isPresented || $0.button != nil }, id: \.id) { anchor in
                        SendPickerSurface(
                            anchor: anchor, sourceBounds: geometry[anchor.bounds],
                            availableSize: geometry.size
                        )
                    }
                }
            }
        }
    }
}

/// Keep the button stationary beneath a menu whose final layout never moves.
/// A bottom-aligned mask reveals the menu vertically, without scaling its labels.
private struct SendPickerSurface: View {
    let anchor: SendPickerAnchor
    let sourceBounds: CGRect
    let availableSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isExpanded = false
    @State private var isInteractive = false
    @State private var transitionID = UUID()
    @ScaledMetric(relativeTo: .body) private var scaledRowHeight: CGFloat = 44
    private var rowHeight: CGFloat { max(44, scaledRowHeight) }
    private let menuGap: CGFloat = 8
    private let menuEffectInset: CGFloat = 8
    private var alignment: Alignment { .bottomTrailing }
    private var maximumMenuWidth: CGFloat {
        let space = layoutDirection == .rightToLeft
            ? availableSize.width - sourceBounds.minX : sourceBounds.maxX
        return min(264, max(anchor.size.width, space - 12))
    }
    private var maximumMenuHeight: CGFloat {
        min(max(44, sourceBounds.minY - menuGap - 12), 360)
    }

    var body: some View {
        ZStack(alignment: alignment) {
            if anchor.isPresented {
                ListDestinationPickerLayout(maximumWidth: maximumMenuWidth, maximumHeight: maximumMenuHeight) {
                    // Measure real SwiftUI text before presentation, so width never
                    // arrives a frame late or shifts sideways during the reveal.
                    VStack(spacing: 0) {
                        SendPickerHeading()
                        VStack(spacing: 2) {
                            ForEach(anchor.destinations) { list in
                                SendPickerRow(list: list, rowHeight: rowHeight)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 8)
                    }
                    .hidden()
                    .accessibilityHidden(true)
                    SendPickerPanel(anchor: anchor, rowHeight: rowHeight, isInteractive: isInteractive)
                }
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                    // Glass extends beyond its layout bounds. Keep that rim
                    // inside the reveal canvas without moving the menu.
                    .padding(menuEffectInset)
                    .mask(alignment: .bottom) {
                        GeometryReader { geometry in
                            Rectangle()
                                .frame(height: isExpanded ? geometry.size.height : 0)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .opacity(isExpanded ? 1 : 0)
                    .padding(-menuEffectInset)
                    .allowsHitTesting(isInteractive && anchor.isPresented)
                    .accessibilityHidden(!isInteractive || !anchor.isPresented)
                    .padding(.bottom, anchor.size.height + menuGap)
            }
            anchor.button
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(anchor.isPresented ? .isModal : [])
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .padding(.bottom, availableSize.height - sourceBounds.maxY)
        .padding(.trailing, layoutDirection == .rightToLeft ? sourceBounds.minX : availableSize.width - sourceBounds.maxX)
        .onChange(of: anchor.isPresented, initial: true) { _, presented in
            isInteractive = false
            let id = UUID()
            transitionID = id
            withAnimation(
                reduceMotion ? nil : .easeInOut(duration: 0.24),
                completionCriteria: .removed
            ) {
                isExpanded = presented
            } completion: {
                guard transitionID == id else { return }
                isInteractive = presented
            }
        }
    }
}

/// First subview is an invisible intrinsic-size probe; only the panel is placed.
/// Constraining the same probe also accounts for wrapped rows and Dynamic Type.
private struct ListDestinationPickerLayout: Layout {
    let maximumWidth: CGFloat
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let probe = subviews.first else { return .zero }
        let width = min(maximumWidth, max(180, probe.sizeThatFits(.unspecified).width))
        let height = min(maximumHeight, probe.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.last?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct SendPickerHeading: View {
    var body: some View {
        Text(ListDestinationPurpose.send.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SnipSnapSpacing.cardContentInset)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }
}

private struct SendPickerRow: View {
    let list: SnipList
    let rowHeight: CGFloat

    var body: some View {
        HStack {
            ListDestinationLabel(list: list)
            Spacer(minLength: 0)
        }
        .font(.body)
        .padding(.horizontal, SnipSnapSpacing.cardContentInset)
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct SendPickerPanel: View {
    let anchor: SendPickerAnchor
    let rowHeight: CGFloat
    let isInteractive: Bool
    @State private var selection: UUID?
    @AccessibilityFocusState private var titleIsAccessibilityFocused: Bool
#if os(macOS)
    @State private var typedPrefix = ""
    @State private var lastTypedAt = Date.distantPast
#endif

    var body: some View {
        VStack(spacing: 0) {
            SendPickerHeading()
                .accessibilityFocused($titleIsAccessibilityFocused)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(anchor.destinations) { list in
                            Button { anchor.choose(list.id) } label: {
                                SendPickerRow(list: list, rowHeight: rowHeight)
                                .background(selection == list.id ? SnipSnapTheme.selectionFill : .clear,
                                            in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                            .accessibilityLabel(list.displayName)
                            .accessibilityIdentifier("composer-send-to-\(list.id.uuidString)")
                            .id(list.id)
#if os(macOS)
                            .onHover { if $0 { selection = list.id } }
#endif
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: anchor.isPresented) { _, presented in
                    if presented, let id = anchor.destinations.first?.id { proxy.scrollTo(id) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-send-picker")
        .accessibilityAction(named: Text("Cancel"), anchor.cancel)
        .accessibilityAction(.escape, anchor.cancel)
        .onChange(of: isInteractive, initial: true) { _, ready in
            if ready { titleIsAccessibilityFocused = true }
        }
#if os(macOS)
        .onChange(of: anchor.isPresented, initial: true) { _, presented in
            if presented {
                selection = anchor.destinations.first?.id
                typedPrefix = ""
                lastTypedAt = .distantPast
            }
        }
        .background {
            // Monitor ownership follows the intent, independently of the
            // menu's reveal animation.
            Group {
                if anchor.isPresented {
                    SendPickerKeyboardInput(handle: handleKey)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
            }
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        }
#endif
    }

#if os(macOS)
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 53:
            anchor.cancel()
        case 36, 76:
            if modifiers.contains(.command) { anchor.cancel() }
            else if isInteractive, let selection { anchor.choose(selection) }
        case 125:
            moveSelection(1)
        case 126:
            moveSelection(-1)
        case 51:
            if !typedPrefix.isEmpty { typedPrefix.removeLast() }
        case 48:
            moveSelection(modifiers.contains(.shift) ? -1 : 1)
        default:
            if modifiers.contains(.command) {
                // Keep standard window/app shortcuts available, without editing the draft.
                return !["q", "w", "h"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
            }
            guard !modifiers.contains(.control), !modifiers.contains(.option),
                  let characters = event.characters, !characters.isEmpty else { return true }
            if Date().timeIntervalSince(lastTypedAt) > 1 { typedPrefix = "" }
            typedPrefix += characters
            lastTypedAt = Date()
            if let match = anchor.destinations.first(where: {
                $0.displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .hasPrefix(typedPrefix.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
            }) { selection = match.id }
        }
        return true
    }

    private func moveSelection(_ offset: Int) {
        let lists = anchor.destinations
        guard !lists.isEmpty else { return }
        let index = lists.firstIndex { $0.id == selection } ?? 0
        selection = lists[(index + offset + lists.count) % lists.count].id
    }
#endif
}

#if os(macOS)
/// Scope menu keys to this panel while the composer temporarily stops accepting input.
private struct SendPickerKeyboardInput: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> SendPickerKeyboardView {
        SendPickerKeyboardView(handle: handle)
    }
    func updateNSView(_ view: SendPickerKeyboardView, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: SendPickerKeyboardView, coordinator: ()) { view.stop() }
}

private final class SendPickerKeyboardView: NSView {
    var handle: (NSEvent) -> Bool
    private var monitor: Any?

    init(handle: @escaping (NSEvent) -> Bool) {
        self.handle = handle
        super.init(frame: .zero)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event) ? nil : event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
#endif

extension View {
    func sendDestinationPickerHost() -> some View { modifier(SendPickerHost()) }
}
