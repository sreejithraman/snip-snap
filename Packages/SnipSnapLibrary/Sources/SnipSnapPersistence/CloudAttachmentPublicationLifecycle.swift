import Foundation
import SnipSnapCore
import SwiftData

/// A record CloudKit accepted, kept as the base for the next write to that record.
struct CloudAttachmentAcceptedRecord: Equatable, Sendable {
  var shadowData: Data?
  var systemFields: Data?

  /// No record has reached this device, as for a payload another device uploaded.
  static let unrecorded = CloudAttachmentAcceptedRecord(shadowData: nil, systemFields: nil)
}

/// A payload record owed a delete, with the shadow to delete it from.
struct CloudAttachmentOwedCleanup: Equatable {
  let identity: CloudTextStorageIdentity
  let shadowData: Data?
}

/// What removing an attachment from its snip leaves for the caller to do.
enum CloudAttachmentLocalRemoval: Equatable {
  /// CloudKit may hold metadata, so the publication stays until its delete is accepted.
  case awaitMetadataDeletion(abandonedUpload: CloudAttachmentAbandonedUpload?)
  case discard(abandonedUpload: CloudAttachmentAbandonedUpload)
}

/// An unaccepted payload whose upload may be in flight, owed a cleanup with no shadow.
struct CloudAttachmentAbandonedUpload: Equatable {
  let cleanup: CloudAttachmentOwedCleanup
  let queuedUpload: String?
}

/// One attachment's publication in one sync namespace.
///
/// It decodes from and encodes to the lifecycle fields of `StoredCloudAttachmentPublication`.
/// The stored shape stays as it is, so older and newer builds keep reading each other's rows.
struct CloudAttachmentPublicationLifecycle {
  /// ADR 0016: CloudKit accepts the immutable payload before the metadata that references it.
  private enum Upload {
    case payloadPending(queuedUpload: String?)
    case metadataPending(payload: CloudAttachmentAcceptedRecord)
    case published(payload: CloudAttachmentAcceptedRecord)
  }

  /// Overlaps every upload phase: a removed attachment keeps its publication until CloudKit
  /// accepts the delete of its metadata.
  private enum Presence {
    case present(localSource: String?)
    case removed
  }

  private var upload: Upload
  private var presence: Presence
  private(set) var payloadIdentity: CloudTextStorageIdentity
  /// The base for the next metadata write, kept in every upload phase.
  private var metadataRecord: CloudAttachmentAcceptedRecord
  /// The payload a published attachment replaced. It is owed a cleanup once the new metadata
  /// publishes.
  private(set) var replacedPayload: CloudAttachmentOwedCleanup?
  /// Raw, so failure codes from newer builds survive a write.
  private var failure: String?
  private(set) var revision: UInt64

  private init(
    upload: Upload,
    presence: Presence,
    payloadIdentity: CloudTextStorageIdentity,
    metadataRecord: CloudAttachmentAcceptedRecord,
    replacedPayload: CloudAttachmentOwedCleanup?,
    failure: String?,
    revision: UInt64
  ) {
    self.upload = upload
    self.presence = presence
    self.payloadIdentity = payloadIdentity
    self.metadataRecord = metadataRecord
    self.replacedPayload = replacedPayload
    self.failure = failure
    self.revision = revision
  }

  /// A new attachment with local bytes, queued for its first payload upload.
  static func localAttachment(
    localSource: String,
    payloadIdentity: CloudTextStorageIdentity,
    queuedUpload: String
  ) -> Self {
    Self(
      upload: .payloadPending(queuedUpload: queuedUpload),
      presence: .present(localSource: localSource),
      payloadIdentity: payloadIdentity,
      metadataRecord: .unrecorded,
      replacedPayload: nil,
      failure: nil,
      revision: 1
    )
  }

  /// An attachment first seen through metadata another device published.
  static func remoteAttachment(
    payloadIdentity: CloudTextStorageIdentity,
    metadataRecord: CloudAttachmentAcceptedRecord
  ) -> Self {
    Self(
      upload: .published(payload: .unrecorded),
      presence: .present(localSource: nil),
      payloadIdentity: payloadIdentity,
      metadataRecord: metadataRecord,
      replacedPayload: nil,
      failure: nil,
      revision: 1
    )
  }

  // MARK: Derived reads

  var isLocallyPresent: Bool {
    guard case .present = presence else { return false }
    return true
  }

  var localSourceRelativePath: String? {
    guard case .present(let localSource) = presence else { return nil }
    return localSource
  }

