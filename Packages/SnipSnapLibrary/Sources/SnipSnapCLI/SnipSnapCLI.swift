import Darwin
import Foundation
import SnipSnapCore
import SnipSnapPersistence

enum SnipSnapCLIError: Error, Equatable, CustomStringConvertible {
  case usage(String)
  case missingContent
  case listNotFound(String)
  case invalidRequestID(String)
  case importFailed(String)
  case appUnavailable
  case commandInProgress(UUID)
  case outcomeUnknown(UUID)
  case legacyAddNeedsVerification(UUID)
  case requestNotFound
  case requestFailed(UUID, String)

  var description: String {
    switch self {
    case .usage(let message): message
    case .missingContent: "Pass snip text as an argument or on standard input."
    case .listNotFound(let value): "No list named or identified by '\(value)' exists."
    case .invalidRequestID(let value): "'\(value)' is not a valid request UUID."
    case .importFailed(let message): message
    case .appUnavailable:
      "Snip Snap did not process the request in time. Check that it is open, then retry. No command was queued."
    case .commandInProgress(let id):
      "The app is still processing request \(id). Check 'snipsnap status \(id)'."
    case .outcomeUnknown(let id):
      "The outcome of request \(id) is unknown. Inspect the snip or list before retrying."
    case .legacyAddNeedsVerification(let id):
      "Request \(id) finished before Snip Snap tracked library ownership. Check the current library before adding it again."
    case .requestNotFound: "No request with that UUID exists."
    case .requestFailed(let id, let message):
      "Request \(id.uuidString): \(message) Check 'snipsnap status \(id.uuidString)' before retrying if the outcome is unclear."
    }
  }

  var isUsageError: Bool {
    switch self {
    case .usage, .missingContent, .invalidRequestID: true
    case .listNotFound, .importFailed, .appUnavailable, .commandInProgress, .outcomeUnknown,
         .legacyAddNeedsVerification,
         .requestNotFound, .requestFailed: false
    }
  }
}

struct SnipSnapAddOptions: Equatable {
  var textArguments: [String] = []
  var list: String?
  var sessionTitle: String?
  var branchName: String?
  var requestID = UUID()
  var storeURL: URL?
  var emitsJSON = false
  var readsStandardInput: Bool { textArguments.isEmpty || textArguments == ["-"] }
}

enum SnipSnapCLICommand: Equatable {
  case help
  case add(SnipSnapAddOptions)
  case request(SnipCLIOptions)
  case status(id: UUID, json: Bool)
}

enum SnipSnapCLIParser {
  static let usage = """
    Usage:
      snipsnap add [--list NAME|UUID] [--session-title TITLE] [--branch NAME]
        [--request-id UUID] [--json] [TEXT...]
      snipsnap list [--list NAME|UUID] [--json]
      snipsnap show UUID [--json]
      snipsnap update UUID --if-updated-at SECONDS [TEXT...] [--json]
      snipsnap delete UUID --if-snip-revision TOKEN --yes [--json]
      snipsnap lists [list|show NAME|UUID|create NAME]
      snipsnap lists rename UUID NAME --if-list-revision TOKEN
      snipsnap lists delete UUID --if-list-revision TOKEN --yes
      snipsnap status REQUEST_UUID [--json]

    Add marks a snip as Agent. Add and update read standard input when TEXT is
    omitted or '-'. Add works while the app is closed; other commands require
    the running app. Take SECONDS from list/show --json. Delete requires --yes.
    Take the snip delete TOKEN from show/list --json and the list TOKEN from
    'lists show UUID --json'. Every command except status accepts --request-id UUID
    before or after arguments. Use it when you may need to retry, and check
    an uncertain non-add outcome with status.
    """

