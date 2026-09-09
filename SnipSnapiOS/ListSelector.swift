import SnipSnapCore
import SwiftUI
import UIKit

/// Geometry stays independent of list identity: the plus is an overscroll destination,
/// never an entry in the library or in the strip's resting layout.
struct ListSelectorGeometry {
    let widths: [CGFloat]
    static let spacing: CGFloat = 8
    static let pullThreshold: CGFloat = 96

    let centers: [CGFloat]

    init(widths: [CGFloat]) {
        self.widths = widths
        var edge: CGFloat = 0
        centers = widths.map { width in
            defer { edge += width + Self.spacing }
            return edge + width / 2
        }
    }

    var plusCenter: CGFloat {
        (centers.last ?? 0) + (widths.last ?? 0) / 2 + 32
    }

    func nearestIndex(to position: CGFloat) -> Int {
        centers.indices.min { abs(centers[$0] - position) < abs(centers[$1] - position) } ?? 0
    }

    func lensWidth(at position: CGFloat) -> CGFloat {
        guard let first = widths.first else { return 96 }
        guard let upper = centers.firstIndex(where: { $0 > position }) else { return widths.last ?? first }
        guard upper > 0 else { return first }
        let lower = upper - 1
        let fraction = (position - centers[lower]) / (centers[upper] - centers[lower])
        let blend = fraction * fraction * (3 - 2 * fraction)
        return widths[lower] + (widths[upper] - widths[lower]) * blend
    }

    func pullProgress(at position: CGFloat) -> CGFloat {
        min(1, max(0, position - (centers.last ?? 0)) / Self.pullThreshold)
    }

    func resisted(_ position: CGFloat) -> CGFloat {
        let first = centers.first ?? 0
        let last = centers.last ?? 0
        if position < first { return first + (position - first) * 0.3 }
        if position > last { return last + (position - last) * 0.35 }
        return position
    }
}

private enum ListSelectorItem: Identifiable {
    case clipboard
    case list(SnipList)

    var id: String {
        switch self {
        case .clipboard: "clipboard-tab"
        case .list(let list): "list-tab-\(list.id.uuidString)"
        }
    }
    var title: String {
        switch self {
        case .clipboard: String(localized: "Clipboard")
        case .list(let list): list.displayName
        }
    }
    var systemImage: String {
        switch self {
        case .clipboard: "clipboard"
        case .list(let list): list.systemImage
        }
    }
    var color: Color {
        switch self {
        case .clipboard: .primary
        case .list(let list): list.accent.color
        }
    }
}

