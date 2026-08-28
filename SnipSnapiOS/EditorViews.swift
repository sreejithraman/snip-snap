import SnipSnapCore
import SwiftUI

enum SnipEditorMode {
    case create(listID: UUID)
    case edit(id: UUID)
}

struct SnipEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let model: IOSAppModel
    let mode: SnipEditorMode
    @State private var content = ""
    @State private var isSaving = false

    private var title: String {
        switch mode {
        case .create: "New Snip"
        case .edit: "Edit Snip"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextEditor(text: $content)
                        .frame(minHeight: 180)
                        .accessibilityIdentifier("snip-text")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-snip")
                }
            }
            .onAppear {
                if case .edit(let id) = mode {
                    content = model.snips.first(where: { $0.id == id })?.content ?? ""
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        let succeeded: Bool
        switch mode {
        case .create(let listID):
            succeeded = await model.createSnip(content: content, in: listID)
        case .edit(let id):
            guard let snip = model.snips.first(where: { $0.id == id }) else {
                isSaving = false
                return
            }
            succeeded = await model.editSnip(snip, content: content)
        }
        isSaving = false
        if succeeded { dismiss() }
    }
}

enum ListEditorMode {
    case create
    case edit(id: UUID)
}

struct ListEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let model: IOSAppModel
    let mode: ListEditorMode
    @State private var name = ""
    @State private var isSaving = false

    private var title: String {
        switch mode {
        case .create: "New List"
        case .edit: "Rename List"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("List name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("list-name")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-list")
                }
            }
            .onAppear {
                if case .edit(let id) = mode {
                    name = model.lists.first(where: { $0.id == id })?.name ?? ""
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        let succeeded: Bool
        switch mode {
        case .create:
            succeeded = await model.createList(name: name)
        case .edit(let id):
            guard let list = model.lists.first(where: { $0.id == id }) else {
                isSaving = false
                return
            }
            succeeded = await model.renameList(list, name: name)
        }
        isSaving = false
        if succeeded { dismiss() }
    }
}
