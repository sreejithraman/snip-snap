import QuickLook
import SnipSnapCore
import SwiftUI
import UniformTypeIdentifiers

private enum FileImportTarget {
    case composer(UUID)
    case edit(UUID)
}

struct PendingEditAttachmentImport: Identifiable {
    let id = UUID()
    let snipID: UUID
    let urls: [URL]
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme
    let coordinator: AppCoordinator
    @ObservedObject private var accessibilityPermissions: AccessibilityPermissionController
    @ObservedObject private var fileDropController: PanelFileDropController
    private let accountNoticeModel: AppleAccountNoticeModel?
    private let dragSessionController: PanelDragSessionController

    @State private var entryDrafts: [UUID: ComposerDraft] = [:]
    @State private var showingNewList = false
    @State private var newListMovingIDs: Set<UUID> = []
    @State private var showingFileImporter = false
    @State private var fileImportTarget: FileImportTarget?
    @State private var pendingEditAttachmentImport: PendingEditAttachmentImport?
    @State private var showingClearClipboard = false
    @State private var showingRecoveryReview = false
    @State private var inlineEntryHeights: [UUID: CGFloat] = [:]
    @State private var inlineEntryFieldHeights: [UUID: CGFloat] = [:]
    @State private var isSavingInlineEntry = false
    @State private var previewURLs: [URL] = []
    @State private var selectedPreviewURL: URL?
    @StateObject private var commandNumberPicker = CommandNumberPicker()
    @FocusState private var focusedTarget: PanelFocusTarget?

