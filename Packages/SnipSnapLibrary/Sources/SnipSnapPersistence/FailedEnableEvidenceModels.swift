import Foundation
import SnipSnapCore

package enum FailedEnablePresence: String, Codable, Equatable, Sendable { case missing, value }
package enum FailedEnableClassification: String, Codable, Equatable, Sendable { case nonconflicting, equalFetched, realConflict, deleteRecovery, legacyAmbiguous, unsupported }
package enum FailedEnableBaseKind: String, Codable, Equatable, Sendable { case sourceCapture, checkedTurnOff, noBaseEnrollment, equalFetched, unverified }
package enum FailedEnableMembership: String, Codable, Equatable, Sendable { case present, deletedBeforeCapture, remoteOnly, unknown }
package enum FailedEnableObservationKind: String, Codable, Equatable, Sendable { case fullRecord }
package enum FailedEnableTransferKind: String, Codable, Equatable, Sendable { case candidate, turnOff }
/// Checked destination output does not by itself authorize source/evidence retirement.
package enum FailedEnableTransferState: String, Codable, Equatable, Sendable { case prepared, checked }
package enum FailedEnableWriterKind: String, Codable, Equatable, Sendable { case source, manifest }
package enum FailedEnableContinuityState: String, Codable, Equatable, Sendable { case verified, uncertain }
package enum FailedEnablePurpose: String, Codable, Equatable, Sendable { case installedEvidence, localExport }

package struct FailedEnablePlacement: Codable, Equatable, Sendable {
  package var listID: String
  package var orderKey: Data
  package init(
    listID: String,
    orderKey: Data
  ) {
    self.listID = listID
    self.orderKey = orderKey
  }
}

package struct FailedEnableSnipValue: Codable, Equatable, Sendable {
  package var id: String
  package var requestID: String
  package var createdAt: String
  package var originRaw: String
  package var text: String
  package var source: FailedEnableNullable<FailedEnableSource>
  package var isDone: Bool
  package var pinnedAt: FailedEnableNullable<String>
  package var placement: FailedEnablePlacement
  package var updatedAt: String
  package init(
    id: String,
    requestID: String,
    createdAt: String,
    originRaw: String,
    text: String,
    source: FailedEnableNullable<FailedEnableSource>,
    isDone: Bool,
    pinnedAt: FailedEnableNullable<String>,
    placement: FailedEnablePlacement,
    updatedAt: String
  ) {
    self.id = id
    self.requestID = requestID
    self.createdAt = createdAt
    self.originRaw = originRaw
    self.text = text
    self.source = source
    self.isDone = isDone
    self.pinnedAt = pinnedAt
    self.placement = placement
    self.updatedAt = updatedAt
  }
}

package struct FailedEnableListValue: Codable, Equatable, Sendable {
  package var id: String
  package var desiredName: String
  package var systemImage: String
  package var colorPreset: FailedEnableNullable<String>
  package var orderKey: Data
  package var updatedAt: String
  package init(
    id: String,
    desiredName: String,
    systemImage: String,
    colorPreset: FailedEnableNullable<String>,
    orderKey: Data,
    updatedAt: String
  ) {
    self.id = id
    self.desiredName = desiredName
    self.systemImage = systemImage
    self.colorPreset = colorPreset
    self.orderKey = orderKey
    self.updatedAt = updatedAt
  }
}

package struct FailedEnableNormalizedLocal: Codable, Equatable, Sendable {
  package var immutableOverrides: FailedEnableNullable<FailedEnableImmutableOverrides>
  package var acceptedPresence: [String: FailedEnablePresence]
  package var defaults: [String]
  package init(
    immutableOverrides: FailedEnableNullable<FailedEnableImmutableOverrides>,
    acceptedPresence: [String: FailedEnablePresence],
    defaults: [String]
  ) {
    self.immutableOverrides = immutableOverrides
    self.acceptedPresence = acceptedPresence
    self.defaults = defaults
  }
}

package struct FailedEnableImmutableOverrides: Codable, Equatable, Sendable {
  package var requestID: String
  package var createdAt: String
  package var originRaw: String
  package init(
    requestID: String,
    createdAt: String,
    originRaw: String
  ) {
    self.requestID = requestID
    self.createdAt = createdAt
    self.originRaw = originRaw
  }
}

