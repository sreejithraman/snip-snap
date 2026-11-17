import Foundation
import XCTest
@testable import SnipSnapCloud
import SnipSnapCore
import SnipSnapPersistence

final class CloudSyncSessionTests: XCTestCase {
  func testTryAgainWaitsForCurrentSyncInsteadOfReportingPause() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    let prematureCompletion = expectation(description: "Retry must wait for active work")
    prematureCompletion.isInverted = true
    let retry = Task {
      defer { prematureCompletion.fulfill() }
      return try await session.retrySynchronization()
    }
    await fulfillment(of: [prematureCompletion], timeout: 0.05)
    await probe.resume()

    _ = try await first.value
    let result = try await retry.value
    XCTAssertEqual(result, .contentUpdated)
    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "retry"])
  }

  func testLocalChangesDuringSyncBecomeOneFollowUpRequest() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    for _ in 0..<20 { await session.scheduleAutomaticSync() }
    await probe.resume()
    _ = try await first.value
    await probe.waitForEvent("schedule")

    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "schedule"])
  }

  func testCancelledCallerDoesNotCancelSharedSyncWork() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    first.cancel()
    do {
      _ = try await first.value
      XCTFail("Expected the caller to stop waiting")
    } catch is CancellationError {}
    await session.scheduleAutomaticSync()
    await probe.resume()
    await probe.waitForEvent("schedule")

    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "schedule"])
  }

  func testDeleteWaitsForSyncAndCancelledQueuedDeleteDoesNotRun() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    let prematureDelete = expectation(description: "Delete must wait for sync")
    prematureDelete.isInverted = true
    let deletion = Task {
      defer { prematureDelete.fulfill() }
      return try await session.deleteSyncedContent()
    }
    await fulfillment(of: [prematureDelete], timeout: 0.05)
    deletion.cancel()
    do {
      _ = try await deletion.value
      XCTFail("Expected cancelled delete to stop")
    } catch is CancellationError {}
    await probe.resume()
    _ = try await first.value

    let events = await probe.events()
    XCTAssertEqual(events, ["sync"])
  }

  func testQueuedSyncAndTryAgainShareOneTryAgainRun() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    let sync = Task { try await session.synchronize() }
    let retry = Task { try await session.retrySynchronization() }
    try await waitForQueuedRequests(2, in: session)
    await probe.resume()

    _ = try await first.value
    let syncResult = try await sync.value
    let retryResult = try await retry.value
    XCTAssertEqual(syncResult, .contentUpdated)
    XCTAssertEqual(retryResult, .contentUpdated)
    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "retry"])
  }

  func testCancelledQueuedRequestNeverRunsAndLaterRequestsStillSync() async throws {
    let probe = SessionWorkProbe()
    let session = makeSession(probe)
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    let retry = Task { try await session.retrySynchronization() }
    try await waitForQueuedRequests(1, in: session)
    retry.cancel()
    try await waitForQueuedRequests(0, in: session)
    await probe.resume()
    do {
      _ = try await retry.value
      XCTFail("Expected the cancelled Try Again to stop waiting")
    } catch is CancellationError {}
    _ = try await first.value

    let later = try await session.synchronize()
    XCTAssertEqual(later, .contentUpdated)
    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "sync"])
  }

  func testFailureReachesAutomaticErrorHandlerOnlyWhenScheduledSyncJoinedTheRun() async throws {
    let probe = SessionWorkProbe()
    let reports = ErrorReports()
    let handlerRelease = Latch()
    let callerResumed = Latch()
    let session = SnipSnapCloudSyncSession(
      synchronize: { try await probe.run("sync"); return .contentUpdated },
      retry: { try await probe.run("retry"); throw SessionTestError("retry") },
      scheduleAutomaticSync: {
        try await probe.run("schedule")
        throw SessionTestError("schedule")
      },
      enable: { try await probe.run("enable"); return .enabled },
      delete: { try await probe.run("delete"); return .completed },
      activeLibrary: { throw SyncModePersistenceError.missingStore },
      automaticErrorHandler: { error in
        await reports.record(error as? SessionTestError ?? SessionTestError("unexpected \(error)"))
        await handlerRelease.wait()
      }
    )
    let first = Task { try await session.synchronize() }
    await probe.waitUntilPaused()
    let retry = Task { () async -> Result<SnipSnapCloudSyncResult, any Error> in
      let result: Result<SnipSnapCloudSyncResult, any Error>
      do {
        result = .success(try await session.retrySynchronization())
      } catch {
        result = .failure(error)
      }
      await callerResumed.open()
      return result
    }
    await session.scheduleAutomaticSync()
    try await waitForQueuedRequests(2, in: session)
    await probe.resume()
    _ = try await first.value

    try await waitUntil("the automatic error handler receives the failure") {
      await reports.values() == [SessionTestError("retry")]
    }
    try await Task.sleep(for: .milliseconds(50))
    let resumedDuringReport = await callerResumed.isOpen
    XCTAssertFalse(resumedDuringReport, "The caller must wait for the automatic error report")
    await handlerRelease.open()
    switch await retry.value {
    case .success:
      XCTFail("Expected Try Again that absorbed scheduled sync to fail")
    case .failure(let error):
      XCTAssertEqual(error as? SessionTestError, SessionTestError("retry"))
    }
    do {
      _ = try await session.retrySynchronization()
      XCTFail("Expected Try Again alone to fail")
    } catch let error as SessionTestError {
      XCTAssertEqual(error, SessionTestError("retry"))
      let reported = await reports.values()
      XCTAssertEqual(reported, [SessionTestError("retry")])
    }
    await session.scheduleAutomaticSync()
    await probe.waitForEvent("schedule")
    // Queued while scheduled sync runs, so it returns only after that run reports its failure.
    let later = try await session.synchronize()
    XCTAssertEqual(later, .contentUpdated)

    let reported = await reports.values()
    XCTAssertEqual(reported, [SessionTestError("retry"), SessionTestError("schedule")])
    let events = await probe.events()
    XCTAssertEqual(events, ["sync", "retry", "retry", "schedule", "sync"])
  }

  /// The session runs mode operations one at a time through its gate.
  func testDisableAndCancelSetupWaitForAnEnableInFlight() async throws {
    let probe = SessionWorkProbe()
    let session = SnipSnapCloudSyncSession(
      synchronize: { .noChange },
      enable: { try await probe.run("enable"); return .enabled },
      cancelEnable: { try await probe.run("cancel setup") },
      disable: { _ in try await probe.run("disable") },
      delete: { .completed },
      activeLibrary: { throw SyncModePersistenceError.missingStore }
    )
    let enable = Task { try await session.enableICloudSync() }
    await probe.waitUntilPaused()

    let disableWaits = expectation(description: "Disable waits for the enable in flight")
    disableWaits.isInverted = true
    let cancelWaits = expectation(description: "Cancel setup waits for the enable in flight")
    cancelWaits.isInverted = true
    let disable = Task {
      defer { disableWaits.fulfill() }
      try await session.disableICloudSync(.useCurrentCache)
    }
    let cancelSetup = Task {
      defer { cancelWaits.fulfill() }
      try await session.cancelICloudSyncSetup()
    }
    await fulfillment(of: [disableWaits, cancelWaits], timeout: 0.05)
    let whileEnabling = await probe.events()
    XCTAssertEqual(whileEnabling, ["enable"])

    await probe.resume()
    let enabled = try await enable.value
    try await disable.value
    try await cancelSetup.value
    XCTAssertEqual(enabled, .enabled)
    let events = await probe.events()
    XCTAssertEqual(events.first, "enable")
    XCTAssertEqual(Set(events.dropFirst()), ["disable", "cancel setup"])
  }

  /// The app gives the account handler the session's gate, so the handler's calls also wait for
  /// a mode operation in flight.
  @MainActor
  func testAccountHandlerWaitsForAnEnableInFlight() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SharedModeGate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = SessionWorkProbe()
    let local = try SwiftDataSnipLibrary(
      storeURL: root.appendingPathComponent("source.store", isDirectory: false)
    )
    let services = SnipSnapCloudAppAssembly.simulatedLocalOnlyServices(
      rootURL: root.appendingPathComponent("SyncMode", isDirectory: true),
      sourceLibrary: PausingSourceLibrary(base: local, probe: probe)
    )
    let session = try XCTUnwrap(services.syncSession)
    let handler = try XCTUnwrap(services.makeAccountCacheHandler(
      syncWhenPossible: {},
      retrySyncWhenPossible: {},
      scheduleSyncAfterLocalChange: {}
    ))
    let enable = Task {
      do {
        let outcome = try await session.enableICloudSync()
        await probe.heldWorkFinished()
        return outcome
      } catch {
        await probe.heldWorkFinished()
        throw error
      }
    }
    await probe.waitUntilPaused()
    guard await probe.events() == ["source read"] else {
      _ = try await enable.value
      XCTFail("The enable finished without reaching its local-library read")
      return
    }

    let checkWaits = expectation(description: "The account handler waits for the enable in flight")
    checkWaits.isInverted = true
    let check = Task {
      defer { checkWaits.fulfill() }
      return try await handler.isCloudSyncActive()
    }
    await fulfillment(of: [checkWaits], timeout: 0.05)

    await probe.resume()
    let enabled = try await enable.value
    let isActive = try await check.value
    XCTAssertEqual(enabled, .enabled)
    XCTAssertTrue(isActive)
  }

  /// Waits for callers to join the queue rather than for a fixed time.
  private func waitForQueuedRequests(
    _ count: Int,
    in session: SnipSnapCloudSyncSession,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    try await waitUntil("\(count) sync requests are queued", file: file, line: line) {
      await session.queuedRequestCount == count
    }
  }

  /// Fails instead of hanging when the condition doesn't hold within two seconds.
  private func waitUntil(
    _ description: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await !condition() {
      guard ContinuousClock.now < deadline else {
        XCTFail("Timed out waiting until \(description)", file: file, line: line)
        return
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private func makeSession(_ probe: SessionWorkProbe) -> SnipSnapCloudSyncSession {
    SnipSnapCloudSyncSession(
      synchronize: { try await probe.run("sync"); return .contentUpdated },
      retry: { try await probe.run("retry"); return .contentUpdated },
      scheduleAutomaticSync: { try await probe.run("schedule") },
      enable: { try await probe.run("enable"); return .enabled },
      delete: { try await probe.run("delete"); return .completed },
      activeLibrary: { throw SyncModePersistenceError.missingStore }
    )
  }
}

private struct SessionTestError: Error, Equatable {
  let name: String

  init(_ name: String) {
    self.name = name
  }
}

private actor ErrorReports {
  private var recorded: [SessionTestError] = []

  func record(_ error: SessionTestError) {
    recorded.append(error)
  }

  func values() -> [SessionTestError] { recorded }
}

/// Suspends callers of `wait()` until `open()`, then lets every later call through.
private actor Latch {
  private(set) var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters = []
  }
}

private actor SessionWorkProbe {
  private var active = false
  private var paused = false
  private var pauseNext = true
  private var heldWorkIsDone = false
  private var recorded: [String] = []
  private var release: CheckedContinuation<Void, Never>?
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var eventWaiters: [(String, CheckedContinuation<Void, Never>)] = []

  func run(_ name: String) async throws {
    guard !active else { throw CloudTransportError.syncAlreadyRunning }
    active = true
    defer { active = false }
    recorded.append(name)
    let ready = eventWaiters.filter { $0.0 == name }
    eventWaiters.removeAll { $0.0 == name }
    ready.forEach { $0.1.resume() }
    if pauseNext {
      pauseNext = false
      paused = true
      pauseWaiters.forEach { $0.resume() }
      pauseWaiters = []
      await withCheckedContinuation { release = $0 }
    }
  }

  func waitUntilPaused() async {
    if paused || heldWorkIsDone { return }
    await withCheckedContinuation { pauseWaiters.append($0) }
  }

  /// Ends `waitUntilPaused()` for work that finished without reaching `run`.
  func heldWorkFinished() {
    heldWorkIsDone = true
    pauseWaiters.forEach { $0.resume() }
    pauseWaiters = []
  }

  func resume() {
    paused = false
    release?.resume()
    release = nil
  }

  func waitForEvent(_ name: String) async {
    if recorded.contains(name) { return }
    await withCheckedContinuation { eventWaiters.append((name, $0)) }
  }

  func events() -> [String] { recorded }
}

/// Holds the enable at its read of the local library until `probe.resume()`.
private struct PausingSourceLibrary: SnipLibrary {
  let base: any SnipLibrary
  let probe: SessionWorkProbe

  func snapshot(sortedBy sortMode: SnipSortMode) async -> SnipLibrarySnapshot {
    await base.snapshot(sortedBy: sortMode)
  }

  func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot {
    try await base.checkedSnapshot(sortedBy: sortMode)
  }

  func perform(
    _ command: SnipLibraryCommand,
    sortedBy sortMode: SnipSortMode
  ) async throws -> SnipLibraryUpdate {
    try await base.perform(command, sortedBy: sortMode)
  }

  func transferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot {
    try await probe.run("source read")
    return try await base.transferSnapshot(revision: revision)
  }
}


extension CloudSyncSessionTests {
  @MainActor
  func testTypedOptionalDefaultDoesNotRunLegacyVoidWork() async {
    let work = CloudOutcomeOwnership()
    let counts = CloudOutcomeCounts()
    let handler: any OptionalCloudSyncHandling = CloudOutcomeLegacyHandler(counts: counts)
    let caller = work.start {
      do {
        let outcome = try await handler.retrySyncWithOutcome()
        guard case .notRun(.unsupportedLegacyHandler) = outcome else {
          return XCTFail("An unsupported optional handler has no original successful action")
        }
      } catch { XCTFail("Unsupported default must return notRun: \(error)") }
    }
    let completed = await caller.finished.wait(for: .seconds(2))
    XCTAssertTrue(completed)
    XCTAssertEqual(counts.values, [:], "Typed default cannot invoke either legacy retry or sync")
    await work.cleanUp()
  }

  @MainActor
  func testBothAccountHandlerConstructorsWithoutTypedCallbackDoZeroVoidOrCoordinatorWork() async throws {
    for injected in [true, false] {
      let work = CloudOutcomeOwnership()
      let fixture = try CloudOutcomeFixture()
      work.retain(fixture)
      let handler: any OptionalCloudSyncHandling = fixture.handler(injected: injected)
      let caller = work.start {
        do {
          let outcome = try await handler.retrySyncWithOutcome()
          guard case .notRun(.unsupportedLegacyHandler) = outcome else {
            return XCTFail("Missing typed callback cannot fall back to a Void action")
          }
        } catch { XCTFail("Missing typed callback must report unsupported: \(error)") }
      }
      let completed = await caller.finished.wait(for: .seconds(2))
      XCTAssertTrue(completed, "Missing typed capability must not start coordinator work")
      XCTAssertEqual(fixture.counts.values, [:])
      await work.cleanUp()
    }
  }

  @MainActor
  func testBothConstructorsForwardRealCoreRefusalAndResolvedHandlerBypassesItsHeldAppGate() async throws {
    for injected in [true, false] {
      let work = CloudOutcomeOwnership()
      let fixture = try CloudOutcomeFixture()
      work.retain(fixture)
      let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
      work.retain(settings)
      let winnerGate = work.gate()
      let appGate = work.gate()
      var appOwner: CloudOutcomeTask?
      if !injected {
        appOwner = work.start {
          do { try await fixture.operationGate.withLease { await appGate.suspend() } }
          catch { XCTFail("App gate setup failed: \(error)") }
        }
        guard await work.ready(appGate.entered, "resolved handler's actual shared app gate held") else {
          await work.cleanUp(); continue
        }
      }
      let winner = work.start { await settings.performExplicitSync { await winnerGate.suspend() } }
      guard await work.ready(winnerGate.entered, "real Settings admission winner") else {
        await work.cleanUp(); continue
      }
      let callback: AppleAccountCacheCoordinatorHandler.RetryOutcomeAction = {
        fixture.counts.record("typed callback")
        return try await settings.performExplicitSyncWithOutcome { _ in
          fixture.counts.record("loser body")
          return .finished(.noChange, .notRequired)
        }
      }
      let handler: any OptionalCloudSyncHandling = fixture.handler(injected: injected, retryOutcome: callback)
      let caller = work.start {
        do {
          let outcome = try await handler.retrySyncWithOutcome()
          guard case .notRun(.overlappingExplicitAction) = outcome else {
            return XCTFail("Actual Core refusal must survive the account handler unchanged")
          }
        } catch { XCTFail("Unexpected forwarding error: \(error)") }
      }
      let completed = await caller.finished.wait(for: .seconds(2))
      XCTAssertTrue(completed, "Typed refusal cannot wait behind the mode/app gate")
      XCTAssertEqual(fixture.counts.values, ["typed callback": 1])
      if let appOwner {
        XCTAssertTrue(appGate.isHeld)
        XCTAssertFalse(appOwner.finished.isSet)
      }
      XCTAssertTrue(winnerGate.isHeld)
      XCTAssertFalse(winner.finished.isSet)
      XCTAssertEqual(settings.state, .removalPending)
      XCTAssertNil(settings.finishDeletingIssue)
      await work.cleanUp()
      XCTAssertEqual(fixture.counts.values, ["typed callback": 1])
    }
  }

  @MainActor
  func testBothAccountHandlerConstructorsPreserveOriginalCallbackErrorAndCancellation() async throws {
    for injected in [true, false] {
      for cancel in [false, true] {
        let work = CloudOutcomeOwnership()
        let fixture = try CloudOutcomeFixture()
        work.retain(fixture)
        let failure = CloudOutcomeFailure()
        let callback: AppleAccountCacheCoordinatorHandler.RetryOutcomeAction = {
          fixture.counts.record("typed callback")
          if cancel { throw CancellationError() }
          throw failure
        }
        let handler: any OptionalCloudSyncHandling = fixture.handler(injected: injected, retryOutcome: callback)
        let caller = work.start {
          do {
            _ = try await handler.retrySyncWithOutcome()
            XCTFail("An original thrown error or cancellation is not a completed action")
          } catch is CancellationError {
            XCTAssertTrue(cancel)
          } catch {
            XCTAssertFalse(cancel)
            XCTAssertTrue((error as AnyObject) === failure, "The original Error identity must survive forwarding")
          }
        }
        let completed = await caller.finished.wait(for: .seconds(2))
        XCTAssertTrue(completed)
        XCTAssertEqual(fixture.counts.values, ["typed callback": 1])
        await work.cleanUp()
      }
    }
  }

  @MainActor
  func testSharedFactoryAndSimulatedRootForwardTypedRetryAndKeepNilUnsupported() async throws {
    for simulated in [false, true] {
      let work = CloudOutcomeOwnership()
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("OriginalOutcomeFactory-\(UUID())")
      NSLog("OriginalOutcomeFactory allocated retained store root: %@", root.path)
      let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("source.store"))
      let services: SnipSnapCloudAppServices
      var appOperationGate: AsyncOperationGate?
      if simulated {
        services = SnipSnapCloudAppAssembly.simulatedLocalOnlyServices(
          rootURL: root.appendingPathComponent("SyncMode"), sourceLibrary: library)
      } else {
        let server = FakeCloudServer()
        let descriptor = CloudCollectionDescriptor.fresh(ownerName: "outcome-factory-owner")
        let lifecycle = SnipSnapICloudSyncLifecycle(
          rootURL: root.appendingPathComponent("SyncMode"), sourceLibrary: library, syncModeStore: nil,
          cloudScope: "private", accountLineage: "outcome-factory-account",
          accountStateSource: FixedICloudAccountStateSource(state: .available(accountLineage: "outcome-factory-account")),
          ownerName: "outcome-factory-owner", controlTransport: FakeCloudControlTransport(server: server),
          makeRecordTransport: { context in
            FakeCloudRecordTransport(server: server, namespace: context.namespace)
          }, makeDescriptor: { descriptor })
        let sharedGate = AsyncOperationGate()
        appOperationGate = sharedGate
        work.retain(server)
        work.retain(lifecycle)
        work.retain(sharedGate)
        services = SnipSnapCloudAppServices(
          syncedContentSettings: SyncedContentSettingsModel(mode: .localOnly), syncSession: nil,
          accountHandlerFactory: SnipSnapCloudAppAssembly.accountHandlerFactory(
            lifecycle: lifecycle, operationGate: sharedGate))
      }
      work.retain(library)
      work.retain(services.syncedContentSettings)
      if let session = services.syncSession { work.retain(session) }
      let counts = CloudOutcomeCounts()
      let settings = SyncedContentSettingsModel(mode: .iCloudSync, initialState: .removalPending)
      work.retain(settings)
      let gate = work.gate()
      let winner = work.start { await settings.performExplicitSync { await gate.suspend() } }
      guard await work.ready(gate.entered, "factory forwarding admission winner") else {
        await work.cleanUp(); continue
      }
      guard let handler = services.makeAccountCacheHandler(
        syncWhenPossible: { counts.record("legacy sync") },
        retrySyncWhenPossible: { counts.record("legacy retry") },
        retrySyncWithOutcome: {
          counts.record("typed callback")
          return try await settings.performExplicitSyncWithOutcome { _ in
            counts.record("loser body")
            return .finished(.noChange, .notRequired)
          }
        },
        scheduleSyncAfterLocalChange: { counts.record("schedule") }
      ) else {
        XCTFail("The actual factory must expose its account handler")
        await work.cleanUp(); continue
      }
      work.retain(handler)
      var heldAppGate: CloudOutcomeGate?
      var appOwner: CloudOutcomeTask?
      var statusRead: CloudOutcomeTask?
      if let appOperationGate {
        let appGate = work.gate()
        heldAppGate = appGate
        appOwner = work.start {
          do { try await appOperationGate.withLease { await appGate.suspend() } }
          catch { XCTFail("Shared factory gate setup failed: \(error)") }
        }
        guard await work.ready(appGate.entered, "actual shared factory app gate held") else {
          await work.cleanUp(); continue
        }
        let statusRequested = CloudOutcomeSignal()
        let read = work.start {
          statusRequested.fire()
          do {
            let active = try await handler.isCloudSyncActive()
            XCTAssertFalse(active, "The fake lifecycle still has no managed persistence")
          } catch { XCTFail("Actual shared factory status read failed: \(error)") }
        }
        statusRead = read
        guard await work.ready(statusRequested, "actual handler status request dispatched") else {
          await work.cleanUp(); continue
        }
        let premature = await read.finished.wait(for: .seconds(2))
        XCTAssertFalse(premature, "Actual status must wait on the passed app gate")
        XCTAssertTrue(appGate.isHeld)
        XCTAssertFalse(appOwner?.finished.isSet ?? true)
      }
      let caller = work.start {
        do {
          let outcome = try await handler.retrySyncWithOutcome()
          guard case .notRun(.overlappingExplicitAction) = outcome else {
            return XCTFail("Both actual assembly factories must preserve real Core refusal")
          }
        } catch { XCTFail("Unexpected factory forwarding error: \(error)") }
      }
      let completed = await caller.finished.wait(for: .seconds(2))
      XCTAssertTrue(completed)
      XCTAssertEqual(counts.values, ["typed callback": 1])
      XCTAssertTrue(gate.isHeld)
      XCTAssertFalse(winner.finished.isSet)
      guard let legacyOnly = services.makeAccountCacheHandler(
        syncWhenPossible: { counts.record("legacy sync") },
        retrySyncWhenPossible: { counts.record("legacy retry") },
        scheduleSyncAfterLocalChange: { counts.record("schedule") }
      ) else {
        XCTFail("The factory must retain its legacy-compatible constructor")
        await work.cleanUp(); continue
      }
      work.retain(legacyOnly)
      let unsupported = work.start {
        do {
          let outcome = try await legacyOnly.retrySyncWithOutcome()
          guard case .notRun(.unsupportedLegacyHandler) = outcome else {
            return XCTFail("Factory default nil cannot silently run legacy work")
          }
        } catch { XCTFail("Unexpected nil-callback error: \(error)") }
      }
      let unsupportedCompleted = await unsupported.finished.wait(for: .seconds(2))
      XCTAssertTrue(unsupportedCompleted)
      XCTAssertEqual(counts.values, ["typed callback": 1])
      XCTAssertTrue(gate.isHeld)
      XCTAssertFalse(winner.finished.isSet)
      if let heldAppGate, let appOwner, let statusRead {
        XCTAssertTrue(heldAppGate.isHeld)
        XCTAssertFalse(appOwner.finished.isSet)
        XCTAssertFalse(statusRead.finished.isSet, "Typed refusal and nil capability must leave status gated")
        heldAppGate.release()
        let deadline = ContinuousClock.now + .seconds(30)
        let statusFinished = await statusRead.finished.wait(for: deadline - ContinuousClock.now)
        XCTAssertTrue(statusFinished, "Actual status must finish after app gate release")
        let ownerFinished = await appOwner.finished.wait(for: deadline - ContinuousClock.now)
        XCTAssertTrue(ownerFinished, "The app gate holder must finish after its own release")
        XCTAssertTrue(gate.isHeld)
        XCTAssertFalse(winner.finished.isSet, "Status completion must not release Core admission")
      }
      await work.cleanUp()
      XCTAssertEqual(counts.values, ["typed callback": 1])
    }
  }
}

