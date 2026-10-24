import Foundation

public struct SnipCLILibraryQuery: Codable, Equatable, Sendable {
  public enum Completion: String, Codable, Sendable { case all, done, notDone }
  public var text: String
  public var list: String?
  public var completion: Completion
  public var pinned: Bool?
  public var sort: SnipSortMode
  public var limit: Int?

  public init(text: String = "", list: String? = nil, completion: Completion = .all,
              pinned: Bool? = nil, sort: SnipSortMode = .chronological, limit: Int? = nil) {
    self.text = text; self.list = list; self.completion = completion
    self.pinned = pinned; self.sort = sort; self.limit = limit
  }

  public func snips(in snapshot: SnipLibrarySnapshot) throws -> [Snip] {
    if let limit, limit < 1 { throw SnipLibraryError.invalidCommand }
    let listID: UUID?
    if let list {
      guard let match = SnipListNameAllocator.matching(list, in: snapshot.lists) else {
        throw SnipLibraryError.invalidList
      }
      listID = match.id
    } else { listID = nil }
    let filter: SnipCompletionFilter = switch completion {
    case .all: .all
    case .done: .done
    case .notDone: .notDone
    }
    let selected = snapshot.snips.filter {
      (listID == nil || $0.listID == listID) && (pinned == nil || $0.isPinned == pinned)
    }
    let filtered = SnipFilter.apply(snips: selected, query: text, completionFilter: filter,
      listNames: Dictionary(uniqueKeysWithValues: snapshot.lists.map { ($0.id, $0.name) }))
    let sorted = Snip.sorted(filtered, by: sort)
    return limit.map { Array(sorted.prefix($0)) } ?? sorted
  }
}

/// A revision from a current read, bound to one snip identity.
public struct SnipCLISnipReference: Codable, Equatable, Sendable {
  public let id: UUID
  public let revision: String
  public init(id: UUID, revision: String) { self.id = id; self.revision = revision }

  public static func resolve(_ references: [Self], in snapshot: SnipLibrarySnapshot) throws -> [Snip] {
    guard !references.isEmpty, Set(references.map(\.id)).count == references.count else {
      throw SnipLibraryError.invalidCommand
    }
    return try references.map { reference in
      guard let snip = snapshot.snips.first(where: { $0.id == reference.id }) else {
        throw SnipLibraryError.snipNotFound
      }
      guard SnipCLIItemRevision.token(snip: snip) == reference.revision else {
        throw SnipLibraryError.snipChanged
      }
      return snip
    }
  }
}

public enum SnipCLILibraryAction: Codable, Equatable, Sendable {
  case query(SnipCLILibraryQuery)
  case setDone(snips: [SnipCLISnipReference], done: Bool)
  case setPinned(snips: [SnipCLISnipReference], pinned: Bool)
  case move(snips: [SnipCLISnipReference], listID: UUID, before: UUID?, listRevision: String)
  case merge(snips: [SnipCLISnipReference])
  case copy(snips: [SnipCLISnipReference], markDone: Bool)
  case delete(snips: [SnipCLISnipReference])
  case undo(token: UUID)
  case addFiles(content: String, list: String?, paths: [String])
  case editAttachments(snip: SnipCLISnipReference, add: [String], remove: [UUID], replace: [String: String])
  case exportAttachment(snipID: UUID, attachmentID: UUID, path: String)
  case previewAttachment(snipID: UUID, attachmentID: UUID)
  case editList(id: UUID, revision: String, name: String?, icon: String?, color: String?)
  case moveList(id: UUID, before: UUID?, revisions: [String: String])

  public var isReadOnly: Bool {
    if case .query = self { return true }
    return false
  }

  public var compacted: Self {
    switch self {
    case .query: .query(.init())
    case .addFiles: .addFiles(content: "", list: nil, paths: [])
    case .editAttachments(let snip, _, _, _): .editAttachments(snip: snip, add: [], remove: [], replace: [:])
    case .exportAttachment(let snip, let attachment, _): .exportAttachment(snipID: snip, attachmentID: attachment, path: "")
    case .editList(let id, let revision, _, _, _): .editList(id: id, revision: revision, name: nil, icon: nil, color: nil)
    default: self
    }
  }

  public var affectedSnipIDs: Set<UUID> {
    switch self {
    case .setDone(let snips, _), .setPinned(let snips, _), .move(let snips, _, _, _),
         .merge(let snips), .copy(let snips, _), .delete(let snips): Set(snips.map(\.id))
    case .editAttachments(let snip, _, _, _): [snip.id]
    default: []
    }
  }