package struct FailedEnablePreparedValue: Codable, Equatable, Sendable {
  package var fields: FailedEnableFields
  package var presence: [String: FailedEnablePresence]
  package init(
    fields: FailedEnableFields,
    presence: [String: FailedEnablePresence]
  ) {
    self.fields = fields
    self.presence = presence
  }
  private enum Keys: String, CodingKey { case kind, fields, presence }
  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: Keys.self)
    switch try values.decode(String.self, forKey: .kind) {
    case "snip":
      fields = .snip(try values.decode(FailedEnableSnipValue.self, forKey: .fields))
      presence = try values.decode([String: FailedEnablePresence].self, forKey: .presence)
    case "list":
      fields = .list(try values.decode(FailedEnableListValue.self, forKey: .fields))
      presence = try values.decode([String: FailedEnablePresence].self, forKey: .presence)
    case "absent": fields = .absent; presence = [:]
    default: throw FailedEnableEvidenceError.unsupported
    }
  }
  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: Keys.self)
    switch fields {
    case .snip(let fields):
      try values.encode("snip", forKey: .kind)
      try values.encode(fields, forKey: .fields)
      try values.encode(presence, forKey: .presence)
    case .list(let fields):
      try values.encode("list", forKey: .kind)
      try values.encode(fields, forKey: .fields)
      try values.encode(presence, forKey: .presence)
    case .absent: try values.encode("absent", forKey: .kind)
    }
  }
}

package struct FailedEnablePreparation: Codable, Equatable, Sendable {
  package var normalizer: Int
  package var classification: FailedEnableClassification
  package var knownFields: [String]
  package var normalizedLocal: FailedEnableNormalizedLocal
  package var baseKind: FailedEnableBaseKind
  package var baseDigest: FailedEnableNullable<String>
  package var fetchedDigest: FailedEnableNullable<String>
  package var value: FailedEnableNullable<FailedEnablePreparedValue>
  package var conflictFields: [String]
  package var recoveryIdentities: [FailedEnableReference]
  package var reason: FailedEnableNullable<String>
  private enum CodingKeys: String, CodingKey {
    case normalizer, knownFields, normalizedLocal, baseKind, baseDigest, fetchedDigest
    case classification = "class"
    case value = "Q"
    case conflictFields, recoveryIdentities, reason
  }
  package init(
    normalizer: Int,
    classification: FailedEnableClassification,
    knownFields: [String],
    normalizedLocal: FailedEnableNormalizedLocal,
    baseKind: FailedEnableBaseKind,
    baseDigest: FailedEnableNullable<String>,
    fetchedDigest: FailedEnableNullable<String>,
    value: FailedEnableNullable<FailedEnablePreparedValue>,
    conflictFields: [String],
    recoveryIdentities: [FailedEnableReference],
    reason: FailedEnableNullable<String>
  ) {
    self.normalizer = normalizer
    self.classification = classification
    self.knownFields = knownFields
    self.normalizedLocal = normalizedLocal
    self.baseKind = baseKind
    self.baseDigest = baseDigest
    self.fetchedDigest = fetchedDigest
    self.value = value
    self.conflictFields = conflictFields
    self.recoveryIdentities = recoveryIdentities
    self.reason = reason
  }
}

package struct FailedEnableObservation: Codable, Equatable, Sendable {
  package var kind: FailedEnableObservationKind
  package var candidateStoreID: String
  package var namespaceRevision: String
  package var localRevision: String
  package var isDeferred: Bool
  package var hasUnresolvedLegacyAbsence: Bool
  package var dependencyListID: FailedEnableNullable<String>
  package var entityBase64: Data
  package init(
    kind: FailedEnableObservationKind,
    candidateStoreID: String,
    namespaceRevision: String,
    localRevision: String,
    isDeferred: Bool,
    hasUnresolvedLegacyAbsence: Bool,
    dependencyListID: FailedEnableNullable<String>,
    entityBase64: Data
  ) {
    self.kind = kind
    self.candidateStoreID = candidateStoreID
    self.namespaceRevision = namespaceRevision
    self.localRevision = localRevision
    self.isDeferred = isDeferred
    self.hasUnresolvedLegacyAbsence = hasUnresolvedLegacyAbsence
    self.dependencyListID = dependencyListID
    self.entityBase64 = entityBase64
  }
}

