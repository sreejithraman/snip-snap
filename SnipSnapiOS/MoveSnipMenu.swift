import SnipSnapCore
import SwiftUI

struct MoveSnipMenu: View {
    let model: IOSAppModel
    let snip: Snip

    var body: some View {
        if model.lists.contains(where: { $0.id != snip.listID }) {
            Menu("Move to List", systemImage: "folder") {
                ForEach(model.lists.filter { $0.id != snip.listID }) { list in
                    Button(list.displayName) {
                        Task { await model.moveSnip(id: snip.id, to: list.id) }
                    }
                    .accessibilityIdentifier("move-to-\(list.name)")
                }
            }
            .accessibilityIdentifier("move-snip")
        }
    }
}
