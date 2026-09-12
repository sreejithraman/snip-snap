import CloudKit
import Foundation
import SnipSnapCore
@testable import SnipSnapPersistence
import Synchronization
import XCTest
@testable import SnipSnapCloud

final class CloudKitOperationRetryTests: XCTestCase {
  func testTryAgainWaitsForTheFinalServerDeadline() async throws {
    let clock = RetryClock()
    let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
    let calls = Mutex<[Duration]>([])
    let error = CKError(_nsError: NSError(
      domain: CKErrorDomain,
      code: CKError.Code.requestRateLimited.rawValue,
      userInfo: [CKErrorRetryAfterKey: 10]
    ))
    do {
      try await retry.run {
        calls.withLock { $0.append(clock.elapsed) }
        throw error
      }
      XCTFail("Expected the bounded attempt to report the pause")
    } catch {
      XCTAssertEqual(SnipSnapCloudSyncIssueMapper.issue(for: error), .retryingSoon)
    }

    try await retry.run {
      calls.withLock { $0.append(clock.elapsed) }
    }

    XCTAssertEqual(calls.withLock { $0 }, [.zero, .seconds(10), .seconds(20), .seconds(30)])
  }

  func testServiceUnavailableRetriesWithoutAnotherUserAction() async throws {
    let clock = RetryClock()
    let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
    let calls = Mutex<[Duration]>([])
    let value = try await retry.run {
      let count = calls.withLock { $0.append(clock.elapsed); return $0.count }
      if count < 3 { throw Self.cloudError(.serviceUnavailable, retryAfter: 7.5) }
      return "synced"
    }
    XCTAssertEqual(value, "synced")
    XCTAssertEqual(calls.withLock { $0 }, [.zero, .seconds(7.5), .seconds(15)])
  }

  func testFallbackBackoffSpansCallsAndResetsAfterSuccess() async throws {
    let clock = RetryClock()
    let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
    let calls = Mutex<[Duration]>([])
    for _ in 0..<3 {
      do {
        try await retry.run {
          calls.withLock { $0.append(clock.elapsed) }
          throw Self.cloudError(.zoneBusy)
        }
        XCTFail("Expected three failed attempts")
      } catch {}
    }
    try await retry.run { calls.withLock { $0.append(clock.elapsed) } }
    XCTAssertEqual(calls.withLock { $0 }, [0, 1, 3, 7, 15, 31, 63, 127, 191, 255].map { .seconds($0) })

    let attempts = Mutex<Int>(0)
    try await retry.run {
      let count = attempts.withLock { $0 += 1; return $0 }
      if count == 1 { throw Self.cloudError(.zoneBusy) }
    }
    XCTAssertEqual(clock.elapsed, .seconds(256))
  }

  func testElapsedDeadlineDoesNotAddAnotherFullDelay() async throws {
    let clock = RetryClock()
    let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
    do {
      try await retry.run { throw Self.cloudError(.requestRateLimited, retryAfter: 10) }
    } catch {}
    clock.advance(.seconds(15))
    let requestTime = try await retry.run { clock.elapsed }
    XCTAssertEqual(requestTime, .seconds(35))
  }

  func testCancellingWaitKeepsTheDeadlineForTheNextCall() async throws {
    let clock = RetryClock()
    let cancelWait = Mutex<Bool>(true)
    let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { delay in
      if cancelWait.withLock({ $0 }) { throw CancellationError() }
      clock.advance(delay)
    })
    do {
      try await retry.run { throw Self.cloudError(.requestRateLimited, retryAfter: 10) }
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    cancelWait.withLock { $0 = false }
    let requestTime = try await retry.run { clock.elapsed }
    XCTAssertEqual(requestTime, .seconds(10))
  }

  func testPermanentFailureDoesNotRetryOrDelayTheNextCall() async throws {
    let clock = RetryClock()
    let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
    let calls = Mutex<Int>(0)
    do {
      try await retry.run {
        calls.withLock { $0 += 1 }
        throw Self.cloudError(.permissionFailure)
      }
      XCTFail("Expected permission failure")
    } catch let error as CKError {
      XCTAssertEqual(error.code, .permissionFailure)
    }
    let requestTime = try await retry.run { clock.elapsed }
    XCTAssertEqual(calls.withLock { $0 }, 1)
    XCTAssertEqual(requestTime, .zero)
  }

