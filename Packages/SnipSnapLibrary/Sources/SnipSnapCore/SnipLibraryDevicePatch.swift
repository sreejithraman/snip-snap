import Foundation

public struct SnipLibraryDevicePatch: Codable, Equatable, Sendable {
  package let snips: [SnipDeviceChange]
  package let lists: [SnipListDeviceChange]

  package init(snips: [SnipDeviceChange], lists: [SnipListDeviceChange]) {
    self.snips = snips
    self.lists = lists
  }

  package var isEmpty: Bool { snips.isEmpty && lists.isEmpty }

  package var reversed: Self {
    Self(
      snips: snips.map { SnipDeviceChange(before: $0.after, after: $0.before) },
      lists: lists.map { SnipListDeviceChange(before: $0.after, after: $0.before) }
    )
  }
}

public struct SnipDeviceChange: Codable, Equatable, Sendable {
  package let before: Snip?
  package let after: Snip?

  package init(before: Snip?, after: Snip?) {
    self.before = before
    self.after = after
  }
}

public struct SnipListDeviceChange: Codable, Equatable, Sendable {
  package let before: SnipList?
  package let after: SnipList?

  package init(before: SnipList?, after: SnipList?) {
    self.before = before
    self.after = after
  }
}

package extension SnipLibraryDevicePatch {
  static func between(
    _ before: SnipLibrarySnapshot,
    _ after: SnipLibrarySnapshot
  ) -> Self {
    let beforeSnips = Dictionary(uniqueKeysWithValues: before.snips.map { ($0.id, $0) })
    let afterSnips = Dictionary(uniqueKeysWithValues: after.snips.map { ($0.id, $0) })
    let snips = Set(beforeSnips.keys).union(afterSnips.keys).sorted(by: uuidOrder).compactMap {
      id -> SnipDeviceChange? in
      let change = SnipDeviceChange(before: beforeSnips[id], after: afterSnips[id])
      return change.before?.deviceFieldsEqual(change.after) == true ? nil : change
    }
    let beforeLists = Dictionary(uniqueKeysWithValues: before.lists.map { ($0.id, $0) })
    let afterLists = Dictionary(uniqueKeysWithValues: after.lists.map { ($0.id, $0) })
    let lists = Set(beforeLists.keys).union(afterLists.keys).sorted(by: uuidOrder).compactMap {
      id -> SnipListDeviceChange? in
      let change = SnipListDeviceChange(before: beforeLists[id], after: afterLists[id])
      return change.before?.deviceFieldsEqual(change.after) == true ? nil : change
    }
    return Self(snips: snips, lists: lists)
  }

  private static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString < rhs.uuidString
  }

  func canApply(to snapshot: SnipLibrarySnapshot) -> Bool {
    var state = SnipLibraryState(
      snips: snapshot.snips,
      lists: snapshot.lists,
      seenRequestIDs: []
    )
    do {
      _ = try state.perform(
        .applyDevicePatch(self, now: .distantFuture),
        prepareAttachments: { _, _ in throw SnipLibraryError.attachmentCopyFailed },
        pruneAttachments: { _, _ in }
      )
      return true
    } catch {
      return false
    }
  }
}

package extension Snip {
  func deviceFieldsEqual(_ other: Snip?) -> Bool {
    guard let other else { return false }
    return id == other.id
      && requestID == other.requestID
      && createdAt == other.createdAt
      && content == other.content
      && origin == other.origin
      && source == other.source
      && listID == other.listID
      && isDone == other.isDone
      && manualSortKey == other.manualSortKey
      && attachments == other.attachments
  }
}

package extension SnipList {
  func deviceFieldsEqual(_ other: SnipList?) -> Bool {
    guard let other else { return false }
    return id == other.id
      && desiredName == other.desiredName
      && systemImage == other.systemImage
      && sortKey == other.sortKey
  }
}
