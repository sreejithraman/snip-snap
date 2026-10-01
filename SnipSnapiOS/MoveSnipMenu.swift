import SnipSnapCore
import SwiftUI

struct MoveSnipMenu: View {
    let model: IOSAppModel
    let snip: Snip

    var body: some View {
        ListDestinationMenu(
            lists: model.lists,
            purpose: .move(sourceListIDs: [snip.listID]),
            identifierPrefix: "move-to-"
        ) { destinationID in
            Task { await model.moveSnip(id: snip.id, to: destinationID) }
        }
        .accessibilityIdentifier("move-snip")
    }
}
