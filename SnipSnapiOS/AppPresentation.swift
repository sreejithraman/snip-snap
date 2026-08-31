import Foundation
import SnipSnapCore

enum AppSheet: Identifiable, Hashable {
    case editSnip(id: UUID)
    case newList
    case editList(id: UUID)
    case settings
    case recoveryCenter
    case recoverSnip(id: UUID)
    case recoverList(id: UUID)

    var id: String {
        switch self {
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

extension AppleAccountNoticeModel {
    var title: String {
        switch notice {
        case .paused: String(localized: "iCloud Sync Paused")
        case .signedOut: String(localized: "Signed Out of iCloud")
        case .accountChanged: String(localized: "Apple Account Changed")
        case nil: ""
        }
    }

    var message: String {
        switch notice {
        case .paused:
            String(localized: "Your synced cache is still on this device. Snip Snap will try again when iCloud is available.")
        case .signedOut, .accountChanged:
            String(localized: "Snip Snap kept the prior account’s cache apart. Keep it as a local copy or remove it from this device.")
        case nil:
            ""
        }
    }

}
