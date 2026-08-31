import CryptoKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence

public enum SnipSnapCloudAttachmentLimits {
  public static let maximumFileBytes: Int64 = 25 * 1_048_576
  public static let maximumAttachmentBytesPerSnip: Int64 = 100 * 1_048_576
}

package struct CloudAttachmentCompatibilityPolicy: Equatable, Sendable {
  package let maximumFileBytes: Int64?
  package let maximumAttachmentBytesPerSnip: Int64?
  package let supportedContentTypes: Set<String>?

  package init(
    maximumFileBytes: Int64? = nil,
    maximumAttachmentBytesPerSnip: Int64? = nil,
    supportedContentTypes: Set<String>? = nil
  ) {
    precondition(maximumFileBytes.map { $0 >= 0 } ?? true)
    precondition(maximumAttachmentBytesPerSnip.map { $0 >= 0 } ?? true)
    self.maximumFileBytes = maximumFileBytes
    self.maximumAttachmentBytesPerSnip = maximumAttachmentBytesPerSnip
    self.supportedContentTypes = supportedContentTypes
  }

  package static let openSourceDefault = CloudAttachmentCompatibilityPolicy(
    maximumFileBytes: SnipSnapCloudAttachmentLimits.maximumFileBytes,
    maximumAttachmentBytesPerSnip:
      SnipSnapCloudAttachmentLimits.maximumAttachmentBytesPerSnip
  )
}

