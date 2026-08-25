import SwiftUI

@MainActor
final class InboxListScroller {
    private weak var scrollView: NSScrollView?

    func attach(_ scrollView: NSScrollView?) {
        self.scrollView = scrollView
    }

    func scrollTo(y: CGFloat) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        clipView.scroll(
            to: NSPoint(
                x: clipView.bounds.origin.x,
                y: y
            )
        )
        scrollView.reflectScrolledClipView(clipView)
    }
}

struct InboxScrollBridge: NSViewRepresentable {
    let scroller: InboxListScroller
    let onScroll: (InboxListGeometry.ScrollSnapshot) -> Void

    func makeNSView(context: Context) -> InboxScrollBridgeView {
        InboxScrollBridgeView(scroller: scroller, onScroll: onScroll)
    }

    func updateNSView(_ nsView: InboxScrollBridgeView, context: Context) {
        nsView.onScroll = onScroll
        nsView.connect()
    }

    static func dismantleNSView(_ nsView: InboxScrollBridgeView, coordinator: ()) {
        nsView.disconnect()
    }
}

@MainActor
final class InboxScrollBridgeView: NSView {
    private let scroller: InboxListScroller
    private weak var connectedScrollView: NSScrollView?
    private var pendingScrollReport: Task<Void, Never>?
    var onScroll: (InboxListGeometry.ScrollSnapshot) -> Void

    init(
        scroller: InboxListScroller,
        onScroll: @escaping (InboxListGeometry.ScrollSnapshot) -> Void
    ) {
        self.scroller = scroller
        self.onScroll = onScroll
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connect()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func connect() {
        guard connectedScrollView !== enclosingScrollView else { return }
        disconnect()
        guard let scrollView = enclosingScrollView else { return }
        connectedScrollView = scrollView
        scroller.attach(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scheduleScrollReport()
    }

    func disconnect() {
        NotificationCenter.default.removeObserver(self)
        pendingScrollReport?.cancel()
        pendingScrollReport = nil
        connectedScrollView = nil
        scroller.attach(nil)
    }

    @objc private func boundsDidChange() {
        scheduleScrollReport()
    }

    private func scheduleScrollReport() {
        guard pendingScrollReport == nil else { return }
        pendingScrollReport = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.pendingScrollReport = nil
            self.reportScroll()
        }
    }

    private func reportScroll() {
        guard let scrollView = connectedScrollView else { return }
        onScroll(
            InboxListGeometry.ScrollSnapshot(
                visibleOrigin: scrollView.contentView.bounds.origin,
                contentHeight: scrollView.documentView?.bounds.height ?? 0,
                viewportHeight: scrollView.contentView.bounds.height
            )
        )
    }
}

enum InboxDropSpace {
    static let name = "InboxDropSpace"
}

enum SectionDropSurface: Equatable {
    case entry(ClipListEntryID)
    case footer
    case header

    func element(in sectionID: UUID) -> InboxListGeometry.Element {
        switch self {
        case .entry(let entryID): .dropSurface(entryID)
        case .footer: .sectionFooterDropSurface(sectionID)
        case .header: .heading(sectionID)
        }
    }

    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }
}

struct SectionDropSurfaceState {
    struct Identity: Equatable {
        let sectionID: UUID
        let surface: SectionDropSurface
    }

    struct Exit: Equatable {
        fileprivate let identity: Identity
        fileprivate let generation: UInt
    }

    private(set) var active: Identity?
    private var generation: UInt = 0

    mutating func activate(sectionID: UUID, surface: SectionDropSurface) {
        generation &+= 1
        active = Identity(sectionID: sectionID, surface: surface)
    }

    func exitToken(sectionID: UUID, surface: SectionDropSurface) -> Exit? {
        let identity = Identity(sectionID: sectionID, surface: surface)
        guard active == identity else { return nil }
        return Exit(identity: identity, generation: generation)
    }

    func owns(_ exit: Exit) -> Bool {
        active == exit.identity && generation == exit.generation
    }

    mutating func clear() {
        generation &+= 1
        active = nil
    }
}

private struct ClipDropTarget: Equatable {
    let plan: ClipDropPlan
    let gapHeight: CGFloat?

    var sectionID: UUID { plan.sectionID }
    var beforeID: UUID? { plan.beforeID }
}

private struct ActiveClipDrag: Equatable {
    let sessionID: UUID
    let payload: ClipDragPayload
}

enum ClipListEntryID: Hashable {
    case item(UUID)
    case originGap(UUID)
    case destinationGap(UUID)
}

enum ClipListEntry: Identifiable {
    case item(CaptureItem)
    case originGap(itemID: UUID, height: CGFloat)
    case destinationGap(sectionID: UUID, height: CGFloat)

