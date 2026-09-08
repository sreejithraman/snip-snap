import SnipSnapCore
import SwiftUI
import UIKit

/// Geometry stays independent of list identity: the plus is an overscroll destination,
/// never an entry in the library or in the strip's resting layout.
struct ListSelectorGeometry {
    let widths: [CGFloat]
    static let spacing: CGFloat = 8
    static let pullThreshold: CGFloat = 72

    var centers: [CGFloat] {
        var edge: CGFloat = 0
        return widths.map { width in
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

    func pullProgress(at position: CGFloat) -> CGFloat {
        min(1, max(0, position - (centers.last ?? 0)) / Self.pullThreshold)
    }

    func resisted(_ position: CGFloat) -> CGFloat {
        let first = centers.first ?? 0
        let last = centers.last ?? 0
        if position < first { return first + (position - first) * 0.3 }
        if position > last { return last + (position - last) * 0.6 }
        return position
    }
}

struct ListSelector: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.self) private var environment
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 16
    @GestureState private var translation: CGFloat = 0
    @State private var presentingCreation = false
    @State private var creationRequest = UUID()
    @State private var deletionTarget: SnipList?
    @State private var confirmsDeletion = false

    let model: IOSAppModel
    let controlLength: CGFloat
    @Binding var sheet: AppSheet?
    let deleteList: (UUID) async -> Void