  static func parse(_ arguments: [String]) throws -> SnipSnapCLICommand {
    guard let command = arguments.first else { return .help }
    if command == "help" || command == "--help" || command == "-h" { return .help }
    guard command == "add" else { return try SnipCLIParser.parse(arguments) }

    var options = SnipSnapAddOptions()
    var index = 1
    var parsesOptions = true
    while index < arguments.count {
      let argument = arguments[index]
      if parsesOptions && argument == "--" {
        parsesOptions = false
      } else if parsesOptions && (argument == "--help" || argument == "-h") {
        return .help
      } else if parsesOptions && argument == "--json" {
        options.emitsJSON = true
      } else if parsesOptions && argument == "--list" {
        index += 1
        guard index < arguments.count else {
          throw SnipSnapCLIError.usage("--list requires a name or UUID.")
        }
        options.list = arguments[index]
      } else if parsesOptions && argument == "--session-title" {
        index += 1
        guard index < arguments.count else {
          throw SnipSnapCLIError.usage("--session-title requires a title.")
        }
        options.sessionTitle = arguments[index]
      } else if parsesOptions && argument == "--branch" {
        index += 1
        guard index < arguments.count else {
          throw SnipSnapCLIError.usage("--branch requires a name.")
        }
        options.branchName = arguments[index]
      } else if parsesOptions && argument == "--request-id" {
        index += 1
        guard index < arguments.count else {
          throw SnipSnapCLIError.usage("--request-id requires a UUID.")
        }
        let value = arguments[index]
        guard let requestID = UUID(uuidString: value) else {
          throw SnipSnapCLIError.invalidRequestID(value)
        }
        options.requestID = requestID
      } else if parsesOptions && argument == "--store" {
        index += 1
        guard index < arguments.count else {
          throw SnipSnapCLIError.usage("--store requires a SwiftData store path.")
        }
        options.storeURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
      } else if parsesOptions && argument.hasPrefix("-") && argument != "-" {
        throw SnipSnapCLIError.usage("Unknown option '\(argument)'.")
      } else {
        options.textArguments.append(argument)
      }
      index += 1
    }

    if options.textArguments.contains("-") && options.textArguments != ["-"] {
      throw SnipSnapCLIError.usage("Use '-' by itself when reading text from standard input.")
    }
    return .add(options)
  }
}

struct SnipSnapCLIResult: Encodable, Equatable {
  enum Status: String, Encodable {
    case added
    case unchanged
    case pending
  }

  let status: Status
  let id: UUID?
  let listID: UUID
  let listName: String
  let origin: String
  let requestID: UUID
}