  var queuedUploadRelativePath: String? {
    guard case .payloadPending(let queuedUpload) = upload else { return nil }
    return queuedUpload
  }

  var isPayloadAccepted: Bool { acceptedPayload != nil }

  /// CloudKit accepted metadata at least once and may still hold it after a local edit.
  var hasPublishedMetadata: Bool { metadataRecord != .unrecorded }

  var isMetadataAccepted: Bool {
    guard case .published = upload else { return false }
    return true
  }

  /// CloudKit holds the payload, so a device without its bytes can download them while a
  /// metadata edit still waits to sync.
  var isPayloadRecoverableFromCloudKit: Bool { isPayloadAccepted }

  var payloadShadowData: Data? { acceptedPayload?.shadowData }

  var metadataShadowData: Data? { metadataRecord.shadowData }

  var lastFailure: CloudAttachmentFailure? {
    failure.flatMap(CloudAttachmentFailure.init(rawValue:))
  }

  /// Present with published metadata and no local source, so its snip shows the attachment from
  /// that metadata.
  var materializesFromCloud: Bool {
    isLocallyPresent && isMetadataAccepted && localSourceRelativePath == nil
  }

  /// Present with unpublished metadata, so a cleanup at its location must wait for it.
  var isPresentAwaitingMetadata: Bool { isLocallyPresent && !isMetadataAccepted }

  /// Whether this device republishes an attachment whose metadata record CloudKit no longer
  /// knows. Only a device with the local bytes can. Any other device applies the remote delete.
  var republishesUnknownMetadata: Bool { localSourceRelativePath != nil }

  /// The cleanup this attachment's payload is owed once nothing references it.
  var payloadCleanup: CloudAttachmentOwedCleanup {
    CloudAttachmentOwedCleanup(identity: payloadIdentity, shadowData: payloadShadowData)
  }

  /// The accepted and replaced payloads owed cleanup once their metadata is gone.
  var payloadCleanupsAfterMetadataDeletion: [CloudAttachmentOwedCleanup] {
    var cleanups: [CloudAttachmentOwedCleanup] = []
    if acceptedPayload != nil { cleanups.append(payloadCleanup) }
    if let replacedPayload { cleanups.append(replacedPayload) }
    return cleanups
  }

  func hasAcceptedMetadata(_ record: CloudAttachmentAcceptedRecord) -> Bool {
    isMetadataAccepted && metadataRecord == record
  }

  private var acceptedPayload: CloudAttachmentAcceptedRecord? {
    switch upload {
    case .payloadPending: return nil
    case .metadataPending(let payload), .published(let payload): return payload
    }
  }

  // MARK: Local events

  /// Returns whether a removed attachment came back. Presence alone does not bump the revision.
  mutating func restoreLocalPresence() -> Bool {
    guard case .removed = presence else { return false }
    presence = .present(localSource: nil)
    return true
  }

  mutating func editMetadataLocally() {
    if case .published(let payload) = upload { upload = .metadataPending(payload: payload) }
    failure = nil
    revision += 1
  }

  mutating func setLocalSource(_ relativePath: String) {
    guard case .present = presence else { return }
    presence = .present(localSource: relativePath)
  }

  /// Queues new local bytes. A payload published by metadata waits until that metadata changes;
  /// an accepted payload never published by metadata is owed a cleanup now.
  mutating func replacePayload(
    with identity: CloudTextStorageIdentity,
    queuedUpload: String
  ) -> CloudAttachmentOwedCleanup? {
    var owedCleanup: CloudAttachmentOwedCleanup?
    switch upload {
    case .payloadPending:
      break
    case .metadataPending:
      if hasPublishedMetadata && replacedPayload == nil {
        replacedPayload = payloadCleanup
      } else {
        owedCleanup = payloadCleanup
      }
    case .published:
      replacedPayload = payloadCleanup
    }
    payloadIdentity = identity
    upload = .payloadPending(queuedUpload: queuedUpload)
    return owedCleanup
  }

  /// Returns whether a pending payload's queued upload moved.
  mutating func restageQueuedUpload(_ relativePath: String) -> Bool {
    guard case .payloadPending(let queuedUpload) = upload, queuedUpload != relativePath else {
      return false
    }
    upload = .payloadPending(queuedUpload: relativePath)
    return true
  }