  func testPartialFailureKeepsLongestNestedCooldownWithoutRepeatingPartialWork() async throws {
    let clock = RetryClock()
    let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
    let calls = Mutex<Int>(0)
    let partial = CKError(_nsError: NSError(
      domain: CKErrorDomain,
      code: CKError.Code.partialFailure.rawValue,
      userInfo: [CKPartialErrorsByItemIDKey: [
        "one": Self.cloudError(.requestRateLimited, retryAfter: 10),
        "two": Self.cloudError(.serviceUnavailable, retryAfter: 20),
        "three": Self.cloudError(.quotaExceeded),
      ]]
    ))
    do {
      try await retry.run { calls.withLock { $0 += 1 }; throw partial }
      XCTFail("Expected partial failure to reach its caller")
    } catch let error as CKError {
      XCTAssertEqual(error.code, .partialFailure)
    }
    let requestTime = try await retry.run { clock.elapsed }
    XCTAssertEqual(calls.withLock { $0 }, 1)
    XCTAssertEqual(requestTime, .seconds(20))
  }

  func testAllTransientNestedZoneFailuresRetryWithTheLongestCooldown() async throws {
    let clock = RetryClock()
    let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
    let attempts = Mutex<[Duration]>([])
    let first = CKRecordZone.ID(zoneName: "first")
    let second = CKRecordZone.ID(zoneName: "second")
    let nested = CKError(_nsError: NSError(
      domain: CKErrorDomain,
      code: CKError.Code.partialFailure.rawValue,
      userInfo: [CKPartialErrorsByItemIDKey: [
        "limited": Self.cloudError(.requestRateLimited, retryAfter: 5),
        "unavailable": Self.cloudError(.serviceUnavailable, retryAfter: 20),
      ]]
    ))
    let results: [CKRecordZone.ID: Result<CKRecordZone, any Error>] = [
      first: .failure(nested),
      second: .failure(Self.cloudError(.requestRateLimited, retryAfter: 10)),
    ]

    let value = try await retry.run {
      let count = attempts.withLock { $0.append(clock.elapsed); return $0.count }
      if count < 3 {
        try CloudKitCollectionControlTransport.requireZoneSuccess(results)
      }
      return "created"
    }

    XCTAssertEqual(value, "created")
    XCTAssertEqual(attempts.withLock { $0 }, [.zero, .seconds(20), .seconds(40)])
  }

  func testConcurrentCallerWaitsForActiveRequestAndItsCooldown() async throws {
    let clock = RetryClock()
    let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
    let gate = RetryRequestGate()
    let entered = expectation(description: "First request entered")
    let premature = expectation(description: "Second request must wait")
    premature.isInverted = true
    let secondMayRun = Mutex(false)
    let first = Task<Void, any Error> {
      try await retry.run { () async throws -> Void in
        entered.fulfill()
        await gate.wait()
        throw CloudKitOperationRetryTests.mixedPartialFailure()
      }
    }
    await fulfillment(of: [entered], timeout: 1)
    let second = Task {
      try await retry.run {
        if !secondMayRun.withLock({ $0 }) { premature.fulfill() }
        return clock.elapsed
      }
    }
    await fulfillment(of: [premature], timeout: 0.05)
    secondMayRun.withLock { $0 = true }
    await gate.release()
    do { try await first.value; XCTFail("Expected partial failure") } catch {}
    let requestTime = try await second.value
    XCTAssertEqual(requestTime, .seconds(10))
  }

  func testCancelledQueuedRequestDoesNotRunOrBlockTheNextCaller() async throws {
    let retry = CloudKitOperationRetry()
    let gate = RetryRequestGate()
    let entered = expectation(description: "First request entered")
    let first = Task<Void, any Error> {
      try await retry.run { entered.fulfill(); await gate.wait() }
    }
    await fulfillment(of: [entered], timeout: 1)
    let queued = expectation(description: "Second caller started")
    let cancelled = Task {
      queued.fulfill()
      try await retry.run { XCTFail("Cancelled request ran") }
    }
    await fulfillment(of: [queued], timeout: 1)
    cancelled.cancel()
    do { try await cancelled.value; XCTFail("Expected cancellation") }
    catch is CancellationError {}
    let next = Task { try await retry.run { "next" } }
    await gate.release()
    try await first.value
    let value = try await next.value
    XCTAssertEqual(value, "next")
  }

  func testZoneSaveResultsKeepEveryFailureAndTheLongestCooldown() async throws {
    let clock = RetryClock()
    let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
    let attempts = Mutex<Int>(0)
    let first = CKRecordZone.ID(zoneName: "first")
    let second = CKRecordZone.ID(zoneName: "second")
    let results: [CKRecordZone.ID: Result<CKRecordZone, any Error>] = [
      first: .failure(Self.cloudError(.requestRateLimited, retryAfter: 5)),
      second: .failure(Self.cloudError(.serviceUnavailable, retryAfter: 20)),
    ]
    do {
      try await retry.run {
        attempts.withLock { $0 += 1 }
        try CloudKitCollectionControlTransport.requireZoneSuccess(results)
      }
      XCTFail("Expected the zone failures")
    } catch let error as CKError {
      XCTAssertEqual(error.partialErrorsByItemID?.count, 2)
    }
    let requestTime = try await retry.run { clock.elapsed }
    XCTAssertEqual(attempts.withLock { $0 }, 3)
    XCTAssertEqual(requestTime, .seconds(60))
  }

