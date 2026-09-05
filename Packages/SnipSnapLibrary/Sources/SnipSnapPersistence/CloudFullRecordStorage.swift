import CryptoKit
import Foundation
import SnipSnapCore

package enum CloudEntityKind: String, Codable, Equatable, Hashable, Sendable {
  case snip
  case list
}

package struct CloudEntityReference: Codable, Equatable, Hashable, Sendable {
  package let kind: CloudEntityKind
  package let domainID: UUID

  package init(kind: CloudEntityKind, domainID: UUID) {
    self.kind = kind
    self.domainID = domainID
  }
}

package struct CloudAcceptedEntity: Equatable, Sendable {
  package let reference: CloudEntityReference
  package let identity: CloudTextStorageIdentity
  package let schemaVersion: Int
  package let acceptedData: Data
  package let presenceData: Data
  package let shadowData: Data
  package let systemFields: Data
  package let dependencyListID: UUID?
  package let isDeferred: Bool
  package let localRevision: UInt64

  package init(
    reference: CloudEntityReference,
    identity: CloudTextStorageIdentity,
    schemaVersion: Int,
    acceptedData: Data,
    presenceData: Data,
    shadowData: Data,
    systemFields: Data,
    dependencyListID: UUID?,
    isDeferred: Bool,
    localRevision: UInt64
  ) {
    self.reference = reference
    self.identity = identity
    self.schemaVersion = schemaVersion
    self.acceptedData = acceptedData
    self.presenceData = presenceData
    self.shadowData = shadowData
    self.systemFields = systemFields
    self.dependencyListID = dependencyListID
    self.isDeferred = isDeferred
    self.localRevision = localRevision
  }
}

package struct CloudAcceptedEntityInput: Codable, Equatable, Sendable {
  package let reference: CloudEntityReference
  package let identity: CloudTextStorageIdentity
  package let schemaVersion: Int
  package let acceptedData: Data
  package let presenceData: Data
  package let shadowData: Data
  package let systemFields: Data
  package let dependencyListID: UUID?

  package init(
    reference: CloudEntityReference,
    identity: CloudTextStorageIdentity,
    schemaVersion: Int,
    acceptedData: Data,
    presenceData: Data,
    shadowData: Data,
    systemFields: Data,
    dependencyListID: UUID? = nil
  ) {
    self.reference = reference
    self.identity = identity
    self.schemaVersion = schemaVersion
    self.acceptedData = acceptedData
    self.presenceData = presenceData
    self.shadowData = shadowData
    self.systemFields = systemFields
    self.dependencyListID = dependencyListID
  }
}

package struct CloudStoredConflict: Equatable, Sendable {
  package let key: String
  package let reference: CloudEntityReference
  package let format: CloudConflictFormat
  package let payload: Data

  package init(
    key: String,
    reference: CloudEntityReference,
    format: CloudConflictFormat,
    payload: Data
  ) {
    self.key = key
    self.reference = reference
    self.format = format
    self.payload = payload
  }
}

package enum CloudConflictFormat: String, Codable, Equatable, Sendable {
  case snipMergeV1
  case listMergeV1
  case legacyBindingV1
}

package struct CloudConflictInput: Codable, Equatable, Sendable {
  package let key: String
  package let reference: CloudEntityReference
  package let format: CloudConflictFormat
  package let payload: Data
  package let recovery: SnipRecoveryRecord?

  package init(
    key: String,
    reference: CloudEntityReference,
    format: CloudConflictFormat,
    payload: Data,
    recovery: SnipRecoveryRecord? = nil
  ) {
    self.key = key
    self.reference = reference
    self.format = format
    self.payload = payload
    self.recovery = recovery
  }
}

package struct CloudQuarantineInput: Codable, Equatable, Sendable {
  package let key: String
  package let reference: CloudEntityReference
  package let identity: CloudTextStorageIdentity
  package let format: CloudConflictFormat
  package let payload: Data

  package init(
    key: String,
    reference: CloudEntityReference,
    identity: CloudTextStorageIdentity,
    format: CloudConflictFormat = .legacyBindingV1,
    payload: Data
  ) {
    self.key = key
    self.reference = reference
    self.identity = identity
    self.format = format
    self.payload = payload
  }
}

