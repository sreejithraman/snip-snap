import Foundation
import SnipSnapCore
import XCTest
#if os(macOS)
@testable import SnipSnap
#else
@testable import SnipSnapiOS
#endif

final class AppFeedbackTests: XCTestCase {
    func testCopiedErrorDetailsExcludePrivateLocalizedErrorText() {
        let privateMessage = "Private snip text in /Users/private/secret-file.txt"
        let failure = AppFailure(message: privateMessage, operation: "clipboard.write",
                                 diagnosticCode: "pasteboard.writeFailed")

        XCTAssertEqual(failure.message, privateMessage)
        XCTAssertTrue(failure.diagnosticReport.contains("Operation: clipboard.write"))
        XCTAssertTrue(failure.diagnosticReport.contains("Error code: pasteboard.writeFailed"))
        XCTAssertFalse(failure.diagnosticReport.contains("Private snip text"))
        XCTAssertFalse(failure.diagnosticReport.contains("secret-file.txt"))
    }

    func testDraftFailureStaysInlineAndCopyFailureDoesNotInterruptEditing() {
        XCTAssertEqual(AppFailure(error: SnipLibraryError.snipNotFound, operation: "snip.update").surface, .inline)
        XCTAssertEqual(AppFailure(error: SnipLibraryError.snipNotFound, operation: "snip.edit_attachments").surface, .inline)
        XCTAssertEqual(AppFailure(error: SnipLibraryError.snipNotFound, operation: "list.create").surface, .inline)
        XCTAssertEqual(AppFailure(error: SnipLibraryError.snipNotFound, operation: "clipboard.write").surface, .snackbar)
        XCTAssertEqual(AppFailure(error: SnipLibraryError.snipNotFound, operation: "list.delete").surface, .snackbar)
        XCTAssertEqual(AppFailure(error: SnipLibraryError.snipNotFound, operation: "app.startup").surface, .dialog)
        XCTAssertEqual(AppFailure(error: SnipLibraryError.snipNotFound, operation: "snip.undo_done").surface, .dialog)
    }

    func testPartialCopyFailureNamesTheSuccessfulAndFailedOutcomes() {
        let failure = AppFailure(message: "Try marking Done again.", operation: "snip.completion_after_copy",
                                 diagnosticCode: "library.storeUnavailable")
        XCTAssertEqual(failure.title, "Copied, but couldn’t mark Done")
        XCTAssertEqual(failure.surface, .snackbar)
        XCTAssertEqual(AppToast.failed(failure).action, .showErrorDetails(failure.id))
        XCTAssertEqual(AppToast.failed(failure).actionTitle, "Details")
    }

    func testTextCopyFeedbackKeepsTheCopiedContentAndUndoMeaningExplicit() {
        let undo = SavedSnipsDoneUndo(id: UUID(), count: 2)
        let toast = AppToast.copiedText().addingDoneUndo(undo)
        XCTAssertEqual(toast.message, "Snapped")
        XCTAssertEqual(toast.detail, "Text copied · 2 marked Done")
        XCTAssertEqual(toast.id, undo.id)
        XCTAssertEqual(toast.action, .undoDone)
        XCTAssertEqual(toast.actionAccessibilityLabel, "Undo marking Done")
    }
}
