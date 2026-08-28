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
                    PanelListSectionHeader(
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
            PinnedListHeaderGlass.hasScrolled(
                visibleOriginY: geometry.contentOffset.y
            )
        } action: { _, hasScrolled in
            if hasScrolledFromTop != hasScrolled {
                hasScrolledFromTop = hasScrolled
            }
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

    var body: some View {
        ClipboardEntryCard(
            entry: entry,
            previewImages: previewImages,
            isCopied: isShowingCopyConfirmation,
            copy: performCopy,
            onPreviewAttachments: onPreviewAttachments
        )
        .background {
            ClipboardEntryDragSourceRegion(
                controller: dragSessionController,
                id: entry.id,
                package: ClipboardEntryDragExportPackage(entry: entry),
                previewRenderer: renderDragPreview
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
        let renderer = ImageRenderer(
            content: ClipboardEntryCard(
                entry: entry,
                previewImages: previewImages,
                isCopied: false,
                copy: {},
                onPreviewAttachments: { _, _ in }
            )
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
}

private enum ClipboardEntryCardMetrics {
    static let previewSize = CGSize(
        width: AttachmentPreviewMetrics.side,
        height: AttachmentPreviewMetrics.side
    )
    static let previewLimit = 3
    static let actionSide: CGFloat = 24
}

private struct ClipboardEntryCard: View {
    let entry: ClipboardEntry
    let previewImages: [NSImage]
    let isCopied: Bool
    let copy: () -> Void
    let onPreviewAttachments: ([URL], URL) -> Void

    var body: some View {
        PanelContentCard(alignment: .top) {
            ClipboardEntryCopyButton(
                isCopied: isCopied,
                action: copy
            )
        } main: {
            PanelContentCardMain {
                if !previewImages.isEmpty {
                    AttachmentPreviewImageStrip(images: previewImages)
                }
                if !entry.fileURLs.isEmpty {
                    AttachmentPreviewStrip(
                        items: attachmentPreviewItems,
                        onPreview: { url in
                            onPreviewAttachments(entry.fileURLs, url)
                        }
                    )
                }
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    SnipCardText(
                        text: entry.text.isEmpty ? "Clipboard item" : entry.text,
                        isDone: false
                    )
                    sourceApplication
                }
            }
        }
    }

    private var attachmentPreviewItems: [AttachmentPreviewItem] {
        entry.fileURLs.map(AttachmentPreviewItem.init(url:))
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
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(
                    width: ClipboardEntryCardMetrics.actionSide,
                    height: ClipboardEntryCardMetrics.actionSide
                )
        }
        .buttonStyle(ClipboardEntryCopyButtonStyle(isHovered: isHovered))
        .onHover { isHovered = $0 }
        .help(isCopied ? "Copied" : "Copy")
        .accessibilityLabel(isCopied ? "Copied" : "Copy")
    }
}

private struct ClipboardEntryCopyButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let edge = PanelEdgeStyle.media
        configuration.label
            .foregroundStyle(SnipSnapColors.textPrimary)
            .background {
                shape
                    .fill(.regularMaterial)
                    .overlay {
                        shape.fill(
                            Color.primary.opacity(
                                configuration.isPressed ? 0.14 : isHovered ? 0.08 : 0.035
                            )
                        )
                    }
            }
            .overlay {
                shape.stroke(edge.color, lineWidth: edge.width)
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
