import Foundation
import SnipSnapCore
import SnipSnapPersistence

package struct CloudAttachmentCompatibilityPolicy: Equatable, Sendable {
  package let maximumFileBytes: Int64?
  package let supportedContentTypes: Set<String>?

  package init(
    maximumFileBytes: Int64? = nil,
    supportedContentTypes: Set<String>? = nil
  ) {
    self.maximumFileBytes = maximumFileBytes
    self.supportedContentTypes = supportedContentTypes
  }

  package static let openSourceDefault = CloudAttachmentCompatibilityPolicy()
}

package enum CloudAttachmentUnsupportedReason: Equatable, Sendable {
  case fileTooLarge(maximumBytes: Int64)
  case contentType(String?)
  case missingLocalFile
}

package struct CloudUnsupportedAttachment: Equatable, Sendable {
  package let attachmentID: UUID
  package let fileName: String
  package let reason: CloudAttachmentUnsupportedReason
}

package enum CloudAttachmentSetupError: Error, Equatable, Sendable {
  case unsupportedFiles([CloudUnsupportedAttachment])
}

package enum CloudAttachmentUse: Equatable, Sendable {
  case preview
  case open
  case copy
  case export
}

package actor CloudAttachmentTransferCoordinator {
  private let library: SwiftDataSnipLibrary
  private let namespaceKey: String
  private let payloadZone: CloudZoneID
  private let transport: any CloudRecordTransport
  private let maximumCacheBytes: Int64
  private let now: @Sendable () -> Date

  package init(
    library: SwiftDataSnipLibrary,
    namespace: CloudSyncNamespace,
    payloadZone: CloudZoneID,
    transport: any CloudRecordTransport,
    maximumCacheBytes: Int64,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    precondition(maximumCacheBytes >= 0)
    precondition(namespace.zones.contains(payloadZone))
    self.library = library
    namespaceKey = namespace.canonicalKey
    self.payloadZone = payloadZone
    self.transport = transport
    self.maximumCacheBytes = maximumCacheBytes
    self.now = now
  }

  package func downloadedURL(attachmentID: UUID) async throws -> URL? {
    try await library.touchCloudAttachmentCache(
      namespaceKey: namespaceKey,
      attachmentID: attachmentID,
      now: now()
    )
  }

  package func download(attachmentID: UUID) async throws -> URL {
    if let cached = try await downloadedURL(attachmentID: attachmentID) { return cached }
    let snapshot = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
    guard let publication = snapshot.publications.first(where: {
      $0.metadata.attachmentID == attachmentID && $0.metadataAccepted && $0.isLocallyPresent
    }) else { throw CloudAttachmentStorageError.missingPublication }
    if let local = publication.localSourceURL,
      FileManager.default.fileExists(atPath: local.path)
    {
      return local
    }
    guard publication.metadata.payloadIdentity.zoneName == payloadZone.name,
      publication.metadata.payloadIdentity.ownerName == payloadZone.ownerName
    else { throw CloudAttachmentStorageError.invalidMetadata }
    let stagingRoot = try await library.cloudAttachmentStagingRoot(namespaceKey: namespaceKey)
    let destination = try CloudAssetDestination(validating: stagingRoot)
    let recordID = CloudAttachmentRecordCodec.recordID(publication.metadata.payloadIdentity)
    guard let receipt = try await transport.fetchAsset(
      recordID,
      field: CloudAttachmentRecordCodec.assetField,
      destination: destination
    ) else { throw CloudAttachmentStorageError.missingPayload }
    guard receipt.recordID == recordID,
      receipt.field == CloudAttachmentRecordCodec.assetField
    else { throw CloudAttachmentStorageError.invalidMetadata }
    do {
      return try await library.installCloudAttachmentCacheFile(
        namespaceKey: namespaceKey,
        attachmentID: attachmentID,
        stagedURL: receipt.fileURL,
        expectedByteCount: publication.metadata.byteCount,
        expectedSHA256: publication.metadata.sha256,
        maximumBytes: maximumCacheBytes,
        now: now()
      )
    } catch {
      try? FileManager.default.removeItem(at: receipt.fileURL)
      throw error
    }
  }

  /// All attachment actions use one verified local file, whether it was saved here or downloaded.
  package func prepare(attachmentID: UUID, for use: CloudAttachmentUse) async throws -> URL {
    _ = use
    return try await download(attachmentID: attachmentID)
  }

  package func clearDownloads() async throws {
    try await library.clearCloudAttachmentCache(namespaceKey: namespaceKey)
  }

  package func transferStates() async throws -> [UUID: CloudAttachmentTransferState] {
    let snapshot = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
    return Dictionary(uniqueKeysWithValues: snapshot.publications.map {
      ($0.metadata.attachmentID, $0.transferState)
    })
  }

  package func unsupportedFiles(
    policy: CloudAttachmentCompatibilityPolicy
  ) async throws -> [CloudUnsupportedAttachment] {
    let snapshot = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
    return snapshot.publications.compactMap { publication in
      guard publication.isLocallyPresent else { return nil }
      guard let localURL = publication.localSourceURL else {
        return publication.metadataAccepted ? nil : CloudUnsupportedAttachment(
          attachmentID: publication.metadata.attachmentID,
          fileName: publication.metadata.fileName,
          reason: .missingLocalFile
        )
      }
      let values = try? localURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values?.isRegularFile == true,
        Int64(values?.fileSize ?? -1) == publication.metadata.byteCount
      else {
        return CloudUnsupportedAttachment(
          attachmentID: publication.metadata.attachmentID,
          fileName: publication.metadata.fileName,
          reason: .missingLocalFile
        )
      }
      if let maximum = policy.maximumFileBytes,
        publication.metadata.byteCount > maximum
      {
        return CloudUnsupportedAttachment(
          attachmentID: publication.metadata.attachmentID,
          fileName: publication.metadata.fileName,
          reason: .fileTooLarge(maximumBytes: maximum)
        )
      }
      if let supported = policy.supportedContentTypes,
        publication.metadata.contentType.map(supported.contains) != true
      {
        return CloudUnsupportedAttachment(
          attachmentID: publication.metadata.attachmentID,
          fileName: publication.metadata.fileName,
          reason: .contentType(publication.metadata.contentType)
        )
      }
      return nil
    }.sorted {
      ($0.fileName, $0.attachmentID.uuidString) < ($1.fileName, $1.attachmentID.uuidString)
    }
  }


  package static func unsupportedFiles(
    in snapshot: SnipLibrarySnapshot,
    policy: CloudAttachmentCompatibilityPolicy
  ) -> [CloudUnsupportedAttachment] {
    snapshot.snips.flatMap(\.attachments).compactMap { attachment in
      guard let url = snapshot.attachmentURLs[attachment.id] else {
        return CloudUnsupportedAttachment(
          attachmentID: attachment.id,
          fileName: attachment.fileName,
          reason: .missingLocalFile
        )
      }
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values?.isRegularFile == true,
        Int64(values?.fileSize ?? -1) == attachment.byteCount
      else {
        return CloudUnsupportedAttachment(
          attachmentID: attachment.id,
          fileName: attachment.fileName,
          reason: .missingLocalFile
        )
      }
      if let maximum = policy.maximumFileBytes, attachment.byteCount > maximum {
        return CloudUnsupportedAttachment(
          attachmentID: attachment.id,
          fileName: attachment.fileName,
          reason: .fileTooLarge(maximumBytes: maximum)
        )
      }
      if let supported = policy.supportedContentTypes,
        attachment.contentType.map(supported.contains) != true
      {
        return CloudUnsupportedAttachment(
          attachmentID: attachment.id,
          fileName: attachment.fileName,
          reason: .contentType(attachment.contentType)
        )
      }
      return nil
    }.sorted {
      ($0.fileName, $0.attachmentID.uuidString) < ($1.fileName, $1.attachmentID.uuidString)
    }
  }
}