package struct CloudStoredQuarantine: Equatable, Sendable {
  package let key: String
  package let reference: CloudEntityReference
  package let identity: CloudTextStorageIdentity
  package let format: CloudConflictFormat
  package let payload: Data
}

package struct CloudDormantBase: Equatable, Sendable {
  package let namespaceKey: String
  package let reference: CloudEntityReference
  package let identity: CloudTextStorageIdentity
  package let payload: Data
}

package struct CloudDormantAcceptedBaseBundle: Codable, Equatable, Sendable {
  package struct Entry: Codable, Equatable, Sendable {
    package let namespaceKey: String
    package let reference: CloudEntityReference
    package let identity: CloudTextStorageIdentity
    package let payload: Data

    package init(
      namespaceKey: String,
      reference: CloudEntityReference,
      identity: CloudTextStorageIdentity,
      payload: Data
    ) {
      self.namespaceKey = namespaceKey
      self.reference = reference
      self.identity = identity
      self.payload = payload
    }
  }

  package let storageVersion: Int
  package let entries: [Entry]

  package init(entries: [Entry]) throws {
    storageVersion = 1
    var domains: Set<String> = []
    var identities: Set<String> = []
    for entry in entries {
      let domain = "\(entry.namespaceKey)|\(entry.reference.kind.rawValue)|\(entry.reference.domainID.uuidString.lowercased())"
      let identity = "\(entry.namespaceKey)|\(entry.identity.key)"
      guard domains.insert(domain).inserted, identities.insert(identity).inserted else {
        throw CloudFullStorageError.duplicateDormantBinding
      }
    }
    self.entries = entries.sorted(by: Self.less)
  }

  package static func decode(_ data: Data) throws -> Self {
    guard !data.isEmpty else { return try Self(entries: []) }
    let value = try JSONDecoder().decode(Self.self, from: data)
    guard value.storageVersion == 1 else { throw CloudFullStorageError.invalidLegacyRecord }
    return try Self(entries: value.entries)
  }

  package func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }

  package func merging(_ source: Self) throws -> Self {
    var values = Dictionary(uniqueKeysWithValues: entries.map { (Self.domainKey($0), $0) })
    var identityKeys = Dictionary(uniqueKeysWithValues: entries.map { (Self.identityKey($0), Self.domainKey($0)) })
    for entry in source.entries {
      let domain = Self.domainKey(entry)
      let identity = Self.identityKey(entry)
      if let current = values[domain] {
        guard current.identity == entry.identity else {
          throw CloudFullStorageError.duplicateDormantBinding
        }
        values[domain] = entry
        continue
      }
      guard identityKeys[identity] == nil else {
        throw CloudFullStorageError.duplicateDormantBinding
      }
      values[domain] = entry
      identityKeys[identity] = domain
    }
    return try Self(entries: Array(values.values))
  }

  private static func domainKey(_ entry: Entry) -> String {
    "\(entry.namespaceKey)|\(entry.reference.kind.rawValue)|\(entry.reference.domainID.uuidString.lowercased())"
  }

  private static func identityKey(_ entry: Entry) -> String {
    "\(entry.namespaceKey)|\(entry.identity.key)"
  }

  private static func less(_ lhs: Entry, _ rhs: Entry) -> Bool {
    (
      lhs.namespaceKey,
      lhs.reference.kind.rawValue,
      lhs.reference.domainID.uuidString.lowercased(),
      lhs.identity.key
    ) < (
      rhs.namespaceKey,
      rhs.reference.kind.rawValue,
      rhs.reference.domainID.uuidString.lowercased(),
      rhs.identity.key
    )
  }
}

