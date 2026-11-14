import Foundation

/// One app model's snackbar and error presentation (ADR 0023).
///
/// The snackbar, the presented failure, open error details, and the retained
/// Retry Undo have overlapping lifetimes, so each is a separate component.
/// Only these events change them.
struct SnackbarAndErrorPresentation {
    private enum Failure {
        case none
        /// No longer presented, but still reachable from Error details.
        case recorded(AppFailure)
        /// `title` is the caller's explicit title, if any.
        case presented(AppFailure, surface: AppFailure.Surface, title: String?)
    }

    private struct RetryUndo {
        let failure: AppFailure
        let undo: AppToast
    }

    private(set) var snackbar: AppToast?
    private var failure = Failure.none
    private(set) var errorDetails: AppFailure?
    private var retryUndo: RetryUndo?

    var latestFailure: AppFailure? {
        switch failure {
        case .none: nil
        case .recorded(let latest), .presented(let latest, _, _): latest
        }
    }

    var presentedFailure: AppFailure? {
        guard case .presented(let presented, _, _) = failure else { return nil }
        return presented
    }

    var presentedTitle: String? {
        guard case .presented(_, _, let title) = failure else { return nil }
        return title
    }

    var inlineFailure: AppFailure? {
        guard case .presented(let presented, .inline, _) = failure else { return nil }
        return presented
    }

    var retryUndoFailure: AppFailure? { retryUndo?.failure }

    /// The failed Undo that needs its own Retry Undo notice: neither the latest
    /// failure nor open in error details.
    var pendingUndoFailure: AppFailure? {
        guard let retryUndo,
              latestFailure?.id != retryUndo.failure.id,
              errorDetails?.id != retryUndo.failure.id else { return nil }
        return retryUndo.failure
    }

    /// The token a saved-snips change must keep valid to preserve the current Undo.
    var undoToken: UUID? {
        retryUndo?.undo.id ?? (snackbar?.offersUndo == true ? snackbar?.id : nil)
    }

    func undoToRetry(for failure: AppFailure) -> AppToast? {
        retryUndo?.failure.id == failure.id ? retryUndo?.undo : nil
    }

    func retainsUndo(_ token: UUID) -> Bool {
        retryUndo?.undo.id == token
    }

    // MARK: Snackbar

    /// An Undo snackbar that replaces the presented failure's Details snackbar
    /// moves that failure inline so it stays visible.
    mutating func show(_ newSnackbar: AppToast) {
        if newSnackbar.offersUndo,
           case .showErrorDetails(let id) = snackbar?.action,
           case .presented(let presented, _, let title) = failure, presented.id == id {
            failure = .presented(presented, surface: .inline, title: title)
        }
        snackbar = newSnackbar
    }

    /// Closes the snackbar only while it is still the one shown.
    mutating func closeSnackbar(id: UUID) {
        guard snackbar?.id == id else { return }
        snackbar = nil
    }

    /// A saved-snips change ends the Undo window and any Retry Undo.
    mutating func endUndoWindow() {
        retryUndo = nil
        if snackbar?.offersUndo == true { snackbar = nil }
    }

    // MARK: Failure

    mutating func hidePresentedFailure() {
        guard case .presented(let presented, _, _) = failure else { return }
        failure = .recorded(presented)
    }

    /// A failure that is no longer available to retry replaces Retry Undo and
    /// takes over its open details.
    mutating func replaceRetryUndo(with newFailure: AppFailure, title: String? = nil) {
        let movesDetails = retryUndo.map { errorDetails?.id == $0.failure.id } ?? false
        retryUndo = nil
        presentLatest(newFailure, title: title)
        if movesDetails { errorDetails = newFailure }
    }

    private mutating func presentLatest(_ newFailure: AppFailure, title: String?) {
        let preservesUndo = snackbar?.offersUndo == true
        let surface: AppFailure.Surface = newFailure.surface == .snackbar && preservesUndo
            ? .inline : newFailure.surface
        record(latest: newFailure, as: .presented(newFailure, surface: surface, title: title))
        if surface == .snackbar { snackbar = .failed(newFailure) }
    }

    /// A Details snackbar always belongs to the latest failure.
    private mutating func record(latest: AppFailure, as state: Failure) {
        failure = state
        if case .showErrorDetails(let id) = snackbar?.action, id != latest.id { snackbar = nil }
    }

