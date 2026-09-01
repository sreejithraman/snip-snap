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

    var id: Self { self }
}

extension AppleAccountNoticeModel {
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
