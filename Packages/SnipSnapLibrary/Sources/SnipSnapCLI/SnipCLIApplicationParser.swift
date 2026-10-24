import Foundation
import SnipSnapCore

enum SnipCLIApplicationParser {
  static let valueOptions: Set<String> = ["--if-revision"]
  static let usage = """
    settings show
    settings set KEY VALUE --if-revision TOKEN
      KEY: appearance (system|light|dark), sort (chronological|manual),
      completion-filter (all|done|notDone), clipboard-only-pinned (on|off),
      clipboard-newest-first (on|off), beta-updates (on|off)
    settings shortcuts set ACTION chord KEY_CODE CARBON_MODIFIERS LABEL --if-revision TOKEN
    settings shortcuts set ACTION double-shift|command-double-shift left|right --if-revision TOKEN
    settings shortcuts reset ACTION --if-revision TOKEN
      ACTION: capture-selection|toggle-panel|toggle-clipboard|toggle-done|merge
    sync status|enable|disable|cancel-setup|retry
      enable, disable, cancel-setup require --if-revision TOKEN from sync status.
      disable accepts --use-current-cache to explicitly keep this device's copy.
    sync clipboard status|enable|disable|retry
      enable and disable require --if-revision TOKEN from sync clipboard status.
    sync account keep|remove --if-revision TOKEN [--yes]
      remove requires --yes; TOKEN comes from sync status.
    diagnostics status|export PATH|clear --if-revision TOKEN --yes
    attachments cache status|clear --if-revision TOKEN --yes
      clear tokens come from the corresponding status command.
    app status|show|hide|clipboard|close-search|select-list NAME_OR_UUID|search QUERY|settings
    app capture-selection|capture-screen
    updates check
    """

  static func parse(_ arguments: [String]) throws -> SnipCLIAction? {
    guard let command = arguments.first else { return nil }
    guard ["settings", "sync", "diagnostics", "app", "updates"].contains(command)
      || (command == "attachments" && arguments.dropFirst().first == "cache")
    else { return nil }
    let action: SnipCLIApplicationAction
    var tokens = SnipCLIArgument.tokenize(Array(arguments.dropFirst()), valueOptions: valueOptions)
      .filter { $0 != .terminator }
    var args: [String] { tokens.flatMap(\.arguments) }
    func invalid() -> SnipSnapCLIError { .usage(usage) }
    func option(_ name: String) throws -> String? {
      let matches = tokens.indices.filter {
        if case .option(let optionName, _) = tokens[$0], optionName == name { return true }
        return false
      }
      guard let index = matches.first else { return nil }
      guard matches.count == 1, case .option(_, let value?) = tokens[index] else { throw invalid() }
      tokens.remove(at: index)
      return value
    }
    func flag(_ name: String) throws -> Bool {
      let matches = tokens.indices.filter { tokens[$0] == .option(name, nil) }
      guard let index = matches.first else { return false }
      guard matches.count == 1 else { throw invalid() }
      tokens.remove(at: index)
      return true
    }
    func revision() throws -> String {
      guard let value = try option("--if-revision"), value.count == 64,
        value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw invalid() }
      return value
    }
    switch command {
    case "settings":
      if args == ["show"] { action = .settingsShow }
      else if args.first == "set" {
        let token = try revision()
        guard args.count == 3, let key = SnipCLIApplicationSetting(rawValue: args[1]),
              key.accepts(args[2]) else { throw invalid() }
        action = .setSetting(key: key, value: args[2], expectedRevision: token)
      } else if args.first == "shortcuts" {
        let token = try revision()
        guard args.count >= 3, let target = SnipCLIShortcutAction(rawValue: args[2]) else { throw invalid() }
        if args[1] == "reset", args.count == 3 {
          action = .resetShortcut(action: target, expectedRevision: token)
        } else if args[1] == "set" {
          let binding: SnipCLIShortcutBinding
          if args.count == 7, args[3] == "chord", let key = UInt32(args[4]), key <= 127,
             let modifiers = UInt32(args[5]), modifiers & ~UInt32(0x1B00) == 0,
             !args[6].isEmpty, args[6].count <= 32 {
            binding = .chord(keyCode: key, modifiers: modifiers, label: args[6])
          } else if args.count == 5, ["left", "right"].contains(args[4]),
                    [.captureSelection, .togglePanel, .toggleClipboard].contains(target) {
            switch args[3] {
            case "double-shift": binding = .doubleShift(right: args[4] == "right")
            case "command-double-shift": binding = .commandDoubleShift(right: args[4] == "right")
            default: throw invalid()
            }
          } else { throw invalid() }
          action = .setShortcut(action: target, binding: binding, expectedRevision: token)
        } else { throw invalid() }
      } else { throw invalid() }
    case "sync":
      if args == ["status"] { action = .syncStatus }
      else if args == ["retry"] { action = .retrySync }
      else if args == ["clipboard", "status"] { action = .clipboardSyncStatus }
      else if args == ["clipboard", "retry"] { action = .retryClipboardSync }
      else {
        let token = try revision()
        if args == ["enable"] { action = .setSync(enabled: true, useCurrentCache: false, expectedRevision: token) }
        else if args.first == "disable" {
          let current = try flag("--use-current-cache")
          guard args == ["disable"] else { throw invalid() }
          action = .setSync(enabled: false, useCurrentCache: current, expectedRevision: token)
        } else if args == ["cancel-setup"] { action = .cancelSyncSetup(expectedRevision: token) }
        else if args == ["clipboard", "enable"] || args == ["clipboard", "disable"] {
          action = .setClipboardSync(enabled: args[1] == "enable", expectedRevision: token)
        } else if args.first == "account" {
          let yes = try flag("--yes")
          guard args.count == 2, let choice = SnipCLIAccountChoice(rawValue: args[1]),
                choice != .remove || yes else { throw invalid() }
          action = .resolveAccount(choice: choice, expectedRevision: token, confirmed: yes)
        } else { throw invalid() }
      }
    case "diagnostics":
      if args == ["status"] { action = .diagnosticsStatus }
      else if args.count == 2, args[0] == "export", !args[1].isEmpty {
        action = .exportDiagnostics(path: URL(fileURLWithPath: args[1]).standardizedFileURL.path)
      } else {
        let token = try revision()
        guard try flag("--yes"), args == ["clear"] else { throw invalid() }
        action = .clearDiagnostics(expectedRevision: token, confirmed: true)
      }
    case "attachments":
      if args == ["cache", "status"] { action = .attachmentCacheStatus }
      else {
        let token = try revision()
        guard try flag("--yes"), args == ["cache", "clear"] else { throw invalid() }
        action = .clearAttachmentCache(expectedRevision: token, confirmed: true)
      }
    case "app":
      switch args {
      case ["status"]: action = .status
      case ["show"]: action = .show
      case ["hide"]: action = .hide
      case ["clipboard"]: action = .showClipboard
      case ["close-search"]: action = .closeSearch
      case ["settings"]: action = .openSettings
      case ["capture-selection"]: action = .captureSelection
      case ["capture-screen"]: action = .captureScreen
      default:
        guard args.count == 2 else { throw invalid() }
        if args[0] == "select-list", !args[1].isEmpty { action = .selectList(selector: args[1]) }
        else if args[0] == "search" { action = .search(query: args[1]) }
        else { throw invalid() }
      }
    case "updates":
      guard args == ["check"] else { throw invalid() }
      action = .checkForUpdates
    default: throw invalid()
    }
    guard tokens.allSatisfy({ if case .positional = $0 { return true }; return false }) else {
      throw invalid()
    }
    return .extended(.application(action))
  }
}
