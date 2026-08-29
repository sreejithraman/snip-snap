import Foundation

enum AppSheet: Identifiable, Hashable {
    case newSnip(listID: UUID)
    case editSnip(id: UUID)
    case newList
    case editList(id: UUID)
    case settings
    case recoveryCenter
    case recoverSnip(id: UUID)
    case recoverList(id: UUID)

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
        case .settings:
            "settings"
        case .recoveryCenter:
            "recovery-center"
        case .recoverSnip(let id):
            "recover-snip-\(id)"
        case .recoverList(let id):
            "recover-list-\(id)"
        }
    }
}