private final class CloudOutcomeCounts: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String: Int] = [:]
  var values: [String: Int] { lock.withLock { recorded } }
  func record(_ name: String) { lock.withLock { recorded[name, default: 0] += 1 } }
}

private final class CloudOutcomeFailure: Error, @unchecked Sendable {}

private struct CloudOutcomeLegacyHandler: OptionalCloudSyncHandling {
  let counts: CloudOutcomeCounts
  func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
  func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
  func syncWhenPossible() async { counts.record("legacy sync") }
  func retrySyncWhenPossible() async { counts.record("legacy retry") }
  func isCloudSyncActive() async throws -> Bool { false }
  func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] { [:] }
  func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
    throw SnipLibraryError.transferUnsupported
  }
  func clearDownloadedFiles() async throws {}
}

@MainActor
private final class CloudOutcomeFixture {
  let counts = CloudOutcomeCounts()
  let operationGate = AsyncOperationGate()
  private let persistence: SwiftDataSyncModePersistence
  private let coordinator: ICloudSyncModeCoordinator
  private let server = FakeCloudServer()

  init() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OriginalOutcomeHandler-\(UUID())")
    NSLog("OriginalOutcomeHandler allocated retained store root: %@", root.path)
    persistence = try SwiftDataSyncModePersistence(rootURL: root)
    let descriptor = CloudCollectionDescriptor.fresh(ownerName: "outcome-owner")
    let namespace = descriptor.namespace(cloudScope: "private", accountLineage: "outcome-account")
    coordinator = ICloudSyncModeCoordinator(persistence: persistence, namespace: namespace,
      textZone: descriptor.metadataZone, payloadZone: descriptor.payloadZone,
      makeTransport: { [server] in FakeCloudRecordTransport(server: server, namespace: namespace) })
  }

  func handler(injected: Bool,
               retryOutcome: AppleAccountCacheCoordinatorHandler.RetryOutcomeAction? = nil
  ) -> AppleAccountCacheCoordinatorHandler {
    let sync: AppleAccountCacheCoordinatorHandler.SyncAction = { [counts] in counts.record("legacy sync") }
    let retry: AppleAccountCacheCoordinatorHandler.SyncAction = { [counts] in counts.record("legacy retry") }
    if injected {
      return AppleAccountCacheCoordinatorHandler(coordinator: coordinator,
        syncWhenPossible: sync, retrySyncWhenPossible: retry, retrySyncWithOutcome: retryOutcome)
    }
    return AppleAccountCacheCoordinatorHandler(
      persistence: { [counts, persistence] in counts.record("persistence lookup"); return persistence },
      controlTransport: FakeCloudControlTransport(server: server),
      accountStateSource: FixedICloudAccountStateSource(state: .available(accountLineage: "outcome-account")),
      makeSyncCoordinator: { [counts, coordinator] _, _, _ in
        counts.record("coordinator lookup")
        return coordinator
      },
      makeAttachmentCoordinator: { [counts, server] library, namespace, descriptor in
        counts.record("attachment lookup")
        return CloudAttachmentTransferCoordinator(library: library, namespace: namespace,
          payloadZone: descriptor.payloadZone,
          transport: FakeCloudRecordTransport(server: server, namespace: namespace), maximumCacheBytes: 0)
      },
      operationGate: operationGate, syncWhenPossible: sync, retrySyncWhenPossible: retry,
      retrySyncWithOutcome: retryOutcome)
  }
}

