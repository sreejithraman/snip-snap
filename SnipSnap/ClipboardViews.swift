import AppKit
import SwiftUI

struct ClipboardListView: View {
    @ObservedObject var model: AppModel
    let coordinator: AppCoordinator
    let dragSessionController: PanelDragSessionController
    @Binding var showingClearConfirmation: Bool
    let onPreviewAttachments: ([URL], URL) -> Void
    @ObservedObject private var history: ClipboardHistory

    init(
        model: AppModel,
        coordinator: AppCoordinator,
        dragSessionController: PanelDragSessionController,
        showingClearConfirmation: Binding<Bool>,
        onPreviewAttachments: @escaping ([URL], URL) -> Void
    ) {
        self.model = model
        self.coordinator = coordinator
        self.dragSessionController = dragSessionController
        _showingClearConfirmation = showingClearConfirmation
        self.onPreviewAttachments = onPreviewAttachments
        history = model.clipboardHistory
    }

    var body: some View {
        ClipboardEntriesList(
            entries: history.entries,
            model: model,
            coordinator: coordinator,
            dragSessionController: dragSessionController,
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
    let coordinator: AppCoordinator
    let dragSessionController: PanelDragSessionController
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
                                onPreviewAttachments: onPreviewAttachments
                            ) {
                                coordinator.copyClipboardEntry(entry)
                            } save: {
                                Task { _ = await model.saveClipboardEntry(entry) }
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                guard PanelGeometryChange.shouldApply(
                    current: contentHeight,
                    proposed: $0
                ) else { return }
                contentHeight = $0
            }
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > PanelGeometryChange.minimumMeaningfulChange
        } action: { _, hasScrolled in
            hasScrolledFromTop = hasScrolled
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            guard PanelGeometryChange.shouldApply(
                current: viewportHeight,
                proposed: $0
            ) else { return }
            viewportHeight = $0
        }
        .overlay(alignment: .bottom) {
            PanelBlankDragRegion(
                viewportHeight: viewportHeight,
                contentHeight: contentHeight
            )
        }
        .frame(maxHeight: maxHeight)
    }
}

struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    let dragSessionController: PanelDragSessionController
    let onPreviewAttachments: ([URL], URL) -> Void
    let copy: () -> Bool
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
            }
        )
    }

    var body: some View {
        PanelContentCard(alignment: .top) {
            ClipboardEntryCopyButton(
                isCopied: isShowingCopyConfirmation,
                action: performCopy
            )
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
        .onDisappear {
            copyConfirmationTask?.cancel()
            copyConfirmationTask = nil
        }
    }

    private func performCopy() {
        guard copy() else { return }
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
    static let actionSide: CGFloat = 24
    static let actionCornerRadius: CGFloat = 8
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
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .frame(
                    width: ClipboardEntryCardMetrics.actionSide,
                    height: ClipboardEntryCardMetrics.actionSide
                )
                .foregroundStyle(SnipSnapColors.textPrimary)
                .background {
                    shape.fill(SnipSnapColors.compactActionFill)
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(isCopied ? "Copied" : "Copy")
        .accessibilityLabel(isCopied ? "Copied" : "Copy")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: ClipboardEntryCardMetrics.actionCornerRadius,
            style: .continuous
        )
    }
}
