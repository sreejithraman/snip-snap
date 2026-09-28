import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnapCLI

final class SnipCommandStoreTests: XCTestCase {
  func testCompletedReceiptIsRejectedIfScopeSwitchesAfterRead() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("account-a")
    let request = SnipCLIRequest(action: .listSnips(list: nil), scopeToken: "account-a")
    _ = try await store.enqueue(request)
    await store.processPending { request in
      SnipCLIReceipt(request: request, status: .success,
                     snips: [Snip(content: "Private A", origin: .agent)])
    }
    guard case .completed(let receipt) = try await store.state(for: request.requestID) else {
      return XCTFail("Expected a completed receipt before switching accounts.")
    }

    try await store.publishActiveScopeToken("account-b")
    do {
      _ = try await SnipCLIService.completed(
        receipt, expectedScope: request.scopeToken, store: store
      )
      XCTFail("A receipt from account A must not be displayed after switching to B.")
    } catch SnipCLIRequestError.scopeChanged {}
  }

  func testAccountSwitchHidesOldReceiptsAndDoesNotClaimOldPendingCommands() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    try await store.publishActiveScopeToken("account-a")
    let oldRead = SnipCLIRequest(action: .listSnips(list: nil), scopeToken: "account-a")
    let oldWrite = SnipCLIRequest(action: .createList(name: "Only A"), scopeToken: "account-a")
    _ = try await store.enqueue(oldRead)
    await store.processPending { request in
      SnipCLIReceipt(request: request, status: .success,
                     snips: [Snip(content: "Private A", origin: .agent)])
    }
    _ = try await store.enqueue(oldWrite)
    try await store.publishActiveScopeToken("account-b")
    let hiddenRead = try await store.state(for: oldRead.requestID)
    let hiddenWrite = try await store.state(for: oldWrite.requestID)
    XCTAssertEqual(hiddenRead, .missing)
    XCTAssertEqual(hiddenWrite, .missing)
    do {
      _ = try await store.enqueue(SnipCLIRequest(
        action: oldWrite.action, requestID: oldWrite.requestID, scopeToken: "account-b"
      ))
      XCTFail("An old request ID must not be reused in a different account.")
    } catch SnipCLIRequestError.scopeChanged {}

    let newRead = SnipCLIRequest(action: .listLists, scopeToken: "account-b")
    _ = try await store.enqueue(newRead)
    await store.processPending { request in
      XCTAssertEqual(request.requestID, newRead.requestID)
      return SnipCLIReceipt(request: request, status: .success)
    }
    guard case .completed = try await store.state(for: newRead.requestID) else {
      return XCTFail("Expected the new account request to complete.")
    }
    try await store.publishActiveScopeToken("account-a")
    guard case .completed(let receipt) = try await store.state(for: oldRead.requestID) else {
      return XCTFail("Expected the old account receipt only in its original scope.")
    }
    XCTAssertEqual(receipt.snips.first?.content, "Private A")
  }

  func testReadRequestReturnsTheAppResponse() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let request = SnipCLIRequest(action: .listSnips(list: nil))

    let queued = try await store.enqueue(request)
    XCTAssertEqual(queued, .pending)
    let commandDirectory = root.appendingPathComponent("Agent/Commands")
    let attributes = try FileManager.default.attributesOfItem(atPath: commandDirectory.path)
    XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    XCTAssertEqual(try commandDirectory.resourceValues(
      forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

    let before = try await store.state(for: request.requestID)
    XCTAssertEqual(before, .pending)

    await store.processPending { received in
      let snip = Snip(content: "Follow up on the release", origin: .agent)
      return SnipCLIReceipt(request: received, status: .success, snips: [snip])
    }

    let after = try await store.state(for: request.requestID)
    guard case .completed(let receipt) = after else {
      return XCTFail("Expected a completed response.")
    }
    XCTAssertEqual(receipt.snips.map(\.content), ["Follow up on the release"])
    try await store.releaseReceipt(request.requestID)
    let cleaned = try await store.state(for: request.requestID)
    XCTAssertEqual(cleaned, .missing)
  }

  func testCancelledRequestIsNotProcessedLater() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let request = SnipCLIRequest(action: .deleteSnip(
      id: UUID(), expectedRevision: String(repeating: "a", count: 64)))
    _ = try await store.enqueue(request)

    let cancelled = try await store.cancelPending(request.requestID)
    XCTAssertEqual(cancelled, .missing)
    await store.processPending { _ in
      XCTFail("A cancelled delete must not reach the app.")
      return SnipCLIReceipt(request: request, status: .success)
    }
    let final = try await store.state(for: request.requestID)
    XCTAssertEqual(final, .missing)
  }

  func testCompletedUpdateKeepsRetryIdentityWithoutRetainingText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let id = UUID()
    let request = SnipCLIRequest(action: .updateSnip(
      id: id, content: "Private text", expectedUpdatedAt: Date()))
    _ = try await store.enqueue(request)
    await store.processPending { received in
      SnipCLIReceipt(request: received, status: .success,
                     snips: [Snip(content: "Private text", origin: .agent)],
                     lists: [SnipList(id: UUID(), name: "Sensitive list",
                                      systemImage: "folder", position: 1)])
    }
    try await store.releaseReceipt(request.requestID)
    let receiptURL = root.appendingPathComponent(
      "Agent/Commands/Receipts/\(request.requestID.uuidString).json")
    let data = try Data(contentsOf: receiptURL)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private text"))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Sensitive list"))
    guard case .completed(let receipt) = try await store.enqueue(request) else {
      return XCTFail("Expected retry receipt")
    }
    XCTAssertTrue(receipt.matches(request))
    XCTAssertNotNil(receipt.updatedSnipID)
    XCTAssertNotNil(receipt.updatedAt)
    XCTAssertTrue(receipt.snips.isEmpty)
    let output = try XCTUnwrap(JSONSerialization.jsonObject(
      with: SnipCLIPrinter.jsonData(for: receipt)) as? [String: Any])
    XCTAssertNotNil(output["updatedSnipID"])
    XCTAssertNotNil(output["updatedAt"])
    XCTAssertNil(output["action"])
    XCTAssertFalse(String(decoding: try SnipCLIPrinter.jsonData(for: receipt),
                          as: UTF8.self).contains("Private text"))
  }

  func testCompletedAddKeepsIDsWithoutRetainingTextOrListName() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let request = SnipCLIRequest(action: .add(
      content: "Private future idea", list: "Private list", agentContext: nil))
    let snip = Snip(content: "Private future idea", origin: .agent)
    let list = SnipList(id: UUID(), name: "Private list", systemImage: "folder", position: 1)
    _ = try await store.enqueue(request)
    await store.processPending { received in
      SnipCLIReceipt(request: received, status: .success, snips: [snip], lists: [list])
    }
    guard case .completed(let delivered) = try await store.state(for: request.requestID) else {
      return XCTFail("Expected full add result before delivery")
    }
    XCTAssertEqual(delivered.resultSnipID, snip.id)
    XCTAssertEqual(delivered.lists.first?.name, list.name)
    try await store.releaseReceipt(request.requestID)

    let receiptURL = root.appendingPathComponent(
      "Agent/Commands/Receipts/\(request.requestID.uuidString).json")
    let bytes = try Data(contentsOf: receiptURL)
    let stored = String(decoding: bytes, as: UTF8.self)
    XCTAssertFalse(stored.contains("Private future idea"))
    XCTAssertFalse(stored.contains("Private list"))
    guard case .completed(let retried) = try await store.enqueue(request) else {
      return XCTFail("Expected add retry receipt")
    }
    XCTAssertEqual(retried.resultSnipID, snip.id)
    XCTAssertEqual(retried.resultListID, list.id)
    XCTAssertTrue(retried.lists.isEmpty)
  }

  func testCompletedListWriteDropsNameAfterDeliveryAndIfUnreadExpires() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let list = SnipList(id: UUID(), name: "Private list", systemImage: "folder", position: 1)
    let delivered = SnipCLIRequest(action: .createList(name: "Private list"))
    _ = try await store.enqueue(delivered)
    await store.processPending { request in
      SnipCLIReceipt(request: request, status: .success, lists: [list])
    }
    guard case .completed(let full) = try await store.state(for: delivered.requestID) else {
      return XCTFail("Expected full result before delivery")
    }
    XCTAssertEqual(full.lists.first?.name, "Private list")
    try await store.releaseReceipt(delivered.requestID)
    let receipts = root.appendingPathComponent("Agent/Commands/Receipts")
    let deliveredURL = receipts.appendingPathComponent("\(delivered.requestID.uuidString).json")
    XCTAssertFalse(try String(contentsOf: deliveredURL, encoding: .utf8).contains("Private list"))
    guard case .completed(let compact) = try await store.enqueue(delivered) else {
      return XCTFail("Expected retry record")
    }
    XCTAssertTrue(compact.matches(delivered))
    XCTAssertEqual(compact.message, "Created list \(list.id.uuidString).")
    XCTAssertEqual(compact.resultListID, list.id)
    let output = try XCTUnwrap(JSONSerialization.jsonObject(
      with: SnipCLIPrinter.jsonData(for: compact)) as? [String: Any])
    XCTAssertEqual(output["resultListID"] as? String, list.id.uuidString)

    let unread = SnipCLIRequest(action: .updateList(
      id: list.id, name: "Private rename", expectedRevision: String(repeating: "a", count: 64)))
    _ = try await store.enqueue(unread)
    await store.processPending { request in
      SnipCLIReceipt(request: request, status: .success,
                     lists: [SnipList(id: list.id, name: "Private rename",
                                      systemImage: "folder", position: 1)])
    }
    let unreadURL = receipts.appendingPathComponent("\(unread.requestID.uuidString).json")
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-2 * 60 * 60)],
      ofItemAtPath: unreadURL.path
    )
    guard case .completed(let expired) = try await store.state(for: unread.requestID) else {
      return XCTFail("Expected compact retry record")
    }
    XCTAssertTrue(expired.matches(unread))
    XCTAssertFalse(try String(contentsOf: unreadURL, encoding: .utf8).contains("Private rename"))
  }

  func testOldWriteRequestIDCannotRunAgainAfterReceiptRetentionWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let request = SnipCLIRequest(action: .createList(name: "Private list"))
    _ = try await store.enqueue(request)
    await store.processPending { request in
      SnipCLIReceipt(request: request, status: .success,
                     lists: [SnipList(id: UUID(), name: "Private list",
                                      systemImage: "folder", position: 1)])
    }
    try await store.releaseReceipt(request.requestID)
    let receiptURL = root.appendingPathComponent(
      "Agent/Commands/Receipts/\(request.requestID.uuidString).json")
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
      ofItemAtPath: receiptURL.path
    )

    try await store.pruneAbandoned()
    guard case .completed(let receipt) = try await store.enqueue(request) else {
      return XCTFail("An old write must keep its request ID and result.")
    }
    XCTAssertTrue(receipt.matches(request))
    XCTAssertFalse(try String(contentsOf: receiptURL, encoding: .utf8).contains("Private list"))
  }

  func testDeadClientRequestCannotRunAfterAppLaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let request = SnipCLIRequest(action: .deleteList(
      id: UUID(), expectedRevision: String(repeating: "a", count: 64)), clientPID: Int32.max)
    _ = try await store.enqueue(request)
    try await store.pruneAbandoned()
    let pendingURL = root.appendingPathComponent(
      "Agent/Commands/Pending/\(request.requestID.uuidString).json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
    await store.processPending { _ in
      XCTFail("A command from an exited CLI must not reach the app")
      return SnipCLIReceipt(request: request, status: .success)
    }
    let state = try await store.state(for: request.requestID)
    XCTAssertEqual(state, .missing)
  }

  func testUnreadReadReceiptExpiresAfterRecoveryWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let request = SnipCLIRequest(action: .showSnip(id: UUID()))
    _ = try await store.enqueue(request)
    await store.processPending { received in
      SnipCLIReceipt(request: received, status: .success,
                     snips: [Snip(content: "Private read", origin: .agent)])
    }
    let receiptURL = root.appendingPathComponent(
      "Agent/Commands/Receipts/\(request.requestID.uuidString).json")
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-2 * 60 * 60)],
      ofItemAtPath: receiptURL.path
    )
    let unrelatedStatus = try await SnipCLIService.status(UUID(), store: store)
    XCTAssertEqual(unrelatedStatus, .missing)
    let state = try await store.state(for: request.requestID)
    XCTAssertEqual(state, .missing)
  }

  func testClaimedUpdateStaysProcessingAfterRequestExpiryWithoutRetainingText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let request = SnipCLIRequest(
      action: .updateSnip(id: UUID(), content: "Private replacement", expectedUpdatedAt: Date()),
      expiresAt: Date().addingTimeInterval(0.5)
    )
    _ = try await store.enqueue(request)
    let started = expectation(description: "App claimed request")
    let processing = Task {
      await store.processPending { received in
        started.fulfill()
        try? await Task.sleep(for: .seconds(1))
        return SnipCLIReceipt(request: received, status: .success)
      }
    }
    await fulfillment(of: [started], timeout: 2)
    let markerURL = root.appendingPathComponent(
      "Agent/Commands/Processing/\(request.requestID.uuidString).json")
    let marker = try String(contentsOf: markerURL, encoding: .utf8)
    XCTAssertFalse(marker.contains("Private replacement"))
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
      ofItemAtPath: markerURL.path
    )
    try await store.pruneAbandoned()
    XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    try await Task.sleep(for: .milliseconds(600))
    let inProgress = try await store.state(for: request.requestID)
    XCTAssertEqual(inProgress, .processing)
    await processing.value
    guard case .completed = try await store.state(for: request.requestID) else {
      return XCTFail("Expected a final receipt")
    }
  }

  func testReceiptWriteFailureLeavesAnUncertainMarker() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let receipts = root.appendingPathComponent("Agent/Commands/Receipts")
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                             ofItemAtPath: receipts.path)
      try? FileManager.default.removeItem(at: root)
    }
    let store = SnipCLIRequestStore(rootURL: root)
    let request = SnipCLIRequest(action: .deleteList(
      id: UUID(), expectedRevision: String(repeating: "a", count: 64)))
    _ = try await store.enqueue(request)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                          ofItemAtPath: receipts.path)
    await store.processPending { received in
      SnipCLIReceipt(request: received, status: .success)
    }
    let result = try await store.state(for: request.requestID)
    XCTAssertEqual(result, .uncertain)
  }

  func testAmbiguousAppWriteKeepsAnUncertainMarkerWithoutFailedReceipt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SnipCLIRequestStore(rootURL: root)
    let request = SnipCLIRequest(action: .updateSnip(
      id: UUID(), content: "Maybe committed", expectedUpdatedAt: Date()))
    _ = try await store.enqueue(request)

    await store.processPending { _ in throw SnipCLIOutcomeUncertain() }

    let state = try await store.state(for: request.requestID)
    let retried = try await store.enqueue(request)
    XCTAssertEqual(state, .uncertain)
    XCTAssertEqual(retried, .uncertain)
    let markerURL = root.appendingPathComponent(
      "Agent/Commands/Processing/\(request.requestID.uuidString).json")
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
      ofItemAtPath: markerURL.path
    )
    try await store.pruneAbandoned()
    let oldRetry = try await store.enqueue(request)
    XCTAssertEqual(oldRetry, .uncertain)
    let receiptURL = root.appendingPathComponent(
      "Agent/Commands/Receipts/\(request.requestID.uuidString).json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
  }

  func testReceiptAndMarkerWriteFailuresStillEndProcessing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let commands = root.appendingPathComponent("Agent/Commands")
    let receipts = commands.appendingPathComponent("Receipts")
    let processing = commands.appendingPathComponent("Processing")
    defer {
      for directory in [receipts, processing] {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)
      }
      try? FileManager.default.removeItem(at: root)
    }
    let store = SnipCLIRequestStore(rootURL: root)
    let request = SnipCLIRequest(action: .deleteList(
      id: UUID(), expectedRevision: String(repeating: "a", count: 64)))
    _ = try await store.enqueue(request)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                          ofItemAtPath: receipts.path)
    await store.processPending { received in
      try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                            ofItemAtPath: processing.path)
      return SnipCLIReceipt(request: received, status: .success)
    }
    let result = try await store.state(for: request.requestID)
    XCTAssertEqual(result, .uncertain)
  }
}