// A timeout ends observation only; it never releases either retry's behavior gate.
private final class CloudOutcomeSignal: @unchecked Sendable {
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

    private func observe() async -> Bool {
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

private final class CloudOutcomeGate: @unchecked Sendable {
    let entered = CloudOutcomeSignal()
    private let lock = NSLock()
    private var released = false
    private var pending: CheckedContinuation<Void, Never>?
    var isHeld: Bool { entered.isSet && lock.withLock { !released } }

    func suspend() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if released { return true }
                pending = continuation
                return false
            }
            entered.fire()
            if resume { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            let continuation = pending
            pending = nil
            return continuation
        }
        continuation?.resume()
    }
}

@MainActor
private final class CloudOutcomeTask {
    let finished: CloudOutcomeSignal
    let task: Task<Void, Never>

    init(_ operation: @escaping @MainActor () async -> Void) {
        let completion = CloudOutcomeSignal()
        finished = completion
        task = Task {
            await operation()
            completion.fire()
        }
    }
}

@MainActor
private final class CloudOutcomeOwnership {
    private var gates: [CloudOutcomeGate] = []
    private var tasks: [CloudOutcomeTask] = []
    private var resources: [AnyObject] = []
    private var retainedAfterFailedJoin: CloudOutcomeOwnership?

