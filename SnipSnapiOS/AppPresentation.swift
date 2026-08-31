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
    typealias ActiveLibraryChangeAction = @MainActor @Sendable () async throws -> Void

    private(set) var notice: AppleAccountNotice?
    private(set) var isResolving = false
    private(set) var errorMessage: String?
    private let handler: (any AppleAccountCacheHandling)?
    private var activeLibraryChangeAction: ActiveLibraryChangeAction?

    init(
        notice: AppleAccountNotice? = nil,
        handler: (any AppleAccountCacheHandling)? = nil,
        activeLibraryChangeAction: ActiveLibraryChangeAction? = nil
    ) {
        self.notice = handler == nil ? nil : notice
        self.handler = handler
        self.activeLibraryChangeAction = activeLibraryChangeAction
    }

    func setActiveLibraryChangeAction(_ action: @escaping ActiveLibraryChangeAction) {
        activeLibraryChangeAction = action
    }

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

    var showsResolutionActions: Bool {
        notice == .signedOut || notice == .accountChanged
    }

    func resolve(_ choice: AppleAccountCacheChoice) async {
        guard let handler, notice != nil, !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            try await handler.resolveAppleAccountCache(choice)
            try await activeLibraryChangeAction?()
            notice = try await handler.refreshAppleAccountNotice()
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Snip Snap could not finish that choice. Please try again.")
        }
    }

    func refresh() async {
        guard let handler, !isResolving else { return }
        do {
            let priorNotice = notice
            let refreshedNotice = try await handler.refreshAppleAccountNotice()
            notice = refreshedNotice
            if Self.changesActiveLibrary(priorNotice) || Self.changesActiveLibrary(refreshedNotice) {
                try await activeLibraryChangeAction?()
            }
            errorMessage = nil
        } catch {
            // Keep the last safe state. Account lookup failures must not prompt removal.
        }
    }

    private static func changesActiveLibrary(_ notice: AppleAccountNotice?) -> Bool {
        notice == .signedOut || notice == .accountChanged
    }
}
