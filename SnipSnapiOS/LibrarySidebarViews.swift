import SnipSnapCore
import SwiftUI

struct ListSidebarView: View {
    let model: IOSAppModel
    @Binding var sheet: AppSheet?
    @Binding var editMode: EditMode
    var importBackup: () -> Void = {}

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedListID },
            set: { id in
                guard let id else { return }
                model.selectList(id)
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            if model.recoverySnapshot.needsAttentionCount > 0 {
                Section {
                    Button {
                        sheet = .recoveryCenter
                    } label: {
                        Label("Needs Attention", systemImage: "exclamationmark.bubble")
                    }
                    .badge(model.recoverySnapshot.needsAttentionCount)
                    .accessibilityIdentifier("needs-attention")
                }
            }
            ForEach(model.lists) { list in
                NavigationLink(value: list.id) {
                    Label {
                        Text(list.displayName)
                    } icon: {
                        Image(systemName: list.systemImage).foregroundStyle(list.accent.color)
                    }
                }
                .tint(list.accent.color)
                .tag(list.id)
                .accessibilityIdentifier("list-\(list.name)")
                .listContextActions(
                    list: list,
                    edit: { sheet = .editList(id: list.id) },
                    delete: { Task { await model.deleteList(id: list.id) } }
                )
            }
        }
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryActionsMenu(
                    model: model,
                    importBackup: importBackup,
                    settings: { sheet = .settings },
                    editMode: $editMode,
                    reviewRecoveredEdits: model.recoverySnapshot.needsAttentionCount > 0
                        ? { sheet = .recoveryCenter }
                        : nil,
                    editSelectedList: { sheet = .editList(id: model.selectedListID) }
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New List", systemImage: "folder.badge.plus") {
                    sheet = .newList
                }
                .accessibilityIdentifier("new-list")
            }
            if model.isCloudSyncActive {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    CloudLibraryActions(model: model)
                }
            }
        }
    }
}

struct LibraryActionsMenu: View {
    let model: IOSAppModel
    let importBackup: () -> Void
    let settings: () -> Void
    @Binding var editMode: EditMode
    var includesCloudActions = false
    var reviewRecoveredEdits: (() -> Void)?
    var editSelectedList: (() -> Void)?
    @State private var confirmsDeleteList = false

    var body: some View {
        Menu("Library Actions", systemImage: "ellipsis") {
            Button(
                editMode.isEditing ? "Done Selecting" : "Select Snips",
                systemImage: editMode.isEditing ? "checkmark" : "checkmark.circle"
            ) {
                model.selectedSnipIDs = []
                editMode = editMode.isEditing ? .inactive : .active
            }
            .disabled(!editMode.isEditing && model.visibleSnips.isEmpty)
            .accessibilityIdentifier("select-snips")
            Divider()
            if model.selectedListID != SnipList.inboxID, let editSelectedList {
                Button("Edit List…", systemImage: "pencil", action: editSelectedList)
                Button("Delete List", systemImage: "trash", role: .destructive) {
                    confirmsDeleteList = true
                }
                Divider()
            }
            Button("Import Backup…", systemImage: "square.and.arrow.down", action: importBackup)
            Button("Settings", systemImage: "gearshape", action: settings)
                .accessibilityIdentifier("settings")
            if let reviewRecoveredEdits {
                Button("Needs Attention", systemImage: "exclamationmark.bubble", action: reviewRecoveredEdits)
                    .accessibilityIdentifier("needs-attention")
            }
            if includesCloudActions, model.isCloudSyncActive {
                Divider()
                CloudLibraryActions(model: model)
            }
        }
        .accessibilityIdentifier("library-actions")
        .listDeletionConfirmation(list: model.selectedList, isPresented: $confirmsDeleteList) {
            Task { await model.deleteList(id: model.selectedListID) }
        }
    }
}

private struct CloudLibraryActions: View {
    let model: IOSAppModel

    var body: some View {
        Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
            Task { await model.syncWhenPossible() }
        }
        .accessibilityIdentifier("sync-icloud-now")
        Button("Clear Downloaded Files", systemImage: "icloud.and.arrow.down") {
            Task { await model.clearDownloadedFiles() }
        }
        .accessibilityIdentifier("clear-icloud-downloads")
    }
}

private struct ListContextActions: ViewModifier {
    let list: SnipList
    let edit: () -> Void
    let delete: () -> Void
    @State private var confirmsDeletion = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if list.id != SnipList.inboxID {
                    Button("Edit List…", systemImage: "pencil", action: edit)
                    Divider()
                    Button("Delete List", systemImage: "trash", role: .destructive) {
                        confirmsDeletion = true
                    }
                }
            }
            .listDeletionConfirmation(list: list, isPresented: $confirmsDeletion, delete: delete)
    }
}

extension View {
    func listContextActions(list: SnipList, edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        modifier(ListContextActions(list: list, edit: edit, delete: delete))
    }

    func listDeletionConfirmation(list: SnipList, isPresented: Binding<Bool>, delete: @escaping () -> Void) -> some View {
        confirmationDialog("Delete \(list.displayName)?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Delete List", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its snips will move to Inbox.")
        }
    }
}
