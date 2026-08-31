import Foundation
import Observation
import SnipSnapCore

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

@MainActor
@Observable
final class AppleAccountNoticeModel {
    private(set) var notice: AppleAccountNotice?
    private(set) var isResolving = false
    private(set) var errorMessage: String?
    private let handler: (any AppleAccountCacheHandling)?

    init(
        notice: AppleAccountNotice? = nil,
        handler: (any AppleAccountCacheHandling)? = nil
    ) {
        self.notice = handler == nil ? nil : notice
        self.handler = handler
    }

    var title: String {
        switch notice {
        case .paused: String(localized: .iCloudSyncPaused)
        case .signedOut: String(localized: .signedOutOfICloud)
        case .accountChanged: String(localized: .appleAccountChanged)
        case nil: ""
        }
    }

    var message: String {
        switch notice {
        case .paused:
            String(localized: .yourSyncedCacheIsStillOnThisDeviceSnipSnapWillTryAgainWhenICloudIsAvailable)
        case .signedOut, .accountChanged:
            String(localized: .snipSnapKeptThePriorAccountsCacheApartKeepItAsALocalCopyOrRemoveItFromThisDevice)
        case nil:
            ""
        }
    }

    var showsResolutionActions: Bool {
        notice == .signedOut || notice == .accountChanged
    }

    func resolve(_ choice: AppleAccountCacheChoice) async {
        guard let handler, notice != nil, !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            try await handler.resolveAppleAccountCache(choice)
            notice = try await handler.refreshAppleAccountNotice()
            errorMessage = nil
        } catch {
            errorMessage = String(localized: .snipSnapCouldNotFinishThatChoicePleaseTryAgain)
        }
    }

    func refresh() async {
        guard let handler, !isResolving else { return }
        do {
            notice = try await handler.refreshAppleAccountNotice()
            errorMessage = nil
        } catch {
            // Keep the last safe state. Account lookup failures must not prompt removal.
        }
    }
}