    private var animation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12)
    }

    private var direction: CGFloat { layoutDirection == .rightToLeft ? -1 : 1 }
    private var height: CGFloat { max(48, controlLength) }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ListSelectorGeometry(widths: model.lists.map { width(for: $0, in: proxy.size.width) })
            let selected = model.lists.firstIndex { $0.id == model.selectedListID } ?? 0
            let origin = geometry.centers.indices.contains(selected) ? geometry.centers[selected] : 0
            let position = origin - translation * direction
            let progress = presentingCreation ? 1 : geometry.pullProgress(at: position)
            let cursor = presentingCreation ? geometry.plusCenter : geometry.resisted(position)
            let nearest = geometry.nearestIndex(to: cursor)
            let baseWidth = geometry.widths.indices.contains(nearest) ? geometry.widths[nearest] : 96
            let lensWidth = baseWidth + (48 - baseWidth) * progress
            let tint = model.lists.indices.contains(nearest) ? model.lists[nearest].accent.color : Color.primary

            ZStack {
                Capsule().fill(.primary.opacity(0.05))
                selectionGlass(width: lensWidth, tint: tint)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                // Keep text above the material. A single sample bends only the curved rim.
                labels(geometry: geometry, cursor: cursor, viewport: proxy.size.width, progress: progress)
                    .modifier(ListLensEffect(width: lensWidth, height: height, viewport: proxy.size.width, enabled: !reduceTransparency))
                    .mask(edgeFade)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                hitTargets(geometry: geometry, cursor: cursor, viewport: proxy.size.width)
            }
            .contentShape(Capsule())
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .updating($translation) { value, state, _ in
                        guard !presentingCreation, sheet == nil,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        state = value.translation.width
                    }
                    .onEnded { value in
                        guard !presentingCreation, sheet == nil,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        let released = origin - value.translation.width * direction
                        if geometry.pullProgress(at: released) >= 1 {
                            beginCreation()
                        } else {
                            let index = geometry.nearestIndex(to: released)
                            if model.lists.indices.contains(index) {
                                withAnimation(animation) { model.selectList(model.lists[index].id) }
                            }
                        }
                    }
            )
            .animation(animation, value: translation == 0)
        }
        .frame(height: height + 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("list-selector")
        .accessibilityAction(named: Text("New List")) { sheet = .newList }
        .onChange(of: sheet) { _, destination in
            if destination == nil { resetCreation() }
        }
        .onChange(of: model.selectedListID) { _, _ in
            if presentingCreation, sheet != .newList { resetCreation() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, sheet == nil { resetCreation() }
        }
        .onDisappear { resetCreation() }
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
            .init(color: .clear, location: 0), .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.92), .init(color: .clear, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }

    private func selectionGlass(width: CGFloat, tint: Color) -> some View {
        ListSelectionGlass(
            width: width,
            height: height,
            tint: tint.resolve(in: environment),
            reduceTransparency: reduceTransparency
        )
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.2), value: tint)
    }

    private func width(for list: SnipList, in viewport: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let textWidth = (list.displayName as NSString).size(withAttributes: [.font: font]).width
        return min(max(64, ceil(textWidth) + fontSize * 1.5 + 48), max(64, viewport - 96))
    }

    private func x(_ center: CGFloat, cursor: CGFloat, viewport: CGFloat) -> CGFloat {
        viewport / 2 + (center - cursor) * direction
    }

    private func labels(geometry: ListSelectorGeometry, cursor: CGFloat, viewport: CGFloat, progress: CGFloat) -> some View {
        ZStack {
            ForEach(Array(model.lists.enumerated()), id: \.element.id) { index, list in
                HStack(spacing: 8) {
                    Image(systemName: list.systemImage)
                    Text(list.displayName).lineLimit(1)
                }
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(list.accent.color)
                .padding(.horizontal, 16)
                .frame(width: geometry.widths[index], height: height)
                .position(x: x(geometry.centers[index], cursor: cursor, viewport: viewport), y: (height + 8) / 2)
            }
            Image(systemName: "plus")
                .font(.system(size: fontSize, weight: .semibold))
                .frame(width: 48, height: height)
                .opacity(progress)
                .position(x: plusX(geometry: geometry, cursor: cursor, viewport: viewport, progress: progress), y: (height + 8) / 2)
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func plusX(geometry: ListSelectorGeometry, cursor: CGFloat, viewport: CGFloat, progress: CGFloat) -> CGFloat {
        let destination = x(geometry.plusCenter, cursor: cursor, viewport: viewport)
        guard !reduceMotion else { return destination }
        let outerEdge = viewport / 2 + (viewport / 2 + 24) * direction
        // Follow the pull from outside the strip; the existing release spring
        // finishes the move to the center only after a committed pull.
        let reveal = 1 - (1 - progress) * (1 - progress)
        return outerEdge + (destination - outerEdge) * reveal
    }

    private func hitTargets(geometry: ListSelectorGeometry, cursor: CGFloat, viewport: CGFloat) -> some View {
        ZStack {
            ForEach(Array(model.lists.enumerated()), id: \.element.id) { index, list in
                let selected = list.id == model.selectedListID
                Group {
                    if selected {
                        Menu {
                            Button("New List", systemImage: "plus") { sheet = .newList }
                                .accessibilityIdentifier("new-list")
                            if list.id != SnipList.inboxID {
                                Button("Edit List…", systemImage: "pencil") { sheet = .editList(id: list.id) }
                                Button("Delete List", systemImage: "trash", role: .destructive) {
                                    model.haptics.invalidatePendingFeedback()
                                    deletionTarget = list
                                    confirmsDeletion = true
                                }
                            }
                        } label: { Color.clear.contentShape(Rectangle()) }
                    } else {
                        Button {
                            withAnimation(animation) { model.selectList(list.id) }
                        } label: { Color.clear.contentShape(Rectangle()) }
                    }
                }
                .buttonStyle(.plain)
                .frame(width: geometry.widths[index], height: height + 8)
                .accessibilityLabel(list.displayName)
                .accessibilityHint(selected ? Text("List actions") : Text("Switch list"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("list-tab-\(list.id.uuidString)")
                .accessibilityAction(named: Text("New List")) { sheet = .newList }
                .accessibilityAdjustableAction { adjustment in
                    let current = model.lists.firstIndex { $0.id == model.selectedListID } ?? 0
                    let next: Int
                    switch adjustment {
                    case .increment: next = current + 1
                    case .decrement: next = current - 1
                    @unknown default: return
                    }
                    guard model.lists.indices.contains(next) else { return }
                    model.selectList(model.lists[next].id)
                }
                .position(x: x(geometry.centers[index], cursor: cursor, viewport: viewport), y: (height + 8) / 2)
                .disabled(presentingCreation)
            }
        }
        .clipped()
    }

    private func beginCreation() {
        guard !presentingCreation, sheet == nil else { return }
        let request = UUID()
        creationRequest = request
        model.haptics.emit(.selection, for: model.haptics.beginInteraction())
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            presentingCreation = true
        } completion: {
            guard presentingCreation, creationRequest == request, sheet == nil else { return }
            sheet = .newList
        }
    }

    private func resetCreation() {
        creationRequest = UUID()
        withAnimation(animation) { presentingCreation = false }
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
