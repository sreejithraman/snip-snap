import AppKit
import SwiftUI

enum InboxFocusTarget: Hashable {
    case list
    case search
    case inlineEntry
}

private struct InlineEditSession {
    let itemID: UUID
    var attachments: [URL]
    var isSaving = false
}

private enum InboxScrollTarget {
    case top
}

@MainActor
private final class InboxReorderGeometry: ObservableObject {
    var rowFrames: [UUID: CGRect] = [:]
    var listFrame: CGRect = .zero
    var scrollOffsetY: CGFloat = 0
}

private struct InboxWindowFrameReader: NSViewRepresentable {
    let onChange: @MainActor (CGRect, CGFloat) -> Void

    func makeNSView(context: Context) -> InboxWindowFrameReaderView {
        InboxWindowFrameReaderView(onChange: onChange)
    }

    func updateNSView(_ nsView: InboxWindowFrameReaderView, context: Context) {
        nsView.onChange = onChange
        nsView.reportFrameIfNeeded()
    }
}

@MainActor
private final class InboxWindowFrameReaderView: NSView {
    var onChange: @MainActor (CGRect, CGFloat) -> Void
    private var lastFrame: CGRect?
    private var lastScrollOffsetY: CGFloat?
    private weak var observedClipView: NSClipView?

