import SnipSnapCore
import SwiftUI

struct IOSAppRootView: View {
    @State private var model: IOSAppModel
    @State private var sheet: AppSheet?

    init(
        library: any SnipLibrary,
        initialSnapshot: SnipLibrarySnapshot? = nil,
        startupError: String? = nil
    ) {
        _model = State(
            initialValue: IOSAppModel(
                library: library,
                initialSnapshot: initialSnapshot ?? SnipLibrarySnapshot(snips: [], lists: [.inbox]),
                startupError: startupError
            )
        )
    }

    var body: some View {
        NavigationSplitView {
            ListSidebarView(model: model, sheet: $sheet)
        } content: {
            SnipCollectionView(model: model, sheet: $sheet)
        } detail: {
            SnipDetailView(model: model, sheet: $sheet)
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .newSnip(let listID):
                SnipEditorView(model: model, mode: .create(listID: listID))
            case .editSnip(let id):
                SnipEditorView(model: model, mode: .edit(id: id))
            case .newList:
                ListEditorView(model: model, mode: .create)
            case .editList(let id):
                ListEditorView(model: model, mode: .edit(id: id))
            }
        }
        .alert(
            "Snip Snap Needs Attention",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Please try again.")
        }
        .task {
            await model.load()
        }
    }
}

#Preview("iPad Library") {
    IOSAppRootView(
        library: PreviewSnipLibrary.snapshot,
        initialSnapshot: .preview
    )
}

#Preview("Empty iPhone") {
    IOSAppRootView(library: PreviewSnipLibrary.empty)
}
