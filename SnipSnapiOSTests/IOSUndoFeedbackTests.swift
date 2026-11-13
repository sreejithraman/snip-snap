import Foundation
import SnipSnapCore
import SnipSnapPersistence
import SwiftUI
import UIKit
import XCTest
@testable import SnipSnapiOS

@MainActor
final class IOSUndoFeedbackTests: IOSModelTestCase {
    func testDoneSnackbarUndoReopensOnlyNewlyDoneSnipsAndKeepsClipboard() async throws {
        let unfinished = Snip(content: "Unfinished", origin: .quickEntry)
        let done = Snip(content: "Already done", origin: .quickEntry, isDone: true)
        let pinned = Snip(content: "Pinned", origin: .quickEntry, pinnedAt: Date())
        let model = IOSAppModel(library: ModelTestLibrary(snips: [unfinished, done, pinned]))
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        let copied = await coordinator.copy(snips: [unfinished, done, pinned], model: model)
        XCTAssertTrue(copied)
        let toast = try XCTUnwrap(model.toast)
        XCTAssertEqual(toast.action, .undoDone)
        let writes = pasteboard.writes
        model.closeSnackbar(toast)
        await model.performToastActionNow(toast)

        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == unfinished.id }).isDone)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == done.id }).isDone)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == pinned.id }).isPinned)
        XCTAssertEqual(pasteboard.writes, writes)
        XCTAssertNil(model.toast)
    }

    func testCopyOnlyPreservesDoneUndoAndLaterMutationInvalidatesItsAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("library.json"))
        let unfinished = Snip(content: "Unfinished", origin: .quickEntry)
        let pinned = Snip(content: "Pinned", origin: .quickEntry, pinnedAt: Date())
        _ = try await library.perform(.restore(snips: [unfinished, pinned]), sortedBy: .chronological)
        let model = IOSAppModel(library: library)
        await model.load()
        let coordinator = IOSCopyShareCoordinator(pasteboard: RecordingPasteboard())
        _ = await coordinator.copy(snips: [unfinished], model: model)
        let undo = try XCTUnwrap(model.toast)
        _ = await coordinator.copy(snips: [pinned], model: model)
        XCTAssertEqual(model.toast?.id, undo.id)

        _ = await model.togglePinned(id: unfinished.id)
        XCTAssertNil(model.toast)
        await model.performToastActionNow(undo)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == unfinished.id }).isPinned)
    }

    func testPartialCopyFailureReportsTheSuccessfulCopyWithoutDoneUndo() async throws {
        let snip = Snip(content: "Copied once", origin: .quickEntry)
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip], failsDone: true))
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        let copiedAndMarked = await coordinator.copy(snips: [snip], model: model)

        XCTAssertFalse(copiedAndMarked)
        XCTAssertEqual(pasteboard.writes, [[.text("Copied once")]])
        XCTAssertFalse(try XCTUnwrap(model.snips.first).isDone)
        XCTAssertEqual(model.failure?.surface, .snackbar)
        XCTAssertEqual(model.toast?.message, "Copied, but couldn’t mark Done")
        if case .showErrorDetails = model.toast?.action {} else { XCTFail("Expected error details, not Undo") }
    }

    func testRecoverableFailureDetailsStayAvailableAfterSnackbarDisappears() async throws {
        let model = IOSAppModel(library: ModelTestLibrary())
        model.presentError("Copy failed", operation: "clipboard.write", diagnosticCode: "pasteboard.writeFailed")
        let toast = try XCTUnwrap(model.toast)
        let failure = try XCTUnwrap(model.latestFailure)
        model.closeSnackbar(toast)

        await model.performToastActionNow(toast)

        XCTAssertEqual(model.errorDetails?.id, failure.id)
        XCTAssertEqual(model.failure?.surface, .snackbar)
        XCTAssertEqual(model.errorMessage, "Copy failed")
    }

    func testReplacingFailureClearsSupersededWarningSnackbar() throws {
        let replacements: [(IOSAppModel) -> Void] = [
            { $0.presentError(SnipLibraryError.duplicateList, operation: "list.create") },
            { $0.presentError(SnipLibraryError.storeUnavailable, operation: "app.user_action") },
            { $0.presentDialogFailure("A later legacy failure") }
        ]
        for replace in replacements {
            let model = IOSAppModel(library: ModelTestLibrary())
            model.presentError("Copy failed", operation: "clipboard.write", diagnosticCode: "pasteboard.writeFailed")
            let warning = try XCTUnwrap(model.toast)
            let first = try XCTUnwrap(model.latestFailure)
            XCTAssertEqual(warning.action, .showErrorDetails(first.id))

            replace(model)

            XCTAssertNotEqual(model.latestFailure?.id, first.id)
            XCTAssertNil(model.toast, "A superseded warning must not keep a Details action for the old incident.")
            model.showLatestErrorDetails()
            XCTAssertEqual(model.errorDetails?.id, model.latestFailure?.id)
        }
    }

    func testUndoSnackbarMovesTheReplacedWarningFailureInline() async throws {
        for deleting in [false, true] {
            let snip = Snip(content: "Undoable", origin: .quickEntry)
            let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]))
            await model.load()
            model.presentError(SnipLibraryError.storeUnavailable, operation: "snip.move")
            let failure = try XCTUnwrap(model.failure)
            XCTAssertEqual(model.toast?.action, .showErrorDetails(failure.id))
            XCTAssertNil(model.inlineFailure)
            XCTAssertFalse(model.hasGlobalInlineFailure)

            if deleting { _ = await model.deleteSnip(id: snip.id) }
            else { _ = await model.toggleDone(id: snip.id) }

            let undo = try XCTUnwrap(model.toast)
            XCTAssertEqual(undo.action, deleting ? .undoDelete : .undoDone)
            XCTAssertEqual(model.inlineFailure?.id, failure.id,
                           "The Undo snackbar must keep the replaced warning visible inline.")
            XCTAssertTrue(model.hasGlobalInlineFailure)
            model.closeSnackbar(undo)
            XCTAssertEqual(model.inlineFailure?.id, failure.id)
            model.dismissError()
            XCTAssertNil(model.inlineFailure)
            XCTAssertEqual(model.latestFailure?.id, failure.id)
        }
    }

    func testCopyConfirmationReplacesAWarningButNeverUndo() async throws {
        let pinned = Snip(content: "Copy only", origin: .quickEntry, pinnedAt: Date())
        let deletable = Snip(content: "Delete me", origin: .quickEntry)
        let model = IOSAppModel(library: ModelTestLibrary(snips: [pinned, deletable]))
        await model.load()
        let coordinator = IOSCopyShareCoordinator(pasteboard: RecordingPasteboard())
        model.presentError(SnipLibraryError.storeUnavailable, operation: "snip.move")
        let failure = try XCTUnwrap(model.failure)
        XCTAssertEqual(model.toast?.action, .showErrorDetails(failure.id))

        let copiedOverWarning = await coordinator.copy(snips: [pinned], model: model)

        XCTAssertTrue(copiedOverWarning)
        XCTAssertEqual(model.toast?.message, "Snapped")
        XCTAssertNil(model.toast?.action, "iOS replaces a warning with the copy confirmation.")
        XCTAssertEqual(model.failure?.id, failure.id)

        _ = await model.deleteSnip(id: deletable.id)
        let undo = try XCTUnwrap(model.toast)
        XCTAssertEqual(undo.action, .undoDelete)
        let copiedOverUndo = await coordinator.copy(snips: [pinned], model: model)
        XCTAssertTrue(copiedOverUndo)
        XCTAssertEqual(model.toast?.id, undo.id, "A copy confirmation never replaces Undo.")
    }

    func testSuccessfulCopyRetryKeepsTheResolvedFailureDetailsOpen() async throws {
        let pinned = Snip(content: "Retry copy", origin: .quickEntry, pinnedAt: Date())
        let model = IOSAppModel(library: ModelTestLibrary(snips: [pinned]))
        await model.load()
        let coordinator = IOSCopyShareCoordinator(pasteboard: RecordingPasteboard())
        model.presentError(SnipLibraryError.attachmentCopyFailed, operation: "clipboard.write")
        let failure = try XCTUnwrap(model.failure)
        XCTAssertEqual(model.toast?.action, .showErrorDetails(failure.id))
        model.showLatestErrorDetails()

        let copied = await coordinator.copy(snips: [pinned], model: model)

        XCTAssertTrue(copied)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.errorDetails?.id, failure.id, "iOS keeps details open after the retry succeeds.")
        XCTAssertEqual(model.latestFailure?.id, failure.id)
        XCTAssertEqual(model.toast?.message, "Snapped")
        XCTAssertNil(model.toast?.action)
    }

    func testExpiringSnackbarClosesThroughTheModelBeforeItsDismissalRuns() async throws {
        let readyBy = ContinuousClock().now.advanced(by: .seconds(3))
        while UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).isEmpty,
              ContinuousClock().now < readyBy {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let snip = Snip(content: "Holds the library", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [snip])
        let model = IOSAppModel(library: library)
        await model.load()
        await library.suspendNextCommand()
        let heldMutation = Task { await model.toggleDone(id: snip.id) }
        await library.waitUntilFirstCommandStarts()
        let snackbar = AppToast(systemImage: "doc.on.doc", message: "Short", duration: .milliseconds(300))
        model.presentToast(snackbar)
        let controller = UIHostingController(rootView: Color.clear.libraryToast(model: model, usesFixedExpiry: true))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }

        let closed = await TestReadiness.wait { model.toast == nil }

        XCTAssertTrue(closed, "The presenter must close the expired snackbar through the model, "
                      + "not wait for the dismissal that needs the library.")
        await library.resumeFirstCommand()
        _ = await heldMutation.value
    }

    func testFailedCopyKeepsDoneAndDeleteUndoAvailable() async throws {
        for deleting in [false, true] {
            let snip = Snip(content: "Preserve Undo", origin: .quickEntry)
            let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]))
            await model.load()
            if deleting { _ = await model.deleteSnip(id: snip.id) }
            else { _ = await model.toggleDone(id: snip.id) }
            let undo = try XCTUnwrap(model.toast)

            model.presentError(SnipLibraryError.attachmentCopyFailed, operation: "clipboard.write")

            XCTAssertEqual(model.toast?.id, undo.id)
            XCTAssertEqual(model.inlineFailure?.operation, "clipboard.write")
            await model.performToastActionNow(undo)
            XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == snip.id }).isDone)
        }
    }

    func testFailedDoneUndoStopsOfferingRetryAfterTheSnipChanges() async throws {
        let snip = Snip(content: "Original", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [snip], failsReopenOnce: true)
        let model = IOSAppModel(library: library)
        await model.load()
        _ = await model.toggleDone(id: snip.id)
        let undo = try XCTUnwrap(model.toast)
        model.closeSnackbar(undo)
        await model.performToastActionNow(undo)
        let failure = try XCTUnwrap(model.failure)
        model.showErrorDetails(failure)
        await library.replaceText("Newer edit", for: snip.id)

        await model.performToastActionNow(undo)

        let unavailable = try XCTUnwrap(model.failure)
        XCTAssertFalse(model.canRetryFailure(unavailable))
        XCTAssertEqual(model.errorDetails?.id, unavailable.id)
        XCTAssertEqual(unavailable.code, "undo.unavailable")
        model.dismissErrorDetails()
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.latestFailure?.id, unavailable.id)
        await model.load()
        XCTAssertEqual(model.snips.first?.content, "Newer edit")
        XCTAssertTrue(try XCTUnwrap(model.snips.first).isDone)
    }

    func testBackendDoneNoopKeepsThePreviousUndoAndDoesNotEmitDoneFeedback() async throws {
        let first = Snip(content: "First", origin: .quickEntry)
        let second = Snip(content: "Second", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [first, second])
        let feedback = makeFeedback()
        let model = IOSAppModel(library: library, haptics: feedback)
        await model.load()
        _ = await model.toggleDone(id: first.id)
        let undo = try XCTUnwrap(model.toast)
        let previousFeedback = feedback.event
        _ = try await library.perform(.setDone(ids: [second.id], done: true), sortedBy: .chronological)

        _ = await model.toggleDone(id: second.id)

        XCTAssertEqual(model.toast?.id, undo.id)
        XCTAssertEqual(feedback.event, previousFeedback)
        await model.performToastActionNow(undo)
        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == first.id }).isDone)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == second.id }).isDone)
    }

    func testLaterCopyFailureKeepsFailedDoneUndoReachable() async throws {
        let snip = Snip(content: "Done can still be undone", origin: .quickEntry)
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip], failsReopenOnce: true))
        await model.load()
        _ = await model.toggleDone(id: snip.id)
        let undo = try XCTUnwrap(model.toast)
        model.closeSnackbar(undo)
        await model.performToastActionNow(undo)
        let inverseFailure = try XCTUnwrap(model.failure)
        XCTAssertTrue(model.canRetryFailure(inverseFailure))
        let pasteboard = RecordingPasteboard()
        pasteboard.succeeds = false
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        let copied = await coordinator.copyText(snips: model.snips, model: model)

        XCTAssertFalse(copied)
        let recovery = try XCTUnwrap(model.pendingUndoFailure)
        XCTAssertEqual(recovery.id, inverseFailure.id)
        XCTAssertEqual(model.failure?.operation, "clipboard.write")
        model.showErrorDetails(recovery)
        XCTAssertTrue(model.canRetryFailure(recovery))
        XCTAssertNil(model.pendingUndoFailure, "Details must own the inverse failure while open.")
        model.dismissErrorDetails()
        XCTAssertEqual(model.pendingUndoFailure?.id, recovery.id)
        let clipboardWrites = pasteboard.writes
        await model.retryPendingUndoNow(recovery)
        XCTAssertFalse(try XCTUnwrap(model.snips.first).isDone)
        XCTAssertNil(model.pendingUndoFailure)
        XCTAssertEqual(model.failure?.operation, "clipboard.write")
        XCTAssertEqual(pasteboard.writes, clipboardWrites)
    }

    func testSameListMovePreservesDoneAndDeleteUndoIncludingFailedRetries() async throws {
        for deleting in [false, true] {
            for failingUndo in [false, true] {
                let snip = Snip(content: "Keep this inverse", origin: .quickEntry)
                let anchor = Snip(content: "Same list", origin: .quickEntry)
                let library = ModelTestLibrary(
                    snips: [snip, anchor], failsReopenOnce: failingUndo && !deleting,
                    failsRestoreOnce: failingUndo && deleting
                )
                let feedback = makeFeedback()
                let model = IOSAppModel(library: library, haptics: feedback)
                await model.load()
                if deleting { _ = await model.deleteSnip(id: snip.id) }
                else { _ = await model.toggleDone(id: snip.id) }
                let undo = try XCTUnwrap(model.toast)
                if failingUndo {
                    model.closeSnackbar(undo)
                    await model.performToastActionNow(undo)
                }
                let failure = model.failure
                let previousFeedback = feedback.event

                let moved = await model.moveSnip(id: anchor.id, to: SnipList.inboxID)

                XCTAssertTrue(moved)
                XCTAssertEqual(feedback.event, previousFeedback)
                if failingUndo {
                    let failure = try XCTUnwrap(failure)
                    XCTAssertEqual(model.failure?.id, failure.id)
                    XCTAssertTrue(model.canRetryFailure(failure))
                    await model.retryPendingUndoNow(failure)
                } else {
                    XCTAssertEqual(model.toast?.id, undo.id)
                    await model.performToastActionNow(undo)
                }
                XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == snip.id }).isDone)
            }
        }
    }

    func testPendingUndoFailurePreservesUnrelatedDetailsOpenedDuringPersistence() async throws {
        for deleting in [false, true] {
            let snip = Snip(content: "Pending inverse", origin: .quickEntry)
            let library = ModelTestLibrary(
                snips: [snip], failsReopenOnce: !deleting, failsRestoreOnce: deleting
            )
            let model = IOSAppModel(library: library)
            await model.load()
            if deleting { _ = await model.deleteSnip(id: snip.id) }
            else { _ = await model.toggleDone(id: snip.id) }
            let undo = try XCTUnwrap(model.toast)
            model.closeSnackbar(undo)
            await library.suspendNextCommand()
            let inverse = Task { await model.performToastActionNow(undo) }
            await library.waitUntilFirstCommandStarts()
            model.presentError(SnipLibraryError.attachmentCopyFailed, operation: "clipboard.write")
            model.showLatestErrorDetails()
            let selectedDetails = try XCTUnwrap(model.errorDetails)

            await library.resumeFirstCommand()
            await inverse.value

            XCTAssertEqual(model.errorDetails?.id, selectedDetails.id)
            let inverseFailure = try XCTUnwrap(model.failure)
            XCTAssertEqual(inverseFailure.operation, deleting ? "snip.undo_delete" : "snip.undo_done")
            XCTAssertTrue(model.canRetryFailure(inverseFailure))
            model.dismissErrorDetails()
            XCTAssertEqual(model.failure?.id, inverseFailure.id)
            await model.retryPendingUndoNow(inverseFailure)
            XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == snip.id }).isDone)
        }
    }

    func testFailedDoneUndoRetainsASafeRetryAndClosesDetailsAfterRecovery() async throws {
        let snip = Snip(content: "Retry only Done", origin: .quickEntry)
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip], failsReopenOnce: true))
        await model.load()
        _ = await model.toggleDone(id: snip.id)
        let undo = try XCTUnwrap(model.toast)
        model.closeSnackbar(undo)

        await model.performToastActionNow(undo)
        let failure = try XCTUnwrap(model.failure)
        XCTAssertTrue(model.canRetryFailure(failure))
        XCTAssertEqual(failure.surface, .dialog)
        XCTAssertTrue(try XCTUnwrap(model.snips.first).isDone)
        model.showErrorDetails(failure)

        await model.performToastActionNow(undo)

        XCTAssertFalse(try XCTUnwrap(model.snips.first).isDone)
        XCTAssertNil(model.errorDetails)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canRetryFailure(failure))
    }

    func testCopyDoesNotMarkNewerRepositoryContentDoneFromAStaleModel() async throws {
        let original = Snip(content: "Copied snapshot", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [original])
        let model = IOSAppModel(library: library)
        await model.load()
        await library.replaceText("Newer repository content", for: original.id)
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        let copiedAndMarked = await coordinator.copyText(snips: [original], model: model)
        await model.load()

        XCTAssertFalse(copiedAndMarked)
        XCTAssertEqual(pasteboard.writes, [[.text("Copied snapshot")]])
        let current = try XCTUnwrap(model.snips.first)
        XCTAssertEqual(current.content, "Newer repository content")
        XCTAssertFalse(current.isDone)
        XCTAssertEqual(model.failure?.operation, "snip.completion_after_copy")
    }
}