package struct CloudFullReenableAcceptedCAS: Codable, Equatable, Sendable {
  package let accepted: CloudAcceptedEntityInput
  package let localRevision: UInt64
  package let isDeferred: Bool

  package init(_ entity: CloudAcceptedEntity) {
    accepted = CloudAcceptedEntityInput(
      reference: entity.reference,
      identity: entity.identity,
      schemaVersion: entity.schemaVersion,
      acceptedData: entity.acceptedData,
      presenceData: entity.presenceData,
      shadowData: entity.shadowData,
      systemFields: entity.systemFields,
      dependencyListID: entity.dependencyListID
    )
    localRevision = entity.localRevision
    isDeferred = entity.isDeferred
  }
}

package struct CloudFullReenableApplyPlan: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let transitionID: UUID
  package let namespaceKey: String
  package let expectedNamespaceRevision: UInt64
  package let targetRevision: UInt64
  package let targetDigest: Data
  package let snips: [Snip]
  package let lists: [SnipList]
  package let attachmentData: [UUID: Data]
  package let dormantPayload: Data
  package let acceptedCAS: [CloudFullReenableAcceptedCAS]
  package let conflicts: [CloudConflictInput]
  package let recoveryInputs: [CloudFullRecoveryInput]
  package let result: SnipLibraryTransferResult
  package let planDigest: Data

  private struct DigestInput: Codable {
    let storageVersion: Int
    let transitionID: UUID
    let namespaceKey: String
    let expectedNamespaceRevision: UInt64
    let targetRevision: UInt64
    let targetDigest: Data
    let snips: [Snip]
    let lists: [SnipList]
    let attachmentData: [UUID: Data]
    let dormantPayload: Data
    let acceptedCAS: [CloudFullReenableAcceptedCAS]
    let conflicts: [CloudConflictInput]
    let recoveryInputs: [CloudFullRecoveryInput]
    let approvedSnipIDs: Set<UUID>
    let recoveredSourceSnipIDs: Set<UUID>
  }

  package init(
    transitionID: UUID,
    namespaceKey: String,
    expectedNamespaceRevision: UInt64 = 0,
    targetRevision: UInt64,
    targetDigest: Data,
    snips: [Snip],
    lists: [SnipList],
    attachmentData: [UUID: Data],
    dormantPayload: Data,
    acceptedCAS: [CloudFullReenableAcceptedCAS],
    conflicts: [CloudConflictInput],
    recoveryInputs: [CloudFullRecoveryInput],
    result: SnipLibraryTransferResult
  ) throws {
    storageVersion = 1
    self.transitionID = transitionID
    self.namespaceKey = namespaceKey
    self.expectedNamespaceRevision = expectedNamespaceRevision
    self.targetRevision = targetRevision
    self.targetDigest = targetDigest
    self.snips = snips
    self.lists = lists
    self.attachmentData = attachmentData
    self.dormantPayload = dormantPayload
    self.acceptedCAS = acceptedCAS.sorted {
      ($0.accepted.reference.kind.rawValue, $0.accepted.reference.domainID.uuidString)
        < ($1.accepted.reference.kind.rawValue, $1.accepted.reference.domainID.uuidString)
    }
    self.conflicts = conflicts.sorted { $0.key < $1.key }
    self.recoveryInputs = recoveryInputs.sorted { $0.batchID.uuidString < $1.batchID.uuidString }
    self.result = result
    planDigest = try Self.digest(
      storageVersion: storageVersion,
      transitionID: transitionID,
      namespaceKey: namespaceKey,
      expectedNamespaceRevision: expectedNamespaceRevision,
      targetRevision: targetRevision,
      targetDigest: targetDigest,
      snips: snips,
      lists: lists,
      attachmentData: attachmentData,
      dormantPayload: dormantPayload,
      acceptedCAS: self.acceptedCAS,
      conflicts: self.conflicts,
      recoveryInputs: self.recoveryInputs,
      result: result
    )
  }

  package func hasValidDigest() throws -> Bool {
    try planDigest == Self.digest(
      storageVersion: storageVersion,
      transitionID: transitionID,
      namespaceKey: namespaceKey,
      expectedNamespaceRevision: expectedNamespaceRevision,
      targetRevision: targetRevision,
      targetDigest: targetDigest,
      snips: snips,
      lists: lists,
      attachmentData: attachmentData,
      dormantPayload: dormantPayload,
      acceptedCAS: acceptedCAS,
      conflicts: conflicts,
      recoveryInputs: recoveryInputs,
      result: result
    )
  }

  private static func digest(
    storageVersion: Int,
    transitionID: UUID,
    namespaceKey: String,
    expectedNamespaceRevision: UInt64,
    targetRevision: UInt64,
    targetDigest: Data,
    snips: [Snip],
    lists: [SnipList],
    attachmentData: [UUID: Data],
    dormantPayload: Data,
    acceptedCAS: [CloudFullReenableAcceptedCAS],
    conflicts: [CloudConflictInput],
    recoveryInputs: [CloudFullRecoveryInput],
    result: SnipLibraryTransferResult
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try encoder.encode(DigestInput(
      storageVersion: storageVersion,
      transitionID: transitionID,
      namespaceKey: namespaceKey,
      expectedNamespaceRevision: expectedNamespaceRevision,
      targetRevision: targetRevision,
      targetDigest: targetDigest,
      snips: snips,
      lists: lists,
      attachmentData: attachmentData,
      dormantPayload: dormantPayload,
      acceptedCAS: acceptedCAS,
      conflicts: conflicts,
      recoveryInputs: recoveryInputs,
      approvedSnipIDs: result.approvedSnipIDs,
      recoveredSourceSnipIDs: result.recoveredSourceSnipIDs
    ))
    return Data(SHA256.hash(data: data))
  }
}