  mutating func removeLocally() -> CloudAttachmentLocalRemoval {
    presence = .removed
    failure = nil
    revision += 1
    switch upload {
    case .published, .metadataPending:
      return .awaitMetadataDeletion(abandonedUpload: nil)
    case .payloadPending(let queuedUpload):
      let abandoned = CloudAttachmentAbandonedUpload(
        cleanup: payloadCleanup,
        queuedUpload: queuedUpload
      )
      if hasPublishedMetadata {
        upload = .payloadPending(queuedUpload: nil)
        return .awaitMetadataDeletion(abandonedUpload: abandoned)
      }
      return .discard(abandonedUpload: abandoned)
    }
  }

  // MARK: CloudKit events

  mutating func adoptBase(_ record: CloudAttachmentAcceptedRecord) {
    guard metadataRecord != record else { return }
    metadataRecord = record
    failure = nil
    revision += 1
  }

  /// Adopts metadata CloudKit holds. The payload it names is accepted, so any queued upload is
  /// released. The payload record and the replaced payload stay as they were.
  mutating func acceptRemoteMetadata(
    payloadIdentity: CloudTextStorageIdentity,
    metadataRecord: CloudAttachmentAcceptedRecord
  ) {
    upload = .published(payload: acceptedPayload ?? .unrecorded)
    self.payloadIdentity = payloadIdentity
    self.metadataRecord = metadataRecord
    failure = nil
    revision += 1
  }

  mutating func acceptPayload(
    _ record: CloudAttachmentAcceptedRecord,
    expectedRevision: UInt64
  ) throws {
    if acceptedPayload == record { return }
    guard revision == expectedRevision, case .payloadPending = upload else {
      throw CloudAttachmentStorageError.staleTransition
    }
    upload = .metadataPending(payload: record)
    failure = nil
    revision += 1
  }

  /// Returns the cleanup owed by the payload this publication replaced.
  mutating func acceptMetadata(
    _ record: CloudAttachmentAcceptedRecord,
    expectedRevision: UInt64
  ) throws -> CloudAttachmentOwedCleanup? {
    if hasAcceptedMetadata(record) { return nil }
    guard revision == expectedRevision, let payload = acceptedPayload else {
      throw CloudAttachmentStorageError.staleTransition
    }
    upload = .published(payload: payload)
    metadataRecord = record
    let owedCleanup = replacedPayload
    replacedPayload = nil
    failure = nil
    revision += 1
    return owedCleanup
  }

  mutating func recordMetadataConflict(
    _ record: CloudAttachmentAcceptedRecord,
    expectedRevision: UInt64
  ) throws {
    try requireRevision(expectedRevision)
    if case .published(let payload) = upload { upload = .metadataPending(payload: payload) }
    metadataRecord = record
    failure = nil
    revision += 1
  }

  mutating func adoptCollisionReplacement(
    _ identity: CloudTextStorageIdentity,
    expectedRevision: UInt64
  ) throws {
    guard revision == expectedRevision, case .payloadPending = upload else {
      throw CloudAttachmentStorageError.staleTransition
    }
    payloadIdentity = identity
    failure = nil
    revision += 1
  }

  /// The lifecycle of the attachment that replaces this one under a new identity after CloudKit
  /// no longer knows its metadata record. Devices that saw the delete clean its accepted
  /// payloads, so only an unaccepted payload can keep its identity.
  func remappedReplacement(
    expectedRevision: UInt64,
    freshPayload: CloudTextStorageIdentity
  ) throws -> Self {
    guard revision == expectedRevision, isLocallyPresent else {
      throw CloudAttachmentStorageError.staleTransition
    }
    var replacement = self
    if acceptedPayload != nil {
      replacement.payloadIdentity = freshPayload
      replacement.upload = .payloadPending(queuedUpload: nil)
    }
    replacement.replacedPayload = nil
    replacement.metadataRecord = .unrecorded
    replacement.failure = nil
    replacement.revision = revision + 1
    return replacement
  }

  mutating func recordFailure(
    _ failure: CloudAttachmentFailure,
    expectedRevision: UInt64
  ) throws {
    try requireRevision(expectedRevision)
    self.failure = failure.rawValue
    revision += 1
  }

  /// Returns the accepted payloads owed cleanup now that their metadata is gone.
  func acceptMetadataDeletion(expectedRevision: UInt64) throws -> [CloudAttachmentOwedCleanup] {
    guard revision == expectedRevision, !isLocallyPresent else {
      throw CloudAttachmentStorageError.staleTransition
    }
    return payloadCleanupsAfterMetadataDeletion
  }

