import Foundation
import SnipSnapCore
import XCTest
#if os(iOS)
import Observation
import SwiftUI
import UIKit
#endif
#if os(macOS)
@testable import SnipSnap
#else
@testable import SnipSnapiOS
#endif

final class AppFeedbackTests: XCTestCase {
    @MainActor
    func testVoiceOverPauseSurvivesPresentationHostHandoff() {
        let start = ContinuousClock().now
        let lifetime = AppToastLifetime(expiresAt: start.advanced(by: .seconds(6)), isActionable: true)
        let root = UUID()

        lifetime.setVoiceOverEnabled(true, at: start)
        lifetime.setInteractionPaused(true, owner: root, at: start.advanced(by: .seconds(1)))
        lifetime.setInteractionPaused(false, owner: root, at: start.advanced(by: .seconds(8)))
        lifetime.setVoiceOverEnabled(true, at: start.advanced(by: .seconds(8)))
        XCTAssertFalse(lifetime.canExpire(at: start.advanced(by: .seconds(10))))
        lifetime.setVoiceOverEnabled(false, at: start.advanced(by: .seconds(10)))

        XCTAssertEqual(lifetime.deadline, start.advanced(by: .seconds(16)))
        XCTAssertFalse(lifetime.canExpire(at: start.advanced(by: .seconds(15))))
        XCTAssertTrue(lifetime.canExpire(at: start.advanced(by: .seconds(16))))
    }

    @MainActor
    func testOverlappingPresentationOwnersPauseOneContinuousInterval() {
        let start = ContinuousClock().now
        let lifetime = AppToastLifetime(expiresAt: start.advanced(by: .seconds(6)), isActionable: true)
        let root = UUID()
        let sheet = UUID()

        lifetime.setInteractionPaused(true, owner: root, at: start.advanced(by: .seconds(2)))
        lifetime.setInteractionPaused(true, owner: sheet, at: start.advanced(by: .seconds(4)))
        lifetime.setInteractionPaused(false, owner: root, at: start.advanced(by: .seconds(8)))
        XCTAssertTrue(lifetime.isPaused)
        lifetime.setInteractionPaused(false, owner: sheet, at: start.advanced(by: .seconds(10)))

        XCTAssertFalse(lifetime.isPaused)
        XCTAssertEqual(lifetime.deadline, start.advanced(by: .seconds(14)))
    }

    @MainActor
    func testVoiceOverAndFocusPauseUntilBothCausesEnd() {
        let start = ContinuousClock().now
        let lifetime = AppToastLifetime(expiresAt: start.advanced(by: .seconds(6)), isActionable: true)
        let focused = UUID()

        lifetime.setVoiceOverEnabled(true, at: start.advanced(by: .seconds(1)))
        lifetime.setInteractionPaused(true, owner: focused, at: start.advanced(by: .seconds(3)))
        lifetime.setVoiceOverEnabled(false, at: start.advanced(by: .seconds(8)))
        XCTAssertTrue(lifetime.isPaused)
        lifetime.setInteractionPaused(false, owner: focused, at: start.advanced(by: .seconds(10)))

        XCTAssertEqual(lifetime.deadline, start.advanced(by: .seconds(15)))
    }

    @MainActor
    func testRepeatedHostUpdatesDoNotRenewUnpausedLifetime() {
        let start = ContinuousClock().now
        let lifetime = AppToastLifetime(expiresAt: start.advanced(by: .seconds(6)), isActionable: true)
        let host = UUID()

        lifetime.setInteractionPaused(true, owner: host, at: start.advanced(by: .seconds(2)))
        lifetime.setInteractionPaused(false, owner: host, at: start.advanced(by: .seconds(4)))
        lifetime.setVoiceOverEnabled(false, at: start.advanced(by: .seconds(5)))
        lifetime.setInteractionPaused(false, owner: UUID(), at: start.advanced(by: .seconds(7)))

        XCTAssertEqual(lifetime.deadline, start.advanced(by: .seconds(8)))
        XCTAssertTrue(lifetime.canExpire(at: start.advanced(by: .seconds(8))))
    }

    @MainActor
    func testReplacementToastOwnsItsPauseHistory() {
        let start = ContinuousClock().now
        let original = AppToastLifetime(expiresAt: start.advanced(by: .seconds(6)), isActionable: true)
        original.setVoiceOverEnabled(true, at: start.advanced(by: .seconds(2)))
        let replacement = AppToastLifetime(expiresAt: start.advanced(by: .seconds(9)), isActionable: true)
        replacement.setVoiceOverEnabled(true, at: start.advanced(by: .seconds(3)))

        original.setVoiceOverEnabled(false, at: start.advanced(by: .seconds(11)))
        XCTAssertTrue(replacement.isPaused)
        replacement.setVoiceOverEnabled(false, at: start.advanced(by: .seconds(11)))

        XCTAssertEqual(original.deadline, start.advanced(by: .seconds(15)))
        XCTAssertEqual(replacement.deadline, start.advanced(by: .seconds(17)))
    }