package struct CloudFullStorageSnapshot: Equatable, Sendable {
  package let readyEntities: [CloudAcceptedEntity]
  package let deferredEntities: [CloudAcceptedEntity]
  package let pendingDeletes: [CloudPendingDelete]
  package let conflicts: [CloudStoredConflict]
  package let enrolledEntities: Set<CloudEntityReference>
  package let quarantines: [CloudStoredQuarantine]
  package let namespaceState: CloudFullNamespaceState
}

package struct CloudPendingDelete: Codable, Equatable, Hashable, Sendable {
  package let storageVersion: Int
  package let reference: CloudEntityReference
  package let identity: CloudTextStorageIdentity

  package init(reference: CloudEntityReference, identity: CloudTextStorageIdentity) {
    storageVersion = 1
    self.reference = reference
    self.identity = identity
  }
}

package struct CloudFullNamespaceState: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let revision: UInt64
  package let phase: CloudNamespaceBootstrapPhase
  package let zoneCreationPending: Bool

  package init(
    revision: UInt64,
    phase: CloudNamespaceBootstrapPhase,
    zoneCreationPending: Bool = false
  ) {
    storageVersion = 1
    self.revision = revision
    self.phase = phase
    self.zoneCreationPending = zoneCreationPending
  }

  package static let notEnrolled = CloudFullNamespaceState(revision: 0, phase: .notEnrolled)
}

package struct CloudFullEnrollmentState: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let namespaceState: CloudFullNamespaceState
  package let references: Set<CloudEntityReference>

  package init(
    namespaceState: CloudFullNamespaceState,
    references: Set<CloudEntityReference>
  ) {
    storageVersion = 1
    self.namespaceState = namespaceState
    self.references = references
  }
}

package enum CloudFullStorageError: Error, Equatable, Sendable {
  case invalidConflictReplay
  case invalidEnrollment
  case invalidLegacyRecord
  case missingListDependency
  case staleAcceptedEntity
  case invalidBatchReplay
  case engineStateMismatch
  case invalidLocalMutation
  case staleLocalEntity
  case duplicateDormantBinding
  case namespaceStateMismatch
}

