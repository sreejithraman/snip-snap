import Foundation
import Observation
import SnipSnapCore

@MainActor
@Observable
final class AppleAccountNoticeModel {
    typealias ActiveLibraryChangeAction = @MainActor @Sendable () async throws -> Void

    /// Kept apart from `notice`: a readiness check can change the notice while a choice resolves.
    private enum CacheChoicePhase: Equatable {
        case ready
        case failed
        case resolving(UUID, showsPriorFailure: Bool)
    }

    private(set) var notice: AppleAccountNotice?
    private var cacheChoice = CacheChoicePhase.ready
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

    var isResolving: Bool {
        if case .resolving = cacheChoice { return true }
        return false
    }

    var errorMessage: String? {
        switch cacheChoice {
        case .failed, .resolving(_, showsPriorFailure: true):
            return String(localized: "Couldn’t save your choice. Try again.")
        case .ready, .resolving:
            return nil
        }
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
        let token = UUID()
        cacheChoice = .resolving(token, showsPriorFailure: cacheChoice == .failed)
        do {
            try await handler.resolveAppleAccountCache(choice)
            try await activeLibraryChangeAction?()
            let refreshedNotice = try await handler.refreshAppleAccountNotice()
            if notice != refreshedNotice {
                notice = refreshedNotice
                recordNotice()
            }
            finishResolving(token, failed: false)
        } catch is CancellationError {
            // Dismissing an account action does not create a new failure presentation.
            cancelResolving(token)
        } catch {
            diagnostics.record(.failure(operation: "sync.account_resolve", error: error, visibility: .user))
            finishResolving(token, failed: true)
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
        clearCacheChoiceFailure()
    }

    private func finishResolving(_ token: UUID, failed: Bool) {
        guard case .resolving(token, _) = cacheChoice else { return }
        cacheChoice = failed ? .failed : .ready
    }

    private func cancelResolving(_ token: UUID) {
        guard case .resolving(token, let showsPriorFailure) = cacheChoice else { return }
        cacheChoice = showsPriorFailure ? .failed : .ready
    }

    private func clearCacheChoiceFailure() {
        switch cacheChoice {
        case .failed:
            cacheChoice = .ready
        case .resolving(let token, showsPriorFailure: true):
            cacheChoice = .resolving(token, showsPriorFailure: false)
        case .ready, .resolving:
            break
        }
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