enum SnipSnapCLIService {
  static func add(
    options: SnipSnapAddOptions,
    content: String,
    imports: AgentImportStore,
    scopeToken: String? = nil
  ) async throws -> SnipSnapCLIResult {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SnipSnapCLIError.missingContent
    }
    switch try await imports.existingResult(for: options.requestID) {
    case .completed(let receipt):
      let recordedScope = receipt.approvedInboxScopeToken ?? receipt.requestScopeToken
      if let recordedScope, recordedScope != scopeToken {
        throw SnipCLIRequestError.scopeChanged
      }
      let completedRequest = AgentImportRequest(
        content: content,
        destinationListID: receipt.requestedListID,
        destinationSelector: options.list,
        agentContext: resolvedAgentContext(options),
        scopeToken: receipt.requestScopeToken,
        requestID: options.requestID
      )
      guard receipt.matches(completedRequest) else { throw AgentImportError.conflictingRequestID }
      if recordedScope == nil {
        throw SnipSnapCLIError.legacyAddNeedsVerification(options.requestID)
      }
      return try result(receipt, status: .unchanged)
    case .pending(let pending):
      if let executionScope = pending.executionScopeToken,
        executionScope != scopeToken { throw SnipCLIRequestError.scopeChanged }
      let retriedRequest = AgentImportRequest(
        content: content,
        destinationListID: pending.destinationListID,
        destinationSelector: options.list,
        agentContext: resolvedAgentContext(options),
        scopeToken: pending.scopeToken,
        requestID: options.requestID
      )
      guard pending.hasSameIdentity(as: retriedRequest) else {
        throw AgentImportError.conflictingRequestID
      }
      let available = if let scopeToken {
        try? await imports.availableLists(matchingScopeToken: scopeToken)
      } else {
        await imports.availableLists()
      }
      let currentList = available?.first {
        $0.id == pending.executionListID
      }
      return SnipSnapCLIResult(
        status: .pending,
        id: nil,
        listID: pending.executionListID,
        listName: currentList?.name ?? (pending.approvedInboxScopeToken == nil
          ? pending.destinationSelector ?? SnipList.inbox.name : SnipList.inbox.name),
        origin: SnipOrigin.agent.rawValue,
        requestID: options.requestID
      )
    case nil:
      break
    }
    let lists = if let scopeToken {
      try await imports.availableLists(matchingScopeToken: scopeToken)
    } else {
      await imports.availableLists()
    }
    let list = try resolveList(options.list, in: lists)
    let request = AgentImportRequest(
      content: content,
      destinationListID: list.id,
      destinationSelector: options.list,
      agentContext: resolvedAgentContext(options),
      scopeToken: scopeToken,
      requestID: options.requestID
    )
    switch try await imports.save(request) {
    case .pending:
      return result(status: .pending, id: nil, list: list, requestID: options.requestID)
    case .completed(let receipt):
      return try result(receipt, status: .unchanged)
    }
  }

  private static func resolvedAgentContext(_ options: SnipSnapAddOptions) -> SnipAgentContext? {
    let context = SnipAgentContext(
      sessionTitle: options.sessionTitle,
      branchName: options.branchName
    )
    return context.displayLabel == nil ? nil : context
  }

  static func completedResult(
    requestID: UUID,
    imports: AgentImportStore,
    requests: SnipCLIRequestStore,
    scopeToken: String?,
    timeout: Duration = .seconds(3)
  ) async throws -> SnipSnapCLIResult? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      guard try await requests.activeScopeToken() == scopeToken else {
        throw SnipCLIRequestError.scopeChanged
      }
      if let receipt = try await imports.receipt(for: requestID) {
        let receiptScope = receipt.approvedInboxScopeToken ?? receipt.requestScopeToken
        guard receiptScope == scopeToken else {
          if receiptScope == nil {
            throw SnipSnapCLIError.legacyAddNeedsVerification(requestID)
          }
          throw SnipCLIRequestError.scopeChanged
        }
        guard try await requests.activeScopeToken() == scopeToken else {
          throw SnipCLIRequestError.scopeChanged
        }
        return try result(receipt)
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    return nil
  }

  static func completedOrPendingResult(
    _ pending: SnipSnapCLIResult,
    imports: AgentImportStore,
    requests: SnipCLIRequestStore,
    scopeToken: String?,
    timeout: Duration = .seconds(3)
  ) async throws -> SnipSnapCLIResult {
    do {
      return try await completedResult(
        requestID: pending.requestID, imports: imports, requests: requests,
        scopeToken: scopeToken, timeout: timeout
      ) ?? pending
    } catch SnipCLIRequestError.scopeChanged {
      // The queued add remains durable, even when its library is no longer active.
      return pending
    }
  }

  private static func resolveList(_ selector: String?, in lists: [SnipList]) throws -> SnipList {
    guard let selector else {
      guard let inbox = lists.first(where: { $0.id == SnipList.inboxID }) else {
        throw SnipLibraryError.invalidStore
      }
      return inbox
    }
    guard let list = SnipListNameAllocator.matching(selector, in: lists) else {
      throw SnipSnapCLIError.listNotFound(selector)
    }
    return list
  }

  private static func result(
    status: SnipSnapCLIResult.Status,
    id: UUID?,
    list: SnipList,
    requestID: UUID
  ) -> SnipSnapCLIResult {
    return SnipSnapCLIResult(
      status: status,
      id: id,
      listID: list.id,
      listName: list.name,
      origin: SnipOrigin.agent.rawValue,
      requestID: requestID
    )
  }

  private static func result(
    _ receipt: AgentImportReceipt,
    status: SnipSnapCLIResult.Status? = nil
  ) throws -> SnipSnapCLIResult {
    if receipt.status == .failed {
      throw SnipSnapCLIError.importFailed(
        receipt.error ?? "Snip Snap could not complete the agent request."
      )
    }
    guard let snipID = receipt.snipID else {
      throw SnipSnapCLIError.importFailed("Snip Snap returned an invalid agent receipt.")
    }
    return SnipSnapCLIResult(
      status: status ?? (receipt.status == .added ? .added : .unchanged),
      id: snipID,
      listID: receipt.listID,
      listName: receipt.listName,
      origin: SnipOrigin.agent.rawValue,
      requestID: receipt.requestID
    )
  }
}

