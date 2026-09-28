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

    guard case .request(let options) = command else {
      return XCTFail("Add should use the running-app command path.")
    }
    XCTAssertEqual(options.requestID, requestID)
    XCTAssertTrue(options.json)
    XCTAssertEqual(try options.action(), .add(
      content: "Keep this", list: "Research",
      agentContext: SnipAgentContext(
        sessionTitle: "Agent provenance", branchName: "feature/agent-context"
      )
    ))
  }

  func testClosedAppAddDoesNotLeaveAQueuedSnip() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let requests = SnipCLIRequestStore(rootURL: directory)
    let request = SnipCLIRequest(action: .add(
      content: "Future idea", list: nil, agentContext: nil
    ))

    do {
      _ = try await SnipCLIService.execute(request, store: requests,
                                          timeout: .milliseconds(50))
      XCTFail("Add should require the running app.")
    } catch SnipSnapCLIError.appUnavailable {}

    let state = try await requests.state(for: request.requestID)
    XCTAssertEqual(state, .missing)
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

}
