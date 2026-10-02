import QuickLook
import SnipSnapCore
import SwiftUI
import UIKit

enum SnipCollectionLayout: Equatable {
    case compactStack
    case inlineList
}

struct SnipCollectionView: View {
    let model: IOSAppModel
    let clipboard: IOSClipboardModel
    let copyShare: IOSCopyShareCoordinator
    @Binding var sheet: AppSheet?
    let layout: SnipCollectionLayout
    var listID: UUID? = nil
    var isActivePage = true
    @Binding var editMode: EditMode
    let cancelNewList: (UUID) async -> Bool
    var blocksPageSwipe: Binding<Bool> = .constant(false)
    var selectionDockFrameChanged: (CGRect) -> Void = { _ in }
    var dismissComposerKeyboard: () -> Void = {}
    var libraryActions: LibraryActionsMenu?
    @State private var isReordering = false
    private var inlineEditDraft: SnipEditorDraft? { model.snipEditorDraft }
    @State private var previewURLs: [URL] = []
    @State private var selectedPreviewURL: URL?
    // Geometry is sampled by actions, so scrolling should not invalidate the collection.
    @State private var gatheringFrames = GatheringFrames()
    @State private var gatheringFlights: [GatheringFlight] = []
    @State private var departingRows: [UUID: UUID] = [:]
    @State private var gatheringPageFrame = CGRect.zero
    @FocusState private var isInlineEditorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var displayedListID: UUID { listID ?? model.selectedListID }
    private var displayedList: SnipList {
        model.lists.first(where: { $0.id == displayedListID }) ?? .inbox
    }
    private var displayedSnips: [Snip] { model.visibleSnips(in: displayedListID) }
    private var remainingSnips: [Snip] {
        isSelecting ? displayedSnips.filter {
            !model.selectedSnipIDs.contains($0.id) || departingRows[$0.id] != nil
        } : displayedSnips
    }
    private var isEditingList: Bool {
        model.editingListID == displayedListID
    }
    private var showsListEditor: Bool { isEditingList && !model.isSearchPresented }

