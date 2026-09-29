import Foundation
import SwiftData

/// App-owned evidence spanning the batches of one fresh-token fetch attempt.
/// Completion of CKSyncEngine's initial fetch alone does not prove that its last
/// batch contains the whole inventory. Any failed batch invalidates this proof.
package struct CloudFullFetchInventory: Codable, Equatable, Sendable {
  package let observed: Set<CloudTextStorageIdentity>
  package let canProveAbsence: Bool

  package init(observed: Set<CloudTextStorageIdentity> = [], canProveAbsence: Bool = true) {
    self.observed = observed
    self.canProveAbsence = canProveAbsence
  }
}

extension SwiftDataSnipLibrary {
  static func startFullFetchInventory(namespaceKey: String, reset: Bool, context: ModelContext) throws {
    let row = try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredCloudFullEnrollment> { $0.namespaceKey == namespaceKey }
    )).first
    let prior = try fullEnrollmentState(from: row?.referencesData)
    guard reset || prior.namespaceState.initialFetchInventory == nil else { return }
    let state = CloudFullNamespaceState(
      revision: prior.namespaceState.revision + 1,
      phase: prior.namespaceState.phase,
      zoneCreationPending: prior.namespaceState.zoneCreationPending,
      initialFetchInventory: CloudFullFetchInventory()
    )
    let data = try JSONEncoder().encode(CloudFullEnrollmentState(
      namespaceState: state, references: prior.references
    ))
    if let row { row.referencesData = data }
    else { context.insert(StoredCloudFullEnrollment(namespaceKey: namespaceKey, referencesData: data)) }
  }
}