    func retain(_ resource: AnyObject) { resources.append(resource) }

    func gate() -> CloudOutcomeGate {
        let gate = CloudOutcomeGate()
        gates.append(gate)
        return gate
    }

    func start(_ operation: @escaping @MainActor () async -> Void) -> CloudOutcomeTask {
        let task = CloudOutcomeTask(operation)
        tasks.append(task)
        return task
    }

    func ready(_ signal: CloudOutcomeSignal, _ stage: String) async -> Bool {
        let ready = await signal.wait(for: .seconds(30))
        XCTAssertTrue(ready, "Cloud-outcome setup/readiness failed: \(stage)")
        return ready
    }

    func cleanUp() async {
        let cleanup = Task { @MainActor [self] in
            gates.forEach { $0.release() }
            tasks.forEach { $0.task.cancel() }
            let deadline = ContinuousClock.now + .seconds(30)
            var settled = true
            for operation in tasks {
                let joined = await operation.finished.wait(for: deadline - ContinuousClock.now)
                XCTAssertTrue(joined, "Cloud-outcome cleanup could not join an owned caller")
                if joined { await operation.task.value } else { settled = false }
            }
            guard settled else {
                retainedAfterFailedJoin = self
                return
            }
            tasks.removeAll()
            gates.removeAll()
            resources.removeAll()
        }
        await cleanup.value
    }
}


