import Foundation
import SnipSnapCore

enum SnipCLIDataParser {
  static let valueOptions: Set<String> = ["--if-preview", "--choice", "--edited-json",
    "--if-recovery-revision", "--if-draft-revision", "--if-destination-revision", "--text", "--to", "--attach"]
  static let usage = """
    snipsnap backup export PATH
    snipsnap backup preview PATH
    snipsnap backup import --if-preview UUID --yes
    snipsnap backup cancel --if-preview UUID
    snipsnap recovery list|drafts
    snipsnap recovery resolve UUID --choice keep-current|use-recovered|keep-both|edit-snip|edit-list
      --if-recovery-revision TOKEN [--edited-json FILE]
    snipsnap recovery move-draft UUID --if-draft-revision TOKEN --if-destination-revision TOKEN
    snipsnap drafts list|show LIST
    snipsnap drafts save LIST --text TEXT [--attach PATH]... --if-draft-revision TOKEN
    snipsnap drafts clear LIST --if-draft-revision TOKEN --yes
    snipsnap drafts move LIST --to LIST --if-draft-revision TOKEN --if-destination-revision TOKEN
    snipsnap drafts save-as-snip LIST [--to LIST] --if-draft-revision TOKEN

    Take revision tokens and preview UUIDs from a fresh --json read. Draft save replaces
    text and attachments. Edited recovery JSON uses the Snip or SnipList object from
    recovery list --json. Paths resolve in the CLI working directory.
    """

  static func parse(_ arguments: [String]) throws -> SnipCLIAction? {
    guard let group = arguments.first, ["backup", "recovery", "drafts"].contains(group) else {
      return nil
    }
    guard arguments.count >= 2 else { throw invalid("Choose a \(group) command.") }
    let command = arguments[1]
    var positionals: [String] = []
    var options: [String: String] = [:]
    var attachments: [String] = []
    var confirmed = false
    for token in SnipCLIArgument.tokenize(Array(arguments.dropFirst(2)), valueOptions: valueOptions) {
      switch token {
      case .terminator: break
      case .option("--yes", nil):
        guard !confirmed else { throw invalid("Repeated --yes.") }
        confirmed = true
      case .option(let name, let value) where valueOptions.contains(name):
        guard let value else { throw invalid("\(name) needs a value.") }
        if name == "--attach" { attachments.append(try path(value)) }
        else {
          guard options[name] == nil else { throw invalid("Repeated \(name).") }
          options[name] = value
        }
      case .option(let name, _): throw invalid("Unknown option '\(name)'.")
      case .positional(let value): positionals.append(value)
      }
    }
    func require(_ keys: Set<String>, count: Int, yes: Bool = false,
                 allowAttachments: Bool = false) throws {
      guard positionals.count == count, Set(options.keys).isSubset(of: keys),
            confirmed == yes, allowAttachments || attachments.isEmpty else {
        throw invalid("Invalid arguments for \(group) \(command).")
      }
    }
    func required(_ key: String) throws -> String {
      guard let value = options[key], !value.isEmpty else { throw invalid("\(key) is required.") }
      return value
    }
    func revision(_ key: String) throws -> String {
      let value = try required(key)
      guard value.count == 64, value.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      }) else { throw invalid("\(key) needs a revision from a current --json read.") }
      return value
    }
    func uuid(_ value: String) throws -> UUID {
      guard let id = UUID(uuidString: value) else { throw invalid("Expected a UUID.") }
      return id
    }
    let action: SnipCLIDataAction
    switch (group, command) {
    case ("backup", "export"), ("backup", "preview"):
      try require([], count: 1)
      let value = try path(positionals[0])
      action = command == "export" ? .exportBackup(path: value) : .previewBackup(path: value)
    case ("backup", "import"):
      try require(["--if-preview"], count: 0, yes: true)
      action = .importBackup(previewID: try uuid(required("--if-preview")))
    case ("backup", "cancel"):
      try require(["--if-preview"], count: 0)
      action = .cancelBackup(previewID: try uuid(required("--if-preview")))
    case ("recovery", "list"):
      try require([], count: 0)
      action = .listRecovery
    case ("recovery", "drafts"):
      try require([], count: 0)
      action = .listRecoveredDrafts
    case ("recovery", "resolve"):
      try require(["--choice", "--edited-json", "--if-recovery-revision"], count: 1)
      guard let choice = SnipCLIRecoveryChoice(rawValue: try required("--choice")) else {
        throw invalid("Unknown recovery choice.")
      }
      var snip: Snip?
      var list: SnipList?
      if choice == .editSnip || choice == .editList {
        let file = try path(required("--edited-json"))
        do {
          let data = try Data(contentsOf: URL(fileURLWithPath: file))
          if choice == .editSnip { snip = try JSONDecoder().decode(Snip.self, from: data) }
          else { list = try JSONDecoder().decode(SnipList.self, from: data) }
        } catch { throw invalid("Cannot read edited recovery JSON: \(error.localizedDescription)") }
      } else if options["--edited-json"] != nil {
        throw invalid("--edited-json requires edit-snip or edit-list.")
      }
      action = .resolveRecovery(id: try uuid(positionals[0]), choice: choice,
        editedSnip: snip, editedList: list, expectedRevision: try revision("--if-recovery-revision"))
    case ("recovery", "move-draft"):
      try require(["--if-draft-revision", "--if-destination-revision"], count: 1)
      action = .moveRecoveredDraft(id: try uuid(positionals[0]),
        expectedRevision: try revision("--if-draft-revision"),
        expectedDestinationRevision: try revision("--if-destination-revision"))
    case ("drafts", "list"):
      try require([], count: 0)
      action = .listDrafts
    case ("drafts", "show"):
      try require([], count: 1)
      action = .showDraft(list: positionals[0])
    case ("drafts", "save"):
      try require(["--text", "--if-draft-revision"], count: 1, allowAttachments: true)
      guard let text = options["--text"] else { throw invalid("--text is required (it may be empty).") }
      guard !text.isEmpty || !attachments.isEmpty else {
        throw invalid("Use drafts clear with --if-draft-revision and --yes to empty a draft.")
      }
      action = .saveDraft(list: positionals[0], text: text, attachmentPaths: attachments,
        expectedRevision: try revision("--if-draft-revision"))
    case ("drafts", "clear"):
      try require(["--if-draft-revision"], count: 1, yes: true)
      action = .clearDraft(list: positionals[0], expectedRevision: try revision("--if-draft-revision"))
    case ("drafts", "move"):
      try require(["--to", "--if-draft-revision", "--if-destination-revision"], count: 1)
      action = .moveDraft(list: positionals[0], destination: try required("--to"),
        expectedRevision: try revision("--if-draft-revision"),
        expectedDestinationRevision: try revision("--if-destination-revision"))
    case ("drafts", "save-as-snip"):
      try require(["--to", "--if-draft-revision"], count: 1)
      action = .saveDraftAsSnip(list: positionals[0], destination: options["--to"],
        expectedRevision: try revision("--if-draft-revision"))
    default: throw invalid("Unknown \(group) command '\(command)'.")
    }
    return .extended(.data(action))
  }

  private static func path(_ raw: String) throws -> String {
    guard !raw.isEmpty, !raw.contains("\0") else { throw invalid("A nonempty path is required.") }
    return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
  }

  private static func invalid(_ message: String) -> SnipSnapCLIError { .usage(message) }
}
