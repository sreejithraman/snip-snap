import SnipSnapCore
import SwiftUI
import UIKit

private enum ListSelectorItem: Identifiable {
    case clipboard
    case list(SnipList)

    var id: String {
        switch self {
        case .clipboard: "clipboard-tab"
        case .list(let list): "list-tab-\(list.id.uuidString)"
        }
    }
    var page: LibraryPage {
        switch self {
        case .clipboard: .clipboard
        case .list(let list): .list(list.id)
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
        case .list(let list): list.displaySystemImage
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
    @GestureState private var gestureIsActive = false
    @State private var presentingCreation = false
    @State private var creationRequest = UUID()
    @AccessibilityFocusState private var focusedTabID: String?

    let model: IOSAppModel
    let controlLength: CGFloat
    let pageWidth: CGFloat
    @Binding var sheet: AppSheet?
    let deleteList: (UUID) async -> Void
    let createList: (LibraryPage, [LibraryPage]) async -> Void
    var labelViewport: CGFloat? = nil
    @Binding var motion: ListPageMotion
    let pageFrame: ListPageFrame

    private func openListManagement() {
        guard !model.isManagingLists, !motion.isDragging, !presentingCreation, sheet == nil else { return }
        motion.interrupt()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        model.haptics.emit(.selection, for: model.haptics.beginInteraction())
        withAnimation(animation) { model.isManagingLists = true }
    }

    private func activate(_ item: ListSelectorItem) {
        guard !model.isManagingLists else { return }
        if item.page == model.selectedPage { openListManagement() } else { select(item) }
    }

    private var animation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12)
    }

    private let edgeFadeFraction: CGFloat = 0.16

    private var direction: CGFloat { layoutDirection == .rightToLeft ? -1 : 1 }
    private var height: CGFloat { max(48, controlLength) }

    private var items: [ListSelectorItem] { [.clipboard] + model.lists.map(ListSelectorItem.list) }

