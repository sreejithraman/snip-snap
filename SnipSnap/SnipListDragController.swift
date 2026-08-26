import SwiftUI

@MainActor
final class SnipListScroller {
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

struct SnipListScrollBridge: NSViewRepresentable {
    let scroller: SnipListScroller
    let onScroll: (SnipListGeometry.ScrollSnapshot) -> Void

    func makeNSView(context: Context) -> SnipListScrollBridgeView {
        SnipListScrollBridgeView(scroller: scroller, onScroll: onScroll)
    }

    func updateNSView(_ nsView: SnipListScrollBridgeView, context: Context) {
        nsView.onScroll = onScroll
        nsView.connect()
    }

    static func dismantleNSView(_ nsView: SnipListScrollBridgeView, coordinator: ()) {
        nsView.disconnect()
    }
}

@MainActor
final class SnipListScrollBridgeView: NSView {
    private let scroller: SnipListScroller
    private weak var connectedScrollView: NSScrollView?
    private var pendingScrollReport: Task<Void, Never>?
    var onScroll: (SnipListGeometry.ScrollSnapshot) -> Void

    init(
        scroller: SnipListScroller,
        onScroll: @escaping (SnipListGeometry.ScrollSnapshot) -> Void
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
            SnipListGeometry.ScrollSnapshot(
                visibleOrigin: scrollView.contentView.bounds.origin,
                contentHeight: scrollView.documentView?.bounds.height ?? 0,
                viewportHeight: scrollView.contentView.bounds.height
            )
        )
    }
}

enum SnipListDropSpace {
    static let name = "SnipListDropSpace"
}

enum SnipListDropSurface: Equatable {
    case entry(SnipListEntryID)
    case footer
    case header

    func element(in listID: UUID) -> SnipListGeometry.Element {
        switch self {
        case .entry(let entryID): .dropSurface(entryID)
        case .footer: .listFooterDropSurface(listID)
        case .header: .heading(listID)
        }
    }

    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }
}

struct SnipListDropSurfaceState {
    struct Identity: Equatable {
        let listID: UUID
        let surface: SnipListDropSurface
    }

    struct Exit: Equatable {
        fileprivate let identity: Identity
        fileprivate let generation: UInt
    }

    private(set) var active: Identity?
    private var generation: UInt = 0

    mutating func activate(listID: UUID, surface: SnipListDropSurface) {
        generation &+= 1
        active = Identity(listID: listID, surface: surface)
    }