@main
struct SnipSnapCLI {
  static func main() async {
    do {
      let command = try SnipSnapCLIParser.parse(Array(CommandLine.arguments.dropFirst()))
      switch command {
      case .help:
        print(SnipSnapCLIParser.usage)
      case .request(let options):
        let request = SnipCLIRequest(
          action: try options.action(), requestID: options.requestID ?? UUID()
        )
        let store = SnipCLIRequestStore(rootURL: importRoot(storeURL: nil))
        do {
          let receipt = try await SnipCLIService.execute(request, store: store)
          try await SnipCLIService.requireActiveScope(receipt.scopeToken, store: store)
          try SnipCLIPrinter.printReceipt(receipt, json: options.json)
        } catch {
          if let cliError = error as? SnipSnapCLIError, case .importFailed = cliError {
            try? await store.releaseReceipt(request.requestID)
          }
          let message = (error as? SnipSnapCLIError)?.description ?? error.localizedDescription
          throw SnipSnapCLIError.requestFailed(request.requestID, message)
        }
        try? await store.releaseReceipt(request.requestID)
      case .status(let id, let json):
        let store = SnipCLIRequestStore(rootURL: importRoot(storeURL: nil))
        let state = try await SnipCLIService.status(id, store: store)
        do {
          if case .completed(let receipt) = state {
            try await SnipCLIService.requireActiveScope(receipt.scopeToken, store: store)
          }
          try SnipCLIPrinter.printState(state, requestID: id, json: json)
        } catch {
          if case .completed = state { try? await store.releaseReceipt(id) }
          throw error
        }
        if case .completed = state { try? await store.releaseReceipt(id) }
      case .add(let options):
        var options = options
        if SnipAgentContext(
          sessionTitle: options.sessionTitle,
          branchName: options.branchName
        ).displayLabel == nil {
          options.branchName = GitBranchDetector.currentBranchName(
            at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
          )
        }
        let content = try readContent(for: options)
        let imports = AgentImportStore(rootURL: importRoot(storeURL: options.storeURL))
        let requests = SnipCLIRequestStore(rootURL: importRoot(storeURL: options.storeURL))
        let scopeToken = try await requests.activeScopeToken()
        var result = try await SnipSnapCLIService.add(
          options: options,
          content: content,
          imports: imports,
          scopeToken: scopeToken
        )
        if result.status == .pending {
          DistributedNotificationCenter.default().postNotificationName(
            AgentImportStore.pendingNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
          )
          result = try await SnipSnapCLIService.completedOrPendingResult(
            result, imports: imports, requests: requests, scopeToken: scopeToken
          )
        }
        if result.status != .pending {
          try await SnipCLIService.requireActiveScope(scopeToken, store: requests)
        }
        try printResult(result, asJSON: options.emitsJSON)
      }
    } catch let error as SnipSnapCLIError {
      FileHandle.standardError.write(Data("snipsnap: \(error.description)\n".utf8))
      if error.isUsageError {
        FileHandle.standardError.write(Data("\(SnipSnapCLIParser.usage)\n".utf8))
      }
      exit(error.isUsageError ? 2 : 1)
    } catch {
      FileHandle.standardError.write(Data("snipsnap: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  private static func readContent(for options: SnipSnapAddOptions) throws -> String {
    guard options.readsStandardInput else { return options.textArguments.joined(separator: " ") }
    guard isatty(STDIN_FILENO) == 0 else { throw SnipSnapCLIError.missingContent }
    guard let content = String(
      data: FileHandle.standardInput.readDataToEndOfFile(),
      encoding: .utf8
    ) else {
      throw SnipSnapCLIError.usage("Standard input is not valid UTF-8 text.")
    }
    return content
  }

  private static func importRoot(storeURL explicitStoreURL: URL?) -> URL {
    let storeURL = explicitStoreURL ?? SwiftDataSnipLibrary.defaultStoreURL()
    return LocalSnipStorePaths(storeURL: storeURL).rootDirectory
  }

  private static func printResult(_ result: SnipSnapCLIResult, asJSON: Bool) throws {
    if asJSON {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      FileHandle.standardOutput.write(try encoder.encode(result))
      FileHandle.standardOutput.write(Data("\n".utf8))
      return
    }
    switch result.status {
    case .added:
      print("Added agent snip \(result.id!.uuidString) in \(result.listName).")
    case .unchanged:
      print("Kept agent snip \(result.id!.uuidString) in \(result.listName).")
    case .pending:
      print("Queued agent snip for \(result.listName). Open Snip Snap; it may need approval in Needs attention.")
    }
  }
}

private enum GitBranchDetector {
  static func currentBranchName(at directory: URL) -> String? {
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "branch", "--show-current"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }
    guard process.terminationStatus == 0,
      let value = String(
        data: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      )?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }
}
