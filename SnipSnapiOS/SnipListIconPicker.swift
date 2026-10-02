import SwiftUI

private struct ListGridIcon: Identifiable {
    let categoryID: String
    let systemName: String

    var id: String { "\(categoryID):\(systemName)" }
}

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
                Image(systemName: ListIconSymbol.supportedName(selection)).foregroundStyle(accent)
            }
        }
        .accessibilityIdentifier("choose-list-icon")
        .accessibilityLabel(
            "Choose list icon, current: \(SnipListIconOptions.title(for: selection))"
        )
    }
}

struct SnipListIconBrowser: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            ListIconSearchField(query: $query)
                .padding(SnipSnapSpacing.paneContentInset)
            ScrollView {
                ListIconGrid(selection: $selection, query: query) { dismiss() }
                    .padding(SnipSnapSpacing.paneContentInset)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("list-icon-results")
        }
        .navigationTitle("Choose List Icon")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct InlineListIconPicker: View {
    @Binding var selection: String
    @Binding var query: String
    var searchFocus: FocusState<ListAppearanceField?>.Binding

    var body: some View {
        ScrollView { iconGrid }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("list-icon-results")
            .safeAreaBar(edge: .top, spacing: 0) { searchField }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private var searchField: some View {
        ListIconSearchField(query: $query, focus: searchFocus, usesGlassBackground: true)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SnipSnapSpacing.paneContentInset)
            .padding(.bottom, SnipSnapSpacing.relatedContent)
    }

    private var iconGrid: some View {
        ListIconGrid(selection: $selection, query: query)
            .padding(.horizontal, SnipSnapSpacing.paneContentInset)
    }
}

struct ListIconGrid: View {
    @Binding var selection: String
    let query: String
    var didSelect: () -> Void = {}
    @State private var recentIcons = SnipListIconOptions.recentIcons()

    var body: some View {
        let categories = SnipListIconOptions.displayedCategories(query: query, recentIcons: recentIcons)
        if categories.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                ForEach(categories) { category in
                    Section {
                        ForEach(category.icons.map {
                            ListGridIcon(categoryID: category.id, systemName: $0)
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
            .onAppear { recentIcons = SnipListIconOptions.recentIcons() }
        }
    }

    private func iconButton(_ icon: String) -> some View {
        let isSelected = selection == icon
        return Button {
            selection = icon
            SnipListIconOptions.recordRecentIcon(icon)
            didSelect()
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background {
                    if isSelected {
                        SnipListSelectionLens()
                    }
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