package struct FailedEnableRecord: Codable, Equatable, Sendable {
  package var reference: FailedEnableReference
  package var identity: FailedEnableIdentity
  package var sourceMembership: FailedEnableMembership
  package var source: FailedEnableNullable<FailedEnableImage>
  package var originalAcceptedExists: Bool
  package var offlineChanged: [String]
  package var preparation: FailedEnablePreparation
  package var observedAccepted: FailedEnableNullable<FailedEnableObservation>
  package var unqualifiedObservation: FailedEnableNullable<FailedEnableObservation>
  package init(
    reference: FailedEnableReference,
    identity: FailedEnableIdentity,
    sourceMembership: FailedEnableMembership,
    source: FailedEnableNullable<FailedEnableImage>,
    originalAcceptedExists: Bool,
    offlineChanged: [String],
    preparation: FailedEnablePreparation,
    observedAccepted: FailedEnableNullable<FailedEnableObservation>,
    unqualifiedObservation: FailedEnableNullable<FailedEnableObservation>
  ) {
    self.reference = reference
    self.identity = identity
    self.sourceMembership = sourceMembership
    self.source = source
    self.originalAcceptedExists = originalAcceptedExists
    self.offlineChanged = offlineChanged
    self.preparation = preparation
    self.observedAccepted = observedAccepted
    self.unqualifiedObservation = unqualifiedObservation
  }
}

package struct FailedEnableFreeze: Codable, Equatable, Sendable {
  package var id: String
  package var sourceRevision: String
  package init(
    id: String,
    sourceRevision: String
  ) {
    self.id = id
    self.sourceRevision = sourceRevision
  }
}

package struct FailedEnableCandidateDelete: Codable, Equatable, Sendable {
  package var reference: FailedEnableReference
  package var identity: FailedEnableIdentity
  package var acceptedRevisionDigest: String
  package var planDigest: String
  package init(
    reference: FailedEnableReference,
    identity: FailedEnableIdentity,
    acceptedRevisionDigest: String,
    planDigest: String
  ) {
    self.reference = reference
    self.identity = identity
    self.acceptedRevisionDigest = acceptedRevisionDigest
    self.planDigest = planDigest
  }
}

package struct FailedEnableCapture: Codable, Equatable, Sendable {
  package var id: String
  package var ordinal: String
  package var transitionID: String
  package var candidateStoreID: String
  package var syncProtocol: SyncModeSyncProtocol
  package var freeze: FailedEnableFreeze
  package var seenRequestIDs: [String]
  package var sourceDigest: String
  package var normalizer: Int
  package var preparationDigest: String
  package var predecessors: [String]
  package var armed: Bool
  package var records: [FailedEnableRecord]
  package var candidateDeletes: [FailedEnableCandidateDelete]
  package init(
    id: String,
    ordinal: String,
    transitionID: String,
    candidateStoreID: String,
    syncProtocol: SyncModeSyncProtocol,
    freeze: FailedEnableFreeze,
    seenRequestIDs: [String],
    sourceDigest: String,
    normalizer: Int,
    preparationDigest: String,
    predecessors: [String],
    armed: Bool,
    records: [FailedEnableRecord],
    candidateDeletes: [FailedEnableCandidateDelete]
  ) {
    self.id = id
    self.ordinal = ordinal
    self.transitionID = transitionID
    self.candidateStoreID = candidateStoreID
    self.syncProtocol = syncProtocol
    self.freeze = freeze
    self.seenRequestIDs = seenRequestIDs
    self.sourceDigest = sourceDigest
    self.normalizer = normalizer
    self.preparationDigest = preparationDigest
    self.predecessors = predecessors
    self.armed = armed
    self.records = records
    self.candidateDeletes = candidateDeletes
  }
}

package enum FailedEnableAlternativeReason: String, Codable, Equatable, Sendable {
  case legacySourceAtOpen, earlierLocalEdit, candidateRecovery, unsupportedHistoricalImage
}

package struct FailedEnableConflictDescriptor: Codable, Equatable, Sendable {
  package let key: String
  package let format: CloudConflictFormat
  package let payload: Data
  package let reviewAndRecoveredDescriptor: FailedEnableNullable<Data>
}

package struct FailedEnableAlternative: Codable, Equatable, Sendable {
  package let id: String
  package let reference: FailedEnableReference
  package let image: FailedEnableNullable<FailedEnableImage>
  package let reason: FailedEnableAlternativeReason
  package let conflict: FailedEnableNullable<FailedEnableConflictDescriptor>
  package let opaqueHistoricalBytes: FailedEnableNullable<Data>
  package let attachmentHashes: [String]
}

package enum FailedEnableReviewReason: String, Codable, Equatable, Sendable {
  case unverifiedHistory, unknownOutcome, rejectedValue, remoteDeletion, unavailableBytes
  case unsupportedRecord, interruptedWriter, evidenceUnavailable, earlierLocalVersion
}

