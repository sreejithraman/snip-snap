import Foundation
import SnipSnapCore

/// Saved snips and lists share the running app's scoped request channel.
enum SnipCLILibraryParser {
  static let valueOptions: Set<String> = ["--list", "--completion", "--pinned", "--sort", "--limit",
    "--if-snip-revision", "--if-list-revision", "--before", "--mark-done", "--file", "--text",
    "--output", "--name", "--icon", "--color"]
  static var usage: String {
    """
      search [TEXT...] [--list NAME|UUID] [--completion all|done|not-done]
        [--pinned on|off] [--sort chronological|manual] [--limit N]
      snips list [same search options]
      snips done|not-done|pin|unpin ID... --if-snip-revision [ID:]REV (repeat per ID)
      snips move ID... --list LIST_UUID [--before SNIP_UUID|end]
        --if-snip-revision [ID:]REV... --if-list-revision REV
      snips merge ID... --if-snip-revision ID:REV... --yes
      snips copy ID... --if-snip-revision [ID:]REV... [--mark-done on|off]
      snips delete ID... --if-snip-revision [ID:]REV... --yes
      snips undo TOKEN
      snips add --file PATH [--file PATH...] [--text TEXT] [--list NAME|UUID]
      attachments add SNIP_ID PATH... --if-snip-revision REV
      attachments replace SNIP_ID ATTACHMENT_ID PATH --if-snip-revision REV
      attachments remove SNIP_ID ATTACHMENT_ID... --if-snip-revision REV --yes
      attachments export SNIP_ID ATTACHMENT_ID --output NEW_PATH
      attachments preview SNIP_ID ATTACHMENT_ID
      lists edit LIST_ID [--name NAME] [--icon SYMBOL] [--color PRESET|none]
        --if-list-revision REV
      lists move LIST_ID [--before LIST_ID|end] --if-list-revision [ID:]REV...
        (supply a revision for the moved list and its before anchor)
    """
  }

