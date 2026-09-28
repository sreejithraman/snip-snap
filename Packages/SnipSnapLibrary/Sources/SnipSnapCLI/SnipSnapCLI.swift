import Darwin
import Foundation
import SnipSnapCore
import SnipSnapPersistence

enum SnipSnapCLIError: Error, Equatable, CustomStringConvertible {
  case usage(String)
  case missingContent
  case invalidRequestID(String)
  case importFailed(String)
  case appUnavailable
  case commandInProgress(UUID)
  case outcomeUnknown(UUID)
  case requestNotFound
  case requestFailed(UUID, String)

  var description: String {
    switch self {
    case .usage(let message): message
    case .missingContent: "Pass snip text as an argument or on standard input."
    case .invalidRequestID(let value): "'\(value)' is not a valid request UUID."
    case .importFailed(let message): message
    case .appUnavailable:
      "Snip Snap did not process the request in time. Check that it is open, then retry. No command was queued."
    case .commandInProgress(let id):
      "The app is still processing request \(id). Check 'snipsnap status \(id)'."
    case .outcomeUnknown(let id):
      "The outcome of request \(id) is unknown. Inspect the snip or list before retrying."
    case .requestNotFound: "No request with that UUID exists."
    case .requestFailed(let id, let message):
      "Request \(id.uuidString): \(message) Check 'snipsnap status \(id.uuidString)' before retrying if the outcome is unclear."
    }
  }

  var isUsageError: Bool {
    switch self {
    case .usage, .missingContent, .invalidRequestID: true
    case .importFailed, .appUnavailable, .commandInProgress, .outcomeUnknown,
         .requestNotFound, .requestFailed: false
    }
  }
}

enum SnipSnapCLICommand: Equatable {
  case help
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
    omitted or '-'. Snip and list commands require the running app. Take SECONDS from
    list/show --json. Delete requires --yes.
    Take the snip delete TOKEN from show/list --json and the list TOKEN from
    'lists show UUID --json'. Every command except status accepts --request-id UUID
    before or after arguments. Use it when you may need to retry, and check
    an uncertain outcome with status.
    """

  static func parse(_ arguments: [String]) throws -> SnipSnapCLICommand {
    guard let command = arguments.first else { return .help }
    if command == "help" || command == "--help" || command == "-h" { return .help }
    return try SnipCLIParser.parse(arguments)
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
        let store = SnipCLIRequestStore(rootURL: importRoot())
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
        let store = SnipCLIRequestStore(rootURL: importRoot())
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

  private static func importRoot() -> URL {
    let storeURL = SwiftDataSnipLibrary.defaultStoreURL()
    return LocalSnipStorePaths(storeURL: storeURL).rootDirectory
  }


}

enum GitBranchDetector {
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
