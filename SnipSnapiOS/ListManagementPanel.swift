import SnipSnapCore
import SwiftUI

private struct ListManagementMenu: ViewModifier {
    let model: IOSAppModel
    let deleteList: (UUID) async -> Void
    let createList: () -> Void
    let sourceFocus: (Bool) -> Void
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 56

    func body(content: Content) -> some View {
        content.glassMenu(
            isPresented: Binding(get: { model.isManagingLists }, set: { model.isManagingLists = $0 }),
            layout: .expanding(preferredSize: CGSize(
                width: 420, height: min(520, CGFloat(model.lists.count) * max(56, rowHeight) + 64)
            )),
            label: "List actions", identifier: "list-management-panel", sourceFocus: sourceFocus
        ) { _ in
            ListManagementPanel(model: model, deleteList: deleteList, createList: createList,
                                dismiss: { model.isManagingLists = false })
        }
    }
}

/// List-specific state and actions; the shared host owns presentation.
private struct ListManagementPanel: View {
    let model: IOSAppModel
    let deleteList: (UUID) async -> Void
    let createList: () -> Void
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isSavingOrder = false
    @State private var pendingOrder: [UUID]?
    @State private var deletionTarget: SnipList?
    @State private var confirmsDeletion = false
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 56

    private var displayedLists: [SnipList] {
        guard let pendingOrder else { return model.lists }
        let lists = Dictionary(uniqueKeysWithValues: model.lists.map { ($0.id, $0) })
        let pendingIDs = Set(pendingOrder)
        return pendingOrder.compactMap { lists[$0] }
            + model.lists.filter { !pendingIDs.contains($0.id) }
    }

    private var animation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.08)
    }

    var body: some View {
        panel
            .listDeletionConfirmation(
                list: deletionTarget ?? model.selectedList,
                isPresented: $confirmsDeletion
            ) {
                guard let target = deletionTarget else { return }
                dismiss()
                Task { await deleteList(target.id) }
            }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            List {
                ForEach(displayedLists) { list in
                    listRow(list)
                        .environment(\.layoutDirection, layoutDirection)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 8))
                        .moveDisabled(list.id == SnipList.inboxID)
                }
                .onMove(perform: moveLists)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            // Move the native drag accessory left while preserving the row's
            // original reading direction and action order.
            .environment(\.layoutDirection, .rightToLeft)
            .disabled(isSavingOrder)
            .animation(animation, value: displayedLists.map(\.id))

            Divider().padding(.horizontal, 20)
            Button {
                dismiss()
                createList()
            } label: {
                Label("New List", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("list-management-new")
            .padding(.bottom, 8)
        }
    }

    private func listRow(_ list: SnipList) -> some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
                model.selectList(list.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: list.displaySystemImage)
                        .foregroundStyle(list.accent.color)
                        .frame(width: 24)
                    Text(list.displayName)
                        .foregroundStyle(list.accent.color)
                        .font(.body.weight(model.selectedPage == .list(list.id) ? .semibold : .regular))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, minHeight: max(56, rowHeight))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(model.selectedPage == .list(list.id) ? .isSelected : [])
            .accessibilityIdentifier("list-management-select-\(list.id.uuidString)")
            .accessibilityActions {
                if let index = model.lists.firstIndex(where: { $0.id == list.id }), index > 0 {
                    if index > 1 { Button("Move up") { move(list, by: -1) } }
                    if index < model.lists.count - 1 { Button("Move down") { move(list, by: 1) } }
                }
            }

            if list.id == SnipList.inboxID {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close list manager")
                .accessibilityIdentifier("list-management-close")
            } else {
                Button {
                    dismiss()
                    model.editListInline(id: list.id)
                } label: {
                    Image(systemName: "pencil").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(list.displayName)")
                .accessibilityIdentifier("list-management-edit-\(list.id.uuidString)")

                Button(role: .destructive) {
                    model.haptics.invalidatePendingFeedback()
                    deletionTarget = list
                    confirmsDeletion = true
                } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("Delete \(list.displayName)")
                .accessibilityIdentifier("list-management-delete-\(list.id.uuidString)")
            }
        }
    }

    private func moveLists(from offsets: IndexSet, to destination: Int) {
        let lists = displayedLists
        guard !isSavingOrder, let source = offsets.first, offsets.count == 1,
              lists.indices.contains(source), lists[source].id != SnipList.inboxID else { return }
        var order = lists
        order.move(fromOffsets: offsets, toOffset: max(1, destination))
        pendingOrder = order.map(\.id)
        guard let moved = order.firstIndex(where: { $0.id == lists[source].id }) else { return }
        saveMove(lists[source].id, before: moved + 1 < order.count ? order[moved + 1].id : nil)
    }

    private func move(_ list: SnipList, by offset: Int) {
        let lists = displayedLists
        guard let index = lists.firstIndex(where: { $0.id == list.id }) else { return }
        let destination = index + offset
        guard destination > 0, lists.indices.contains(destination) else { return }
        moveLists(from: IndexSet(integer: index), to: offset < 0 ? destination : destination + 1)
    }

    private func saveMove(_ id: UUID, before destination: UUID?) {
        guard !isSavingOrder else { return }
        isSavingOrder = true
        Task { @MainActor in
            _ = await model.moveList(id: id, before: destination)
            withAnimation(animation) { pendingOrder = nil }
            isSavingOrder = false
        }
    }
}

extension View {
    func listManagementMenu(
        model: IOSAppModel, deleteList: @escaping (UUID) async -> Void, createList: @escaping () -> Void,
        sourceFocus: @escaping (Bool) -> Void
    ) -> some View {
        modifier(ListManagementMenu(model: model, deleteList: deleteList, createList: createList, sourceFocus: sourceFocus))
    }
}