    init(onChange: @escaping @MainActor (CGRect, CGFloat) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        observeScrollIfNeeded()
        reportFrameIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScrollIfNeeded()
        reportFrameIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func reportFrameIfNeeded() {
        guard window != nil else { return }
        let nextFrame = convert(bounds, to: nil)
        let nextScrollOffsetY = enclosingScrollView?.contentView.bounds.origin.y ?? 0
        guard nextFrame != lastFrame || nextScrollOffsetY != lastScrollOffsetY else { return }
        lastFrame = nextFrame
        lastScrollOffsetY = nextScrollOffsetY
        onChange(nextFrame, nextScrollOffsetY)
    }

    private func observeScrollIfNeeded() {
        let clipView = window == nil ? nil : enclosingScrollView?.contentView
        guard observedClipView !== clipView else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
        observedClipView = clipView
        guard let clipView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc
    private func clipViewBoundsDidChange(_ notification: Notification) {
        reportFrameIfNeeded()
    }
}

@MainActor
final class InboxListState: ObservableObject {
    fileprivate var anchor: UUID?
    fileprivate var focus: UUID?

    func selectAllVisible(model: AppModel) {
        model.selectAllVisible()
        let ids = orderedIDs(for: model.filteredItems)
        anchor = ids.first
        focus = ids.last
    }

    fileprivate func orderedIDs(for items: [CaptureItem]) -> [UUID] {
        items.map(\.id)
    }

    fileprivate func apply(_ update: InboxSelection.Update, to model: AppModel) {
        model.selection = update.selection
        anchor = update.anchor
        focus = update.focus
    }

    fileprivate func reconcile(model: AppModel) {
        let selection = model.selection
        guard !selection.isEmpty else {
            anchor = nil
            focus = nil
            return
        }
        if let anchor, !selection.contains(anchor) {
            self.anchor = nil
        }
        if focus.map(selection.contains) != true {
            focus = orderedIDs(for: model.filteredItems).first(where: selection.contains)
        }
    }
}

struct InboxListView: View {
    @ObservedObject var model: AppModel
    let coordinator: AppCoordinator
    let clipDragSourceController: ClipDragSourceController
    let fileDropController: PanelFileDropController
    @ObservedObject var state: InboxListState
    @FocusState.Binding var focusedTarget: InboxFocusTarget?
    let moveSelectionToNewSection: (Set<UUID>) -> Void
    let requestFileImport: (UUID) -> Void
    @Binding var pendingEditAttachmentImport: PendingEditAttachmentImport?
    let captureScreenAreaForEdit: (@escaping @MainActor (URL?) -> Void) -> Void
    let bottomContentInset: CGFloat
    let onPreviewAttachments: ([URL], URL) -> Void
    let onRemovePreviewURL: (URL) -> Void

    @State private var selectionModifiers: EventModifiers = []
    @State private var hasScrolledFromTop = false
    @State private var addedClipRevealState = InboxAddedClipRevealState()
    @State private var editSession: InlineEditSession?
    @State private var pendingOrderBySection: [UUID: [UUID]] = [:]
    @State private var activeDragPayload: ClipDragPayload?
    @State private var activeDragOriginalOrder: [UUID] = []
    @State private var activeDragScrollOffsetY: CGFloat = 0
    @State private var activeDropTarget: InboxReorderTarget?
    @State private var isCommittingDrop = false
    @State private var activeDragRowFrames: [UUID: CGRect] = [:]
    @StateObject private var reorderGeometry = InboxReorderGeometry()

    private var orderedItemIDs: [UUID] {
        state.orderedIDs(for: model.filteredItems)
    }

    private var itemCommands: InboxItemCommandDispatcher {
        InboxItemCommandDispatcher(model: model, coordinator: coordinator)
    }

    var body: some View {
        let snapshot = InboxListSnapshot(
            visibleItems: model.filteredItems,
            allItems: model.items,
            sections: model.sections,
            selection: model.selection,
            keepsEmptySectionID: model.query.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? model.activeSectionID : nil,
            attachmentURL: model.attachmentURL
        )
        let showsSearchSections = snapshot.groups.count > 1
        ScrollViewReader { proxy in
            List {
                topSpacer
                if showsSearchSections {
                    ForEach(snapshot.groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                reorderableItemCard(
                                    item,
                                    snapshot: snapshot,
                                    sectionID: group.sectionID,
                                    items: group.items
                                )
                            }
                        } header: {
                            PanelListHeader(
                                group.section,
                                showsGlass: hasScrolledFromTop
                            )
                            .background {
                                ClipDragBlockingRegion(
                                    controller: clipDragSourceController,
                                    id: group.sectionID
                                )
                            }
                        }
                    }
                } else {
                    let displayedItems = displayedItems(in: snapshot)
                    ForEach(displayedItems) { item in
                        reorderableItemCard(
                            item,
                            snapshot: snapshot,
                            sectionID: model.activeSectionID,
                            items: displayedItems
                        )
                    }
                }
                bottomSpacer
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(0, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 1)
            .background {
                InboxWindowFrameReader { frame, _ in
                    reorderGeometry.listFrame = frame
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !showsSearchSections {
                    PanelListHeader(
                        model.activeSection.name,
                        showsGlass: hasScrolledFromTop
                    )
                }
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y > 0.5
            } action: { _, hasScrolled in
                hasScrolledFromTop = hasScrolled
            }
            .onModifierKeysChanged(mask: [.command, .shift]) { _, modifiers in
                selectionModifiers = modifiers
            }
            .onChange(of: model.sortMode) {
                if let selectedID = orderedItemIDs.first(where: model.selection.contains) {
                    withAnimation(.snappy(duration: 0.18)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
            .onChange(of: model.latestAddedClipID) { _, clipID in
                let isVisibleInModel = clipID.map { addedID in
                    model.filteredItems.contains(where: { $0.id == addedID })
                } ?? false
                if let destination = addedClipRevealState.record(
                    clipID: clipID,
                    wasAtTop: !hasScrolledFromTop,
                    isVisibleInModel: isVisibleInModel,
                    visibleIDs: snapshot.orderedVisibleIDs
                ) {
                    revealAddedClip(
                        at: destination,
                        proxy: proxy
                    )
                }
            }
            .onChange(of: snapshot.orderedVisibleIDs) { _, visibleIDs in
                if let destination = addedClipRevealState.nextDestination(
                    visibleIDs: visibleIDs
                ) {
                    revealAddedClip(
                        at: destination,
                        proxy: proxy
                    )
                }
            }
            .onChange(of: model.editingID, initial: true) { _, editingID in
                editSession = editingID.flatMap { itemID in
                    model.items.first(where: { $0.id == itemID }).map { item in
                        InlineEditSession(
                            itemID: itemID,
                            attachments: item.attachments.map(model.attachmentURL)
                        )
                    }
                }
                guard let editingID,
                      snapshot.orderedVisibleIDs.contains(editingID) else { return }
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.snappy(duration: 0.18)) {
                        proxy.scrollTo(editingID, anchor: .center)
                    }
                    try? await Task.sleep(for: .milliseconds(220))
                    proxy.scrollTo(editingID, anchor: .center)
                }
            }
            .overlay(alignment: .topLeading) {
                selectionFocusTarget(proxy: proxy)
            }
        }
        .onAppear {
            state.reconcile(model: model)
        }
        .onChange(of: model.selection) {
            state.reconcile(model: model)
        }
        .onReceive(fileDropController.fileDrops) { urls in
            guard let editingID = model.editingID else { return }
            addEditAttachments(urls, to: editingID)
        }
        .onChange(of: pendingEditAttachmentImport?.id, initial: true) {
            guard let pendingEditAttachmentImport else { return }
            self.pendingEditAttachmentImport = nil
            addEditAttachments(
                pendingEditAttachmentImport.urls,
                to: pendingEditAttachmentImport.itemID
            )
        }
    }

    private func addEditAttachments(_ urls: [URL], to itemID: UUID) {
        guard model.editingID == itemID,
              let item = model.items.first(where: { $0.id == itemID }) else { return }
        var session: InlineEditSession
        if let editSession, editSession.itemID == itemID {
            session = editSession
        } else {
            session = InlineEditSession(
                itemID: itemID,
                attachments: item.attachments.map(model.attachmentURL)
            )
        }
        guard !session.isSaving else { return }
        session.attachments.append(
            contentsOf: PanelFileDropValidation.newFiles(
                in: urls,
                excluding: session.attachments
            )
        )
        editSession = session
    }

    private func revealAddedClip(
        at destination: InboxAddedClipRevealDestination,
        proxy: ScrollViewProxy
    ) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.snappy(duration: 0.18)) {
                switch destination {
                case .scrollViewTop:
                    proxy.scrollTo(InboxScrollTarget.top, anchor: .top)
                }
            }
        }
    }

