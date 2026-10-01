import SnipSnapCore
import SwiftUI

/// Both item and selection menus offer the same destination and creation actions.
struct MoveDestinationOptions: View {
    let destinations: [SnipList]
    let identifierPrefix: String
    let move: (UUID) -> Void
    let addList: () -> Void

    var body: some View {
        ForEach(destinations) { list in
            Button { move(list.id) } label: {
                ListDestinationLabel(list: list)
            }
            .accessibilityIdentifier("\(identifierPrefix)\(list.name)")
        }
        if !destinations.isEmpty { Divider() }
        Button("Add List…", systemImage: "plus") { addList() }
            .accessibilityIdentifier("add-list-for-move")
    }
}

struct MoveSnipMenu: View {
    let model: IOSAppModel
    let snip: Snip

    var body: some View {
        Menu("Move to…", systemImage: "folder") {
            MoveDestinationOptions(
                destinations: model.moveDestinations(for: [snip]),
                identifierPrefix: "move-to-",
                move: { listID in Task { await model.moveSnip(id: snip.id, to: listID) } },
                addList: { model.requestNewListMove(snips: [snip]) }
            )
        }
        .accessibilityIdentifier("move-snip")
    }
}
