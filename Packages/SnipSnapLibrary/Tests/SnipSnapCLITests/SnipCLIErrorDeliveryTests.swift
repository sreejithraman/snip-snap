import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnapCLI

final class SnipCLIErrorDeliveryTests: XCTestCase {
  func testExecutableStatusRetainsMissingRequestID() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let command = try launchCLI(["status", id.uuidString, "--json"], root: root)
    let error = try await failureOutput(command)
    XCTAssertEqual(error["code"] as? String, "request_not_found")
    XCTAssertEqual(error["requestID"] as? String, id.uuidString)
  }

  func testExecutableStatusRetainsFailedRequestIDAndCompactsDeliveredFailure() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("test")
    let privatePath = root.appendingPathComponent("Secret export.zip").path
    let request = SnipCLIRequest(action: .extended(.data(.exportBackup(path: privatePath))), scopeToken: "test")
    _ = try await store.enqueue(request)
    await store.processPending { received in
      SnipCLIReceipt(request: received, status: .failed, message: "Cannot write \(privatePath).")
    }
    let command = try launchCLI(["status", request.requestID.uuidString, "--json"], root: root)
    let error = try await failureOutput(command)
    XCTAssertEqual(error["code"] as? String, "command_failed")
    XCTAssertEqual(error["requestID"] as? String, request.requestID.uuidString)
    XCTAssertTrue((error["message"] as? String)?.contains(privatePath) == true)
    let stored = try String(contentsOf: receiptURL(request, root: root), encoding: .utf8)
    XCTAssertFalse(stored.contains("Secret"))
    guard case .completed(let retained) = try await store.enqueue(request) else {
      return XCTFail("Delivered failure must retain retry protection")
    }
    XCTAssertEqual(retained.status, .failed)
    XCTAssertTrue(retained.matches(request))
  }

  func testExecutableDeliversExportFailureThenRetainsSanitizedFailureWithoutReplaying() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("test")
    let privatePath = root.appendingPathComponent("Private folder/Secret export.zip").path
    let request = SnipCLIRequest(action: .extended(.data(.exportBackup(path: privatePath))), scopeToken: "test")
    let arguments = ["backup", "export", privatePath, "--json", "--request-id", request.requestID.uuidString]
    let command = try launchCLI(arguments, root: root)
    defer { if command.process.isRunning { command.process.terminate() } }
    try await waitUntilPending(request, store: store)
    await store.processPending { received in
      SnipCLIReceipt(request: received, status: .failed,
        message: "Cannot export Secret note to \(privatePath): access denied.")
    }
    let delivered = try await failureOutput(command)
    XCTAssertEqual(delivered["code"] as? String, "command_failed")
    XCTAssertEqual(delivered["requestID"] as? String, request.requestID.uuidString)
    XCTAssertTrue((delivered["message"] as? String)?.contains(privatePath) == true)
    XCTAssertTrue((delivered["message"] as? String)?.contains("access denied") == true)

    guard case .completed(let retained) = try await store.enqueue(request) else {
      return XCTFail("A failed write must retain its request identity")
    }
    XCTAssertEqual(retained.status, .failed)
    XCTAssertTrue(retained.matches(request))
    XCTAssertEqual(retained.action, .extended(.data(.exportBackup(path: ""))))
    XCTAssertEqual(retained.message, "Snip Snap could not complete the command.")
    let stored = try String(contentsOf: receiptURL(request, root: root), encoding: .utf8)
    XCTAssertFalse(stored.contains(privatePath))
    XCTAssertFalse(stored.contains("Secret"))
    XCTAssertFalse(retained.hasListWritePayload)

    let retry = try launchCLI(arguments, root: root)
    let retried = try await failureOutput(retry)
    XCTAssertEqual(retried["code"] as? String, "command_failed")
    XCTAssertEqual(retried["requestID"] as? String, request.requestID.uuidString)
    XCTAssertFalse((retried["message"] as? String)?.contains("Secret") == true)
    await store.processPending { received in
      XCTFail("A failed export must never replay")
      return SnipCLIReceipt(request: received, status: .success)
    }
  }

  func testExecutablePreservesUncertainOutcomeCodeAndRequestID() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("test")
    let request = SnipCLIRequest(action: .listLists, scopeToken: "test")
    _ = try await store.enqueue(request)
    await store.processPending { _ in throw SnipCLIOutcomeUncertain() }
    let state = try await store.state(for: request.requestID)
    XCTAssertEqual(state, .uncertain)

    let command = try launchCLI(["lists", "--json", "--request-id", request.requestID.uuidString], root: root)
    let error = try await failureOutput(command)
    XCTAssertEqual(error["code"] as? String, "outcome_unknown")
    XCTAssertEqual(error["requestID"] as? String, request.requestID.uuidString)
    XCTAssertTrue((error["message"] as? String)?.contains("Inspect the snip or list") == true)
    await store.processPending { received in
      XCTFail("An uncertain command must never run again")
      return SnipCLIReceipt(request: received, status: .success)
    }
  }

  func testExecutablePreservesInProgressTimeoutCodeAndRequestID() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("test")
    let request = SnipCLIRequest(action: .listLists, scopeToken: "test")
    let command = try launchCLI(["lists", "--json", "--request-id", request.requestID.uuidString], root: root)
    defer { if command.process.isRunning { command.process.terminate() } }
    try await waitUntilPending(request, store: store)
    await store.processPending { received in
      // Hold the real processing lease until the CLI's five-second timeout.
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while command.process.isRunning, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      return SnipCLIReceipt(request: received, status: .success)
    }
    let error = try await failureOutput(command)
    XCTAssertEqual(error["code"] as? String, "in_progress")
    XCTAssertEqual(error["requestID"] as? String, request.requestID.uuidString)
    XCTAssertTrue((error["message"] as? String)?.contains("still processing") == true)
  }

  func testExecutablePreservesUnavailableAppCodeAndCancelsUnclaimedRequests() async throws {
    // Cover both launch denial and a running-app marker with no handler.
    for scope: String? in [nil, "test"] {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = SnipCLIRequestStore(rootURL: root)
      if let scope { try await store.publishActiveScopeToken(scope) }
      let id = UUID()
      let command = try launchCLI(["lists", "--json", "--request-id", id.uuidString], root: root)
      let error = try await failureOutput(command)
      XCTAssertEqual(error["code"] as? String, "app_unavailable")
      XCTAssertEqual(error["requestID"] as? String, id.uuidString)
      XCTAssertTrue((error["message"] as? String)?.contains("No command was queued") == true)
      let state = try await store.state(for: id)
      XCTAssertEqual(state, .missing)
      await store.processPending { received in
        XCTFail("An unavailable-app failure must not leave a command queued")
        return SnipCLIReceipt(request: received, status: .success)
      }
    }
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("snipsnap-cli-error-fix-tests-\(UUID().uuidString)")
  }

  private func receiptURL(_ request: SnipCLIRequest, root: URL) -> URL {
    root.appendingPathComponent("Agent/Commands/Receipts/\(request.requestID.uuidString).json")
  }

  private func waitUntilPending(_ request: SnipCLIRequest, store: SnipCLIRequestStore) async throws {
    for _ in 0..<200 {
      if case .pending = try await store.state(for: request.requestID) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("CLI did not enqueue its request")
    throw NSError(domain: "SnipCLIErrorDeliveryTests.pendingTimeout", code: 1)
  }

  private func launchCLI(_ arguments: [String], root: URL) throws -> (process: Process, output: Pipe, errors: Pipe) {
    let executable = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent().appendingPathComponent("snipsnap")
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

  private func failureOutput(_ command: (process: Process, output: Pipe, errors: Pipe)) async throws -> [String: Any] {
    defer { if command.process.isRunning { command.process.terminate() } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while command.process.isRunning, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard !command.process.isRunning else {
      throw NSError(domain: "SnipCLIErrorDeliveryTests.timeout", code: 1)
    }
    XCTAssertEqual(command.process.terminationStatus, 1)
    XCTAssertTrue(command.output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    let data = command.errors.fileHandleForReading.readDataToEndOfFile()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["status"] as? String, "failed")
    return object
  }
}