struct ListSelector: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.self) private var environment
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 16
    @GestureState private var dragPosition: CGFloat?
    @State private var presentingCreation = false
    @State private var creationRequest = UUID()
    @State private var deletionTarget: SnipList?
    @State private var confirmsDeletion = false

    let model: IOSAppModel
    let controlLength: CGFloat
    @Binding var sheet: AppSheet?
    let deleteList: (UUID) async -> Void
    var labelViewport: CGFloat? = nil

    private var animation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12)
    }

    private let edgeFadeFraction: CGFloat = 0.16

    private var direction: CGFloat { layoutDirection == .rightToLeft ? -1 : 1 }
    private var height: CGFloat { max(48, controlLength) }

    private var items: [ListSelectorItem] { [.clipboard] + model.lists.map(ListSelectorItem.list) }
    private var selectedItemID: String {
        model.showsClipboard ? "clipboard-tab" : "list-tab-\(model.selectedListID.uuidString)"
    }

    private func select(_ item: ListSelectorItem, feedback: Bool = true) {
        guard item.id != selectedItemID else { return }
        switch item {
        case .clipboard: model.showsClipboard = true
        case .list(let list): model.selectList(list.id)
        }
        if feedback {
            model.haptics.emit(.selection, for: model.haptics.beginInteraction())
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ListSelectorGeometry(widths: items.map { width(for: $0, in: labelViewport ?? proxy.size.width) })
            let selected = items.firstIndex { $0.id == selectedItemID } ?? 0
            let origin = geometry.centers.indices.contains(selected) ? geometry.centers[selected] : 0
            let position = dragPosition ?? origin
            let progress = presentingCreation ? 1 : geometry.pullProgress(at: position)
            let hoveringAdd = progress >= 1
            let cursor = hoveringAdd ? geometry.plusCenter : geometry.resisted(position)
            let nearest = geometry.nearestIndex(to: cursor)
            let baseWidth = geometry.lensWidth(at: cursor)
            let lensWidth = baseWidth + (height - baseWidth) * progress
            let tint = items.indices.contains(nearest) ? items[nearest].color : Color.primary

            ZStack {
                Capsule().fill(.primary.opacity(0.05))
                selectionGlass(width: lensWidth, tint: tint, addProgress: progress)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                // Keep labels clear above the selection material.
                labels(geometry: geometry, cursor: cursor, viewport: proxy.size.width, progress: progress)
                    .mask(edgeFade)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                hitTargets(geometry: geometry, cursor: cursor)
            }
            .contentShape(Capsule())
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .updating($dragPosition) { value, state, transaction in
                        guard !presentingCreation, sheet == nil,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        transaction.animation = nil
                        state = origin - value.translation.width * direction
                    }
                    .onEnded { value in
                        guard !presentingCreation, sheet == nil,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        let released = origin - value.translation.width * direction
                        if geometry.pullProgress(at: released) >= 1 {
                            beginCreation()
                        } else {
                            let index = geometry.nearestIndex(to: released)
                            if items.indices.contains(index) {
                                select(items[index], feedback: false)
                            }
                        }
                    }
            )
            .animation(animation, value: hoveringAdd)
            .onChange(of: hoveringAdd ? items.count : nearest) { _, destination in
                guard dragPosition != nil, !presentingCreation, sheet == nil else { return }
                model.haptics.emit(destination == items.count ? .snap : .selection, for: model.haptics.beginInteraction())
            }
            // Animate only this strip after release, never the shared model update.
            .animation(dragPosition == nil ? animation : nil, value: dragPosition == nil)
            .animation(dragPosition == nil ? animation : nil, value: selectedItemID)
        }
        .frame(height: height + 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("list-selector")
        .accessibilityAction(named: Text("New List")) { Task { await model.openNewList() } }
        .onChange(of: sheet) { _, destination in
            if destination == nil { resetCreation() }
        }
        .onChange(of: model.selectedListID) { _, _ in
            if presentingCreation { resetCreation() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, sheet == nil { resetCreation() }
        }
        .onDisappear {
            resetCreation()
        }
        .listDeletionConfirmation(
            list: deletionTarget ?? model.selectedList,
            isPresented: $confirmsDeletion,
            delete: {
                guard let target = deletionTarget else { return }
                Task { await deleteList(target.id) }
            }
        )
    }

    private var edgeFade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: edgeFadeFraction),
            .init(color: .black, location: 1 - edgeFadeFraction), .init(color: .clear, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }

    private func selectionGlass(width: CGFloat, tint: Color, addProgress: CGFloat) -> some View {
        let listTint = tint.resolve(in: environment)
        let neutralTint = Color.primary.resolve(in: environment)
        let blend = Float(addProgress)
        let resolvedTint = Color.Resolved(
            red: listTint.red + (neutralTint.red - listTint.red) * blend,
            green: listTint.green + (neutralTint.green - listTint.green) * blend,
            blue: listTint.blue + (neutralTint.blue - listTint.blue) * blend,
            opacity: listTint.opacity + (neutralTint.opacity - listTint.opacity) * blend
        )
        return ListSelectionGlass(
            width: width,
            height: height,
            tint: resolvedTint,
            reduceTransparency: reduceTransparency
        )
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.2), value: tint)
    }

    private func width(for item: ListSelectorItem, in viewport: CGFloat) -> CGFloat {
        let font = UIFont.rounded(size: fontSize, weight: .semibold)
        let textWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
        return min(max(64, ceil(textWidth) + fontSize * 1.5 + 48), max(64, viewport - 96))
    }

    private func labelOffset(_ center: CGFloat, cursor: CGFloat) -> CGFloat {
        (center - cursor) * direction
    }

    private func labels(geometry: ListSelectorGeometry, cursor: CGFloat, viewport: CGFloat, progress: CGFloat) -> some View {
        let reveal = plusReveal(progress: progress)
        return ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: item.systemImage)
                    Text(item.title).lineLimit(1)
                }
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(item.color)
                .padding(.horizontal, 16)
                .frame(width: geometry.widths[index], height: height)
                .modifier(ListLabelPosition(x: labelOffset(geometry.centers[index], cursor: cursor)))
            }
            Image(systemName: "plus")
                .foregroundStyle(.primary)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .frame(width: height, height: height)
                .opacity(reduceMotion ? reveal : 1)
                .position(x: plusX(viewport: viewport, reveal: reveal), y: (height + 8) / 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }

    private func plusReveal(progress: CGFloat) -> CGFloat {
        // Spread travel through the edge fade across the full pull.
        progress * progress * (3 - 2 * progress)
    }

    private func plusX(viewport: CGFloat, reveal: CGFloat) -> CGFloat {
        if presentingCreation || reveal >= 1 { return viewport / 2 }
        // Hover over Add when ready; reversing the pull returns it to the edge.
        let halfIcon = fontSize / 2
        let inset = viewport * edgeFadeFraction + halfIcon
        guard !reduceMotion else { return viewport / 2 + (viewport / 2 - inset) * direction }
        let distance = viewport / 2 + halfIcon - (inset + halfIcon) * reveal
        return viewport / 2 + distance * direction
    }

    private func hitTargets(geometry: ListSelectorGeometry, cursor: CGFloat) -> some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let selected = item.id == selectedItemID
                Group {
                    if selected {
                        ListActionsMenu {
                            var actions = [UIAction(title: String(localized: "New List"), image: UIImage(systemName: "plus"), identifier: UIAction.Identifier("new-list")) { _ in Task { await model.openNewList() } }]
                            if case .list(let list) = item, list.id != SnipList.inboxID {
                                actions.append(UIAction(title: String(localized: "Edit List…"), image: UIImage(systemName: "pencil")) { _ in model.editListInline(id: list.id) })
                                actions.append(UIAction(title: String(localized: "Delete List"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                                    model.haptics.invalidatePendingFeedback()
                                    deletionTarget = list
                                    confirmsDeletion = true
                                })
                            }
                            return UIMenu(children: actions)
                        }
                    } else {
                        Button {
                            select(item)
                        } label: { Color.clear.contentShape(Rectangle()) }
                    }
                }
                .buttonStyle(.plain)
                .frame(width: geometry.widths[index], height: height + 8)
                .accessibilityLabel(item.title)
                .accessibilityHint(selected ? Text("List actions") : Text("Switch list"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(item.id)
                .accessibilityAction(named: Text("New List")) { Task { await model.openNewList() } }
                .accessibilityAdjustableAction { adjustment in
                    adjustItem(item.id, direction: adjustment)
                }
                .offset(x: labelOffset(geometry.centers[index], cursor: cursor))
                .disabled(presentingCreation || dragPosition != nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func adjustItem(_ id: String, direction: AccessibilityAdjustmentDirection) {
        guard let current = items.firstIndex(where: { $0.id == id }) else { return }
        let next: Int
        switch direction {
        case .increment: next = current + 1
        case .decrement: next = current - 1
        @unknown default: return
        }
        guard items.indices.contains(next) else { return }
        select(items[next])
    }

    private func beginCreation() {
        guard !presentingCreation, sheet == nil else { return }
        let request = UUID()
        creationRequest = request
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            presentingCreation = true
        } completion: {
            guard presentingCreation, creationRequest == request, sheet == nil else { return }
            Task {
                await model.openNewList()
                resetCreation()
            }
        }
    }

    private func resetCreation() {
        creationRequest = UUID()
        withAnimation(animation) { presentingCreation = false }
    }
}

// Open only after a completed tap, so a slow swipe cannot open the menu.
private struct ListActionsMenu: UIViewRepresentable {
    let menu: () -> UIMenu

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.addInteraction(context.coordinator.interaction)
        button.addTarget(context.coordinator, action: #selector(Coordinator.showMenu), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.isEnabled = context.environment.isEnabled
        context.coordinator.menu = menu
    }

    func makeCoordinator() -> Coordinator { Coordinator(menu: menu) }

    @MainActor
    final class Coordinator: NSObject, @MainActor UIEditMenuInteractionDelegate {
        var menu: () -> UIMenu
        lazy var interaction = UIEditMenuInteraction(delegate: self)

        init(menu: @escaping () -> UIMenu) { self.menu = menu }

        @objc func showMenu(_ button: UIButton) {
            interaction.presentEditMenu(with: UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: CGPoint(x: button.bounds.midX, y: 0)
            ))
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            menu()
        }
    }
}

// Interpolate the channels explicitly: the native glass tint itself switches
// discretely even when its surrounding layout has an animation transaction.
nonisolated private struct ListSelectionGlass: View, Animatable {
    let width: CGFloat
    let height: CGFloat
    var tint: Color.Resolved
    let reduceTransparency: Bool

    var animatableData: AnimatablePair<AnimatablePair<Float, Float>, AnimatablePair<Float, Float>> {
        get { AnimatablePair(AnimatablePair(tint.red, tint.green), AnimatablePair(tint.blue, tint.opacity)) }
        set {
            tint = Color.Resolved(
                red: newValue.first.first,
                green: newValue.first.second,
                blue: newValue.second.first,
                opacity: newValue.second.second
            )
        }
    }

    var body: some View {
        let color = Color(tint)
        if reduceTransparency {
            Capsule().fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay { Capsule().strokeBorder(color, lineWidth: 1) }
                .frame(width: width, height: height)
        } else {
            Color.clear.frame(width: width, height: height)
                .glassEffect(.clear.tint(color.opacity(0.1)), in: Capsule())
        }
    }
}

// Offset from the layout center so resizing the track cannot move a label.
// Animate the whole label as one value. Implicit child layout animation can
// otherwise let SwiftUI's text rendering lag behind the symbol during a snap.
nonisolated private struct ListLabelPosition: ViewModifier, Animatable {
    var x: CGFloat

    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(x: x)
            .transaction { $0.animation = nil }
    }
}