    // MARK: Error details

    mutating func showErrorDetails(_ failure: AppFailure) {
        errorDetails = failure
    }

    /// Opens the latest failure's details; with an ID, only while that failure is still the latest.
    mutating func showLatestErrorDetails(ifLatestIs id: UUID? = nil) {
        guard id == nil || latestFailure?.id == id else { return }
        errorDetails = latestFailure
    }

    // MARK: Retry Undo

    /// Keeps the latest failure's Undo for Retry Undo. Details open on
    /// `priorFailureID` move to the new failure.
    mutating func retainUndoFailure(of undo: AppToast, movingDetailsFrom priorFailureID: UUID? = nil) {
        guard let latest = latestFailure else { return }
        if let priorFailureID, errorDetails?.id == priorFailureID { errorDetails = latest }
        retryUndo = RetryUndo(failure: latest, undo: undo)
    }

    /// A successful Undo ends its snackbar, its Retry Undo, and details open on that retry.
    mutating func undoSucceeded(_ undo: AppToast) {
        closeSnackbar(id: undo.id)
        if errorDetails?.id == retryUndo?.failure.id { errorDetails = nil }
        retryUndo = nil
    }
}

#if os(macOS)
extension SnackbarAndErrorPresentation {
    /// Mac confirmations never replace a snackbar that offers an action.
    mutating func showUnlessActionable(_ confirmation: AppToast) {
        guard snackbar?.action == nil else { return }
        show(confirmation)
    }

    /// On Mac, a failure of Retry Undo's operation replaces it.
    mutating func present(_ newFailure: AppFailure, title: String?) {
        if retryUndo?.failure.operation == newFailure.operation {
            replaceRetryUndo(with: newFailure, title: title)
        } else {
            presentLatest(newFailure, title: title)
        }
    }

    /// Keeps a failure for Error details without presenting it.
    mutating func record(_ newFailure: AppFailure) {
        record(latest: newFailure, as: .recorded(newFailure))
    }

    /// The latest failure's operation succeeded: close its details and Details snackbar.
    mutating func resolveLatestFailure() {
        if let id = latestFailure?.id {
            if errorDetails?.id == id { errorDetails = nil }
            if snackbar?.action == .showErrorDetails(id) { snackbar = nil }
        }
        hidePresentedFailure()
    }

    mutating func dismissPresentedFailure() {
        errorDetails = nil
        hidePresentedFailure()
        if case .showErrorDetails = snackbar?.action { snackbar = nil }
    }

    /// Closes `closing`, or else the open details or the presented dialog. Closing
    /// a dialog failure's details also dismisses that failure.
    mutating func closeErrorDetails(_ closing: AppFailure?) {
        let closingID = closing?.id ?? errorDetails?.id
            ?? (presentedFailure?.surface == .dialog ? presentedFailure?.id : nil)
        if let errorDetails, errorDetails.id != closingID { return }
        errorDetails = nil
        if let latestFailure, latestFailure.id == closingID, latestFailure.surface == .dialog {
            dismissPresentedFailure()
        }
    }
}
#else
extension SnackbarAndErrorPresentation {
    /// iOS replaces a Details snackbar but never replaces Undo with a plain confirmation.
    mutating func showKeepingUndo(_ newSnackbar: AppToast) {
        guard snackbar?.offersUndo != true || newSnackbar.action != nil else { return }
        show(newSnackbar)
    }

    mutating func present(_ newFailure: AppFailure) {
        presentLatest(newFailure, title: nil)
    }

    /// The presented failure's operation succeeded: close its Details snackbar.
    mutating func resolvePresentedFailure(id: UUID) {
        guard presentedFailure?.id == id else { return }
        if snackbar?.action == .showErrorDetails(id) { snackbar = nil }
        hidePresentedFailure()
    }

    /// Closing a presented dialog failure's details also dismisses that failure.
    mutating func closeErrorDetails() {
        if let presentedFailure, presentedFailure.id == errorDetails?.id, presentedFailure.surface == .dialog {
            hidePresentedFailure()
        }
        errorDetails = nil
    }
}
#endif

private extension AppToast {
    var offersUndo: Bool { action == .undoDone || action == .undoDelete }
}