package enum CloudAttachmentUnsupportedReason: Equatable, Sendable {
  case fileTooLarge(maximumBytes: Int64)
  case snipTotalTooLarge(maximumBytes: Int64)
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

extension CloudAttachmentSetupError: LocalizedError {
  package var errorDescription: String? {
    switch self {
    case .unsupportedFiles(let files):
      let details = files.map { file in
        String(localized: LocalizedStringResource.attachmentErrorDetail(file.fileName, file.reason.errorDescription))
      }.joined(separator: "; ")
      return String(localized: LocalizedStringResource.theseAttachmentsCannotSync(details))
    }
  }
}

private extension CloudAttachmentUnsupportedReason {
  var errorDescription: String {
    switch self {
    case .fileTooLarge(let maximumBytes):
      String(localized: LocalizedStringResource.largerThanSnipSnapsPerFileLimit(formatSnipSnapByteLimit(maximumBytes)))
    case .snipTotalTooLarge(let maximumBytes):
      String(localized: LocalizedStringResource.partOfASnipAboveSnipSnapsAttachmentLimit(formatSnipSnapByteLimit(maximumBytes)))
    case .contentType(let value):
      String(localized: LocalizedStringResource.unsupportedFileType(value ?? String(localized: LocalizedStringResource.unknown)))
    case .missingLocalFile:
      String(localized: LocalizedStringResource.localFileIsMissingOrChanged)
    }
  }
}

private func formatSnipSnapByteLimit(_ byteCount: Int64) -> String {
  let mib: Int64 = 1_048_576
  if byteCount.isMultiple(of: mib) {
    return String(localized: LocalizedStringResource.miB(Int(byteCount / mib)))
  }
  return String(localized: LocalizedStringResource.bytes(Int(byteCount)))
}

package enum CloudAttachmentUse: Equatable, Sendable {
  case preview
  case open
  case copy
  case export
}

package protocol CloudAttachmentTransferring: Sendable {
  func prepare(attachmentID: UUID, for use: CloudAttachmentUse) async throws -> URL
  func clearDownloads() async throws
  func transferStates() async throws -> [UUID: CloudAttachmentTransferState]
}

package actor CloudAttachmentTransferCoordinator: CloudAttachmentTransferring {
  private let library: SwiftDataSnipLibrary
  private let namespaceKey: String
  private let payloadZone: CloudZoneID
  private let transport: any CloudRecordTransport
  private let maximumCacheBytes: Int64
  private let now: @Sendable () -> Date
  private var didSweepCache = false

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
    if !didSweepCache {
      didSweepCache = true
      do {
        try await library.sweepCloudAttachmentCache(
          namespaceKey: namespaceKey,
          maximumBytes: maximumCacheBytes
        )
      } catch {
        didSweepCache = false
        throw error
      }
    }
    return try await library.touchCloudAttachmentCache(
      namespaceKey: namespaceKey,
      attachmentID: attachmentID,
      now: now()
    )
  }

  package func download(attachmentID: UUID) async throws -> URL {
    if let cached = try await downloadedURL(attachmentID: attachmentID) { return cached }
    let snapshot = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespaceKey)
    guard let publication = snapshot.publications.first(where: {
      $0.metadata.attachmentID == attachmentID && $0.isLocallyPresent
    }) else { throw CloudAttachmentStorageError.missingPublication }
    if let local = publication.localSourceURL {
      do {
        let values = try local.resourceValues(
          forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          Int64(values.fileSize ?? -1) == publication.metadata.byteCount
        else { throw CloudAttachmentStorageError.sizeMismatch }
        guard try Self.sha256(of: local) == publication.metadata.sha256 else {
          throw CloudAttachmentStorageError.hashMismatch
        }
        return local
      } catch {
        guard !FileManager.default.fileExists(atPath: local.path), publication.metadataAccepted
        else { throw error }
      }
    }
    guard publication.metadataAccepted else {
      throw CloudAttachmentStorageError.missingPublication
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
    else {
      Self.removeStagedFileIfSafe(receipt.fileURL, stagingRoot: stagingRoot)
      throw CloudAttachmentStorageError.invalidMetadata
    }
    do {
      return try await library.installCloudAttachmentCacheFile(
        namespaceKey: namespaceKey,
        attachmentID: attachmentID,
        expectedPayloadIdentity: publication.metadata.payloadIdentity,
        stagedURL: receipt.fileURL,
        expectedByteCount: publication.metadata.byteCount,
        expectedSHA256: publication.metadata.sha256,
        maximumBytes: maximumCacheBytes,
        now: now()
      )
    } catch {
      Self.removeStagedFileIfSafe(receipt.fileURL, stagingRoot: stagingRoot)
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
    return Self.unsupportedFiles(in: snapshot, policy: policy)
  }

  package static func unsupportedFiles(
    in snapshot: CloudAttachmentStorageSnapshot,
    policy: CloudAttachmentCompatibilityPolicy
  ) -> [CloudUnsupportedAttachment] {
    let inputs: [CompatibilityInput] = snapshot.publications.compactMap { publication in
      guard publication.isLocallyPresent else { return nil }
      return CompatibilityInput(
        attachmentID: publication.metadata.attachmentID,
        snipID: publication.metadata.snipID,
        fileName: publication.metadata.fileName,
        contentType: publication.metadata.contentType,
        byteCount: publication.metadata.byteCount,
        localURL: publication.localSourceURL,
        allowsMissingLocalFile: publication.metadataAccepted
      )
    }
    return unsupportedFiles(in: inputs, policy: policy)
  }

  package static func unsupportedFiles(
    in snapshot: SnipLibrarySnapshot,
    policy: CloudAttachmentCompatibilityPolicy
  ) -> [CloudUnsupportedAttachment] {
    let inputs = snapshot.snips.flatMap { snip in
      snip.attachments.map { attachment in
        CompatibilityInput(
          attachmentID: attachment.id,
          snipID: snip.id,
          fileName: attachment.fileName,
          contentType: attachment.contentType,
          byteCount: attachment.byteCount,
          localURL: snapshot.attachmentURLs[attachment.id],
          allowsMissingLocalFile: false
        )
      }
    }
    return unsupportedFiles(in: inputs, policy: policy)
  }

  private struct CompatibilityInput {
    let attachmentID: UUID
    let snipID: UUID
    let fileName: String
    let contentType: String?
    let byteCount: Int64
    let localURL: URL?
    let allowsMissingLocalFile: Bool
  }

  private static func unsupportedFiles(
    in inputs: [CompatibilityInput],
    policy: CloudAttachmentCompatibilityPolicy
  ) -> [CloudUnsupportedAttachment] {
    let oversizedSnipIDs = oversizedSnipIDs(
      inputs.map { ($0.snipID, $0.byteCount) },
      maximum: policy.maximumAttachmentBytesPerSnip
    )
    return inputs.compactMap { input in
      if input.localURL == nil, input.allowsMissingLocalFile { return nil }
      guard let localURL = input.localURL else {
        return CloudUnsupportedAttachment(
          attachmentID: input.attachmentID,
          fileName: input.fileName,
          reason: .missingLocalFile
        )
      }
      let values = try? localURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values?.isRegularFile == true, Int64(values?.fileSize ?? -1) == input.byteCount else {
        return CloudUnsupportedAttachment(
          attachmentID: input.attachmentID,
          fileName: input.fileName,
          reason: .missingLocalFile
        )
      }
      if let maximum = policy.maximumFileBytes, input.byteCount > maximum {
        return CloudUnsupportedAttachment(
          attachmentID: input.attachmentID,
          fileName: input.fileName,
          reason: .fileTooLarge(maximumBytes: maximum)
        )
      }
      if let maximum = policy.maximumAttachmentBytesPerSnip,
        oversizedSnipIDs.contains(input.snipID)
      {
        return CloudUnsupportedAttachment(
          attachmentID: input.attachmentID,
          fileName: input.fileName,
          reason: .snipTotalTooLarge(maximumBytes: maximum)
        )
      }
      if let supported = policy.supportedContentTypes,
        input.contentType.map(supported.contains) != true
      {
        return CloudUnsupportedAttachment(
          attachmentID: input.attachmentID,
          fileName: input.fileName,
          reason: .contentType(input.contentType)
        )
      }
      return nil
    }.sorted {
      ($0.fileName, $0.attachmentID.uuidString) < ($1.fileName, $1.attachmentID.uuidString)
    }
  }

  private static func oversizedSnipIDs(
    _ values: [(snipID: UUID, byteCount: Int64)],
    maximum: Int64?
  ) -> Set<UUID> {
    guard let maximum else { return [] }
    return Set(Dictionary(grouping: values, by: \.snipID).compactMap { snipID, values in
      totalExceeds(values.map(\.byteCount), maximum: maximum) ? snipID : nil
    })
  }

  private static func totalExceeds(_ byteCounts: [Int64], maximum: Int64) -> Bool {
    var remaining = maximum
    for byteCount in byteCounts {
      guard byteCount >= 0, byteCount <= remaining else { return true }
      remaining -= byteCount
    }
    return false
  }

  private static func sha256(of url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return Data(hasher.finalize())
  }

  private static func removeStagedFileIfSafe(_ fileURL: URL, stagingRoot: URL) {
    let root = stagingRoot.standardizedFileURL
    let file = fileURL.standardizedFileURL
    guard root.isFileURL, file.isFileURL, file != root,
      file.path.hasPrefix(root.path + "/")
    else { return }
    var current = file
    while current != root {
      guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
        values.isSymbolicLink != true
      else { return }
      let parent = current.deletingLastPathComponent()
      guard parent != current else { return }
      current = parent
    }
    try? FileManager.default.removeItem(at: file)
  }
}
