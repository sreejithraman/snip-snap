import AppKit
import SwiftUI

struct ClipboardListView: View {
    @ObservedObject var model: AppModel
    let coordinator: AppCoordinator
    @Binding var showingClearConfirmation: Bool
    @ObservedObject private var history: ClipboardHistory

    init(model: AppModel, coordinator: AppCoordinator, showingClearConfirmation: Binding<Bool>) {
        self.model = model
        self.coordinator = coordinator
        _showingClearConfirmation = showingClearConfirmation
        history = model.clipboardHistory
    }

    var body: some View {
        ClipboardEntriesList(
            entries: history.entries,
            model: model,
            coordinator: coordinator,
            verticalContentPadding: PanelListMetrics.verticalContentInset,
            maxHeight: .infinity
        ) {
            HStack(spacing: SnipSnapSpacing.relatedContent) {
                Button {
                    history.setPaused(!history.isPaused)
                } label: {
                    Text(history.isPaused ? .resume : .pause)
                }
                Button(.clear) { showingClearConfirmation = true }.disabled(history.entries.isEmpty)
            }
        }
    }

}

private struct ClipboardEntriesList<HeaderActions: View>: View {
    let entries: [ClipboardEntry]
    @ObservedObject var model: AppModel
    let coordinator: AppCoordinator
    let verticalContentPadding: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder let headerActions: () -> HeaderActions
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var hasScrolledFromTop = false

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
                            ClipboardEntryRow(entry: entry) {
                                coordinator.useClipboardEntry(entry)
                            } save: {
                                Task { _ = await model.saveClipboardEntry(entry) }
                            }
                        }
                    }
                    .padding(.horizontal, PanelListMetrics.horizontalContentInset)
                    .padding(.vertical, verticalContentPadding)
                } header: {
                    PanelListSectionHeader(
                        String(localized: .clipboard),
                        hasScrolledFromTop: hasScrolledFromTop,
                        actions: headerActions
                    )
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
    let copy: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: SnipSnapSpacing.relatedContent) {
            if let data = entry.imageRepresentations.first?.data {
                ClipboardImagePreview(entryID: entry.id, data: data)
            } else {
                Image(systemName: entry.fileURLs.isEmpty ? "doc.on.clipboard" : "doc.fill")
                    .frame(width: 42, height: 42)
            }
            VStack(alignment: .leading) {
                Text(entry.text.isEmpty ? String(localized: .clipboardItemPlaceholder) : entry.text)
                    .lineLimit(3)
                if let source = entry.sourceApplication {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(SnipSnapColors.textSecondary)
                }
            }
            Spacer()
            Button(.save, action: save).buttonStyle(.borderless)
        }
        .padding(SnipSnapSpacing.cardContentInset)
        .panelContentCardSurface()
        .contentShape(Rectangle())
        .onTapGesture(perform: copy)
        .draggable(ClipboardDragPayload(entryID: entry.id))
        .contextMenu { Button(.saveToActiveList, action: save) }
    }
}

private struct ClipboardImagePreview: View {
    let entryID: UUID
    let data: Data
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: 42, height: 42)
        .clipped()
        .task(id: entryID) {
            image = await PreviewImageCache.shared.clipboardImage(
                id: entryID,
                data: data,
                size: CGSize(width: 42, height: 42),
                scale: displayScale
            )
        }
    }
}
