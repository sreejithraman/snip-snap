import Foundation

/// What a committed legacy text fetch showed, in precedence order.
package enum CloudTextFetchOutcome: Equatable, Sendable {
  case destructiveReset
  case zoneMissing
  case incomplete
  /// `remoteSnipIDs` holds the snips the fetch returned text for.
  case complete(remoteSnipIDs: Set<UUID>, localSnipIDs: Set<UUID>)
}

/// What a committed legacy text send showed, in precedence order.
package enum CloudTextSendOutcome: Equatable, Sendable {
  case destructiveReset
  case zoneMissing
  /// `finishedSnipIDs` holds snips whose record is accepted or reached a final result.
  /// `unlinkedSnipIDs` holds live snips without a record.
  case delivered(zoneSaved: Bool, finishedSnipIDs: Set<UUID>, unlinkedSnipIDs: Set<UUID>)
}

/// The legacy text namespace's enrollment. `StoredCloudNamespaceState` keeps it in four
/// columns; only seeding has approvals in flight or pending zone creation.
package struct CloudNamespaceStateStorage: Equatable, Sendable {
  private enum Enrollment: Equatable, Sendable {
    case notEnrolled
    case remoteChecked(excluded: Set<UUID>)
    case remoteCheckedMissingZone(excluded: Set<UUID>)
    case seeding(approved: Set<UUID>, excluded: Set<UUID>, zoneCreationPending: Bool)
    case active(excluded: Set<UUID>)
    case blocked(approved: Set<UUID>, excluded: Set<UUID>)
  }

  private let enrollment: Enrollment

  private init(_ enrollment: Enrollment) {
    self.enrollment = enrollment
  }

  package static let notEnrolled = CloudNamespaceStateStorage(.notEnrolled)

  /// Reads the stored columns. Each phase keeps only the fields it holds; no event writes others.
  init(
    storedPhase phase: CloudNamespaceBootstrapPhase,
    approvedSnipIDs: Set<UUID>,
    excludedSnipIDs: Set<UUID>,
    zoneCreationPending: Bool
  ) {
    switch phase {
    case .notEnrolled:
      enrollment = .notEnrolled
    case .remoteChecked:
      enrollment = .remoteChecked(excluded: excludedSnipIDs)
    case .remoteCheckedMissingZone:
      enrollment = .remoteCheckedMissingZone(excluded: excludedSnipIDs)
    case .seeding:
      enrollment = .seeding(
        approved: approvedSnipIDs, excluded: excludedSnipIDs, zoneCreationPending: zoneCreationPending
      )
    case .active:
      enrollment = .active(excluded: excludedSnipIDs)
    case .blocked:
      enrollment = .blocked(approved: approvedSnipIDs, excluded: excludedSnipIDs)
    }
  }

  package var phase: CloudNamespaceBootstrapPhase {
    switch enrollment {
    case .notEnrolled: .notEnrolled
    case .remoteChecked: .remoteChecked
    case .remoteCheckedMissingZone: .remoteCheckedMissingZone
    case .seeding: .seeding
    case .active: .active
    case .blocked: .blocked
    }
  }

  package var approvedSnipIDs: Set<UUID> {
    switch enrollment {
    case .seeding(let approved, _, _), .blocked(let approved, _): approved
    case .notEnrolled, .remoteChecked, .remoteCheckedMissingZone, .active: []
    }
  }

  package var excludedSnipIDs: Set<UUID> {
    switch enrollment {
    case .remoteChecked(let excluded), .remoteCheckedMissingZone(let excluded),
      .seeding(_, let excluded, _), .active(let excluded), .blocked(_, let excluded):
      excluded
    case .notEnrolled:
      []
    }
  }

  package var zoneCreationPending: Bool {
    guard case .seeding(_, _, let pending) = enrollment else { return false }
    return pending
  }

  /// `nil` until a remote check has run.
  package func approvingSeed(
    _ snipIDs: Set<UUID>,
    localSnipIDs: Set<UUID>
  ) -> CloudNamespaceStateStorage? {
    let excluded = localSnipIDs.subtracting(snipIDs)
    switch enrollment {
    case .remoteChecked:
      if snipIDs.isEmpty { return CloudNamespaceStateStorage(.active(excluded: excluded)) }
      return CloudNamespaceStateStorage(
        .seeding(approved: snipIDs, excluded: excluded, zoneCreationPending: false)
      )
    case .remoteCheckedMissingZone:
      return CloudNamespaceStateStorage(
        .seeding(approved: snipIDs, excluded: excluded, zoneCreationPending: true)
      )
    case .notEnrolled, .seeding, .active, .blocked:
      return nil
    }
  }

  /// A mode merge during seeding replaces the approvals. `nil` outside seeding or when unchanged.
  package func replacingSeedApproval(with snipIDs: Set<UUID>) -> CloudNamespaceStateStorage? {
    guard case .seeding(let approved, let excluded, let pending) = enrollment,
      approved != snipIDs
    else { return nil }
    let remaining = excluded.subtracting(snipIDs)
    // As in seed pruning, an empty seed still waiting for its zone finishes on the zone save.
    if snipIDs.isEmpty && !pending { return CloudNamespaceStateStorage(.active(excluded: remaining)) }
    return CloudNamespaceStateStorage(
      .seeding(approved: snipIDs, excluded: remaining, zoneCreationPending: pending)
    )
  }

  /// A mode merge while active seeds the approved snips that have no record yet and stops
  /// excluding every approved snip. `nil` unless active.
  package func approvingActiveAdditions(
    _ snipIDs: Set<UUID>,
    unlinkedSnipIDs: Set<UUID>
  ) -> CloudNamespaceStateStorage? {
    guard case .active(let excluded) = enrollment else { return nil }
    let seeds = snipIDs.intersection(unlinkedSnipIDs)
    let remaining = excluded.union(unlinkedSnipIDs.subtracting(seeds)).subtracting(snipIDs)
    if seeds.isEmpty { return CloudNamespaceStateStorage(.active(excluded: remaining)) }
    return CloudNamespaceStateStorage(
      .seeding(approved: seeds, excluded: remaining, zoneCreationPending: false)
    )
  }

  /// Drops approvals of deleted snips. `nil` unless seeding lost an approved snip.
  package func pruningDeletedSeeds(
    liveSnipIDs: Set<UUID>,
    linkedSnipIDs: Set<UUID>
  ) -> CloudNamespaceStateStorage? {
    guard case .seeding(let approved, let excluded, let pending) = enrollment else { return nil }
    let remaining = approved.intersection(liveSnipIDs)
    guard remaining != approved else { return nil }
    guard remaining.isEmpty else {
      return CloudNamespaceStateStorage(
        .seeding(approved: remaining, excluded: excluded, zoneCreationPending: pending)
      )
    }
    let finished = excluded.union(liveSnipIDs.subtracting(linkedSnipIDs))
    if pending {
      return CloudNamespaceStateStorage(
        .seeding(approved: [], excluded: finished, zoneCreationPending: true)
      )
    }
    return CloudNamespaceStateStorage(.active(excluded: finished))
  }

  package func committingFetch(_ outcome: CloudTextFetchOutcome) -> CloudNamespaceStateStorage {
    switch (outcome, enrollment) {
    case (.destructiveReset, _):
      return asBlocked
    case (_, .blocked), (.incomplete, _), (.complete, .seeding), (.complete, .active):
      return self
    case (.zoneMissing, .active(let excluded)):
      return CloudNamespaceStateStorage(.blocked(approved: [], excluded: excluded))
    case (.zoneMissing, .seeding(let approved, let excluded, _)):
      return CloudNamespaceStateStorage(
        .seeding(approved: approved, excluded: excluded, zoneCreationPending: true)
      )
    case (.zoneMissing, _):
      return CloudNamespaceStateStorage(.remoteCheckedMissingZone(excluded: excludedSnipIDs))
    case (.complete(let remoteSnipIDs, let localSnipIDs), _):
      if remoteSnipIDs.isEmpty {
        return CloudNamespaceStateStorage(.remoteChecked(excluded: excludedSnipIDs))
      }
      return CloudNamespaceStateStorage(.active(excluded: localSnipIDs.subtracting(remoteSnipIDs)))
    }
  }

  package func committingSend(_ outcome: CloudTextSendOutcome) -> CloudNamespaceStateStorage {
    switch (outcome, enrollment) {
    case (.destructiveReset, _):
      return asBlocked
    case (.zoneMissing, .seeding(let approved, let excluded, _)):
      return CloudNamespaceStateStorage(
        .seeding(approved: approved, excluded: excluded, zoneCreationPending: true)
      )
    case (.zoneMissing, _):
      return asBlocked
    case (.delivered(let zoneSaved, let finishedSnipIDs, let unlinkedSnipIDs),
      .seeding(let approved, let excluded, let pending)):
      if pending && !zoneSaved { return self }
      if approved.isSubset(of: finishedSnipIDs) {
        return CloudNamespaceStateStorage(.active(excluded: excluded.union(unlinkedSnipIDs)))
      }
      return CloudNamespaceStateStorage(
        .seeding(approved: approved, excluded: excluded, zoneCreationPending: false)
      )
    case (.delivered, _):
      return self
    }
  }

  private var asBlocked: CloudNamespaceStateStorage {
    CloudNamespaceStateStorage(.blocked(approved: approvedSnipIDs, excluded: excludedSnipIDs))
  }
}
