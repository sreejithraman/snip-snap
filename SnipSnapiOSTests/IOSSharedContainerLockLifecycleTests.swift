import SnipSnapCore
import UIKit
import XCTest
@testable import SnipSnapiOS

@MainActor
final class IOSSharedContainerLockLifecycleTests: XCTestCase {
    private let gate = SharedContainerLockGate()
    private let center = NotificationCenter()
    private var begun: [UIBackgroundTaskIdentifier] = []
    private var ended: [UIBackgroundTaskIdentifier] = []
    private var expire: (@MainActor @Sendable () -> Void)?
    private var endedExpectation: XCTestExpectation?

    private func makeLifecycle() -> IOSSharedContainerLockLifecycle {
        IOSSharedContainerLockLifecycle(
            gate: gate,
            notificationCenter: center,
            beginBackgroundTask: { [unowned self] handler in
                expire = handler
                let task = UIBackgroundTaskIdentifier(rawValue: begun.count + 1)
                begun.append(task)
                return task
            },
            endBackgroundTask: { [unowned self] task in
                ended.append(task)
                endedExpectation?.fulfill()
            }
        )
    }

    private func isAdmitting() -> Bool {
        guard let admission = gate.admit() else { return false }
        admission.release()
        return true
    }

    func testAppGroupLocksWaitUntilLaunchProvesTheAppIsActive() {
        let lifecycle = makeLifecycle()

        XCTAssertFalse(isAdmitting())
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(isAdmitting())
        withExtendedLifetime(lifecycle) {}
    }

    func testBackgroundTransitionKeepsExecutionUntilHeldLockIsReleased() async {
        let lifecycle = makeLifecycle()
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let held = gate.admit()

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        XCTAssertEqual(begun.count, 1)
        XCTAssertFalse(isAdmitting())
        XCTAssertEqual(ended, [])
        endedExpectation = expectation(description: "background task ended")
        held?.release()
        await fulfillment(of: [endedExpectation!], timeout: 2)
        XCTAssertEqual(ended, begun)
        expire?()
        XCTAssertEqual(ended, begun)

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertTrue(isAdmitting())
        withExtendedLifetime(lifecycle) {}
    }

    func testExpiredBackgroundTaskEndsOnce() async throws {
        let lifecycle = makeLifecycle()
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let held = gate.admit()
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        try XCTUnwrap(expire)()
        XCTAssertEqual(ended, begun)
        held?.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ended, begun)
        XCTAssertFalse(isAdmitting())
        withExtendedLifetime(lifecycle) {}
    }
}
