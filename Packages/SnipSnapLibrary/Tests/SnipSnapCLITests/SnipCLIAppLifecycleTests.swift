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

extension SnipCLIAppLifecycleTests {
  @MainActor
  func testReturningReadinessJoinsTheFinalPublishedPassAndCancelsOnlyOneWaiter() async throws {
    try await withReturningReadinessWork { work in
      let store = SnipCLIRequestStore(rootURL: work.root)
      let lifecycle = SnipCLIAppLifecycle(store: store, instance: self.instance())
      work.lifecycle = lifecycle
      let first = work.gate()
      let second = work.gate()
      let scheduled = ReturningReadinessSignal()
      var calls = 0
      var startupError: (any Error)?
      let startup = work.start {
        do {
          try await lifecycle.start(reconcile: {
            calls += 1
            if calls == 1 { await first.pause(); return "discarded-first-pass" }
            await second.pause()
            return "final-published-pass"
          }, scheduleSync: { scheduled.fire() })
        } catch { startupError = error }
      }
      guard await work.ready(first.entered, "first reconciliation") else { return }
      var cancelledResult: Result<String, any Error>?
      let cancelledStarted = ReturningReadinessSignal()
      let cancelled = work.start {
        cancelledStarted.fire()
        do { cancelledResult = .success(try await lifecycle.refreshAndReturnScope()) }
        catch { cancelledResult = .failure(error) }
      }
      var followerResult: Result<String, any Error>?
      let followerStarted = ReturningReadinessSignal()
      let follower = work.start {
        followerStarted.fire()
        do { followerResult = .success(try await lifecycle.refreshAndReturnScope()) }
        catch { followerResult = .failure(error) }
      }
      guard await work.ready(cancelledStarted, "cancelled caller dispatch"),
            await work.ready(followerStarted, "surviving caller dispatch") else { return }
      cancelled.task.cancel()
      guard await work.prompt(cancelled.finished, "cancelled waiter") else { return }
      guard case .failure(let error) = cancelledResult else {
        XCTFail("Cancelling one waiter must not produce a readiness token.")
        return
      }
      XCTAssertTrue(error is CancellationError)
      XCTAssertTrue(first.isHeld)
      XCTAssertFalse(startup.finished.isSet)
      XCTAssertFalse(follower.finished.isSet)
      XCTAssertEqual(calls, 1)
      let during = try await store.appReadiness()
      XCTAssertNil(during)

      first.release()
      guard await work.ready(second.entered, "coalesced final reconciliation") else { return }
      XCTAssertEqual(calls, 2)
      XCTAssertFalse(follower.finished.isSet)
      let beforeFinal = try await store.appReadiness()
      XCTAssertNil(beforeFinal)
      second.release()
      guard await work.prompt(follower.finished, "surviving final token"),
            await work.prompt(startup.finished, "original startup") else { return }
      if let startupError { throw startupError }
      XCTAssertEqual(try XCTUnwrap(followerResult).get(), "final-published-pass")
      let ready = try await store.appReadiness()
      XCTAssertEqual(ready?.scopeToken, "final-published-pass")
      XCTAssertEqual(calls, 2)
      guard await work.ready(scheduled, "optional scheduling after publication") else { return }
    }
  }

  @MainActor
  func testReturningReadinessPreservesOriginalReconcileErrorAndCanRetry() async throws {
    let root = returningReadinessRoot()
    let store = SnipCLIRequestStore(rootURL: root)
    let lifecycle = SnipCLIAppLifecycle(store: store, instance: instance())
    let failure = ReturningReadinessFailure()
    var calls = 0
    do {
      try await lifecycle.start(reconcile: {
        calls += 1
        if calls == 1 { throw failure }
        return "checked-after-error"
      }, scheduleSync: {})
      XCTFail("A failed required reconciliation cannot publish readiness.")
    } catch { XCTAssertTrue((error as? ReturningReadinessFailure) === failure) }
    let failed = try await store.appReadiness()
    XCTAssertNil(failed)

    let token = try await lifecycle.refreshAndReturnScope()

    XCTAssertEqual(token, "checked-after-error")
    XCTAssertEqual(calls, 2)
    let recovered = try await store.appReadiness()
    XCTAssertEqual(recovered?.scopeToken, "checked-after-error")
    try await lifecycle.stop()
  }

