import Foundation
import SnipSnapCore

package enum CloudLocalPrecondition: Codable, Equatable, Sendable {
  case none
  case requireMissing
  case exactSnip(CloudLocalSnipMutation)
  case exactList(CloudLocalListMutation)
}

package enum CloudFullLocalMutation: Codable, Equatable, Sendable {
  case none
  case upsertSnip(CloudLocalSnipMutation)
  case upsertList(SnipList)
  case removeSnip(UUID)
  case removeList(UUID)
  case recoverDeletedSnip(
    original: CloudLocalSnipMutation,
    recovered: CloudLocalSnipMutation,
    attachmentIDs: [UUID]
  )
  case removeListAndMoveSnips(
    list: CloudLocalListMutation,
    snips: [CloudLocalSnipMutation]
  )
}

package struct CloudDeferredLocalMutation: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let precondition: CloudLocalPrecondition
  package let mutation: CloudFullLocalMutation
  package let wasMaterializedBeforeDeferral: Bool
  package let hasUnresolvedLegacyAbsence: Bool
  package let graphRepair: CloudFullGraphRepair?

  private enum CodingKeys: String, CodingKey {
    case storageVersion, precondition, mutation, wasMaterializedBeforeDeferral, hasUnresolvedLegacyAbsence
    case graphRepair
  }

  package init(
    precondition: CloudLocalPrecondition,
    mutation: CloudFullLocalMutation,
    wasMaterializedBeforeDeferral: Bool? = nil,
    hasUnresolvedLegacyAbsence: Bool = false,
    graphRepair: CloudFullGraphRepair? = nil
  ) {
    storageVersion = 1
    self.precondition = precondition
    self.mutation = mutation
    self.wasMaterializedBeforeDeferral = wasMaterializedBeforeDeferral
      ?? Self.materialized(precondition, mutation: mutation)
    self.hasUnresolvedLegacyAbsence = hasUnresolvedLegacyAbsence
    self.graphRepair = graphRepair
  }

  package init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    storageVersion = try values.decode(Int.self, forKey: .storageVersion)
    guard storageVersion == 1 else { throw CloudFullStorageError.invalidBatchReplay }
    precondition = try values.decode(CloudLocalPrecondition.self, forKey: .precondition)
    mutation = try values.decode(CloudFullLocalMutation.self, forKey: .mutation)
    let materialized = try values.decodeIfPresent(
      Bool.self,
      forKey: .wasMaterializedBeforeDeferral
    )
    wasMaterializedBeforeDeferral = materialized ?? Self.materialized(precondition, mutation: mutation)
    // Older refetches conflated a deletion with a snip that was never downloaded.
    // Neither inserting nor deleting cloud content is safe without resolving that.
    hasUnresolvedLegacyAbsence = try values.decodeIfPresent(Bool.self, forKey: .hasUnresolvedLegacyAbsence)
      ?? (materialized == nil && precondition == .requireMissing && mutation == .none)
    graphRepair = try values.decodeIfPresent(CloudFullGraphRepair.self, forKey: .graphRepair)
  }

  package func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(storageVersion, forKey: .storageVersion)
    try values.encode(precondition, forKey: .precondition)
    try values.encode(mutation, forKey: .mutation)
    try values.encode(wasMaterializedBeforeDeferral, forKey: .wasMaterializedBeforeDeferral)
    if hasUnresolvedLegacyAbsence {
      try values.encode(true, forKey: .hasUnresolvedLegacyAbsence)
    }
    try values.encodeIfPresent(graphRepair, forKey: .graphRepair)
  }

  private static func materialized(
    _ precondition: CloudLocalPrecondition,
    mutation: CloudFullLocalMutation
  ) -> Bool {
    if case .exactSnip = precondition { return true }
    // Old successful-save ACKs and retained local deletions stored no mutation.
    // Preserve that absence rather than treating them as new remote content.
    if mutation == .none, precondition == .none { return true }
    return false
  }
}

/// A checked repair for an accepted cloud graph that cannot be materialized as-is.
package struct CloudFullGraphRepair: Codable, Equatable, Sendable {
  package let snipID: UUID
  package let missingListID: UUID
  package let replacementListID: UUID

  package init(snipID: UUID, missingListID: UUID, replacementListID: UUID) {
    self.snipID = snipID
    self.missingListID = missingListID
    self.replacementListID = replacementListID
  }
}
