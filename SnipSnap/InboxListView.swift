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
    let captureScreenAreaForEdit: (@escaping @MainActor (URL?) -> Void) -> Void
    let bottomContentInset: CGFloat
    let onPreviewAttachments: ([URL], URL) -> Void
    let onRemovePreviewURL: (URL) -> Void

    @State private var selectionModifiers: EventModifiers = []
    @StateObject private var dragController = InboxDragController()
    @State private var pinnedSections: Set<UUID> = []
    @State private var hasScrolledFromTop = false
    @State private var addedClipRevealState = InboxAddedClipRevealState()
    @State private var editSession: InlineEditSession?

    private var orderedItemIDs: [UUID] {
        state.orderedIDs(for: model.filteredItems)
    }

    private var itemCommands: InboxItemCommandDispatcher {
        InboxItemCommandDispatcher(model: model, coordinator: coordinator)
    }

    private var dragContext: InboxDragContext {
        InboxDragContext(
            allItems: model.items,
            visibleItems: model.filteredItems,
            validSectionIDs: Set(model.sections.map(\.id)),
            sortMode: model.sortMode,
            filtersActive: model.completionFilter != .all
                || !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
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
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: 0,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        ForEach(snapshot.groups) { group in
                            sectionView(group, snapshot: snapshot, proxy: proxy)
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
                    .coordinateSpace(name: InboxDropSpace.name)
                    .overlay(alignment: .topLeading) {
                        sectionDropHighlight(snapshot: snapshot)
                    }
                    .background {
                        ZStack {
                            PanelDragRegion()
                                .allowsHitTesting(!dragController.isDragging)
                            InboxScrollBridge(
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
                        revealAddedClip(at: destination)
                    }
                }
                .onChange(of: snapshot.orderedVisibleIDs) { _, visibleIDs in
                    if let destination = addedClipRevealState.nextDestination(
                        visibleIDs: visibleIDs
                    ) {
                        revealAddedClip(at: destination)
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
        }
        .onAppear {
            dragController.retainItems(Set(snapshot.orderedVisibleIDs))
            state.reconcile(model: model)
        }
        .onChange(of: snapshot.orderedVisibleIDs) { _, visibleIDs in
            dragController.retainItems(Set(visibleIDs))
        }
        .onChange(of: model.selection) {
            state.reconcile(model: model)
        }
        .onReceive(fileDropController.fileDrops) { urls in
            guard let editingID = model.editingID,
                  model.items.contains(where: { $0.id == editingID }) else { return }
            addEditAttachments(urls, to: editingID)
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

    private func revealAddedClip(at destination: InboxAddedClipRevealDestination) {
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

    private func sectionView(
        _ group: InboxItemGroup,
        snapshot: InboxListSnapshot,
        proxy: ScrollViewProxy
    ) -> some View {
        let entries = dragController.entries(for: group)
        return Section {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                sectionEntry(
                    entry,
                    index: index,
                    sectionID: group.sectionID,
                    snapshot: snapshot,
                    proxy: proxy
                )
            }
            sectionFooter(
                group,
                expandsTop: entries.isEmpty,
                proxy: proxy
            )
        } header: {
            sectionDropTarget(
                sectionHeader(group),
                sectionID: group.sectionID,
                surface: .header,
                proxy: proxy
            )
        }
    }

    private func sectionEntry(
        _ entry: ClipListEntry,
        index: Int,
        sectionID: UUID,
        snapshot: InboxListSnapshot,
        proxy: ScrollViewProxy
    ) -> some View {
        let entryElement = InboxListGeometry.Element.entry(entry.id)
        let content = VStack(alignment: .leading, spacing: 0) {
            PanelDragRegion()
                .frame(
                    height: index == 0
                        ? PanelListMetrics.sectionSpacing
                        : PanelListMetrics.rowSpacing
                )
                .allowsHitTesting(!dragController.isDragging)

            dropGeometry(
                sectionEntryContent(entry, snapshot: snapshot),
                for: entryElement
            )
        }
        return sectionContentDropTarget(
            content,
            sectionID: sectionID,
            surface: .entry(entry.id),
            expandsTop: index == 0,
            proxy: proxy
        )
        .onDisappear { dragController.remove(entryElement) }
    }

    @ViewBuilder
    private func sectionEntryContent(
        _ entry: ClipListEntry,
        snapshot: InboxListSnapshot
    ) -> some View {
        switch entry {
        case .item(let item):
            dropGeometry(
                itemCard(item, snapshot: snapshot)
                    .id(item.id),
                for: .row(item.id)
            )
        case .originGap(_, let height):
            dropGap(height: height, showsDestinationEdge: false)
        case .destinationGap(_, let height):
            dropGap(height: height, showsDestinationEdge: true)
        }
    }

    private func sectionFooter(
        _ group: InboxItemGroup,
        expandsTop: Bool,
        proxy: ScrollViewProxy
    ) -> some View {
        let footerElement = InboxListGeometry.Element.sectionFooter(group.sectionID)
        let content = dropGeometry(
            PanelDragRegion()
                .frame(height: PanelListMetrics.sectionSpacing)
                .allowsHitTesting(!dragController.isDragging),
            for: footerElement
        )
        return sectionContentDropTarget(
            content,
            sectionID: group.sectionID,
            surface: .footer,
            expandsTop: expandsTop,
            expandsBottom: true,
            proxy: proxy
        )
        .onDisappear { dragController.remove(footerElement) }
    }

    private func sectionContentDropTarget<Content: View>(
        _ content: Content,
        sectionID: UUID,
        surface: SectionDropSurface,
        expandsTop: Bool = false,
        expandsBottom: Bool = false,
        proxy: ScrollViewProxy
    ) -> some View {
        let element = surface.element(in: sectionID)
        let expansion = PanelDropTargetStyle.expansion
        let hitInsets = EdgeInsets(
            top: expandsTop ? expansion : 0,
            leading: expansion,
            bottom: expandsBottom ? expansion : 0,
            trailing: expansion
        )
        return sectionDropTarget(
            dropGeometry(
                content.padding(hitInsets),
                for: element
            ),
            sectionID: sectionID,
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
    private func sectionDropHighlight(snapshot: InboxListSnapshot) -> some View {
        if let sectionID = dragController.targetSectionID,
           let group = snapshot.groups.first(where: { $0.sectionID == sectionID }),
           let frame = dragController.sectionBodyFrame(for: group) {
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
                .animation(.snappy(duration: 0.16), value: sectionID)
        }
    }

    @ViewBuilder
    private func dropGeometry<Content: View>(
        _ content: Content,
        for element: InboxListGeometry.Element
    ) -> some View {
        if dragController.needsDropGeometry {
            content.onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(InboxDropSpace.name))
            } action: { frame in
                dragController.record(frame, for: element)
            }
        } else {
            content
        }
    }

    private func sectionHeader(_ group: InboxItemGroup) -> some View {
        let isPinned = pinnedSections.contains(group.sectionID)
        let showsGlass = InboxPinnedHeaderGlass.isVisible(
            isPinned: isPinned,
            hasScrolled: hasScrolledFromTop
        )
        return PanelListHeader(group.section, showsGlass: showsGlass)
            .background {
                ClipDragBlockingRegion(
                    controller: clipDragSourceController,
                    id: group.sectionID
                )
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(InboxDropSpace.name))
            } action: { frame in
                dragController.record(frame, for: .heading(group.sectionID))
            }
            .onDisappear {
                dragController.remove(.heading(group.sectionID))
                if let updated = InboxPinnedHeaderGlass.updatedSections(
                    pinnedSections,
                    sectionID: group.sectionID,
                    isPinned: false
                ) {
                    pinnedSections = updated
                }
            }
            .overlay {
                PanelDragRegion()
                    .allowsHitTesting(!dragController.isDragging)
            }
    }

    private func updateScroll(_ metrics: InboxListGeometry.ScrollSnapshot) {
        dragController.updateScroll(metrics)
        let hasScrolled = InboxPinnedHeaderGlass.hasScrolled(
            visibleOriginY: metrics.visibleOrigin.y
        )
        if hasScrolledFromTop != hasScrolled {
            hasScrolledFromTop = hasScrolled
        }
        let nextPinnedSections = dragController.pinnedSectionIDs()
        if pinnedSections != nextPinnedSections {
            pinnedSections = nextPinnedSections
        }
    }

    private func sectionDropTarget<Content: View>(
        _ content: Content,
        sectionID: UUID,
        surface: SectionDropSurface,
        proxy: ScrollViewProxy
    ) -> some View {
        content
        .dropDestination(for: PanelDropPayload.self) { payloads, session in
            handleDrop(
                payloads: payloads,
                session: session,
                sectionID: sectionID,
                surface: surface,
                proxy: proxy
            )
        }
        .onDropSessionUpdated { session in
            if dragController.isDragging {
                dragController.updateDropSession(
                    session,
                    sectionID: sectionID,
                    surface: surface,
                    context: dragContext
                )
            } else {
                dragController.updateClipboardDropSession(
                    session,
                    sectionID: sectionID,
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

    private func itemCard(_ item: CaptureItem, snapshot: InboxListSnapshot) -> some View {
        let payload = snapshot.dragPayload(for: item)
        return InboxItemRow(
            item: item,
            isSelected: model.selection.contains(item.id),
            isEditing: model.editingID == item.id,
            dragPayload: payload,
            dragSourceController: clipDragSourceController,
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

    private func handleDrop(
        payloads: [PanelDropPayload],
        session: DropSession,
        sectionID: UUID,
        surface: SectionDropSurface,
        proxy: ScrollViewProxy
    ) {
        guard payloads.count == 1, let payload = payloads.first else { return }
        switch payload {
        case .clipboard(let clipboardPayload):
            guard let entry = model.clipboardHistory.entry(id: clipboardPayload.entryID) else { return }
            let plan = dragController.clipboardDropPlan(
                session: session,
                sectionID: sectionID,
                surface: surface,
                context: dragContext
            )
            Task { @MainActor in
                let saved = await model.saveClipboardEntry(
                    entry,
                    sectionID: plan.sectionID,
                    before: plan.beforeID,
                    placesManually: plan.behavior == .exact
                )
                if saved, let id = model.latestAddedClipID {
                    withAnimation(.snappy(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        case .clip(let clipPayload):
            handleClipDrop(
                payload: clipPayload,
                session: session,
                sectionID: sectionID,
                surface: surface,
                proxy: proxy
            )
        }
    }

    private func handleClipDrop(
        payload: ClipDragPayload,
        session: DropSession,
        sectionID: UUID,
        surface: SectionDropSurface,
        proxy: ScrollViewProxy
    ) {
        guard let execution = dragController.beginDrop(
            payloads: [payload],
            session: session,
            sectionID: sectionID,
            surface: surface,
            context: dragContext
        ) else { return }
        let selectionBeforeMove = model.selection

        Task { @MainActor in
            defer { dragController.completeDrop(execution) }
            let moved: Bool
            switch execution.plan.behavior {
            case .exact, .sectionTop:
                moved = await model.move(
                    ids: execution.payload.ids,
                    to: execution.plan.sectionID,
                    before: execution.plan.beforeID,
                    selectionAfterMove: selectionBeforeMove
                )
            case .chronological:
                moved = await model.moveChronologically(
                    ids: execution.payload.ids,
                    to: execution.plan.sectionID,
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
