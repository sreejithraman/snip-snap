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

    func testRepeatedDiagnosticCallbackSettlesAwaitedDeliveryWithoutDuplicateRecording() async throws {
        let delivery = IOSDiagnosticShareDelivery()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let task = Task { try await delivery.deliver(url) }
        let request = try await pendingRequest(in: delivery)
        let probe = ShareDiagnosticRecorderProbe()
        let presenter = IOSShareSheetPresenter(
            request: Binding(get: { delivery.request }, set: { delivery.request = $0 }),
            diagnosticOperation: "diagnostics.export", diagnostics: probe.recorder
        )
        let activity = presenter.makeActivityController(for: request)
        let callback = try XCTUnwrap(activity.completionWithItemsHandler)
        let error = CocoaError(.fileWriteNoPermission)
        callback(nil, false, nil, error)
        callback(nil, false, nil, error)
        let result = await task.result
        guard case .failure(let failure) = result else { return XCTFail("Delivery must fail") }
        XCTAssertEqual((failure as NSError).code, NSFileWriteNoPermissionError)
        await drainMainQueue()
        XCTAssertNil(delivery.request)
        XCTAssertTrue(probe.events.isEmpty, "The shared model records awaited delivery failures")
    }

    func testCanceledDeliveryWaitsForPresenterTeardownAndIgnoresLateCallback() async throws {
        let delivery = IOSDiagnosticShareDelivery()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("diagnostic report".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var didFinish = false
        let task = Task {
            defer { didFinish = true }
            return try await delivery.deliver(url)
        }
        let request = try await pendingRequest(in: delivery)
        XCTAssertEqual(request.items, [.file(url)])
        let probe = ShareDiagnosticRecorderProbe()
        let presenter = IOSShareSheetPresenter(
            request: Binding(get: { delivery.request }, set: { delivery.request = $0 }),
            diagnosticOperation: "diagnostics.export", diagnostics: probe.recorder
        )
        let coordinator = presenter.makeCoordinator()
        let activity = presenter.makeActivityController(for: request, coordinator: coordinator)
        let lateCallback = try XCTUnwrap(activity.completionWithItemsHandler)
        task.cancel()
        await drainMainQueue()
        XCTAssertFalse(didFinish)
        XCTAssertEqual(try Data(contentsOf: url), Data("diagnostic report".utf8))
        IOSShareSheetPresenter.dismantleUIViewController(UIViewController(), coordinator: coordinator)
        let result = try await task.value
        guard case .cancelled = result else { return XCTFail("Teardown must settle cancellation") }
        lateCallback(nil, false, nil, CocoaError(.fileWriteNoPermission))
        await drainMainQueue()
        XCTAssertNil(delivery.request)
        XCTAssertTrue(probe.events.isEmpty)
    }

    func testTeardownBeforePresentationSettlesPendingDelivery() async throws {
        let delivery = IOSDiagnosticShareDelivery()
        let presenter = IOSShareSheetPresenter(
            request: Binding(get: { delivery.request }, set: { delivery.request = $0 })
        )
        let coordinator = presenter.makeCoordinator()
        let task = Task { try await delivery.deliver(URL(fileURLWithPath: "/unused/report.txt")) }
        _ = try await pendingRequest(in: delivery)
        IOSShareSheetPresenter.dismantleUIViewController(UIViewController(), coordinator: coordinator)
        let result = try await task.value
        guard case .cancelled = result else { return XCTFail("Unpresented delivery must settle") }
        XCTAssertNil(delivery.request)
    }

    func testLateAwaitedCallbackDoesNotClearReplacementRequest() async throws {
        let delivery = IOSDiagnosticShareDelivery()
        let task = Task { try await delivery.deliver(URL(fileURLWithPath: "/unused/report.txt")) }
        let oldRequest = try await pendingRequest(in: delivery)
        let presenter = IOSShareSheetPresenter(
            request: Binding(get: { delivery.request }, set: { delivery.request = $0 })
        )
        let activity = presenter.makeActivityController(for: oldRequest)
        let callback = try XCTUnwrap(activity.completionWithItemsHandler)
        let nextRequest = IOSShareRequest(items: [.text("next request")])
        delivery.request = nextRequest
        callback(nil, false, nil, nil)
        _ = try await task.value
        XCTAssertEqual(delivery.request?.id, nextRequest.id)
    }

    private func pendingRequest(in delivery: IOSDiagnosticShareDelivery) async throws -> IOSShareRequest {
        for _ in 0..<1_000 {
            if let request = delivery.request { return request }
            await Task.yield()
        }
        return try XCTUnwrap(delivery.request)
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
