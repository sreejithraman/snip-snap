import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnapCLI

final class SnipCLIScopeTransitionTests: XCTestCase {
  func testAwaitedTransitionSurvivesScopeSuspensionAndReturnsCurrentResult() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("local")
    let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: "local")
    let execution = Task { try await SnipCLIService.execute(request, store: store) }
    try await waitUntilPending(request, store: store)
    await store.processPending { received in
      try await store.suspendActiveScope()
      try await Task.sleep(for: .milliseconds(150))
      try await store.publishActiveScopeToken("cloud")
      try await Task.sleep(for: .milliseconds(150))
      return SnipCLIReceipt(request: received, status: .success,
        extendedResult: .application(.init(values: ["mode": "icloud"])),
        resultingScopeToken: "cloud")
    }
    let receipt = try await execution.value
    XCTAssertEqual(receipt.status, .success)
    XCTAssertEqual(receipt.extendedResult, .application(.init(values: ["mode": "icloud"])))
  }

  func testEveryApprovedTransitionReturnsStatusAndCannotReplayInNewScope() async throws {
    let actions: [SnipCLIApplicationAction] = [
      .setSync(enabled: true, useCurrentCache: false, expectedRevision: "before"),
      .setSync(enabled: false, useCurrentCache: true, expectedRevision: "before"),
      .cancelSyncSetup(expectedRevision: "before"), .retrySync,
      .resolveAccount(choice: .keep, expectedRevision: "before", confirmed: false),
      .resolveAccount(choice: .remove, expectedRevision: "before", confirmed: true),
    ]
    for action in actions {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = SnipCLIRequestStore(rootURL: root)
      try await store.publishActiveScopeToken("before")
      let request = SnipCLIRequest(action: .extended(.application(action)), scopeToken: "before",
        expiresAt: Date().addingTimeInterval(0.15))
      let execution = Task { try await SnipCLIService.execute(request, store: store) }
      try await waitUntilPending(request, store: store)
      await store.processPending { received in
        try await store.publishActiveScopeToken("after")
        // Claimed transitions must finish even after the original request expires.
        try await Task.sleep(for: .milliseconds(200))
        return SnipCLIReceipt(request: received, status: .success,
          extendedResult: .application(.init(values: ["state": "finished"])),
          resultingScopeToken: "after")
      }
      let delivered = try await execution.value
      XCTAssertTrue(delivered.matches(request))
      XCTAssertEqual(delivered.scopeToken, "before")
      XCTAssertEqual(delivered.visibleScopeToken, "after")
      guard case .completed(let status) = try await SnipCLIService.status(request.requestID, store: store) else {
        return XCTFail("Expected the result in the destination scope for \(action)")
      }
      XCTAssertEqual(status.status, .success)
      XCTAssertEqual(status.extendedResult, delivered.extendedResult)
      try await store.releaseReceipt(request.requestID)
      guard case .completed(let compact) = try await SnipCLIService.status(request.requestID, store: store) else {
        return XCTFail("Expected a retained transition result")
      }
      XCTAssertTrue(compact.matches(request))
      XCTAssertEqual(compact.visibleScopeToken, "after")
      XCTAssertNil(compact.extendedResult)
      do {
        _ = try await SnipCLIService.execute(request.scoped(to: "after"), store: store)
        XCTFail("Reusing the UUID in the new scope must not queue a mutation")
      } catch SnipCLIRequestError.conflictingRequestID {}
      await store.processPending { received in
        XCTFail("A completed transition must never run twice")
        return SnipCLIReceipt(request: received, status: .success)
      }
      try await store.publishActiveScopeToken("unrelated-account")
      let hidden = try await SnipCLIService.status(request.requestID, store: store)
      XCTAssertEqual(hidden, .missing)
      do {
        _ = try await SnipCLIService.completed(delivered, expectedScope: "before", store: store)
        XCTFail("A result read before an account change must not be displayed afterward")
      } catch SnipCLIRequestError.scopeChanged {}
    }
  }

  func testExpiredUnreadTransitionRetainsDestinationAndRetryIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("before")
    let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: "before")
    _ = try await store.enqueue(request)
    await store.processPending { received in
      try await store.publishActiveScopeToken("after")
      return SnipCLIReceipt(request: received, status: .success,
        extendedResult: .application(.init(values: ["detail": "Private state"])),
        resultingScopeToken: "after")
    }
    let url = root.appendingPathComponent("Agent/Commands/Receipts/\(request.requestID.uuidString).json")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)],
      ofItemAtPath: url.path)
    try await store.pruneAbandoned()
    guard case .completed(let retained) = try await SnipCLIService.status(request.requestID, store: store) else {
      return XCTFail("A transition write must remain identifiable after retention")
    }
    XCTAssertEqual(retained.visibleScopeToken, "after")
    XCTAssertTrue(retained.matches(request))
    XCTAssertNil(retained.extendedResult)
    XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("Private state"))
    do {
      _ = try await store.enqueue(request.scoped(to: "after"))
      XCTFail("An expired receipt must still prevent duplicate writes")
    } catch SnipCLIRequestError.conflictingRequestID {}
  }

  func testOrdinaryCommandsCannotSupplyResultScopeIncludingDecodedReceipts() async throws {
    let actions: [SnipCLIAction] = [.listSnips(list: nil), .createList(name: "private"),
      .extended(.application(.syncStatus)), .extended(.application(.retryClipboardSync)),
      .extended(.application(.search(query: "private")))]
    for action in actions {
      let request = SnipCLIRequest(action: action, scopeToken: "before")
      let receipt = SnipCLIReceipt(request: request, status: .success, resultingScopeToken: "after")
      XCTAssertNil(receipt.resultingScopeToken)
      XCTAssertEqual(receipt.visibleScopeToken, "before")
      var object = try XCTUnwrap(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(receipt)) as? [String: Any])
      object["resultingScopeToken"] = "after"
      let decoded = try JSONDecoder().decode(SnipCLIReceipt.self,
        from: JSONSerialization.data(withJSONObject: object))
      XCTAssertNil(decoded.resultingScopeToken)
      XCTAssertEqual(decoded.visibleScopeToken, "before")
      XCTAssertEqual(decoded.compacted().visibleScopeToken, "before")
    }
  }

  func testLegacyReceiptsKeepOriginalScopeAndFingerprint() throws {
    let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: "before")
    let legacy = SnipCLIReceipt(request: request, status: .success)
    let decoded = try JSONDecoder().decode(SnipCLIReceipt.self, from: JSONEncoder().encode(legacy))
    XCTAssertNil(decoded.resultingScopeToken)
    XCTAssertEqual(decoded.visibleScopeToken, "before")
    XCTAssertTrue(decoded.matches(request))
  }

  func testOrdinaryCommandStillFailsWhenHandlerSwitchesScope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("before")
    let request = SnipCLIRequest(action: .listSnips(list: nil), scopeToken: "before")
    let execution = Task { try await SnipCLIService.execute(request, store: store) }
    try await waitUntilPending(request, store: store)
    await store.processPending { received in
      try await store.publishActiveScopeToken("after")
      return SnipCLIReceipt(request: received, status: .success,
        snips: [Snip(content: "Private before", origin: .agent)], resultingScopeToken: "after")
    }
    do {
      _ = try await execution.value
      XCTFail("Ordinary reads must fail across a scope change")
    } catch SnipCLIRequestError.scopeChanged {}
    let hidden = try await SnipCLIService.status(request.requestID, store: store)
    XCTAssertEqual(hidden, .missing)
  }

  func testMismatchedCompletionCannotBeConsumed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("scope")
    let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: "scope")
    let execution = Task { try await SnipCLIService.execute(request, store: store) }
    try await waitUntilPending(request, store: store)
    let conflicting = SnipCLIRequest(action: .listLists, requestID: request.requestID, scopeToken: "scope")
    let url = root.appendingPathComponent("Agent/Commands/Receipts/\(request.requestID.uuidString).json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(SnipCLIReceipt(request: conflicting, status: .success)).write(to: url)
    do {
      _ = try await execution.value
      XCTFail("A completed receipt must match the original request fingerprint")
    } catch SnipCLIRequestError.conflictingRequestID {}
  }

  func testTransitionUncertaintySurvivesScopeSuspensionAndBlocksReplay() async throws {
    for destination: String? in [nil, "after"] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = SnipCLIRequestStore(rootURL: root)
      try await store.publishActiveScopeToken("before")
      let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: "before")
      let execution = Task { try await SnipCLIService.execute(request, store: store) }
      try await waitUntilPending(request, store: store)
      await store.processPending { _ in
        try await store.suspendActiveScope()
        if let destination { try await store.publishActiveScopeToken(destination) }
        throw SnipCLIOutcomeUncertain()
      }
      do {
        _ = try await execution.value
        XCTFail("A claimed transition without a receipt must report uncertainty")
      } catch SnipSnapCLIError.outcomeUnknown(let id) { XCTAssertEqual(id, request.requestID) }
      let marker = root.appendingPathComponent("Agent/Commands/Processing/\(request.requestID.uuidString).json")
      try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)],
        ofItemAtPath: marker.path)
      try await store.pruneAbandoned()
      let state = try await store.state(for: request.requestID, waitingFor: request)
      XCTAssertEqual(state, .uncertain)
      try await store.publishActiveScopeToken("after")
      do {
        _ = try await store.enqueue(request.scoped(to: "after"))
        XCTFail("A transition with uncertain outcome cannot be requeued in a new scope")
      } catch SnipCLIRequestError.scopeChanged {}
      try await store.publishActiveScopeToken("before")
      let oldRetry = try await store.enqueue(request)
      XCTAssertEqual(oldRetry, .uncertain)
    }
  }

  func testTransitionReceiptWriteFailureReportsUncertaintyAcrossScopeChange() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let receipts = root.appendingPathComponent("Agent/Commands/Receipts")
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: receipts.path)
      try? FileManager.default.removeItem(at: root)
    }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("before")
    let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: "before")
    let execution = Task { try await SnipCLIService.execute(request, store: store) }
    try await waitUntilPending(request, store: store)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: receipts.path)
    await store.processPending { received in
      try await store.publishActiveScopeToken("after")
      return SnipCLIReceipt(request: received, status: .success, resultingScopeToken: "after")
    }
    do {
      _ = try await execution.value
      XCTFail("Receipt persistence failure must not look successful or unclaimed")
    } catch SnipSnapCLIError.outcomeUnknown(let id) { XCTAssertEqual(id, request.requestID) }
  }

  func testTransitionTimeoutWhileSuspendedReportsProcessingThenStatusSucceeds() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("before")
    let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: "before")
    let execution = Task { try await SnipCLIService.execute(request, store: store, timeout: .milliseconds(100)) }
    try await waitUntilPending(request, store: store)
    await store.processPending { received in
      try await store.suspendActiveScope()
      try await Task.sleep(for: .milliseconds(250))
      try await store.publishActiveScopeToken("after")
      return SnipCLIReceipt(request: received, status: .success, resultingScopeToken: "after")
    }
    do {
      _ = try await execution.value
      XCTFail("A claimed transition must remain processing when the CLI times out")
    } catch SnipSnapCLIError.commandInProgress(let id) { XCTAssertEqual(id, request.requestID) }
    guard case .completed(let receipt) = try await SnipCLIService.status(request.requestID, store: store) else {
      return XCTFail("Status must recover the eventual transition result")
    }
    XCTAssertEqual(receipt.status, .success)
    XCTAssertEqual(receipt.visibleScopeToken, "after")
  }

  func testUnclaimedTransitionTimeoutCancelsOriginalPendingRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("before")
    let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: "before")
    let execution = Task { try await SnipCLIService.execute(request, store: store, timeout: .milliseconds(100)) }
    try await waitUntilPending(request, store: store)
    try await store.publishActiveScopeToken("unrelated")
    do {
      _ = try await execution.value
      XCTFail("An unclaimed request must time out")
    } catch SnipSnapCLIError.appUnavailable {}
    try await store.publishActiveScopeToken("before")
    await store.processPending { received in
      XCTFail("A timed out, unclaimed transition must not run after returning to its old scope")
      return SnipCLIReceipt(request: received, status: .success)
    }
    let state = try await store.state(for: request.requestID)
    XCTAssertEqual(state, .missing)
  }

  func testFailedTransitionReportsActualFailureInDestinationScope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("before")
    let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: "before")
    let execution = Task { try await SnipCLIService.execute(request, store: store) }
    try await waitUntilPending(request, store: store)
    await store.processPending { received in
      try await store.publishActiveScopeToken("after")
      return SnipCLIReceipt(request: received, status: .failed, message: "Retry failed",
        resultingScopeToken: "after")
    }
    do {
      _ = try await execution.value
      XCTFail("A failed transition must report its app failure")
    } catch SnipSnapCLIError.importFailed(let message) { XCTAssertEqual(message, "Retry failed") }
    guard case .completed(let receipt) = try await SnipCLIService.status(request.requestID, store: store) else {
      return XCTFail("Status must retain the transition failure")
    }
    XCTAssertEqual(receipt.status, .failed)
    XCTAssertEqual(receipt.visibleScopeToken, "after")
    XCTAssertTrue(receipt.matches(request))
  }

  func testStandaloneCLIPrintsTransitionAndStatusWithoutLaunchingAppOrReplaying() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("before")
    let id = UUID()
    let request = SnipCLIRequest(action: .extended(.application(.retrySync)), requestID: id, scopeToken: "before")
    let command = try launchCLI(["sync", "retry", "--request-id", id.uuidString, "--json"], root: root)
    defer { if command.process.isRunning { command.process.terminate() } }
    try await waitUntilPending(request, store: store)
    await store.processPending { received in
      try await store.suspendActiveScope()
      try await Task.sleep(for: .milliseconds(100))
      try await store.publishActiveScopeToken("after")
      try await Task.sleep(for: .milliseconds(100))
      return SnipCLIReceipt(request: received, status: .success,
        extendedResult: .application(.init(values: ["mode": "icloud"])), resultingScopeToken: "after")
    }
    command.process.waitUntilExit()
    XCTAssertEqual(command.process.terminationStatus, 0,
      String(decoding: command.errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    let output = try XCTUnwrap(JSONSerialization.jsonObject(
      with: command.output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    XCTAssertEqual(output["status"] as? String, "success")
    XCTAssertEqual(output["requestID"] as? String, id.uuidString)

    let status = try launchCLI(["status", id.uuidString, "--json"], root: root)
    status.process.waitUntilExit()
    XCTAssertEqual(status.process.terminationStatus, 0,
      String(decoding: status.errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    let statusOutput = try XCTUnwrap(JSONSerialization.jsonObject(
      with: status.output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    XCTAssertEqual(statusOutput["status"] as? String, "success")
    XCTAssertEqual(statusOutput["requestID"] as? String, id.uuidString)

    let replay = try launchCLI(["sync", "retry", "--request-id", id.uuidString, "--json"], root: root)
    replay.process.waitUntilExit()
    XCTAssertNotEqual(replay.process.terminationStatus, 0)
    await store.processPending { received in
      XCTFail("Replaying the CLI command must never run the transition again")
      return SnipCLIReceipt(request: received, status: .success)
    }
  }

  private func launchCLI(_ arguments: [String], root: URL) throws -> (process: Process, output: Pipe, errors: Pipe) {
    let executable = Bundle(for: SnipCLIScopeTransitionTests.self).bundleURL
      .deletingLastPathComponent().appendingPathComponent("snipsnap")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "SNIP_SNAP_APP_PATH")
    environment["SNIP_SNAP_CLI_NO_LAUNCH"] = "1"
    environment["SNIP_SNAP_STORE_PATH"] = root.appendingPathComponent("items.json").path
    process.environment = environment
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    try process.run()
    return (process, output, errors)
  }

  private func waitUntilPending(_ request: SnipCLIRequest, store: SnipCLIRequestStore) async throws {
    for _ in 0..<200 {
      if case .pending = try await store.state(for: request.requestID) { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Service did not enqueue its request")
    throw SnipSnapCLIError.appUnavailable
  }
}
