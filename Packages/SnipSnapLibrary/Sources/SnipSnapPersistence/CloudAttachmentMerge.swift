import Foundation

/// SM33-F2: merges attachment edits against the values iCloud last acknowledged.
///
/// A field this device left at its acknowledged value takes the remote value. A field it changed
/// keeps the local value, because this device sends next and reaches iCloud last.
enum CloudAttachmentMerge {
  static func field<Value: Equatable>(base: Value, local: Value, remote: Value) -> Value {
    local == base ? remote : local
  }

  /// Merges a row's fields. Without a readable base, the local record stays whole.
  static func metadata(
    base: CloudAttachmentMetadataValue?,
    local: CloudAttachmentMetadataValue,
    remote: CloudAttachmentMetadataValue
  ) -> CloudAttachmentMetadataValue {
    guard let base else { return local }
    return CloudAttachmentMetadataValue(
      attachmentID: remote.attachmentID,
      snipID: field(base: base.snipID, local: local.snipID, remote: remote.snipID),
      position: field(base: base.position, local: local.position, remote: remote.position),
      fileName: field(base: base.fileName, local: local.fileName, remote: remote.fileName),
      contentType: field(base: base.contentType, local: local.contentType, remote: remote.contentType),
      byteCount: remote.byteCount,
      sha256: remote.sha256,
      payloadIdentity: remote.payloadIdentity
    )
  }

  /// Merges a snip's attachment order as one field and returns every member in its final order.
  ///
  /// The shared members are those in `local` with both a base and a remote position. Adds and
  /// removals stay outside them, so they never count as a reorder. If only the remote side
  /// reordered them, the remote order wins; otherwise the local order does. A member the other
  /// side lacks keeps its index in its own side's sequence (SM33 D-F2-6).
  ///
  /// - Parameters:
  ///   - local: the snip's stored order before this commit inserted references.
  ///   - arrived: the members this commit inserted.
  ///   - base: acknowledged positions before this commit.
  ///   - remote: acknowledged positions after this commit.
  ///   - remoteMayWin: false keeps the local order, as when only part of this device's own
  ///     unacknowledged edit came back and the base can't be trusted.
  static func order(
    local: [UUID],
    arrived: [UUID],
    base: [UUID: Int],
    remote: [UUID: Int],
    remoteMayWin: Bool = true
  ) -> [UUID] {
    let shared = local.filter { base[$0] != nil && remote[$0] != nil }
    let sharedIDs = Set(shared)
    let baseOrder = sorted(shared, by: base)
    let remoteSequence = sorted((local + arrived).filter { remote[$0] != nil }, by: remote)
    let remoteOrder = remoteSequence.filter { sharedIDs.contains($0) }
    if remoteMayWin && remoteOrder != baseOrder && shared == baseOrder {
      return inserting(local.filter { remote[$0] == nil }, at: local, into: remoteSequence)
    }
    return inserting(arrived, at: remoteSequence, into: local)
  }

  private static func sorted(_ ids: [UUID], by positions: [UUID: Int]) -> [UUID] {
    ids.sorted { lhs, rhs in
      let lhsPosition = positions[lhs] ?? .max
      let rhsPosition = positions[rhs] ?? .max
      if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
      return lhs.uuidString < rhs.uuidString
    }
  }

  /// Inserts each member at its index in `source`, lowest index first, clamped to the end.
  private static func inserting(_ members: [UUID], at source: [UUID], into sequence: [UUID]) -> [UUID] {
    var result = sequence
    let placements = members.map { (index: source.firstIndex(of: $0) ?? .max, id: $0) }
      .sorted { $0.index < $1.index }
    for placement in placements {
      result.insert(placement.id, at: min(placement.index, result.count))
    }
    return result
  }
}

/// What another device's changes did to locally present attachments in one commit.
struct CloudAttachmentRemoteChanges {
  var adoptions: [UUID: CloudAttachmentAdoption] = [:]
  /// Snips that lost an attachment to another device's delete.
  var removedSnipIDs: Set<UUID> = []
  /// Snips whose every published pending move with a readable shadow came back as an own save.
  var ownSaveSnipIDs: Set<UUID> = []
  /// Snips where only some of those moves came back, as when a fetch fails for one record. The
  /// local order stands for this commit (SM33 D7).
  var partlyReturnedSnipIDs: Set<UUID> = []

  /// The base for an adopted row's place in its snip's order. An own save counts only when the
  /// snip's whole unacknowledged move came back: a record that matches one row by chance must
  /// not mix two devices' orders into one base (SM33 D7).
  func orderBase(
    of adoption: CloudAttachmentAdoption,
    onSnip snipID: UUID
  ) -> CloudAttachmentMetadataValue? {
    ownSaveSnipIDs.contains(snipID) ? adoption.fieldBase : adoption.base
  }
}

/// A fetched record applied to a locally present publication in one commit.
struct CloudAttachmentAdoption {
  /// What iCloud acknowledged before the commit, or nil when this device can't read it.
  let base: CloudAttachmentMetadataValue?
  /// The row's unacknowledged edit when the record equals it. iCloud then holds this device's
  /// own save, whose result never arrived (SM33 D7).
  let ownSave: CloudAttachmentMetadataValue?
  let record: CloudAttachmentMetadataValue

  /// The base for the row's fields.
  var fieldBase: CloudAttachmentMetadataValue? { ownSave ?? base }
}

extension StoredCloudAttachmentPublication {
  /// The values iCloud last acknowledged, or nil when this device can't read them. The library
  /// mirrors an accepted row, so its own values are the base. Only a pending row reads its shadow.
  func acknowledgedMetadata(
    _ acknowledgedValues: CloudAttachmentAcknowledgedValues
  ) -> CloudAttachmentMetadataValue? {
    let lifecycle = self.lifecycle
    if lifecycle.isMetadataAccepted { return metadata }
    return lifecycle.metadataShadowData.flatMap { try? acknowledgedValues.metadata(fromShadow: $0) }
  }
}
