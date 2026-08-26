import SwiftUI

enum PanelFocusTarget: Hashable {
    case list
    case search
    case inlineEntry
}

private struct InlineEditSession {
    let snipID: UUID
    var attachments: [URL]
    var isSaving = false
}

@MainActor
final class SnipListState: ObservableObject {
    fileprivate var anchor: UUID?
    fileprivate var focus: UUID?

    func selectAllVisible(model: AppModel) {
        model.selectAllVisible()
        let ids = orderedIDs(for: model.filteredSnips)
        anchor = ids.first
        focus = ids.last
    }

    fileprivate func orderedIDs(for snips: [Snip]) -> [UUID] {
        snips.map(\.id)
    }

    fileprivate func apply(_ update: SnipSelection.Update, to model: AppModel) {
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
            focus = orderedIDs(for: model.filteredSnips).first(where: selection.contains)
        }
    }
}

struct SnipListView: View {
    @ObservedObject var model: AppModel
    let coordinator: AppCoordinator
    let snipDragSourceController: SnipDragSourceController
    let fileDropController: PanelFileDropController
    @ObservedObject var state: SnipListState
    @FocusState.Binding var focusedTarget: PanelFocusTarget?
    let moveSelectionToNewList: (Set<UUID>) -> Void
    let requestFileImport: (UUID) -> Void
    @Binding var pendingEditAttachmentImport: PendingEditAttachmentImport?
    let captureScreenAreaForEdit: (@escaping @MainActor (URL?) -> Void) -> Void
    let bottomContentInset: CGFloat
    let onPreviewAttachments: ([URL], URL) -> Void
    let onRemovePreviewURL: (URL) -> Void

    @State private var selectionModifiers: EventModifiers = []
    @StateObject private var dragController = SnipListDragController()
    @State private var pinnedLists: Set<UUID> = []
    @State private var hasScrolledFromTop = false
    @State private var addedSnipRevealState = AddedSnipRevealState()
    @State private var editSession: InlineEditSession?

    private var orderedSnipIDs: [UUID] {
        state.orderedIDs(for: model.filteredSnips)
    }

    private var snipCommands: SnipCommandDispatcher {
        SnipCommandDispatcher(model: model, coordinator: coordinator)
    }

