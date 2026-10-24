import Foundation
import SnipSnapCore

enum SnipCLIClipboardParser {
    static let valueOptions: Set<String> = ["--search", "--sort", "--limit", "--list", "--if-revision"]
    static let usage = """
      clipboard status
      clipboard list [--search TEXT] [--pinned] [--sort newest|oldest] [--limit N]
      clipboard show ID
      clipboard copy|restore ID --if-revision REVISION
      clipboard save ID --list NAME_OR_ID --if-revision REVISION
      clipboard pin|unpin ID --if-revision REVISION
      clipboard delete ID --if-revision REVISION --yes
      clipboard pause|resume --if-revision HISTORY_REVISION
      clipboard clear --if-revision HISTORY_REVISION --yes
    """

    static func parse(_ arguments: [String]) throws -> SnipCLIAction? {
        guard arguments.first == "clipboard" else { return nil }
        // Clipboard sync is owned by the application's settings commands.
        guard arguments.dropFirst().first != "sync" else { return nil }
        guard arguments.count >= 2 else { throw usageError() }
        let command = arguments[1]
        let allowed: Set<String>
        switch command {
        case "status", "show": allowed = []
        case "list": allowed = ["--search", "--pinned", "--sort", "--limit"]
        case "save": allowed = ["--list", "--if-revision"]
        case "copy", "restore", "pin", "unpin", "pause", "resume": allowed = ["--if-revision"]
        case "delete", "clear": allowed = ["--if-revision", "--yes"]
        default: throw usageError()
        }
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
        for token in SnipCLIArgument.tokenize(Array(arguments.dropFirst(2)), valueOptions: valueOptions) {
            switch token {
            case .option(let argument, let value):
                guard allowed.contains(argument), values[argument] == nil,
                      !flags.contains(argument) else { throw usageError() }
                if valueOptions.contains(argument) {
                    guard let value else { throw usageError() }
                    values[argument] = value
                } else {
                    flags.insert(argument)
                }
            case .positional(let value): positionals.append(value)
            case .terminator: break
            }
        }
        let targeted = ["show", "copy", "restore", "save", "pin", "unpin", "delete"].contains(command)
        guard positionals.count == (targeted ? 1 : 0) else { throw usageError() }
        let id = targeted ? UUID(uuidString: positionals[0]) : nil
        if targeted, id == nil { throw usageError() }
        func revision() throws -> String {
            guard let value = values["--if-revision"], value.count == 64,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw usageError()
            }
            return value
        }
        let action: SnipCLIClipboardAction
        switch command {
        case "status": action = .status
        case "show": action = .show(id: id!)
        case "list":
            let sort = values["--sort"] ?? "newest"
            guard sort == "newest" || sort == "oldest" else { throw usageError() }
            var limit: Int?
            if let raw = values["--limit"] {
                guard let number = Int(raw), number > 0 else { throw usageError() }
                limit = number
            }
            action = .list(.init(search: values["--search"], onlyPinned: flags.contains("--pinned"),
                                 newestFirst: sort == "newest", limit: limit))
        case "copy", "restore": action = .restore(id: id!, expectedRevision: try revision())
        case "save":
            guard let list = values["--list"], !list.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw usageError()
            }
            action = .save(id: id!, list: list, expectedRevision: try revision())
        case "pin", "unpin":
            action = .setPinned(id: id!, pinned: command == "pin", expectedRevision: try revision())
        case "delete":
            guard flags.contains("--yes") else { throw usageError() }
            action = .delete(id: id!, expectedRevision: try revision())
        case "pause", "resume":
            action = .setPaused(paused: command == "pause", expectedRevision: try revision())
        case "clear":
            guard flags.contains("--yes") else { throw usageError() }
            action = .clear(expectedRevision: try revision())
        default: throw usageError()
        }
        return .extended(.clipboard(action))
    }

    private static func usageError() -> SnipSnapCLIError { .usage(usage) }
}