  @MainActor
  func testTerminationRejectsReturningWaitersWithoutPublishingAHeldPass() async throws {
    try await withReturningReadinessWork { work in
      let store = SnipCLIRequestStore(rootURL: work.root)
      let lifecycle = SnipCLIAppLifecycle(store: store, instance: self.instance())
      work.lifecycle = lifecycle
      let gate = work.gate()
      var scheduled = false
      var startupError: (any Error)?
      let startup = work.start {
        do {
          try await lifecycle.start(reconcile: {
            // The reconciliation effect stays held even when its waiting worker is cancelled.
            let effect = Task { await gate.pause() }
            await effect.value
            return "must-not-publish"
          }, scheduleSync: { scheduled = true })
        } catch { startupError = error }
      }
      guard await work.ready(gate.entered, "held required reconciliation") else { return }
      var result: Result<String, any Error>?
      let started = ReturningReadinessSignal()
      let follower = work.start {
        started.fire()
        do { result = .success(try await lifecycle.refreshAndReturnScope()) }
        catch { result = .failure(error) }
      }
      guard await work.ready(started, "returning waiter dispatch") else { return }
      lifecycle.beginTermination()
      guard await work.prompt(follower.finished, "terminated readiness waiter") else { return }
      guard case .failure(let error) = result else {
        XCTFail("Termination must not fabricate a final scope.")
        return
      }
      XCTAssertTrue(error is CancellationError)
      XCTAssertTrue(gate.isHeld)
      XCTAssertFalse(startup.finished.isSet)
      gate.release()
      guard await work.ready(startup.finished, "cancelled original worker joined") else { return }
      XCTAssertTrue(startupError is CancellationError)
      XCTAssertFalse(scheduled)
      let ready = try await store.appReadiness()
      XCTAssertNil(ready)
    }
  }
}

private func returningReadinessRoot() -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReturningReadiness-\(UUID())")
  print("OFFLINE-CHECKED-APPLICATION retained unique root: \(root.path)")
  return root
}

private final class ReturningReadinessFailure: Error, @unchecked Sendable {}

private final class ReturningReadinessSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
  var isSet: Bool { lock.withLock { fired } }

  func fire() {
    let pending = lock.withLock {
      fired = true
      let pending = Array(waiters.values)
      waiters.removeAll()
      return pending
    }
    pending.forEach { $0.resume(returning: true) }
  }

  func observe() async -> Bool {
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediate: Bool? = lock.withLock {
          if fired { return true }
          if Task.isCancelled { return false }
          waiters[id] = continuation
          return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
      }
    } onCancel: {
      self.lock.withLock { self.waiters.removeValue(forKey: id) }?.resume(returning: false)
    }
  }

  func wait(for timeout: Duration) async -> Bool {
    if isSet { return true }
    guard timeout > .zero else { return false }
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask { await self.observe() }
      group.addTask {
        do { try await Task.sleep(for: timeout) } catch {}
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }
}

private final class ReturningReadinessGate: @unchecked Sendable {
  let entered = ReturningReadinessSignal()
  private let released = ReturningReadinessSignal()
  var isHeld: Bool { entered.isSet && !released.isSet }
  func pause() async { entered.fire(); _ = await released.observe() }
  func release() { released.fire() }
}

@MainActor
private final class ReturningReadinessTask {
  let finished: ReturningReadinessSignal
  let task: Task<Void, Never>
  init(_ operation: @escaping @MainActor () async -> Void) {
    let finished = ReturningReadinessSignal()
    self.finished = finished
    task = Task { await operation(); finished.fire() }
  }
}

