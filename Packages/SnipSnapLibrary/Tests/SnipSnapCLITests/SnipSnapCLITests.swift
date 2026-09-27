@testable import SnipSnapCLI
import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest

final class SnipSnapCLITests: XCTestCase {
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

  func testAddTargetsAListByCaseInsensitiveName() async throws {
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
    options.list = "research"

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
    let requestID = UUID()
    var firstOptions = SnipSnapAddOptions()
    firstOptions.list = research.name
    firstOptions.requestID = requestID
    _ = try await SnipSnapCLIService.add(
      options: firstOptions, content: "Read this", imports: fixture.imports
    )

    let summary = await fixture.imports.importPending { request in
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
    try await fixture.imports.publishAvailableLists([.inbox])

    var retryOptions = SnipSnapAddOptions()
    retryOptions.list = research.name
    retryOptions.requestID = requestID
    let retry = try await SnipSnapCLIService.add(
      options: retryOptions, content: "Read this", imports: fixture.imports
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
