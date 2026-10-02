import SnipSnapCore
import SwiftUI

/// Gathering is a projection of selection, never a change to list membership.
struct GatheredSnipsDock: View {
    let model: IOSAppModel
    let copyShare: IOSCopyShareCoordinator
    let isPerformingAction: Bool
    let move: (UUID) -> Void
    let delete: () -> Void
    let performAction: (@escaping @MainActor () async -> Bool) -> Void
    let cancel: () -> Void
    let previewAttachment: (SnipAttachment) -> Void
    let containerFrame: CGRect
    var arrivingSnipIDs: Set<UUID> = []
    var settleArrivals: () -> Void = {}
    var cardFramesChanged: ([UUID: CGRect]) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var showsContents: Bool {
        get { model.isSelectionExpanded }
        nonmutating set { model.isSelectionExpanded = newValue }
    }
    @State private var isMoveMenuPresented = false
    @State private var headerFrame = CGRect.zero
    @State private var cardHeights: [UUID: CGFloat] = [:]
    @State private var actionRowHeight: CGFloat = 44
    @AccessibilityFocusState private var focusedControl: ContentsFocus?
    @State private var viewportFrame = CGRect.zero
    @State private var pendingCardFrames: [UUID: CGRect] = [:]
    @State private var scrollPhase = ScrollPhase.idle
    @State private var selectionScrollPosition = ScrollPosition(idType: UUID.self)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .body) private var returnControlDiameter: CGFloat = 28

    private enum ContentsFocus: Hashable {
        case stack
        case putBack(UUID)
        case instructions
    }

    private var morphAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.06)
    }

    private var cardGap: CGFloat { 12 }
    private var usesCompactControls: Bool {
        verticalSizeClass == .compact || (containerFrame.height > 0 && containerFrame.height < 400)
    }
    private var minimumCardHeight: CGFloat { max(44, returnControlDiameter) + 20 }
    private var landedCount: Int { snips.lazy.filter { !arrivingSnipIDs.contains($0.id) }.count }
    private func boundedViewportHeight(_ contentHeight: CGFloat) -> CGFloat {
        // Keep the controls and one source row reachable in short windows.
        let chrome = usesCompactControls ? headerFrame.height : headerFrame.height + actionRowHeight
        let gaps = usesCompactControls ? cardGap : cardGap * 2
        let available = containerFrame.height - chrome - gaps - 24 - 16 - 80
        let minimum = minimumCardHeight
        return min(max(minimum, contentHeight), 320, max(minimum, available))
    }
    private var contentsViewportHeight: CGFloat { boundedViewportHeight(projectedContentsHeight) }
    private var projectedContentsHeight: CGFloat {
        snips.reduce(CGFloat.zero) { $0 + (cardHeights[$1.id] ?? 64) } + CGFloat(max(0, snips.count - 1)) * 8
    }
    private var previewSnip: Snip? { snips.first { !arrivingSnipIDs.contains($0.id) } }
    private var targetCardFrames: [UUID: CGRect] {
        guard !viewportFrame.isEmpty else { return [:] }
        let height = showsContents ? boundedViewportHeight(projectedContentsHeight)
            : min(firstCardHeight, boundedViewportHeight(projectedContentsHeight))
        let viewport = CGRect(x: viewportFrame.minX, y: viewportFrame.maxY - height,
                              width: viewportFrame.width, height: height)
        var frames: [UUID: CGRect] = [:]
        for snip in snips {
            let cardHeight = cardHeights[snip.id] ?? 64
            if arrivingSnipIDs.contains(snip.id), cardHeights[snip.id] != nil {
                let card: CGRect
                if showsContents {
                    guard let measured = pendingCardFrames[snip.id] else { continue }
                    card = measured
                } else {
                    card = CGRect(x: viewport.minX, y: viewport.minY,
                                  width: viewport.width, height: cardHeight)
                }
                let visible = card.intersection(showsContents ? viewportFrame : viewport)
                // Fast repeated selections can settle beneath the visible cards.
                frames[snip.id] = visible.isNull || visible.isEmpty
                    ? CGRect(x: viewport.minX, y: viewport.maxY - 44, width: viewport.width, height: 44)
                    : visible
            }
        }
        return frames
    }

    private var snips: [Snip] { model.selectedSnips }
    private var destinations: [SnipList] { model.moveDestinations(for: snips) }
    private var cardContentWidth: CGFloat? {
        guard viewportFrame.width > 0 else { return nil }
        // Hidden native buttons can propose a narrower text column. Pin both states
        // to the real viewport so the transfer and landed card measure identically.
        return max(1, viewportFrame.width - 24 - max(44, returnControlDiameter) - 8)
    }
    private var firstCardHeight: CGFloat { snips.first.flatMap { cardHeights[$0.id] } ?? minimumCardHeight }
    private var compactViewportHeight: CGFloat { min(firstCardHeight, contentsViewportHeight) }
    var body: some View {
        VStack(alignment: .leading, spacing: snips.isEmpty ? 12 : cardGap) {
            containerControls
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { headerFrame = $0 }
            stack
                .zIndex(1)
            if !usesCompactControls { actionRow }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26))
        .padding(.horizontal, SnipSnapSpacing.cardContentInset)
        .padding(.vertical, 8)
        .disabled(isPerformingAction)
        .onChange(of: snips.isEmpty) { _, isEmpty in
            if isEmpty { showsContents = false }
        }
        .onChange(of: targetCardFrames, initial: true) { _, frames in cardFramesChanged(frames) }
        .onChange(of: model.selectedSnipIDs) { _, ids in
            cardHeights = cardHeights.filter { ids.contains($0.key) }
            pendingCardFrames = pendingCardFrames.filter { ids.contains($0.key) }
        }
        .onChange(of: arrivingSnipIDs) { _, ids in
            pendingCardFrames = pendingCardFrames.filter { ids.contains($0.key) }
            if showsContents && (scrollPhase == .tracking || scrollPhase == .interacting || scrollPhase == .decelerating) {
                settleArrivals()
            } else if showsContents, let first = snips.first, ids.contains(first.id) {
                scrollTo(first.id)
            }
        }

    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            moveMenu
            Spacer(minLength: 0)
            Button {
                let captured = snips
                Task { await copyShare.copy(snips: captured, model: model) }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(minWidth: 30, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(SnipSnapTheme.actionAccent)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("copy-selection")

            Button(role: .destructive, action: delete) {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(minWidth: 30, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("delete-selection")

            SelectionActionsMenu(model: model, copyShare: copyShare, performAction: performAction)
        }
        .disabled(snips.isEmpty)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionRowHeight = $0 }
    }


    private var stack: some View {
        // One mounted set of cards keeps the first card and its glass unchanged.
        // Top anchoring keeps content steady as the native viewport opens.
        contents
        .frame(height: showsContents ? contentsViewportHeight : compactViewportHeight, alignment: .top)
        .modifier(SelectedCardsViewport(height: showsContents ? contentsViewportHeight : compactViewportHeight))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewportFrame = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if landedCount == 0 {
                Label("Tap items to select", systemImage: "square.stack")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: minimumCardHeight)
                    .accessibilityIdentifier("gathering-instructions")
                    .accessibilityFocused($focusedControl, equals: .instructions)
            }
        }
        .background {
            ForEach(0..<min(2, max(0, snips.lazy.filter { !arrivingSnipIDs.contains($0.id) }.count - 1)), id: \.self) { layer in
                RoundedRectangle(cornerRadius: 18)
                    .fill(.clear)
                    .modifier(GatheringGlassSurface(isInteractive: false, reduceTransparency: reduceTransparency))
                    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
                    .frame(height: compactViewportHeight)
                    .padding(.horizontal, CGFloat(layer + 1) * 4)
                    .offset(y: -CGFloat(layer + 1) * 4)
                    .opacity(showsContents ? 0 : 1)
                    .zIndex(-Double(layer + 1))
            }
        }
        .overlay(alignment: .topLeading) {
            if !showsContents {
                // The closed viewport can keep an incoming lazy row offscreen.
                // Measure only arrivals, using the canonical content and width.
                ZStack(alignment: .topLeading) {
                    ForEach(snips.filter { arrivingSnipIDs.contains($0.id) && cardHeights[$0.id] == nil }) { snip in
                        cardContent(snip)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
        }
        .overlay {
            if !showsContents && !snips.isEmpty {
                Button { setShowsContents(true) } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 12 + max(44, returnControlDiameter) + 8)
                .accessibilityLabel("Selected items")
                .accessibilityValue(snips.count == 1 ? Text("1 item") : Text("\(snips.count) items"))
                .accessibilityHint("Tap to view selected items.")
                .accessibilityIdentifier("gathered-stack")
                .accessibilityFocused($focusedControl, equals: .stack)
            }
        }

    }

    private func gatheredCard(_ snip: Snip, isPreview: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            SnipCircularControl(
                systemImage: "arrow.uturn.backward",
                appearance: listAppearance(for: snip, in: model.lists)
            ) { putBack(snip) }
            .accessibilityLabel("Deselect: \(summary(snip))")
            .accessibilityIdentifier("put-back-\(snip.id)")
            .accessibilityFocused($focusedControl, equals: .putBack(snip.id))

            cardContent(snip, isPreview: isPreview)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(GatheringGlassSurface(
            isInteractive: isPreview,
            reduceTransparency: reduceTransparency,
            isVisible: (isPreview || showsContents) && !arrivingSnipIDs.contains(snip.id)
        ))
    }

    private func cardContent(_ snip: Snip, isPreview: Bool = false) -> some View {
        let proposedWidth = cardContentWidth
        return VStack(alignment: .leading, spacing: 8) {
            SnipContentView(
                snip: snip,
                model: model,
                isRecovered: model.isRecoveredSnip(snip.id),
                lineLimit: nil,
                loadsAttachmentPreviews: (isPreview || showsContents) && !arrivingSnipIDs.contains(snip.id),
                onPreviewAttachment: isPreview ? nil : previewAttachment
            )
            if isPerformingAction { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        .frame(width: proposedWidth, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { CGSize(width: proposedWidth ?? 0, height: $0.size.height) } action: { size in
            // Include the proposal: it can settle without the content height changing.
            guard size.width > 0, size.height >= 44 else { return }
            cardHeights[snip.id] = max(size.height, max(44, returnControlDiameter)) + 20
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SnipContentView.accessibilityLabel(for: snip))
        .accessibilityValue(
            snip.isPinned ? String(localized: "Pinned") : SnipCompletionLanguage.stateTitle(isDone: snip.isDone)
        )
        .accessibilityIdentifier("selected-card-content-\(snip.id)")
    }

    private func putBack(_ snip: Snip) {
        let index = snips.firstIndex { $0.id == snip.id } ?? 0
        let next = index + 1 < snips.count ? snips[index + 1] : (index > 0 ? snips[index - 1] : nil)
        withAnimation(morphAnimation) {
            model.selectSnips(model.selectedSnipIDs.subtracting([snip.id]))
        }
        focusedControl = showsContents ? next.map { .putBack($0.id) } ?? .instructions
            : (next == nil ? .instructions : .stack)
    }

    private func setShowsContents(_ expanded: Bool) {
        withAnimation(morphAnimation) { showsContents = expanded }
        focusedControl = expanded ? snips.first.map { .putBack($0.id) } : .stack
    }

    private var moveMenu: some View {
        Button { isMoveMenuPresented.toggle() } label: {
            Label("Move to…", systemImage: "folder")
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
                .frame(minWidth: 30, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(SnipSnapTheme.actionAccent)
        .foregroundStyle(SnipSnapTheme.actionLabel)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityIdentifier("move-gathered")
        .accessibilityHint("Choose a destination list or add a new list for selected items.")
        .glassMenu(isPresented: $isMoveMenuPresented, label: "Move to list", identifier: "selection-move-panel") { _ in
            VStack(spacing: 2) {
                MoveDestinationOptions(
                    destinations: destinations,
                    identifierPrefix: "move-gathered-to-",
                    move: { id in isMoveMenuPresented = false; move(id) },
                    addList: {
                        isMoveMenuPresented = false
                        model.requestNewListMove(snips: snips, fromSelection: true)
                    }
                )
            }
            .padding(6)
            .buttonStyle(GlassMenuActionStyle())
        }
        .onChange(of: model.selectedSnipIDs) { _, ids in
            if ids.isEmpty { isMoveMenuPresented = false }
        }
    }

    private var contents: some View {
        ScrollView {
            GlassEffectContainer(spacing: 4) {
                LazyVStack(spacing: 8) {
                    ForEach(snips) { snip in
                        // Reserve the destination's layout until its flying copy lands.
                        let isArriving = arrivingSnipIDs.contains(snip.id)
                        let isVisible = (showsContents || snip.id == previewSnip?.id) && !isArriving
                        gatheredCard(snip, isPreview: snip.id == previewSnip?.id && !showsContents)
                            .frame(height: isArriving ? cardHeights[snip.id] : nil, alignment: .top)
                            .id(snip.id)
                            .onGeometryChange(for: SelectedCardMeasurement.self) {
                                SelectedCardMeasurement(id: snip.id, frame: $0.frame(in: .global),
                                                        isArriving: arrivingSnipIDs.contains(snip.id))
                            } action: { measurement in
                                if measurement.isArriving { pendingCardFrames[measurement.id] = measurement.frame }
                            }
                            .modifier(SelectedCardArrivalVisibility(isArriving: isArriving))
                            .opacity(isVisible ? 1 : 0)
                            .transaction { transaction in
                                if arrivingSnipIDs.contains(snip.id) {
                                    // The new row must start hidden, without inheriting insertion motion.
                                    transaction.animation = nil
                                    transaction.disablesAnimations = true
                                }
                            }
                            .transition(.identity)
                            .allowsHitTesting(isVisible)
                            .accessibilityHidden(!isVisible)
                    }
                }
                .scrollTargetLayout()
            }
        }
        .scrollPosition($selectionScrollPosition)
        .defaultScrollAnchor(.top)
        .scrollDisabled(!showsContents)
        .onScrollPhaseChange { _, phase in
            scrollPhase = phase
            if phase == .tracking || phase == .interacting || phase == .decelerating {
                settleArrivals()
            } else if phase == .idle, let first = snips.first, arrivingSnipIDs.contains(first.id) {
                scrollTo(first.id)
            }
        }
        .accessibilityIdentifier(showsContents ? "gathered-contents" : "gathered-preview")
        .accessibilityLabel(showsContents ? Text("Selected items") : Text(""))
        .accessibilityValue(showsContents
            ? (snips.count == 1 ? Text("1 item") : Text("\(snips.count) items")) : Text(""))
        .onChange(of: showsContents ? nil : previewSnip?.id) { _, firstID in
            guard let firstID else { return }
            scrollTo(firstID)
        }
        .onChange(of: snips.map(\.id)) { previousIDs, _ in
            if showsContents, scrollPhase == .idle, let first = snips.first, !previousIDs.contains(first.id) {
                scrollTo(first.id)
            } else if !showsContents, let first = previewSnip {
                scrollTo(first.id)
            }
        }
    }

    private func scrollTo(_ id: UUID) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        // Native scroll position retains the request until a new lazy target is laid out.
        withTransaction(transaction) { selectionScrollPosition.scrollTo(id: id, anchor: .top) }
    }

    private var containerControls: some View {
        HStack(spacing: 8) {
            cancelButton
            if usesCompactControls {
                actionRow
            } else {
                Spacer(minLength: 0)
            }
            contentsButton
        }
    }

    private var cancelButton: some View {
        Button {
            withAnimation(morphAnimation) {
                showsContents = false
                cancel()
            }
        } label: {
            Label("Cancel", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
                .frame(minWidth: 30, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(SnipSnapTheme.actionAccent)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint("Deselect all items and return them to their lists.")
        .accessibilityIdentifier("finish-selecting")
    }

    private var contentsButton: some View {
        Button { setShowsContents(!showsContents) } label: {
            ZStack {
                Text(landedCount, format: .number)
                    .monospacedDigit()
                    .opacity(showsContents ? 0 : 1)
                Image(systemName: "chevron.down")
                    .opacity(showsContents ? 1 : 0)
            }
                .font(.system(size: 17, weight: .semibold))
                .frame(minWidth: 30, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(SnipSnapTheme.actionAccent)
        .frame(minWidth: 44, minHeight: 44)
        .opacity(snips.isEmpty ? 0 : 1)
        .disabled(snips.isEmpty)
        .accessibilityHidden(snips.isEmpty)
        .accessibilityLabel(showsContents ? "Collapse Selection" : "Expand Selection")
        .accessibilityValue(landedCount == 1 ? Text("1 item") : Text("\(landedCount) items"))
        .accessibilityHint(showsContents ? "Show the selected items as a stack." : "View the selected items in this container.")
        .accessibilityIdentifier(showsContents ? "collapse-gathered" : "expand-gathered")
    }

    private func summary(_ snip: Snip) -> String {
        if !snip.content.isEmpty { return snip.content }
        let names = snip.attachments.map(\.fileName).joined(separator: ", ")
        return names.isEmpty ? String(localized: "Attachments") : names
    }
}

private struct SelectedCardMeasurement: Equatable {
    let id: UUID
    let frame: CGRect
    let isArriving: Bool
}

/// Bound vertical scrolling without cutting off glass that renders beyond a card's sides.
private struct SelectedCardsViewport: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .scrollClipDisabled()
            .padding(.horizontal, 12)
            .frame(height: height, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .padding(.horizontal, -12)
    }
}

/// Keeps the destination measured without drawing a second copy during arrival.
private struct SelectedCardArrivalVisibility: ViewModifier {
    let isArriving: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isArriving {
            content.hidden()
        } else {
            content
        }
    }
}

struct GatheringGlassSurface: ViewModifier {
    var isInteractive = false
    let reduceTransparency: Bool
    var isVisible = true

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(isVisible ? 1 : 0), in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(isVisible ? 0.18 : 0), lineWidth: 1) }
        } else {
            content.glassEffect(
                isVisible ? (isInteractive ? .regular.interactive() : .regular) : .identity,
                in: RoundedRectangle(cornerRadius: 18)
            )
        }
    }
}

/// Transient transfer state; selection and list membership remain model-owned.
struct GatheringFlight: Identifiable {
    let id = UUID()
    let snip: Snip
    let source: CGRect
    let sourceIsSelecting: Bool
    var destination: CGRect?
}

struct GatheringFlightView: View {
    let flight: GatheringFlight
    let model: IOSAppModel
    let origin: CGPoint
    let completed: () -> Void
    @State private var progress: CGFloat = 0
    @State private var arrivalFrame: CGRect?
    @State private var arrivalRevision = 0

    var body: some View {
        GatheringTransferCard(
            snip: flight.snip, model: model, sourceIsSelecting: flight.sourceIsSelecting,
            frame: arrivalFrame ?? flight.source, origin: origin, progress: progress
        )
        .task(id: flight.destination) {
            guard let destination = flight.destination else {
                // Layout can disappear during navigation or offscreen realization.
                // Keep selection usable even if no landing frame ever arrives.
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                completed()
                return
            }
            if progress == 0 { await Task.yield() }
            guard !Task.isCancelled else { return }
            arrivalRevision += 1
            let revision = arrivalRevision
            withAnimation(.easeInOut(duration: 0.36), completionCriteria: .removed) {
                arrivalFrame = destination
                progress = 1
            } completion: {
                if arrivalRevision == revision { completed() }
            }
        }
    }
}

/// One canonical content view travels intact; only its framing and control change.
nonisolated private struct GatheringTransferCard: View, Animatable {
    let snip: Snip
    let model: IOSAppModel
    let sourceIsSelecting: Bool
    var frame: CGRect
    let origin: CGPoint
    var progress: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    typealias AnimatableData = AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>>
    var animatableData: AnimatableData {
        get { .init(.init(frame.minX, frame.minY), .init(.init(frame.width, frame.height), progress)) }
        set {
            frame = CGRect(x: newValue.first.first, y: newValue.first.second,
                           width: newValue.second.first.first, height: newValue.second.first.second)
            progress = newValue.second.second
        }
    }

    @MainActor var body: some View {
        let phase = min(1, max(0, progress))
        let controlPhase = min(1, max(0, (phase - 0.45) / 0.55))
        let appearance = listAppearance(for: snip, in: model.lists)
        HStack(alignment: .top, spacing: 12 - 4 * phase) {
            ZStack {
                if snip.isPinned && !sourceIsSelecting {
                    SnipCircularControlLabel(systemImage: "pin.fill", appearance: appearance)
                        .opacity(1 - controlPhase)
                } else {
                    SnipCompletionIcon(isDone: snip.isDone, appearance: appearance)
                        .opacity((sourceIsSelecting ? 0.35 : 1) * (1 - controlPhase))
                }
                SnipCircularControlLabel(systemImage: "arrow.uturn.backward", appearance: appearance)
                    .opacity(controlPhase)
            }
            SnipContentView(
                snip: snip, model: model, isRecovered: model.isRecoveredSnip(snip.id),
                lineLimit: phase < 0.75 ? 3 : nil,
                showsPin: sourceIsSelecting || controlPhase > 0
            )
            .padding(.top, 8 * (1 - phase))
            .frame(minHeight: 44, alignment: .topLeading)
        }
        .padding(.horizontal, 12 * phase)
        .padding(.vertical, 4 + 6 * phase)
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipped()
        .background(Color(uiColor: .systemBackground).opacity(1 - phase), in: RoundedRectangle(cornerRadius: 18))
        .modifier(GatheringGlassSurface(reduceTransparency: reduceTransparency, isVisible: phase > 0))
        .position(x: frame.midX - origin.x, y: frame.midY - origin.y)
    }
}