  /// Adopts the server's metadata after a delete conflict, so the delete retries from it.
  /// Returns the cleanup owed by the old payload when the server names another one.
  mutating func recordMetadataDeletionConflict(
    _ record: CloudAttachmentAcceptedRecord,
    payloadIdentity serverPayload: CloudTextStorageIdentity,
    expectedRevision: UInt64
  ) throws -> CloudAttachmentOwedCleanup? {
    guard revision == expectedRevision, !isLocallyPresent else {
      throw CloudAttachmentStorageError.staleTransition
    }
    var owedCleanup: CloudAttachmentOwedCleanup?
    var payload = acceptedPayload ?? .unrecorded
    if payloadIdentity != serverPayload {
      owedCleanup = payloadCleanup
      payloadIdentity = serverPayload
      payload = .unrecorded
    }
    upload = .published(payload: payload)
    metadataRecord = record
    failure = nil
    revision += 1
    return owedCleanup
  }

  /// Returns whether the publication was not already quarantined.
  mutating func quarantine() -> Bool {
    let invalidRecord = CloudAttachmentFailure.invalidRecord.rawValue
    guard failure != invalidRecord else { return false }
    failure = invalidRecord
    revision += 1
    return true
  }

  /// Returns whether a failure that only a manual retry clears was cleared.
  mutating func clearManuallyRetryableFailure() -> Bool {
    guard let lastFailure, lastFailure.clearsOnManualRetryOnly else { return false }
    failure = nil
    revision += 1
    return true
  }

  private func requireRevision(_ expected: UInt64) throws {
    guard revision == expected else { throw CloudAttachmentStorageError.staleTransition }
  }

  // MARK: Stored form

  /// Drops values no build writes outside their phase, and a queued upload beside an accepted
  /// payload, which older builds left behind.
  fileprivate init(decoding row: StoredCloudAttachmentPublication) {
    let payload = CloudAttachmentAcceptedRecord(
      shadowData: row.payloadShadowData,
      systemFields: row.payloadSystemFields
    )
    let upload: Upload
    if !row.payloadAccepted {
      upload = .payloadPending(queuedUpload: row.uploadRelativePath)
    } else if row.metadataAccepted {
      upload = .published(payload: payload)
    } else {
      upload = .metadataPending(payload: payload)
    }
    let replacedPayload: CloudAttachmentOwedCleanup?
    if let zoneName = row.priorPayloadZoneName,
      let ownerName = row.priorPayloadOwnerName,
      let recordName = row.priorPayloadRecordName
    {
      replacedPayload = CloudAttachmentOwedCleanup(
        identity: CloudTextStorageIdentity(
          zoneName: zoneName,
          ownerName: ownerName,
          recordName: recordName
        ),
        shadowData: row.priorPayloadShadowData
      )
    } else {
      replacedPayload = nil
    }
    self.init(
      upload: upload,
      presence: row.isLocallyPresent ? .present(localSource: row.sourceRelativePath) : .removed,
      payloadIdentity: row.payloadIdentity,
      metadataRecord: CloudAttachmentAcceptedRecord(
        shadowData: row.metadataShadowData,
        systemFields: row.metadataSystemFields
      ),
      replacedPayload: replacedPayload,
      failure: row.lastFailure,
      revision: row.revision
    )
  }

  /// Assigns only the fields that changed, so an unchanged lifecycle leaves the row clean.
  fileprivate func encode(into row: StoredCloudAttachmentPublication) {
    func write<Value: Equatable>(
      _ field: ReferenceWritableKeyPath<StoredCloudAttachmentPublication, Value>,
      _ value: Value
    ) {
      if row[keyPath: field] != value { row[keyPath: field] = value }
    }
    let payload = acceptedPayload
    write(\.isLocallyPresent, isLocallyPresent)
    write(\.sourceRelativePath, localSourceRelativePath)
    write(\.uploadRelativePath, queuedUploadRelativePath)
    write(\.payloadZoneName, payloadIdentity.zoneName)
    write(\.payloadOwnerName, payloadIdentity.ownerName)
    write(\.payloadRecordName, payloadIdentity.recordName)
    write(\.payloadAccepted, isPayloadAccepted)
    write(\.payloadShadowData, payload?.shadowData)
    write(\.payloadSystemFields, payload?.systemFields)
    write(\.metadataAccepted, isMetadataAccepted)
    write(\.metadataShadowData, metadataRecord.shadowData)
    write(\.metadataSystemFields, metadataRecord.systemFields)
    write(\.priorPayloadZoneName, replacedPayload?.identity.zoneName)
    write(\.priorPayloadOwnerName, replacedPayload?.identity.ownerName)
    write(\.priorPayloadRecordName, replacedPayload?.identity.recordName)
    write(\.priorPayloadShadowData, replacedPayload?.shadowData)
    write(\.lastFailure, failure)
    write(\.revision, revision)
  }
}