    private func select(_ item: ListSelectorItem, feedback: Bool = true, animates: Bool = true) {
        guard item.page != model.selectedPage, !motion.isEnteringNewList,
              !motion.isCreatingFromEdge else { return }
        if animates, let destination = items.firstIndex(where: { $0.id == item.id }) {
            guard motion.select(destination, selectedPage: model.selectedPage,
                                pages: items.map(\.page), reduceMotion: reduceMotion, at: Date()) else { return }
        }
        model.selectPage(item.page)
        if feedback {
            model.haptics.emit(.selection, for: model.haptics.beginInteraction())
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ListSelectorGeometry(widths: items.map { width(for: $0, in: labelViewport ?? proxy.size.width) })
            let presentation = motionPresentation(in: geometry)

            selectorSurface(
                geometry: geometry, cursor: presentation.cursor, progress: presentation.progress,
                hoveringAdd: presentation.hoveringAdd, lensWidth: presentation.lensWidth, tint: presentation.tint,
                viewport: proxy.size.width
            )
            .simultaneousGesture(selectorDragGesture(geometry: geometry))
            .opacity(model.isManagingLists ? 0 : 1)
            .allowsHitTesting(!model.isManagingLists)
            .onChange(of: presentation.hoveringAdd ? items.count : presentation.nearest) { _, destination in
                guard motion.isSelectorDragging, !presentingCreation, sheet == nil else { return }
                model.haptics.emit(destination == items.count ? .snap : .selection, for: model.haptics.beginInteraction())
            }
            .onChange(of: gestureIsActive) { _, active in
                guard !active else { return }
                Task { @MainActor in
                    // onEnded and GestureState reset may arrive in either order.
                    await Task.yield()
                    guard !gestureIsActive else { return }
                    motion.cancelDrag(reduceMotion: reduceMotion, at: Date())
                }
            }

        }
        .frame(height: height + 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("list-selector")
        .listManagementMenu(
            model: model, deleteList: deleteList,
            createList: { Task { await createList(model.selectedPage, model.pages) } },
            sourceFocus: { focused in
                focusedTabID = focused && sheet == nil && !model.isSearchPresented && model.editingListID == nil
                    ? items.first(where: { $0.page == model.selectedPage })?.id : nil
            }
        )
        .accessibilityAction(named: Text("Manage Lists"), openListManagement)
        .accessibilityAction(named: Text("New List")) {
            Task { await createList(model.selectedPage, model.pages) }
        }
        .onChange(of: sheet) { _, destination in
            motion.interrupt()
            model.isManagingLists = false
            if destination == nil { resetCreation() }
        }
        .onChange(of: model.selectedListID) { _, _ in
            if presentingCreation { resetCreation() }
        }
        .onChange(of: model.selectedPage) { _, _ in
            model.isManagingLists = false
            if presentingCreation { resetCreation() }
        }
        .onChange(of: model.isSearchPresented) { _, isPresented in
            if isPresented { model.isManagingLists = false }
            if isPresented && presentingCreation { resetCreation() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.isManagingLists = false
                motion.interrupt()
                if sheet == nil { resetCreation() }
            }
        }
        .onDisappear {
            motion.interrupt()
            model.isManagingLists = false
            resetCreation()
        }
    }

    private struct MotionPresentation {
        let cursor: CGFloat
        let progress: CGFloat
        let hoveringAdd: Bool
        let nearest: Int
        let lensWidth: CGFloat
        let tint: Color
    }

    private func motionPresentation(in geometry: ListSelectorGeometry) -> MotionPresentation {
        let selected = items.firstIndex { $0.page == model.selectedPage } ?? 0
        let origin = geometry.centers.indices.contains(selected) ? geometry.centers[selected] : 0
        let directPresentation = pageFrame.selectorPresentation(in: geometry, reduceMotion: reduceMotion)
        let holdsAtAdd = motion.isCreatingFromEdge || motion.transition?.settlement?.createsList == true
        let creationProgress = pageFrame.creationProgress(
            dragProgress: motion.pageCreationProgress,
            holdsAtAdd: holdsAtAdd
        )
        let pagePullCursor = pageFrame.selectorPullCursor(
            in: geometry, progress: creationProgress, holdsAtAdd: holdsAtAdd
        )
        let position: CGFloat
        if let dragCursor = motion.dragCursor {
            position = dragCursor
        } else if reduceMotion, let settlement = motion.transition?.settlement,
                  !settlement.createsList {
            position = geometry.cursor(at: settlement.destination)
        } else if creationProgress > 0 {
            position = pagePullCursor
        } else if let directPresentation {
            position = directPresentation.cursor
        } else if motion.transition != nil {
            position = geometry.cursor(at: pageFrame.position)
        } else {
            position = origin
        }
        let settlesWithoutTravel = reduceMotion && motion.transition?.settlement != nil
            && motion.transition?.settlement?.createsList != true
        let progress = directPresentation?.addProgress ?? (settlesWithoutTravel ? 0
            : presentingCreation ? 1 : max(geometry.pullProgress(at: position), creationProgress))
        let hoveringAdd = directPresentation == nil && progress >= 1
        let resistedCursor = geometry.resisted(position)
        let pull = min(1, max(0, (progress - 0.2) / 0.8))
        let pullEase = pull * pull * (3 - 2 * pull)
        let cursor = directPresentation?.cursor
            ?? resistedCursor + (geometry.plusCenter - resistedCursor) * pullEase
        let nearest = geometry.nearestIndex(to: cursor)
        let baseWidth = geometry.lensWidth(at: cursor)
        let morph = min(1, max(0, (progress - 0.3) / 0.7))
        let morphEase = morph * morph * (3 - 2 * morph)
        let stretch = reduceMotion ? 0 : 30 * sin(.pi * progress) * (1 - morphEase)
        let lensWidth = baseWidth + (height - baseWidth) * morphEase + stretch
        let tint = items.indices.contains(nearest) ? items[nearest].color : Color.primary

        return MotionPresentation(
            cursor: cursor, progress: progress, hoveringAdd: hoveringAdd,
            nearest: nearest, lensWidth: lensWidth, tint: tint
        )
    }

    private func selectorSurface(
        geometry: ListSelectorGeometry, cursor: CGFloat, progress: CGFloat,
        hoveringAdd: Bool, lensWidth: CGFloat, tint: Color, viewport: CGFloat
    ) -> some View {
        ZStack {
            // Render each glass surface separately so the pill keeps its own edge.
            GlassEffectContainer(spacing: 0) {
                selectionGlass(width: lensWidth, tint: tint, addProgress: progress)
                    .scaleEffect(!reduceMotion && hoveringAdd ? 1.06 : 1)
                    .animation(animation, value: hoveringAdd)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            // Foreground labels need their own refraction at the glass rim.
            labels(geometry: geometry, cursor: cursor, viewport: viewport, progress: progress)
                .id(pageFrame.directEntrance == nil ? "regular-labels" : "new-list-labels")
                .transaction { $0.animation = nil }
                .modifier(ListLensEffect(width: lensWidth, height: height, viewport: viewport, enabled: !reduceTransparency))
                .mask(edgeFade)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background {
            if reduceTransparency {
                Capsule().fill(Color(uiColor: .systemBackground))
            } else {
                GlassEffectContainer(spacing: 0) {
                    Color.clear.glassEffect(.regular, in: Capsule())
                }
            }
        }
        .overlay {
            hitTargets(geometry: geometry, cursor: cursor)
        }
        .contentShape(Capsule())
    }

    private func selectorDragGesture(geometry: ListSelectorGeometry) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($gestureIsActive) { _, state, transaction in
                transaction.animation = nil
                state = true
            }
            .onChanged { value in
                guard !model.isManagingLists, !presentingCreation, sheet == nil else { return }
                motion.updateDrag(
                    translation: value.translation,
                    selectedPage: model.selectedPage,
                    pages: items.map(\.page),
                    geometry: geometry,
                    pageWidth: pageWidth,
                    layoutDirection: layoutDirection,
                    at: Date()
                )
            }
            .onEnded { value in
                guard !model.isManagingLists, !presentingCreation, sheet == nil else {
                    motion.interrupt()
                    return
                }
                switch motion.release(
                    translation: value.translation,
                    geometry: geometry,
                    reduceMotion: reduceMotion,
                    at: Date()
                ) {
                case .createList:
                    beginCreation()
                case .cancelNewList:
                    break // Only page swipes can cancel a New List editor.
                case .select(let index):
                    if items.indices.contains(index) { select(items[index], feedback: false, animates: false) }
                case nil:
                    break
                }
            }
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
        // Reserve the faded edges for previews of neighboring tabs.
        let maximumWidth = viewport * (1 - edgeFadeFraction * 2)
        return min(max(64, ceil(textWidth) + fontSize * 1.5 + 48), max(64, maximumWidth))
    }

    private func labelOffset(_ center: CGFloat, cursor: CGFloat) -> CGFloat {
        (center - cursor) * direction
    }

    private func labels(geometry: ListSelectorGeometry, cursor: CGFloat, viewport: CGFloat, progress: CGFloat) -> some View {
        let reveal = plusReveal(progress: progress)
        let trailingLabelOpacity = 1 - min(1, reveal * 2)
        return ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: item.systemImage)
                    Text(item.title).lineLimit(1)
                }
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(item.color)
                .opacity((pageFrame.directEntrance?.destination == item.page
                    ? Double(pageFrame.directEntrance?.selectorProgress ?? 1) : 1)
                    * (index == items.count - 1 ? Double(trailingLabelOpacity) : 1))
                .padding(.horizontal, 16)
                .frame(width: geometry.widths[index], height: height)
                .modifier(ListLabelPosition(x: labelOffset(geometry.centers[index], cursor: cursor)))
            }
            Image(systemName: "plus")
                .foregroundStyle(.primary)
                .font(.system(size: fontSize + (reduceMotion ? 8 : 8 * progress),
                              weight: .semibold, design: .rounded))
                .frame(width: height, height: height)
                .opacity(reveal)
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
        // Hover over Add when ready; reversing the pull returns it to the edge.
        let halfIcon = fontSize / 2
        let inset = viewport * edgeFadeFraction + halfIcon
        guard !reduceMotion else { return viewport / 2 }
        let edge = viewport / 2 + (viewport / 2 - inset) * direction
        return edge + (viewport / 2 - edge) * reveal
    }

    private func hitTargets(geometry: ListSelectorGeometry, cursor: CGFloat) -> some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let selected = item.page == model.selectedPage
                Button { activate(item) } label: { Color.clear.contentShape(Rectangle()) }
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.45, maximumDistance: 8)
                        .exclusively(before: TapGesture())
                        .onEnded { result in
                            switch result {
                            case .first: openListManagement()
                            case .second: activate(item)
                            }
                        }
                )
                .buttonStyle(.plain)
                .frame(width: geometry.widths[index], height: height + 8)
                .accessibilityFocused($focusedTabID, equals: item.id)
                .accessibilityLabel(item.title)
                .accessibilityHint(selected ? Text("Manage lists") : Text("Switch list; press and hold to manage lists"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(item.id)
                .accessibilityAction(named: Text("New List")) {
                    Task { await createList(model.selectedPage, model.pages) }
                }
                .accessibilityAdjustableAction { adjustment in
                    adjustItem(item.id, direction: adjustment)
                }
                .offset(x: labelOffset(geometry.centers[index], cursor: cursor))
                .disabled(presentingCreation || motion.isDragging || motion.isEnteringNewList
                          || motion.isCreatingFromEdge)
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
        guard !model.isManagingLists, !presentingCreation, sheet == nil, !model.isSearchPresented else { return }
        let sourcePage = model.selectedPage
        let sourcePages = model.pages
        if model.newListID != nil {
            Task {
                guard !model.isSearchPresented, sheet == nil,
                      model.selectedPage == sourcePage else {
                    motion.interrupt()
                    return
                }
                await createList(sourcePage, sourcePages)
            }
            return
        }
        let request = UUID()
        creationRequest = request
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            presentingCreation = true
        } completion: {
            guard presentingCreation, creationRequest == request,
                  model.selectedPage == sourcePage,
                  sheet == nil, !model.isSearchPresented else { return }
            Task {
                guard presentingCreation, creationRequest == request,
                      model.selectedPage == sourcePage,
                      sheet == nil, !model.isSearchPresented else { return }
                await createList(sourcePage, sourcePages)
                resetCreation()
            }
        }
    }

    private func resetCreation() {
        creationRequest = UUID()
        withAnimation(animation) { presentingCreation = false }
    }
}

// Keep the selection color smooth as the strip moves between lists.
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

// Interpolate the shader bounds with the capsule while its width snaps.
nonisolated private struct ListLensEffect: ViewModifier, Animatable {
    var width: CGFloat
    let height: CGFloat
    let viewport: CGFloat
    let enabled: Bool

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func body(content: Content) -> some View {
        content.distortionEffect(
            ShaderLibrary.listLens(.float4((viewport - width) / 2, 4, width, height)),
            maxSampleOffset: CGSize(width: 8, height: 8),
            isEnabled: enabled
        )
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
