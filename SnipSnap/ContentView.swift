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
    let coordinator: AppCoordinator
    @ObservedObject private var accessibilityPermissions: AccessibilityPermissionController
    @ObservedObject private var fileDropController: PanelFileDropController
    private let accountNoticeModel: AppleAccountNoticeModel?
    private let dragSessionController: PanelDragSessionController

    @State private var entryDraft = ComposerDraft()
    @State private var entryDraftListID = SnipList.inboxID
    @State private var showingNewList = false
    @State private var movesSelectionToNewList = false
    @State private var showingFileImporter = false
    @State private var fileImportTarget: FileImportTarget?
    @State private var pendingEditAttachmentImport: PendingEditAttachmentImport?
    @State private var showingClearClipboard = false
    @State private var showingRecoveryReview = false
    @State private var measuredInlineEntryHeight = PanelControlMetrics.inlineEntryBaseHeight
    @State private var inlineEntryFieldHeight: CGFloat = 0
    @State private var isSavingInlineEntry = false
    @State private var previewURLs: [URL] = []
    @State private var selectedPreviewURL: URL?
    @State private var inlineEntryDragBlockingID = UUID()
    @StateObject private var listState = SnipListState()
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
                    if model.activeListID == listID {
                        entryDraft = model.composerDraft(for: listID)
                    }
                case .edit, .none:
                    break
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    model.presentedError = error.localizedDescription
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
                movesSelectionToNewList = false
                showingNewList = true
            }
        }
        .panelControlBaseline()
        .frame(
            minWidth: AppWindowDefaults.minimumContentSize.width,
            minHeight: AppWindowDefaults.minimumContentSize.height
        )
        .onAppear {
            entryDraftListID = model.activeListID
            entryDraft = model.composerDraft(for: model.activeListID)
            focusedTarget = .list
        }
        .onChange(of: model.activeListID) { _, listID in
            entryDraftListID = listID
            entryDraft = model.composerDraft(for: listID)
        }
        .onChange(of: model.isShowingClipboard) { _, _ in
            updatePanelComposerExpansion(for: measuredInlineEntryHeight)
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
                movesSelectionToNewList = false
                restoreListFocus()
            }
        ) {
            NewSnipListSheet(
                model: model,
                isPresented: $showingNewList,
                movesSelection: movesSelectionToNewList
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
            Text("Review: \(model.importPreviewSummary). Snip Snap will merge these records with your saved snips.")
        }
        .sheet(isPresented: $accessibilityPermissions.isRepairPresented) {
            AccessibilityRepairView(controller: accessibilityPermissions)
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
                            PanelDragBlockingRegion(
                                controller: dragSessionController,
                                id: inlineEntryDragBlockingID
                            )
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        let height = PanelComposerLayout.clampedEntryHeight(height)
                        guard PanelGeometryChange.shouldApply(
                            current: measuredInlineEntryHeight,
                            proposed: height
                        ) else { return }
                        measuredInlineEntryHeight = height
                        updatePanelComposerExpansion(for: height)
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

    private var hasSnipCommandFocus: Bool {
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
                    movesSelectionToNewList = true
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
    private var mainContent: some View {
        if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            globalSearchResults
        } else if model.isShowingClipboard {
            ClipboardListView(
                model: model,
                coordinator: coordinator,
                dragSessionController: dragSessionController,
                showingClearConfirmation: $showingClearClipboard,
                onPreviewAttachments: openAttachmentPreview
            )
        } else {
            if model.filteredSnips.isEmpty {
                ZStack {
                    savedSnipList
                    emptyState
                        .allowsHitTesting(false)
                }
            } else {
                savedSnipList
            }
        }
    }

    @ViewBuilder
    private var globalSearchResults: some View {
        if model.filteredSnips.isEmpty && model.clipboardSearchMatches.isEmpty {
            emptyState
        } else {
            savedSnipList
        }
    }

    private var savedSnipList: some View {
        SnipListView(
            model: model,
            coordinator: coordinator,
            dragSessionController: dragSessionController,
            fileDropController: fileDropController,
            state: listState,
            focusedTarget: $focusedTarget,
            moveSelectionToNewList: { ids in
                model.selection = ids
                movesSelectionToNewList = true
                showingNewList = true
            },
            requestFileImport: { snipID in
                fileImportTarget = .edit(snipID)
                showingFileImporter = true
            },
            pendingEditAttachmentImport: $pendingEditAttachmentImport,
            captureScreenAreaForEdit: captureScreenAreaForEdit,
            bottomContentInset: model.isShowingClipboard ? 0 : measuredInlineEntryHeight,
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

    private var inlineEntry: some View {
        HStack(alignment: .top, spacing: SnipSnapSpacing.relatedContent) {
            inlineAttachmentMenu

            VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
                if !entryDraft.attachments.isEmpty {
                    AttachmentPreviewStrip(
                        items: draftAttachmentPreviewItems,
                        onPreview: { item in
                            guard let url = item.url else { return }
                            openAttachmentPreview(entryDraft.attachments, selectedURL: url)
                        },
                        onRemove: { item in
                            guard let url = item.url else { return }
                            removePreviewURL(url)
                            model.removeDraftAttachment(url, from: model.activeListID)
                            entryDraft = model.composerDraft(for: model.activeListID)
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
                        .padding(.trailing, SnipSnapSpacing.relatedContent)
                }
                .padding(.leading, SnipSnapSpacing.controlContentInset)
                .padding(.top, inlineEntryTextTopPadding)
                .padding(.bottom, inlineEntryTextBottomPadding)
            }
            .panelEmbeddedInputSurface(
                minHeight: PanelControlMetrics.compactComposerHeight,
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
                fileImportTarget = .composer(model.activeListID)
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
        PanelMultilineTextInput(
            "Add to \(model.activeList.displayName)…",
            text: entryText,
            lineRange: PanelComposerMetrics.textLineRange,
            lineSpacing: PanelComposerMetrics.textLineSpacing,
            isFocused: focusedTarget == .inlineEntry,
            onFocusChange: { isFocused in
                if isFocused {
                    focusedTarget = .inlineEntry
                } else if focusedTarget == .inlineEntry {
                    focusedTarget = nil
                }
            },
            onPasteImages: pasteImagesIntoComposer,
            onSubmit: saveInlineEntry
        )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                guard PanelGeometryChange.shouldApply(
                    current: inlineEntryFieldHeight,
                    proposed: height
                ) else { return }
                inlineEntryFieldHeight = height
            }
    }

    private var entryText: Binding<String> {
        Binding(
            get: { entryDraft.text },
            set: { value in
                entryDraft.text = value
                model.saveComposerText(value, for: entryDraftListID)
            }
        )
    }

    private var inlineSendButton: some View {
        AppProminentActionButton(action: saveInlineEntry) {
            InlineSendButtonLabel()
        }
        .disabled(!canSaveInlineEntry)
        .accessibilityLabel("Add to \(model.activeList.displayName)")
        .help("Add to \(model.activeList.displayName)")
    }

    private var isInlineEntryExpanded: Bool {
        PanelComposerLayout.isExpanded(fieldHeight: inlineEntryFieldHeight)
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

        let listID = model.activeListID
        model.addDraftAttachments(files, to: listID)
        entryDraftListID = listID
        entryDraft = model.composerDraft(for: listID)
        focusedTarget = .inlineEntry
        return true
    }

    @MainActor
    private func pasteImagesIntoComposer(_ images: [PanelPastedImage]) {
        let listID = model.activeListID
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                PanelPastedImageStaging.write(images)
            }.value
            switch result {
            case .success(let urls):
                for url in urls {
                    model.addTemporaryDraftAttachment(url, to: listID)
                }
                if model.activeListID == listID {
                    entryDraftListID = listID
                    entryDraft = model.composerDraft(for: listID)
                }
            case .failure(let error):
                model.presentedError = error.localizedDescription
            }
        }
    }

    private func updatePanelComposerExpansion(for height: CGFloat) {
        let expansion = model.isShowingClipboard
            ? 0
            : max(height - PanelControlMetrics.inlineEntryBaseHeight, 0)
        coordinator.updatePanelComposerExpansion(expansion)
    }

    private func saveInlineEntry() {
        let text = entryDraft.text
        guard canSaveInlineEntry else { return }
        isSavingInlineEntry = true
        let listID = model.activeListID
        Task {
            defer { isSavingInlineEntry = false }
            let saved = await model.saveComposerDraft(content: text, listID: listID)
            guard saved else {
                focusedTarget = .inlineEntry
                return
            }
            if model.activeListID == listID {
                entryDraft = model.composerDraft(for: listID)
                focusedTarget = .inlineEntry
            }
        }
    }

    private func captureScreenArea() {
        let listID = model.activeListID
        let url = model.stageScreenCapture()
        runScreenCapture(to: url) { succeeded in
            model.finishScreenCapture(url, in: listID, succeeded: succeeded)
            if succeeded, model.activeListID == listID {
                entryDraft = model.composerDraft(for: listID)
            }
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
            model.presentedError = String(localized: "Snip Snap could not start screen capture.")
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
                coordinator.hidePanel()
            } else {
                entryDraft = ComposerDraft()
                model.clearDraft(for: model.activeListID)
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
                "Clear clipboard history?",
                isPresented: $showingClearConfirmation
            ) {
                Button("Clear History", role: .destructive) { history.clear() }
            } message: {
                Text("This leaves the current Mac clipboard unchanged.")
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
            .padding(.horizontal, 4)
    }
}
