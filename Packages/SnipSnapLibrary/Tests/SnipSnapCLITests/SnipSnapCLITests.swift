@testable import SnipSnapCLI
import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

final class SnipSnapCLITests: XCTestCase {
  func testParserAcceptsReadingSavedSnips() throws {
    guard case .request(let options) = try SnipSnapCLIParser.parse([
      "list", "--list", "Research", "--json",
    ]) else { return XCTFail("Expected list command.") }
    XCTAssertEqual(options.input, .action(.listSnips(list: "Research")))
    XCTAssertTrue(options.json)
  }

  func testParserPassesEmptyUpdateToLibraryForAttachmentSnips() throws {
    let id = UUID()
    let timestamp = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
    guard case .request(let options) = try SnipSnapCLIParser.parse([
      "update", id.uuidString, "--if-updated-at", "1700000000", "",
    ]) else { return XCTFail("Expected update command.") }
    XCTAssertEqual(try options.action(), .updateSnip(
      id: id, content: "", expectedUpdatedAt: timestamp))
  }

  func testParserRequiresExplicitDeleteConfirmation() throws {
    let id = UUID()
    let revision = String(repeating: "a", count: 64)
    XCTAssertThrowsError(try SnipSnapCLIParser.parse(["delete", id.uuidString]))
    guard case .request(let options) = try SnipSnapCLIParser.parse([
      "delete", id.uuidString, "--if-snip-revision", revision, "--yes",
    ]) else { return XCTFail("Expected delete command.") }
    XCTAssertEqual(options.input, .action(.deleteSnip(id: id, expectedRevision: revision)))

    XCTAssertThrowsError(try SnipSnapCLIParser.parse(["lists", "delete", id.uuidString]))
    guard case .request(let listOptions) = try SnipSnapCLIParser.parse([
      "lists", "delete", id.uuidString, "--if-list-revision", revision, "--yes",
    ]) else { return XCTFail("Expected list delete command.") }
    XCTAssertEqual(listOptions.input, .action(.deleteList(id: id, expectedRevision: revision)))
  }

  func testParserAcceptsAgentFriendlyAddOptions() throws {
    let requestID = UUID()
    let command = try SnipSnapCLIParser.parse([
      "add", "--list", "Research", "--request-id", requestID.uuidString,
      "--session-title", "Agent provenance", "--branch", "feature/agent-context",
      "--json", "Keep", "this",
    ])

    guard case .add(let options) = command else { return XCTFail("Expected add command.") }
    XCTAssertEqual(options.textArguments, ["Keep", "this"])
    XCTAssertEqual(options.list, "Research")
    XCTAssertEqual(options.sessionTitle, "Agent provenance")
    XCTAssertEqual(options.branchName, "feature/agent-context")
    XCTAssertEqual(options.requestID, requestID)
    XCTAssertTrue(options.emitsJSON)
    XCTAssertFalse(options.readsStandardInput)
  }

  func testAgentContextPrefersSessionTitleAndFallsBackToBranch() {
    XCTAssertEqual(
      SnipAgentContext(
        sessionTitle: "  Agent provenance  ",
        branchName: "feature/agent-context"
      ).displayLabel,
      "Agent provenance"
    )
    XCTAssertEqual(
      SnipAgentContext(branchName: " feature/agent-context ").displayLabel,
      "feature/agent-context"
    )
    XCTAssertNil(SnipAgentContext(sessionTitle: " \n ", branchName: "").displayLabel)
  }

  func testRequestFingerprintDistinguishesDestinationAndOptionalFieldBoundaries() {
    let firstListID = UUID()
    let secondListID = UUID()
    let base = AgentImportRequest(content: "Keep this", destinationListID: firstListID)
    let otherList = AgentImportRequest(content: "Keep this", destinationListID: secondListID)
    let emptySelector = AgentImportRequest(
      content: "Keep this",
      destinationListID: firstListID,
      destinationSelector: ""
    )

    XCTAssertNotEqual(base.fingerprint, otherList.fingerprint)
    XCTAssertNotEqual(base.fingerprint, emptySelector.fingerprint)
    XCTAssertNotEqual(
      base.fingerprint,
      AgentImportRequest(
        content: "Keep this", destinationListID: firstListID, scopeToken: "account-a"
      ).fingerprint
    )
  }

