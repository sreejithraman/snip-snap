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
    private let diagnostics: AppDiagnosticRecorder
    private var activeLibraryChangeAction: ActiveLibraryChangeAction?

    init(
        notice: AppleAccountNotice? = nil,
        handler: (any AppleAccountCacheHandling)? = nil,
        activeLibraryChangeAction: ActiveLibraryChangeAction? = nil,
        diagnostics: AppDiagnosticRecorder = .live
    ) {
        self.notice = handler == nil ? nil : notice
        self.handler = handler
        self.activeLibraryChangeAction = activeLibraryChangeAction
        self.diagnostics = diagnostics
        recordNotice()
    }

    func setActiveLibraryChangeAction(_ action: @escaping ActiveLibraryChangeAction) {
        activeLibraryChangeAction = action
    }

    var showsResolutionActions: Bool {
        notice == .signedOut || notice == .accountChanged
    }

    var title: String {
        switch notice {
        case .paused: String(localized: "Sync paused")
        case .signedOut: String(localized: "Signed out of iCloud")
        case .accountChanged: String(localized: "iCloud account changed")
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
            let refreshedNotice = try await handler.refreshAppleAccountNotice()
            if notice != refreshedNotice {
                notice = refreshedNotice
                recordNotice()
            }
            errorMessage = nil
        } catch is CancellationError {
            // Dismissing an account action does not create a new failure presentation.
        } catch {
            diagnostics.record(.failure(operation: "sync.account_resolve", error: error, visibility: .user))
            errorMessage = String(localized: "Couldn’t save your choice. Try again.")
        }
    }

    func refresh() async {
        guard !isResolving else { return }
        do {
            try await refreshCheckingAccount()
        } catch {
            if !(error is CancellationError) {
                diagnostics.record(.failure(operation: "sync.account_refresh", error: error, visibility: .background))
            }
            // Keep the last safe state. Account lookup failures must not prompt removal.
        }
    }

    /// Readiness must observe lookup failures and adopt the checked library before publishing.
    func refreshCheckingAccount(notifyActiveLibraryChange: Bool = true) async throws {
        guard let handler else { return }
        let priorNotice = notice
        let refreshedNotice = try await handler.refreshAppleAccountNotice()
        notice = refreshedNotice
        if priorNotice != refreshedNotice { recordNotice() }
        if notifyActiveLibraryChange,
           Self.changesActiveLibrary(priorNotice) || Self.changesActiveLibrary(refreshedNotice) {
            try await activeLibraryChangeAction?()
        }
        errorMessage = nil
    }

    private static func changesActiveLibrary(_ notice: AppleAccountNotice?) -> Bool {
        notice == .signedOut || notice == .accountChanged
    }

    private func recordNotice() {
        let issue: SyncedContentSyncIssue
        switch notice {
        case .paused: issue = .checkingAccount
        case .signedOut: issue = .signInRequired
        case .accountChanged: issue = .iCloudAccountChanged
        case nil: return
        }
        diagnostics.record(.failure(
            operation: "sync.account_status", errorCode: issue.diagnosticCode, visibility: .user
        ))
    }
}
