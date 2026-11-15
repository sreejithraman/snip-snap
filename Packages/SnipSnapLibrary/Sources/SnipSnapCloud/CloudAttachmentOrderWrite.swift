import Foundation

/// SM33-F2A: a snip's attachment order reaches iCloud whole or not at all.
///
/// An order write is an attachment metadata save that moves an attachment from its acknowledged
/// position or publishes it for the first time. Every metadata save of that snip travels in one
/// atomic batch, so no device can acknowledge a mix of two devices' orders.
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
