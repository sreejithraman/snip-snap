import SwiftUI
import SnipSnapCore

private struct SnipListNameAndIconField: View {
    @Binding var name: String
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            SnipListIconPicker(selection: $selection)
            TextField("List name", text: $name)
        }
    }
}

private struct SnipListIconPicker: View {
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
        .accessibilityLabel("Choose list icon, current: \(SnipListIconOptions.title(for: selection))")
        .help("Choose List Icon")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SnipListIconBrowser(selection: $selection)
        }
    }
}

private struct SnipListIconBrowser: View {
    private struct GridIcon: Identifiable {
        let categoryID: String
        let systemName: String

        var id: String { "\(categoryID):\(systemName)" }
    }

    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var recentIcons = SnipListIconOptions.recentIcons()
    @FocusState private var searchIsFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 36, maximum: 36), spacing: 8)]

    private var displayedCategories: [SnipListIconCategory] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else {
            guard !recentIcons.isEmpty else { return SnipListIconOptions.categories }
            return [SnipListIconCategory(title: "Recent", icons: recentIcons)]
                + SnipListIconOptions.categories
        }

        return SnipListIconOptions.categories.compactMap { category in
            if category.title.localizedCaseInsensitiveContains(cleanQuery) {
                return category
            }

            let icons = category.icons.filter { SnipListIconOptions.matches($0, query: cleanQuery) }
            return icons.isEmpty ? nil : SnipListIconCategory(title: category.title, icons: icons)
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
            recentIcons = SnipListIconOptions.recentIcons()
            searchIsFocused = true
        }
    }

    private func iconButton(_ icon: String) -> some View {
        let edge = selection == icon ? PanelEdgeStyle.selected : .hidden
        return Button {
            selection = icon
            SnipListIconOptions.recordRecentIcon(icon)
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
                            edge.color,
                            lineWidth: edge.width
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SnipListIconOptions.title(for: icon))
        .accessibilityAddTraits(selection == icon ? .isSelected : [])
        .help(SnipListIconOptions.title(for: icon))
    }
}

struct NewSnipListSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    let movesSelection: Bool
    @State private var name = ""
    @State private var systemImage = "circle.grid.2x2.fill"

    var body: some View {
        VStack(alignment: .leading) {
            Text("New list")
                .font(.system(size: 15, weight: .semibold))
            SnipListNameAndIconField(name: $name, selection: $systemImage)
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
        let list = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !list.isEmpty else { return }
        let movingIDs = movesSelection ? model.selection : []
        Task {
            guard await model.createList(
                name: list,
                systemImage: systemImage,
                movingIDs: movingIDs
            ) else { return }
            name = ""
            isPresented = false
        }
    }
}

struct SnipListEditSheet: View {
    @ObservedObject var model: AppModel
    let list: SnipList
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var systemImage: String

    init(model: AppModel, list: SnipList) {
        self.model = model
        self.list = list
        _name = State(initialValue: list.name)
        _systemImage = State(initialValue: list.systemImage)
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Edit list").font(.headline)
            SnipListNameAndIconField(name: $name, selection: $systemImage)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        if await model.updateList(list, name: name, systemImage: systemImage) {
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
