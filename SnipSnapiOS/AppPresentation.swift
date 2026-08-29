import Foundation
import Observation
import SnipSnapCore

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
        case .paused: "iCloud Sync Paused"
        case .signedOut: "Signed Out of iCloud"
        case .accountChanged: "Apple Account Changed"
        case nil: ""
        }
    }

    var message: String {
        switch notice {
        case .paused:
            "Your synced cache is still on this device. Snip Snap will try again when iCloud is available."
        case .signedOut, .accountChanged:
            "Snip Snap kept the prior account’s cache apart. Keep it as a local copy or remove it from this device."
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
            errorMessage = "Snip Snap could not finish that choice. Please try again."
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
