import Darwin
import Foundation
import SnipSnapCore
import SnipSnapPersistence

struct SnipCLIOptions: Equatable {
  enum Input: Equatable {
    case action(SnipCLIAction)
    case updateSnip(id: UUID, expectedUpdatedAt: Date, textArguments: [String])
  }

  let input: Input
  let json: Bool
  let requestID: UUID?

  func action() throws -> SnipCLIAction {
    switch input {
    case .action(let action): return action
    case .updateSnip(let id, let expectedUpdatedAt, let textArguments):
      let content: String
      if textArguments.isEmpty || textArguments == ["-"] {
        guard isatty(STDIN_FILENO) == 0 else { throw SnipSnapCLIError.missingContent }
        guard let value = String(
          data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8
        ) else { throw SnipSnapCLIError.usage("Standard input is not valid UTF-8 text.") }
        content = value
      } else {
        content = textArguments.joined(separator: " ")
      }
      return .updateSnip(id: id, content: content, expectedUpdatedAt: expectedUpdatedAt)
    }
  }
}

enum SnipCLIParser {
  static func parse(_ arguments: [String]) throws -> SnipSnapCLICommand {
    let command = arguments[0]
    var positionals: [String] = []
    var listSelector: String?
    var json = false
    var confirmed = false
    var requestID: UUID?
    var expectedUpdatedAt: Date?
    var expectedSnipRevision: String?
    var expectedListRevision: String?
    var index = 1
    var parsesOptions = true
    while index < arguments.count {
      let argument = arguments[index]
      if parsesOptions && argument == "--" {
        parsesOptions = false
      } else if parsesOptions && (argument == "--help" || argument == "-h") {
        return .help
      } else if parsesOptions && argument == "--json" {
        json = true
      } else if parsesOptions && argument == "--yes" {
        confirmed = true
      } else if parsesOptions && (argument == "--list" || argument == "--request-id" || argument == "--if-updated-at" || argument == "--if-snip-revision" || argument == "--if-list-revision") {
        index += 1
        guard index < arguments.count else {
          throw SnipSnapCLIError.usage("\(argument) requires a value.")
        }
        if argument == "--list" {
          listSelector = arguments[index]
        } else if argument == "--request-id" {
          guard let id = UUID(uuidString: arguments[index]) else {
            throw SnipSnapCLIError.invalidRequestID(arguments[index])
          }
          requestID = id
        } else if argument == "--if-updated-at" {
          guard let seconds = Double(arguments[index]), seconds.isFinite else {
            throw SnipSnapCLIError.usage("--if-updated-at needs the updatedAt number from --json.")
          }
          expectedUpdatedAt = Date(timeIntervalSinceReferenceDate: seconds)
        } else {
          let token = arguments[index]
          guard token.count == 64, token.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
          }) else {
            throw SnipSnapCLIError.usage("\(argument) needs the revision from a current --json read.")
          }
          if argument == "--if-snip-revision" { expectedSnipRevision = token }
          else { expectedListRevision = token }
        }
      } else if parsesOptions && argument.hasPrefix("-") && argument != "-" {
        throw SnipSnapCLIError.usage("Unknown option '\(argument)'.")
      } else {
        positionals.append(argument)
      }
      index += 1
    }
    if listSelector != nil && command != "list" {
      throw SnipSnapCLIError.usage("--list applies only to 'list'.")
    }
    if expectedUpdatedAt != nil && command != "update" {
      throw SnipSnapCLIError.usage("--if-updated-at applies only to snip update.")
    }
    if expectedSnipRevision != nil && command != "delete" {
      throw SnipSnapCLIError.usage("--if-snip-revision applies only to snip delete.")
    }
    if expectedListRevision != nil && command != "lists" {
      throw SnipSnapCLIError.usage("--if-list-revision applies only to list rename and delete.")
    }
    let input: SnipCLIOptions.Input
    switch command {
    case "list":
      guard positionals.isEmpty, !confirmed else { throw invalid(command) }
      input = .action(.listSnips(list: listSelector))
    case "show":
      guard positionals.count == 1, let id = UUID(uuidString: positionals[0]), !confirmed else {
        throw invalid(command)
      }
      input = .action(.showSnip(id: id))
    case "update":
      guard let rawID = positionals.first, let id = UUID(uuidString: rawID),
        let expectedUpdatedAt, !confirmed else {
        throw invalid(command)
      }
      let textArguments = Array(positionals.dropFirst())
      guard !textArguments.contains("-") || textArguments == ["-"] else {
        throw SnipSnapCLIError.usage("Use '-' by itself to read text from standard input.")
      }
      input = .updateSnip(id: id, expectedUpdatedAt: expectedUpdatedAt,
                          textArguments: textArguments)
    case "delete":
      guard positionals.count == 1, let id = UUID(uuidString: positionals[0]),
        let expectedSnipRevision, confirmed else {
        throw SnipSnapCLIError.usage("Delete requires a snip UUID, --if-snip-revision, and --yes.")
      }
      input = .action(.deleteSnip(id: id, expectedRevision: expectedSnipRevision))
    case "lists":
      guard listSelector == nil else { throw invalid(command) }
      let subcommand = positionals.first ?? "list"
      if expectedListRevision != nil && subcommand != "rename" && subcommand != "delete" {
        throw SnipSnapCLIError.usage("--if-list-revision applies only to list rename and delete.")
      }
      let values = Array(positionals.dropFirst())
      switch subcommand {
      case "list":
        guard values.isEmpty, !confirmed else { throw invalid(command) }
        input = .action(.listLists)
      case "show":
        guard values.count == 1, !confirmed else { throw invalid(command) }
        input = .action(.showList(selector: values[0]))
      case "create":
        guard !values.isEmpty, !confirmed else { throw invalid(command) }
        input = .action(.createList(name: values.joined(separator: " ")))
      case "rename":
        guard values.count >= 2, let id = UUID(uuidString: values[0]),
          let expectedListRevision, !confirmed else {
          throw invalid(command)
        }
        input = .action(.updateList(id: id, name: values.dropFirst().joined(separator: " "),
                                    expectedRevision: expectedListRevision))
      case "delete":
        guard values.count == 1, let id = UUID(uuidString: values[0]),
          let expectedListRevision, confirmed else {
          throw SnipSnapCLIError.usage("List deletion requires a list UUID, --if-list-revision, and --yes.")
        }
        input = .action(.deleteList(id: id, expectedRevision: expectedListRevision))
      default: throw invalid(command)
      }
    case "status":
      guard positionals.count == 1, let id = UUID(uuidString: positionals[0]),
        requestID == nil, !confirmed else { throw invalid(command) }
      return .status(id: id, json: json)
    default:
      throw SnipSnapCLIError.usage("Unknown command '\(command)'.")
    }
    return .request(SnipCLIOptions(input: input, json: json, requestID: requestID))
  }

  private static func invalid(_ command: String) -> SnipSnapCLIError {
    .usage("Invalid arguments for '\(command)'. Run 'snipsnap --help'.")
  }
}