    init(
        coordinator: AppCoordinator,
        fileDropController: PanelFileDropController,
        dragSessionController: PanelDragSessionController,
        accountNoticeModel: AppleAccountNoticeModel? = nil
    ) {
        self.coordinator = coordinator
        self.accountNoticeModel = accountNoticeModel
        _accessibilityPermissions = ObservedObject(
            wrappedValue: coordinator.accessibilityPermissions
        )
        self.dragSessionController = dragSessionController
        _fileDropController = ObservedObject(wrappedValue: fileDropController)
    }

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            panelShell
        }
        .padding(AppWindowDefaults.effectGutter)
        .overlay(alignment: .topTrailing) {
            if let developmentBuild = DevelopmentBuildIdentity.current {
                DevelopmentBuildBadge(identity: developmentBuild)
                    .offset(
                        x: DevelopmentBuildBadge.panelXOffset,
                        y: DevelopmentBuildBadge.panelYOffset
                    )
            }
        }
        .appToast(
            $model.toast,
            alignment: .top,
            edge: .top,
            onAction: model.performToastAction,
            onDismiss: model.dismissToast
        )
        .background {
            PanelDragRegion()
        }
        .tint(SnipSnapColors.controlTint)
        .preferredColorScheme(model.appearance.colorScheme)
        .quickLookPreview($selectedPreviewURL, in: previewURLs)
        .background {
            ClipboardAlertHost(
                history: model.clipboardHistory,
                showingClearConfirmation: $showingClearClipboard
            )
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                switch fileImportTarget {
                case .edit(let snipID) where snipID == model.editingID:
                    pendingEditAttachmentImport = PendingEditAttachmentImport(
                        snipID: snipID,
                        urls: urls
                    )
                case .composer(let listID):
                    model.addDraftAttachments(urls, to: listID)
                    cacheComposerDraft(for: listID)
                case .edit, .none:
                    break
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    model.presentError(error)
                }
            }
            fileImportTarget = nil
        }
        .onReceive(fileDropController.fileDrops) { urls in
            guard model.editingID == nil else { return }
            _ = attachDroppedFiles(urls)
        }
    }

    private var panelShell: some View {
        VStack(spacing: SnipSnapSpacing.relatedContent) {
            floatingHeader

            if let accountNoticeModel, accountNoticeModel.notice != nil {
                AppleAccountNoticeView(
                    model: accountNoticeModel,
                    accessibilityIdentifier: "apple-account-notice-main"
                )
            }

            if accessibilityPermissions.isSetupCardVisible {
                AccessibilitySetupCard(controller: accessibilityPermissions)
            }

            mainPanel

            SnipListTabBarView(
                model: model,
                dragSessionController: dragSessionController
            ) {
                newListMovingIDs = []
                showingNewList = true
            }
        }
        .panelControlBaseline()
        .background {
            PanelDragRegion()
        }
        .frame(
            minWidth: AppWindowDefaults.minimumContentSize.width,
            minHeight: AppWindowDefaults.minimumContentSize.height
        )
        .onAppear {
            cacheComposerDraft(for: model.activeListID)
            focusedTarget = .list
            commandNumberPicker.startMonitoring(onPick: pickCommandNumber)
            commandNumberPicker.setEnabled(hasCommandNumberFocus)
        }
        .onDisappear {
            commandNumberPicker.stopMonitoring()
        }
        .onChange(of: hasCommandNumberFocus, initial: true) { _, isEnabled in
            commandNumberPicker.setEnabled(isEnabled)
        }
        .onChange(of: model.activeListID) { _, listID in
            cacheComposerDraft(for: listID)
        }
        .onChange(of: model.isShowingClipboard) { _, _ in
            updatePanelComposerExpansion(for: inlineEntryHeight(for: model.activeListID))
        }
        .onReceive(coordinator.panelFocusRequests) { request in
            switch request {
            case .search:
                focusedTarget = .search
            case .inlineEntry:
                focusedTarget = .inlineEntry
            }
        }
        .focusedValue(
            \.snipCommandModel,
            hasSnipCommandFocus ? model : nil
        )
        .onChange(of: hasSnipCommandFocus, initial: true) { _, isActive in
            coordinator.setSnipCommandFocusActive(isActive)
        }
        .onExitCommand(perform: handleCancel)
        .sheet(
            isPresented: $showingNewList,
            onDismiss: {
                newListMovingIDs = []
                restoreListFocus()
            }
        ) {
            NewSnipListSheet(
                model: model,
                isPresented: $showingNewList,
                movingIDs: newListMovingIDs
            )
        }
        .sheet(isPresented: $showingRecoveryReview) {
            MacRecoveryReviewSheet(model: model)
        }
        .confirmationDialog(
            "Import this backup?",
            isPresented: Binding(
                get: { model.pendingImportPreview != nil },
                set: { if !$0 { model.cancelBackupImport() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Import Backup") {
                Task { await model.confirmBackupImport() }
            }
            Button("Cancel", role: .cancel) { model.cancelBackupImport() }
        } message: {
            Text("This backup contains \(model.importPreviewSummary). Snip Snap will merge this backup with your saved snips.")
        }
        .sheet(isPresented: $accessibilityPermissions.isRepairPresented) {
            AccessibilityRepairView(controller: accessibilityPermissions)
        }
        .alert(
            model.presentedErrorTitle ?? String(localized: "Something Went Wrong"),
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.dismissPresentedError() } }
            )
        ) {
            Button("OK") { model.dismissPresentedError() }
        } message: {
            Text(model.presentedError ?? "")
        }
    }

    private var mainPanel: some View {
        let shape = RoundedRectangle(
            cornerRadius: PanelShapeMetrics.paneCornerRadius,
            style: .continuous
        )
        return PanelTabPager(
            selectedPage: selectedPage,
            pages: PanelTabPage.ordered(lists: model.lists),
            animatesChanges: model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onSelectionChange: { commandNumberPicker.setOrderedTargets([]) }
        ) { page, isInteractive in
            tabPage(page, isInteractive: isInteractive)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                PanelFileDropRegion(
                    controller: fileDropController,
                    isEnabled: !model.isShowingClipboard
                )
            }
            .clipShape(shape)
            .panelGlassSurface(in: shape)
            .panelDropTargetState(
                in: shape,
                isTargeted: !model.isShowingClipboard && fileDropController.isTargeted
            )
            .overlay {
                PanelResizeSurface()
                    .accessibilityHidden(true)
            }
    }

    private var hasSnipCommandFocus: Bool {
        focusedTarget == .list && model.editingID == nil && controlActiveState == .key
    }

    private var selectedPage: PanelTabPage {
        model.isShowingClipboard ? .clipboard : .list(model.activeListID)
    }

    private var hasCommandNumberFocus: Bool {
        controlActiveState == .key && model.editingID == nil
    }

    private func pickCommandNumber(_ target: CommandNumberTarget) {
        switch target {
        case .snip(let id):
            guard let snip = model.snips.first(where: { $0.id == id }) else { return }
            _ = model.placeOnClipboard(.snips([snip]), feedback: .notify)
        case .clipboardEntry(let id):
            guard let entry = model.clipboardHistory.entry(id: id) else { return }
            _ = model.placeOnClipboard(.clipboardEntry(entry), feedback: .notify)
        }
    }

    private var floatingHeader: some View {
        HStack(spacing: SnipSnapSpacing.relatedContent) {
            HStack(spacing: SnipSnapSpacing.relatedContent) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SnipSnapColors.textSecondary)
                    .accessibilityHidden(true)
                searchField
            }
            .padding(.horizontal, SnipSnapSpacing.controlContentInset)
            .panelInputSurface()

            if model.needsAttentionCount > 0 {
                Button {
                    showingRecoveryReview = true
                } label: {
                    Label("Needs Attention (\(model.needsAttentionCount))", systemImage: "exclamationmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .help("Review recovered edits")
            }

            PanelMoreButton(
                model: model,
                accessibilityPermissions: accessibilityPermissions,
                focusedTarget: $focusedTarget,
                moveSelectionToNewList: {
                    newListMovingIDs = model.selection
                    showingNewList = true
                },
                selectAllVisible: selectAllVisible
            )
        }
        .background {
            PanelDragRegion()
        }
    }

    private var searchField: some View {
        TextField("Search", text: $model.query)
            .panelInputStyle()
            .focused($focusedTarget, equals: .search)
    }

    @ViewBuilder
    private func tabPage(_ page: PanelTabPage, isInteractive: Bool) -> some View {
        ZStack(alignment: .bottom) {
            pageContent(for: page, isInteractive: isInteractive)

            if case .list(let listID) = page {
                inlineEntry(for: listID, isInteractive: isInteractive)
                    .padding(PanelControlMetrics.inlineEntryInset)
                    .background {
                        ZStack {
                            PanelDragRegion()
                            PanelDragBlockingRegion(
                                controller: dragSessionController
                            )
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        cacheInlineEntryHeight(
                            height,
                            for: listID,
                            updatePanel: isInteractive
                        )
                    }
                    .onChange(of: isInteractive, initial: true) { _, isInteractive in
                        guard isInteractive, page == selectedPage else { return }
                        updatePanelComposerExpansion(for: inlineEntryHeight(for: listID))
                    }
                    .zIndex(1)
            }
        }
    }

    @ViewBuilder
    private func pageContent(
        for page: PanelTabPage,
        isInteractive: Bool
    ) -> some View {
        if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            globalSearchResults(for: page, isInteractive: isInteractive)
        } else if case .clipboard = page {
            ClipboardListView(
                model: model,
                dragSessionController: dragSessionController,
                commandNumberPicker: commandNumberPicker,
                isInteractive: isInteractive,
                showingClearConfirmation: $showingClearClipboard,
                onPreviewAttachments: openAttachmentPreview
            )
        } else if case .list(let listID) = page {
            if model.filteredSnips(in: listID).isEmpty {
                ZStack {
                    savedSnipList(for: listID, isInteractive: isInteractive, ownsSharedEvents: page == selectedPage)
                    emptyState
                        .allowsHitTesting(false)
                }
            } else {
                savedSnipList(for: listID, isInteractive: isInteractive, ownsSharedEvents: page == selectedPage)
            }
        }
    }

    @ViewBuilder
    private func globalSearchResults(
        for page: PanelTabPage,
        isInteractive: Bool
    ) -> some View {
        if model.filteredSnips.isEmpty && model.clipboardSearchMatches.isEmpty {
            emptyState
        } else {
            switch page {
            case .list(let listID):
                savedSnipList(for: listID, isInteractive: isInteractive, ownsSharedEvents: page == selectedPage)
            case .clipboard:
                savedSnipList(for: model.activeListID, isInteractive: isInteractive, ownsSharedEvents: page == selectedPage)
            }
        }
    }

    private func savedSnipList(
        for listID: UUID,
        isInteractive: Bool,
        ownsSharedEvents: Bool
    ) -> some View {
        SnipListView(
            model: model,
            displayedListID: listID,
            isInteractive: isInteractive,
            ownsSharedEvents: ownsSharedEvents,
            dragSessionController: dragSessionController,
            fileDropController: fileDropController,
            commandNumberPicker: commandNumberPicker,
            focusedTarget: $focusedTarget,
            moveSelectionToNewList: { ids in
                newListMovingIDs = ids
                showingNewList = true
            },
            requestFileImport: { snipID in
                fileImportTarget = .edit(snipID)
                showingFileImporter = true
            },
            pendingEditAttachmentImport: $pendingEditAttachmentImport,
            captureScreenAreaForEdit: captureScreenAreaForEdit,
            bottomContentInset: inlineEntryHeight(for: listID),
            clipboardEntries: model.clipboardSearchMatches,
            onPreviewAttachments: openAttachmentPreview,
            onRemovePreviewURL: removePreviewURL
        )
    }

    private var emptyState: some View {
        VStack(spacing: SnipSnapSpacing.relatedContent) {
            Spacer()
            Image(systemName: emptyStateIcon)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(SnipSnapColors.textTertiary)
            Text(emptyStateTitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SnipSnapColors.textSecondary)
            if model.query.isEmpty, model.completionFilter == .all {
                Text("\(shortcutSettings.configuration.captureSelection.displayName) captures the selection")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SnipSnapColors.textTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            PanelDragRegion()
        }
    }

    private var emptyStateIcon: String {
        if !model.query.isEmpty {
            return "magnifyingglass"
        }
        if model.completionFilter != .all {
            return "line.3.horizontal.decrease.circle"
        }
        return "tray"
    }

    private var emptyStateTitle: String {
        if !model.query.isEmpty {
            return String(localized: "No matches")
        }
        return model.completionFilter.emptyStateTitle
    }

    private func inlineEntry(for listID: UUID, isInteractive: Bool) -> some View {
        let draft = composerDraft(for: listID)
        let list = model.lists.first(where: { $0.id == listID }) ?? .inbox
        return HStack(alignment: .top, spacing: SnipSnapSpacing.relatedContent) {
            inlineAttachmentMenu(for: listID)

            GlassEffectContainer {
                VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
                    if !draft.attachments.isEmpty {
                        AttachmentPreviewStrip(
                            items: draftAttachmentPreviewItems(for: listID),
                            onPreview: { item in
                                guard let url = item.url else { return }
                                openAttachmentPreview(draft.attachments, selectedURL: url)
                            },
                            onRemove: { item in
                                guard let url = item.url else { return }
                                removePreviewURL(url)
                                model.removeDraftAttachment(url, from: listID)
                                cacheComposerDraft(for: listID)
                            }
                        )
                        .padding(.horizontal, SnipSnapSpacing.controlContentInset)
                        .padding(.top, PanelControlMetrics.expandedInputVerticalPadding)
                    }

                    HStack(
                        alignment: PanelComposerLayout.actionAlignment(
                            isExpanded: isInlineEntryExpanded(for: listID)
                        ),
                        spacing: SnipSnapSpacing.relatedContent
                    ) {
                        inlineEntryField(
                            for: listID,
                            list: list,
                            isInteractive: isInteractive
                        )
                        Color.clear
                            .frame(width: PanelControlMetrics.actionWidth, height: PanelControlMetrics.actionHeight)
                            .padding(.trailing, PanelControlMetrics.sendInset)
                            .allowsHitTesting(false)
                    }
                    .padding(.leading, SnipSnapSpacing.controlContentInset)
                    .padding(.top, inlineEntryTextTopPadding(for: listID))
                    .padding(.bottom, inlineEntryTextBottomPadding(for: listID))
                }
                .panelEmbeddedInputSurface(
                    minHeight: PanelControlMetrics.compactComposerHeight,
                    expanded: isInlineEntrySurfaceExpanded(for: listID)
                )
            }
            .overlay(alignment: .bottomTrailing) {
                GlassEffectContainer {
                    inlineSendButton(
                        for: listID,
                        list: list,
                        isInteractive: isInteractive
                    )
                        .padding(.trailing, PanelControlMetrics.sendInset)
                        .padding(
                            .bottom,
                            max(
                                inlineEntryTextBottomPadding(for: listID),
                                PanelControlMetrics.sendInset
                            )
                        )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.rect)
    }

    private func inlineAttachmentMenu(for listID: UUID) -> some View {
        Menu {
            Button("Choose Files…") {
                fileImportTarget = .composer(listID)
                showingFileImporter = true
            }
            Button("Capture Screen Area…") { captureScreenArea(for: listID) }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(
                    width: PanelControlMetrics.floatingIconLength,
                    height: PanelControlMetrics.floatingIconLength
                )
                .panelStandaloneActionControl()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Add Attachment")
        .accessibilityLabel("Add Attachment")
    }

    private func inlineEntryField(
        for listID: UUID,
        list: SnipList,
        isInteractive: Bool
    ) -> some View {
        PanelMultilineTextInput(
            "Add to \(list.displayName)…",
            text: entryText(for: listID),
            lineRange: PanelComposerMetrics.textLineRange,
            lineSpacing: PanelComposerMetrics.textLineSpacing,
            isFocused: isInteractive && focusedTarget == .inlineEntry,
            onFocusChange: { isFocused in
                guard isInteractive, selectedPage == .list(listID) else { return }
                if isFocused {
                    focusedTarget = .inlineEntry
                } else if focusedTarget == .inlineEntry {
                    focusedTarget = nil
                }
            },
            onPasteImages: { pasteImagesIntoComposer($0, for: listID) },
            onPasteLargeText: { pasteLargeTextIntoComposer($0, for: listID) },
            onSubmit: { saveInlineEntry(for: listID) }
        )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                guard PanelGeometryChange.shouldApply(
                    current: inlineEntryFieldHeights[listID] ?? 0,
                    proposed: height
                ) else { return }
                inlineEntryFieldHeights[listID] = height
            }
    }

    private func entryText(for listID: UUID) -> Binding<String> {
        Binding(
            get: { composerDraft(for: listID).text },
            set: { value in
                let draft = composerDraft(for: listID)
                if let pasted = LargePastedText.largeInsertion(
                    from: draft.text,
                    to: value
                ) {
                    pasteLargeTextIntoComposer(pasted, for: listID)
                    return
                }
                entryDrafts[listID] = ComposerDraft(
                    text: value,
                    attachments: draft.attachments
                )
                model.saveComposerText(value, for: listID)
            }
        )
    }

    private func inlineSendButton(
        for listID: UUID,
        list: SnipList,
        isInteractive: Bool
    ) -> some View {
        PanelGlassActionButton(
            systemImage: "arrow.up",
            isEnabled: isInteractive && canSaveInlineEntry(for: listID),
            tint: list.accent.color.opacity(SnipSnapTheme.listGlassTintOpacity),
            labelColor: list.accent.sendIconColor(in: model.appearance.colorScheme ?? colorScheme),
            action: { saveInlineEntry(for: listID) }
        )
        .accessibilityLabel("Add to \(list.displayName)")
        .accessibilityIdentifier("composer-send")
        .help("Add to \(list.displayName)")
    }

    private func isInlineEntryExpanded(for listID: UUID) -> Bool {
        PanelComposerLayout.isExpanded(fieldHeight: inlineEntryFieldHeights[listID] ?? 0)
    }

    private func inlineEntryHeight(for listID: UUID) -> CGFloat {
        PanelComposerHeightCache.height(for: listID, in: inlineEntryHeights)
    }

    private func cacheInlineEntryHeight(
        _ height: CGFloat,
        for listID: UUID,
        updatePanel: Bool
    ) {
        guard PanelComposerHeightCache.update(
            height,
            for: listID,
            in: &inlineEntryHeights
        ) else { return }
        let height = inlineEntryHeight(for: listID)
        guard updatePanel, selectedPage == .list(listID) else { return }
        updatePanelComposerExpansion(for: height)
    }

    private func isInlineEntrySurfaceExpanded(for listID: UUID) -> Bool {
        isInlineEntryExpanded(for: listID) || !composerDraft(for: listID).attachments.isEmpty
    }

    private func inlineEntryTextTopPadding(for listID: UUID) -> CGFloat {
        isInlineEntryExpanded(for: listID) && composerDraft(for: listID).attachments.isEmpty
            ? PanelControlMetrics.expandedInputVerticalPadding
            : 0
    }

    private func inlineEntryTextBottomPadding(for listID: UUID) -> CGFloat {
        isInlineEntrySurfaceExpanded(for: listID)
            ? PanelControlMetrics.expandedInputVerticalPadding
            : 0
    }

    private func canSaveInlineEntry(for listID: UUID) -> Bool {
        let draft = composerDraft(for: listID)
        return !isSavingInlineEntry
            && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draft.attachments.isEmpty)
    }

    private func draftAttachmentPreviewItems(for listID: UUID) -> [AttachmentPreviewItem] {
        composerDraft(for: listID).attachments.map(AttachmentPreviewItem.init(url:))
    }

    private func composerDraft(for listID: UUID) -> ComposerDraft {
        entryDrafts[listID] ?? model.composerDraft(for: listID)
    }

    private func cacheComposerDraft(for listID: UUID) {
        entryDrafts[listID] = model.composerDraft(for: listID)
    }

    private func openAttachmentPreview(_ urls: [URL], selectedURL: URL) {
        previewURLs = urls
        selectedPreviewURL = selectedURL
    }

    private func removePreviewURL(_ url: URL) {
        if selectedPreviewURL == url {
            selectedPreviewURL = nil
        }
        previewURLs.removeAll { $0 == url }
    }

    private func attachDroppedFiles(_ urls: [URL]) -> Bool {
        guard !model.isShowingClipboard else { return false }
        let files = PanelFileDropValidation.existingFiles(in: urls)
        guard !files.isEmpty else { return false }

        let listID = model.activeListID
        model.addDraftAttachments(files, to: listID)
        cacheComposerDraft(for: listID)
        focusedTarget = .inlineEntry
        return true
    }

    @MainActor
    private func pasteLargeTextIntoComposer(_ text: String, for listID: UUID) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try LargePastedText.write(text) }
            }.value
            switch result {
            case .success(let url):
                model.addTemporaryDraftAttachment(url, to: listID)
                cacheComposerDraft(for: listID)
            case .failure:
                model.presentError(String(
                    localized: "Couldn’t prepare pasted text. Try again."
                ))
            }
        }
    }

    @MainActor
    private func pasteImagesIntoComposer(_ images: [PanelPastedImage], for listID: UUID) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                PanelPastedImageStaging.write(images)
            }.value
            switch result {
            case .success(let urls):
                for url in urls {
                    model.addTemporaryDraftAttachment(url, to: listID)
                }
                cacheComposerDraft(for: listID)
            case .failure(let error):
                model.presentError(error)
            }
        }
    }

    private func updatePanelComposerExpansion(for height: CGFloat) {
        let expansion = model.isShowingClipboard
            ? 0
            : max(height - PanelControlMetrics.inlineEntryBaseHeight, 0)
        coordinator.updatePanelComposerExpansion(expansion)
    }

    private func saveInlineEntry(for listID: UUID) {
        let text = composerDraft(for: listID).text
        guard canSaveInlineEntry(for: listID) else { return }
        isSavingInlineEntry = true
        Task {
            defer { isSavingInlineEntry = false }
            let saved = await model.saveComposerDraft(content: text, listID: listID)
            guard saved else {
                if model.activeListID == listID { focusedTarget = .inlineEntry }
                return
            }
            cacheComposerDraft(for: listID)
            if model.activeListID == listID {
                focusedTarget = .inlineEntry
            }
        }
    }

    private func captureScreenArea(for listID: UUID) {
        let url = model.stageScreenCapture()
        runScreenCapture(to: url) { succeeded in
            model.finishScreenCapture(url, in: listID, succeeded: succeeded)
            if succeeded { cacheComposerDraft(for: listID) }
        }
    }

    private func captureScreenAreaForEdit(
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip Snap Capture \(UUID().uuidString).png")
        runScreenCapture(to: url) { succeeded in
            guard succeeded else {
                try? FileManager.default.removeItem(at: url)
                completion(nil)
                return
            }
            completion(url)
        }
    }

    private func runScreenCapture(
        to url: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", url.path]
        process.terminationHandler = { process in
            Task { @MainActor in
                let succeeded = process.terminationStatus == 0
                    && FileManager.default.fileExists(atPath: url.path)
                completion(succeeded)
            }
        }
        do { try process.run() } catch {
            completion(false)
            model.presentError(String(localized: "Couldn’t start screen capture. Try again."))
        }
    }

    private func selectAllVisible() {
        model.selectAllVisible()
        focusedTarget = .list
    }

    private func restoreListFocus() {
        focusedTarget = .list
    }

    private func handleCancel() {
        if focusedTarget == .search {
            focusedTarget = .list
        } else if focusedTarget == .inlineEntry {
            let listID = model.activeListID
            let draft = composerDraft(for: listID)
            if draft.text.isEmpty && draft.attachments.isEmpty {
                coordinator.hidePanel()
            } else {
                entryDrafts[listID] = ComposerDraft()
                model.clearDraft(for: listID)
            }
        } else if !model.selection.isEmpty {
            model.selection = []
        } else {
            coordinator.hidePanel()
        }
    }

}

