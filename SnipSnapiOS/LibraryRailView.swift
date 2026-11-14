import SnipSnapCore
import SwiftUI
import UIKit

/// How the regular-width library shows its lists.
enum RegularLibraryLayout: String {
    case sidebar
    case rail

    /// Phone panels, such as the open iPhone Duo or a large iPhone in landscape, get the rail.
    @MainActor static let current: RegularLibraryLayout = TryOverride.value("SNIP_SNAP_REGULAR_LAYOUT")
        ?? (UIDevice.current.userInterfaceIdiom == .phone ? .rail : .sidebar)
}

/// Launch-time switches for trying design candidates on a device. Release builds ignore them.
enum TryOverride {
    static func value<Value: RawRepresentable>(_ key: String) -> Value? where Value.RawValue == String {
#if DEBUG
        ProcessInfo.processInfo.environment[key].flatMap(Value.init(rawValue:))
#else
        nil
#endif
    }
}

extension EnvironmentValues {
    /// Paste and library actions ask for the system's trailing column of round buttons.
    @Entry var prefersSideButtons = false
}

extension View {
    /// Asks for side buttons only where the system shows a vertical bar, such as the open iPhone
    /// Duo. Elsewhere the rail keeps the iPad toolbar, where an explicit Search item would become
    /// a full field.
    func sideButtonsWhereVerticalBar() -> some View { modifier(VerticalBarSideButtons()) }
}

private struct VerticalBarSideButtons: ViewModifier {
    // Seeded from the scene so the first frame matches; the probe follows later changes.
    @State private var hasVerticalBar = VerticalBarProbe.sceneHasVerticalBar

    func body(content: Content) -> some View {
        content
            .environment(\.prefersSideButtons, hasVerticalBar)
            .background {
                VerticalBarProbe(hasVerticalBar: $hasVerticalBar)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
    }
}

/// SwiftUI has no environment value for the vertical bar, so this reads the UIKit trait.
private struct VerticalBarProbe: UIViewRepresentable {
    @Binding var hasVerticalBar: Bool

    static func hasVerticalBar(in traits: UITraitCollection?) -> Bool {
        guard #available(iOS 27.1, *), let traits else { return false }
        return traits.verticalBarEdge != .unspecified
    }

    static var sceneHasVerticalBar: Bool {
        hasVerticalBar(in: UIApplication.shared.connectedScenes
            .lazy.compactMap { $0 as? UIWindowScene }.first?.traitCollection)
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        // Reports can arrive while SwiftUI mounts the probe, where a state write is dropped.
        view.report = { [binding = $hasVerticalBar] value in
            DispatchQueue.main.async {
                if binding.wrappedValue != value { binding.wrappedValue = value }
            }
        }
    }

    final class ProbeView: UIView {
        var report: ((Bool) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            if #available(iOS 27.1, *) {
                registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (view: ProbeView, _: UITraitCollection) in
                    view.reportVerticalBar()
                }
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportVerticalBar()
        }

        func reportVerticalBar() {
            guard window != nil else { return }
            report?(VerticalBarProbe.hasVerticalBar(in: traitCollection))
        }
    }
}

extension ToolbarContent {
    /// Joins the open iPhone Duo's trailing column of round buttons. Without that column it stays put.
    @ToolbarContentBuilder
    func sideButton() -> some ToolbarContent {
        if #available(iOS 27.1, *) {
            axisBehavior(.verticalPreferred)
        } else {
            self
        }
    }
}

enum NewListButtonStyle: String {
    case roundPlus
    case roundCompose
    case inlinePlus
    case inlineStackBadgePlus

    static let current: NewListButtonStyle = TryOverride.value("SNIP_SNAP_NEW_LIST_BUTTON") ?? .roundPlus

    var systemImage: String {
        switch self {
        case .roundPlus, .inlinePlus: "plus"
        case .roundCompose: "square.and.pencil"
        case .inlineStackBadgePlus: "rectangle.stack.badge.plus"
        }
    }

    /// Round styles pin a glass circle to the bottom of the rail; the others follow the last list.
    var isPinned: Bool { self == .roundPlus || self == .roundCompose }
}

/// What the rail draws for a list in place of its name.
enum RailListMark: Equatable {
    case icon(String)
    case letters(String)

    enum Policy: String {
        case letterBadgeForDefaultIcon = "letters"
        case iconOnly = "icons"

        static let current: Policy = TryOverride.value("SNIP_SNAP_RAIL_LIST_MARK") ?? .letterBadgeForDefaultIcon
    }

    /// Icons a list has until someone picks one: the app's new-list icon and the core fallback.
    static let defaultIcons: Set<String> = [ListIconSymbol.defaultName, "circle.grid.2x2.fill"]

    init(name: String, systemImage: String, policy: Policy = .current) {
        guard policy == .letterBadgeForDefaultIcon, Self.defaultIcons.contains(systemImage) else {
            self = .icon(systemImage)
            return
        }
        let initials = name.split(whereSeparator: \.isWhitespace)
            .compactMap { word in word.first(where: { $0.isLetter || $0.isNumber }) }
            .prefix(2)
        self = initials.isEmpty ? .icon(systemImage) : .letters(String(initials).uppercased())
    }
}