  func testQueuedAddWaitsForOriginalLibraryScope() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.imports.publishAvailableLists([.inbox], scopeToken: "account-a")
    var options = SnipSnapAddOptions()
    options.requestID = UUID()
    _ = try await SnipSnapCLIService.add(
      options: options, content: "Scoped note", imports: fixture.imports,
      scopeToken: "account-a"
    )

    let wrongScope = await fixture.imports.importPending(activeScopeToken: "account-b") { _ in
      XCTFail("A queued add must not reach the wrong account")
      throw AgentImportError.invalidRequest
    }
    XCTAssertEqual(wrongScope, AgentImportSummary(imported: 0, failed: 0))
    let pendingBefore = await fixture.imports.pendingImportCount()
    XCTAssertEqual(pendingBefore, 1)

    let originalScope = await fixture.imports.importPending(activeScopeToken: "account-a") {
      request in
      XCTAssertEqual(request.scopeToken, "account-a")
      return AgentImportReceipt(
        status: .added, snipID: UUID(), listID: request.destinationListID,
        listName: "Inbox", request: request
      )
    }
    XCTAssertEqual(originalScope, AgentImportSummary(imported: 1, failed: 0))
    let pendingAfter = await fixture.imports.pendingImportCount()
    XCTAssertEqual(pendingAfter, 0)
  }

  func testQueuedAddStillReportsRequestIDIfLibrarySwitchesBeforeOutput() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = SnipCLIRequestStore(rootURL: fixture.directory)
    try await requests.publishActiveScopeToken("account-a")
    try await fixture.imports.publishAvailableLists([.inbox], scopeToken: "account-a")
    var options = SnipSnapAddOptions()
    options.requestID = UUID()
    let pending = try await SnipSnapCLIService.add(
      options: options, content: "Scoped note", imports: fixture.imports,
      scopeToken: "account-a"
    )
    XCTAssertEqual(pending.status, .pending)

    try await requests.publishActiveScopeToken("account-b")
    let output = try await SnipSnapCLIService.completedOrPendingResult(
      pending, imports: fixture.imports, requests: requests, scopeToken: "account-a"
    )
    XCTAssertEqual(output.status, .pending)
    XCTAssertEqual(output.requestID, options.requestID)
    let pendingCount = await fixture.imports.pendingImportCount()
    XCTAssertEqual(pendingCount, 1)
  }

  func testUnattributedAddKeepsRetryIdentityBeforeAndAfterInboxApproval() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let research = SnipList(
      id: UUID(), name: "Research", systemImage: "folder", position: 1
    )
    try await fixture.imports.publishAvailableLists([.inbox, research])
    var options = SnipSnapAddOptions()
    options.list = "Research"
    options.requestID = UUID()
    let first = try await SnipSnapCLIService.add(
      options: options, content: "Future idea", imports: fixture.imports
    )
    XCTAssertEqual(first.status, .pending)
    XCTAssertEqual(first.listID, research.id)

    // The app has now established a library scope, but the user has not approved
    // this previously unattributed request for it yet.
    try await fixture.imports.publishAvailableLists([.inbox], scopeToken: "account-b")
    let beforeApproval = try await SnipSnapCLIService.add(
      options: options, content: "Future idea", imports: fixture.imports,
      scopeToken: "account-b"
    )
    XCTAssertEqual(beforeApproval.status, .pending)
    XCTAssertEqual(beforeApproval.listID, research.id)

    try await fixture.imports.bindPendingRequestToInbox(
      options.requestID, scopeToken: "account-b"
    )
    let afterApproval = try await SnipSnapCLIService.add(
      options: options, content: "Future idea", imports: fixture.imports,
      scopeToken: "account-b"
    )
    XCTAssertEqual(afterApproval.status, .pending)
    XCTAssertEqual(afterApproval.listID, SnipList.inboxID)
    let summary = await fixture.imports.importPending(activeScopeToken: "account-b") { request in
      XCTAssertNil(request.scopeToken)
      XCTAssertEqual(request.destinationListID, research.id)
      XCTAssertEqual(request.destinationSelector, "Research")
      XCTAssertEqual(request.executionListID, SnipList.inboxID)
      return AgentImportReceipt(
        status: .added, snipID: UUID(), listID: request.executionListID,
        listName: SnipList.inbox.name, request: request
      )
    }
    XCTAssertEqual(summary, AgentImportSummary(imported: 1, failed: 0))

    let completed = try await SnipSnapCLIService.add(
      options: options, content: "Future idea", imports: fixture.imports,
      scopeToken: "account-b"
    )
    XCTAssertEqual(completed.status, .unchanged)
    XCTAssertEqual(completed.listID, SnipList.inboxID)
    do {
      _ = try await SnipSnapCLIService.add(
        options: options, content: "Future idea", imports: fixture.imports,
        scopeToken: "account-c"
      )
      XCTFail("Approved adds must stay in their chosen library")
    } catch SnipCLIRequestError.scopeChanged {}
  }

  func testClosedAppAddForPreviousLibraryRequiresExplicitInboxChoice() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.imports.publishAvailableLists([.inbox], scopeToken: "account-a")
    var options = SnipSnapAddOptions()
    options.requestID = UUID()
    let queued = try await SnipSnapCLIService.add(
      options: options, content: "From account A", imports: fixture.imports,
      scopeToken: "account-a"
    )
    XCTAssertEqual(queued.status, .pending)
    try await fixture.imports.publishAvailableLists([.inbox], scopeToken: "account-b")

    let skipped = await fixture.imports.importPending(activeScopeToken: "account-b") { _ in
      XCTFail("An add from account A must wait for a choice")
      throw AgentImportError.invalidRequest
    }
    XCTAssertEqual(skipped, AgentImportSummary(imported: 0, failed: 0))
    let needsAttention = try await fixture.imports.pendingRequestsRequiringAttention(
      activeScopeToken: "account-b"
    )
    XCTAssertEqual(needsAttention.map(\.requestID), [options.requestID])

    try await fixture.imports.bindPendingRequestToInbox(
      options.requestID, scopeToken: "account-b"
    )
    let imported = await fixture.imports.importPending(activeScopeToken: "account-b") { request in
      XCTAssertEqual(request.scopeToken, "account-a")
      XCTAssertEqual(request.approvedInboxScopeToken, "account-b")
      XCTAssertEqual(request.executionListID, SnipList.inboxID)
      return AgentImportReceipt(
        status: .added, snipID: UUID(), listID: request.executionListID,
        listName: SnipList.inbox.name, request: request
      )
    }
    XCTAssertEqual(imported, AgentImportSummary(imported: 1, failed: 0))
    let retry = try await SnipSnapCLIService.add(
      options: options, content: "From account A", imports: fixture.imports,
      scopeToken: "account-b"
    )
    XCTAssertEqual(retry.status, .unchanged)
    do {
      _ = try await SnipSnapCLIService.add(
        options: options, content: "From account A", imports: fixture.imports,
        scopeToken: "account-a"
      )
      XCTFail("The approved add now belongs to account B")
    } catch SnipCLIRequestError.scopeChanged {}
  }

  func testInterruptedLibraryTransitionStillQueuesOfflineAddForReview() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = SnipCLIRequestStore(rootURL: fixture.directory)
    try await requests.publishActiveScopeToken("account-a")
    try await fixture.imports.publishAvailableLists([.inbox], scopeToken: "account-a")

    try await requests.suspendActiveScope()
    let unavailableScope = try await requests.activeScopeToken()
    XCTAssertNil(unavailableScope)
    var options = SnipSnapAddOptions()
    options.requestID = UUID()
    let queued = try await SnipSnapCLIService.add(
      options: options, content: "Interrupted transition idea",
      imports: fixture.imports, scopeToken: unavailableScope
    )
    XCTAssertEqual(queued.status, .pending)
    let pending = try await fixture.imports.pendingRequestsRequiringAttention(
      activeScopeToken: "account-b"
    )
    XCTAssertEqual(pending.map(\.requestID), [options.requestID])
  }

  func testAddCompletionWaitRejectsAnActiveLibrarySwitch() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = SnipCLIRequestStore(rootURL: fixture.directory)
    try await requests.publishActiveScopeToken("account-a")
    let request = AgentImportRequest(
      content: "Account A idea", destinationListID: SnipList.inboxID,
      scopeToken: "account-a"
    )
    _ = try await fixture.imports.save(request)
    let waiting = Task {
      try await SnipSnapCLIService.completedResult(
        requestID: request.requestID, imports: fixture.imports,
        requests: requests, scopeToken: "account-a", timeout: .seconds(1)
      )
    }
    await Task.yield()
    try await requests.publishActiveScopeToken("account-b")
    do {
      _ = try await waiting.value
      XCTFail("The original add must not report a result after the library switches")
    } catch SnipCLIRequestError.scopeChanged {}
  }

  func testCompletedScopedAddReportsLibrarySwitchOnRetry() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.imports.publishAvailableLists([.inbox], scopeToken: "account-a")
    var options = SnipSnapAddOptions()
    options.requestID = UUID()
    _ = try await SnipSnapCLIService.add(
      options: options, content: "Account A idea", imports: fixture.imports,
      scopeToken: "account-a"
    )
    _ = await fixture.imports.importPending(activeScopeToken: "account-a") { request in
      AgentImportReceipt(
        status: .added, snipID: UUID(), listID: request.executionListID,
        listName: SnipList.inbox.name, request: request
      )
    }

    do {
      _ = try await SnipSnapCLIService.add(
        options: options, content: "Account A idea", imports: fixture.imports,
        scopeToken: "account-b"
      )
      XCTFail("A completed add must remain owned by account A")
    } catch SnipCLIRequestError.scopeChanged {}
  }

  func testLegacyCompletedAddRequiresLibraryVerificationAfterUpgrade() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var options = SnipSnapAddOptions()
    options.requestID = UUID()
    _ = try await SnipSnapCLIService.add(
      options: options, content: "Older idea", imports: fixture.imports
    )
    _ = await fixture.imports.importPending { request in
      AgentImportReceipt(
        status: .added, snipID: UUID(), listID: request.destinationListID,
        listName: SnipList.inbox.name, request: request
      )
    }
    let receiptURL = fixture.directory.appendingPathComponent(
      "Agent/Receipts/\(options.requestID.uuidString).json"
    )
    let oldReceipt = try JSONSerialization.jsonObject(
      with: Data(contentsOf: receiptURL)
    ) as? [String: Any]
    XCTAssertNil(oldReceipt?["requestScopeToken"])
    XCTAssertNil(oldReceipt?["approvedInboxScopeToken"])

    do {
      _ = try await SnipSnapCLIService.add(
        options: options, content: "Older idea", imports: fixture.imports
      )
      XCTFail("An old receipt cannot prove library ownership while the app is closed")
    } catch SnipSnapCLIError.legacyAddNeedsVerification(let id) {
      XCTAssertEqual(id, options.requestID)
    }
    do {
      _ = try await SnipSnapCLIService.add(
        options: options, content: "Older idea", imports: fixture.imports,
        scopeToken: "account-b"
      )
      XCTFail("An old receipt cannot prove which library owns the snip")
    } catch SnipSnapCLIError.legacyAddNeedsVerification(let id) {
      XCTAssertEqual(id, options.requestID)
    }
  }

  func testScopedAddNeverResolvesAnotherAccountListCatalog() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let firstList = SnipList(
      id: UUID(), name: "Research", systemImage: "folder", position: 1
    )
    let secondList = SnipList(
      id: UUID(), name: "Research", systemImage: "folder", position: 1
    )
    try await fixture.imports.publishAvailableLists([.inbox, firstList], scopeToken: "account-a")
    var options = SnipSnapAddOptions()
    options.list = "Research"

    do {
      _ = try await SnipSnapCLIService.add(
        options: options, content: "Account B note", imports: fixture.imports,
        scopeToken: "account-b"
      )
      XCTFail("A new scope must not resolve the old account's list")
    } catch SnipCLIRequestError.scopeChanged {}
    let pendingBefore = await fixture.imports.pendingImportCount()
    XCTAssertEqual(pendingBefore, 0)

    try await fixture.imports.publishAvailableLists([.inbox, secondList], scopeToken: "account-b")
    let added = try await SnipSnapCLIService.add(
      options: options, content: "Account B note", imports: fixture.imports,
      scopeToken: "account-b"
    )
    XCTAssertEqual(added.listID, secondList.id)
  }

  func testReturningToScopeImportsAfterPreviousImportFinishes() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let first = AgentImportRequest(
      content: "Account B", destinationListID: SnipList.inboxID, scopeToken: "account-b"
    )
    let second = AgentImportRequest(
      content: "Account A", destinationListID: SnipList.inboxID, scopeToken: "account-a"
    )
    _ = try await fixture.imports.save(first)
    _ = try await fixture.imports.save(second)
    let gate = TestGate()
    let started = expectation(description: "account B import started")
    let importingB = Task {
      await fixture.imports.importPending(activeScopeToken: "account-b") { request in
        started.fulfill()
        await gate.wait()
        return AgentImportReceipt(
          status: .added, snipID: UUID(), listID: request.destinationListID,
          listName: "Inbox", request: request
        )
      }
    }
    await fulfillment(of: [started])
    let importingA = Task {
      await fixture.imports.importPending(
        activeScopeToken: "account-a", waitForCurrent: true
      ) { request in
        XCTAssertEqual(request.requestID, second.requestID)
        return AgentImportReceipt(
          status: .added, snipID: UUID(), listID: request.destinationListID,
          listName: "Inbox", request: request
        )
      }
    }
    await Task.yield()
    await gate.open()
    let bSummary = await importingB.value
    let aSummary = await importingA.value
    XCTAssertEqual(bSummary, AgentImportSummary(imported: 1, failed: 0))
    XCTAssertEqual(aSummary, AgentImportSummary(imported: 1, failed: 0))
  }

  func testParserUsesStandardInputWhenTextIsOmitted() throws {
    guard case .add(let options) = try SnipSnapCLIParser.parse(["add"]) else {
      return XCTFail("Expected add command.")
    }
    XCTAssertTrue(options.readsStandardInput)
  }

  func testAddQueuesAgentRequestAndRetryIsIdempotent() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requestID = UUID()
    var options = SnipSnapAddOptions()
    options.requestID = requestID
    options.sessionTitle = "Agent provenance"
    options.branchName = "feature/agent-context"

    let first = try await SnipSnapCLIService.add(
      options: options, content: "Agent note", imports: fixture.imports
    )
    let second = try await SnipSnapCLIService.add(
      options: options, content: "Agent note", imports: fixture.imports
    )

    XCTAssertEqual(first.status, .pending)
    XCTAssertEqual(second, first)
    XCTAssertNil(first.id)
    let pendingCount = await fixture.imports.pendingImportCount()
    XCTAssertEqual(pendingCount, 1)
    XCTAssertEqual(first.origin, "agent")

    var importedContext: SnipAgentContext?
    _ = await fixture.imports.importPending { request in
      importedContext = request.agentContext
      return AgentImportReceipt(
        status: .added,
        snipID: UUID(),
        listID: request.destinationListID,
        listName: "Inbox",
        request: request
      )
    }
    XCTAssertEqual(
      importedContext,
      SnipAgentContext(
        sessionTitle: "Agent provenance",
        branchName: "feature/agent-context"
      )
    )
  }

  func testAddTargetsAListByCanonicalName() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let listUpdate = try await fixture.library.perform(
      .createList(name: "Research", systemImage: "books.vertical"),
      sortedBy: .chronological
    )
    guard case .listCreated(let list) = listUpdate.outcome else {
      return XCTFail("Expected a created list.")
    }
    var options = SnipSnapAddOptions()
    options.list = "  Ｒｅｓｅａｒｃｈ  "

    let result = try await SnipSnapCLIService.add(
      options: options, content: "Read this", imports: fixture.imports
    )

    XCTAssertEqual(result.listID, list.id)
    XCTAssertEqual(result.listName, "Research")
  }

  func testCompletedRetryIsUnchangedAfterListLeavesCatalog() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let update = try await fixture.library.perform(
      .createList(name: "Research", systemImage: "books.vertical"),
      sortedBy: .chronological
    )
    guard case .listCreated(let research) = update.outcome else {
      return XCTFail("Expected a created list.")
    }
    try await fixture.imports.publishAvailableLists([.inbox, research], scopeToken: "account-a")
    let requestID = UUID()
    var firstOptions = SnipSnapAddOptions()
    firstOptions.list = research.name
    firstOptions.requestID = requestID
    _ = try await SnipSnapCLIService.add(
      options: firstOptions, content: "Read this", imports: fixture.imports,
      scopeToken: "account-a"
    )

    let summary = await fixture.imports.importPending(activeScopeToken: "account-a") { request in
      let saved = try await fixture.library.perform(
        .add(
          content: request.content,
          origin: .agent,
          source: nil,
          listID: request.destinationListID,
          attachmentURLs: [],
          requestID: request.requestID,
          now: request.createdAt
        ),
        sortedBy: .chronological
      )
      guard case .add(.added(let id)) = saved.outcome else {
        throw SnipLibraryError.invalidCommand
      }
      return AgentImportReceipt(
        status: .added,
        snipID: id,
        listID: research.id,
        listName: research.name,
        request: request
      )
    }
    XCTAssertEqual(summary, AgentImportSummary(imported: 1, failed: 0))
    try await fixture.imports.publishAvailableLists([.inbox], scopeToken: "account-a")

    var retryOptions = SnipSnapAddOptions()
    retryOptions.list = research.name
    retryOptions.requestID = requestID
    let retry = try await SnipSnapCLIService.add(
      options: retryOptions, content: "Read this", imports: fixture.imports,
      scopeToken: "account-a"
    )

    XCTAssertEqual(retry.status, .unchanged)
    XCTAssertEqual(retry.listID, research.id)
    XCTAssertEqual(retry.listName, "Research")
  }

  func testPendingRetrySucceedsAfterListLeavesCatalog() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let update = try await fixture.library.perform(
      .createList(name: "Research", systemImage: "books.vertical"),
      sortedBy: .chronological
    )
    guard case .listCreated(let research) = update.outcome else {
      return XCTFail("Expected a created list.")
    }
    let requestID = UUID()
    var options = SnipSnapAddOptions()
    options.list = research.name
    options.requestID = requestID
    let first = try await SnipSnapCLIService.add(
      options: options, content: "Read this", imports: fixture.imports
    )
    try await fixture.imports.publishAvailableLists([.inbox])

    let retry = try await SnipSnapCLIService.add(
      options: options, content: "Read this", imports: fixture.imports
    )

    XCTAssertEqual(first.status, .pending)
    XCTAssertEqual(retry.status, .pending)
    XCTAssertEqual(retry.listID, research.id)
    XCTAssertEqual(retry.listName, "Research")
    let pendingCount = await fixture.imports.pendingImportCount()
    XCTAssertEqual(pendingCount, 1)
  }

  func testReusingRequestIDForDifferentContentFails() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var options = SnipSnapAddOptions()
    options.requestID = UUID()
    _ = try await SnipSnapCLIService.add(
      options: options, content: "First", imports: fixture.imports
    )

    do {
      _ = try await SnipSnapCLIService.add(
        options: options, content: "Different", imports: fixture.imports
      )
      XCTFail("Expected a request ID conflict.")
    } catch {
      XCTAssertEqual(error as? AgentImportError, .conflictingRequestID)
    }
  }

  func testWhitespaceOnlyContentFailsBeforeItIsQueued() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    do {
      _ = try await SnipSnapCLIService.add(
        options: SnipSnapAddOptions(), content: " \n\t", imports: fixture.imports
      )
      XCTFail("Expected empty content to fail.")
    } catch {
      XCTAssertEqual(error as? SnipSnapCLIError, .missingContent)
    }
    let pendingCount = await fixture.imports.pendingImportCount()
    XCTAssertEqual(pendingCount, 0)
  }

  func testCompletedRequestIDRejectsDifferentContent() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var options = SnipSnapAddOptions()
    options.requestID = UUID()
    _ = try await SnipSnapCLIService.add(
      options: options, content: "First", imports: fixture.imports
    )
    _ = await fixture.imports.importPending { request in
      AgentImportReceipt(
        status: .added,
        snipID: UUID(),
        listID: .init(uuidString: "00000000-0000-0000-0000-000000000001")!,
        listName: "Inbox",
        request: request
      )
    }

    do {
      _ = try await SnipSnapCLIService.add(
        options: options, content: "Different", imports: fixture.imports
      )
      XCTFail("Expected a request ID conflict.")
    } catch {
      XCTAssertEqual(error as? AgentImportError, .conflictingRequestID)
    }
  }

  func testTerminalImportConflictWritesFailedReceiptAndStopsRetrying() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let request = AgentImportRequest(
      content: "Conflicting agent todo",
      destinationListID: SnipList.inboxID
    )
    _ = try await fixture.imports.save(request)

    let first = await fixture.imports.importPending { _ in
      throw AgentImportError.conflictingRequestID
    }
    let second = await fixture.imports.importPending { _ in
      XCTFail("A terminal conflict must not remain pending.")
      throw SnipLibraryError.invalidCommand
    }
    let receipt = try await fixture.imports.receipt(for: request.requestID)
    let pendingCount = await fixture.imports.pendingImportCount()

    XCTAssertEqual(first, AgentImportSummary(imported: 0, failed: 1))
    XCTAssertEqual(second, AgentImportSummary(imported: 0, failed: 0))
    XCTAssertEqual(receipt?.status, .failed)
    XCTAssertTrue(receipt?.matches(request) == true)
    XCTAssertEqual(pendingCount, 0)
  }

  func testReturnedFailedReceiptCountsAsFailedAndLeavesNoPendingRequest() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let request = AgentImportRequest(
      content: "Deleted original",
      destinationListID: SnipList.inboxID
    )
    _ = try await fixture.imports.save(request)

    let summary = await fixture.imports.importPending { request in
      AgentImportReceipt(
        status: .failed,
        snipID: nil,
        listID: request.destinationListID,
        listName: "Inbox",
        request: request,
        error: "The original snip is unavailable."
      )
    }
    let pendingCount = await fixture.imports.pendingImportCount()

    XCTAssertEqual(summary, AgentImportSummary(imported: 0, failed: 1))
    XCTAssertEqual(pendingCount, 0)
  }

  func testMalformedPendingRequestIsQuarantinedInsteadOfRetried() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let request = AgentImportRequest(
      content: "Corrupt me",
      destinationListID: SnipList.inboxID
    )
    _ = try await fixture.imports.save(request)
    let pendingURL = fixture.directory
      .appendingPathComponent("Agent/Pending", isDirectory: true)
      .appendingPathComponent("\(request.requestID.uuidString).json")
    try Data("not json".utf8).write(to: pendingURL)
    let invalidRootURL = fixture.directory
      .appendingPathComponent("Agent/Invalid", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidRootURL, withIntermediateDirectories: true)
    let invalidURL = invalidRootURL
      .appendingPathComponent("\(request.requestID.uuidString).json")
    try Data("older invalid request".utf8).write(to: invalidURL)

    let first = await fixture.imports.importPending { _ in
      XCTFail("A malformed request must not reach the importer.")
      throw SnipLibraryError.invalidCommand
    }
    let second = await fixture.imports.importPending { _ in
      XCTFail("A quarantined request must not be retried.")
      throw SnipLibraryError.invalidCommand
    }
    let pendingCount = await fixture.imports.pendingImportCount()
    let quarantinedFiles = try FileManager.default.contentsOfDirectory(
      at: invalidRootURL,
      includingPropertiesForKeys: nil
    )

    XCTAssertEqual(first, AgentImportSummary(imported: 0, failed: 1))
    XCTAssertEqual(second, AgentImportSummary(imported: 0, failed: 0))
    XCTAssertEqual(pendingCount, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: invalidURL.path))
    XCTAssertEqual(quarantinedFiles.count, 2)
  }

  func testTemporarilyUnreadablePendingRequestRemainsQueued() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let request = AgentImportRequest(
      content: "Retry me",
      destinationListID: SnipList.inboxID
    )
    _ = try await fixture.imports.save(request)
    let pendingURL = fixture.directory
      .appendingPathComponent("Agent/Pending", isDirectory: true)
      .appendingPathComponent("\(request.requestID.uuidString).json")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: pendingURL.path)

    let summary = await fixture.imports.importPending { _ in
      XCTFail("An unreadable request must not reach the importer.")
      throw SnipLibraryError.invalidCommand
    }
    let invalidURL = fixture.directory
      .appendingPathComponent("Agent/Invalid", isDirectory: true)
      .appendingPathComponent("\(request.requestID.uuidString).json")
    let pendingCount = await fixture.imports.pendingImportCount()
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)

    XCTAssertEqual(summary, AgentImportSummary(imported: 0, failed: 1))
    XCTAssertEqual(pendingCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: invalidURL.path))
  }

  func testPublishedActiveListsReplaceTheStoreDerivedCatalog() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let syncedList = SnipList(
      id: UUID(), name: "Synced Research", systemImage: "cloud", position: 1
    )

    try await fixture.imports.publishAvailableLists([.inbox, syncedList])

    let availableLists = await fixture.imports.availableLists()
    XCTAssertEqual(availableLists, [.inbox, syncedList])
  }

  func testConcurrentImportNotificationRescansForNewRequests() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let firstID = UUID()
    let secondID = UUID()
    let gate = TestGate()
    let started = expectation(description: "first import started")
    _ = try await fixture.imports.save(AgentImportRequest(
      content: "First", destinationListID: SnipList.inboxID, requestID: firstID
    ))

    let importing = Task {
      await fixture.imports.importPending { request in
        if request.requestID == firstID {
          started.fulfill()
          await gate.wait()
        }
        return AgentImportReceipt(
          status: .added,
          snipID: UUID(),
          listID: SnipList.inboxID,
          listName: "Inbox",
          request: request
        )
      }
    }
    await fulfillment(of: [started])
    _ = try await fixture.imports.save(AgentImportRequest(
      content: "Second", destinationListID: SnipList.inboxID, requestID: secondID
    ))
    let overlapping = await fixture.imports.importPending { _ in
      XCTFail("The overlapping importer must only request a rescan.")
      throw SnipLibraryError.invalidCommand
    }
    XCTAssertEqual(overlapping, AgentImportSummary(imported: 0, failed: 0))
    await gate.open()

    let summary = await importing.value
    XCTAssertEqual(summary, AgentImportSummary(imported: 2, failed: 0))
    let pendingCount = await fixture.imports.pendingImportCount()
    XCTAssertEqual(pendingCount, 0)
  }

  private func makeFixture() throws -> (
    directory: URL,
    library: any SnipLibrary,
    imports: AgentImportStore
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnipSnapCLITests-\(UUID().uuidString)", isDirectory: true)
    let library = try SwiftDataSnipLibrary(storeURL: ShareImportStore.storeURL(in: directory))
    return (directory, library, AgentImportStore(rootURL: directory))
  }
}

private actor TestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
}
