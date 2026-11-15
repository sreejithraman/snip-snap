import Foundation

/// What a committed full-record fetch showed, in precedence order.
package enum CloudFullFetchOutcome: Equatable, Sendable {
  case destructiveReset
  case ownedZoneMissing
  case incomplete
  case complete(hasRecords: Bool)
}

/// What a committed full-record send showed, in precedence order.
package enum CloudFullSendOutcome: Equatable, Sendable {
  case destructiveReset
  case ownedZoneMissing
  case delivered(needsRetry: Bool, savedDataZone: Bool)
}

/// The full-record namespace's enrollment and, beside it, one fresh-token initial fetch
/// attempt. Each event advances `revision` by one, the step a commit requires.
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

  /// One fresh-token initial fetch attempt. Its lifetime overlaps enrollment, so it is a
  /// separate machine. With proof, the attempt can show that a record absent from it is gone.
  private enum InitialFetch: Equatable, Sendable {
    case absent
    case collectingWithProof(observed: Set<CloudTextStorageIdentity>)
    case collectingWithoutProof(observed: Set<CloudTextStorageIdentity>)

    /// A fresh token opens an attempt that has observed nothing and can prove absence.
    static let started = InitialFetch.collectingWithProof(observed: [])

    init(_ inventory: CloudFullFetchInventory?) {
      guard let inventory else {
        self = .absent
        return
      }
      self = inventory.canProveAbsence
        ? .collectingWithProof(observed: inventory.observed)
        : .collectingWithoutProof(observed: inventory.observed)
    }

    var inventory: CloudFullFetchInventory? {
      switch self {
      case .absent:
        nil
      case .collectingWithProof(let observed):
        CloudFullFetchInventory(observed: observed, canProveAbsence: true)
      case .collectingWithoutProof(let observed):
        CloudFullFetchInventory(observed: observed, canProveAbsence: false)
      }
    }

    func after(_ step: CloudFullInitialFetchStep) -> InitialFetch {
      switch step {
      case .unchanged:
        return self
      case .ended:
        return .absent
      case .observed(let observations, let isClean, let tokenless):
        return observing(observations, isClean: isClean, tokenless: tokenless)
      }
    }

    /// An initial batch with no open attempt opens one, which can prove absence only when
    /// tokenless. A batch with an issue ends the proof for the rest of the attempt.
    private func observing(
      _ observations: [CloudFullFetchObservation],
      isClean: Bool,
      tokenless: Bool
    ) -> InitialFetch {
      let current = inventory
      var observed = current?.observed ?? []
      for observation in observations {
        switch observation {
        case .present(let identity): observed.insert(identity)
        case .absent(let identity): observed.remove(identity)
        }
      }
      return (current?.canProveAbsence ?? tokenless) && isClean
        ? .collectingWithProof(observed: observed)
        : .collectingWithoutProof(observed: observed)
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
  private let initialFetch: InitialFetch

  private init(
    storageVersion: Int = 1,
    revision: UInt64,
    enrollment: Enrollment,
    initialFetch: InitialFetch
  ) {
    self.storageVersion = storageVersion
    self.revision = revision
    self.enrollment = enrollment
    self.initialFetch = initialFetch
  }

  package static let notEnrolled = CloudFullNamespaceState(
    revision: 0, enrollment: .notEnrolled, initialFetch: .absent
  )

  /// A references-only row from before namespace revisions. Any reference means it was active.
  static func legacy(hasReferences: Bool) -> CloudFullNamespaceState {
    CloudFullNamespaceState(
      revision: 0, enrollment: hasReferences ? .active : .notEnrolled, initialFetch: .absent
    )
  }

  package var phase: CloudNamespaceBootstrapPhase { enrollment.phase }
  package var zoneCreationPending: Bool { enrollment.zoneCreationPending }
  package var initialFetchInventory: CloudFullFetchInventory? { initialFetch.inventory }

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
    return advanced(to: next, initialFetch: initialFetch)
  }

  /// Opens a fresh-token initial fetch attempt. `nil` when one is already open.
  package func startingInitialFetch() -> CloudFullNamespaceState? {
    guard case .absent = initialFetch else { return nil }
    return advanced(to: enrollment, initialFetch: .started)
  }

  /// Replaces any open attempt with a fresh one.
  package func restartingInitialFetch() -> CloudFullNamespaceState {
    advanced(to: enrollment, initialFetch: .started)
  }

  /// The initial-fetch inventory a batch would leave, read before its commit is planned.
  package func inventory(after step: CloudFullInitialFetchStep) -> CloudFullFetchInventory? {
    initialFetch.after(step).inventory
  }

  package func committingFetch(
    _ outcome: CloudFullFetchOutcome,
    initialFetch step: CloudFullInitialFetchStep
  ) -> CloudFullNamespaceState {
    advanced(to: enrollment.afterFetch(outcome), initialFetch: initialFetch.after(step))
  }

  package func committingSend(_ outcome: CloudFullSendOutcome) -> CloudFullNamespaceState {
    advanced(to: enrollment.afterSend(outcome), initialFetch: initialFetch)
  }

  private func advanced(
    to enrollment: Enrollment,
    initialFetch: InitialFetch
  ) -> CloudFullNamespaceState {
    CloudFullNamespaceState(
      revision: revision + 1, enrollment: enrollment, initialFetch: initialFetch
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
      initialFetch: InitialFetch(stored.initialFetchInventory)
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