    var id: ClipListEntryID {
        switch self {
        case .item(let item): .item(item.id)
        case .originGap(let itemID, _): .originGap(itemID)
        case .destinationGap(let sectionID, _): .destinationGap(sectionID)
        }
    }
}

struct InboxDragContext {
    let allItems: [CaptureItem]
    let visibleItems: [CaptureItem]
    let validSectionIDs: Set<UUID>
    let sortMode: ClipSortMode
    let filtersActive: Bool
}

@MainActor
final class InboxDragController: ObservableObject {
    struct DropExecution {
        fileprivate let sessionID: UUID
        let payload: ClipDragPayload
        let plan: ClipDropPlan
    }

    @Published private var activeDrag: ActiveClipDrag?
    @Published private var dropTarget: ClipDropTarget?
    @Published private var clipboardDropTarget: ClipDropTarget?
    @Published private var isClipboardDropSessionActive = false
    @Published private(set) var autoScrollDirection = 0
    let scroller = InboxListScroller()

    private let geometry = InboxListGeometry()
    private var pendingDropSessions: Set<UUID> = []
    private var lastDropViewportLocation: CGPoint?
    private var lastDropSurface: SectionDropSurface?
    private var dropSurfaceState = SectionDropSurfaceState()
    private var pendingDropExit: Task<Void, Never>?

    var isDragging: Bool { activeDrag != nil }
    var needsDropGeometry: Bool {
        activeDrag != nil || isClipboardDropSessionActive
    }
    var targetSectionID: UUID? { (dropTarget ?? clipboardDropTarget)?.sectionID }

    func beginNativeDrag(_ payload: ClipDragPayload) {
        beginDrag(payload)
    }