extension StoredCloudAttachmentPublication {
  var payloadIdentity: CloudTextStorageIdentity {
    CloudTextStorageIdentity(
      zoneName: payloadZoneName,
      ownerName: payloadOwnerName,
      recordName: payloadRecordName
    )
  }

  /// The only writer of this row's lifecycle fields after its `init`.
  var lifecycle: CloudAttachmentPublicationLifecycle {
    get { CloudAttachmentPublicationLifecycle(decoding: self) }
    set { newValue.encode(into: self) }
  }
}

// MARK: Payload cleanup

/// The payload cleanups of one sync namespace within one save.
///
/// ADR 0016: a payload is deleted only after no published metadata references it. A cleanup can
/// also wait for a replacement attachment at the same location to publish its metadata. The
/// planner reads that wait from the stored blocker.
struct CloudAttachmentCleanupQueue {
  private let namespaceKey: String
  private let context: ModelContext
  private var rows: [CloudTextStorageIdentity: StoredCloudAttachmentCleanup]
  private var acceptedIdentities: Set<CloudTextStorageIdentity> = []

  init(namespaceKey: String, context: ModelContext) throws {
    let stored = try SwiftDataSnipLibrary.cloudAttachmentCleanups(
      namespaceKey: namespaceKey,
      context: context
    )
    self.namespaceKey = namespaceKey
    self.context = context
    rows = Dictionary(uniqueKeysWithValues: stored.map { ($0.identity, $0) })
  }

  /// Queues a cleanup, or merges into the one already queued for that payload, keeping its first
  /// shadow and its first blocker.
  mutating func queue(_ cleanup: CloudAttachmentOwedCleanup, blockedBy attachmentID: UUID? = nil) {
    if let current = rows[cleanup.identity] {
      if current.shadowData == nil { current.shadowData = cleanup.shadowData }
      if current.blockedByAttachmentID == nil { current.blockedByAttachmentID = attachmentID }
      return
    }
    let row = StoredCloudAttachmentCleanup(
      namespaceKey: namespaceKey,
      identity: cleanup.identity,
      shadowData: cleanup.shadowData,
      blockedByAttachmentID: attachmentID
    )
    context.insert(row)
    rows[cleanup.identity] = row
  }

  mutating func acceptDeletion(
    of identity: CloudTextStorageIdentity,
    expectedRevision: UInt64
  ) throws {
    guard let row = rows[identity] else { return }
    guard row.revision == expectedRevision else {
      throw CloudAttachmentStorageError.staleTransition
    }
    context.delete(row)
    acceptedIdentities.insert(identity)
  }

  func recordConflict(
    for identity: CloudTextStorageIdentity,
    shadowData: Data,
    expectedRevision: UInt64
  ) throws {
    guard let row = rows[identity], row.revision == expectedRevision else {
      throw CloudAttachmentStorageError.staleTransition
    }
    row.shadowData = shadowData
    row.lastFailure = nil
    row.revision += 1
  }

  func recordFailure(
    _ failure: CloudAttachmentFailure,
    for identity: CloudTextStorageIdentity,
    expectedRevision: UInt64
  ) throws {
    guard let row = rows[identity], row.revision == expectedRevision else {
      throw CloudAttachmentStorageError.staleTransition
    }
    row.lastFailure = failure.rawValue
    row.revision += 1
  }

  /// A replacement that gets a new identity keeps blocking every cleanup that waited for it,
  /// whether stored by an earlier save or queued earlier in this one. The revision stays, as a
  /// merge keeps it when it sets a blocker, so a delete planned from this revision still applies.
  func remapBlockers(from attachmentID: UUID, to replacementID: UUID) {
    for (identity, row) in rows
    where !acceptedIdentities.contains(identity) && row.blockedByAttachmentID == attachmentID {
      row.blockedByAttachmentID = replacementID
    }
  }
}

extension StoredCloudAttachmentCleanup {
  /// Returns whether the cleanup was not already quarantined.
  func quarantine() -> Bool {
    let invalidRecord = CloudAttachmentFailure.invalidRecord.rawValue
    guard lastFailure != invalidRecord else { return false }
    lastFailure = invalidRecord
    revision += 1
    return true
  }

  /// Returns whether a failure that only a manual retry clears was cleared.
  func clearManuallyRetryableFailure() -> Bool {
    guard let failure = lastFailure.flatMap(CloudAttachmentFailure.init(rawValue:)),
      failure.clearsOnManualRetryOnly
    else { return false }
    lastFailure = nil
    revision += 1
    return true
  }
}