extension CloudSyncSessionTests {
  @MainActor
  func testBothConstructorsForwardACoreProjectedIssueWithoutPublishingHistoricalState() async throws {
    for injected in [true, false] {
      let work = CloudOutcomeOwnership()
      let fixture = try CloudOutcomeFixture()
      work.retain(fixture)
      let settings = SyncedContentSettingsModel(mode: .iCloudSync)
      work.retain(settings)
      let gate = work.gate()
      var appOwner: CloudOutcomeTask?
      if !injected {
        appOwner = work.start {
          do { try await fixture.operationGate.withLease { await gate.suspend() } }
          catch { XCTFail("App gate setup failed: \(error)") }
        }
        guard await work.ready(gate.entered, "resolved handler gate before original report forwarding") else {
          await work.cleanUp(); continue
        }
      }
      let callback: AppleAccountCacheCoordinatorHandler.RetryOutcomeAction = {
        fixture.counts.record("typed callback")
        return try await settings.performExplicitSyncWithOutcome { _ in
          fixture.counts.record("original body")
          return .finished(.syncIssue(.attachmentUnavailable), .notRequired)
        }
      }
      let handler: any OptionalCloudSyncHandling = fixture.handler(injected: injected, retryOutcome: callback)
      let caller = work.start {
        do {
          let outcome = try await handler.retrySyncWithOutcome()
          guard case .completed(let report) = outcome else {
            return XCTFail("The real Core projection must survive both handler constructors")
          }
          guard case .failed = report.operation.status else { return XCTFail("Keep the original result-valued issue") }
          XCTAssertEqual(report.operation.message, "iCloud can’t provide this attachment yet. Sync will try again.")
        } catch { XCTFail("Unexpected original report forwarding error: \(error)") }
      }
      let completed = await caller.finished.wait(for: .seconds(2))
      XCTAssertTrue(completed)
      XCTAssertEqual(fixture.counts.values, ["typed callback": 1, "original body": 1])
      XCTAssertEqual(settings.state, .syncing, "A controlled raw original is not a live application result")
      if let appOwner {
        XCTAssertTrue(gate.isHeld)
        XCTAssertFalse(appOwner.finished.isSet)
      }
      await work.cleanUp()
      XCTAssertEqual(fixture.counts.values, ["typed callback": 1, "original body": 1])
    }
  }
}