extension EnvironmentValues {
    /// Sizing for a library sidebar, set by the container that holds it and its detail.
    @Entry var librarySidebarSizing = LibrarySidebarSizing.unmeasured
}

extension View {
    /// Measures this view as the container of a library sidebar and its detail, so the sidebar
    /// can size itself to the container's width and to a vertical hinge that divides it.
    func librarySidebarContainer() -> some View { modifier(LibrarySidebarContainer()) }
}

private struct LibrarySidebarContainer: ViewModifier {
    @State private var sizing = LibrarySidebarSizing.unmeasured

    func body(content: Content) -> some View {
        content
            .environment(\.librarySidebarSizing, sizing)
            .onGeometryChange(for: LibrarySidebarSizing.self) { proxy in
                guard #available(iOS 27.1, *) else {
                    return LibrarySidebarSizing(containerWidth: proxy.size.width, hingeEdge: nil)
                }
                return LibrarySidebarSizing(
                    containerWidth: proxy.size.width,
                    divisions: proxy.reservedRegions(kind: .division).map(\.frame)
                )
            } action: { sizing = $0 }
    }
}

/// The library's list column beside the page card. It is a thin rail of marks, or a wider sidebar
/// that also shows names. Dragging its trailing edge resizes it; the toggle at its top switches looks.
struct LibraryRailView: View {
    /// Rows keep this inset on both sides, so a mark stays put as the column widens.
    private static let inset: CGFloat = 12
    let model: IOSAppModel
    @Binding var sheet: AppSheet?
    let deleteList: (UUID) async -> Void
    @Environment(\.librarySidebarSizing) private var sizing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage private var isExpanded: Bool
    @AppStorage private var expandedWidth: LibrarySidebarExpandedWidth
    /// How far the finger has widened the column since the drag began.
    @State private var dragTravel: CGFloat?
    @GestureState private var isResizing = false
    private let newListStyle = NewListButtonStyle.current

    init(model: IOSAppModel, sheet: Binding<AppSheet?>, deleteList: @escaping (UUID) async -> Void) {
        self.model = model
        _sheet = sheet
        self.deleteList = deleteList
        _isExpanded = AppStorage(wrappedValue: false, Self.storageKey("library-sidebar-expanded"))
        _expandedWidth = AppStorage(wrappedValue: .default, Self.storageKey("library-sidebar-expanded-width"))
    }

    /// UI-test runs each keep their own store, so one run's width choice can't leak into another.
    private static func storageKey(_ key: String) -> String {
#if DEBUG
        if let store = ProcessInfo.processInfo.environment["SNIP_SNAP_UI_TEST_STORE"] {
            return "\(key)-\(store)"
        }
#endif
        return key
    }

    private var settledWidth: CGFloat {
        sizing.width(isExpanded: isExpanded, expandedWidth: expandedWidth)
    }

    /// Resolved from the current sizing on every render, so a fold during a drag applies its new maximum.
    private var width: CGFloat {
        dragTravel.map { sizing.dragWidth(settledWidth + $0) } ?? settledWidth
    }

    private var nameOpacity: Double { LibrarySidebarSizing.nameOpacity(at: width) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                RailButton(
                    title: String(localized: "Clipboard"),
                    isSelected: model.selectedPage == .clipboard,
                    nameOpacity: nameOpacity,
                    action: { model.selectPage(.clipboard) }
                ) {
                    RailIcon(systemImage: "clipboard", color: .primary)
                }
                .accessibilityIdentifier("clipboard-sidebar")

                if model.recoverySnapshot.needsAttentionCount > 0 {
                    needsAttention
                }

                Divider()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)

                ForEach(model.lists) { list in
                    RailButton(
                        title: list.displayName,
                        isSelected: model.selectedPage == .list(list.id),
                        nameOpacity: nameOpacity,
                        action: { model.selectPage(.list(list.id)) }
                    ) {
                        RailListMarkView(list: list)
                    }
                    .accessibilityIdentifier("list-\(list.name)")
                    .listContextActions(
                        list: list,
                        beforeDelete: model.haptics.invalidatePendingFeedback,
                        edit: { model.editListInline(id: list.id) },
                        delete: { Task { await deleteList(list.id) } }
                    )
                }

