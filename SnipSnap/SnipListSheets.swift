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
                SnipListMarkView(
                    mark: ListIconSymbol.pickerMark(for: selection),
                    appearance: SnipListAppearance(preset: nil),
                    diameter: 20
                )

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
        SnipListIconOptions.displayedCategories(query: query, recentIcons: recentIcons)
    }

    var body: some View {
        VStack(spacing: 0) {
            ListIconSearchField(query: $query)
                .focused($searchIsFocused)
                .submitScope()
                .padding(12)

            Divider()

            if displayedCategories.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SnipListNoIconButton(selection: $selection) { dismiss() }
                            .padding([.horizontal, .top], 12)
                    }
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
                                    .appFont(.caption, weight: .semibold)
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
        .frame(width: 360, height: 340)
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
                        .fill(selection == icon ? SnipSnapTheme.selectionFill : .clear)
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
    let movingIDs: Set<UUID>
    @State private var name = ""
    @State private var systemImage = ""
    @State private var color: SnipListColorPreset?

    var body: some View {
        VStack(alignment: .leading) {
            Text("New list")
                .font(AppTypography.font(size: 15, weight: .semibold))
            SnipListNameAndIconField(name: $name, selection: $systemImage)
                .tint(SnipListAppearance(preset: color).color)
                .textFieldStyle(.automatic)
                .controlSize(.regular)
                .onSubmit(create)
            SnipListColorPicker(selection: $color)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                AppPrimaryActionButton { create() } label: {
                    Text("Create")
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private func create() {
        let list = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !list.isEmpty else { return }
        Task {
            guard await model.createList(
                name: list,
                systemImage: systemImage,
                color: color,
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
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name: String
    @State private var systemImage: String
    @State private var color: SnipListColorPreset?
    @State private var showsIcons = false
    @State private var isSaving = false
    @FocusState private var nameIsFocused: Bool

    init(model: AppModel, list: SnipList, dismiss: @escaping () -> Void) {
        self.model = model
        self.list = list
        self.dismiss = dismiss
        _name = State(initialValue: list.name)
        _systemImage = State(initialValue: list.systemImage)
        _color = State(initialValue: list.color)
    }

    /// The list as it will look once saved.
    private var preview: SnipList {
        var preview = list
        if !cleanedName.isEmpty { preview.name = cleanedName }
        preview.systemImage = systemImage
        preview.color = color
        return preview
    }
    private var appearance: SnipListAppearance { preview.accent }
    private var cleanedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.paneContentInset) {
            Text("Edit list")
                .appFont(.headline)

            HStack(spacing: SnipSnapSpacing.paneContentInset) {
                Button { showsIcons = true } label: {
                    SnipListMarkView(list: preview, diameter: 40)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: systemImage)
                        .frame(width: 64, height: 64)
                        .background(appearance.selectionFill, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil.circle.fill")
                                .appFont(.body)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.primary, .background)
                                .offset(x: 4, y: 4)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose list icon, current: \(SnipListIconOptions.title(for: systemImage))")
                .help("Choose List Icon")
                .popover(isPresented: $showsIcons, arrowEdge: .bottom) {
                    SnipListIconBrowser(selection: $systemImage)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(cleanedName.isEmpty ? list.displayName : cleanedName)
                        .appFont(.title2, weight: .bold)
                        .lineLimit(2)
                        .foregroundStyle(appearance.color)
                    Text("Choose a look for your list.")
                        .appFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)

            VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
                Text("Name").appFont(.subheadline, weight: .semibold)
                TextField("List name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($nameIsFocused)
                    .accessibilityLabel("List name")
                    .onSubmit(save)
            }

            SnipListColorPicker(selection: $color, automatic: SnipList.automaticColor(for: list.id))

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                AppPrimaryActionButton(action: save) {
                    Text(isSaving ? "Saving…" : "Save")
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleanedName.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(SnipSnapSpacing.paneContentInset)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .onAppear { nameIsFocused = true }
    }

    private func save() {
        guard !isSaving, !cleanedName.isEmpty else { return }
        isSaving = true
        Task {
            if await model.updateList(list, name: cleanedName, systemImage: systemImage, color: .set(color)) {
                dismiss()
            }
            isSaving = false
        }
    }
}
