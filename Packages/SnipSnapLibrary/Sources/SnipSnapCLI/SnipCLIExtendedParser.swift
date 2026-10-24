import Foundation
import SnipSnapCore

/// Keeps option values and arguments after `--` literal for every command group.
enum SnipCLIArgument: Equatable {
  case positional(String)
  case option(String, String?)
  case terminator

  var arguments: [String] {
    switch self {
    case .positional(let value): [value]
    case .option(let name, let value): [name] + (value.map { [$0] } ?? [])
    case .terminator: ["--"]
    }
  }

  static func tokenize(_ arguments: [String], valueOptions: Set<String>) -> [Self] {
    var tokens: [Self] = []
    var index = 0
    var parsesOptions = true
    while index < arguments.count {
      let argument = arguments[index]
      if parsesOptions && argument == "--" {
        tokens.append(.terminator)
        parsesOptions = false
      } else if parsesOptions && argument.hasPrefix("-"), argument != "-" {
        var value: String?
        if valueOptions.contains(argument), index + 1 < arguments.count {
          index += 1
          value = arguments[index]
        }
        tokens.append(.option(argument, value))
      } else {
        tokens.append(.positional(argument))
      }
      index += 1
    }
    return tokens
  }
}

enum SnipCLIExtendedParser {
  private static func tokens(_ arguments: [String]) -> [SnipCLIArgument] {
    // Find the namespace after leading globals, before choosing its option arities.
    let command = SnipCLIArgument.tokenize(arguments, valueOptions: ["--request-id"])
      .compactMap { token -> String? in
        if case .positional(let value) = token { return value }
        return nil
      }.first
    let valueOptions: Set<String>
    switch command {
    case "clipboard": valueOptions = SnipCLIClipboardParser.valueOptions
    case "backup", "recovery", "drafts": valueOptions = SnipCLIDataParser.valueOptions
    case "settings", "sync", "diagnostics", "app", "updates":
      valueOptions = SnipCLIApplicationParser.valueOptions
    case "attachments":
      valueOptions = SnipCLILibraryParser.valueOptions.union(SnipCLIApplicationParser.valueOptions)
    default:
      // Legacy add/update values supplement the library's shared option names.
      valueOptions = SnipCLILibraryParser.valueOptions.union(["--session-title", "--branch", "--if-updated-at"])
    }
    return SnipCLIArgument.tokenize(arguments, valueOptions: valueOptions.union(["--request-id"]))
  }

  static func requestsJSON(_ arguments: [String]) -> Bool {
    tokens(arguments).contains(.option("--json", nil))
  }

  static func parse(_ arguments: [String]) throws -> SnipSnapCLICommand? {
    var filtered: [String] = []
    var json = false
    var requestID: UUID?
    for token in tokens(arguments) {
      switch token {
      case .option("--help", nil), .option("-h", nil): return .help
      case .option("--json", nil): json = true
      case .option("--request-id", let raw):
        guard let raw else {
          throw SnipSnapCLIError.usage("--request-id requires a value.")
        }
        guard let value = UUID(uuidString: raw) else {
          throw SnipSnapCLIError.invalidRequestID(raw)
        }
        guard requestID == nil else {
          throw SnipSnapCLIError.usage("Pass --request-id only once.")
        }
        requestID = value
      default: filtered.append(contentsOf: token.arguments)
      }
    }
    let action = try SnipCLILibraryParser.parse(filtered)
      ?? SnipCLIClipboardParser.parse(filtered)
      ?? SnipCLIDataParser.parse(filtered)
      ?? SnipCLIApplicationParser.parse(filtered)
    if let action {
      return .request(SnipCLIOptions(input: .action(action), json: json, requestID: requestID))
    }
    // The legacy parser expects the command first. Normalize leading globals here.
    guard !filtered.isEmpty, filtered.first != arguments.first else { return nil }
    switch try SnipCLIParser.parse(filtered) {
    case .request(let options):
      return .request(.init(input: options.input, json: json, requestID: requestID))
    case .status(let id, _):
      guard requestID == nil else {
        throw SnipSnapCLIError.usage("--request-id does not apply to status.")
      }
      return .status(id: id, json: json)
    case .help: return .help
    }
  }
}
