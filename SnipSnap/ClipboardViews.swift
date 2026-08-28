import AppKit
import SwiftUI

struct ClipboardListView: View {
    @ObservedObject var model: AppModel
    let coordinator: AppCoordinator
    let dragSessionController: PanelDragSessionController
    @Binding var showingClearConfirmation: Bool
    @ObservedObject private var history: ClipboardHistory

    init(
        model: AppModel,
        coordinator: AppCoordinator,
        dragSessionController: PanelDragSessionController,
        showingClearConfirmation: Binding<Bool>
    ) {
        self.model = model
        self.coordinator = coordinator
        self.dragSessionController = dragSessionController
        _showingClearConfirmation = showingClearConfirmation
        history = model.clipboardHistory
    }

    var body: some View {
        ClipboardEntriesList(
            entries: history.entries,
            model: model,
            coordinator: coordinator,
            dragSessionController: dragSessionController,
            verticalContentPadding: PanelListMetrics.verticalContentInset,
            maxHeight: .infinity
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
                                dragSessionController: dragSessionController
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
    let copy: () -> Bool
    let save: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var previewImages: [NSImage] = []
    @State private var isShowingCopyConfirmation = false
    @State private var copyConfirmationTask: Task<Void, Never>?

    var body: some View {
        Button(action: performCopy) {
            ClipboardEntryCard(entry: entry, previewImages: previewImages) {
                ClipboardEntryCopyLabel(isCopied: isShowingCopyConfirmation)
            }
        }
        .buttonStyle(.plain)
        .help(isShowingCopyConfirmation ? "Copied" : "Copy")
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
            var images: [NSImage] = []
            let representations = entry.standaloneImageRepresentations
                .prefix(3)
                .enumerated()
            for (index, representation) in representations {
                guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
            previewImages = images
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
            content: ClipboardEntryCard(entry: entry, previewImages: previewImages) {
                ClipboardEntryCopyLabel(isCopied: false)
            }
            .frame(width: size.width, height: size.height, alignment: .leading)
            .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = scale
        return renderer.nsImage ?? NSWorkspace.shared.icon(for: .data)
    }
}

private enum ClipboardEntryCardMetrics {
    static let previewSize = CGSize(
        width: AttachmentPreviewMetrics.side,
        height: AttachmentPreviewMetrics.side
    )
    static let actionSide: CGFloat = 24
}

private struct ClipboardEntryCard<Trailing: View>: View {
    let entry: ClipboardEntry
    let previewImages: [NSImage]
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        PanelContentCard(alignment: .top, main: {
            PanelContentCardMain {
                if !previewImages.isEmpty {
                    AttachmentPreviewImageStrip(images: previewImages)
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
        }, trailing: {
            trailing()
        })
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

private struct ClipboardEntryCopyLabel: View {
    let isCopied: Bool

    var body: some View {
        Label(
            isCopied ? "Copied" : "Copy",
            systemImage: isCopied ? "checkmark" : "doc.on.doc"
        )
        .labelStyle(.iconOnly)
        .foregroundStyle(SnipSnapColors.textSecondary)
        .frame(
            width: ClipboardEntryCardMetrics.actionSide,
            height: ClipboardEntryCardMetrics.actionSide
        )
    }
}