package struct CloudLocalSnipMutation: Codable, Equatable, Sendable {
  package let snipID: UUID
  package let requestID: UUID
  package let createdAt: Date
  package let updatedAt: Date
  package let content: String
  package let origin: SnipOrigin
  package let source: SnipSource?
  package let listID: UUID
  package let isDone: Bool
  package let orderKey: SnipOrderKey

  package init(
    snipID: UUID,
    requestID: UUID,
    createdAt: Date,
    updatedAt: Date,
    content: String,
    origin: SnipOrigin,
    source: SnipSource?,
    listID: UUID,
    isDone: Bool,
    orderKey: SnipOrderKey
  ) {
    self.snipID = snipID
    self.requestID = requestID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.content = content
    self.origin = origin
    self.source = source
    self.listID = listID
    self.isDone = isDone
    self.orderKey = orderKey
  }

  package init(_ snip: Snip) {
    snipID = snip.id
    requestID = snip.requestID
    createdAt = snip.createdAt
    updatedAt = snip.updatedAt
    content = snip.content
    origin = snip.origin
    source = snip.source
    listID = snip.listID
    isDone = snip.isDone
    orderKey = snip.manualSortKey
  }
}

package struct CloudLocalListMutation: Codable, Equatable, Sendable {
  package let listID: UUID
  package let desiredName: String
  package let systemImage: String
  package let color: SnipListColor?
  package let orderKey: SnipOrderKey

  package init(_ list: SnipList) {
    listID = list.id
    desiredName = list.desiredName
    systemImage = list.systemImage
    color = list.color
    orderKey = list.sortKey
  }
}

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

package enum CloudAcceptedAction: String, Codable, Equatable, Sendable {
  case upsert
  case remove
  case quarantine
}

package struct CloudDeferredLocalMutation: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let precondition: CloudLocalPrecondition
  package let mutation: CloudFullLocalMutation

  package init(
    precondition: CloudLocalPrecondition,
    mutation: CloudFullLocalMutation
  ) {
    storageVersion = 1
    self.precondition = precondition
    self.mutation = mutation
  }
}

package struct CloudFullBatchItem: Codable, Equatable, Sendable {
  package let accepted: CloudAcceptedEntityInput
  package let acceptedAction: CloudAcceptedAction
  package let expectedLocalRevision: UInt64?
  package let expectedSystemFields: Data?
  package let localPrecondition: CloudLocalPrecondition
  package let localMutation: CloudFullLocalMutation
  package let conflict: CloudConflictInput?
  package let quarantine: CloudQuarantineInput?

  package init(
    accepted: CloudAcceptedEntityInput,
    acceptedAction: CloudAcceptedAction = .upsert,
    expectedLocalRevision: UInt64?,
    expectedSystemFields: Data?,
    localPrecondition: CloudLocalPrecondition = .none,
    localMutation: CloudFullLocalMutation,
    conflict: CloudConflictInput?,
    quarantine: CloudQuarantineInput?
  ) {
    self.accepted = accepted
    self.acceptedAction = acceptedAction
    self.expectedLocalRevision = expectedLocalRevision
    self.expectedSystemFields = expectedSystemFields
    self.localPrecondition = localPrecondition
    self.localMutation = localMutation
    self.conflict = conflict
    self.quarantine = quarantine
  }
}

package enum CloudFullOutboundAction: String, Codable, Equatable, Sendable {
  case save
  case delete
}

/// The exact wire operation that produced one sent-batch result.
package struct CloudFullOutboundBinding: Codable, Equatable, Sendable {
  package let identity: CloudTextStorageIdentity
  package let action: CloudFullOutboundAction
  package let operationData: Data

  package init(
    identity: CloudTextStorageIdentity,
    action: CloudFullOutboundAction,
    operationData: Data
  ) {
    self.identity = identity
    self.action = action
    self.operationData = operationData
  }
}

package enum CloudFullRecoveryKind: String, Codable, Equatable, Sendable {
  case malformedSentBatch
  case retryableFetch
  case terminalFetch
  case retryableSend
  case terminalSend
  case destructiveReset
  case modeRecoveredSnip
  case modeRecoveredList
  case modeDeletedListPlacement
  case deletedListPlacement
}

package struct CloudRecoveryReviewInput: Codable, Equatable, Sendable {
  package let conflictKey: String
  package let recovery: SnipRecoveryRecord

  package init(conflictKey: String, recovery: SnipRecoveryRecord) {
    self.conflictKey = conflictKey
    self.recovery = recovery
  }
}

