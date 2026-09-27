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

  var description: String {
    switch self {
    case .usage(let message): message
    case .missingContent: "Pass snip text as an argument or on standard input."
    case .listNotFound(let value): "No list named or identified by '\(value)' exists."
    case .invalidRequestID(let value): "'\(value)' is not a valid request UUID."
    case .importFailed(let message): message
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
}

enum SnipSnapCLIParser {
  static let usage = """
    Usage:
      snipsnap add [--list NAME|UUID] [--session-title TITLE] [--branch NAME]
        [--request-id UUID] [--json] [TEXT...]

    Add a saved snip marked as Agent. When TEXT is omitted or is '-', read it
    from standard input. The UI shows the session title, or the current Git
    branch when no title is provided. Reuse the same request ID when retrying.
    """

  static func parse(_ arguments: [String]) throws -> SnipSnapCLICommand {
    guard let command = arguments.first else { return .help }
    if command == "help" || command == "--help" || command == "-h" { return .help }
    guard command == "add" else {
      throw SnipSnapCLIError.usage("Unknown command '\(command)'.")
    }

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
    imports: AgentImportStore
  ) async throws -> SnipSnapCLIResult {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SnipSnapCLIError.missingContent
    }
    switch try await imports.existingResult(for: options.requestID) {
    case .completed(let receipt):
      let completedRequest = AgentImportRequest(
        content: content,
        destinationListID: receipt.requestedListID,
        destinationSelector: options.list,
        agentContext: resolvedAgentContext(options),
        requestID: options.requestID
      )
      guard receipt.matches(completedRequest) else { throw AgentImportError.conflictingRequestID }
      return try result(receipt, status: .unchanged)
    case .pending(let pending):
      let retriedRequest = AgentImportRequest(
        content: content,
        destinationListID: pending.destinationListID,
        destinationSelector: options.list,
        agentContext: resolvedAgentContext(options),
        requestID: options.requestID
      )
      guard pending.hasSameIdentity(as: retriedRequest) else {
        throw AgentImportError.conflictingRequestID
      }
      let currentList = await imports.availableLists().first {
        $0.id == pending.destinationListID
      }
      return SnipSnapCLIResult(
        status: .pending,
        id: nil,
        listID: pending.destinationListID,
        listName: currentList?.name ?? pending.destinationSelector ?? SnipList.inbox.name,
        origin: SnipOrigin.agent.rawValue,
        requestID: options.requestID
      )
    case nil:
      break
    }
    let list = try resolveList(options.list, in: await imports.availableLists())
    let request = AgentImportRequest(
      content: content,
      destinationListID: list.id,
      destinationSelector: options.list,
      agentContext: resolvedAgentContext(options),
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
    timeout: Duration = .seconds(3)
  ) async throws -> SnipSnapCLIResult? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if let receipt = try await imports.receipt(for: requestID) {
        return try result(receipt)
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    return nil
  }

  private static func resolveList(_ selector: String?, in lists: [SnipList]) throws -> SnipList {
    guard let selector else {
      guard let inbox = lists.first(where: { $0.id == SnipList.inboxID }) else {
        throw SnipLibraryError.invalidStore
      }
      return inbox
    }
    if let id = UUID(uuidString: selector), let list = lists.first(where: { $0.id == id }) {
      return list
    }
    guard let list = lists.first(where: {
      $0.name.compare(selector, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }) else {
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
        var result = try await SnipSnapCLIService.add(
          options: options,
          content: content,
          imports: imports
        )
        if result.status == .pending {
          DistributedNotificationCenter.default().postNotificationName(
            AgentImportStore.pendingNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
          )
          result = try await SnipSnapCLIService.completedResult(
            requestID: options.requestID,
            imports: imports
          ) ?? result
        }
        try printResult(result, asJSON: options.emitsJSON)
      }
    } catch let error as SnipSnapCLIError {
      FileHandle.standardError.write(Data("snipsnap: \(error.description)\n".utf8))
      FileHandle.standardError.write(Data("\(SnipSnapCLIParser.usage)\n".utf8))
      exit(2)
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
      print("Queued agent snip for \(result.listName); Snip Snap will add it when the app opens.")
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
