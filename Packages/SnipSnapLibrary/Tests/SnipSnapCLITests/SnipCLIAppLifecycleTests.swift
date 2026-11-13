import Darwin
import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnapCLI

final class SnipCLIAppLifecycleTests: XCTestCase {
  @MainActor
  func testTerminationWhilePublicationWaitsForStoreLockDoesNotRepublishReadiness() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let current = instance()
    let lifecycle = SnipCLIAppLifecycle(store: store, instance: current)
    let reconciled = expectation(description: "Account check reached publication")
    var descriptor: Int32 = -1
    defer {
      if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
    }
    let startup = Task {
      try await lifecycle.start(reconcile: {
        let lock = root.appendingPathComponent("Agent/Commands/requests.lock")
        descriptor = open(lock.path, O_RDWR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        reconciled.fulfill()
        return "checked"
      }, scheduleSync: {})
    }
    await fulfillment(of: [reconciled], timeout: 2)
    // Reconciliation returns synchronously on MainActor before the waiter can
    // resume, so publication has passed the lifecycle's cancellation check.
    lifecycle.beginTermination()
    XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
    do {
      try await startup.value
      XCTFail("Cancellation at the publication boundary must reject readiness.")
    } catch is CancellationError {}
    let ready = try await store.appReadiness()
    XCTAssertNil(ready)
    let request = SnipCLIRequest(action: .createList(name: "Must not be admitted"), scopeToken: "checked")
    do {
      _ = try await store.enqueue(request, readiness: .init(instance: current, scopeToken: "checked"))
      XCTFail("A terminating app must not admit a new command.")
    } catch SnipCLIRequestError.scopeChanged {}
    catch SnipCLIAppReadinessError.unavailable {}
    let state = try await store.state(for: request.requestID)
    XCTAssertEqual(state, .missing)
    try await lifecycle.stop()
  }

