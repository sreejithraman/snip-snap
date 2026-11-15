import Foundation
import SwiftData

/// App-owned evidence spanning the batches of one fresh-token fetch attempt.
/// Completion of CKSyncEngine's initial fetch alone does not prove that its last
/// batch contains the whole inventory. Any failed batch invalidates this proof.
package struct CloudFullFetchInventory: Codable, Equatable, Sendable {
  package let observed: Set<CloudTextStorageIdentity>
  package let canProveAbsence: Bool

  private init(observed: Set<CloudTextStorageIdentity>, canProveAbsence: Bool) {
    self.observed = observed
    self.canProveAbsence = canProveAbsence
  }

  package static let fresh = CloudFullFetchInventory(observed: [], canProveAbsence: true)

  /// An initial batch with no started attempt begins one. Only a tokenless start can prove absence.
  package static func started(tokenless: Bool) -> CloudFullFetchInventory {
    CloudFullFetchInventory(observed: [], canProveAbsence: tokenless)
  }

  /// Applies one initial batch in item order. A batch with an issue ends absence proof.
  package func observing(
    _ observations: [CloudFullFetchObservation],
    isClean: Bool
  ) -> CloudFullFetchInventory {
    var observed = self.observed
    for observation in observations {
      switch observation {
      case .present(let identity): observed.insert(identity)
      case .absent(let identity): observed.remove(identity)
      }
    }
    return CloudFullFetchInventory(observed: observed, canProveAbsence: canProveAbsence && isClean)
  }
}

/// One data-zone item of an initial fetch batch.
package enum CloudFullFetchObservation: Equatable, Sendable {
  case present(CloudTextStorageIdentity)
  case absent(CloudTextStorageIdentity)
}

extension SwiftDataSnipLibrary {
  static func startFullFetchInventory(namespaceKey: String, reset: Bool, context: ModelContext) throws {
    let row = try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredCloudFullEnrollment> { $0.namespaceKey == namespaceKey }
    )).first
    let prior = try fullEnrollmentState(from: row?.referencesData)
    guard reset || prior.namespaceState.initialFetchInventory == nil else { return }
    let data = try JSONEncoder().encode(CloudFullEnrollmentState(
      namespaceState: prior.namespaceState.startingInitialFetch(), references: prior.references
    ))
    if let row { row.referencesData = data }
    else { context.insert(StoredCloudFullEnrollment(namespaceKey: namespaceKey, referencesData: data)) }
  }
}