    var body: some View {
        Group {
            if model.isSearchPresented {
                LibrarySearchView(model: model, clipboard: clipboard, copyShare: copyShare)
            } else if displayedSnips.isEmpty {
                if layout == .compactStack {
                    compactEmptyState
                } else {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: emptySystemImage,
                        description: Text(emptyDescription)
                    )
                    .accessibilityIdentifier("empty-snips")
                }
            } else {
                List {
                    ForEach(model.recoverySnapshot.pendingSnips.filter { recovery in
                        recovery.recovered.listID == displayedListID
                            && !model.snips.contains { $0.id == recovery.id }
                    }) { recovery in
                        Button {
                            sheet = .recoverSnip(id: recovery.id)
                        } label: {
                            RecoveredSnipRow(recovery: recovery)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("recovered-snip-\(recovery.id)")
                    }
                    ForEach(remainingSnips) { snip in
                        let departure = departingRows[snip.id]
                        Group {
                            if isSelecting {
                                Button {
                                    gather(snip)
                                } label: {
                                    SnipRow(
                                        snip: snip,
                                        model: model,
                                        isRecovered: model.isRecoveredSnip(snip.id),
                                        isGathering: true,
                                        sourceFrameChanged: { gatheringFrames.rows[snip.id] = $0 }
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(model.isPerformingGatheredAction || departingRows[snip.id] != nil)
                                .accessibilityHint("Select this item.")
                                .accessibilityIdentifier("snip-\(snip.id)")
                            } else {
                                if let draft = inlineEditDraft, draft.original.id == snip.id {
                                    InlineSnipEditor(
                                        draft: draft,
                                        model: model,
                                        isFocused: $isInlineEditorFocused
                                    )
                                } else {
                                    SnipRow(
                                        snip: snip,
                                        model: model,
                                        isRecovered: model.isRecoveredSnip(snip.id),
                                        isReordering: isReordering,
                                        sourceFrameChanged: { gatheringFrames.rows[snip.id] = $0 },
                                        onPreviewAttachment: previewAttachment,
                                        onCopy: { Task { await copyShare.copy(snips: [snip], model: model) } },
                                        onToggleDone: {
                                            await copyShare.toggleDone(snip: snip, model: model)
                                        }
                                    )
                                    .contentShape(Rectangle())
                                    .highPriorityGesture(
                                        TapGesture(count: 2).onEnded {
                                            beginEditing(snip)
                                        }
                                    )
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityHint("Double tap to edit. Touch and hold for actions.")
                                    .accessibilityAction {
                                        beginEditing(snip)
                                    }
                                    .accessibilityAction(named: "Edit") {
                                        beginEditing(snip)
                                    }
                                    .accessibilityAction(named: Text(snip.isPinned ? "Unpin" : "Pin")) {
                                        Task { await model.togglePinned(id: snip.id) }
                                    }
                                    .accessibilityAction(named: "Delete") {
                                        Task { await model.deleteSnip(id: snip.id) }
                                    }
                                    .accessibilityActions {
                                        if snip.isPinned {
                                            Button("Copy") {
                                                Task { await copyShare.copy(snips: [snip], model: model) }
                                            }
                                        } else {
                                            Button(SnipCompletionLanguage.actionTitle(isDone: snip.isDone)) {
                                                Task { await copyShare.toggleDone(snip: snip, model: model) }
                                            }
                                        }
                                    }
                                    .accessibilityIdentifier("snip-\(snip.id)")
                                }
                            }
                        }
                        .modifier(SelectionSourceVisibility(
                            opacity: model.selectedSnipIDs.contains(snip.id) ? 0 : 1,
                            completed: {
                                guard let departure else { return }
                                finishDeparture(of: snip.id, departure: departure)
                            }
                        ))
                        .animation(reduceMotion ? nil : .linear(duration: 0.06), value: model.selectedSnipIDs.contains(snip.id))
                        .accessibilityHidden(model.selectedSnipIDs.contains(snip.id))
                        .transition(isSelecting ? .identity : .opacity)
                        .tag(snip.id)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            if inlineEditDraft == nil { itemContextActions(for: snip) }
                        }
                        .moveDisabled(isSelecting || snip.isPinned || !model.canReorderVisibleSnips || inlineEditDraft != nil)
                    }
                    .onMove(perform: move)
                }
                .listStyle(.plain)
                .environment(\.editMode, .constant(isReordering ? .active : .inactive))
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    if isSelecting && remainingSnips.isEmpty {
                        ContentUnavailableView("All items selected", systemImage: "square.stack", description: Text("Move selected items to a list, or cancel to deselect them."))
                            .accessibilityIdentifier("all-snips-gathered")
                    }
                }
            }
        }
        .disabled(model.isPerformingGatheredAction)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting && isActivePage && !model.isSearchPresented {
                GatheredSnipsDock(
                    model: model,
                    copyShare: copyShare,
                    isPerformingAction: model.isPerformingGatheredAction,
                    move: moveGatheredSnips,
                    delete: deleteGatheredSnips,
                    performAction: { action in performGatheredAction(action) },
                    cancel: endSelection,
                    previewAttachment: previewAttachment,
                    containerFrame: gatheringPageFrame,
                    arrivingSnipIDs: Set(gatheringFlights.map { $0.snip.id }),
                    settleArrivals: {
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { gatheringFlights = [] }
                    },
                    cardFramesChanged: { frames in
                        for index in gatheringFlights.indices {
                            if let frame = frames[gatheringFlights[index].snip.id],
                               gatheringFlights[index].destination != frame {
                                gatheringFlights[index].destination = frame
                            }
                        }
                    }
                )
                .transaction { transaction in
                    if !gatheringFlights.isEmpty {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    selectionDockFrameChanged($0)
                }
            }
        }
        .modifier(ListEditorRecession(isActive: showsListEditor))
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onChanged { value in
                guard value.translation.height > 8,
                      abs(value.translation.height) > abs(value.translation.width)
                else { return }
                dismissComposerKeyboard()
            }
        )
        .attachmentPreview($selectedPreviewURL, in: previewURLs)
        .modifier(CollectionScreenPresentation(
            title: isEditingList ? "" : displayedList.name,
            titleColor: displayedList.accent.color,
            showsControls: !model.isSearchPresented,
            recedesControls: showsListEditor,
            trailingControls: collectionToolbar
        ))
        .overlay(alignment: .top) {
            if isEditingList {
                InlineListEditor(model: model, list: displayedList, cancelNewList: cancelNewList)
                    .id(displayedListID)
                    .frame(height: model.isSearchPresented ? 0 : nil)
                    .opacity(model.isSearchPresented ? 0 : 1)
                    .allowsHitTesting(!model.isSearchPresented)
                    .accessibilityHidden(model.isSearchPresented)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? nil : ListEditorPresentation.animation(reduceMotion: false, isPresented: showsListEditor),
            value: showsListEditor
        )
        .overlay {
            GeometryReader { geometry in
                ForEach(gatheringFlights) { flight in
                    GatheringFlightView(
                        flight: flight, model: model, origin: geometry.frame(in: .global).origin
                    ) {
                        // Exchange the flying copy and destination in one render update.
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            gatheringFlights.removeAll { $0.id == flight.id }
                        }
                    }
                    .transition(.identity)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGRect.self) { geometry in
            let frame = geometry.frame(in: .global)
            // The navigation bar overlays this frame; the tray needs the usable height.
            let topInset = geometry.safeAreaInsets.top
            return CGRect(x: frame.minX, y: frame.minY + topInset,
                          width: frame.width, height: max(0, frame.height - topInset))
        } action: {
            gatheringPageFrame = $0
        }
        .onChange(of: model.selectedSnipIDs) { _, selectedIDs in
            gatheringFlights.removeAll { !selectedIDs.contains($0.snip.id) }
            departingRows = departingRows.filter { selectedIDs.contains($0.key) }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                gatheringFlights = []
                departingRows = [:]
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                gatheringFlights = []
                departingRows = [:]
            }
        }
        .onChange(of: model.editingListID) { _, id in
            if isActivePage && id != nil {
                model.isSearchPresented = false
                dismissComposerKeyboard()
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: isActivePage) { _, isActive in
            if !isActive {
                isInlineEditorFocused = false
                gatheringFlights = []
                departingRows = [:]
            }
        }
        .onChange(of: isReordering || inlineEditDraft != nil, initial: true) { _, blocked in
            blocksPageSwipe.wrappedValue = blocked
        }
        .onAppear {
            blocksPageSwipe.wrappedValue = isReordering || inlineEditDraft != nil
        }
        .onDisappear {
            blocksPageSwipe.wrappedValue = false
            gatheringFlights = []
            departingRows = [:]
        }
        .onChange(of: model.selectedListID) {
            guard isActivePage else { return }
            isReordering = false
            isInlineEditorFocused = false
            gatheringFlights = []
            departingRows = [:]
            gatheringFrames.rows = [:]
            // The persistent dock can retain its frame without another geometry callback.
        }
        .onChange(of: model.completionFilter) {
            model.haptics.invalidatePendingFeedback()
        }
        .onChange(of: editMode) { _, mode in
            guard isActivePage else { return }
            model.haptics.invalidatePendingFeedback()
            if !mode.isEditing {
                if model.isSelectingSnips || !model.selectedSnipIDs.isEmpty { model.endSelectingSnips() }
                gatheringFlights = []
                departingRows = [:]
            }
            if mode.isEditing {
                guard inlineEditDraft == nil else {
                    editMode = .inactive
                    return
                }
                isReordering = false
                model.selectedSnipID = nil
            }
        }
        .onChange(of: model.searchText) { model.haptics.invalidatePendingFeedback() }
        .onChange(of: model.isSearchPresented) { _, isPresented in
            model.haptics.invalidatePendingFeedback()
            if isPresented {
                isReordering = false
                gatheringFlights = []
                departingRows = [:]
            }
        }
    }

    private var emptyTitle: String {
        if hasSearchQuery {
            return String(localized: "No results")
        }
        return model.completionFilter.emptyStateTitle
    }

    @ViewBuilder
    private var collectionToolbar: some View {
        Group {
            if isReordering {
                Button("Done") {
                    model.haptics.invalidatePendingFeedback()
                    isReordering = false
                }
                .accessibilityIdentifier("finish-reordering")
            } else if isSelecting {
                WorkflowOptionsMenu(model: model)
            } else {
                WorkflowOptionsMenu(model: model) {
                    guard inlineEditDraft == nil else { return }
                    model.haptics.invalidatePendingFeedback()
                    dismissComposerKeyboard()
                    isReordering = true
                }
                .disabled(inlineEditDraft?.canDismiss == false)
            }
            if let libraryActions, !isReordering, !isSelecting {
                libraryActions
            }
        }
        .disabled(model.isPerformingGatheredAction)
    }

    private var hasSearchQuery: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptySystemImage: String {
        hasSearchQuery ? "magnifyingglass" : "text.page"
    }

    private var emptyDescription: String {
        if hasSearchQuery {
            return String(localized: "Try a different search.")
        }
        return model.completionFilter == .all
            ? String(localized: "Type or paste text below.")
            : String(localized: "Change the filter to see other snips.")
    }

    private var compactEmptyState: some View {
        CollectionEmptyState(title: emptyTitle, systemImage: emptySystemImage, detail: emptyDescription)
            .accessibilityIdentifier("empty-snips")
    }

    private func beginEditing(_ snip: Snip) {
        guard model.beginInlineSnipEdit(snip) else { return }
        dismissComposerKeyboard()
        isReordering = false
        if isSelecting { endSelection() }
        Task { @MainActor in
            await Task.yield()
            guard inlineEditDraft?.original.id == snip.id else { return }
            isInlineEditorFocused = true
        }
    }

    private func previewAttachment(_ attachment: SnipAttachment) {
        model.haptics.invalidatePendingFeedback()
        Task { @MainActor in
            guard let url = await model.prepareAttachment(attachment.id, for: .preview) else {
                return
            }
            previewURLs = [url]
            selectedPreviewURL = url
        }
    }

    @ViewBuilder
    private func itemContextActions(for snip: Snip) -> some View {
        CopyShareActions(
            snips: [snip],
            model: model,
            coordinator: copyShare,
            identifierSuffix: "snip"
        )
        Divider()
        Button("Edit", systemImage: "pencil") {
            beginEditing(snip)
        }
        .accessibilityIdentifier("edit-snip")
        Button(snip.isPinned ? "Unpin" : "Pin", systemImage: snip.isPinned ? "pin.slash" : "pin") {
            Task { await model.togglePinned(id: snip.id) }
        }
        if !snip.isPinned {
        Button(
            SnipCompletionLanguage.menuActionTitle(isDone: snip.isDone),
            systemImage: snip.isDone ? "arrow.uturn.backward" : "checkmark"
        ) {
            Task { await copyShare.toggleDone(snip: snip, model: model) }
        }
        }
        Divider()
        Button("Select", systemImage: "square.stack") {
            guard inlineEditDraft == nil else { return }
            let sourceIsSelecting = isSelecting
            dismissComposerKeyboard()
            isReordering = false
            editMode = .active
            gather(snip, sourceIsSelecting: sourceIsSelecting)
        }
        .accessibilityIdentifier("select-snip")
        MoveSnipMenu(model: model, snip: snip)
        Divider()
        Button(role: .destructive) {
            Task { await model.deleteSnip(id: snip.id) }
        } label: {
            Label {
                Text("Delete")
            } icon: {
                Image(systemName: "trash")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red)
            }
        }
        .tint(.red)
        .accessibilityIdentifier("delete-context-snip")
    }

