import Foundation
@testable import SnipSnapCloud
import XCTest

@MainActor
final class SnipSnapCloudLifecycleHooksTests: XCTestCase {
  func testSeveralTriggersDuringOneSyncRunOneTrailingSync() async {
    let firstStarted = expectation(description: "First sync started")
    let trailingStarted = expectation(description: "Trailing sync started")
    let extraSync = expectation(description: "Another sync started")
    extraSync.isInverted = true
    let probe = HookSyncProbe(started: [firstStarted, trailingStarted], extra: extraSync)
    let hooks = SnipSnapCloudLifecycleHooks { await probe.sync() }

    let firstReturned = startRun(hooks)
    await fulfillment(of: [firstStarted], timeout: 2)
    await triggerCoalesced(hooks)
    await triggerCoalesced(hooks)
    await triggerCoalesced(hooks)
    probe.release(1)
    await fulfillment(of: [trailingStarted], timeout: 2)
    probe.release(2)
    await fulfillment(of: [firstReturned], timeout: 2)
    await fulfillment(of: [extraSync], timeout: 0.2)

    XCTAssertEqual(probe.calls, 2)
  }

  func testTriggerDuringTheTrailingSyncRunsOneMore() async {
    let firstStarted = expectation(description: "First sync started")
    let trailingStarted = expectation(description: "Trailing sync started")
    let followUpStarted = expectation(description: "Follow-up sync started")
    let extraSync = expectation(description: "Another sync started")
    extraSync.isInverted = true
    let probe = HookSyncProbe(
      started: [firstStarted, trailingStarted, followUpStarted], extra: extraSync)
    let hooks = SnipSnapCloudLifecycleHooks { await probe.sync() }

    let firstReturned = startRun(hooks)
    await fulfillment(of: [firstStarted], timeout: 2)
    await triggerCoalesced(hooks)
    probe.release(1)
    await fulfillment(of: [trailingStarted], timeout: 2)
    await triggerCoalesced(hooks)
    probe.release(2)
    await fulfillment(of: [followUpStarted], timeout: 2)
    probe.release(3)
    await fulfillment(of: [firstReturned], timeout: 2)
    await fulfillment(of: [extraSync], timeout: 0.2)

    XCTAssertEqual(probe.calls, 3)
  }

  func testCoalescedTriggerReturnsBeforeTheTrailingSyncRuns() async {
    let firstStarted = expectation(description: "First sync started")
    let trailingStarted = expectation(description: "Trailing sync started")
    let extraSync = expectation(description: "Another sync started")
    extraSync.isInverted = true
    let probe = HookSyncProbe(started: [firstStarted, trailingStarted], extra: extraSync)
    let hooks = SnipSnapCloudLifecycleHooks { await probe.sync() }

    let firstReturned = startRun(hooks)
    await fulfillment(of: [firstStarted], timeout: 2)
    await triggerCoalesced(hooks)
    XCTAssertEqual(probe.calls, 1, "The trailing sync waits for the running one")

    probe.release(1)
    await fulfillment(of: [trailingStarted], timeout: 2)
    probe.release(2)
    await fulfillment(of: [firstReturned], timeout: 2)
    await fulfillment(of: [extraSync], timeout: 0.2)
    XCTAssertEqual(probe.calls, 2)
  }

  private func startRun(_ hooks: SnipSnapCloudLifecycleHooks) -> XCTestExpectation {
    let returned = expectation(description: "Triggering run returned")
    Task {
      await hooks.run()
      returned.fulfill()
    }
    return returned
  }

  /// A trigger during a sync returns at once; a trigger that ran a sync here would hang on the probe.
  private func triggerCoalesced(_ hooks: SnipSnapCloudLifecycleHooks) async {
    let returned = expectation(description: "Coalesced trigger returned")
    Task {
      await hooks.run()
      returned.fulfill()
    }
    await fulfillment(of: [returned], timeout: 2)
  }
}

/// Holds each sync open until the test releases it.
@MainActor
private final class HookSyncProbe {
  private(set) var calls = 0
  private let started: [XCTestExpectation]
  private let extra: XCTestExpectation
  private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
  private var released: Set<Int> = []

  init(started: [XCTestExpectation], extra: XCTestExpectation) {
    self.started = started
    self.extra = extra
  }

  func sync() async {
    calls += 1
    let call = calls
    if started.indices.contains(call - 1) {
      started[call - 1].fulfill()
    } else {
      extra.fulfill()
    }
    guard !released.contains(call) else { return }
    await withCheckedContinuation { releases[call] = $0 }
  }

  func release(_ call: Int) {
    released.insert(call)
    releases.removeValue(forKey: call)?.resume()
  }
}