  static func parse(_ arguments: [String]) throws -> SnipCLIAction? {
    guard let group = arguments.first else { return nil }
    if group == "attachments", arguments.dropFirst().first == "cache" { return nil }
    guard ["search", "snips", "attachments"].contains(group)
      || (group == "lists" && arguments.count > 1 && ["edit", "move"].contains(arguments[1])) else { return nil }
    let subcommand = group == "search" ? "list" : arguments.dropFirst().first ?? "list"
    let offset = group == "search" ? 1 : min(2, arguments.count)
    var values: [String] = []
    var options: [String: [String]] = [:]
    var confirmed = false
    for token in SnipCLIArgument.tokenize(Array(arguments.dropFirst(offset)), valueOptions: valueOptions) {
      switch token {
      case .terminator: break
      case .option("--yes", nil):
        guard !confirmed else { throw invalid("Duplicate --yes.") }
        confirmed = true
      case .option(let name, let value) where valueOptions.contains(name):
        guard let value else { throw invalid("\(name) requires a value.") }
        if options[name] != nil && !["--file", "--if-snip-revision", "--if-list-revision"].contains(name) {
          throw invalid("Duplicate \(name).")
        }
        options[name, default: []].append(value)
      case .option(let name, _): throw invalid("Unknown option '\(name)'.")
      case .positional(let value): values.append(value)
      }
    }
    func only(_ allowed: Set<String>, confirmation: Bool = false) throws {
      guard Set(options.keys).isSubset(of: allowed), !confirmed || confirmation else {
        throw invalid("Options do not apply to this command.")
      }
    }
    func oneID() throws -> UUID {
      guard let first = values.first else { throw invalid("A UUID is required.") }
      return try uuid(first)
    }
    func refs(_ ids: [UUID]) throws -> [SnipCLISnipReference] {
      let revisions = try revisionMap(options["--if-snip-revision"] ?? [], ids: ids)
      guard Set(revisions.keys) == Set(ids), Set(ids).count == ids.count, !ids.isEmpty else {
        throw invalid("Supply a current --if-snip-revision for every snip, once each.")
      }
      return ids.map { .init(id: $0, revision: revisions[$0]!) }
    }
    func listRevision(_ id: UUID) throws -> String {
      let revisions = try revisionMap(options["--if-list-revision"] ?? [], ids: [id])
      guard revisions.count == 1, let revision = revisions[id] else { throw invalid("Supply --if-list-revision.") }
      return revision
    }
    func before() throws -> UUID? {
      guard let value = options["--before"]?.first, value != "end" else { return nil }
      return try uuid(value)
    }
    let action: SnipCLILibraryAction
    if group == "search" || (group == "snips" && subcommand == "list") {
      try only(["--list", "--completion", "--pinned", "--sort", "--limit"])
      let completion: SnipCLILibraryQuery.Completion
      switch options["--completion"]?.first ?? "all" {
      case "all": completion = .all
      case "done": completion = .done
      case "not-done": completion = .notDone
      default: throw invalid("Completion must be all, done, or not-done.")
      }
      let sortText = options["--sort"]?.first ?? "chronological"
      guard let sort = SnipSortMode(rawValue: sortText) else { throw invalid("Sort must be chronological or manual.") }
      let limit: Int?
      if let raw = options["--limit"]?.first {
        guard let parsed = Int(raw), parsed > 0 else { throw invalid("Limit must be a positive integer.") }
        limit = parsed
      } else { limit = nil }
      action = .query(.init(text: values.joined(separator: " "), list: options["--list"]?.first,
        completion: completion, pinned: try options["--pinned"]?.first.map(onOff), sort: sort, limit: limit))
    } else if group == "snips" {
      switch subcommand {
      case "done", "not-done", "pin", "unpin", "delete", "merge", "copy", "move":
        var allowed: Set<String> = ["--if-snip-revision"]
        if subcommand == "copy" { allowed.insert("--mark-done") }
        if subcommand == "move" { allowed.formUnion(["--list", "--before", "--if-list-revision"]) }
        try only(allowed, confirmation: ["delete", "merge"].contains(subcommand))
        let ids = try values.map(uuid)
        let references = try refs(ids)
        switch subcommand {
        case "done", "not-done": action = .setDone(snips: references, done: subcommand == "done")
        case "pin", "unpin": action = .setPinned(snips: references, pinned: subcommand == "pin")
        case "delete":
          guard confirmed else { throw invalid("Delete requires --yes.") }
          action = .delete(snips: references)
        case "merge":
          guard confirmed, ids.count >= 2 else { throw invalid("Merge requires two snips and --yes.") }
          action = .merge(snips: references)
        case "copy": action = .copy(snips: references, markDone: try onOff(options["--mark-done"]?.first ?? "on"))
        default:
          guard let selector = options["--list"]?.first else { throw invalid("Move requires --list UUID.") }
          let list = try uuid(selector)
          action = .move(snips: references, listID: list, before: try before(), listRevision: try listRevision(list))
        }
      case "undo":
        try only([])
        guard values.count == 1 else { throw invalid("Undo requires its deletion token.") }
        action = .undo(token: try oneID())
      case "add":
        try only(["--file", "--text", "--list"])
        guard values.isEmpty, let paths = options["--file"], !paths.isEmpty else { throw invalid("Use snips add --file PATH; text-only add remains 'add TEXT'.") }
        action = .addFiles(content: options["--text"]?.first ?? "", list: options["--list"]?.first,
          paths: try paths.map(filePath))
      default: throw invalid("Unknown snips command '\(subcommand)'.")
      }
    } else if group == "attachments" {
      let id = try oneID()
      switch subcommand {
      case "add", "replace", "remove":
        try only(["--if-snip-revision"], confirmation: subcommand == "remove")
        let reference = try refs([id])[0]
        if subcommand == "add" {
          guard values.count >= 2 else { throw invalid("Attachment add requires file paths.") }
          action = .editAttachments(snip: reference, add: try values.dropFirst().map(filePath), remove: [], replace: [:])
        } else if subcommand == "replace" {
          guard values.count == 3 else { throw invalid("Replace requires a snip, attachment, and file path.") }
          action = .editAttachments(snip: reference, add: [], remove: [], replace: [try uuid(values[1]).uuidString: try filePath(values[2])])
        } else {
          guard values.count >= 2, confirmed else { throw invalid("Remove requires attachment UUIDs and --yes.") }
          action = .editAttachments(snip: reference, add: [], remove: try values.dropFirst().map(uuid), replace: [:])
        }
      case "export", "preview":
        try only(subcommand == "export" ? ["--output"] : [])
        guard values.count == 2 else { throw invalid("Supply a snip UUID and attachment UUID.") }
        let attachment = try uuid(values[1])
        if subcommand == "export" {
          guard let output = options["--output"]?.first else { throw invalid("Export requires --output NEW_PATH.") }
          action = .exportAttachment(snipID: id, attachmentID: attachment, path: try filePath(output))
        } else { action = .previewAttachment(snipID: id, attachmentID: attachment) }
      default: throw invalid("Unknown attachments command '\(subcommand)'.")
      }
    } else {
      guard values.count == 1 else { throw invalid("Supply one list UUID.") }
      let id = try oneID()
      if subcommand == "edit" {
        try only(["--if-list-revision", "--name", "--icon", "--color"])
        guard options["--name"] != nil || options["--icon"] != nil || options["--color"] != nil else { throw invalid("Choose a list detail to edit.") }
        if let color = options["--color"]?.first, color != "none", SnipListColorPreset(rawValue: color) == nil { throw invalid("Unknown list color preset.") }
        for key in ["--name", "--icon"] {
          if let value = options[key]?.first, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw invalid("\(key) cannot be empty.") }
        }
        action = .editList(id: id, revision: try listRevision(id), name: options["--name"]?.first,
          icon: options["--icon"]?.first, color: options["--color"]?.first)
      } else {
        try only(["--if-list-revision", "--before"])
        let anchor = try before()
        let revisions = try revisionMap(options["--if-list-revision"] ?? [], ids: [id])
        guard Set(revisions.keys) == Set([id, anchor].compactMap { $0 }), anchor != id else {
          throw invalid("Supply a revision for the moved list and its before anchor.")
        }
        action = .moveList(id: id, before: anchor, revisions: Dictionary(uniqueKeysWithValues: revisions.map { ($0.key.uuidString, $0.value) }))
      }
    }
    return .extended(.library(action))
  }

  private static func uuid(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else { throw invalid("Expected UUID, got '\(value)'.") }
    return id
  }
  private static func onOff(_ value: String) throws -> Bool {
    guard ["on", "off"].contains(value) else { throw invalid("State must be on or off.") }
    return value == "on"
  }
  private static func filePath(_ value: String) throws -> String {
    guard !value.isEmpty else { throw invalid("File path cannot be empty.") }
    return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
  }
  private static func revisionMap(_ values: [String], ids: [UUID]) throws -> [UUID: String] {
    var result: [UUID: String] = [:]
    for value in values {
      let parts = value.split(separator: ":", omittingEmptySubsequences: false)
      let id: UUID
      let token: String
      if parts.count == 2 { id = try uuid(String(parts[0])); token = String(parts[1]) }
      else if parts.count == 1, ids.count == 1 { id = ids[0]; token = value }
      else { throw invalid("Use ID:REV for each revision when selecting multiple snips or lists.") }
      guard token.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), result[id] == nil else {
        throw invalid("Supply each current revision once, using the value from --json.")
      }
      result[id] = token
    }
    return result
  }
  private static func invalid(_ message: String) -> SnipSnapCLIError { .usage(message) }
}