private struct AccessibilitySetupCard: View {
    @ObservedObject var controller: AccessibilityPermissionController

    var body: some View {
        let presentation = controller.setupCardState.presentation
        PanelContentCard {
            Image(systemName: "accessibility")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SnipSnapColors.textSecondary)
                .frame(width: 32, height: 32)
                .background(SnipSnapColors.compactSubduedFill, in: Circle())
                .accessibilityHidden(true)
        } main: {
            VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SnipSnapColors.textPrimary)

                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(SnipSnapColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: SnipSnapSpacing.relatedContent) {
                    Spacer(minLength: 0)
                    Button("Later") {
                        controller.deferSetup()
                    }
                    .buttonStyle(.borderless)

                    Button(presentation.primaryActionTitle) {
                        controller.performPrimaryAction()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }

}

private struct AccessibilityRepairView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: AccessibilityPermissionController

    var body: some View {
        let presentation = controller.setupCardState.presentation
        VStack(alignment: .leading, spacing: SnipSnapSpacing.paneContentInset) {
            Label("Accessibility Access Needed", systemImage: "accessibility")
                .font(.headline)

            Text(
                "Capture Selection and global Shift shortcuts need Accessibility access. You can keep using other parts of Snip Snap without it."
            )
            .foregroundStyle(SnipSnapColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if presentation.showsRepairInstructions {
                Text(AccessibilitySetupCardState.repairInstructions)
                .font(.caption)
                .foregroundStyle(SnipSnapColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: SnipSnapSpacing.relatedContent) {
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(presentation.primaryActionTitle) {
                    dismiss()
                    controller.performPrimaryAction()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(SnipSnapSpacing.paneContentInset)
        .frame(width: 380)
    }
}

private struct ClipboardAlertHost: View {
    @ObservedObject var history: ClipboardHistory
    @Binding var showingClearConfirmation: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .confirmationDialog(
                "Clear Clipboard History?",
                isPresented: $showingClearConfirmation
            ) {
                Button("Clear History", role: .destructive) { history.clear() }
            } message: {
                Text(history.syncIsActive ? "This clears unpinned history across synced devices. Pinned items stay." : "This clears unpinned history on this device. Pinned items stay.")
            }
            .alert(
                "Couldn’t Save Clipboard History",
                isPresented: persistenceErrorPresented
            ) {
                Button("OK") { history.dismissPersistenceError() }
            } message: {
                Text(history.persistenceError ?? "")
            }
    }

    private var persistenceErrorPresented: Binding<Bool> {
        Binding(
            get: { history.persistenceError != nil },
            set: { if !$0 { history.dismissPersistenceError() } }
        )
    }
}
