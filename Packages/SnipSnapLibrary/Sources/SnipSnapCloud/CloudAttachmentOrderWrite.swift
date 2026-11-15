import Foundation

/// SM33-F2A: a snip's attachment order reaches iCloud whole or not at all.
///
/// An order write is an attachment metadata save that moves an attachment from its acknowledged
/// position or publishes it for the first time. Every metadata save of that snip travels in one
/// atomic batch, so no device can acknowledge a mix of two devices' orders. Another device's
/// order reaches this device only through a fetch, which brings that order whole.
package enum CloudAttachmentOrderWrite {
  /// CloudKit's per-request limit, saves and deletes combined. A larger group can't be atomic.
  package static let requestRecordLimit = 250

  package static func changesOrder(_ draft: CloudRecordDraft) -> Bool {
    guard draft.recordType == CloudAttachmentRecordCodec.metadataRecordType else { return false }
    guard let base = draft.base else { return true }
    return draft.encryptedFields[positionField] != position(in: base)
  }

  /// Each snip with an order write, and every metadata save of that snip, in batch order.
  package static func groups(in operations: [CloudOutboundOperation]) -> [UUID: [CloudRecordID]] {
    var savesBySnip: [UUID: [CloudRecordID]] = [:]
    var reorderedSnipIDs: Set<UUID> = []
    for case .save(let draft) in operations
    where draft.recordType == CloudAttachmentRecordCodec.metadataRecordType {
      guard let snipID = snipID(of: draft) else { continue }
      savesBySnip[snipID, default: []].append(draft.id)
      if changesOrder(draft) { reorderedSnipIDs.insert(snipID) }
    }
    return savesBySnip.filter { reorderedSnipIDs.contains($0.key) }
  }

  /// A conflict carries another device's order when iCloud's position differs from the position
  /// the save was based on. A missing or unreadable base counts as a different position.
  package static func carriesOrder(
    conflict server: CloudRecordSnapshot,
    draft: CloudRecordDraft
  ) -> Bool {
    guard server.recordType == CloudAttachmentRecordCodec.metadataRecordType else { return false }
    guard let base = draft.base else { return true }
    return server.encryptedFields[positionField] != position(in: base)
  }

  /// Snips whose metadata saves wait for the next fetch after this send: an order-carrying
  /// conflict shows only part of the other device's order, and a companion that met another
  /// device's delete would only meet it again.
  /// - Parameter acknowledgedMetadataIDs: metadata records of present, acknowledged attachments
  ///   after the send committed. A save of one of those was a companion.
  package static func snipsAwaitingFetch(
    after sent: CloudSentBatch,
    outbound: CloudOutboundBatch,
    acknowledgedMetadataIDs: Set<CloudRecordID>
  ) -> Set<UUID> {
    var drafts: [CloudRecordID: CloudRecordDraft] = [:]
    for case .save(let draft) in outbound.operations
    where draft.recordType == CloudAttachmentRecordCodec.metadataRecordType {
      drafts[draft.id] = draft
    }
    var held: Set<UUID> = []
    for item in sent.items {
      guard let draft = drafts[item.id], let snipID = snipID(of: draft) else { continue }
      switch item {
      case .conflict(_, let server) where carriesOrder(conflict: server, draft: draft):
        held.insert(snipID)
      case .unknownItem(let id) where acknowledgedMetadataIDs.contains(id):
        held.insert(snipID)
      default:
        continue
      }
    }
    return held
  }

  private static let positionField = "position"

  private static func snipID(of draft: CloudRecordDraft) -> UUID? {
    guard case .string(let value)? = draft.encryptedFields["snipID"] else { return nil }
    return UUID(uuidString: value)
  }

  /// An unreadable base counts as a move, so the save stays inside its snip's atomic write.
  private static func position(in base: CloudRecordShadow) -> CloudFieldValue? {
    (try? CloudKitRecordMapper.snapshot(base.record()))?.encryptedFields[positionField]
  }
}
