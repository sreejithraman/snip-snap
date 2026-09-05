import SwiftUI

struct SnipListIconPicker: View {
    @Binding var selection: String
    var accent: Color = .primary

    var body: some View {
        NavigationLink {
            SnipListIconBrowser(selection: $selection)
        } label: {
            Label {
                Text("Icon")
            } icon: {
                Image(systemName: selection).foregroundStyle(accent)
            }
        }
        .accessibilityIdentifier("choose-list-icon")
        .accessibilityLabel(
            "Choose list icon, current: \(SnipListIconOptions.title(for: selection))"
        )
    }
}

struct SnipListIconBrowser: View {
    private struct GridIcon: Identifiable {
        let categoryID: String
        let systemName: String

        var id: String { "\(categoryID):\(systemName)" }
    }

    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var recentIcons = SnipListIconOptions.recentIcons()

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 12)]

    private var displayedCategories: [SnipListIconCategory] {
        SnipListIconOptions.displayedCategories(query: query, recentIcons: recentIcons)
    }

    var body: some View {
        Group {
            if displayedCategories.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
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
                                    .padding(.top, 8)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(SnipSnapSpacing.paneContentInset)
                }
            }
        }
        .navigationTitle("Choose List Icon")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search icons")
        .onAppear {
            recentIcons = SnipListIconOptions.recentIcons()
        }
    }

    private func iconButton(_ icon: String) -> some View {
        let isSelected = selection == icon
        return Button {
            selection = icon
            SnipListIconOptions.recordRecentIcon(icon)
            dismiss()
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? SnipSnapTheme.compactSelectionFill : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isSelected ? SnipSnapTheme.emphasizedGlassEdge : .clear,
                            lineWidth: isSelected ? 2 : 0
                        )
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SnipListIconOptions.title(for: icon))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("list-icon-\(icon)")
    }
}
