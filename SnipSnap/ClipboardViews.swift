import AppKit
import SwiftUI

struct ClipboardListView: View {
    @ObservedObject var model: AppModel
    let dragSessionController: PanelDragSessionController
    @ObservedObject var commandNumberPicker: CommandNumberPicker
    @Binding var showingClearConfirmation: Bool
    let onPreviewAttachments: ([URL], URL) -> Void
    @ObservedObject private var history: ClipboardHistory

    init(
        model: AppModel,
        dragSessionController: PanelDragSessionController,
        commandNumberPicker: CommandNumberPicker,
        showingClearConfirmation: Binding<Bool>,
        onPreviewAttachments: @escaping ([URL], URL) -> Void
    ) {
        self.model = model
        self.dragSessionController = dragSessionController
        self.commandNumberPicker = commandNumberPicker
        _showingClearConfirmation = showingClearConfirmation
        self.onPreviewAttachments = onPreviewAttachments
        history = model.clipboardHistory
    }

    var body: some View {
        ClipboardEntriesList(
            entries: history.entries,
            model: model,
            dragSessionController: dragSessionController,
            commandNumberPicker: commandNumberPicker,
            verticalContentPadding: PanelListMetrics.verticalContentInset,
            maxHeight: .infinity,
            onPreviewAttachments: onPreviewAttachments
        ) {
            HStack(spacing: SnipSnapSpacing.relatedContent) {
                Button(history.isPaused ? "Resume" : "Pause") {
                    history.setPaused(!history.isPaused)
                }
                Button("Clear") { showingClearConfirmation = true }.disabled(history.entries.isEmpty)
            }
        }
    }

}

private struct ClipboardEntriesList<HeaderActions: View>: View {
    let entries: [ClipboardEntry]
    @ObservedObject var model: AppModel
    let dragSessionController: PanelDragSessionController
    @ObservedObject var commandNumberPicker: CommandNumberPicker
    let verticalContentPadding: CGFloat
    let maxHeight: CGFloat
    let onPreviewAttachments: ([URL], URL) -> Void
    @ViewBuilder let headerActions: () -> HeaderActions
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var hasScrolledFromTop = false
    @State private var headerDragBlockingID = UUID()

    var body: some View {
        ScrollView {
            LazyVStack(
                alignment: .leading,
                spacing: 0,
                pinnedViews: [.sectionHeaders]
            ) {
                Section {
                    LazyVStack(
                        alignment: .leading,
                        spacing: PanelListMetrics.rowSpacing
                    ) {
                        ForEach(entries) { entry in
                            ClipboardEntryRow(
                                entry: entry,
                                dragSessionController: dragSessionController,
                                commandNumber: commandNumberPicker.displayedNumber(
                                    for: .clipboardEntry(entry.id)
                                ),
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
                                    commandNumberPicker.setRowFrame(
                                        .clipboardEntry(entry.id),
                                        frame: frame
                                    )
                                }
                            }
                            .onDisappear {
                                commandNumberPicker.setRowFrame(
                                    .clipboardEntry(entry.id),
                                    frame: nil
                                )
                            }
                        }
                    }
                    .padding(.horizontal, PanelListMetrics.horizontalContentInset)
                    .padding(.vertical, verticalContentPadding)
                } header: {
                    PanelListHeader(
                        "Clipboard",
                        hasScrolledFromTop: hasScrolledFromTop,
                        actions: headerActions
                    )
                    .background {
                        PanelDragBlockingRegion(
                            controller: dragSessionController,
                            id: headerDragBlockingID
                        )
                    }
                }
            }
            .panelMeasuredHeight($contentHeight)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > PanelGeometryChange.minimumMeaningfulChange
        } action: { _, hasScrolled in
            hasScrolledFromTop = hasScrolled
        }
        .panelBlankDragOverlay(
            viewportHeight: $viewportHeight,
            contentHeight: contentHeight
        )
        .frame(maxHeight: maxHeight)
        .background {
            SnipListWindowFrameReader { frame, _ in
                commandNumberPicker.setViewport(frame)
            }
        }
        .onAppear {
            commandNumberPicker.setOrderedTargets(
                entries.map { .clipboardEntry($0.id) }
            )
        }
        .onChange(of: entries.map(\.id)) { _, ids in
            commandNumberPicker.setOrderedTargets(ids.map(CommandNumberTarget.clipboardEntry))
        }
        .onKeyPress(phases: .down) { press in
            commandNumberPicker.handleKeyPress(press)
        }
    }
}

struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    let dragSessionController: PanelDragSessionController
    let commandNumber: Int?
    let onPickCommandNumber: () -> Void
    let copiedPulse: ClipboardCopyPulse?
    let onPreviewAttachments: ([URL], URL) -> Void
    let place: (ClipboardPlacementFeedback) -> Bool
    let save: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var previewImages: [NSImage] = []
    @State private var isShowingCopyConfirmation = false
    @State private var copyConfirmationTask: Task<Void, Never>?

    private var dragAdapter: PanelDragSessionAdapter {
        .exporting(
            makeExport: {
                ClipboardEntryDragExportPackage(entry: entry)
            },
            previewImage: { _, context in
                renderDragPreview(
                    scale: context.scale,
                    colorScheme: context.colorScheme,
                    size: context.sourceFrame.size
                )
            },
            callbacks: PanelDragSessionCallbacks(
                onBegan: {},
                onMoved: { _ in },
                onEnded: { outcome, _ in
                    if ClipboardDragPlacement.shouldPlace(
                        outcome: outcome,
                        droppedInList: false
                    ) {
                        _ = place(.silent)
                    }
                }
            )
        )
    }

    var body: some View {
        PanelContentCard(alignment: .top) {
            ZStack {
                ClipboardEntryCopyButton(
                    isCopied: isShowingCopyConfirmation,
                    action: performCopy
                )
                .opacity(commandNumber == nil || isShowingCopyConfirmation ? 1 : 0)
                if let commandNumber, !isShowingCopyConfirmation {
                    Button(action: onPickCommandNumber) {
                        CommandNumberBadge(number: commandNumber)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Copy \(commandNumber)"))
                }
            }
        } main: {
            PanelContentCardMain {
                if !liveAttachmentPreviewItems.isEmpty {
                    AttachmentPreviewStrip(
                        items: liveAttachmentPreviewItems,
                        onPreview: { item in
                            guard let url = item.url else { return }
                            onPreviewAttachments(entry.fileURLs, url)
                        }
                    )
                }
            } content: {
                ClipboardEntryCardContent(entry: entry)
            }
        }
        .background {
            PanelDragSourceRegion(
                controller: dragSessionController,
                regionID: .clipboardEntry(entry.id),
                adapter: dragAdapter
            )
        }
        .contextMenu { Button("Add to Active List", action: save) }
        .task(id: entry.id) {
            previewImages = await loadPreviewImages()
        }
        .onChange(of: copiedPulse) { _, pulse in
            guard pulse?.entryID == entry.id else { return }
            showCopyConfirmation()
        }
        .onDisappear {
            copyConfirmationTask?.cancel()
            copyConfirmationTask = nil
        }
    }

    private func performCopy() {
        _ = place(.notify)
    }

    private func showCopyConfirmation() {
        copyConfirmationTask?.cancel()
        isShowingCopyConfirmation = true
        copyConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            isShowingCopyConfirmation = false
        }
    }

    private func renderDragPreview(
        scale: CGFloat,
        colorScheme: ColorScheme,
        size: NSSize
    ) -> NSImage {
        let attachmentPreviewItems = dragAttachmentPreviewItems(scale: scale)
        let renderer = ImageRenderer(
            content: PanelContentCard(alignment: .top) {
                PanelContentCardMain {
                    if !attachmentPreviewItems.isEmpty {
                        AttachmentPreviewStrip(items: attachmentPreviewItems)
                    }
                } content: {
                    ClipboardEntryCardContent(entry: entry)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .leading)
            .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = scale
        return renderer.nsImage ?? NSWorkspace.shared.icon(for: .data)
    }

    private func loadPreviewImages() async -> [NSImage] {
        var images: [NSImage] = []
        for (index, representation) in entry.standaloneImageRepresentations.enumerated() {
            guard images.count < ClipboardEntryCardMetrics.previewLimit,
                  !Task.isCancelled else { return images }
            if let image = await PreviewImageCache.shared.clipboardImage(
                id: entry.id,
                variant: index,
                data: representation.data,
                size: ClipboardEntryCardMetrics.previewSize,
                scale: displayScale
            ) {
                images.append(image)
            }
        }
        return images
    }

    private var liveAttachmentPreviewItems: [AttachmentPreviewItem] {
        let images = previewImages.enumerated().map { index, image in
            AttachmentPreviewItem(
                id: "\(entry.id.uuidString)-image-\(index)",
                image: image
            )
        }
        return images + entry.fileURLs.map(AttachmentPreviewItem.init(url:))
    }

    private func dragAttachmentPreviewItems(scale: CGFloat) -> [AttachmentPreviewItem] {
        var items = previewImages.prefix(ClipboardEntryCardMetrics.previewLimit).enumerated().map {
            index, image in
            AttachmentPreviewItem(
                id: "\(entry.id.uuidString)-image-\(index)",
                image: image
            )
        }
        guard items.count < ClipboardEntryCardMetrics.previewLimit else { return items }
        for url in entry.fileURLs {
            guard items.count < ClipboardEntryCardMetrics.previewLimit else { break }
            if let thumbnail = PreviewImageCache.shared.cachedFileThumbnail(
                url: url,
                scale: scale
            ) {
                items.append(
                    AttachmentPreviewItem(
                        url: url,
                        previewImage: thumbnail,
                        fillsTile: true
                    )
                )
            } else {
                items.append(
                    AttachmentPreviewItem(
                        url: url,
                        previewImage: NSWorkspace.shared.icon(forFile: url.path),
                        fillsTile: false
                    )
                )
            }
        }
        return items
    }
}

private enum ClipboardEntryCardMetrics {
    static let previewSize = CGSize(
        width: AttachmentPreviewMetrics.side,
        height: AttachmentPreviewMetrics.side
    )
    static let previewLimit = 3
}

private struct ClipboardEntryCardContent: View {
    let entry: ClipboardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SnipCardText(
                text: entry.text.isEmpty ? "Clipboard item" : entry.text,
                isDone: false
            )
            sourceApplication
        }
    }

    @ViewBuilder
    private var sourceApplication: some View {
        if let source = entry.sourceApplication {
            Text(source)
                .font(.caption2)
                .foregroundStyle(SnipSnapColors.textSecondary)
        }
    }
}

private struct ClipboardEntryCopyButton: View {
    let isCopied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                shape.fill(SnipSnapColors.compactActionFill)
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(SnipSnapColors.textPrimary)
            }
            .frame(
                width: PanelCardLeadingMetrics.controlSide,
                height: PanelCardLeadingMetrics.controlSide
            )
            .contentShape(shape)
            .clipShape(shape)
        }
        .buttonStyle(.plain)
        .frame(
            width: PanelCardLeadingMetrics.controlSide,
            height: PanelCardLeadingMetrics.controlSide
        )
        .help(isCopied ? "Copied" : "Copy")
        .accessibilityLabel(isCopied ? "Copied" : "Copy")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: PanelCardLeadingMetrics.cornerRadius,
            style: .continuous
        )
    }
}