    private var dragContext: SnipListDragContext {
        SnipListDragContext(
            allSnips: model.snips,
            visibleSnips: model.filteredSnips,
            validListIDs: Set(model.lists.map(\.id)),
            sortMode: model.sortMode,
            filtersActive: model.completionFilter != .all
                || !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    var body: some View {
        let snapshot = SnipListSnapshot(
            visibleSnips: model.filteredSnips,
            allSnips: model.snips,
            lists: model.lists,
            selection: model.selection,
            keepsEmptyListID: model.query.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? model.activeListID : nil,
            attachmentURL: model.attachmentURL
        )
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: 0,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        ForEach(snapshot.groups) { group in
                            listGroupView(group, snapshot: snapshot, proxy: proxy)
                        }
                    }
                    .padding(
                        .bottom,
                        PanelOverlayLayout.listBottomPadding(
                            composerHeight: bottomContentInset
                        )
                    )
                    .frame(
                        minHeight: viewport.size.height,
                        alignment: .top
                    )
                    .coordinateSpace(name: SnipListDropSpace.name)
                    .overlay(alignment: .topLeading) {
                        listDropHighlight(snapshot: snapshot)
                    }
                    .background {
                        ZStack {
                            PanelDragRegion()
                                .allowsHitTesting(!dragController.isDragging)
                            SnipListScrollBridge(
                                scroller: dragController.scroller,
                                onScroll: updateScroll
                            )
                        }
                    }
                }
                .scrollEdgeEffectStyle(.hard, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .onModifierKeysChanged(mask: [.command, .shift]) { _, modifiers in
                    selectionModifiers = modifiers
                }
                .task(id: dragController.autoScrollDirection) {
                    await dragController.autoScrollWhileNeeded { dragContext }
                }
                .onChange(of: model.sortMode) {
                    if let selectedID = orderedSnipIDs.first(where: model.selection.contains) {
                        withAnimation(.snappy(duration: 0.18)) {
                            proxy.scrollTo(selectedID, anchor: .center)
                        }
                    }
                }
                .onChange(of: model.latestAddedSnipID) { _, snipID in
                    let isVisibleInModel = snipID.map { addedID in
                        model.filteredSnips.contains(where: { $0.id == addedID })
                    } ?? false
                    if let destination = addedSnipRevealState.record(
                        snipID: snipID,
                        wasAtTop: !hasScrolledFromTop,
                        isVisibleInModel: isVisibleInModel,
                        visibleIDs: snapshot.orderedVisibleIDs
                    ) {
                        revealAddedSnip(at: destination)
                    }
                }
                .onChange(of: snapshot.orderedVisibleIDs) { _, visibleIDs in
                    if let destination = addedSnipRevealState.nextDestination(
                        visibleIDs: visibleIDs
                    ) {
                        revealAddedSnip(at: destination)
                    }
                }
                .onChange(of: model.editingID, initial: true) { _, editingID in
                    if let editingID,
                       let snip = model.snips.first(where: { $0.id == editingID }) {
                        editSession = InlineEditSession(
                            snipID: editingID,
                            attachments: snip.attachments.map(model.attachmentURL)
                        )
                    } else {
                        editSession = nil
                    }
                    guard let editingID,
                          snapshot.orderedVisibleIDs.contains(editingID) else { return }
                    revealEditor(editingID, proxy: proxy)
                }
                .overlay(alignment: .topLeading) {
                    selectionFocusTarget(proxy: proxy)
                }
            }
        }
        .onAppear {
            dragController.retainSnips(Set(snapshot.orderedVisibleIDs))
            state.reconcile(model: model)
        }
        .onChange(of: snapshot.orderedVisibleIDs) { _, visibleIDs in
            dragController.retainSnips(Set(visibleIDs))
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
                to: pendingEditAttachmentImport.snipID
            )
        }
    }

    private func revealEditor(_ snipID: UUID, proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.snappy(duration: 0.18)) {
                proxy.scrollTo(snipID, anchor: .center)
            }
            try? await Task.sleep(for: .milliseconds(220))
            proxy.scrollTo(snipID, anchor: .center)
        }
    }

    private func addEditAttachments(_ urls: [URL], to snipID: UUID) {
        guard model.editingID == snipID,
              let snip = model.snips.first(where: { $0.id == snipID }) else { return }
        var session: InlineEditSession
        if let editSession, editSession.snipID == snipID {
            session = editSession
        } else {
            session = InlineEditSession(
                snipID: snipID,
                attachments: snip.attachments.map(model.attachmentURL)
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

    private func revealAddedSnip(at destination: AddedSnipRevealDestination) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.snappy(duration: 0.18)) {
                switch destination {
                case .scrollViewTop:
                    dragController.scroller.scrollTo(y: 0)
                }
            }
        }
    }

    private func listGroupView(
        _ group: SnipListGroup,
        snapshot: SnipListSnapshot,
        proxy: ScrollViewProxy
    ) -> some View {
        let entries = dragController.entries(for: group)
        return Section {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                listEntry(
                    entry,
                    index: index,
                    listID: group.listID,
                    snapshot: snapshot,
                    proxy: proxy
                )
            }
            listFooter(
                group,
                expandsTop: entries.isEmpty,
                proxy: proxy
            )
        } header: {
            listDropTarget(
                listHeader(group),
                listID: group.listID,
                surface: .header,
                proxy: proxy
            )
        }
    }

    private func listEntry(
        _ entry: SnipListEntry,
        index: Int,
        listID: UUID,
        snapshot: SnipListSnapshot,
        proxy: ScrollViewProxy
    ) -> some View {
        let entryElement = SnipListGeometry.Element.entry(entry.id)
        let content = VStack(alignment: .leading, spacing: 0) {
            PanelDragRegion()
                .frame(
                    height: index == 0
                        ? PanelListMetrics.listSpacing
                        : PanelListMetrics.rowSpacing
                )
                .allowsHitTesting(!dragController.isDragging)

            dropGeometry(
                listEntryContent(entry, snapshot: snapshot),
                for: entryElement
            )
        }
        return listContentDropTarget(
            content,
            listID: listID,
            surface: .entry(entry.id),
            expandsTop: index == 0,
            proxy: proxy
        )
        .onDisappear { dragController.remove(entryElement) }
    }

    @ViewBuilder
    private func listEntryContent(
        _ entry: SnipListEntry,
        snapshot: SnipListSnapshot
    ) -> some View {
        switch entry {
        case .snip(let snip):
            dropGeometry(
                snipCard(snip, snapshot: snapshot)
                    .id(snip.id),
                for: .row(snip.id)
            )
        case .originGap(_, let height):
            dropGap(height: height, showsDestinationEdge: false)
        case .destinationGap(_, let height):
            dropGap(height: height, showsDestinationEdge: true)
        }
    }

    private func listFooter(
        _ group: SnipListGroup,
        expandsTop: Bool,
        proxy: ScrollViewProxy
    ) -> some View {
        let footerElement = SnipListGeometry.Element.listFooter(group.listID)
        let content = dropGeometry(
            PanelDragRegion()
                .frame(height: PanelListMetrics.listSpacing)
                .allowsHitTesting(!dragController.isDragging),
            for: footerElement
        )
        return listContentDropTarget(
            content,
            listID: group.listID,
            surface: .footer,
            expandsTop: expandsTop,
            expandsBottom: true,
            proxy: proxy
        )
        .onDisappear { dragController.remove(footerElement) }
    }

    private func listContentDropTarget<Content: View>(
        _ content: Content,
        listID: UUID,
        surface: SnipListDropSurface,
        expandsTop: Bool = false,
        expandsBottom: Bool = false,
        proxy: ScrollViewProxy
    ) -> some View {
        let element = surface.element(in: listID)
        let expansion = PanelDropTargetStyle.expansion
        let hitInsets = EdgeInsets(
            top: expandsTop ? expansion : 0,
            leading: expansion,
            bottom: expandsBottom ? expansion : 0,
            trailing: expansion
        )
        return listDropTarget(
            dropGeometry(
                content.padding(hitInsets),
                for: element
            ),
            listID: listID,
            surface: surface,
            proxy: proxy
        )
        .padding(
            EdgeInsets(
                top: -hitInsets.top,
                leading: -hitInsets.leading,
                bottom: -hitInsets.bottom,
                trailing: -hitInsets.trailing
            )
        )
        .padding(.horizontal, PanelListMetrics.horizontalContentInset)
        .onDisappear { dragController.remove(element) }
    }

    @ViewBuilder
    private func listDropHighlight(snapshot: SnipListSnapshot) -> some View {
        if let listID = dragController.targetListID,
           let group = snapshot.groups.first(where: { $0.listID == listID }),
           let frame = dragController.listBodyFrame(for: group) {
            let expandedFrame = frame.insetBy(
                dx: -PanelDropTargetStyle.expansion,
                dy: -PanelDropTargetStyle.expansion
            )
            Color.clear
                .frame(width: expandedFrame.width, height: expandedFrame.height)
                .panelDropTargetState(
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                    isTargeted: true
                )
                .offset(x: expandedFrame.minX, y: expandedFrame.minY)
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(.snappy(duration: 0.16), value: listID)
        }
    }

    @ViewBuilder
    private func dropGeometry<Content: View>(
        _ content: Content,
        for element: SnipListGeometry.Element
    ) -> some View {
        if dragController.needsDropGeometry {
            content.onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(SnipListDropSpace.name))
            } action: { frame in
                dragController.record(frame, for: element)
            }
        } else {
            content
        }
    }

    private func listHeader(_ group: SnipListGroup) -> some View {
        let isPinned = pinnedLists.contains(group.listID)
        let showsGlass = PinnedListHeaderGlass.isVisible(
            isPinned: isPinned,
            hasScrolled: hasScrolledFromTop
        )
        return PanelListHeader(group.list, showsGlass: showsGlass)
            .background {
                SnipDragBlockingRegion(
                    controller: snipDragSourceController,
                    id: group.listID
                )
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(SnipListDropSpace.name))
            } action: { frame in
                dragController.record(frame, for: .heading(group.listID))
            }
            .onDisappear {
                dragController.remove(.heading(group.listID))
                if let updated = PinnedListHeaderGlass.updatedLists(
                    pinnedLists,
                    listID: group.listID,
                    isPinned: false
                ) {
                    pinnedLists = updated
                }
            }
            .overlay {
                PanelDragRegion()
                    .allowsHitTesting(!dragController.isDragging)
            }
    }

    private func updateScroll(_ metrics: SnipListGeometry.ScrollSnapshot) {
        dragController.updateScroll(metrics)
        let hasScrolled = PinnedListHeaderGlass.hasScrolled(
            visibleOriginY: metrics.visibleOrigin.y
        )
        if hasScrolledFromTop != hasScrolled {
            hasScrolledFromTop = hasScrolled
        }
        let nextPinnedLists = dragController.pinnedListIDs()
        if pinnedLists != nextPinnedLists {
            pinnedLists = nextPinnedLists
        }
    }

    private func listDropTarget<Content: View>(
        _ content: Content,
        listID: UUID,
        surface: SnipListDropSurface,
        proxy: ScrollViewProxy
    ) -> some View {
        content
        .dropDestination(for: PanelDropPayload.self) { payloads, session in
            handleDrop(
                payloads: payloads,
                session: session,
                listID: listID,
                surface: surface,
                proxy: proxy
            )
        }
        .onDropSessionUpdated { session in
            if dragController.isDragging {
                dragController.updateDropSession(
                    session,
                    listID: listID,
                    surface: surface,
                    context: dragContext
                )
            } else {
                dragController.updateClipboardDropSession(
                    session,
                    listID: listID,
                    surface: surface,
                    context: dragContext
                )
            }
        }
        .dropConfiguration { session in
            let operation: DropOperation = session.suggestedOperations.contains(.move)
                ? .move
                : .copy
            var configuration = DropConfiguration(operation: operation)
            configuration.acceptedItemCount = 1
            return configuration
        }
    }

    private func dropGap(
        height: CGFloat,
        showsDestinationEdge: Bool
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Color.clear
            .frame(height: max(height, 2))
            .overlay {
                if showsDestinationEdge {
                    shape.stroke(SnipSnapColors.insertionEdge, lineWidth: 1)
                }
            }
            .contentShape(shape)
            .transition(.opacity)
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

    private func snipCard(_ snip: Snip, snapshot: SnipListSnapshot) -> some View {
        let payload = snapshot.dragPayload(for: snip)
        return SnipCardRow(
            snip: snip,
            isSelected: model.selection.contains(snip.id),
            isEditing: model.editingID == snip.id,
            dragPayload: payload,
            dragSourceController: snipDragSourceController,
            editAttachments: editAttachmentsBinding(for: snip),
            isSaving: savingBinding(for: snip),
            attachmentURL: model.attachmentURL,
            onPreviewAttachments: onPreviewAttachments,
            onRemovePreviewURL: onRemovePreviewURL,
            onSelect: { select(snip.id) },
            onOpen: { edit(snip.id) },
            onToggleDone: { model.toggleDone(id: snip.id) },
            onChooseFiles: {
                guard model.editingID == snip.id else { return }
                requestFileImport(snip.id)
            },
            onCaptureScreenArea: captureScreenAreaForEdit,
            onCancelEdit: {
                model.editingID = nil
                focusedTarget = .list
            },
            onSaveEdit: { text, attachments in
                let saved = await model.update(
                    id: snip.id,
                    content: text,
                    attachmentURLs: attachments
                )
                guard saved else { return false }
                model.selection = [snip.id]
                model.editingID = nil
                focusedTarget = .list
                return true
            },
            onEditError: { model.presentedError = $0 },
            onDragBegan: {
                dragController.beginNativeDrag(payload)
            },
            onDragEnded: { outcome in
                dragController.endNativeDrag(
                    payload,
                    outcome: outcome,
                    markDoneAfterExternalCopy: model.markDoneAfterExternalDrop
                )
            }
        )
        .contextMenu {
            if model.editingID != snip.id {
                selectionMenu(for: contextSelection(for: snip.id))
            }
        }
        .accessibilityAddTraits(model.selection.contains(snip.id) ? .isSelected : [])
        .accessibilityAction(named: "Select") {
            selectExclusively(snip.id)
        }
        .accessibilityAction(named: "Copy") {
            selectExclusively(snip.id)
            snipCommands.perform(.copy)
        }
        .accessibilityAction(named: "Edit") {
            edit(snip.id)
        }
        .accessibilityAction(named: "Edit in New Window") {
            selectExclusively(snip.id)
            snipCommands.perform(.editInNewWindow)
        }
        .accessibilityAction(named: snip.isDone ? "Mark Not Done" : "Mark Done") {
            model.toggleDone(id: snip.id)
        }
        .accessibilityAction(named: "Move Up") {
            model.selection = contextSelection(for: snip.id)
            model.moveSelectionUp()
        }
        .accessibilityAction(named: "Move Down") {
            model.selection = contextSelection(for: snip.id)
            model.moveSelectionDown()
        }
        .accessibilityAction(named: "Delete") {
            selectExclusively(snip.id)
            snipCommands.perform(.delete)
        }
    }

    private func editAttachmentsBinding(for snip: Snip) -> Binding<[URL]> {
        Binding(
            get: {
                guard let editSession, editSession.snipID == snip.id else {
                    return snip.attachments.map(model.attachmentURL)
                }
                return editSession.attachments
            },
            set: { attachments in
                let isSaving = editSession?.snipID == snip.id
                    && editSession?.isSaving == true
                editSession = InlineEditSession(
                    snipID: snip.id,
                    attachments: attachments,
                    isSaving: isSaving
                )
            }
        )
    }

    private func savingBinding(for snip: Snip) -> Binding<Bool> {
        Binding(
            get: { editSession?.snipID == snip.id && editSession?.isSaving == true },
            set: { isSaving in
                let attachments: [URL]
                if let editSession, editSession.snipID == snip.id {
                    attachments = editSession.attachments
                } else {
                    attachments = snip.attachments.map(model.attachmentURL)
                }
                editSession = InlineEditSession(
                    snipID: snip.id,
                    attachments: attachments,
                    isSaving: isSaving
                )
            }
        )
    }

    private func handleDrop(
        payloads: [PanelDropPayload],
        session: DropSession,
        listID: UUID,
        surface: SnipListDropSurface,
        proxy: ScrollViewProxy
    ) {
        guard payloads.count == 1, let payload = payloads.first else { return }
        switch payload {
        case .clipboard(let clipboardPayload):
            guard let entry = model.clipboardHistory.entry(id: clipboardPayload.entryID) else { return }
            let plan = dragController.clipboardDropPlan(
                session: session,
                listID: listID,
                surface: surface,
                context: dragContext
            )
            Task { @MainActor in
                let saved = await model.saveClipboardEntry(
                    entry,
                    listID: plan.listID,
                    before: plan.beforeID,
                    placesManually: plan.behavior == .exact
                )
                if saved, let id = model.latestAddedSnipID {
                    withAnimation(.snappy(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        case .snip(let snipPayload):
            handleSnipDrop(
                payload: snipPayload,
                session: session,
                listID: listID,
                surface: surface,
                proxy: proxy
            )
        }
    }

    private func handleSnipDrop(
        payload: SnipDragPayload,
        session: DropSession,
        listID: UUID,
        surface: SnipListDropSurface,
        proxy: ScrollViewProxy
    ) {
        guard let execution = dragController.beginDrop(
            payloads: [payload],
            session: session,
            listID: listID,
            surface: surface,
            context: dragContext
        ) else { return }
        let selectionBeforeMove = model.selection

        Task { @MainActor in
            defer { dragController.completeDrop(execution) }
            let moved: Bool
            switch execution.plan.behavior {
            case .exact, .listTop:
                moved = await model.move(
                    ids: execution.payload.ids,
                    to: execution.plan.listID,
                    before: execution.plan.beforeID,
                    selectionAfterMove: selectionBeforeMove
                )
            case .chronological:
                moved = await model.moveChronologically(
                    ids: execution.payload.ids,
                    to: execution.plan.listID,
                    selectionAfterMove: selectionBeforeMove
                )
            }
            if moved, let firstID = execution.payload.ids.first {
                withAnimation(.snappy(duration: 0.18)) {
                    proxy.scrollTo(firstID, anchor: .center)
                }
            }
        }
    }

    private func select(_ id: UUID) {
        let update = SnipSelection.click(
            id,
            orderedIDs: orderedSnipIDs,
            selection: model.selection,
            anchor: state.anchor,
            focus: state.focus,
            modifiers: snipSelectionModifiers
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
        guard orderedSnipIDs.contains(id) else { return }
        state.apply(
            SnipSelection.Update(selection: [id], anchor: id, focus: id),
            to: model
        )
        focusedTarget = .list
    }

    private func moveSelection(
        by offset: Int,
        extending: Bool,
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        let update = SnipSelection.move(
            by: offset,
            orderedIDs: orderedSnipIDs,
            selection: model.selection,
            anchor: state.anchor,
            focus: state.focus,
            extending: extending
        )
        let current = SnipSelection.Update(
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

    private var snipSelectionModifiers: SnipSelection.Modifiers {
        var modifiers: SnipSelection.Modifiers = []
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
                .disabled(!SnipCommand.edit.isAvailable(for: ids.count))
            Button("Edit in New Window") { perform(.editInNewWindow, on: ids) }
                .disabled(!SnipCommand.editInNewWindow.isAvailable(for: ids.count))
            Button("Merge Snips") { perform(.merge, on: ids) }
                .disabled(!SnipCommand.merge.isAvailable(for: ids.count))
            Menu("Move to") {
                ForEach(model.lists) { list in
                    Button(list.name) {
                        model.selection = ids
                        model.moveSelection(to: list.id)
                    }
                }
                Divider()
                Button("New List…") {
                    moveSelectionToNewList(ids)
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

    private func perform(_ command: SnipCommand, on ids: Set<UUID>) {
        model.selection = ids
        if command == .edit {
            focusedTarget = nil
        }
        snipCommands.perform(command)
    }

    private func doneCommandTitle(for ids: Set<UUID>) -> String {
        let selectedSnips = model.snips.filter { ids.contains($0.id) }
        return selectedSnips.allSatisfy(\.isDone) ? "Mark Not Done" : "Mark Done"
    }

    private func canReorder(_ ids: Set<UUID>) -> Bool {
        model.canReorder(ids: ids)
    }
}
