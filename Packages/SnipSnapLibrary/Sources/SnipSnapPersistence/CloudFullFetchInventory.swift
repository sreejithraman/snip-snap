import Foundation
import SwiftData

/// App-owned evidence spanning the batches of one fresh-token fetch attempt.
/// Completion of CKSyncEngine's initial fetch alone does not prove that its last
/// batch contains the whole inventory. Any failed batch invalidates this proof.
/// `CloudFullNamespaceState` owns the attempt; this is its read and stored JSON form.
package struct CloudFullFetchInventory: Codable, Equatable, Sendable {
  package let observed: Set<CloudTextStorageIdentity>
  package let canProveAbsence: Bool
}

/// One data-zone item of an initial fetch batch.
package enum CloudFullFetchObservation: Equatable, Sendable {
  case present(CloudTextStorageIdentity)
  case absent(CloudTextStorageIdentity)
}

/// What one batch tells the initial-fetch attempt.
package enum CloudFullInitialFetchStep: Equatable, Sendable {
  /// A send leaves the attempt as it is.
  case unchanged
  /// A fetch that is not part of an initial fetch ends the attempt.
  case ended
  /// An initial batch observes data-zone items in order. `isClean` is false when the batch
  /// had an issue; `tokenless` says whether an attempt this batch opens can prove absence.
  case observed([CloudFullFetchObservation], isClean: Bool, tokenless: Bool)
}

extension SwiftDataSnipLibrary {
  /// `reset` replaces an open attempt; otherwise an open attempt is left unwritten.
  static func startFullFetchInventory(namespaceKey: String, reset: Bool, context: ModelContext) throws {
    let row = try context.fetch(FetchDescriptor(
      predicate: #Predicate<StoredCloudFullEnrollment> { $0.namespaceKey == namespaceKey }
    )).first
    let prior = try fullEnrollmentState(from: row?.referencesData)
    let next: CloudFullNamespaceState? = reset
      ? prior.namespaceState.restartingInitialFetch()
      : prior.namespaceState.startingInitialFetch()
    guard let next else { return }
    let data = try JSONEncoder().encode(CloudFullEnrollmentState(
      namespaceState: next, references: prior.references
    ))
    if let row { row.referencesData = data }
    else { context.insert(StoredCloudFullEnrollment(namespaceKey: namespaceKey, referencesData: data)) }
  }
}