    @MainActor
    func testVoiceOverDoesNotPauseInformationalToast() {
        let start = ContinuousClock().now
        let lifetime = AppToastLifetime(expiresAt: start.advanced(by: .seconds(3)), isActionable: false)

        lifetime.setVoiceOverEnabled(true, at: start)

        XCTAssertFalse(lifetime.isPaused)
        XCTAssertTrue(lifetime.canExpire(at: start.advanced(by: .seconds(3))))
    }

    @MainActor
    func testToastCopiesShareLifetimeAndReplacementsDoNot() {
        let toast = AppToast.markedDone(count: 1, id: UUID())
        let copy = toast
        let replacement = AppToast.markedDone(count: 1, id: UUID())
        let start = toast.expiresAt.advanced(by: .seconds(-6))

        copy.lifetime.setVoiceOverEnabled(true, at: start)
        copy.lifetime.setVoiceOverEnabled(false, at: start.advanced(by: .seconds(8)))

        XCTAssertEqual(toast.lifetime.deadline, toast.expiresAt.advanced(by: .seconds(8)))
        XCTAssertEqual(replacement.lifetime.deadline, replacement.expiresAt)
    }

    func testCopiedErrorDetailsExcludePrivateLocalizedErrorText() {
        let privateMessage = "Private snip text in /private/secret-file.txt"
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

#if os(iOS)

extension AppFeedbackTests {
    @MainActor
    func testMountedToastPreservesPauseAcrossSettingsPresentation() async throws {
        let readyBy = ContinuousClock().now.advanced(by: .seconds(3))
        while UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).isEmpty,
              ContinuousClock().now < readyBy {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let toast = AppToast(systemImage: "checkmark.circle", message: "Marked Done",
                             action: .undoDone, duration: .seconds(1))
        let pauseOwner = UUID()
        toast.lifetime.setInteractionPaused(true, owner: pauseOwner)
        let state = ToastHandoffState(toast: toast)
        let rootMounted = XCTestExpectation(description: "Library presenter mounted")
        let settingsMounted = XCTestExpectation(description: "Settings presenter mounted")
        let dismissed = XCTestExpectation(description: "Resumed toast expired once")
        dismissed.assertForOverFulfill = true
        let controller = UIHostingController(rootView: ToastHandoffProbe(
            state: state,
            rootMounted: { rootMounted.fulfill() },
            settingsMounted: { settingsMounted.fulfill() },
            dismissed: { presented in
                state.dismissed.append(presented.id)
                dismissed.fulfill()
            }
        ))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }

        let mounted = await XCTWaiter.fulfillment(of: [rootMounted], timeout: 3)
        XCTAssertEqual(mounted, .completed)
        guard mounted == .completed else { return }
        try await ContinuousClock().sleep(until: toast.expiresAt.advanced(by: .milliseconds(200)))
        let pausedToast = try XCTUnwrap(state.toast,
                                       "A paused lifetime must remain actionable beyond its original deadline")
        XCTAssertEqual(pausedToast.id, toast.id)

        state.showsSettings = true
        let settings = await XCTWaiter.fulfillment(of: [settingsMounted], timeout: 3)
        XCTAssertEqual(settings, .completed)
        guard settings == .completed else { return }
        XCTAssertEqual(try XCTUnwrap(state.toast).id, toast.id)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Paused toast in Settings after the original deadline"
        attachment.lifetime = .keepAlways
        add(attachment)
        let resumedAt = ContinuousClock().now
        toast.lifetime.setInteractionPaused(false, owner: pauseOwner)
        try await ContinuousClock().sleep(until: resumedAt.advanced(by: .milliseconds(250)))
        XCTAssertEqual(state.toast?.id, toast.id,
                       "Changing hosts must preserve the remaining unpaused interval")

        let expired = await XCTWaiter.fulfillment(of: [dismissed], timeout: 3)
        XCTAssertEqual(expired, .completed)
        XCTAssertNil(state.toast)
        XCTAssertEqual(state.dismissed, [toast.id])
    }
}

@MainActor
@Observable
private final class ToastHandoffState {
    var toast: AppToast?
    var showsSettings = false
    var dismissed: [UUID] = []

    init(toast: AppToast) { self.toast = toast }
}

private struct ToastHandoffProbe: View {
    @Bindable var state: ToastHandoffState
    let rootMounted: () -> Void
    let settingsMounted: () -> Void
    let dismissed: (AppToast) -> Void

    var body: some View {
        Text("Library")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appToast($state.toast, alignment: .bottom, edge: .bottom,
                      isHidden: state.showsSettings, usesFixedExpiry: true, onDismiss: dismissed)
            .onAppear(perform: rootMounted)
            .sheet(isPresented: $state.showsSettings) {
                Text("Settings")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .appToast($state.toast, alignment: .bottom, edge: .bottom,
                              usesFixedExpiry: true, onDismiss: dismissed)
                    .onAppear(perform: settingsMounted)
            }
    }
}
#endif