    private func move(from source: IndexSet, to destination: Int) {
        var orderedIDs = displayedSnips.map(\.id)
        orderedIDs.move(fromOffsets: source, toOffset: destination)
        Task { _ = await model.placeVisibleSnips(orderedIDs) }
    }

    private func endSelection() {
        gatheringFlights = []
        departingRows = [:]
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
            model.endSelectingSnips()
            editMode = .inactive
        }
    }

    private func gather(_ snip: Snip, sourceIsSelecting: Bool? = nil) {
        guard !model.isPerformingGatheredAction, !model.selectedSnipIDs.contains(snip.id) else { return }
        if !reduceMotion, let source = gatheringFrames.rows[snip.id], !source.isEmpty {
            let flight = GatheringFlight(
                snip: snip,
                source: source,
                sourceIsSelecting: sourceIsSelecting ?? isSelecting,
                destination: nil
            )
            // Hide the source before List snapshots its removal. The transfer covers
            // this brief fade; the transparent native cell can then close the gap.
            gatheringFlights.append(flight)
            departingRows[snip.id] = flight.id
            model.selectSnips(model.selectedSnipIDs.union([snip.id]))
        } else {
            model.selectSnips(model.selectedSnipIDs.union([snip.id]))
        }
    }

    private func finishDeparture(of id: UUID, departure: UUID) {
        guard departingRows[id] == departure else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            departingRows.removeValue(forKey: id)
        }
    }

    private func performGatheredAction(
        _ action: @escaping @MainActor () async -> Bool,
        requiresEmptySelection: Bool = false
    ) {
        guard !model.isPerformingGatheredAction, isActivePage, isSelecting,
              displayedListID == model.selectedListID, !model.selectedSnips.isEmpty else { return }
        model.isPerformingGatheredAction = true
        let sessionID = model.gatheringSessionID
        Task { @MainActor in
            defer { model.isPerformingGatheredAction = false }
            guard isSelecting, model.gatheringSessionID == sessionID else { return }
            if await action(), model.gatheringSessionID == sessionID,
               !requiresEmptySelection || model.selectedSnips.isEmpty {
                endSelection()
            }
        }
    }

    private func deleteGatheredSnips() {
        performGatheredAction({ await model.deleteSelection() }, requiresEmptySelection: true)
    }

    private func moveGatheredSnips(to listID: UUID) {
        guard model.moveDestinations(for: model.selectedSnips).contains(where: { $0.id == listID }) else { return }
        performGatheredAction({ await model.moveSelection(to: listID) }, requiresEmptySelection: true)
    }

    private var isSelecting: Bool {
        editMode.isEditing
    }

}