    func endNativeDrag(
        _ payload: ClipDragPayload,
        outcome: ClipDragOutcome,
        markDoneAfterExternalCopy: ([UUID]) -> Void
    ) {
        guard let drag = activeDrag, drag.payload == payload else { return }
        if outcome == .copy {
            markDoneAfterExternalCopy(payload.ids)
        }
        if outcome != .move {
            finishDrag(drag)
        } else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self,
                      !self.pendingDropSessions.contains(drag.sessionID) else { return }
                self.finishDrag(drag)
            }
        }
    }

    func record(_ frame: CGRect, for element: InboxListGeometry.Element) {
        geometry.record(frame, for: element)
    }

    func remove(_ element: InboxListGeometry.Element) {
        geometry.remove(element)
    }

    func retainItems(_ ids: Set<UUID>) {
        geometry.retainItems(ids)
    }

    func updateScroll(_ snapshot: InboxListGeometry.ScrollSnapshot) {
        geometry.updateScroll(snapshot)
    }

    func pinnedSectionIDs() -> Set<UUID> {
        geometry.pinnedSectionIDs()
    }

    func sectionBodyFrame(for group: InboxItemGroup) -> CGRect? {
        let entries = entries(for: group)
        return geometry.sectionBodyFrame(
            sectionID: group.sectionID,
            rowIDs: group.items.map(\.id),
            entryIDs: entries.map(\.id)
        )
    }

    func entries(for group: InboxItemGroup) -> [ClipListEntry] {
        guard activeDrag != nil || clipboardDropTarget != nil else {
            return group.items.map(ClipListEntry.item)
        }
        let movingIDs = Set(activeDrag?.payload.ids ?? [])
        let destination = (dropTarget ?? clipboardDropTarget).flatMap { target in
            target.sectionID == group.sectionID && target.gapHeight != nil ? target : nil
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: group.items.map { ($0.id, $0) })
        return ClipDragListLayout.slots(
            itemIDs: group.items.map(\.id),
            draggingIDs: movingIDs,
            destinationBeforeID: destination?.beforeID,
            showsDestinationGap: destination != nil,
            preservesOriginGaps: activeDrag != nil && dropTarget == nil
        ).compactMap { slot in
            switch slot {
            case .item(let id):
                itemsByID[id].map(ClipListEntry.item)
            case .originGap(let id):
                .originGap(itemID: id, height: geometry.dragGapHeight(for: [id]))
            case .destinationGap:
                destination?.gapHeight.map {
                    .destinationGap(sectionID: group.sectionID, height: $0)
                }
            }
        }
    }

    func updateDropSession(
        _ session: DropSession,
        sectionID: UUID,
        surface: SectionDropSurface,
        context: InboxDragContext
    ) {
        switch session.phase {
        case .entering, .active:
            activateDropSurface(sectionID: sectionID, surface: surface)
            let location = dropLocation(session.location, in: sectionID, surface: surface)
            let viewportLocation = geometry.viewportPoint(fromContentPoint: location)
            lastDropViewportLocation = viewportLocation
            lastDropSurface = surface
            updateAutoScrollDirection(for: viewportLocation)
            if let activeDrag {
                updateDropTarget(
                    at: location,
                    sectionID: sectionID,
                    surface: surface,
                    payload: activeDrag.payload,
                    context: context
                )
            }
        case .exiting:
            deferDropExit(sectionID: sectionID, surface: surface)
        case .ended, .dataTransferCompleted:
            if activeDrag == nil {
                clearDropInteraction()
            }
        @unknown default:
            break
        }
    }

    func updateClipboardDropSession(
        _ session: DropSession,
        sectionID: UUID,
        surface: SectionDropSurface,
        context: InboxDragContext
    ) {
        guard activeDrag == nil else { return }
        switch session.phase {
        case .entering, .active:
            beginClipboardDropSession()
            activateDropSurface(sectionID: sectionID, surface: surface)
            let plan = clipboardDropPlan(
                session: session,
                sectionID: sectionID,
                surface: surface,
                context: context,
                clearsTarget: false
            )
            let next = ClipDropTarget(
                plan: plan,
                gapHeight: plan.showsInsertion ? 72 : nil
            )
            if next != clipboardDropTarget {
                withAnimation(.snappy(duration: 0.16)) { clipboardDropTarget = next }
            }
        case .exiting:
            deferDropExit(sectionID: sectionID, surface: surface)
        case .ended, .dataTransferCompleted:
            endClipboardDropSession()
        @unknown default:
            break
        }
    }

    func beginClipboardDropSession() {
        if !isClipboardDropSessionActive {
            isClipboardDropSessionActive = true
        }
    }

    func endClipboardDropSession() {
        clearDropInteraction()
    }

    func clipboardDropPlan(
        session: DropSession,
        sectionID: UUID,
        surface: SectionDropSurface,
        context: InboxDragContext,
        clearsTarget: Bool = true
    ) -> ClipDropPlan {
        let location = dropLocation(session.location, in: sectionID, surface: surface)
        let overHeading = surface.isHeader
            || geometry.frame(for: .heading(sectionID))?.contains(location) == true
        let sectionItems = context.visibleItems.filter { $0.sectionID == sectionID }
        let hasPlacementFrames = geometry.hasPlacementFrames(
            in: sectionID,
            among: sectionItems
        )
        let placesManually = context.sortMode == .manual
            && !context.filtersActive
            && !overHeading
            && hasPlacementFrames
        let beforeID = placesManually
            ? geometry.insertionID(
                atContentPoint: location,
                among: sectionItems
            )
            : nil
        if clearsTarget { clipboardDropTarget = nil }
        return ClipDropPlan(
            sectionID: sectionID,
            beforeID: beforeID,
            behavior: placesManually ? .exact : (overHeading ? .sectionTop : .chronological),
            showsInsertion: placesManually
        )
    }

    func beginDrop(
        payloads: [ClipDragPayload],
        session: DropSession,
        sectionID: UUID,
        surface: SectionDropSurface,
        context: InboxDragContext
    ) -> DropExecution? {
        let location = dropLocation(session.location, in: sectionID, surface: surface)
        guard payloads.count == 1,
              let payload = payloads.first,
              let drag = activeDrag,
              drag.payload == payload,
              let target = target(
                at: location,
                sectionID: sectionID,
                surface: surface,
                payload: payload,
                context: context
              ) else {
            if let activeDrag {
                finishDrag(activeDrag)
            }
            clearDropInteraction()
            return nil
        }
        pendingDropSessions.insert(drag.sessionID)
        return DropExecution(
            sessionID: drag.sessionID,
            payload: drag.payload,
            plan: target.plan
        )
    }

    func completeDrop(_ execution: DropExecution) {
        pendingDropSessions.remove(execution.sessionID)
        guard let activeDrag, activeDrag.sessionID == execution.sessionID else { return }
        finishDrag(activeDrag)
    }

    func autoScrollWhileNeeded(
        context: @escaping @MainActor () -> InboxDragContext
    ) async {
        let direction = autoScrollDirection
        guard direction != 0 else { return }
        while !Task.isCancelled && autoScrollDirection == direction {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let metrics = geometry.scrollSnapshot
            let maximumOffset = max(metrics.contentHeight - metrics.viewportHeight, 0)
            let nextOffset = min(
                max(metrics.visibleOrigin.y + CGFloat(direction) * 14, 0),
                maximumOffset
            )
            guard nextOffset != metrics.visibleOrigin.y else {
                autoScrollDirection = 0
                return
            }
            scroller.scrollTo(y: nextOffset)
            let currentContext = context()
            if let lastDropViewportLocation,
               let lastDropSurface,
               let activeDrag,
               let sectionID = dropTarget?.sectionID,
               currentContext.validSectionIDs.contains(sectionID) {
                let location = geometry.contentPoint(
                    fromViewportPoint: lastDropViewportLocation
                )
                updateDropTarget(
                    at: location,
                    sectionID: sectionID,
                    surface: lastDropSurface,
                    payload: activeDrag.payload,
                    context: currentContext
                )
            }
        }
    }

    private func beginDrag(_ payload: ClipDragPayload) {
        withAnimation(.snappy(duration: 0.18)) {
            activeDrag = ActiveClipDrag(sessionID: UUID(), payload: payload)
        }
    }

    private func finishDrag(_ drag: ActiveClipDrag) {
        pendingDropSessions.remove(drag.sessionID)
        guard activeDrag?.sessionID == drag.sessionID else { return }
        withAnimation(.snappy(duration: 0.18)) {
            activeDrag = nil
        }
        clearDropInteraction()
    }

    private func updateDropTarget(
        at location: CGPoint,
        sectionID: UUID,
        surface: SectionDropSurface,
        payload: ClipDragPayload,
        context: InboxDragContext
    ) {
        let nextTarget = target(
            at: location,
            sectionID: sectionID,
            surface: surface,
            payload: payload,
            context: context
        )
        guard nextTarget != dropTarget else { return }
        withAnimation(.snappy(duration: 0.16)) {
            dropTarget = nextTarget
        }
    }

    private func target(
        at location: CGPoint,
        sectionID: UUID,
        surface: SectionDropSurface,
        payload: ClipDragPayload,
        context: InboxDragContext
    ) -> ClipDropTarget? {
        guard !payload.ids.isEmpty else { return nil }
        let movingIDs = Set(payload.ids)
        let visibleTargetItems = context.visibleItems.filter {
            $0.sectionID == sectionID && !movingIDs.contains($0.id)
        }
        let overHeading = surface.isHeader
            || geometry.frame(for: .heading(sectionID))?.contains(location) == true
        guard let plan = ClipDropPlanner.plan(
            payloadIDs: payload.ids,
            items: context.allItems,
            targetSectionID: sectionID,
            pointerBeforeID: geometry.insertionID(
                atContentPoint: location,
                among: visibleTargetItems
            ),
            isOverHeading: overHeading,
            sortMode: context.sortMode,
            filtersActive: context.filtersActive
        ) else { return nil }
        return ClipDropTarget(
            plan: plan,
            gapHeight: plan.showsInsertion ? geometry.dragGapHeight(for: payload.ids) : nil
        )
    }

    private func dropLocation(
        _ localLocation: CGPoint,
        in sectionID: UUID,
        surface: SectionDropSurface
    ) -> CGPoint {
        geometry.contentPoint(
            fromLocalPoint: localLocation,
            in: surface.element(in: sectionID)
        ) ?? localLocation
    }

    private func updateAutoScrollDirection(for location: CGPoint) {
        let metrics = geometry.scrollSnapshot
        guard metrics.viewportHeight > 0 else {
            autoScrollDirection = 0
            return
        }
        let edgeSize: CGFloat = 44
        if location.y < edgeSize {
            autoScrollDirection = -1
        } else if location.y > metrics.viewportHeight - edgeSize {
            autoScrollDirection = 1
        } else {
            autoScrollDirection = 0
        }
    }

    private func activateDropSurface(
        sectionID: UUID,
        surface: SectionDropSurface
    ) {
        pendingDropExit?.cancel()
        pendingDropExit = nil
        dropSurfaceState.activate(
            sectionID: sectionID,
            surface: surface
        )
    }

    private func deferDropExit(
        sectionID: UUID,
        surface: SectionDropSurface
    ) {
        guard let exit = dropSurfaceState.exitToken(
            sectionID: sectionID,
            surface: surface
        ) else { return }
        pendingDropExit?.cancel()
        pendingDropExit = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.dropSurfaceState.owns(exit) else { return }
            self.pendingDropExit = nil
            self.clearDropInteraction()
        }
    }

    private func clearDropInteraction() {
        pendingDropExit?.cancel()
        pendingDropExit = nil
        dropSurfaceState.clear()
        withAnimation(.snappy(duration: 0.12)) {
            dropTarget = nil
            clipboardDropTarget = nil
            isClipboardDropSessionActive = false
        }
        lastDropViewportLocation = nil
        lastDropSurface = nil
        autoScrollDirection = 0
    }
}
