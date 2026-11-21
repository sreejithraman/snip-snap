import Foundation
import SnipSnapCore

enum AppSheet: Identifiable, Hashable {
    case settings
    case recoveryCenter
    case recoverSnip(id: UUID)
    case recoverList(id: UUID)

    var id: Self { self }
}
