import Foundation

enum AppSheet: Identifiable, Hashable {
    case newSnip(listID: UUID)
    case editSnip(id: UUID)
    case newList
    case editList(id: UUID)

    var id: String {
        switch self {
        case .newSnip:
            "new-snip"
        case .editSnip(let id):
            "edit-snip-\(id)"
        case .newList:
            "new-list"
        case .editList(let id):
            "edit-list-\(id)"
        }
    }
}
