import Foundation

/// What a committed full-record fetch showed, in precedence order.
package enum CloudFullFetchOutcome: Equatable, Sendable {
  case destructiveReset
  case ownedZoneMissing
  case complete(hasRecords: Bool)
  case incomplete
}

/// What a committed full-record send showed, in precedence order.
package enum CloudFullSendOutcome: Equatable, Sendable {
  case destructiveReset
  case ownedZoneMissing
  case delivered(needsRetry: Bool, savedDataZone: Bool)
}

/// The full-record namespace's enrollment, with the inventory of one fresh-token initial
/// fetch beside it. Each event advances `revision` by one, the step a commit requires.
package struct CloudFullNamespaceState: Codable, Equatable, Sendable {
  private enum Enrollment: Equatable, Sendable {
    case notEnrolled
    case remoteChecked(zoneCreationPending: Bool)
    case remoteCheckedMissingZone(zoneCreationPending: Bool)
    case seeding(zoneCreationPending: Bool)
    case active
    case blocked(zoneCreationPending: Bool)

    var phase: CloudNamespaceBootstrapPhase {
      switch self {
      case .notEnrolled: .notEnrolled
      case .remoteChecked: .remoteChecked
      case .remoteCheckedMissingZone: .remoteCheckedMissingZone
      case .seeding: .seeding
      case .active: .active
      case .blocked: .blocked
      }
    }

    var zoneCreationPending: Bool {
      switch self {
      case .remoteChecked(let pending), .remoteCheckedMissingZone(let pending),
        .seeding(let pending), .blocked(let pending):
        pending
      case .notEnrolled, .active:
        false
      }
    }

    func afterFetch(_ outcome: CloudFullFetchOutcome) -> Enrollment {
      switch (outcome, self) {
      case (.destructiveReset, _), (.ownedZoneMissing, .active):
        return .blocked(zoneCreationPending: false)
      case (.ownedZoneMissing, .notEnrolled):
        return .remoteCheckedMissingZone(zoneCreationPending: false)
      case (.ownedZoneMissing, .remoteChecked(let pending)),
        (.ownedZoneMissing, .remoteCheckedMissingZone(let pending)),
        (.ownedZoneMissing, .seeding(let pending)):
        return .remoteCheckedMissingZone(zoneCreationPending: pending)
      case (.complete(let hasRecords), .notEnrolled):
        return hasRecords ? .active : .remoteChecked(zoneCreationPending: false)
      case (.complete(let hasRecords), .remoteChecked(let pending)),
        (.complete(let hasRecords), .remoteCheckedMissingZone(let pending)):
        return hasRecords ? .active : .remoteChecked(zoneCreationPending: pending)
      case (.ownedZoneMissing, .blocked), (.complete, .seeding), (.complete, .active),
        (.complete, .blocked), (.incomplete, _):
        return self
      }
    }

    func afterSend(_ outcome: CloudFullSendOutcome) -> Enrollment {
      switch (outcome, self) {
      case (.destructiveReset, _):
        return .blocked(zoneCreationPending: false)
      case (.ownedZoneMissing, .seeding):
        return .seeding(zoneCreationPending: true)
      case (.ownedZoneMissing, _):
        return .blocked(zoneCreationPending: zoneCreationPending)
      case (.delivered(let needsRetry, let savedDataZone), .seeding(let pending)):
        if !needsRetry && (!pending || savedDataZone) { return .active }
        return .seeding(zoneCreationPending: pending && !savedDataZone)
      // A saved data zone ends pending zone creation in every phase.
      case (.delivered(_, let savedDataZone), .remoteChecked(let pending)):
        return .remoteChecked(zoneCreationPending: pending && !savedDataZone)
      case (.delivered(_, let savedDataZone), .remoteCheckedMissingZone(let pending)):
        return .remoteCheckedMissingZone(zoneCreationPending: pending && !savedDataZone)
      case (.delivered(_, let savedDataZone), .blocked(let pending)):
        return .blocked(zoneCreationPending: pending && !savedDataZone)
      case (.delivered, .notEnrolled), (.delivered, .active):
        return self
      }
    }
  }

  /// The JSON form, unchanged from the flat struct this type replaced.
  private struct StoredForm: Codable {
    let storageVersion: Int
    let revision: UInt64
    let phase: CloudNamespaceBootstrapPhase
    let zoneCreationPending: Bool
    let initialFetchInventory: CloudFullFetchInventory?
  }

  /// Kept as read so callers can refuse a version they don't know.
  package let storageVersion: Int
  package let revision: UInt64
  private let enrollment: Enrollment
  package let initialFetchInventory: CloudFullFetchInventory?

  private init(
    storageVersion: Int = 1,
    revision: UInt64,
    enrollment: Enrollment,
    initialFetchInventory: CloudFullFetchInventory?
  ) {
    self.storageVersion = storageVersion
    self.revision = revision
    self.enrollment = enrollment
    self.initialFetchInventory = initialFetchInventory
  }

  package static let notEnrolled = CloudFullNamespaceState(
    revision: 0, enrollment: .notEnrolled, initialFetchInventory: nil
  )

  /// A references-only row from before namespace revisions. Any reference means it was active.
  package static func legacy(hasReferences: Bool) -> CloudFullNamespaceState {
    CloudFullNamespaceState(
      revision: 0, enrollment: hasReferences ? .active : .notEnrolled, initialFetchInventory: nil
    )
  }

  package var phase: CloudNamespaceBootstrapPhase { enrollment.phase }
  package var zoneCreationPending: Bool { enrollment.zoneCreationPending }

  /// Approval seeds the namespace, and an active one stays active. Callers check for
  /// attention first, so this does not refuse a blocked namespace.
  package func approvingEnrollment() -> CloudFullNamespaceState {
    let next: Enrollment = switch enrollment {
    case .notEnrolled: .seeding(zoneCreationPending: false)
    case .remoteChecked(let pending), .seeding(let pending), .blocked(let pending):
      .seeding(zoneCreationPending: pending)
    case .remoteCheckedMissingZone: .seeding(zoneCreationPending: true)
    case .active: .active
    }
    return advanced(to: next, inventory: initialFetchInventory)
  }

  package func startingInitialFetch() -> CloudFullNamespaceState {
    advanced(to: enrollment, inventory: .fresh)
  }

  package func committingFetch(
    _ outcome: CloudFullFetchOutcome,
    inventory: CloudFullFetchInventory?
  ) -> CloudFullNamespaceState {
    advanced(to: enrollment.afterFetch(outcome), inventory: inventory)
  }

  package func committingSend(_ outcome: CloudFullSendOutcome) -> CloudFullNamespaceState {
    advanced(to: enrollment.afterSend(outcome), inventory: initialFetchInventory)
  }

  private func advanced(
    to enrollment: Enrollment,
    inventory: CloudFullFetchInventory?
  ) -> CloudFullNamespaceState {
    CloudFullNamespaceState(
      revision: revision + 1, enrollment: enrollment, initialFetchInventory: inventory
    )
  }

  package init(from decoder: any Decoder) throws {
    let stored = try StoredForm(from: decoder)
    let pending = stored.zoneCreationPending
    // No event leaves notEnrolled or active with pending zone creation; such rows heal here.
    let enrollment: Enrollment = switch stored.phase {
    case .notEnrolled: .notEnrolled
    case .remoteChecked: .remoteChecked(zoneCreationPending: pending)
    case .remoteCheckedMissingZone: .remoteCheckedMissingZone(zoneCreationPending: pending)
    case .seeding: .seeding(zoneCreationPending: pending)
    case .active: .active
    case .blocked: .blocked(zoneCreationPending: pending)
    }
    self.init(
      storageVersion: stored.storageVersion,
      revision: stored.revision,
      enrollment: enrollment,
      initialFetchInventory: stored.initialFetchInventory
    )
  }

  package func encode(to encoder: any Encoder) throws {
    try StoredForm(
      storageVersion: storageVersion,
      revision: revision,
      phase: phase,
      zoneCreationPending: zoneCreationPending,
      initialFetchInventory: initialFetchInventory
    ).encode(to: encoder)
  }
}