  /// Plans an atomic write against the exact values reviewed by the caller.
  /// Delete, undo, copy, and file-add also need their app/session side effects.
  public func command(in snapshot: SnipLibrarySnapshot, now: Date = Date()) throws -> SnipLibraryCommand {
    switch self {
    case .setDone(let references, let done):
      return try guarded(references, in: snapshot, commands: [.setDone(ids: Set(references.map(\.id)), done: done)])
    case .setPinned(let references, let pinned):
      return try guarded(references, in: snapshot, commands: [.setPinned(ids: Set(references.map(\.id)), pinned: pinned)])
    case .copy(let references, let markDone):
      let snips = try SnipCLISnipReference.resolve(references, in: snapshot)
      let eligibleIDs = Set(snips.filter { !$0.isPinned && !$0.isDone }.map(\.id))
      return .guarded(expectation: .init(expectedSnips: snips), command: .batch(
        markDone && !eligibleIDs.isEmpty ? [.setDone(ids: eligibleIDs, done: true)] : []))
    case .merge(let references):
      guard references.count >= 2 else { throw SnipLibraryError.requiresMultipleSnips }
      return try guarded(references, in: snapshot, commands: [.merge(ids: Set(references.map(\.id)), now: now)])
    case .move(let references, let listID, let before, let revision):
      let snips = try SnipCLISnipReference.resolve(references, in: snapshot)
      let list = try checkedList(id: listID, revision: revision, in: snapshot)
      let members = snapshot.snips.filter { $0.listID == listID }
      if let before, !members.contains(where: { $0.id == before }) { throw SnipLibraryError.snipChanged }
      return .guarded(expectation: .init(expectedSnips: snips + members.filter { !references.map(\.id).contains($0.id) },
        expectedLists: [list], expectedListMemberships: [listID: Set(members.map(\.id))]),
        command: .batch([.place(ids: references.map(\.id), in: listID, before: before, basedOn: .manual)]))
    case .editAttachments(let reference, let added, let removed, let replacementPaths):
      let replacements = try uuidKeys(replacementPaths)
      let snip = try SnipCLISnipReference.resolve([reference], in: snapshot)[0]
      let originalIDs = Set(snip.attachments.map(\.id))
      guard Set(removed).count == removed.count, Set(removed).isSubset(of: originalIDs),
            Set(replacements.keys).isSubset(of: originalIDs),
            Set(removed).isDisjoint(with: replacements.keys) else { throw SnipLibraryError.invalidCommand }
      var edits: [SnipAttachmentEdit] = snip.attachments.compactMap { attachment in
        if removed.contains(attachment.id) { return nil }
        if let path = replacements[attachment.id] { return .replacement(attachmentID: attachment.id, sourceURL: URL(fileURLWithPath: path)) }
        return .existing(attachmentID: attachment.id)
      }
      edits += added.map { .added(sourceURL: URL(fileURLWithPath: $0)) }
      return .guarded(expectation: .init(expectedSnips: [snip]), command: .batch([
        .editAttachments(snipID: snip.id, content: snip.content, edits: edits, expectedUpdatedAt: snip.updatedAt, now: now)
      ]))
    case .editList(let id, let revision, let name, let icon, let color):
      let list = try checkedList(id: id, revision: revision, in: snapshot)
      let change: SnipListColorChange
      if let color {
        guard color == "none" || SnipListColorPreset(rawValue: color) != nil else { throw SnipLibraryError.invalidCommand }
        change = .set(SnipListColorPreset(rawValue: color))
      } else { change = .keep }
      return .guarded(expectation: .init(expectedLists: [list],
        expectedListMemberships: [id: Set(snapshot.snips.filter { $0.listID == id }.map(\.id))]),
        command: .batch([.updateList(id: id, name: name ?? list.name, systemImage: icon ?? list.systemImage, color: change)]))
    case .moveList(let id, let before, let revisionTokens):
      let revisions = try uuidKeys(revisionTokens)
      guard revisions[id] != nil else { throw SnipLibraryError.invalidCommand }
      if let before {
        guard before != id, revisions[before] != nil else { throw SnipLibraryError.invalidCommand }
      }
      let lists = try revisions.map { try checkedList(id: $0.key, revision: $0.value, in: snapshot) }
      return .guarded(expectation: .init(expectedLists: lists, expectedListMemberships:
        Dictionary(uniqueKeysWithValues: lists.map { list in
          (list.id, Set(snapshot.snips.filter { $0.listID == list.id }.map(\.id)))
        })), command: .batch([.moveList(id: id, before: before)]))
    default: throw SnipLibraryError.invalidCommand
    }
  }

  private func uuidKeys(_ values: [String: String]) throws -> [UUID: String] {
    var result: [UUID: String] = [:]
    for (key, value) in values {
      guard let id = UUID(uuidString: key), result[id] == nil else { throw SnipLibraryError.invalidCommand }
      result[id] = value
    }
    return result
  }

  private func guarded(_ references: [SnipCLISnipReference], in snapshot: SnipLibrarySnapshot,
                       commands: [SnipLibraryCommand]) throws -> SnipLibraryCommand {
    let snips = try SnipCLISnipReference.resolve(references, in: snapshot)
    return .guarded(expectation: .init(expectedSnips: snips), command: .batch(commands))
  }

  private func checkedList(id: UUID, revision: String, in snapshot: SnipLibrarySnapshot) throws -> SnipList {
    guard let list = snapshot.lists.first(where: { $0.id == id }) else { throw SnipLibraryError.invalidList }
    guard SnipCLIListRevision.token(list: list, memberIDs: snapshot.snips.filter { $0.listID == id }.map(\.id)) == revision else {
      throw SnipLibraryError.snipChanged
    }
    return list
  }
}

public struct SnipCLILibraryResult: Codable, Equatable, Sendable {
  public let undoToken: UUID?
  public let paths: [String]
  public init(undoToken: UUID? = nil, paths: [String] = []) { self.undoToken = undoToken; self.paths = paths }
}