@MainActor
private final class ReturningReadinessWork {
  let root = returningReadinessRoot()
  var lifecycle: SnipCLIAppLifecycle?
  private var gates: [ReturningReadinessGate] = []
  private var tasks: [ReturningReadinessTask] = []
  private var retainedAfterFailedJoin: ReturningReadinessWork?

  func gate() -> ReturningReadinessGate {
    let gate = ReturningReadinessGate()
    gates.append(gate)
    return gate
  }

  func start(_ operation: @escaping @MainActor () async -> Void) -> ReturningReadinessTask {
    let task = ReturningReadinessTask(operation)
    tasks.append(task)
    return task
  }

  func ready(_ signal: ReturningReadinessSignal, _ stage: String) async -> Bool {
    let ready = await signal.wait(for: .seconds(30))
    XCTAssertTrue(ready, "Readiness setup/cleanup failed: \(stage)")
    return ready
  }

  func prompt(_ signal: ReturningReadinessSignal, _ stage: String) async -> Bool {
    let ready = await signal.wait(for: .seconds(2))
    XCTAssertTrue(ready, "Readiness caller failed to finish promptly: \(stage)")
    return ready
  }

  func cleanUp() async {
    let cleanup = Task { @MainActor [self] in
      lifecycle?.beginTermination()
      gates.forEach { $0.release() }
      tasks.forEach { $0.task.cancel() }
      if let lifecycle {
        _ = start {
          do { try await lifecycle.stop() }
          catch { XCTFail("Readiness store cleanup failed: \(error)") }
        }
      }
      let deadline = ContinuousClock.now + .seconds(30)
      var settled = true
      for operation in tasks {
        let joined = await operation.finished.wait(for: deadline - ContinuousClock.now)
        XCTAssertTrue(joined, "Readiness cleanup did not join; retaining live ownership and root")
        if joined { await operation.task.value } else { settled = false }
      }
      guard settled else { retainedAfterFailedJoin = self; return }
      tasks.removeAll()
      gates.removeAll()
      lifecycle = nil
    }
    await cleanup.value
  }
}

@MainActor
private func withReturningReadinessWork(
  _ operation: @MainActor (ReturningReadinessWork) async throws -> Void
) async throws {
  let work = ReturningReadinessWork()
  do { try await operation(work) }
  catch { await work.cleanUp(); throw error }
  await work.cleanUp()
}


