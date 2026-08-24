import CoreTransferable
import SwiftUI

struct SectionTabBarView: View {
    private enum TabSelection: Hashable {
        case clipboard
        case section(UUID)

        var sectionID: UUID? {
            switch self {
            case .clipboard: nil
            case .section(let sectionID): sectionID
            }
        }
    }

    @ObservedObject var model: AppModel
    let clipDragSourceController: ClipDragSourceController
    let createSection: () -> Void
    @State private var dragBlockingID = UUID()
    @State private var dropTargetTab: TabSelection?
    @State private var hoverOpenTask: Task<Void, Never>?
    @State private var editingSection: SnipSnapSection?
    @State private var sectionPendingDeletion: SnipSnapSection?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SnipSnapSpacing.relatedContent) {
                tabStrip
                    .fixedSize(horizontal: true, vertical: false)
                newSectionButton
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: SnipSnapSpacing.relatedContent) {
                scrollingTabStrip
                    .frame(maxWidth: .infinity, alignment: .leading)
                newSectionButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ClipDragBlockingRegion(
                controller: clipDragSourceController,
                id: dragBlockingID
            )
        }
        .onDisappear { hoverOpenTask?.cancel() }
        .sheet(item: $editingSection) { section in
            SectionEditSheet(model: model, section: section)
        }
        .confirmationDialog(
            "Delete \(sectionPendingDeletion?.name ?? "section")?",
            isPresented: sectionDeletionPresented
        ) {
            Button("Delete Section", role: .destructive) {
                guard let section = sectionPendingDeletion else { return }
                sectionPendingDeletion = nil
                Task { await model.deleteSection(section) }
            }
            Button("Cancel", role: .cancel) { sectionPendingDeletion = nil }
        } message: {
            Text("Its clips will move to Inbox.")
        }
    }

    private var scrollingTabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                tabStrip
            }
            .scrollIndicators(.hidden)
            .onAppear { scrollSelectedTab(using: proxy) }
            .onChange(of: currentTab) { _, _ in
                scrollSelectedTab(using: proxy)
            }
            .onChange(of: tabs) { _, _ in
                scrollSelectedTab(using: proxy)
            }
        }
    }

    private var newSectionButton: some View {
        Button(action: createSection) {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(
                    width: PanelControlMetrics.floatingIconLength,
                    height: PanelControlMetrics.floatingIconLength
                )
                .panelStandaloneActionControl()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Section")
        .help("New Section")
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .frame(minHeight: PanelControlMetrics.floatingRowHeight)
        .panelGlassSurface(in: Capsule())
    }

    private func tabButton(_ tab: TabSelection) -> some View {
        let selected = selectedTab.wrappedValue == tab
        let remembered = model.isShowingClipboard
            && tab == .section(model.activeSectionID)
        let targeted = dropTargetTab == tab
        let name = tabName(tab)

        return Button {
            selectedTab.wrappedValue = tab
        } label: {
            ZStack {
                Color.clear
                    .frame(
                        width: PanelControlMetrics.compactSelectionWidth,
                        height: PanelControlMetrics.compactSelectionHeight
                    )
                    .panelCompactStateSurface(
                        isEmphasized: selected,
                        isSubdued: remembered
                    )
                    .panelDropTargetState(in: Circle(), isTargeted: targeted)

                tabIcon(tab)
            }
            .frame(
                width: PanelControlMetrics.tabItemWidth,
                height: PanelControlMetrics.floatingRowHeight
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(tab)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(name)
        .contextMenu {
            if case .section(let sectionID) = tab,
               sectionID != SnipSnapSection.inboxID,
               let section = model.sections.first(where: { $0.id == sectionID }) {
                Button("Edit Section…") { editingSection = section }
                Divider()
                Button("Delete Section", role: .destructive) {
                    sectionPendingDeletion = section
                }
            }
        }
        .dropDestination(
            for: PanelDropPayload.self,
            isEnabled: tab.sectionID != nil
        ) { payloads, _ in
            guard let sectionID = tab.sectionID else { return }
            performDrop(payloads, in: sectionID)
        }
        .onDropSessionUpdated { session in
            updateDropSession(session, over: tab)
        }
        .dropConfiguration { session in
            let operation: DropOperation = session.suggestedOperations.contains(.move)
                ? .move
                : .copy
            var configuration = DropConfiguration(operation: operation)
            configuration.acceptedItemCount = 1
            return configuration
        }
    }

    private func performDrop(_ payloads: [PanelDropPayload], in sectionID: UUID) {
        cancelHoverOpen()
        dropTargetTab = nil
        guard payloads.count == 1, let payload = payloads.first else { return }

        switch payload {
        case .clip(let payload):
            let selectionBeforeMove = model.selection
            Task {
                _ = await model.moveToSection(
                    ids: payload.ids,
                    sectionID: sectionID,
                    selectionAfterMove: selectionBeforeMove
                )
            }
        case .clipboard(let payload):
            guard let entry = model.clipboardHistory.entry(id: payload.entryID) else { return }
            Task { _ = await model.saveClipboardEntry(entry, sectionID: sectionID) }
        }
    }

    private func updateDropSession(_ session: DropSession, over tab: TabSelection) {
        guard tab.sectionID != nil else { return }
        switch session.phase {
        case .entering:
            dropTargetTab = tab
            scheduleHoverOpen(for: tab)
        case .active:
            if dropTargetTab != tab {
                dropTargetTab = tab
                scheduleHoverOpen(for: tab)
            }
        case .exiting, .ended, .dataTransferCompleted:
            if dropTargetTab == tab {
                dropTargetTab = nil
                cancelHoverOpen()
            }
        @unknown default:
            break
        }
    }

    private func scheduleHoverOpen(for tab: TabSelection) {
        cancelHoverOpen()
        hoverOpenTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            guard dropTargetTab == tab,
                  let sectionID = tab.sectionID,
                  let section = model.sections.first(where: { $0.id == sectionID }) else {
                return
            }
            model.selectSection(section, preservingSelection: true)
            hoverOpenTask = nil
        }
    }

    private func cancelHoverOpen() {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
    }

    private var sectionDeletionPresented: Binding<Bool> {
        Binding(
            get: { sectionPendingDeletion != nil },
            set: { if !$0 { sectionPendingDeletion = nil } }
        )
    }

    private var tabs: [TabSelection] {
        [.clipboard] + model.sections.map { .section($0.id) }
    }

    private var currentTab: TabSelection {
        model.isShowingClipboard
            ? .clipboard
            : .section(model.activeSectionID)
    }

    private func scrollSelectedTab(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(currentTab, anchor: .center)
            }
        }
    }

    private func tabName(_ tab: TabSelection) -> String {
        switch tab {
        case .clipboard:
            "Clipboard"
        case .section(let sectionID):
            model.sections.first(where: { $0.id == sectionID })?.name ?? "Section"
        }
    }

    private var selectedTab: Binding<TabSelection> {
        Binding(
            get: {
                currentTab
            },
            set: { tab in
                switch tab {
                case .clipboard:
                    model.showClipboard()
                case .section(let sectionID):
                    guard let section = model.sections.first(where: { $0.id == sectionID }) else {
                        return
                    }
                    model.selectSection(section)
                }
            }
        )
    }

    @ViewBuilder
    private func tabIcon(_ tab: TabSelection) -> some View {
        switch tab {
        case .clipboard:
            Image(systemName: "clipboard.fill")
                .accessibilityLabel("Clipboard")
                .help("Clipboard")
        case .section(let sectionID):
            if let section = model.sections.first(where: { $0.id == sectionID }) {
                Image(systemName: section.systemImage)
                    .accessibilityLabel(section.name)
                    .help(section.name)
            }
        }
    }
}

enum PanelDropPayload: Transferable, Sendable {
    case clip(ClipDragPayload)
    case clipboard(ClipboardDragPayload)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { (payload: ClipDragPayload) in
            PanelDropPayload.clip(payload)
        }
        ProxyRepresentation { (payload: ClipboardDragPayload) in
            PanelDropPayload.clipboard(payload)
        }
    }
}