enum SnipCLIService {
  static func execute(
    _ request: SnipCLIRequest,
    store: SnipCLIRequestStore,
    timeout: Duration = .seconds(5)
  ) async throws -> SnipCLIReceipt {
    let activeScope = try await store.activeScopeToken()
    let request = request.scopeToken == nil ? request.scoped(to: activeScope) : request
    let initial = try await store.enqueue(request)
    if case .completed(let receipt) = initial {
      return try await completed(receipt, expectedScope: request.scopeToken, store: store)
    }
    if case .uncertain = initial { throw SnipSnapCLIError.outcomeUnknown(request.requestID) }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var nextNotification = clock.now
    while clock.now < deadline {
      guard try await store.activeScopeToken() == request.scopeToken else {
        throw SnipCLIRequestError.scopeChanged
      }
      if clock.now >= nextNotification {
        DistributedNotificationCenter.default().postNotificationName(
          SnipCLIRequestStore.pendingNotificationName,
          object: nil,
          userInfo: nil,
          deliverImmediately: true
        )
        nextNotification = clock.now.advanced(by: .milliseconds(250))
      }
      try await Task.sleep(for: .milliseconds(50))
      switch try await store.state(for: request.requestID) {
      case .completed(let receipt):
        return try await completed(receipt, expectedScope: request.scopeToken, store: store)
      case .uncertain: throw SnipSnapCLIError.outcomeUnknown(request.requestID)
      case .missing, .pending, .processing: break
      }
    }
    let final = try await store.cancelPending(request.requestID)
    if case .completed(let receipt) = final {
      return try await completed(receipt, expectedScope: request.scopeToken, store: store)
    }
    if case .uncertain = final { throw SnipSnapCLIError.outcomeUnknown(request.requestID) }
    if case .processing = final {
      throw SnipSnapCLIError.commandInProgress(request.requestID)
    }
    throw SnipSnapCLIError.appUnavailable
  }

  static func status(_ id: UUID, store: SnipCLIRequestStore) async throws -> SnipCLIRequestState {
    try await store.pruneAbandoned()
    let scope = try await store.activeScopeToken()
    let state = try await store.state(for: id)
    try await requireActiveScope(scope, store: store)
    if case .completed(let receipt) = state, receipt.scopeToken != scope {
      throw SnipCLIRequestError.scopeChanged
    }
    return state
  }