extension SnipCLIAppLifecycleTests {
  @MainActor
  func testOriginalTargetApplicationHasOneOwnerWhenItsFirstReadinessWaiterCancels() async throws {
    try await withReturningReadinessWork { work in
      let persistence = try SwiftDataSyncModePersistence(rootURL: work.root.appendingPathComponent("mode"))
      let library = try await persistence.activeLibrary()
      let saved = SavedSnipsSession(library: library)
      let originalRead = try await saved.checkedRead(sortedBy: .manual)
      let target = try XCTUnwrap(originalRead.target)
      let store = SnipCLIRequestStore(rootURL: work.root)
      let lifecycle = SnipCLIAppLifecycle(store: store, instance: self.instance())
      work.lifecycle = lifecycle
      try await lifecycle.start(reconcileChecked: {
        let read = try await saved.checkedRead(sortedBy: .manual)
        return ("original-scope", read.publication)
      }, scheduleSync: {})
      let gate = work.gate()
      var applications = 0
      let apply: SnipCLIAppLifecycle.CheckedReconcile = {
        applications += 1
        let prepared = try await saved.prepareLibraryApplication(target.library, recoveryScope: target.recoveryScope,
          replacing: true, sortedBy: .manual)
        await gate.pause()
        let closing = try XCTUnwrap(prepared.read.publication).beginApplication()
        do { try prepared.install(within: closing) } catch { closing.finish(); throw error }
        closing.finish()
        await prepared.finishRetiredActions()
        return ("original-scope", prepared.read.publication)
      }
      var firstError: (any Error)?
      let first = work.start {
        do { _ = try await lifecycle.refreshAndReturnScope(for: target, reconcile: apply) }
        catch { firstError = error }
      }
      guard await work.ready(gate.entered, "original target required application") else { return }
      let followerStarted = ReturningReadinessSignal()
      var followerScope: String?
      let follower = work.start {
        followerStarted.fire()
        do { followerScope = try await lifecycle.refreshAndReturnScope(for: target, reconcile: apply) }
        catch { XCTFail("A surviving target follower failed: \(error)") }
      }
      guard await work.ready(followerStarted, "same target follower dispatch") else { return }
      first.task.cancel()
      guard await work.prompt(first.finished, "cancelled original waiter") else { return }
      XCTAssertTrue(firstError is CancellationError)
      XCTAssertTrue(gate.isHeld)
      XCTAssertFalse(follower.finished.isSet)
      XCTAssertEqual(applications, 1)
      gate.release()
      guard await work.prompt(follower.finished, "surviving application and readiness") else { return }
      XCTAssertEqual(followerScope, "original-scope")
      XCTAssertEqual(applications, 1)
      let readiness = try await store.appReadiness()
      XCTAssertEqual(readiness?.scopeToken, "original-scope")
      _ = try await saved.performUserCommand(.add(content: "Command after surviving application", origin: .quickEntry,
        source: nil, listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: .distantPast), sortedBy: .manual)
      let reopened = try SwiftDataSyncModePersistence(rootURL: work.root.appendingPathComponent("mode"))
      let durable = try await (try await reopened.activeLibrary()).checkedSnapshot(sortedBy: .manual)
      XCTAssertEqual(durable.snips.map(\.content), ["Command after surviving application"])
    }
  }

  @MainActor
  func testRetirementBeforeTheRealReadinessWriteCannotPublishTheOldScope() async throws {
    try await withReturningReadinessWork { work in
      let persistence = try SwiftDataSyncModePersistence(rootURL: work.root.appendingPathComponent("mode"))
      let library = try await persistence.activeLibrary()
      let saved = SavedSnipsSession(library: library)
      let store = SnipCLIRequestStore(rootURL: work.root)
      let lifecycle = SnipCLIAppLifecycle(store: store, instance: self.instance())
      work.lifecycle = lifecycle
      let gate = work.gate()
      var failure: (any Error)?
      let startup = work.start {
        do {
          try await lifecycle.start(reconcileChecked: {
            let read = try await saved.checkedRead(sortedBy: .manual)
            await gate.pause()
            return ("retired-original", read.publication)
          }, scheduleSync: {})
        } catch { failure = error }
      }
      guard await work.ready(gate.entered, "actual read before readiness publication") else { return }
      try await persistence.activateEmptyCollection(namespace: ICloudSyncNamespaceBinding(scope: "private",
        accountLineage: "account-free-readiness", generation: UUID(uuidString: "11111111-2222-3333-4444-666666666666")!,
        zones: [.init(name: "replacement", ownerName: "owner")]))
      gate.release()
      guard await work.prompt(startup.finished, "retired publication failure") else { return }
      XCTAssertTrue(failure is SnipLibraryReadPublicationError)
      let readiness = try await store.appReadiness()
      XCTAssertNil(readiness, "The write boundary must refuse a retired root rather than stamp its scope")
    }
  }
}