    func exitToken(listID: UUID, surface: SnipListDropSurface) -> Exit? {
        let identity = Identity(listID: listID, surface: surface)
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

private struct SnipDropTarget: Equatable {
    let plan: SnipDropPlan
    let gapHeight: CGFloat?

    var listID: UUID { plan.listID }
    var beforeID: UUID? { plan.beforeID }
}

private struct ActiveSnipDrag: Equatable {
    let sessionID: UUID
    let payload: SnipDragPayload
}

enum SnipListEntryID: Hashable {
    case snip(UUID)
    case originGap(UUID)
    case destinationGap(UUID)
}

enum SnipListEntry: Identifiable {
    case snip(Snip)
    case originGap(snipID: UUID, height: CGFloat)
    case destinationGap(listID: UUID, height: CGFloat)

    var id: SnipListEntryID {
        switch self {
        case .snip(let snip): .snip(snip.id)
        case .originGap(let snipID, _): .originGap(snipID)
        case .destinationGap(let listID, _): .destinationGap(listID)
        }
    }
}

struct SnipListDragContext {
    let allSnips: [Snip]
    let visibleSnips: [Snip]
    let validListIDs: Set<UUID>
    let sortMode: SnipSortMode
    let filtersActive: Bool
}

@MainActor
final class SnipListDragController: ObservableObject {
    struct DropExecution {
        fileprivate let sessionID: UUID
        let payload: SnipDragPayload
        let plan: SnipDropPlan
    }

    @Published private var activeDrag: ActiveSnipDrag?
    @Published private var dropTarget: SnipDropTarget?
    @Published private var clipboardDropTarget: SnipDropTarget?
    @Published private var isClipboardDropSessionActive = false
    @Published private(set) var autoScrollDirection = 0
    let scroller = SnipListScroller()

    private let geometry = SnipListGeometry()
    private var pendingDropSessions: Set<UUID> = []
    private var lastDropViewportLocation: CGPoint?
    private var lastDropSurface: SnipListDropSurface?
    private var dropSurfaceState = SnipListDropSurfaceState()
    private var pendingDropExit: Task<Void, Never>?

    var isDragging: Bool { activeDrag != nil }
    var needsDropGeometry: Bool {
        activeDrag != nil || isClipboardDropSessionActive
    }
    var targetListID: UUID? { (dropTarget ?? clipboardDropTarget)?.listID }

    func beginNativeDrag(_ payload: SnipDragPayload) {
        beginDrag(payload)
    }

    func endNativeDrag(
        _ payload: SnipDragPayload,
        outcome: SnipDragOutcome,
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

    func record(_ frame: CGRect, for element: SnipListGeometry.Element) {
        geometry.record(frame, for: element)
    }

    func remove(_ element: SnipListGeometry.Element) {
        geometry.remove(element)
    }

    func retainSnips(_ ids: Set<UUID>) {
        geometry.retainSnips(ids)
    }

    func updateScroll(_ snapshot: SnipListGeometry.ScrollSnapshot) {
        geometry.updateScroll(snapshot)
    }

    func pinnedListIDs() -> Set<UUID> {
        geometry.pinnedListIDs()
    }

    func listBodyFrame(for group: SnipListGroup) -> CGRect? {
        let entries = entries(for: group)
        return geometry.listBodyFrame(
            listID: group.listID,
            rowIDs: group.snips.map(\.id),
            entryIDs: entries.map(\.id)
        )
    }

    func entries(for group: SnipListGroup) -> [SnipListEntry] {
        guard activeDrag != nil || clipboardDropTarget != nil else {
            return group.snips.map(SnipListEntry.snip)
        }
        let movingIDs = Set(activeDrag?.payload.ids ?? [])
        let destination = (dropTarget ?? clipboardDropTarget).flatMap { target in
            target.listID == group.listID && target.gapHeight != nil ? target : nil
        }
        let snipsByID = Dictionary(uniqueKeysWithValues: group.snips.map { ($0.id, $0) })
        return SnipDragListLayout.slots(
            snipIDs: group.snips.map(\.id),
            draggingIDs: movingIDs,
            destinationBeforeID: destination?.beforeID,
            showsDestinationGap: destination != nil,
            preservesOriginGaps: activeDrag != nil && dropTarget == nil
        ).compactMap { slot in
            switch slot {
            case .snip(let id):
                snipsByID[id].map(SnipListEntry.snip)
            case .originGap(let id):
                .originGap(snipID: id, height: geometry.dragGapHeight(for: [id]))
            case .destinationGap:
                destination?.gapHeight.map {
                    .destinationGap(listID: group.listID, height: $0)
                }
            }
        }
    }

    func updateDropSession(
        _ session: DropSession,
        listID: UUID,
        surface: SnipListDropSurface,
        context: SnipListDragContext
    ) {
        switch session.phase {
        case .entering, .active:
            activateDropSurface(listID: listID, surface: surface)
            let location = dropLocation(session.location, in: listID, surface: surface)
            let viewportLocation = geometry.viewportPoint(fromContentPoint: location)
            lastDropViewportLocation = viewportLocation
            lastDropSurface = surface
            updateAutoScrollDirection(for: viewportLocation)
            if let activeDrag {
                updateDropTarget(
                    at: location,
                    listID: listID,
                    surface: surface,
                    payload: activeDrag.payload,
                    context: context
                )
            }
        case .exiting:
            deferDropExit(listID: listID, surface: surface)
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
        listID: UUID,
        surface: SnipListDropSurface,
        context: SnipListDragContext
    ) {
        guard activeDrag == nil else { return }
        switch session.phase {
        case .entering, .active:
            beginClipboardDropSession()
            activateDropSurface(listID: listID, surface: surface)
            let plan = clipboardDropPlan(
                session: session,
                listID: listID,
                surface: surface,
                context: context,
                clearsTarget: false
            )
            let next = SnipDropTarget(
                plan: plan,
                gapHeight: plan.showsInsertion ? 72 : nil
            )
            if next != clipboardDropTarget {
                withAnimation(.snappy(duration: 0.16)) { clipboardDropTarget = next }
            }
        case .exiting:
            deferDropExit(listID: listID, surface: surface)
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
        listID: UUID,
        surface: SnipListDropSurface,
        context: SnipListDragContext,
        clearsTarget: Bool = true
    ) -> SnipDropPlan {
        let location = dropLocation(session.location, in: listID, surface: surface)
        let overHeading = surface.isHeader
            || geometry.frame(for: .heading(listID))?.contains(location) == true
        let listSnips = context.visibleSnips.filter { $0.listID == listID }
        let hasPlacementFrames = geometry.hasPlacementFrames(
            in: listID,
            among: listSnips
        )
        let placesManually = context.sortMode == .manual
            && !context.filtersActive
            && !overHeading
            && hasPlacementFrames
        let beforeID = placesManually
            ? geometry.insertionID(
                atContentPoint: location,
                among: listSnips
            )
            : nil
        if clearsTarget { clipboardDropTarget = nil }
        return SnipDropPlan(
            listID: listID,
            beforeID: beforeID,
            behavior: placesManually ? .exact : (overHeading ? .listTop : .chronological),
            showsInsertion: placesManually
        )
    }

    func beginDrop(
        payloads: [SnipDragPayload],
        session: DropSession,
        listID: UUID,
        surface: SnipListDropSurface,
        context: SnipListDragContext
    ) -> DropExecution? {
        let location = dropLocation(session.location, in: listID, surface: surface)
        guard payloads.count == 1,
              let payload = payloads.first,
              let drag = activeDrag,
              drag.payload == payload,
              let target = target(
                at: location,
                listID: listID,
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
        context: @escaping @MainActor () -> SnipListDragContext
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
               let listID = dropTarget?.listID,
               currentContext.validListIDs.contains(listID) {
                let location = geometry.contentPoint(
                    fromViewportPoint: lastDropViewportLocation
                )
                updateDropTarget(
                    at: location,
                    listID: listID,
                    surface: lastDropSurface,
                    payload: activeDrag.payload,
                    context: currentContext
                )
            }
        }
    }

    private func beginDrag(_ payload: SnipDragPayload) {
        withAnimation(.snappy(duration: 0.18)) {
            activeDrag = ActiveSnipDrag(sessionID: UUID(), payload: payload)
        }
    }

    private func finishDrag(_ drag: ActiveSnipDrag) {
        pendingDropSessions.remove(drag.sessionID)
        guard activeDrag?.sessionID == drag.sessionID else { return }
        withAnimation(.snappy(duration: 0.18)) {
            activeDrag = nil
        }
        clearDropInteraction()
    }

    private func updateDropTarget(
        at location: CGPoint,
        listID: UUID,
        surface: SnipListDropSurface,
        payload: SnipDragPayload,
        context: SnipListDragContext
    ) {
        let nextTarget = target(
            at: location,
            listID: listID,
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
        listID: UUID,
        surface: SnipListDropSurface,
        payload: SnipDragPayload,
        context: SnipListDragContext
    ) -> SnipDropTarget? {
        guard !payload.ids.isEmpty else { return nil }
        let movingIDs = Set(payload.ids)
        let visibleTargetSnips = context.visibleSnips.filter {
            $0.listID == listID && !movingIDs.contains($0.id)
        }
        let overHeading = surface.isHeader
            || geometry.frame(for: .heading(listID))?.contains(location) == true
        guard let plan = SnipDropPlanner.plan(
            payloadIDs: payload.ids,
            snips: context.allSnips,
            targetListID: listID,
            pointerBeforeID: geometry.insertionID(
                atContentPoint: location,
                among: visibleTargetSnips
            ),
            isOverHeading: overHeading,
            sortMode: context.sortMode,
            filtersActive: context.filtersActive
        ) else { return nil }
        return SnipDropTarget(
            plan: plan,
            gapHeight: plan.showsInsertion ? geometry.dragGapHeight(for: payload.ids) : nil
        )
    }

    private func dropLocation(
        _ localLocation: CGPoint,
        in listID: UUID,
        surface: SnipListDropSurface
    ) -> CGPoint {
        geometry.contentPoint(
            fromLocalPoint: localLocation,
            in: surface.element(in: listID)
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
        listID: UUID,
        surface: SnipListDropSurface
    ) {
        pendingDropExit?.cancel()
        pendingDropExit = nil
        dropSurfaceState.activate(
            listID: listID,
            surface: surface
        )
    }

    private func deferDropExit(
        listID: UUID,
        surface: SnipListDropSurface
    ) {
        guard let exit = dropSurfaceState.exitToken(
            listID: listID,
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