package enum FailedEnableReviewChoice: String, Codable, Equatable, Sendable {
  case useDevice, useICloud, useEditedVersion, keepBoth, keepDeleted, recoverAsNew
  case keepOff, dismissExportedVersion, discardNamedVersion
}

package enum FailedEnableServerState: String, Codable, Equatable, Sendable {
  case value, deleted, unknown, unavailable
}

package struct FailedEnableServerExpectation: Codable, Equatable, Sendable {
  package let state: FailedEnableServerState
  package let observation: FailedEnableNullable<FailedEnableObservation>
  package let acceptedRevisionDigest: FailedEnableNullable<String>
}

package struct FailedEnableLocalExpectation: Codable, Equatable, Sendable {
  package let sourceStoreID: String
  package let sourceRevision: String
  package let sourceDigest: String
  package let membership: FailedEnableMembership
  package let image: FailedEnableNullable<FailedEnableImage>
}

package struct FailedEnableAttachmentCopyID: Codable, Equatable, Sendable {
  package let originalID: String
  package let newID: String
}

package struct FailedEnableCopyIDs: Codable, Equatable, Sendable {
  package let original: FailedEnableReference
  package let output: FailedEnableReference
  package let requestID: FailedEnableNullable<String>
  package let attachments: [FailedEnableAttachmentCopyID]
}

package struct FailedEnableReviewDecision: Codable, Equatable, Sendable {
  package let choice: FailedEnableReviewChoice
  package let fieldMask: [String]
  package let selectedImage: FailedEnableNullable<FailedEnableImage>
  package let outputIDs: [FailedEnableCopyIDs]
  package let resolvedAlternativeIDs: [String]
}

package struct FailedEnableReview: Codable, Equatable, Sendable {
  package let id: String
  package let reference: FailedEnableReference
  package let identity: FailedEnableNullable<FailedEnableIdentity>
  package let reason: FailedEnableReviewReason
  package let issueDigest: String
  package let local: FailedEnableLocalExpectation
  package let server: FailedEnableServerExpectation
  package let earlierAlternativeIDs: [String]
  package let decision: FailedEnableNullable<FailedEnableReviewDecision>
}

package struct FailedEnableTransfer: Codable, Equatable, Sendable {
  package var kind: FailedEnableTransferKind
  package var sourceCaptureIDs: [String]
  package var sourceStoreID: String
  package var destinationStoreID: String
  package var namespace: FailedEnableBinding
  package var planDigest: String
  package var dormantDigest: String
  package var outputs: [FailedEnableImage]
  package var conflicts: [Data]
  package var recoveryDescriptors: [Data]
  package var state: FailedEnableTransferState
  package init(
    kind: FailedEnableTransferKind,
    sourceCaptureIDs: [String],
    sourceStoreID: String,
    destinationStoreID: String,
    namespace: FailedEnableBinding,
    planDigest: String,
    dormantDigest: String,
    outputs: [FailedEnableImage],
    conflicts: [Data],
    recoveryDescriptors: [Data],
    state: FailedEnableTransferState
  ) {
    self.kind = kind
    self.sourceCaptureIDs = sourceCaptureIDs
    self.sourceStoreID = sourceStoreID
    self.destinationStoreID = destinationStoreID
    self.namespace = namespace
    self.planDigest = planDigest
    self.dormantDigest = dormantDigest
    self.outputs = outputs
    self.conflicts = conflicts
    self.recoveryDescriptors = recoveryDescriptors
    self.state = state
  }
}

package struct FailedEnableZone: Codable, Equatable, Hashable, Sendable {
  package var owner: String
  package var name: String
  package init(
    owner: String,
    name: String
  ) {
    self.owner = owner
    self.name = name
  }
}

package struct FailedEnableBinding: Codable, Equatable, Hashable, Sendable {
  package var scope: String
  package var accountLineage: String
  package var generation: String
  package var zones: [FailedEnableZone]
  package init(
    scope: String,
    accountLineage: String,
    generation: String,
    zones: [FailedEnableZone]
  ) {
    self.scope = scope
    self.accountLineage = accountLineage
    self.generation = generation
    self.zones = zones
  }
}

package struct FailedEnableNamespace: Codable, Equatable, Sendable {
  package var binding: FailedEnableBinding
  package var captures: [FailedEnableCapture]
  package var alternatives: [FailedEnableAlternative]
  package var reviews: [FailedEnableReview]
  package init(
    binding: FailedEnableBinding,
    captures: [FailedEnableCapture],
    alternatives: [FailedEnableAlternative],
    reviews: [FailedEnableReview]
  ) {
    self.binding = binding
    self.captures = captures
    self.alternatives = alternatives
    self.reviews = reviews
  }
}