struct CollectionEmptyState: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3.weight(.regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct LibrarySearchView: View {
    let model: IOSAppModel
    let clipboard: IOSClipboardModel
    let copyShare: IOSCopyShareCoordinator
    @State private var previewURL: URL?
    private var inlineEditDraft: SnipEditorDraft? { model.snipEditorDraft }
    @FocusState private var isInlineEditorFocused: Bool

    var body: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = LibrarySearchResults(
            query: query,
            snips: model.snips,
            lists: model.lists,
            clipboard: clipboard.entries,
            sortMode: model.sortMode,
            sourceLabel: { $0.displaySourceLabel }
        )
        Group {
            if query.isEmpty {
                CollectionEmptyState(
                    title: String(localized: "Search"),
                    systemImage: "magnifyingglass",
                    detail: String(localized: "Search every list and Clipboard.")
                )
                .accessibilityIdentifier("search-prompt")
            } else if results.isEmpty {
                CollectionEmptyState(
                    title: String(localized: "No results"),
                    systemImage: "magnifyingglass",
                    detail: String(localized: "Try another search.")
                )
                .accessibilityIdentifier("empty-search")
            } else {
                List {
                    ForEach(results.lists) { group in
                        Section {
                            ForEach(group.snips) { snip in
                                snipResult(snip)
                            }
                        } header: {
                            Label(group.list.displayName, systemImage: group.list.displaySystemImage)
                                .foregroundStyle(group.list.accent.color)
                                .accessibilityIdentifier("search-section-\(group.list.id)")
                        }
                    }
                    if !results.clipboard.isEmpty {
                        Section {
                            ForEach(results.clipboard) { entry in
                                clipboardResult(entry)
                            }
                        } header: {
                            Label("Clipboard", systemImage: "clipboard")
                                .foregroundStyle(.primary)
                                .accessibilityIdentifier("search-section-clipboard")
                        }
                    }
                }
                .listStyle(.plain)
                .textCase(nil)
                .scrollDismissesKeyboard(.immediately)
                .accessibilityIdentifier("global-search-results")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .attachmentPreview($previewURL)
        .task { await clipboard.load() }
        .onDisappear { isInlineEditorFocused = false }
        .overlay(alignment: .bottom) {
            if clipboard.copied {
                Label("Copied", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        clipboard.copied = false
                    }
            }
        }
    }

    private func snipResult(_ snip: Snip) -> some View {
        Group {
            if let draft = inlineEditDraft, draft.original.id == snip.id {
                InlineSnipEditor(
                    draft: draft,
                    model: model,
                    isFocused: $isInlineEditorFocused
                )
            } else {
                IOSItemRow {
                    SnipCopyControl(appearance: listAppearance(for: snip, in: model.lists), isPinned: snip.isPinned) {
                        Task { await copyShare.copy(snips: [snip], model: model) }
                    }
                    .accessibilityLabel(snip.isPinned ? "Copy Pinned Snip" : "Copy Snip")
                    .accessibilityIdentifier("copy-search-snip-\(snip.id)")
                } content: {
                    SnipContentView(
                        snip: snip,
                        model: model,
                        isRecovered: model.isRecoveredSnip(snip.id),
                        allowsTextExpansion: true,
                        onPreviewAttachment: { attachment in
                            Task { previewURL = await model.prepareAttachment(attachment.id, for: .preview) }
                        },
                        showsPin: false
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(SnipContentView.accessibilityLabel(for: snip))
                    .accessibilityValue(snip.isPinned ? String(localized: "Pinned") : SnipCompletionLanguage.stateTitle(isDone: snip.isDone))
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        TapGesture(count: 2).onEnded { beginEditing(snip) }
                    )
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Double tap to edit. Touch and hold for actions.")
                    .accessibilityAction { beginEditing(snip) }
                    .accessibilityIdentifier("search-snip-\(snip.id)")
                }
            }
        }
        .listRowSeparator(.hidden)
        .contextMenu {
            if inlineEditDraft == nil {
                Button("Edit", systemImage: "pencil") { beginEditing(snip) }
                    .accessibilityIdentifier("edit-snip")
                Button("Copy", systemImage: "doc.on.doc") {
                    Task { await copyShare.copy(snips: [snip], model: model) }
                }
                MoveSnipMenu(model: model, snip: snip)
            }
        }
    }

    private func beginEditing(_ snip: Snip) {
        guard model.beginInlineSnipEdit(snip) else { return }
        Task { @MainActor in
            await Task.yield()
            guard inlineEditDraft?.original.id == snip.id else { return }
            isInlineEditorFocused = true
        }
    }

    private func clipboardResult(_ entry: ClipboardEntry) -> some View {
        ClipboardItemRow(entry: entry, model: clipboard) {
            copyShare.copyClipboardEntry(entry, clipboard: clipboard)
        }
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("search-clipboard-\(entry.id)")
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                copyShare.copyClipboardEntry(entry, clipboard: clipboard)
            }
            Button(entry.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                Task { await clipboard.togglePin(entry) }
            }
        }
    }

}

/// Transient measurements read by gathering actions, independent of rendered state.
private final class GatheringFrames {
    var rows: [UUID: CGRect] = [:]
}

/// Observe only the source fade, so unrelated transfer animations cannot delay
/// the native List closing its now-transparent cell.
nonisolated private struct SelectionSourceVisibility: AnimatableModifier {
    var opacity: Double
    let completed: @MainActor @Sendable () -> Void

    var animatableData: Double {
        get { opacity }
        set {
            opacity = newValue
            if newValue == 0 {
                let completed = completed
                Task { @MainActor in completed() }
            }
        }
    }

    @MainActor func body(content: Content) -> some View {
        content.opacity(opacity)
    }
}