                if !newListStyle.isPinned {
                    newListButton
                }
            }
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            widthToggle
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Self.inset + 6)
                .padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if newListStyle.isPinned {
                newListButton
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.inset + 2)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: width)
        .overlay(alignment: .trailing) {
            resizeHandle
                .alignmentGuide(HorizontalAlignment.trailing) { $0[HorizontalAlignment.center] }
        }
        .onChange(of: isResizing) { _, isActive in
            // A canceled drag never ends, so it settles where it stopped.
            guard !isActive, let dragTravel else { return }
            settle(atPredictedWidth: settledWidth + dragTravel)
        }
    }

    private var widthToggleTitle: Text {
        isExpanded ? Text("Hide List Names") : Text("Show List Names")
    }

    private var widthToggle: some View {
        Button {
            withAnimation(settleAnimation) { isExpanded.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .accessibilityLabel(widthToggleTitle)
        .accessibilityIdentifier("sidebar-width-toggle")
        .accessibilityShowsLargeContentViewer {
            Label { widthToggleTitle } icon: { Image(systemName: "sidebar.left") }
        }
    }

    /// An invisible strip centered on the column's trailing edge. The toggle offers the same change
    /// to assistive technologies, so the strip stays out of their way.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 20)
            .contentShape(Rectangle())
            .overlay {
                if dragTravel != nil {
                    Capsule()
                        .fill(.tertiary)
                        .frame(width: 5, height: 40)
                }
            }
            .gesture(resizeGesture)
            .accessibilityHidden(true)
    }

    private var resizeGesture: some Gesture {
        // Global, because the strip moves with the edge it drags.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($isResizing) { _, isActive, _ in isActive = true }
            .onChanged { value in dragTravel = widening(value.translation) }
            .onEnded { value in
                guard dragTravel != nil else { return }
                settle(atPredictedWidth: settledWidth + widening(value.predictedEndTranslation))
            }
    }

    /// Global coordinates don't mirror, so a right-to-left column widens as the finger moves left.
    private func widening(_ translation: CGSize) -> CGFloat {
        layoutDirection == .rightToLeft ? -translation.width : translation.width
    }

    private func settle(atPredictedWidth predictedWidth: CGFloat) {
        let outcome = sizing.outcome(predictedWidth: predictedWidth)
        withAnimation(settleAnimation) {
            switch outcome {
            case .rail:
                isExpanded = false
            case .expanded(let settled):
                expandedWidth = settled
                isExpanded = true
            }
            dragTravel = nil
        }
    }

    private var settleAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.15)
    }

    private var needsAttention: some View {
        RailButton(
            title: String(localized: "Needs attention"),
            isSelected: false,
            nameOpacity: nameOpacity,
            count: model.recoverySnapshot.needsAttentionCount,
            action: { sheet = .recoveryCenter }
        ) {
            RailIcon(systemImage: "exclamationmark.bubble", color: .primary)
        }
        .accessibilityValue(Text(model.recoverySnapshot.needsAttentionCount, format: .number))
        .accessibilityIdentifier("needs-attention")
    }

    private var newListButton: some View {
        Group {
            if newListStyle.isPinned {
                Button {
                    Task { await model.openNewList() }
                } label: {
                    Image(systemName: newListStyle.systemImage)
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("New List")
                .accessibilityShowsLargeContentViewer {
                    Label("New List", systemImage: newListStyle.systemImage)
                }
            } else {
                RailButton(
                    title: String(localized: "New List"),
                    isSelected: false,
                    nameOpacity: nameOpacity,
                    action: { Task { await model.openNewList() } }
                ) {
                    RailIcon(systemImage: newListStyle.systemImage, color: .secondary)
                }
            }
        }
        .accessibilityIdentifier("new-list")
#if DEBUG
        .anchorPreference(key: DevelopmentMenuBoundsKey.self, value: .bounds) { $0 }
#endif
    }
}

/// A row of the list column: the mark, then the name once the column is wide enough to show it.
private struct RailButton<Mark: View>: View {
    private static var length: CGFloat { 56 }
    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
    let title: String
    let isSelected: Bool
    let nameOpacity: Double
    var count: Int?
    let action: () -> Void
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                mark()
                    .frame(width: Self.length, height: Self.length)
                    .overlay(alignment: .topTrailing) {
                        if let count {
                            CountBadge(count: count)
                                .offset(x: -7, y: 7)
                                .opacity(1 - nameOpacity)
                        }
                    }
                // A zero-width minimum, a height cap while hidden, and the clip let the rail hide the
                // name without growing the row or spilling onto the card.
                HStack(spacing: 8) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let count { CountBadge(count: count) }
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .frame(
                    minWidth: 0, maxWidth: .infinity,
                    maxHeight: nameOpacity == 0 ? Self.length : nil,
                    alignment: .leading
                )
                .clipped()
                .opacity(nameOpacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The card's color ties the selected list to the page beside it.
                if isSelected { Self.shape.fill(Color(.systemBackground)) }
            }
            .contentShape([.interaction, .contextMenuPreview], Self.shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label { Text(title) } icon: { mark() }
        }
    }
}

private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count, format: .number)
            .lineLimit(1)
            .fixedSize()
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(.red, in: Capsule())
    }
}

private struct RailIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(color)
    }
}

private struct RailListMarkView: View {
    @Environment(\.self) private var environment
    let list: SnipList

    var body: some View {
        switch RailListMark(name: list.displayName, systemImage: list.displaySystemImage) {
        case .icon(let systemImage):
            RailIcon(systemImage: systemImage, color: list.accent.color)
        case .letters(let letters):
            Text(verbatim: letters)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(list.color == nil ? Color.primary : list.accent.filledControlLabel(in: environment))
                .padding(4)
                .frame(width: 36, height: 36)
                .background(list.color == nil ? Color(.systemGray4) : list.accent.color, in: Circle())
        }
    }
}