extension SnipCLIAppLifecycleTests {
  @MainActor
  func testSupersededReadinessTargetCannotBorrowSameStoreFollowersPublication() async throws {
    try await withReturningReadinessWork { work in
      let persistence = try SwiftDataSyncModePersistence(rootURL: work.root.appendingPathComponent("mode"))
      let library = try await persistence.activeLibrary()
      let saved = SavedSnipsSession(library: library)
      let firstRead = try await saved.checkedRead(sortedBy: .manual)
      let secondRead = try await saved.checkedRead(sortedBy: .manual)
      let firstTarget = try XCTUnwrap(firstRead.target)
      let secondTarget = try XCTUnwrap(secondRead.target)
      XCTAssertEqual(firstTarget.source, secondTarget.source)
      XCTAssertFalse(firstTarget === secondTarget)

      let store = SnipCLIRequestStore(rootURL: work.root)
      let lifecycle = SnipCLIAppLifecycle(store: store, instance: self.instance())
      work.lifecycle = lifecycle
      let startupGate = work.gate()
      let startup = work.start {
        do {
          try await lifecycle.start(reconcileChecked: {
            let read = try await saved.checkedRead(sortedBy: .manual)
            await startupGate.pause()
            return ("startup", read.publication)
          }, scheduleSync: {})
        } catch { XCTFail("Startup could not join the final pass: \(error)") }
      }
      guard await work.ready(startupGate.entered, "held startup reconciliation") else { return }

      let firstDispatched = ReturningReadinessSignal()
      var firstCalls = 0
      var firstFailure: (any Error)?
      let first = work.start {
        firstDispatched.fire()
        do {
          _ = try await lifecycle.refreshAndReturnScope(for: firstTarget) {
            firstCalls += 1
            let read = try await saved.checkedRead(sortedBy: .manual)
            return ("superseded-first", read.publication)
          }
          XCTFail("A target whose reconciliation never ran cannot receive another cohort's token")
        } catch { firstFailure = error }
      }
      guard await work.ready(firstDispatched, "first target requested") else { return }
      let secondDispatched = ReturningReadinessSignal()
      var secondCalls = 0
      let applySecond: SnipCLIAppLifecycle.CheckedReconcile = {
        secondCalls += 1
        let prepared = try await saved.prepareLibraryApplication(secondTarget.library,
          recoveryScope: secondTarget.recoveryScope, replacing: true, sortedBy: .manual)
        let closing = try XCTUnwrap(prepared.read.publication).beginApplication()
        do { try prepared.install(within: closing) } catch { closing.finish(); throw error }
        closing.finish()
        await prepared.finishRetiredActions()
        return ("actual-second", prepared.read.publication)
      }
      var secondScope: String?
      let second = work.start {
        secondDispatched.fire()
        do { secondScope = try await lifecycle.refreshAndReturnScope(for: secondTarget, reconcile: applySecond) }
        catch { XCTFail("Final target failed: \(error)") }
      }
      guard await work.ready(secondDispatched, "second target supersedes first") else { return }
      let followerDispatched = ReturningReadinessSignal()
      var followerScope: String?
      let follower = work.start {
        followerDispatched.fire()
        do { followerScope = try await lifecycle.refreshAndReturnScope(for: secondTarget, reconcile: applySecond) }
        catch { XCTFail("Same-target follower failed: \(error)") }
      }
      guard await work.ready(followerDispatched, "same-target follower dispatched") else { return }
      XCTAssertTrue(startupGate.isHeld)
      XCTAssertEqual(firstCalls, 0)
      XCTAssertEqual(secondCalls, 0)
      XCTAssertFalse(follower.finished.isSet)
      startupGate.release()
      guard await work.prompt(startup.finished, "startup joins final published pass"),
            await work.prompt(first.finished, "superseded target refused"),
            await work.prompt(second.finished, "final target readiness"),
            await work.prompt(follower.finished, "same-target follower readiness") else { return }
      XCTAssertTrue(firstFailure is SnipLibraryReadPublicationError)
      XCTAssertEqual(firstCalls, 0)
      XCTAssertEqual(secondCalls, 1)
      XCTAssertEqual(secondScope, "actual-second")
      XCTAssertEqual(followerScope, "actual-second")
      let readiness = try await store.appReadiness()
      XCTAssertEqual(readiness?.scopeToken, "actual-second")
    }
  }
}
