import Observation
import SnipSnapCore

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

    var showsResolutionActions: Bool {
        notice == .signedOut || notice == .accountChanged
    }

    var title: String {
        switch notice {
        case .paused: String(localized: "iCloud Sync Paused")
        case .signedOut: String(localized: "Signed Out of iCloud")
        case .accountChanged: String(localized: "Apple Account Changed")
        case nil: ""
        }
    }

    var systemImage: String {
        notice == .paused ? "icloud.slash" : "person.crop.circle.badge.exclamationmark"
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