package struct CloudFullRecoveryInput: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let namespaceKey: String
  package let batchID: UUID
  package let kind: CloudFullRecoveryKind
  package let outboundData: Data
  package let resultData: Data

  package init(
    namespaceKey: String,
    batchID: UUID,
    kind: CloudFullRecoveryKind,
    outboundData: Data,
    resultData: Data
  ) {
    storageVersion = 1
    self.namespaceKey = namespaceKey
    self.batchID = batchID
    self.kind = kind
    self.outboundData = outboundData
    self.resultData = resultData
  }
}

package struct CloudFullBatchCommit: Codable, Equatable, Sendable {
  package let storageVersion: Int
  package let namespaceKey: String
  package let batchID: UUID
  package let expectedEngineState: Data?
  package let nextEngineState: Data?
  package let nextEnrollment: Set<CloudEntityReference>?
  package let expectedNamespaceRevision: UInt64?
  package let nextNamespaceState: CloudFullNamespaceState?
  package let rawBatchData: Data?
  package let outboundBindings: [CloudFullOutboundBinding]
  package let recoveryInputs: [CloudFullRecoveryInput]
  package let recoveryReviews: [CloudRecoveryReviewInput]
  package let settledDeleteIdentities: [CloudTextStorageIdentity]
  package let attachmentTransitions: [CloudAttachmentTransition]
  package let items: [CloudFullBatchItem]

  private enum CodingKeys: String, CodingKey {
    case storageVersion, namespaceKey, batchID, expectedEngineState, nextEngineState
    case nextEnrollment, expectedNamespaceRevision, nextNamespaceState, rawBatchData
    case outboundBindings, recoveryInputs, recoveryReviews, settledDeleteIdentities
    case attachmentTransitions, items
  }

  package init(
    namespaceKey: String,
    batchID: UUID,
    expectedEngineState: Data?,
    nextEngineState: Data?,
    nextEnrollment: Set<CloudEntityReference>? = nil,
    expectedNamespaceRevision: UInt64? = nil,
    nextNamespaceState: CloudFullNamespaceState? = nil,
    rawBatchData: Data? = nil,
    outboundBindings: [CloudFullOutboundBinding] = [],
    recoveryInputs: [CloudFullRecoveryInput] = [],
    recoveryReviews: [CloudRecoveryReviewInput] = [],
    settledDeleteIdentities: [CloudTextStorageIdentity] = [],
    attachmentTransitions: [CloudAttachmentTransition] = [],
    items: [CloudFullBatchItem]
  ) {
    storageVersion = 1
    self.namespaceKey = namespaceKey
    self.batchID = batchID
    self.expectedEngineState = expectedEngineState
    self.nextEngineState = nextEngineState
    self.nextEnrollment = nextEnrollment
    self.expectedNamespaceRevision = expectedNamespaceRevision
    self.nextNamespaceState = nextNamespaceState
    self.rawBatchData = rawBatchData
    self.outboundBindings = outboundBindings
    self.recoveryInputs = recoveryInputs
    self.recoveryReviews = recoveryReviews
    self.settledDeleteIdentities = settledDeleteIdentities
    self.attachmentTransitions = attachmentTransitions
    self.items = items
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    storageVersion = try container.decode(Int.self, forKey: .storageVersion)
    namespaceKey = try container.decode(String.self, forKey: .namespaceKey)
    batchID = try container.decode(UUID.self, forKey: .batchID)
    expectedEngineState = try container.decodeIfPresent(Data.self, forKey: .expectedEngineState)
    nextEngineState = try container.decodeIfPresent(Data.self, forKey: .nextEngineState)
    nextEnrollment = try container.decodeIfPresent(
      [CloudEntityReference].self,
      forKey: .nextEnrollment
    ).map(Set.init)
    expectedNamespaceRevision = try container.decodeIfPresent(
      UInt64.self,
      forKey: .expectedNamespaceRevision
    )
    nextNamespaceState = try container.decodeIfPresent(
      CloudFullNamespaceState.self,
      forKey: .nextNamespaceState
    )
    rawBatchData = try container.decodeIfPresent(Data.self, forKey: .rawBatchData)
    outboundBindings = try container.decodeIfPresent(
      [CloudFullOutboundBinding].self,
      forKey: .outboundBindings
    ) ?? []
    recoveryInputs = try container.decodeIfPresent(
      [CloudFullRecoveryInput].self,
      forKey: .recoveryInputs
    ) ?? []
    recoveryReviews = try container.decodeIfPresent(
      [CloudRecoveryReviewInput].self,
      forKey: .recoveryReviews
    ) ?? []
    settledDeleteIdentities = try container.decodeIfPresent(
      [CloudTextStorageIdentity].self,
      forKey: .settledDeleteIdentities
    ) ?? []
    attachmentTransitions = try container.decodeIfPresent(
      [CloudAttachmentTransition].self,
      forKey: .attachmentTransitions
    ) ?? []
    items = try container.decode([CloudFullBatchItem].self, forKey: .items)
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(storageVersion, forKey: .storageVersion)
    try container.encode(namespaceKey, forKey: .namespaceKey)
    try container.encode(batchID, forKey: .batchID)
    try container.encodeIfPresent(expectedEngineState, forKey: .expectedEngineState)
    try container.encodeIfPresent(nextEngineState, forKey: .nextEngineState)
    try container.encodeIfPresent(
      nextEnrollment?.sorted {
        ($0.kind.rawValue, $0.domainID.uuidString)
          < ($1.kind.rawValue, $1.domainID.uuidString)
      },
      forKey: .nextEnrollment
    )
    try container.encodeIfPresent(expectedNamespaceRevision, forKey: .expectedNamespaceRevision)
    try container.encodeIfPresent(nextNamespaceState, forKey: .nextNamespaceState)
    try container.encodeIfPresent(rawBatchData, forKey: .rawBatchData)
    try container.encode(outboundBindings, forKey: .outboundBindings)
    try container.encode(recoveryInputs, forKey: .recoveryInputs)
    try container.encode(recoveryReviews, forKey: .recoveryReviews)
    try container.encode(settledDeleteIdentities, forKey: .settledDeleteIdentities)
    try container.encode(attachmentTransitions, forKey: .attachmentTransitions)
    try container.encode(items, forKey: .items)
  }
}