  func testZoneDeleteResultsIgnoreMissingZonesAndKeepOtherDeadlines() async throws {
    let clock = RetryClock()
    let retry = CloudKitOperationRetry(now: { clock.now }, sleep: { clock.advance($0) })
    let attempts = Mutex<Int>(0)
    let missing = CKRecordZone.ID(zoneName: "missing")
    let first = CKRecordZone.ID(zoneName: "first")
    let second = CKRecordZone.ID(zoneName: "second")
    let results: [CKRecordZone.ID: Result<Void, any Error>] = [
      missing: .failure(Self.cloudError(.zoneNotFound)),
      first: .failure(Self.cloudError(.requestRateLimited, retryAfter: 20)),
      second: .failure(Self.cloudError(.serviceUnavailable, retryAfter: 5)),
    ]
    do {
      try await retry.run {
        attempts.withLock { $0 += 1 }
        try CloudKitCollectionControlTransport.requireZoneSuccess(results, ignoringMissingZones: true)
      }
      XCTFail("Expected the remaining zone failures")
    } catch let error as CKError {
      XCTAssertEqual(error.partialErrorsByItemID?.count, 2)
      XCTAssertNil(error.partialErrorsByItemID?[missing])
    }
    let requestTime = try await retry.run { clock.elapsed }
    XCTAssertEqual(attempts.withLock { $0 }, 3)
    XCTAssertEqual(requestTime, .seconds(60))
    try CloudKitCollectionControlTransport.requireZoneSuccess(
      [missing: Result<Void, any Error>.failure(Self.cloudError(.zoneNotFound))],
      ignoringMissingZones: true
    )
  }

  func testAllTransientZoneSetupFailureStaysInSettingUp() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PartialZoneSetup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try JSONSnipLibrary(fileURL: root.appendingPathComponent("source.json"))
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "owner")
    let lifecycle = SnipSnapICloudSyncLifecycle(
      rootURL: root.appendingPathComponent("SyncMode", isDirectory: true),
      sourceLibrary: source,
      syncModeStore: nil,
      cloudScope: "private",
      accountLineage: "account-a",
      ownerName: "owner",
      controlTransport: AllTransientZoneFailureControlTransport(),
      makeRecordTransport: { context in
        FakeCloudRecordTransport(server: FakeCloudServer(), namespace: context.namespace)
      },
      makeDescriptor: { descriptor }
    )

    let outcome = try await lifecycle.enableICloudSync()

    XCTAssertEqual(outcome, .settingUp(.retryingSoon))
  }

  private static func mixedPartialFailure() -> CKError {
    CKError(_nsError: NSError(
      domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
      userInfo: [CKPartialErrorsByItemIDKey: [
        "limited": cloudError(.requestRateLimited, retryAfter: 10),
        "denied": cloudError(.permissionFailure),
      ]]
    ))
  }

  private static func cloudError(_ code: CKError.Code, retryAfter: Double? = nil) -> CKError {
    CKError(_nsError: NSError(
      domain: CKErrorDomain,
      code: code.rawValue,
      userInfo: retryAfter.map { [CKErrorRetryAfterKey: $0] } ?? [:]
    ))
  }

}

private final class RetryClock: Sendable {
  private let origin = ContinuousClock.now
  var now: ContinuousClock.Instant { origin.advanced(by: elapsed) }
  private let value = Mutex<Duration>(.zero)
  var elapsed: Duration { value.withLock { $0 } }
  func advance(_ duration: Duration) { value.withLock { $0 += duration } }
}

private actor RetryRequestGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

private actor AllTransientZoneFailureControlTransport: CloudCollectionControlTransport {
  func fetchControl() async throws -> CloudCollectionControlRecord? { nil }

  func createZones(_ zones: Set<CloudZoneID>) async throws {
    let errors = Dictionary(uniqueKeysWithValues: zones.map { zone in
      (zone.name, CKError(_nsError: NSError(
        domain: CKErrorDomain,
        code: CKError.Code.requestRateLimited.rawValue
      )))
    })
    throw CKError(_nsError: NSError(
      domain: CKErrorDomain,
      code: CKError.Code.partialFailure.rawValue,
      userInfo: [CKPartialErrorsByItemIDKey: errors]
    ))
  }

  func saveControl(
    _ descriptor: CloudCollectionDescriptor,
    replacing version: Data?
  ) async throws -> CloudCollectionControlSaveResult {
    throw CloudCollectionError.invalidDescriptor
  }

  func deleteZones(_ zones: Set<CloudZoneID>) async throws {}
}
