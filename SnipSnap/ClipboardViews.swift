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
    @State private var previewImage: NSImage?
    @State private var isShowingCopyConfirmation = false
    @State private var copyConfirmationTask: Task<Void, Never>?

    var body: some View {
        Button(action: performCopy) {
            ClipboardEntryCard(entry: entry, previewImage: previewImage) {
                ClipboardEntryCopyLabel(isCopied: isShowingCopyConfirmation)
            }
        }
        .buttonStyle(.plain)
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
            guard let data = entry.imageRepresentations.first?.data else {
                previewImage = nil
                return
            }
            previewImage = await PreviewImageCache.shared.clipboardImage(
                id: entry.id,
                data: data,
                size: ClipboardEntryCardMetrics.previewSize,
                scale: displayScale
            )
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
            content: ClipboardEntryCard(entry: entry, previewImage: previewImage) {
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
    static let previewSize = CGSize(width: 42, height: 42)
    static let actionWidth: CGFloat = 72
}

private struct ClipboardEntryCard<Trailing: View>: View {
    let entry: ClipboardEntry
    let previewImage: NSImage?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        PanelContentCard(alignment: .center) {
            ClipboardEntryArtwork(
                hasImage: !entry.imageRepresentations.isEmpty,
                hasFiles: !entry.fileURLs.isEmpty,
                image: previewImage
            )
        } main: {
            PanelContentCardMain {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text.isEmpty ? "Clipboard item" : entry.text)
                        .foregroundStyle(SnipSnapColors.textPrimary)
                        .lineLimit(3)
                        .lineSpacing(2)
                    if let source = entry.sourceApplication {
                        Text(source)
                            .font(.caption2)
                            .foregroundStyle(SnipSnapColors.textSecondary)
                    }
                }
            }
        } trailing: {
            trailing()
        }
    }
}

private struct ClipboardEntryArtwork: View {
    let hasImage: Bool
    let hasFiles: Bool
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: hasImage ? "photo" : (hasFiles ? "doc.fill" : "doc.on.clipboard"))
            }
        }
        .frame(
            width: ClipboardEntryCardMetrics.previewSize.width,
            height: ClipboardEntryCardMetrics.previewSize.height
        )
        .clipped()
    }
}

private struct ClipboardEntryCopyLabel: View {
    let isCopied: Bool

    var body: some View {
        Label(
            isCopied ? "Copied" : "Copy",
            systemImage: isCopied ? "checkmark" : "doc.on.doc"
        )
        .frame(width: ClipboardEntryCardMetrics.actionWidth, alignment: .trailing)
    }
}
