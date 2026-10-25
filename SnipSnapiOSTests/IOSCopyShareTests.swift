import Foundation
import SnipSnapCore
import SwiftUI
import UIKit
import XCTest
@testable import SnipSnapiOS

@MainActor
final class IOSCopyShareTests: XCTestCase {
    func testDiagnosticShareCallbackRecordsPrivateSafeFailureAndClearsRequest() async throws {
        let request = IOSShareRequest(items: [.text("private shared content")])
        let state = ShareRequestState(request)
        let probe = ShareDiagnosticRecorderProbe()
        let presenter = IOSShareSheetPresenter(
            request: state.binding,
            diagnosticOperation: "diagnostics.export",
            diagnostics: probe.recorder
        )
        let activity = presenter.makeActivityController(for: request)
        let completion = try XCTUnwrap(activity.completionWithItemsHandler)
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [
                NSLocalizedDescriptionKey: "private recipient refused private shared content",
                NSFilePathErrorKey: "/private/customer/diagnostic-log.txt",
                NSUnderlyingErrorKey: NSError(domain: "private.account.example", code: 42),
            ]
        )

        completion(nil, false, nil, error)
        await drainMainQueue()

        XCTAssertNil(state.request)
        XCTAssertEqual(probe.events.map(\.line), [
            "diagnostic_event operation=diagnostics.export outcome=failed visibility=user error=cocoa.513",
        ])
    }

    func testOrdinaryShareCallbackRecordsFailureAndClearsRequest() async throws {
        let request = IOSShareRequest(items: [.text("private shared content")])
        let state = ShareRequestState(request)
        let probe = ShareDiagnosticRecorderProbe()
        let presenter = IOSShareSheetPresenter(request: state.binding, diagnostics: probe.recorder)
        let activity = presenter.makeActivityController(for: request)
        let completion = try XCTUnwrap(activity.completionWithItemsHandler)

        completion(nil, false, nil, URLError(.notConnectedToInternet))
        await drainMainQueue()

        XCTAssertNil(state.request)
        XCTAssertEqual(probe.events.map(\.line), [
            "diagnostic_event operation=app.user_action outcome=failed visibility=user error=url.-1009",
        ])
    }

    func testShareCallbacksWithoutErrorsStayQuietAndClearRequest() async throws {
        for completed in [false, true] {
            let request = IOSShareRequest(items: [.text("private shared content")])
            let state = ShareRequestState(request)
            let probe = ShareDiagnosticRecorderProbe()
            let presenter = IOSShareSheetPresenter(request: state.binding, diagnostics: probe.recorder)
            let activity = presenter.makeActivityController(for: request)
            let completion = try XCTUnwrap(activity.completionWithItemsHandler)

            completion(nil, completed, nil, nil)
            await drainMainQueue()

            XCTAssertNil(state.request)
            XCTAssertTrue(probe.events.isEmpty)
        }
    }

    func testShareCancellationErrorsStayQuietAndClearRequest() async throws {
        let errors: [any Error] = [
            CancellationError(),
            CocoaError(.userCancelled),
            URLError(.cancelled),
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ]
        for error in errors {
            let request = IOSShareRequest(items: [.text("private shared content")])
            let state = ShareRequestState(request)
            let probe = ShareDiagnosticRecorderProbe()
            let presenter = IOSShareSheetPresenter(
                request: state.binding,
                diagnosticOperation: "diagnostics.export",
                diagnostics: probe.recorder
            )
            let activity = presenter.makeActivityController(for: request)
            let completion = try XCTUnwrap(activity.completionWithItemsHandler)

            completion(nil, false, nil, error)
            await drainMainQueue()

            XCTAssertNil(state.request)
            XCTAssertTrue(probe.events.isEmpty)
        }
    }

    func testShareCallbackDoesNotTreatUnrelatedDomainCodesAsCancellation() async throws {
        for code in [NSUserCancelledError, NSURLErrorCancelled] {
            let request = IOSShareRequest(items: [.text("private shared content")])
            let state = ShareRequestState(request)
            let probe = ShareDiagnosticRecorderProbe()
            let presenter = IOSShareSheetPresenter(request: state.binding, diagnostics: probe.recorder)
            let activity = presenter.makeActivityController(for: request)
            let completion = try XCTUnwrap(activity.completionWithItemsHandler)

            completion(nil, false, nil, NSError(domain: "private.account.example", code: code))
            await drainMainQueue()

            XCTAssertNil(state.request)
            XCTAssertEqual(probe.events.map(\.line), [
                "diagnostic_event operation=app.user_action outcome=failed visibility=user error=other.UnknownError",
            ])
        }
    }

    func testLateShareCallbackRecordsFailureWithoutClearingNewRequest() async throws {
        let request = IOSShareRequest(items: [.text("old content")])
        let state = ShareRequestState(request)
        let probe = ShareDiagnosticRecorderProbe()
        let presenter = IOSShareSheetPresenter(request: state.binding, diagnostics: probe.recorder)
        let activity = presenter.makeActivityController(for: request)
        let completion = try XCTUnwrap(activity.completionWithItemsHandler)
        let nextRequest = IOSShareRequest(items: [.text("new content")])
        state.request = nextRequest

        completion(nil, false, nil, URLError(.notConnectedToInternet))
        await drainMainQueue()

        XCTAssertEqual(state.request?.id, nextRequest.id)
        XCTAssertEqual(probe.events.map(\.line), [
            "diagnostic_event operation=app.user_action outcome=failed visibility=user error=url.-1009",
        ])
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class ShareRequestState {
    var request: IOSShareRequest?

    init(_ request: IOSShareRequest) {
        self.request = request
    }

    var binding: Binding<IOSShareRequest?> {
        Binding(get: { self.request }, set: { self.request = $0 })
    }
}

private final class ShareDiagnosticRecorderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [AppDiagnosticEvent] = []

    var recorder: AppDiagnosticRecorder {
        AppDiagnosticRecorder { [self] event in
            lock.withLock { storedEvents.append(event) }
        }
    }

    var events: [AppDiagnosticEvent] {
        lock.withLock { storedEvents }
    }
}
