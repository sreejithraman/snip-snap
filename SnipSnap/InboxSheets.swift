import SwiftUI

private enum SectionIconOptions {
    static let all = [
        "circle.grid.2x2.fill", "bookmark.fill", "star.fill", "bolt.fill",
        "briefcase.fill", "hammer.fill", "doc.text.fill", "terminal.fill"
    ]
}

struct InboxNewSectionSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    let movesSelection: Bool
    @State private var name = ""
    @State private var systemImage = "circle.grid.2x2.fill"

    var body: some View {
        VStack(alignment: .leading) {
            Text("New section")
                .font(.system(size: 15, weight: .semibold))
            TextField("Section name", text: $name)
                .textFieldStyle(.automatic)
                .controlSize(.regular)
                .onSubmit(create)
            Picker("Icon", selection: $systemImage) {
                ForEach(SectionIconOptions.all, id: \.self) { icon in
                    Label(icon, systemImage: icon).tag(icon)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func create() {
        let section = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !section.isEmpty else { return }
        let movingIDs = movesSelection ? model.selection : []
        Task {
            guard await model.createSection(
                name: section,
                systemImage: systemImage,
                movingIDs: movingIDs
            ) else { return }
            name = ""
            isPresented = false
        }
    }
}

struct SectionEditSheet: View {
    @ObservedObject var model: AppModel
    let section: SnipSnapSection
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var systemImage: String

    init(model: AppModel, section: SnipSnapSection) {
        self.model = model
        self.section = section
        _name = State(initialValue: section.name)
        _systemImage = State(initialValue: section.systemImage)
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Edit section").font(.headline)
            TextField("Section name", text: $name)
            Picker("Icon", selection: $systemImage) {
                ForEach(SectionIconOptions.all, id: \.self) { icon in
                    Label(icon, systemImage: icon).tag(icon)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        if await model.updateSection(section, name: name, systemImage: systemImage) {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
    }
}
