import AppKit
import SnipSnapCore
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

private enum SnipListScrollTarget {
    case top
}

struct SnipListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    let dragSessionController: PanelDragSessionController
    let fileDropController: PanelFileDropController
    @ObservedObject var commandNumberPicker: CommandNumberPicker
    @FocusState.Binding var focusedTarget: PanelFocusTarget?
    let moveSelectionToNewList: (Set<UUID>) -> Void
    let requestFileImport: (UUID) -> Void
    @Binding var pendingEditAttachmentImport: PendingEditAttachmentImport?
    let captureScreenAreaForEdit: (@escaping @MainActor (URL?) -> Void) -> Void
    let bottomContentInset: CGFloat
    let clipboardEntries: [ClipboardEntry]
    let onPreviewAttachments: ([URL], URL) -> Void
    let onRemovePreviewURL: (URL) -> Void

    @State private var contextMenuSelection: Set<UUID>?
    @State private var hasScrolledFromTop = false
    @State private var addedSnipRevealState = AddedSnipRevealState()
    @State private var editSession: InlineEditSession?
    @State private var pendingOrderByList: [UUID: [UUID]] = [:]
    @State private var activeDragPayload: SnipDragPayload?
    @State private var activeDragOriginalOrder: [UUID] = []
    @State private var activeDragScrollOffsetY: CGFloat = 0
    @State private var activeDropTarget: SnipListReorderTarget?
    @State private var isCommittingDrop = false
    @State private var activeDragRowFrames: [UUID: CGRect] = [:]
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @StateObject private var cardInteractionController = PanelCardInteractionController()
    @StateObject private var reorderGeometry = SnipListReorderGeometry()

    private var orderedSnipIDs: [UUID] {
        model.filteredSnips.map(\.id)
    }

    private var snipCommands: SnipCommandDispatcher {
        SnipCommandDispatcher(model: model)
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
        let showsSearchLists = snapshot.groups.count > 1
        let showsActiveListHeader = !showsSearchLists
            && (clipboardEntries.isEmpty || !snapshot.orderedVisibleIDs.isEmpty)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: 0,
                    pinnedViews: [.sectionHeaders]
                ) {
                    Color.clear
                        .frame(height: 0)
                        .id(SnipListScrollTarget.top)
                    if showsSearchLists {
                        ForEach(snapshot.groups) { group in
                            Section {
                                sectionContentTopSpacer
                                ForEach(group.snips) { snip in
                                    reorderableSnipCard(
                                        snip,
                                        snapshot: snapshot,
                                        listID: group.listID,
                                        snips: group.snips
                                    )
                                }
                            } header: {
                                listSectionHeader(group.listName)
                            }
                        }
                    } else if showsActiveListHeader {
                        let displayedSnips = displayedSnips(in: snapshot)
                        Section {
                            sectionContentTopSpacer
                            ForEach(displayedSnips) { snip in
                                reorderableSnipCard(
                                    snip,
                                    snapshot: snapshot,
                                    listID: model.activeListID,
                                    snips: displayedSnips
                                )
                            }
                        } header: {
                            listSectionHeader(model.activeList.displayName)
                        }
                    }
                    if !clipboardEntries.isEmpty {
                        Section {
                            sectionContentTopSpacer
                            ForEach(clipboardEntries) { entry in
                                clipboardEntryRow(entry)
                            }
                        } header: {
                            listSectionHeader("Clipboard")
                        }
                    }
                    bottomSpacer
                }
                .panelMeasuredHeight($contentHeight)
            }
            .contentMargins(0, for: .scrollContent)
            .background {
                SnipListWindowFrameReader { frame, _ in
                    reorderGeometry.listFrame = frame
                    commandNumberPicker.setViewport(frame)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
                    > PanelGeometryChange.minimumMeaningfulChange
            } action: { _, hasScrolled in
                hasScrolledFromTop = hasScrolled
            }
            .onChange(of: model.sortMode) {
                if let selectedID = orderedSnipIDs.first(where: model.selection.contains) {
                    animateIfAllowed(.snappy(duration: 0.18)) {
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
                    revealAddedSnip(
                        at: destination,
                        proxy: proxy
                    )
                }
            }
            .onChange(of: snapshot.orderedVisibleIDs) { _, visibleIDs in
                if let destination = addedSnipRevealState.nextDestination(
                    visibleIDs: visibleIDs
                ) {
                    revealAddedSnip(
                        at: destination,
                        proxy: proxy
                    )
                }
            }
            .onChange(of: model.editingID, initial: true) { _, editingID in
                editSession = editingID.flatMap { snipID in
                    model.snips.first(where: { $0.id == snipID }).map { snip in
                        InlineEditSession(
                            snipID: snipID,
                            attachments: snip.attachments.compactMap(model.attachmentURL)
                        )
                    }
                }
                guard let editingID,
                      snapshot.orderedVisibleIDs.contains(editingID) else { return }
                Task { @MainActor in
                    await Task.yield()
                    animateIfAllowed(.snappy(duration: 0.18)) {
                        proxy.scrollTo(editingID, anchor: .center)
                    }
                    try? await Task.sleep(for: .milliseconds(220))
                    proxy.scrollTo(editingID, anchor: .center)
                }
            }
            .overlay(alignment: .topLeading) {
                selectionFocusTarget(proxy: proxy)
            }
            .panelBlankDragOverlay(
                viewportHeight: $viewportHeight,
                contentHeight: contentHeight
            )
        }
        .onAppear {
            model.reconcileSelection()
            commandNumberPicker.setOrderedTargets(
                commandNumberTargets(snapshot: snapshot)
            )
        }
        .onChange(of: snapshot.orderedVisibleIDs) { _, _ in
            commandNumberPicker.setOrderedTargets(
                commandNumberTargets(snapshot: snapshot)
            )
        }
        .onChange(of: clipboardEntries.map(\.id)) { _, _ in
            commandNumberPicker.setOrderedTargets(
                commandNumberTargets(snapshot: snapshot)
            )
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
        .background {
            PanelCardInteractionHost(
                controller: cardInteractionController,
                onClickAway: { [model] in
                    model.applySelection(
                        SnipSelection.Update(selection: [], anchor: nil, focus: nil)
                    )
                }
            )
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
                attachments: snip.attachments.compactMap(model.attachmentURL)
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

    private func revealAddedSnip(
        at destination: AddedSnipRevealDestination,
        proxy: ScrollViewProxy
    ) {
        Task { @MainActor in
            await Task.yield()
            animateIfAllowed(.snappy(duration: 0.18)) {
                switch destination {
                case .scrollViewTop:
                    proxy.scrollTo(SnipListScrollTarget.top, anchor: .top)
                }
            }
        }
    }

    private var bottomSpacer: some View {
        PanelDragRegion()
            .frame(maxWidth: .infinity)
            .frame(
                height: PanelOverlayLayout.listBottomPadding(
                    composerHeight: bottomContentInset
                )
            )
    }

    private var sectionContentTopSpacer: some View {
        Color.clear
            .frame(
                height: PanelListMetrics.verticalContentInset
                    + PanelListMetrics.rowSpacing / 2
            )
    }

    private var canDragReorder: Bool {
        model.editingID == nil
            && model.completionFilter == .all
            && model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func listSectionHeader(_ title: String) -> some View {
        PanelListHeader(title, hasScrolledFromTop: hasScrolledFromTop)
            .background {
                PanelDragBlockingRegion(
                    controller: dragSessionController
                )
            }
    }

    private func reorderableSnipCard(
        _ snip: Snip,
        snapshot: SnipListSnapshot,
        listID: UUID,
        snips: [Snip]
    ) -> some View {
        let payload = snapshot.dragPayload(for: snip)
        return snipCard(snip)
                .opacity(isShowingDragGap(for: snip.id) ? 0 : 1)
                .background {
                    if model.editingID != snip.id {
                        PanelDragSourceRegion(
                            controller: dragSessionController,
                            regionID: .snip(snip.id),
                            adapter: snipDragAdapter(
                                payload: payload,
                                listID: listID,
                                snips: snips
                            )
                        )
                    }
                }
                .panelListRowLayout()
                .id(snip.id)
                .background {
                    SnipListWindowFrameReader { frame, scrollOffsetY in
                        reorderGeometry.rowFrames[snip.id] = frame
                        reorderGeometry.scrollOffsetY = scrollOffsetY
                        commandNumberPicker.setRowFrame(.snip(snip.id), frame: frame)
                    }
                }
                .onDisappear {
                    reorderGeometry.rowFrames[snip.id] = nil
                    commandNumberPicker.setRowFrame(.snip(snip.id), frame: nil)
                }
    }

    private func clipboardEntryRow(_ entry: ClipboardEntry) -> some View {
        ClipboardEntryRow(
            entry: entry,
            dragSessionController: dragSessionController,
            commandNumber: commandNumberPicker.displayedNumber(for: .clipboardEntry(entry.id)),
            onPickCommandNumber: {
                commandNumberPicker.pick(.clipboardEntry(entry.id))
            },
            copiedPulse: model.clipboardCopyPulse,
            onPreviewAttachments: onPreviewAttachments
        ) {
            model.placeOnClipboard(.clipboardEntry(entry), feedback: $0)
        } save: {
            Task { _ = await model.saveClipboardEntry(entry) }
        }
        .background {
            SnipListWindowFrameReader { frame, _ in
                commandNumberPicker.setRowFrame(.clipboardEntry(entry.id), frame: frame)
            }
        }
        .onDisappear {
            commandNumberPicker.setRowFrame(.clipboardEntry(entry.id), frame: nil)
        }
        .panelListRowLayout()
    }

    private func beginDrag(_ payload: SnipDragPayload, orderedIDs: [UUID]) {
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

    private func snipDragAdapter(
        payload: SnipDragPayload,
        listID: UUID,
        snips: [Snip]
    ) -> PanelDragSessionAdapter {
        .exporting(
            makeExport: { SnipDragExportPackage(payload: payload) },
            previewImage: { export, context in
                SnipDragPreview.image(for: export.payload, in: context)
            },
            canBegin: { !payload.hasRemoteOnlyAttachments },
            onBlocked: {
                Task { @MainActor in
                    _ = await model.prepareAttachmentsForExternalDrag(
                        snipIDs: payload.ids
                    )
                }
            },
            callbacks: PanelDragSessionCallbacks(
                onBegan: {
                    beginDrag(payload, orderedIDs: snips.map(\.id))
                },
                onMoved: { point in
                    updateDrag(at: point, listID: listID, snips: snips)
                },
                onEnded: { outcome, point in
                    endDrag(
                        payload,
                        outcome: outcome,
                        at: point,
                        listID: listID,
                        snips: snips
                    )
                }
            )
        )
    }

    private func updateDrag(
        at location: CGPoint,
        listID: UUID,
        snips: [Snip]
    ) {
        guard activeDragPayload != nil, !activeDragOriginalOrder.isEmpty else { return }
        guard reorderGeometry.listFrame.contains(location) else {
            if activeDropTarget != nil {
                activeDropTarget = nil
                pendingOrderByList[listID] = nil
            }
            return
        }
        let target = reorderTarget(at: location, snips: snips)
        activeDropTarget = target
        updatePendingOrder(listID: listID, target: target)
    }

    private func reorderTarget(
        at location: CGPoint,
        snips: [Snip]
    ) -> SnipListReorderTarget {
        let placementFrames = activeDragRowFrames.isEmpty
            ? reorderGeometry.rowFrames
            : activeDragRowFrames
        return SnipListReorderPlan.target(
            atWindowY: location.y,
            orderedIDs: snips.map(\.id),
            movingIDs: Set(activeDragPayload?.ids ?? []),
            rowFrames: placementFrames,
            rowFrameOffsetY: reorderGeometry.scrollOffsetY - activeDragScrollOffsetY
        )
    }

    private func updatePendingOrder(
        listID: UUID,
        target: SnipListReorderTarget
    ) {
        guard let payload = activeDragPayload else { return }
        guard let reorderedIDs = SnipListReorderPlan.orderedIDs(
            from: activeDragOriginalOrder,
            movingIDs: payload.ids,
            target: target
        ) else { return }
        guard pendingOrderByList[listID] != reorderedIDs else { return }
        animateIfAllowed(.easeOut(duration: 0.12)) {
            pendingOrderByList[listID] = reorderedIDs
        }
    }

    private func commitDrop(
        _ payload: SnipDragPayload,
        target: SnipListReorderTarget,
        listID: UUID
    ) {
        guard payload == activeDragPayload else { return }
        guard let reorderedIDs = SnipListReorderPlan.orderedIDs(
            from: activeDragOriginalOrder,
            movingIDs: payload.ids,
            target: target
        ), reorderedIDs != activeDragOriginalOrder else {
            clearDrag(listID: listID)
            return
        }
        activeDropTarget = target
        updatePendingOrder(listID: listID, target: target)
        isCommittingDrop = true
        Task { @MainActor in
            _ = await model.move(
                ids: payload.ids,
                to: listID,
                before: target.beforeID
            )
            guard payload == activeDragPayload, isCommittingDrop else { return }
            clearDrag(listID: listID)
        }
    }

    private func endDrag(
        _ payload: SnipDragPayload,
        outcome: PanelDragSessionOutcome,
        at location: CGPoint,
        listID: UUID,
        snips: [Snip]
    ) {
        guard payload == activeDragPayload else { return }
        let droppedInList = !activeDragOriginalOrder.isEmpty
            && reorderGeometry.listFrame.contains(location)
        if droppedInList {
            let finalTarget = reorderTarget(at: location, snips: snips)
            commitDrop(payload, target: finalTarget, listID: listID)
            return
        }
        if ClipboardDragPlacement.shouldPlace(outcome: outcome, droppedInList: false) {
            model.setDoneAfterExternalDrop(ids: payload.ids)
            let placed = payload.ids.compactMap { id in
                model.snips.first { $0.id == id }
            }
            _ = model.placeOnClipboard(.snips(placed), feedback: .silent)
        }
        guard outcome == .move else {
            clearDrag(listID: listID)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard payload == activeDragPayload, !isCommittingDrop else { return }
            clearDrag(listID: listID)
        }
    }

    private func isShowingDragGap(for snipID: UUID) -> Bool {
        activeDragPayload?.ids.contains(snipID) == true
    }

    private func clearDrag(listID: UUID) {
        animateIfAllowed(.snappy(duration: 0.12)) {
            pendingOrderByList[listID] = nil
            activeDragPayload = nil
            activeDragOriginalOrder = []
            activeDragScrollOffsetY = 0
            activeDragRowFrames = [:]
            activeDropTarget = nil
            isCommittingDrop = false
        }
    }

    private func animateIfAllowed(
        _ animation: Animation,
        changes: () -> Void
    ) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(animation, changes)
        }
    }

    private func commandNumberTargets(snapshot: SnipListSnapshot) -> [CommandNumberTarget] {
        let snipIDs = snapshot.groups.count > 1
            ? snapshot.orderedVisibleIDs
            : displayedSnips(in: snapshot).map(\.id)
        return snipIDs.map(CommandNumberTarget.snip)
            + clipboardEntries.map { .clipboardEntry($0.id) }
    }

    private func displayedSnips(in snapshot: SnipListSnapshot) -> [Snip] {
        guard snapshot.groups.count == 1, let group = snapshot.groups.first else {
            return snapshot.groups.flatMap(\.snips)
        }
        return orderedSnips(in: group)
    }

    private func orderedSnips(in group: SnipListGroup) -> [Snip] {
        guard let pendingOrder = pendingOrderByList[group.listID],
              Set(pendingOrder) == Set(group.snips.map(\.id)) else {
            return group.snips
        }
        let snipsByID = Dictionary(uniqueKeysWithValues: group.snips.map { ($0.id, $0) })
        return pendingOrder.compactMap { snipsByID[$0] }
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
            .onKeyPress(phases: .down) { press in
                commandNumberPicker.handleKeyPress(press)
            }
    }

    private func snipCard(_ snip: Snip) -> some View {
        SnipCardRow(
            snip: snip,
            isRecovered: model.isRecoveredSnip(snip.id),
            isSelected: (contextMenuSelection ?? model.selection).contains(snip.id),
            isEditing: model.editingID == snip.id,
            commandNumber: commandNumberPicker.displayedNumber(for: .snip(snip.id)),
            onPickCommandNumber: { commandNumberPicker.pick(.snip(snip.id)) },
            editAttachments: editAttachmentsBinding(for: snip),
            isSaving: savingBinding(for: snip),
            attachmentURL: model.attachmentURL,
            onPreviewSavedAttachments: previewSavedAttachments,
            onPreviewLocalAttachments: onPreviewAttachments,
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
                model.editingID = nil
                focusedTarget = .list
                return true
            },
            onEditError: { model.presentedError = $0 }
        )
        .overlay {
            PanelCardInteractionRegion(
                controller: cardInteractionController,
                id: snip.id,
                contextMenu: model.editingID == snip.id ? nil : PanelCardContextMenu(
                    makeMenu: { makeContextMenu(for: snip.id) },
                    onOpen: {
                        contextMenuSelection = contextSelection(for: snip.id)
                    },
                    onClose: { contextMenuSelection = nil }
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityAddTraits(model.selection.contains(snip.id) ? .isSelected : [])
        .accessibilityAction(named: "Select") {
            selectExclusively(snip.id)
        }
        .accessibilityAction(named: SnipCommand.copy.title) {
            snipCommands.perform(.copy, on: [snip.id])
        }
        .accessibilityAction(named: SnipCommand.edit.title) {
            edit(snip.id)
        }
        .accessibilityAction(
            named: SnipCommand.toggleDone.title(allSelectedAreDone: snip.isDone)
        ) {
            model.toggleDone(id: snip.id)
        }
        .accessibilityAction(named: "Move Up") {
            let ids = contextSelection(for: snip.id)
            Task { await model.moveSelectionNow(by: -1, ids: ids) }
        }
        .accessibilityAction(named: "Move Down") {
            let ids = contextSelection(for: snip.id)
            Task { await model.moveSelectionNow(by: 1, ids: ids) }
        }
        .accessibilityAction(named: SnipCommand.delete.title) {
            snipCommands.perform(.delete, on: [snip.id])
        }
    }

    private func previewSavedAttachments(
        _ attachments: [SnipAttachment],
        selected: SnipAttachment
    ) {
        Task { @MainActor in
            do {
                guard let preview = try await model.prepareAttachmentPreview(
                    attachments,
                    selected: selected
                ) else { return }
                onPreviewAttachments(preview.urls, preview.selectedURL)
            } catch {
                model.presentedError = error.localizedDescription
            }
        }
    }

    private func editAttachmentsBinding(for snip: Snip) -> Binding<[URL]> {
        Binding(
            get: {
                guard let editSession, editSession.snipID == snip.id else {
                    return snip.attachments.compactMap(model.attachmentURL)
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
                    attachments = snip.attachments.compactMap(model.attachmentURL)
                }
                editSession = InlineEditSession(
                    snipID: snip.id,
                    attachments: attachments,
                    isSaving: isSaving
                )
            }
        )
    }

    private func select(_ id: UUID) {
        model.selectSnip(id, modifiers: selectionModifiers(for: id))
        focusedTarget = .list
    }

    private func edit(_ id: UUID) {
        focusedTarget = nil
        Task { @MainActor in
            let opened = await model.beginEditing(id)
            if !opened { focusedTarget = .list }
        }
    }

    private func selectExclusively(_ id: UUID) {
        guard orderedSnipIDs.contains(id) else { return }
        model.applySelection(
            SnipSelection.Update(selection: [id], anchor: id, focus: id)
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
            anchor: model.selectionState.anchor,
            focus: model.selectionState.focus,
            extending: extending
        )
        guard update != model.selectionState else { return .handled }
        model.applySelection(update)
        if let focus = update.focus {
            proxy.scrollTo(focus, anchor: .center)
        }
        return .handled
    }

    private func selectionModifiers(for id: UUID) -> SnipSelection.Modifiers {
        let flags = cardInteractionController.clickModifiers(for: id)
        var modifiers: SnipSelection.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    private func selectAllVisible() {
        model.selectAllVisible()
        focusedTarget = .list
    }

    private func contextSelection(for id: UUID) -> Set<UUID> {
        model.selection.contains(id) ? model.selection : [id]
    }

    private func makeContextMenu(for id: UUID) -> NSMenu {
        makeSelectionMenu(for: contextSelection(for: id))
    }

    private func makeSelectionMenu(for ids: Set<UUID>) -> NSMenu {
        let menu = NSMenu()
        guard !ids.isEmpty else { return menu }

        menu.addPanelAction(SnipCommand.copy.title, systemImage: "doc.on.doc") { perform(.copy, on: ids) }
        menu.addItem(.separator())
        let selectedSnips = model.snips.filter { ids.contains($0.id) }
        if ids.count == 1 {
            menu.addPanelAction(SnipCommand.edit.title, systemImage: "pencil") { perform(.edit, on: ids) }
        }
        if SnipCommand.merge.isAvailable(for: ids.count) {
            menu.addPanelAction(SnipCommand.merge.title, systemImage: "arrow.triangle.merge") { perform(.merge, on: ids) }
        }
        if selectedSnips.contains(where: { !$0.isDone }) {
            menu.addPanelAction(SnipCompletionLanguage.menuActionTitle(isDone: false), systemImage: "checkmark") {
                model.setDone(true, ids: ids)
            }
        }
        if selectedSnips.contains(where: \.isDone) {
            menu.addPanelAction(SnipCompletionLanguage.menuActionTitle(isDone: true), systemImage: "arrow.uturn.backward") {
                model.setDone(false, ids: ids)
            }
        }
        menu.addItem(.separator())
        menu.addPanelSubmenu(String(localized: "Move to List"), systemImage: "folder") { submenu in
            let destinations = model.lists.filter { list in
                !selectedSnips.allSatisfy { $0.listID == list.id }
            }
            for list in destinations {
                submenu.addPanelAction(list.displayName, systemImage: "folder") {
                    let orderedIDs = model.snips.filter { ids.contains($0.id) }.map(\.id)
                    Task { _ = await model.moveToList(ids: orderedIDs, listID: list.id) }
                }
            }
            if !destinations.isEmpty { submenu.addItem(.separator()) }
            submenu.addPanelAction(String(localized: "New List…"), systemImage: "folder.badge.plus") {
                moveSelectionToNewList(ids)
            }
        }
        menu.addItem(.separator())
        menu.addPanelAction(SnipCommand.delete.title, systemImage: "trash", isDestructive: true) {
            perform(.delete, on: ids)
        }

        return menu
    }

    private func perform(_ command: SnipCommand, on ids: Set<UUID>) {
        if command == .edit {
            focusedTarget = nil
        }
        snipCommands.perform(command, on: ids)
    }

}

private extension View {
    func panelListRowLayout() -> some View {
        padding(PanelListMetrics.rowInsets)
            .padding(.bottom, PanelListMetrics.rowSpacing)
    }
}