package struct FailedEnableWriterTicket: Codable, Equatable, Sendable {
  package var kind: FailedEnableWriterKind
  package var ownerNonce: String
  package var previousActivationDigest: String
  package var previousSourceRevision: String
  package var previousSourceDigest: String
  package var reservedRevision: FailedEnableNullable<String>
  package var manifestPostimageDigest: FailedEnableNullable<String>
  package init(
    kind: FailedEnableWriterKind,
    ownerNonce: String,
    previousActivationDigest: String,
    previousSourceRevision: String,
    previousSourceDigest: String,
    reservedRevision: FailedEnableNullable<String>,
    manifestPostimageDigest: FailedEnableNullable<String>
  ) {
    self.kind = kind
    self.ownerNonce = ownerNonce
    self.previousActivationDigest = previousActivationDigest
    self.previousSourceRevision = previousSourceRevision
    self.previousSourceDigest = previousSourceDigest
    self.reservedRevision = reservedRevision
    self.manifestPostimageDigest = manifestPostimageDigest
  }
}

package struct FailedEnableContinuity: Codable, Equatable, Sendable {
  package var state: FailedEnableContinuityState
  package var activationDigest: String
  package var sourceRevision: String
  package var sourceDigest: String
  package var inFlight: FailedEnableNullable<FailedEnableWriterTicket>
  package init(
    state: FailedEnableContinuityState,
    activationDigest: String,
    sourceRevision: String,
    sourceDigest: String,
    inFlight: FailedEnableNullable<FailedEnableWriterTicket>
  ) {
    self.state = state
    self.activationDigest = activationDigest
    self.sourceRevision = sourceRevision
    self.sourceDigest = sourceDigest
    self.inFlight = inFlight
  }
}

package struct FailedEnableInstalledEvidence: Codable, Equatable, Sendable {
  package var version: Int
  package var purpose: FailedEnablePurpose
  package var sourceStoreID: String
  package var sequence: String
  package var continuity: FailedEnableContinuity
  package var namespaces: [FailedEnableNamespace]
  package var transfers: [FailedEnableTransfer]
  package var blobs: [String: Data]
  package init(
    version: Int,
    purpose: FailedEnablePurpose,
    sourceStoreID: String,
    sequence: String,
    continuity: FailedEnableContinuity,
    namespaces: [FailedEnableNamespace],
    transfers: [FailedEnableTransfer],
    blobs: [String: Data]
  ) {
    self.version = version
    self.purpose = purpose
    self.sourceStoreID = sourceStoreID
    self.sequence = sequence
    self.continuity = continuity
    self.namespaces = namespaces
    self.transfers = transfers
    self.blobs = blobs
  }
}

package enum FailedEnableFields: Codable, Equatable, Sendable {
  case snip(FailedEnableSnipValue), list(FailedEnableListValue), absent
  private enum Keys: String, CodingKey { case kind, fields }
  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: Keys.self)
    switch try values.decode(String.self, forKey: .kind) {
    case "snip": self = .snip(try values.decode(FailedEnableSnipValue.self, forKey: .fields))
    case "list": self = .list(try values.decode(FailedEnableListValue.self, forKey: .fields))
    case "absent": self = .absent
    default: throw FailedEnableEvidenceError.unsupported
    }
  }
  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: Keys.self)
    switch self {
    case .snip(let fields):
      try values.encode("snip", forKey: .kind)
      try values.encode(fields, forKey: .fields)
    case .list(let fields):
      try values.encode("list", forKey: .kind)
      try values.encode(fields, forKey: .fields)
    case .absent: try values.encode("absent", forKey: .kind)
    }
  }
}

extension FailedEnableBinding {
  package init(_ value: ICloudSyncNamespaceBinding) {
    scope = value.scope
    accountLineage = value.accountLineage
    generation = FailedEnableEncoding.uuid(value.generation)
    zones = value.zones.map { FailedEnableZone(owner: $0.ownerName, name: $0.name) }
      .sorted { ($0.owner, $0.name) < ($1.owner, $1.name) }
  }
  package var domain: ICloudSyncNamespaceBinding {
    get throws {
      try ICloudSyncNamespaceBinding(scope: scope, accountLineage: accountLineage,
        generation: FailedEnableEncoding.uuid(generation),
        zones: Set(zones.map { ICloudSyncZoneBinding(name: $0.name, ownerName: $0.owner) }))
    }
  }
}
