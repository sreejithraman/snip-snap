import CoreTransferable
import SnipSnapCore
import SwiftUI

struct SnipListTabBarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum TabSelection: Hashable {
        case clipboard
        case list(UUID)

        var listID: UUID? {
            switch self {
            case .clipboard: nil
            case .list(let listID): listID
            }
        }
    }

    @ObservedObject var model: AppModel
    let dragSessionController: PanelDragSessionController
    let createList: () -> Void
    @State private var dropTargetTab: TabSelection?
    @State private var hoverOpenTask: Task<Void, Never>?
    @State private var editingList: SnipList?
    @State private var listPendingDeletion: SnipList?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SnipSnapSpacing.relatedContent) {
                tabStrip
                    .fixedSize(horizontal: true, vertical: false)
                newListButton
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: SnipSnapSpacing.relatedContent) {
                scrollingTabStrip
                    .frame(maxWidth: .infinity, alignment: .leading)
                newListButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            PanelDragRegion()
        }
        .background {
            PanelDragBlockingRegion(
                controller: dragSessionController
            )
        }
        .onDisappear { hoverOpenTask?.cancel() }
        .sheet(item: $editingList) { list in
            SnipListEditSheet(model: model, list: list)
        }
        .confirmationDialog(
            String(localized: "Delete \(listPendingDeletion?.name ?? String(localized: "list"))?"),
            isPresented: listDeletionPresented
        ) {
            Button("Delete List", role: .destructive) {
                guard let list = listPendingDeletion else { return }
                listPendingDeletion = nil
                Task { await model.deleteList(list) }
            }
            Button("Cancel", role: .cancel) { listPendingDeletion = nil }
        } message: {
            Text("Its snips will move to Inbox.")
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

    private var newListButton: some View {
        Button(action: createList) {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(
                    width: PanelControlMetrics.floatingIconLength,
                    height: PanelControlMetrics.floatingIconLength
                )
                .panelStandaloneActionControl()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New List")
        .help("New List")
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
            && tab == .list(model.activeListID)
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
                        isSubdued: remembered,
                        tint: model.lists.first(where: { $0.id == tab.listID })?.accent.color
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
            if case .list(let listID) = tab,
               listID != SnipList.inboxID,
               let list = model.lists.first(where: { $0.id == listID }) {
                Button("Edit List…") { editingList = list }
                Divider()
                Button("Delete List", role: .destructive) {
                    listPendingDeletion = list
                }
            }
        }
        .dropDestination(
            for: PanelDropPayload.self,
            isEnabled: tab.listID != nil
        ) { payloads, _ in
            guard let listID = tab.listID else { return }
            performDrop(payloads, in: listID)
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

    private func performDrop(_ payloads: [PanelDropPayload], in listID: UUID) {
        cancelHoverOpen()
        dropTargetTab = nil
        guard payloads.count == 1, let payload = payloads.first else { return }

        switch payload {
        case .snip(let payload):
            Task {
                _ = await model.moveToList(
                    ids: payload.ids,
                    listID: listID
                )
            }
        }
    }

    private func updateDropSession(_ session: DropSession, over tab: TabSelection) {
        guard tab.listID != nil else { return }
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
                  let listID = tab.listID,
                  let list = model.lists.first(where: { $0.id == listID }) else {
                return
            }
            model.selectList(list, preservingSelection: true)
            hoverOpenTask = nil
        }
    }

    private func cancelHoverOpen() {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
    }

    private var listDeletionPresented: Binding<Bool> {
        Binding(
            get: { listPendingDeletion != nil },
            set: { if !$0 { listPendingDeletion = nil } }
        )
    }

    private var tabs: [TabSelection] {
        [.clipboard] + model.lists.map { .list($0.id) }
    }

    private var currentTab: TabSelection {
        model.isShowingClipboard
            ? .clipboard
            : .list(model.activeListID)
    }

    private func scrollSelectedTab(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            if reduceMotion {
                proxy.scrollTo(currentTab, anchor: .center)
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(currentTab, anchor: .center)
                }
            }
        }
    }

    private func tabName(_ tab: TabSelection) -> String {
        switch tab {
        case .clipboard:
            String(localized: "Clipboard")
        case .list(let listID):
            model.lists.first(where: { $0.id == listID })?.displayName
                ?? String(localized: "List")
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
                case .list(let listID):
                    guard let list = model.lists.first(where: { $0.id == listID }) else {
                        return
                    }
                    model.selectList(list)
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
        case .list(let listID):
            if let list = model.lists.first(where: { $0.id == listID }) {
                Image(systemName: list.systemImage)
                    .foregroundStyle(list.accent.color)
                    .accessibilityLabel(list.displayName)
                    .help(list.displayName)
            }
        }
    }
}

enum PanelDropPayload: Transferable, Sendable {
    case snip(SnipDragPayload)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { (payload: SnipDragPayload) in
            PanelDropPayload.snip(payload)
        }
    }
}
