import SwiftUI

private struct SectionNameAndIconField: View {
    @Binding var name: String
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            SectionIconPicker(selection: $selection)
            TextField("Section name", text: $name)
        }
    }
}

private struct SectionIconPicker: View {
    @Binding var selection: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selection)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 34)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityLabel("Choose section icon, current: \(SectionIconOptions.title(for: selection))")
        .help("Choose Section Icon")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SectionIconBrowser(selection: $selection)
        }
    }
}

private struct SectionIconBrowser: View {
    private struct GridIcon: Identifiable {
        let categoryID: String
        let systemName: String

        var id: String { "\(categoryID):\(systemName)" }
    }

    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var recentIcons = SectionIconOptions.recentIcons()
    @FocusState private var searchIsFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 36, maximum: 36), spacing: 8)]

    private var displayedCategories: [SectionIconCategory] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else {
            guard !recentIcons.isEmpty else { return SectionIconOptions.categories }
            return [SectionIconCategory(title: "Recent", icons: recentIcons)]
                + SectionIconOptions.categories
        }

        return SectionIconOptions.categories.compactMap { category in
            if category.title.localizedCaseInsensitiveContains(cleanQuery) {
                return category
            }

            let icons = category.icons.filter { SectionIconOptions.matches($0, query: cleanQuery) }
            return icons.isEmpty ? nil : SectionIconCategory(title: category.title, icons: icons)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search icons", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchIsFocused)
                .submitScope()
                .padding(12)

            Divider()

            if displayedCategories.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(displayedCategories) { category in
                            Section {
                                ForEach(category.icons.map {
                                    GridIcon(categoryID: category.id, systemName: $0)
                                }) { icon in
                                    iconButton(icon.systemName)
                                }
                            } header: {
                                Text(category.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 10)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 360, height: 420)
        .onAppear {
            query = ""
            recentIcons = SectionIconOptions.recentIcons()
            searchIsFocused = true
        }
    }

    private func iconButton(_ icon: String) -> some View {
        Button {
            selection = icon
            SectionIconOptions.recordRecentIcon(icon)
            dismiss()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selection == icon ? SnipSnapColors.selectionFill : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            selection == icon ? SnipSnapColors.selectionEdge : .clear,
                            lineWidth: 1
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SectionIconOptions.title(for: icon))
        .accessibilityAddTraits(selection == icon ? .isSelected : [])
        .help(SectionIconOptions.title(for: icon))
    }
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
            SectionNameAndIconField(name: $name, selection: $systemImage)
                .textFieldStyle(.automatic)
                .controlSize(.regular)
                .onSubmit(create)
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
        .frame(width: 360)
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
            SectionNameAndIconField(name: $name, selection: $systemImage)
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
        .frame(width: 360)
    }
}