  @MainActor
  func testOverlappingForegroundReconciliationWaitsAndRunsOneTrailingCheck() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let lifecycle = SnipCLIAppLifecycle(store: store, instance: instance())
    let account = ReadinessGate()
    var calls = 0
    let startup = Task {
      try await lifecycle.start(reconcile: {
        calls += 1
        if calls == 1 { await account.pause() }
        return "account-\(calls)"
      }, scheduleSync: {})
    }
    await account.waitUntilPaused()
    let completedEarly = expectation(description: "Foreground must await the current account check")
    completedEarly.isInverted = true
    let foreground = Task {
      try await lifecycle.refresh()
      completedEarly.fulfill()
    }
    await fulfillment(of: [completedEarly], timeout: 0.05)
    XCTAssertEqual(calls, 1)
    let premature = try await store.appReadiness()
    XCTAssertNil(premature)
    await account.release()
    try await startup.value
    try await foreground.value
    XCTAssertEqual(calls, 2)
    let ready = try await store.appReadiness()
    XCTAssertEqual(ready?.scopeToken, "account-2")
    try await lifecycle.stop()
  }

  @MainActor
  func testTerminationRejectsLateCompletionAndFurtherReconciliation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let lifecycle = SnipCLIAppLifecycle(store: store, instance: instance())
    let account = ReadinessGate()
    var calls = 0
    var scheduled = false
    let startup = Task {
      try await lifecycle.start(reconcile: {
        calls += 1
        if calls == 1 { await account.pause() }
        return "checked"
      }, scheduleSync: { scheduled = true })
    }
    await account.waitUntilPaused()
    try await lifecycle.stop()
    await account.release()
    do { try await startup.value; XCTFail("Termination must stop readiness publication.") }
    catch is CancellationError {}
    catch SnipCLIAppReadinessError.unavailable {}
    do { try await lifecycle.refresh(); XCTFail("A terminated lifecycle cannot restart.") }
    catch SnipCLIAppReadinessError.unavailable {}
    XCTAssertEqual(calls, 1)
    XCTAssertFalse(scheduled)
    let ready = try await store.appReadiness()
    XCTAssertNil(ready)
  }

  @MainActor
  func testRefreshAfterFailedAppSessionStartRetriesTheSessionMarker() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    // A file where the commands directory belongs makes the session marker write fail.
    let commands = root.appendingPathComponent("Agent/Commands")
    try FileManager.default.createDirectory(at: commands.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: commands.path, contents: Data()))
    let store = SnipCLIRequestStore(rootURL: root)
    let current = instance()
    let lifecycle = SnipCLIAppLifecycle(store: store, instance: current)
    var calls = 0
    do {
      try await lifecycle.start(reconcile: {
        calls += 1
        return "checked"
      }, scheduleSync: {})
      XCTFail("Startup must fail when the app session marker cannot be written.")
    } catch SnipCLIAppReadinessError.unavailable {
      XCTFail("A failed session marker write is not a lifecycle rejection.")
    } catch {}
    XCTAssertEqual(calls, 0)
    do {
      try await lifecycle.start(reconcile: { "again" }, scheduleSync: {})
      XCTFail("A started lifecycle cannot start twice.")
    } catch SnipCLIAppReadinessError.unavailable {}

    try FileManager.default.removeItem(at: commands)
    try await lifecycle.refresh()
    XCTAssertEqual(calls, 1)
    let ready = try await store.appReadiness()
    XCTAssertEqual(ready, SnipCLIAppReadiness(instance: current, scopeToken: "checked"))
    try await lifecycle.stop()
  }

  @MainActor
  func testTerminationWhileAppSessionStartWaitsForStoreLockDoesNotAdmit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let commands = root.appendingPathComponent("Agent/Commands")
    try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
    let lock = commands.appendingPathComponent("requests.lock")
    XCTAssertTrue(FileManager.default.createFile(atPath: lock.path, contents: Data()))
    let descriptor = open(lock.path, O_RDWR)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
    defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
    let store = SnipCLIRequestStore(rootURL: root)
    let current = instance()
    let lifecycle = SnipCLIAppLifecycle(store: store, instance: current)
    var calls = 0
    var scheduled = false
    let startup = Task {
      try await lifecycle.start(reconcile: {
        calls += 1
        return "checked"
      }, scheduleSync: { scheduled = true })
    }
    // The store tightens the directory to 0o700 just before it waits for the lock.
    let deadline = Date().addingTimeInterval(5)
    while try FileManager.default.attributesOfItem(atPath: commands.path)[.posixPermissions]
      as? Int != 0o700, Date() < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: commands.path)[.posixPermissions] as? Int, 0o700,
      "The app session start must reach the store lock before termination."
    )
    lifecycle.beginTermination()
    XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
    do {
      try await startup.value
      XCTFail("Termination during the app session start must reject readiness.")
    } catch is CancellationError {}
    catch SnipCLIAppReadinessError.unavailable {}
    do { try await lifecycle.refresh(); XCTFail("A terminated lifecycle cannot restart.") }
    catch SnipCLIAppReadinessError.unavailable {}
    XCTAssertEqual(calls, 0)
    XCTAssertFalse(scheduled)
    let ready = try await store.appReadiness()
    XCTAssertNil(ready)
    let request = SnipCLIRequest(action: .createList(name: "Must not be admitted"), scopeToken: "checked")
    do {
      _ = try await store.enqueue(request, readiness: .init(instance: current, scopeToken: "checked"))
      XCTFail("A terminating app must not admit a new command.")
    } catch SnipCLIRequestError.scopeChanged {}
    catch SnipCLIAppReadinessError.unavailable {}
    try await lifecycle.stop()
  }

  private func instance() -> SnipCLIAppInstance {
    SnipCLIAppInstance(pid: 123, launchDate: Date(timeIntervalSince1970: 10),
                       applicationURL: URL(fileURLWithPath: "/tmp/Example.app"))
  }

  @MainActor
  func testBackgroundStartupAdmitsAfterAccountCheckWhileOptionalSyncIsHeld() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let instance = SnipCLIAppInstance(pid: 123, launchDate: Date(timeIntervalSince1970: 10),
                                     applicationURL: URL(fileURLWithPath: "/tmp/Example.app"))
    let lifecycle = SnipCLIAppLifecycle(store: store, instance: instance)
    let account = ReadinessGate()
    let optionalSync = ReadinessGate()
    let startup = Task {
      try await lifecycle.start(reconcile: {
        await account.pause()
        return "checked-account"
      }, scheduleSync: { await optionalSync.pause() })
    }
    await account.waitUntilPaused()
    let beforeCheck = try await store.appReadiness()
    XCTAssertNil(beforeCheck)
    await account.release()
    await optionalSync.waitUntilPaused()
    let ready = try await store.appReadiness()
    XCTAssertEqual(ready?.scopeToken, "checked-account")
    if let ready {
      let request = SnipCLIRequest(action: .extended(.application(.status)), scopeToken: ready.scopeToken)
      _ = try await store.enqueue(request, readiness: ready)
      let state = try await store.state(for: request.requestID)
      XCTAssertEqual(state, .pending)
    }
    await optionalSync.release()
    try await startup.value
    try await lifecycle.stop()
  }
}

private actor ReadinessGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var paused = false

  func pause() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      paused = true
      waiters.forEach { $0.resume() }
      waiters = []
    }
  }

  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    continuation?.resume()
    continuation = nil
    paused = false
  }
}