package enum CloudFullBatchCommitResult: Equatable, Sendable {
  case applied
  case replayed
}

package enum CloudWirePayloadFormat: String, Codable, Equatable, Sendable {
  case legacyTextV1
  case fullRecordV1
}

package struct CloudWirePayloadEnvelope: Codable, Equatable, Sendable {
  private static let expectedMarker = "snipsnap-cloud-wire"

  package let format: CloudWirePayloadFormat
  package let payload: Data
  private let marker: String
  private let storageVersion: Int
  private struct Header: Codable {
    let marker: String
    let storageVersion: Int
  }

  package init(format: CloudWirePayloadFormat, payload: Data) {
    self.format = format
    self.payload = payload
    marker = Self.expectedMarker
    storageVersion = 1
  }

  package static func decode(_ data: Data) -> CloudWirePayloadEnvelope? {
    guard let value = try? JSONDecoder().decode(Self.self, from: data),
      value.marker == expectedMarker,
      value.storageVersion == 1
    else { return nil }
    return value
  }

  package static func hasEnvelopeMarker(_ data: Data) -> Bool {
    (try? JSONDecoder().decode(Header.self, from: data))?.marker == expectedMarker
  }

  package func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }

  package static func legacyPayload(from data: Data) -> Data? {
    guard let envelope = decode(data) else {
      return hasEnvelopeMarker(data) ? nil : data
    }
    guard envelope.format == .legacyTextV1 else { return nil }
    return envelope.payload
  }
}

/// The fixed local form used when a schema-1 text-only record first enters the full-record store.
package struct CloudLegacySnipMaterialization: Codable, Equatable, Sendable {
  package static let storageVersion = 1

  package let version: Int
  package let snipID: UUID
  package let requestID: UUID
  package let createdAt: Date
  package let updatedAt: Date
  package let content: String
  package let origin: String
  package let listID: UUID
  package let isDone: Bool
  package let orderKey: Data
  package let remotePresentFields: Set<String>
}
