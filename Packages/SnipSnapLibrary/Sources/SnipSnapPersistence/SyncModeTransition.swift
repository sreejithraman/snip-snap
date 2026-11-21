import Foundation
import SnipSnapCore

/// The activation manifest is the commit point. A candidate can be discarded until
/// the same manifest write records the swap and selects it as active.
package struct SyncModeTransition: Codable, Equatable, Sendable {
  package let id: UUID
  package let sourceStoreID: UUID
  package let candidateStoreID: UUID
  package let targetKind: SyncModeStoreKind
  package let namespace: ICloudSyncNamespaceBinding?
  package let syncProtocol: SyncModeSyncProtocol
  private(set) package var phase: SyncModeTransitionPhase

  init(
    id: UUID,
    sourceStoreID: UUID,
    candidateStoreID: UUID,
    targetKind: SyncModeStoreKind,
    namespace: ICloudSyncNamespaceBinding?,
    syncProtocol: SyncModeSyncProtocol
  ) {
    self.id = id
    self.sourceStoreID = sourceStoreID
    self.candidateStoreID = candidateStoreID
    self.targetKind = targetKind
    self.namespace = namespace
    self.syncProtocol = syncProtocol
    phase = .declared
  }

  mutating func completeMerge() throws {
    guard phase == .declared else { throw SyncModePersistenceError.transitionInProgress }
    phase = .merged
  }

  mutating func swap() throws {
    guard phase == .merged else { throw SyncModePersistenceError.transitionInProgress }
    phase = .swapped
  }

  private enum CodingKeys: String, CodingKey {
    case id, sourceStoreID, candidateStoreID, targetKind, namespace, syncProtocol, phase
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    sourceStoreID = try values.decode(UUID.self, forKey: .sourceStoreID)
    candidateStoreID = try values.decode(UUID.self, forKey: .candidateStoreID)
    targetKind = try values.decode(SyncModeStoreKind.self, forKey: .targetKind)
    namespace = try values.decodeIfPresent(ICloudSyncNamespaceBinding.self, forKey: .namespace)
    syncProtocol = try values.decodeIfPresent(
      SyncModeSyncProtocol.self, forKey: .syncProtocol
    ) ?? .retiredText
    switch try values.decode(String.self, forKey: .phase) {
    case "merged": phase = .merged
    case "swapped", "pointerSwapped": phase = .swapped
    default: phase = .declared
    }
  }
}
