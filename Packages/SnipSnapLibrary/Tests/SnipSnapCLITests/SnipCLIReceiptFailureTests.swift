import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

final class SnipCLIReceiptFailureTests: XCTestCase {
  func testUnreadFailureMessageExpiresWhileTransitionIdentityRemainsVisible() async throws {
    for prune in [false, true] {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = SnipCLIRequestStore(rootURL: root)
      try await store.publishActiveScopeToken("before")
      // retrySync has no action payload, snips, lists, or extended result. The
      // failure message alone must still be recognized as a retained payload.
      let request = SnipCLIRequest(action: .extended(.application(.retrySync)), scopeToken: "before")
      _ = try await store.enqueue(request)
      await store.processPending { received in
        try await store.publishActiveScopeToken("after")
        return SnipCLIReceipt(request: received, status: .failed,
          message: "Cannot read /private/Secret note.txt", resultingScopeToken: "after")
      }
      let url = receiptURL(request, root: root)
      try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 60)],
        ofItemAtPath: url.path)
      try await store.pruneAbandoned()
      guard case .completed(let fresh) = try await store.state(for: request.requestID) else {
        return XCTFail("The actionable error must remain available before retention expires")
      }
      XCTAssertEqual(fresh.message, "Cannot read /private/Secret note.txt")
      XCTAssertTrue(fresh.hasListWritePayload)
      XCTAssertNil(fresh.extendedResult)

      try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 60 * 60)],
        ofItemAtPath: url.path)
      if prune { try await store.pruneAbandoned() }
      guard case .completed(let compact) = try await store.state(for: request.requestID) else {
        return XCTFail("An expired failed write must retain its receipt")
      }
      XCTAssertEqual(compact.status, .failed)
      XCTAssertEqual(compact.message, "Snip Snap could not complete the command.")
      XCTAssertFalse(compact.hasListWritePayload)
      XCTAssertTrue(compact.matches(request))
      XCTAssertEqual(compact.visibleScopeToken, "after")
      XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("Secret note"))
      do {
        _ = try await store.enqueue(request.scoped(to: "after"))
        XCTFail("A retained transition must prevent reusing its request ID in the new scope")
      } catch SnipCLIRequestError.conflictingRequestID {}
      await store.processPending { received in
        XCTFail("An expired failed write must never replay")
        return SnipCLIReceipt(request: received, status: .success)
      }
      try await store.publishActiveScopeToken("unrelated")
      let hidden = try await store.state(for: request.requestID)
      XCTAssertEqual(hidden, .missing)
    }
  }

  func testReadFailuresKeepActionableMessageUntilReleaseOrExpiryThenDisappear() async throws {
    for expire in [false, true] {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = SnipCLIRequestStore(rootURL: root)
      let request = SnipCLIRequest(action: .extended(.data(.previewBackup(path: "/private/Secret.zip"))))
      _ = try await store.enqueue(request)
      await store.processPending { _ in
        throw NSError(domain: "Export", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Cannot read /private/Secret.zip: access denied."])
      }
      guard case .completed(let delivered) = try await store.state(for: request.requestID) else {
        return XCTFail("Expected a readable failure before release")
      }
      XCTAssertEqual(delivered.status, .failed)
      XCTAssertEqual(delivered.message, "Cannot read /private/Secret.zip: access denied.")
      let url = receiptURL(request, root: root)
      if expire {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 60 * 60)],
          ofItemAtPath: url.path)
        try await store.pruneAbandoned()
      } else {
        try await store.releaseReceipt(request.requestID)
      }
      let state = try await store.state(for: request.requestID)
      XCTAssertEqual(state, .missing)
      XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
  }

  func testLegacyFailedWritesKeepTheirMessagesAndImmediateCompaction() async throws {
    let actions: [SnipCLIAction] = [.createList(name: "Private list"),
      .add(content: "Private text", list: "Private list", agentContext: nil)]
    for action in actions {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = SnipCLIRequestStore(rootURL: root)
      let request = SnipCLIRequest(action: action)
      _ = try await store.enqueue(request)
      await store.processPending { received in
        SnipCLIReceipt(request: received, status: .failed, message: "Finish editing and try again.")
      }
      guard case .completed(let delivered) = try await store.state(for: request.requestID) else {
        return XCTFail("Expected a legacy failed write")
      }
      XCTAssertEqual(delivered.status, .failed)
      XCTAssertEqual(delivered.message, "Finish editing and try again.")
      XCTAssertFalse(try String(contentsOf: receiptURL(request, root: root), encoding: .utf8).contains("Private"))
      try await store.releaseReceipt(request.requestID)
      guard case .completed(let retry) = try await store.enqueue(request) else {
        return XCTFail("Legacy failure must remain completed")
      }
      XCTAssertEqual(retry, delivered)
      XCTAssertTrue(retry.matches(request))
      await store.processPending { received in
        XCTFail("A failed legacy write must never replay")
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
}
