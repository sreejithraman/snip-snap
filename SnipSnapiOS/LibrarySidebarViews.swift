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
                    Label(list.displayName, systemImage: list.systemImage)
                }
                .tag(list.id)
                .accessibilityIdentifier("list-\(list.name)")
                .contextMenu {
                    if list.id != SnipList.inboxID {
                        Button("Edit List") { sheet = .editList(id: list.id) }
                        Button("Delete", role: .destructive) {
                            Task { await model.deleteList(id: list.id) }
                        }
                    }
                }
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
        Menu("Library Actions", systemImage: "ellipsis.circle") {
            Button("Settings", systemImage: "gearshape", action: settings)
                .accessibilityIdentifier("settings")
            Button(
                editMode.isEditing ? "Done Selecting" : "Select Snips",
                systemImage: editMode.isEditing ? "checkmark" : "checkmark.circle"
            ) {
                editMode = editMode.isEditing ? .inactive : .active
            }
            .disabled(!editMode.isEditing && model.visibleSnips.isEmpty)
            .accessibilityIdentifier("select-snips")
            Divider()
            if let reviewRecoveredEdits {
                Button {
                    reviewRecoveredEdits()
                } label: {
                    Label("Needs Attention", systemImage: "exclamationmark.bubble")
                }
                .accessibilityIdentifier("needs-attention")
                Divider()
            }
            Button("Import Backup…", systemImage: "square.and.arrow.down", action: importBackup)
            if model.selectedListID != SnipList.inboxID, let editSelectedList {
                Divider()
                Button("Edit List", systemImage: "pencil", action: editSelectedList)
                Button("Delete List", systemImage: "trash", role: .destructive) {
                    confirmsDeleteList = true
                }
            }
            if includesCloudActions, model.isCloudSyncActive {
                Divider()
                CloudLibraryActions(model: model)
            }
        }
        .accessibilityIdentifier("library-actions")
        .alert("Delete \(model.selectedList.name)?", isPresented: $confirmsDeleteList) {
            Button("Cancel", role: .cancel) {}
            Button("Delete List", role: .destructive) {
                Task { await model.deleteList(id: model.selectedListID) }
            }
        } message: {
            Text("The list will be removed. Its snips will move to Inbox.")
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