    private var bottomSpacer: some View {
        Color.clear
            .frame(
                height: PanelOverlayLayout.listBottomPadding(
                    composerHeight: bottomContentInset
                )
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var topSpacer: some View {
        Color.clear
            .frame(
                height: PanelListMetrics.verticalContentInset
                    + PanelListMetrics.rowSpacing / 2
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .id(InboxScrollTarget.top)
    }

    private var canDragReorder: Bool {
        model.editingID == nil
            && model.completionFilter == .all
            && model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reorderableItemCard(
        _ item: CaptureItem,
        snapshot: InboxListSnapshot,
        sectionID: UUID,
        items: [CaptureItem]
    ) -> some View {
        let payload = snapshot.dragPayload(for: item)
        return itemCard(item)
                .opacity(isShowingDragGap(for: item.id) ? 0 : 1)
                .background {
                    if model.editingID != item.id {
                        ClipDragSourceRegion(
                            controller: clipDragSourceController,
                            id: item.id,
                            payload: payload,
                            onBegan: {
                                beginDrag(payload, orderedIDs: items.map(\.id))
                            },
                            onMoved: { point in
                                updateDrag(
                                    at: point,
                                    sectionID: sectionID,
                                    items: items
                                )
                            },
                            onEnded: { outcome, point in
                                endDrag(
                                    payload,
                                    outcome: outcome,
                                    at: point,
                                    sectionID: sectionID,
                                    items: items
                                )
                            }
                        )
                    }
                }
                .padding(.bottom, PanelListMetrics.rowSpacing)
                .id(item.id)
                .listRowInsets(PanelListMetrics.inboxRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .background {
                    InboxWindowFrameReader { frame, scrollOffsetY in
                        reorderGeometry.rowFrames[item.id] = frame
                        reorderGeometry.scrollOffsetY = scrollOffsetY
                    }
                }
                .onDisappear {
                    reorderGeometry.rowFrames[item.id] = nil
                }
    }

    private func beginDrag(_ payload: ClipDragPayload, orderedIDs: [UUID]) {
        activeDragPayload = payload
        activeDropTarget = nil
        isCommittingDrop = false
        guard canDragReorder else {
            activeDragOriginalOrder = []
            activeDragRowFrames = [:]
            return
        }
        activeDragOriginalOrder = orderedIDs
        activeDragRowFrames = reorderGeometry.rowFrames
        activeDragScrollOffsetY = reorderGeometry.scrollOffsetY
    }

    private func updateDrag(
        at location: CGPoint,
        sectionID: UUID,
        items: [CaptureItem]
    ) {
        guard activeDragPayload != nil, !activeDragOriginalOrder.isEmpty else { return }
        guard reorderGeometry.listFrame.contains(location) else {
            if activeDropTarget != nil {
                activeDropTarget = nil
                pendingOrderBySection[sectionID] = nil
            }
            return
        }
        let target = reorderTarget(at: location, items: items)
        activeDropTarget = target
        updatePendingOrder(sectionID: sectionID, target: target)
    }

    private func reorderTarget(
        at location: CGPoint,
        items: [CaptureItem]
    ) -> InboxReorderTarget {
        let placementFrames = activeDragRowFrames.isEmpty
            ? reorderGeometry.rowFrames
            : activeDragRowFrames
        return InboxReorderPlan.target(
            atWindowY: location.y,
            orderedIDs: items.map(\.id),
            movingIDs: Set(activeDragPayload?.ids ?? []),
            rowFrames: placementFrames,
            rowFrameOffsetY: reorderGeometry.scrollOffsetY - activeDragScrollOffsetY
        )
    }

    private func updatePendingOrder(
        sectionID: UUID,
        target: InboxReorderTarget
    ) {
        guard let payload = activeDragPayload else { return }
        guard let reorderedIDs = InboxReorderPlan.orderedIDs(
            from: activeDragOriginalOrder,
            movingIDs: payload.ids,
            target: target
        ) else { return }
        guard pendingOrderBySection[sectionID] != reorderedIDs else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            pendingOrderBySection[sectionID] = reorderedIDs
        }
    }

    private func commitDrop(
        _ payload: ClipDragPayload,
        target: InboxReorderTarget,
        sectionID: UUID
    ) {
        guard payload == activeDragPayload else { return }
        guard let reorderedIDs = InboxReorderPlan.orderedIDs(
            from: activeDragOriginalOrder,
            movingIDs: payload.ids,
            target: target
        ), reorderedIDs != activeDragOriginalOrder else {
            clearDrag(sectionID: sectionID)
            return
        }
        activeDropTarget = target
        updatePendingOrder(sectionID: sectionID, target: target)
        isCommittingDrop = true
        let selectionBeforeMove = model.selection
        Task { @MainActor in
            _ = await model.move(
                ids: payload.ids,
                to: sectionID,
                before: target.beforeID,
                selectionAfterMove: selectionBeforeMove
            )
            guard payload == activeDragPayload, isCommittingDrop else { return }
            clearDrag(sectionID: sectionID)
        }
    }

    private func endDrag(
        _ payload: ClipDragPayload,
        outcome: ClipDragOutcome,
        at location: CGPoint,
        sectionID: UUID,
        items: [CaptureItem]
    ) {
        guard payload == activeDragPayload else { return }
        if !activeDragOriginalOrder.isEmpty, reorderGeometry.listFrame.contains(location) {
            let finalTarget = reorderTarget(at: location, items: items)
            commitDrop(payload, target: finalTarget, sectionID: sectionID)
            return
        }
        if outcome == .copy {
            model.markDoneAfterExternalDrop(ids: payload.ids)
        }
        guard outcome == .move else {
            clearDrag(sectionID: sectionID)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard payload == activeDragPayload, !isCommittingDrop else { return }
            clearDrag(sectionID: sectionID)
        }
    }

    private func isShowingDragGap(for itemID: UUID) -> Bool {
        activeDragPayload?.ids.contains(itemID) == true
    }

    private func clearDrag(sectionID: UUID) {
        withAnimation(.snappy(duration: 0.12)) {
            pendingOrderBySection[sectionID] = nil
            activeDragPayload = nil
            activeDragOriginalOrder = []
            activeDragScrollOffsetY = 0
            activeDragRowFrames = [:]
            activeDropTarget = nil
            isCommittingDrop = false
        }
    }

    private func displayedItems(in snapshot: InboxListSnapshot) -> [CaptureItem] {
        guard snapshot.groups.count == 1, let group = snapshot.groups.first else {
            return snapshot.groups.flatMap(\.items)
        }
        return orderedItems(in: group)
    }

    private func orderedItems(in group: InboxItemGroup) -> [CaptureItem] {
        guard let pendingOrder = pendingOrderBySection[group.sectionID],
              Set(pendingOrder) == Set(group.items.map(\.id)) else {
            return group.items
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: group.items.map { ($0.id, $0) })
        return pendingOrder.compactMap { itemsByID[$0] }
    }

    private func selectionFocusTarget(proxy: ScrollViewProxy) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable()
            .focusEffectDisabled()
            .focused($focusedTarget, equals: .list)
            .accessibilityHidden(true)
            .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                moveSelection(by: -1, extending: press.modifiers.contains(.shift), proxy: proxy)
            }
            .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
                moveSelection(by: 1, extending: press.modifiers.contains(.shift), proxy: proxy)
            }
            .onKeyPress("a", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                selectAllVisible()
                return .handled
            }
            .onKeyPress("c", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                return model.copySelection() ? .handled : .ignored
            }
    }

    private func itemCard(_ item: CaptureItem) -> some View {
        InboxItemRow(
            item: item,
            isSelected: model.selection.contains(item.id),
            isEditing: model.editingID == item.id,
            editAttachments: editAttachmentsBinding(for: item),
            isSaving: savingBinding(for: item),
            attachmentURL: model.attachmentURL,
            onPreviewAttachments: onPreviewAttachments,
            onRemovePreviewURL: onRemovePreviewURL,
            onSelect: { select(item.id) },
            onOpen: { edit(item.id) },
            onToggleDone: { model.toggleDone(id: item.id) },
            onChooseFiles: {
                guard model.editingID == item.id else { return }
                requestFileImport(item.id)
            },
            onCaptureScreenArea: captureScreenAreaForEdit,
            onCancelEdit: {
                model.editingID = nil
                focusedTarget = .list
            },
            onSaveEdit: { text, attachments in
                let saved = await model.update(
                    id: item.id,
                    content: text,
                    attachmentURLs: attachments
                )
                guard saved else { return false }
                model.selection = [item.id]
                model.editingID = nil
                focusedTarget = .list
                return true
            },
            onEditError: { model.presentedError = $0 }
        )
        .contextMenu {
            if model.editingID != item.id {
                selectionMenu(for: contextSelection(for: item.id))
            }
        }
        .accessibilityAddTraits(model.selection.contains(item.id) ? .isSelected : [])
        .accessibilityAction(named: "Select") {
            selectExclusively(item.id)
        }
        .accessibilityAction(named: "Copy") {
            selectExclusively(item.id)
            itemCommands.perform(.copy)
        }
        .accessibilityAction(named: "Edit") {
            edit(item.id)
        }
        .accessibilityAction(named: "Edit in New Window") {
            selectExclusively(item.id)
            itemCommands.perform(.editInNewWindow)
        }
        .accessibilityAction(named: item.isDone ? "Mark Not Done" : "Mark Done") {
            model.toggleDone(id: item.id)
        }
        .accessibilityAction(named: "Move Up") {
            model.selection = contextSelection(for: item.id)
            model.moveSelectionUp()
        }
        .accessibilityAction(named: "Move Down") {
            model.selection = contextSelection(for: item.id)
            model.moveSelectionDown()
        }
        .accessibilityAction(named: "Delete") {
            selectExclusively(item.id)
            itemCommands.perform(.delete)
        }
    }

    private func editAttachmentsBinding(for item: CaptureItem) -> Binding<[URL]> {
        Binding(
            get: {
                guard let editSession, editSession.itemID == item.id else {
                    return item.attachments.map(model.attachmentURL)
                }
                return editSession.attachments
            },
            set: { attachments in
                let isSaving = editSession?.itemID == item.id
                    && editSession?.isSaving == true
                editSession = InlineEditSession(
                    itemID: item.id,
                    attachments: attachments,
                    isSaving: isSaving
                )
            }
        )
    }

    private func savingBinding(for item: CaptureItem) -> Binding<Bool> {
        Binding(
            get: { editSession?.itemID == item.id && editSession?.isSaving == true },
            set: { isSaving in
                let attachments: [URL]
                if let editSession, editSession.itemID == item.id {
                    attachments = editSession.attachments
                } else {
                    attachments = item.attachments.map(model.attachmentURL)
                }
                editSession = InlineEditSession(
                    itemID: item.id,
                    attachments: attachments,
                    isSaving: isSaving
                )
            }
        )
    }

    private func select(_ id: UUID) {
        let update = InboxSelection.click(
            id,
            orderedIDs: orderedItemIDs,
            selection: model.selection,
            anchor: state.anchor,
            focus: state.focus,
            modifiers: inboxSelectionModifiers
        )
        state.apply(update, to: model)
        focusedTarget = .list
    }

    private func edit(_ id: UUID) {
        selectExclusively(id)
        focusedTarget = nil
        model.editingID = id
    }

    private func selectExclusively(_ id: UUID) {
        guard orderedItemIDs.contains(id) else { return }
        state.apply(
            InboxSelection.Update(selection: [id], anchor: id, focus: id),
            to: model
        )
        focusedTarget = .list
    }

    private func moveSelection(
        by offset: Int,
        extending: Bool,
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let update = InboxSelection.move(
            by: offset,
            orderedIDs: orderedItemIDs,
            selection: model.selection,
            anchor: state.anchor,
            focus: state.focus,
            extending: extending
        )
        let current = InboxSelection.Update(
            selection: model.selection,
            anchor: state.anchor,
            focus: state.focus
        )
        guard update != current else { return .handled }
        state.apply(update, to: model)
        if let focus = update.focus {
            proxy.scrollTo(focus, anchor: .center)
        }
        return .handled
    }

    private var inboxSelectionModifiers: InboxSelection.Modifiers {
        var modifiers: InboxSelection.Modifiers = []
        if selectionModifiers.contains(.command) { modifiers.insert(.command) }
        if selectionModifiers.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    private func selectAllVisible() {
        state.selectAllVisible(model: model)
        focusedTarget = .list
    }

    private func contextSelection(for id: UUID) -> Set<UUID> {
        model.selection.contains(id) ? model.selection : [id]
    }

    @ViewBuilder
    private func selectionMenu(for ids: Set<UUID>) -> some View {
        if !ids.isEmpty {
            Button("Copy") { perform(.copy, on: ids) }
            Divider()
            Button(doneCommandTitle(for: ids)) { perform(.toggleDone, on: ids) }
            Button("Edit") { perform(.edit, on: ids) }
                .disabled(!InboxItemCommand.edit.isAvailable(for: ids.count))
            Button("Edit in New Window") { perform(.editInNewWindow, on: ids) }
                .disabled(!InboxItemCommand.editInNewWindow.isAvailable(for: ids.count))
            Button("Merge Clips") { perform(.merge, on: ids) }
                .disabled(!InboxItemCommand.merge.isAvailable(for: ids.count))
            Menu("Move to") {
                ForEach(model.sections) { section in
                    Button(section.name) {
                        model.selection = ids
                        model.moveSelection(to: section.id)
                    }
                }
                Divider()
                Button("New Section…") {
                    moveSelectionToNewSection(ids)
                }
            }
            Button("Move Up") {
                model.selection = ids
                model.moveSelectionUp()
            }
            .disabled(!canReorder(ids))
            Button("Move Down") {
                model.selection = ids
                model.moveSelectionDown()
            }
            .disabled(!canReorder(ids))
            Divider()
            Button("Delete", role: .destructive) { perform(.delete, on: ids) }
        }
    }

    private func perform(_ command: InboxItemCommand, on ids: Set<UUID>) {
        model.selection = ids
        if command == .edit {
            focusedTarget = nil
        }
        itemCommands.perform(command)
    }

    private func doneCommandTitle(for ids: Set<UUID>) -> String {
        let selectedItems = model.items.filter { ids.contains($0.id) }
        return selectedItems.allSatisfy(\.isDone) ? "Mark Not Done" : "Mark Done"
    }

    private func canReorder(_ ids: Set<UUID>) -> Bool {
        model.canReorder(ids: ids)
    }
}
