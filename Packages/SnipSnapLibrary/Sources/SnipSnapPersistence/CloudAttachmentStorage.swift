import Foundation

package struct CloudAttachmentMetadataValue: Codable, Equatable, Sendable {
  package let attachmentID: UUID
  package let snipID: UUID
  package let position: Int
  package let fileName: String
  package let contentType: String?
  package let byteCount: Int64
  package let sha256: Data
  package let payloadIdentity: CloudTextStorageIdentity

  package init(
    attachmentID: UUID,
    snipID: UUID,
    position: Int,
    fileName: String,
    contentType: String?,
    byteCount: Int64,
    sha256: Data,
    payloadIdentity: CloudTextStorageIdentity
  ) {
    self.attachmentID = attachmentID
    self.snipID = snipID
    self.position = position
    self.fileName = fileName
    self.contentType = contentType
    self.byteCount = byteCount
    self.sha256 = sha256
    self.payloadIdentity = payloadIdentity
  }
}

package struct CloudAttachmentPublication: Equatable, Sendable {
  package let metadata: CloudAttachmentMetadataValue
  package let metadataIdentity: CloudTextStorageIdentity
  package let isLocallyPresent: Bool
  package let localSourceURL: URL?
  package let sourceURL: URL?
  package let payloadAccepted: Bool
  package let payloadShadowData: Data?
  package let metadataAccepted: Bool
  package let metadataShadowData: Data?
  package let priorPayloadIdentity: CloudTextStorageIdentity?
  package let priorPayloadShadowData: Data?
  package let lastFailure: CloudAttachmentFailure?
  package let revision: UInt64

  package init(
    metadata: CloudAttachmentMetadataValue,
    metadataIdentity: CloudTextStorageIdentity,
    isLocallyPresent: Bool = true,
    localSourceURL: URL? = nil,
    sourceURL: URL?,
    payloadAccepted: Bool,
    payloadShadowData: Data?,
    metadataAccepted: Bool,
    metadataShadowData: Data?,
    priorPayloadIdentity: CloudTextStorageIdentity? = nil,
    priorPayloadShadowData: Data? = nil,
    lastFailure: CloudAttachmentFailure? = nil,
    revision: UInt64
  ) {
    self.metadata = metadata
    self.metadataIdentity = metadataIdentity
    self.isLocallyPresent = isLocallyPresent
    self.localSourceURL = localSourceURL
    self.sourceURL = sourceURL
    self.payloadAccepted = payloadAccepted
    self.payloadShadowData = payloadShadowData
    self.metadataAccepted = metadataAccepted
    self.metadataShadowData = metadataShadowData
    self.priorPayloadIdentity = priorPayloadIdentity
    self.priorPayloadShadowData = priorPayloadShadowData
    self.lastFailure = lastFailure
    self.revision = revision
  }
}

package enum CloudAttachmentTransferState: Equatable, Sendable {
  case waitingForUpload
  case waitingForMetadata
  case available
  case waitingForDeletion
  case failed(CloudAttachmentFailure)
}

package enum CloudAttachmentFailure: String, Codable, Equatable, Sendable {
  case retryable
  case quotaExceeded
  case updateRequired
  case accessDenied
  case rejected
  case attachmentMissing
  case invalidRecord
  case zoneMissing
  case localStorage

  package var retriesAutomatically: Bool { self == .retryable }

  package var retriesManually: Bool {
    self != .updateRequired && self != .accessDenied
  }
}

package extension CloudAttachmentPublication {
  var transferState: CloudAttachmentTransferState {
    if let lastFailure { return .failed(lastFailure) }
    if !isLocallyPresent { return .waitingForDeletion }
    if localSourceURL == nil, metadataAccepted { return .available }
    if !payloadAccepted { return .waitingForUpload }
    if !metadataAccepted { return .waitingForMetadata }
    return .available
  }
}

package struct CloudAttachmentCleanup: Equatable, Sendable {
  package let identity: CloudTextStorageIdentity
  package let shadowData: Data?
  package let blockedByAttachmentID: UUID?
  package let lastFailure: CloudAttachmentFailure?
  package let revision: UInt64
}

package struct CloudAttachmentCacheEntry: Equatable, Sendable {
  package let attachmentID: UUID
  package let payloadIdentity: CloudTextStorageIdentity
  package let fileURL: URL
  package let byteCount: Int64
  package let lastAccessedAt: Date
}

package struct CloudAttachmentStorageSnapshot: Equatable, Sendable {
  package let publications: [CloudAttachmentPublication]
  package let cleanups: [CloudAttachmentCleanup]
  package let cacheEntries: [CloudAttachmentCacheEntry]
}

package enum CloudAttachmentStorageError: Error, Equatable, Sendable {
  case invalidPath
  case invalidMetadata
  case staleTransition
  case missingPublication
  case hashMismatch
  case sizeMismatch
  case missingPayload
}

package enum CloudAttachmentTransition: Codable, Equatable, Sendable {
  case remoteMetadataAccepted(
    metadata: CloudAttachmentMetadataValue,
    metadataIdentity: CloudTextStorageIdentity,
    shadowData: Data,
    systemFields: Data
  )
  case payloadAccepted(
    attachmentID: UUID,
    expectedRevision: UInt64,
    shadowData: Data,
    systemFields: Data
  )
  case metadataAccepted(
    attachmentID: UUID,
    expectedRevision: UInt64,
    shadowData: Data,
    systemFields: Data
  )
  case metadataConflict(
    attachmentID: UUID,
    expectedRevision: UInt64,
    shadowData: Data,
    systemFields: Data
  )
  case payloadCollision(
    attachmentID: UUID,
    expectedRevision: UInt64,
    replacementIdentity: CloudTextStorageIdentity
  )
  case metadataUnknown(
    attachmentID: UUID,
    expectedRevision: UInt64,
    replacementAttachmentID: UUID,
    replacementMetadataIdentity: CloudTextStorageIdentity
  )
  case operationFailed(
    attachmentID: UUID,
    expectedRevision: UInt64,
    failure: CloudAttachmentFailure
  )
  case metadataDeleteAccepted(attachmentID: UUID, expectedRevision: UInt64)
  case metadataDeleteConflict(
    attachmentID: UUID,
    expectedRevision: UInt64,
    shadowData: Data,
    systemFields: Data,
    payloadIdentity: CloudTextStorageIdentity
  )
  case remoteMetadataDeleted(metadataIdentity: CloudTextStorageIdentity)
  case cleanupAccepted(identity: CloudTextStorageIdentity, expectedRevision: UInt64)
  case cleanupConflict(
    identity: CloudTextStorageIdentity, expectedRevision: UInt64, shadowData: Data
  )
  case cleanupFailed(
    identity: CloudTextStorageIdentity,
    expectedRevision: UInt64,
    failure: CloudAttachmentFailure
  )
}
