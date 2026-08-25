import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var shortcutSettings: ShortcutSettings
    @Environment(\.controlActiveState) private var controlActiveState
    let coordinator: AppCoordinator
    @ObservedObject private var fileDropController: PanelFileDropController
    private let clipDragSourceController: ClipDragSourceController

    @State private var entryDraft = ComposerDraft()
    @State private var entryDraftSectionID = SnipSnapSection.inboxID
    @State private var showingNewSection = false
    @State private var movesSelectionToNewSection = false
    @State private var showingFileImporter = false
    @State private var fileImportSectionID: UUID?
    @State private var showingClearClipboard = false
    @State private var declinedClipboardOnboarding = false
    @State private var measuredInlineEntryHeight = PanelControlMetrics.inlineEntryBaseHeight
    @State private var inlineEntryFieldHeight: CGFloat = 0
    @State private var isSavingInlineEntry = false
    @State private var previewURLs: [URL] = []
    @State private var selectedPreviewURL: URL?
    @State private var inlineEntryDragBlockingID = UUID()
    @StateObject private var listState = InboxListState()
    @FocusState private var focusedTarget: InboxFocusTarget?

    init(
        coordinator: AppCoordinator,
        fileDropController: PanelFileDropController,
        clipDragSourceController: ClipDragSourceController
    ) {
        self.coordinator = coordinator
        self.clipDragSourceController = clipDragSourceController
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
        .background {
            PanelDragRegion()
        }
        .tint(SnipSnapColors.controlTint)
        .preferredColorScheme(model.appearance.colorScheme)
        .quickLookPreview($selectedPreviewURL, in: previewURLs)
        .background {
            ClipboardAlertHost(
                history: model.clipboardHistory,
                isShowingClipboard: model.isShowingClipboard,
                showingClearConfirmation: $showingClearClipboard,
                declinedOnboarding: $declinedClipboardOnboarding
            )
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                let sectionID = fileImportSectionID ?? model.activeSectionID
                model.addDraftAttachments(urls, to: sectionID)
                if model.activeSectionID == sectionID {
                    entryDraft = model.composerDraft(for: sectionID)
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    model.presentedError = error.localizedDescription
                }
            }
            fileImportSectionID = nil
        }
        .onReceive(fileDropController.fileDrops) { urls in
            guard model.editingID == nil else { return }
            _ = attachDroppedFiles(urls)
        }
    }

    private var panelShell: some View {
        VStack(spacing: SnipSnapSpacing.relatedContent) {
            floatingHeader

            mainPanel

            SectionTabBarView(
                model: model,
                clipDragSourceController: clipDragSourceController
            ) {
                movesSelectionToNewSection = false
                showingNewSection = true
            }
        }
        .panelControlBaseline()
        .frame(
            minWidth: AppWindowDefaults.minimumContentSize.width,
            minHeight: AppWindowDefaults.minimumContentSize.height
        )
        .onAppear {
            entryDraftSectionID = model.activeSectionID
            entryDraft = model.composerDraft(for: model.activeSectionID)
            focusedTarget = .list
        }
        .onChange(of: model.activeSectionID) { _, sectionID in
            entryDraftSectionID = sectionID
            entryDraft = model.composerDraft(for: sectionID)
        }
        .onChange(of: model.isShowingClipboard) { _, showing in
            if !showing { declinedClipboardOnboarding = false }
            updateInboxComposerExpansion(for: measuredInlineEntryHeight)
        }
        .onReceive(coordinator.inboxFocusRequests) { request in
            switch request {
            case .search:
                focusedTarget = .search
            case .inlineEntry:
                focusedTarget = .inlineEntry
            }
        }
        .focusedValue(
            \.inboxCommandModel,
            hasInboxCommandFocus ? model : nil
        )
        .onChange(of: hasInboxCommandFocus, initial: true) { _, isActive in
            coordinator.setInboxCommandFocusActive(isActive)
        }
        .onExitCommand(perform: handleCancel)
        .sheet(
            isPresented: $showingNewSection,
            onDismiss: {
                movesSelectionToNewSection = false
                restoreListFocus()
            }
        ) {
            InboxNewSectionSheet(
                model: model,
                isPresented: $showingNewSection,
                movesSelection: movesSelectionToNewSection
            )
        }
        .alert(
            "Allow Accessibility Access?",
            isPresented: $model.isAccessibilityAccessExplanationPresented
        ) {
            Button("Not Now", role: .cancel) {}
            Button("Continue") {
                coordinator.requestAccessibilityAccess()
            }
        } message: {
            Text(
                "Snip Snap uses Accessibility to detect Shift shortcuts and capture selected content. macOS will ask you to allow access in System Settings."
            )
        }
        .alert(
            "Snip Snap",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            Button("OK") { model.presentedError = nil }
        } message: {
            Text(model.presentedError ?? "")
        }
    }

    private var mainPanel: some View {
        let shape = RoundedRectangle(
            cornerRadius: PanelShapeMetrics.paneCornerRadius,
            style: .continuous
        )
        return ZStack(alignment: .bottom) {
            mainContent

            if !model.isShowingClipboard {
                inlineEntry
                    .padding(PanelControlMetrics.inlineEntryInset)
                    .background {
                        ZStack {
                            PanelDragRegion()
                            ClipDragBlockingRegion(
                                controller: clipDragSourceController,
                                id: inlineEntryDragBlockingID
                            )
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        guard PanelGeometryChange.shouldApply(
                            current: measuredInlineEntryHeight,
                            proposed: height
                        ) else { return }
                        measuredInlineEntryHeight = height
                        updateInboxComposerExpansion(for: height)
                    }
                    .zIndex(1)
            }
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

    private var hasInboxCommandFocus: Bool {
        focusedTarget == .list && model.editingID == nil && controlActiveState == .key
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

            InboxMoreButton(
                model: model,
                focusedTarget: $focusedTarget,
                moveSelectionToNewSection: {
                    movesSelectionToNewSection = true
                    showingNewSection = true
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
    private var mainContent: some View {
        if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            globalSearchResults
        } else if model.isShowingClipboard {
            ClipboardListView(
                model: model,
                coordinator: coordinator,
                showingClearConfirmation: $showingClearClipboard
            )
        } else {
            if model.filteredItems.isEmpty {
                ZStack {
                    savedClipList
                    emptyState
                        .allowsHitTesting(false)
                }
            } else {
                savedClipList
            }
        }
    }

    @ViewBuilder
    private var globalSearchResults: some View {
        ClipboardSearchLayout(
            history: model.clipboardHistory,
            query: model.query,
            hasSavedMatches: !model.filteredItems.isEmpty
        ) {
            savedClipList
        } clipboardResults: { fillsAvailableSpace in
            ClipboardSearchStrip(
                model: model,
                coordinator: coordinator,
                fillsAvailableSpace: fillsAvailableSpace
            )
        } empty: {
            emptyState
        }
    }

    private struct ClipboardSearchLayout<
        SavedResults: View,
        ClipboardResults: View,
        Empty: View
    >: View {
        @ObservedObject var history: ClipboardHistory
        let query: String
        let hasSavedMatches: Bool
        @ViewBuilder let savedResults: () -> SavedResults
        @ViewBuilder let clipboardResults: (Bool) -> ClipboardResults
        @ViewBuilder let empty: () -> Empty

        var body: some View {
            if !hasSavedMatches && !hasClipboardMatches {
                empty()
            } else {
                VStack(spacing: 0) {
                    if hasSavedMatches {
                        savedResults()
                    }
                    if hasClipboardMatches {
                        clipboardResults(!hasSavedMatches)
                    }
                }
            }
        }

        private var hasClipboardMatches: Bool {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return false }
            return history.entries.contains {
                $0.searchText.localizedCaseInsensitiveContains(needle)
            }
        }
    }

    private var savedClipList: some View {
        InboxListView(
            model: model,
            coordinator: coordinator,
            clipDragSourceController: clipDragSourceController,
            fileDropController: fileDropController,
            state: listState,
            focusedTarget: $focusedTarget,
            moveSelectionToNewSection: { ids in
                model.selection = ids
                movesSelectionToNewSection = true
                showingNewSection = true
            },
            bottomContentInset: model.isShowingClipboard ? 0 : measuredInlineEntryHeight,
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
            return "No matches"
        }
        return model.completionFilter.emptyStateTitle
    }

    private var inlineEntry: some View {
        HStack(alignment: .top, spacing: SnipSnapSpacing.relatedContent) {
            inlineAttachmentMenu

            VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
                if !entryDraft.attachments.isEmpty {
                    AttachmentPreviewStrip(
                        items: draftAttachmentPreviewItems,
                        onPreview: { url in
                            openAttachmentPreview(entryDraft.attachments, selectedURL: url)
                        },
                        onRemove: { item in
                            removePreviewURL(item.url)
                            model.removeDraftAttachment(item.url, from: model.activeSectionID)
                            entryDraft = model.composerDraft(for: model.activeSectionID)
                        }
                    )
                    .padding(.horizontal, SnipSnapSpacing.controlContentInset)
                    .padding(.top, PanelControlMetrics.expandedInputVerticalPadding)
                }

                HStack(
                    alignment: PanelComposerLayout.actionAlignment(
                        isExpanded: isInlineEntryExpanded
                    ),
                    spacing: SnipSnapSpacing.relatedContent
                ) {
                    inlineEntryField
                    inlineSendButton
                        .padding(.trailing, PanelControlMetrics.sendButtonInset)
                }
                .padding(.leading, SnipSnapSpacing.controlContentInset)
                .padding(.top, inlineEntryTextTopPadding)
                .padding(.bottom, inlineEntryTextBottomPadding)
            }
            .panelEmbeddedInputSurface(
                minHeight: PanelControlMetrics.floatingRowHeight,
                expanded: isInlineEntrySurfaceExpanded,
                isFocused: focusedTarget == .inlineEntry
            )
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }

    private var inlineAttachmentMenu: some View {
        Menu {
            Button("Choose Files…") {
                fileImportSectionID = model.activeSectionID
                showingFileImporter = true
            }
            Button("Capture Screen Area…") { captureScreenArea() }
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

    private var inlineEntryField: some View {
        TextField("Add to \(model.activeSection.name)…", text: entryText, axis: .vertical)
            .panelInputStyle()
            .lineLimit(1...5)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                guard PanelGeometryChange.shouldApply(
                    current: inlineEntryFieldHeight,
                    proposed: height
                ) else { return }
                inlineEntryFieldHeight = height
            }
            .focused($focusedTarget, equals: .inlineEntry)
            .onSubmit(saveInlineEntry)
    }

    private var entryText: Binding<String> {
        Binding(
            get: { entryDraft.text },
            set: { value in
                entryDraft.text = value
                model.saveComposerText(value, for: entryDraftSectionID)
            }
        )
    }

    private var inlineSendButton: some View {
        Button(action: saveInlineEntry) {
            InlineSendButtonLabel()
        }
        .panelEmbeddedProminentActionControl()
        .disabled(!canSaveInlineEntry)
        .accessibilityLabel("Add to \(model.activeSection.name)")
        .help("Add to \(model.activeSection.name)")
    }

    private var isInlineEntryExpanded: Bool {
        inlineEntryFieldHeight > 30
    }

    private var isInlineEntrySurfaceExpanded: Bool {
        isInlineEntryExpanded || !entryDraft.attachments.isEmpty
    }

    private var inlineEntryTextTopPadding: CGFloat {
        isInlineEntryExpanded && entryDraft.attachments.isEmpty
            ? PanelControlMetrics.expandedInputVerticalPadding
            : 0
    }

    private var inlineEntryTextBottomPadding: CGFloat {
        isInlineEntrySurfaceExpanded
            ? PanelControlMetrics.expandedInputVerticalPadding
            : 0
    }

    private var canSaveInlineEntry: Bool {
        !isSavingInlineEntry
            && (!entryDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !entryDraft.attachments.isEmpty)
    }

    private var draftAttachmentPreviewItems: [AttachmentPreviewItem] {
        entryDraft.attachments.map(AttachmentPreviewItem.init(url:))
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

        let sectionID = model.activeSectionID
        model.addDraftAttachments(files, to: sectionID)
        entryDraftSectionID = sectionID
        entryDraft = model.composerDraft(for: sectionID)
        focusedTarget = .inlineEntry
        return true
    }

    private func updateInboxComposerExpansion(for height: CGFloat) {
        let expansion = model.isShowingClipboard
            ? 0
            : max(height - PanelControlMetrics.inlineEntryBaseHeight, 0)
        coordinator.updateInboxComposerExpansion(expansion)
    }

    private func saveInlineEntry() {
        let text = entryDraft.text
        guard canSaveInlineEntry else { return }
        isSavingInlineEntry = true
        let sectionID = model.activeSectionID
        Task {
            defer { isSavingInlineEntry = false }
            let saved = await model.saveComposerDraft(content: text, sectionID: sectionID)
            guard saved else {
                focusedTarget = .inlineEntry
                return
            }
            if model.activeSectionID == sectionID {
                entryDraft = model.composerDraft(for: sectionID)
                focusedTarget = .inlineEntry
            }
        }
    }

    private func captureScreenArea() {
        let sectionID = model.activeSectionID
        let url = model.stageScreenCapture()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", url.path]
        process.terminationHandler = { process in
            Task { @MainActor in
                let succeeded = process.terminationStatus == 0
                    && FileManager.default.fileExists(atPath: url.path)
                model.finishScreenCapture(url, in: sectionID, succeeded: succeeded)
                if succeeded, model.activeSectionID == sectionID {
                    entryDraft = model.composerDraft(for: sectionID)
                }
            }
        }
        do { try process.run() } catch {
            model.finishScreenCapture(url, in: sectionID, succeeded: false)
            model.presentedError = "Snip Snap could not start screen capture."
        }
    }

    private func selectAllVisible() {
        listState.selectAllVisible(model: model)
        focusedTarget = .list
    }

    private func restoreListFocus() {
        focusedTarget = .list
    }

    private func handleCancel() {
        if focusedTarget == .search {
            focusedTarget = .list
        } else if focusedTarget == .inlineEntry {
            if entryDraft.text.isEmpty && entryDraft.attachments.isEmpty {
                coordinator.hideInbox()
            } else {
                entryDraft = ComposerDraft()
                model.clearDraft(for: model.activeSectionID)
            }
        } else if !model.selection.isEmpty {
            model.selection = []
        } else {
            coordinator.hideInbox()
        }
    }

}

private struct ClipboardAlertHost: View {
    @ObservedObject var history: ClipboardHistory
    let isShowingClipboard: Bool
    @Binding var showingClearConfirmation: Bool
    @Binding var declinedOnboarding: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .confirmationDialog(
                "Clear clipboard history?",
                isPresented: $showingClearConfirmation
            ) {
                Button("Clear History", role: .destructive) { history.clear() }
            } message: {
                Text("This leaves the current Mac clipboard unchanged.")
            }
            .alert("Turn On Clipboard History?", isPresented: onboardingPresented) {
                Button("Not Now", role: .cancel) { }
                Button("Turn On") { history.startMonitoring() }
            } message: {
                Text("Snip Snap keeps up to 100 clipboard items on this Mac. You can pause or clear history at any time.")
            }
            .alert(
                "Clipboard History Was Not Saved",
                isPresented: persistenceErrorPresented
            ) {
                Button("OK") { history.dismissPersistenceError() }
            } message: {
                Text(history.persistenceError ?? "")
            }
    }

    private var onboardingPresented: Binding<Bool> {
        Binding(
            get: {
                isShowingClipboard
                    && !history.hasConsent
                    && !declinedOnboarding
            },
            set: { if !$0 { declinedOnboarding = true } }
        )
    }

    private var persistenceErrorPresented: Binding<Bool> {
        Binding(
            get: { history.persistenceError != nil },
            set: { if !$0 { history.dismissPersistenceError() } }
        )
    }
}

private struct InlineSendButtonLabel: View {
    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 13, weight: .bold))
    }
}