  static func requireActiveScope(
    _ expectedScope: String?, store: SnipCLIRequestStore
  ) async throws {
    guard try await store.activeScopeToken() == expectedScope else {
      throw SnipCLIRequestError.scopeChanged
    }
  }

  static func completed(
    _ receipt: SnipCLIReceipt,
    expectedScope: String?,
    store: SnipCLIRequestStore
  ) async throws -> SnipCLIReceipt {
    try await requireActiveScope(expectedScope, store: store)
    guard receipt.scopeToken == expectedScope else { throw SnipCLIRequestError.scopeChanged }
    guard receipt.status == .success else {
      throw SnipSnapCLIError.importFailed(receipt.message ?? "Snip Snap could not complete the command.")
    }
    return receipt
  }
}

enum SnipCLIPrinter {
  private struct JSONResult: Encodable {
    let requestID: UUID
    let status: SnipCLIReceipt.Status
    let snips: [Snip]
    let lists: [SnipList]
    let listRevision: String?
    let snipRevisions: [String: String]
    let updatedSnipID: UUID?
    let updatedAt: Date?
    let resultListID: UUID?
    let message: String?

    init(_ receipt: SnipCLIReceipt) {
      requestID = receipt.requestID
      status = receipt.status
      snips = receipt.snips
      lists = receipt.lists
      listRevision = receipt.listRevision
      snipRevisions = receipt.snipRevisions
      updatedSnipID = receipt.updatedSnipID
      updatedAt = receipt.updatedAt
      resultListID = receipt.resultListID
      message = receipt.message
    }
  }

  static func printReceipt(_ receipt: SnipCLIReceipt, json: Bool) throws {
    guard receipt.status == .success else {
      throw SnipSnapCLIError.importFailed(receipt.message ?? "Snip Snap could not complete the command.")
    }
    if json {
      FileHandle.standardOutput.write(try jsonData(for: receipt))
      FileHandle.standardOutput.write(Data("\n".utf8))
      return
    }
    switch receipt.action {
    case .listSnips:
      for snip in receipt.snips {
        let preview = snip.content.components(separatedBy: .newlines).first ?? ""
        let revision = receipt.snipRevisions[snip.id.uuidString] ?? ""
        print("\(snip.id.uuidString)\t\(snip.updatedAt.timeIntervalSinceReferenceDate)\t\(revision)\t\(preview)")
      }
    case .showSnip:
      guard let snip = receipt.snips.first else { return }
      print("ID: \(snip.id.uuidString)")
      print("Updated at: \(snip.updatedAt.timeIntervalSinceReferenceDate)")
      if let revision = receipt.snipRevisions[snip.id.uuidString] {
        print("Revision: \(revision)")
      }
      print("List: \(receipt.lists.first(where: { $0.id == snip.listID })?.name ?? "Unknown")")
      print("\n\(snip.content)")
    case .updateSnip:
      print(receipt.message ?? receipt.snips.first.map { "Updated snip \($0.id.uuidString)." }
            ?? "Updated snip.")
    case .deleteSnip, .deleteList:
      print(receipt.message ?? "Deleted.")
    case .listLists:
      for list in receipt.lists { print("\(list.id.uuidString)\t\(list.name)") }
    case .createList, .updateList:
      if receipt.lists.isEmpty, let message = receipt.message { print(message) }
      else { for list in receipt.lists { print("\(list.id.uuidString)\t\(list.name)") } }
    case .showList:
      for list in receipt.lists { print("\(list.id.uuidString)\t\(list.name)") }
      if let revision = receipt.listRevision { print("Revision: \(revision)") }
      for snip in receipt.snips {
        let preview = snip.content.components(separatedBy: .newlines).first ?? ""
        print("  \(snip.id.uuidString)\t\(snip.updatedAt.timeIntervalSinceReferenceDate)\t\(preview)")
      }
    }
  }

  static func jsonData(for receipt: SnipCLIReceipt) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.timeIntervalSinceReferenceDate)
    }
    return try encoder.encode(JSONResult(receipt))
  }

  static func printState(_ state: SnipCLIRequestState, requestID: UUID, json: Bool) throws {
    switch state {
    case .completed(let receipt): try printReceipt(receipt, json: json)
    case .pending, .processing:
      if json {
        let stateName = state == .pending ? "pending" : "processing"
        print("{\"requestID\":\"\(requestID.uuidString)\",\"state\":\"\(stateName)\"}")
      } else {
        print("Request is still processing.")
      }
    case .uncertain: throw SnipSnapCLIError.outcomeUnknown(requestID)
    case .missing: throw SnipSnapCLIError.requestNotFound
    }
  }
}
