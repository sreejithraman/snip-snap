import CryptoKit
import Foundation
import SnipSnapCore
import XCTest

@testable import SnipSnapPersistence

final class CloudAttachmentStorageTests: XCTestCase {
  func testPreparationPersistsOpaquePayloadIdentityBeforeUploadAndReusesItAfterReopen() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("hello attachment".utf8).write(to: source)
    let storeURL = root.appendingPathComponent("store")
    var library: SwiftDataSnipLibrary? = try SwiftDataSnipLibrary(storeURL: storeURL)
    _ = try await library?.perform(
      .add(
        content: "with file",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: Date(timeIntervalSince1970: 1)
      ),
      sortedBy: .manual
    )
    try await library?.reconcileCloudAttachments(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace-generation-a"),
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let firstSnapshot = try await library?.cloudAttachmentStorageSnapshot(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace-generation-a")
    )
    let first = try XCTUnwrap(firstSnapshot?.publications.first)
    XCTAssertFalse(first.payloadAccepted)
    XCTAssertNotNil(first.sourceURL)
    XCTAssertNotEqual(first.metadata.attachmentID.uuidString.lowercased(), first.metadata.payloadIdentity.recordName)
    let stagedURL = try XCTUnwrap(first.sourceURL)
    try Data(repeating: 0x78, count: Int(first.metadata.byteCount)).write(to: stagedURL)

    library = nil
    let reopened = try SwiftDataSnipLibrary(storeURL: storeURL)
    try await reopened.reconcileCloudAttachments(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace-generation-a"),
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let secondSnapshot = try await reopened.cloudAttachmentStorageSnapshot(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace-generation-a")
    )
    let second = try XCTUnwrap(secondSnapshot.publications.first)
    XCTAssertEqual(second.metadata.payloadIdentity, first.metadata.payloadIdentity)
    XCTAssertEqual(second.metadata.sha256, first.metadata.sha256)
    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(second.sourceURL)), Data("hello attachment".utf8))
  }

  func testNamespaceGenerationKeepsSeparatePayloadLedgers() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("hello".utf8).write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
      .add(
        content: "file",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ), sortedBy: .manual
    )
    for namespace in [
      CloudSyncNamespaceKey(rawValue: "generation-a"),
      CloudSyncNamespaceKey(rawValue: "generation-b"),
    ] {
      try await library.reconcileCloudAttachments(
        namespaceKey: namespace,
        metadataZoneName: "data",
        metadataOwnerName: "owner",
        payloadZoneName: "payload",
        payloadOwnerName: "owner"
      )
    }
    let a = try await library.cloudAttachmentStorageSnapshot(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "generation-a")
    )
    let b = try await library.cloudAttachmentStorageSnapshot(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "generation-b")
    )
    XCTAssertEqual(a.publications.map(\.metadata.attachmentID), b.publications.map(\.metadata.attachmentID))
    XCTAssertNotEqual(a.publications.first?.metadata.payloadIdentity, b.publications.first?.metadata.payloadIdentity)
  }

  func testDownloadedAttachmentMetadataEditRemainsPendingForUpload() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "remote file",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let attachmentID = UUID()
    let payloadIdentity = CloudTextStorageIdentity(
      zoneName: "payload", ownerName: "owner", recordName: UUID().uuidString.lowercased()
    )
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      transitions: [.remoteMetadataAccepted(
        metadata: CloudAttachmentMetadataValue(
          attachmentID: attachmentID,
          snipID: snipID,
          position: 0,
          fileName: "remote.txt",
          contentType: "text/plain",
          byteCount: 4,
          sha256: Data(repeating: 1, count: 32),
          payloadIdentity: payloadIdentity
        ),
        metadataIdentity: CloudTextStorageIdentity(
          zoneName: "data",
          ownerName: "owner",
          recordName: "a-\(attachmentID.uuidString.lowercased())"
        ),
        shadowData: Data("metadata-shadow".utf8),
        systemFields: Data("metadata-fields".utf8)
      )]
    )
    var local = try await library.checkedSnapshot(sortedBy: .manual).snips
    local[0].attachments[0].fileName = "renamed.txt"
    _ = try await library.perform(.replaceAll(local), sortedBy: .manual)

    try await library.reconcileCloudAttachments(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )

    let stored = try await library.cloudAttachmentStorageSnapshot(namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"))
    let publication = try XCTUnwrap(stored.publications.first)
    XCTAssertEqual(publication.metadata.fileName, "renamed.txt")
    XCTAssertFalse(publication.metadataAccepted)
    XCTAssertTrue(publication.payloadAccepted)
  }

  func testRemoteReplacementMovesThePublicationToTheNewPayloadIdentity() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let attachmentID = UUID()
    let metadataIdentity = CloudTextStorageIdentity(
      zoneName: "data",
      ownerName: "owner",
      recordName: "a-\(attachmentID.uuidString.lowercased())"
    )
    let firstPayload = CloudTextStorageIdentity(
      zoneName: "payload", ownerName: "owner", recordName: UUID().uuidString.lowercased()
    )
    let secondPayload = CloudTextStorageIdentity(
      zoneName: "payload", ownerName: "owner", recordName: UUID().uuidString.lowercased()
    )
    func metadata(_ payload: CloudTextStorageIdentity, hashByte: UInt8) -> CloudAttachmentMetadataValue {
      CloudAttachmentMetadataValue(
        attachmentID: attachmentID,
        snipID: UUID(),
        position: 0,
        fileName: "remote.txt",
        contentType: "text/plain",
        byteCount: 4,
        sha256: Data(repeating: hashByte, count: 32),
        payloadIdentity: payload
      )
    }
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      transitions: [.remoteMetadataAccepted(
        metadata: metadata(firstPayload, hashByte: 1),
        metadataIdentity: metadataIdentity,
        shadowData: Data("shadow-1".utf8),
        systemFields: Data("fields-1".utf8)
      )]
    )
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      transitions: [.remoteMetadataAccepted(
        metadata: metadata(secondPayload, hashByte: 2),
        metadataIdentity: metadataIdentity,
        shadowData: Data("shadow-2".utf8),
        systemFields: Data("fields-2".utf8)
      )]
    )

    let stored = try await library.cloudAttachmentStorageSnapshot(namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"))
    XCTAssertEqual(stored.publications.first?.metadata.payloadIdentity, secondPayload)
    XCTAssertEqual(stored.publications.first?.metadata.sha256, Data(repeating: 2, count: 32))
  }

  func testReconcileSweepsUntrackedUploadDirectoriesAndKeepsDurableQueuedPayload() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("queued".utf8).write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
      .add(
        content: "queued upload",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    try await library.reconcileCloudAttachments(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let initial = try await library.cloudAttachmentStorageSnapshot(namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"))
    let queued = try XCTUnwrap(initial.publications.first?.sourceURL)
    let uploadRoot = queued.deletingLastPathComponent().deletingLastPathComponent()
    let orphan = uploadRoot.appendingPathComponent("orphan/payload")
    try FileManager.default.createDirectory(
      at: orphan.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("left after a crash".utf8).write(to: orphan)

    try await library.reconcileCloudAttachments(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: queued.path))
  }

  func testReplacementRemovesSupersededUploadDirectory() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("first".utf8).write(to: source)
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    _ = try await library.perform(
      .add(
        content: "replace upload",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [source],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    try await library.reconcileCloudAttachments(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let initial = try await library.cloudAttachmentStorageSnapshot(namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"))
    let publication = try XCTUnwrap(initial.publications.first)
    let oldUpload = try XCTUnwrap(publication.sourceURL)
    let localSource = try XCTUnwrap(publication.localSourceURL)
    try Data("replacement".utf8).write(to: localSource)

    try await library.reconcileCloudAttachments(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: oldUpload.path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: oldUpload.deletingLastPathComponent().path
    ))
  }

  func testFetchedMetadataDeletionQueuesItsPayloadForCleanup() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let attachmentID = UUID()
    let metadataIdentity = CloudTextStorageIdentity(
      zoneName: "data",
      ownerName: "owner",
      recordName: "a-\(attachmentID.uuidString.lowercased())"
    )
    let payloadIdentity = CloudTextStorageIdentity(
      zoneName: "payload",
      ownerName: "owner",
      recordName: UUID().uuidString.lowercased()
    )
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      transitions: [.remoteMetadataAccepted(
        metadata: CloudAttachmentMetadataValue(
          attachmentID: attachmentID,
          snipID: UUID(),
          position: 0,
          fileName: "remote.txt",
          contentType: "text/plain",
          byteCount: 4,
          sha256: Data(repeating: 1, count: 32),
          payloadIdentity: payloadIdentity
        ),
        metadataIdentity: metadataIdentity,
        shadowData: Data("metadata-shadow".utf8),
        systemFields: Data("metadata-fields".utf8)
      )]
    )

    try await library.commitCloudAttachmentTransitions(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      transitions: [.remoteMetadataDeleted(metadataIdentity: metadataIdentity)]
    )

    let stored = try await library.cloudAttachmentStorageSnapshot(namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"))
    XCTAssertTrue(stored.publications.isEmpty)
    XCTAssertEqual(stored.cleanups.map(\.identity), [payloadIdentity])
  }

  func testDeleteConflictAdoptsServerReplacementPayloadBeforeCleanup() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let attachmentID = UUID()
    let metadataIdentity = CloudTextStorageIdentity(
      zoneName: "data", ownerName: "owner",
      recordName: "a-\(attachmentID.uuidString.lowercased())"
    )
    let oldPayload = CloudTextStorageIdentity(
      zoneName: "payload", ownerName: "owner", recordName: "old-payload"
    )
    let replacementPayload = CloudTextStorageIdentity(
      zoneName: "payload", ownerName: "owner", recordName: "replacement-payload"
    )
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      transitions: [.remoteMetadataAccepted(
        metadata: CloudAttachmentMetadataValue(
          attachmentID: attachmentID,
          snipID: UUID(),
          position: 0,
          fileName: "remote.txt",
          contentType: "text/plain",
          byteCount: 4,
          sha256: Data(repeating: 1, count: 32),
          payloadIdentity: oldPayload
        ),
        metadataIdentity: metadataIdentity,
        shadowData: Data("old-shadow".utf8),
        systemFields: Data("old-fields".utf8)
      )]
    )
    try await library.reconcileCloudAttachments(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      metadataZoneName: "data",
      metadataOwnerName: "owner",
      payloadZoneName: "payload",
      payloadOwnerName: "owner"
    )
    let deletingSnapshot = try await library.cloudAttachmentStorageSnapshot(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace")
    )
    let deleting = try XCTUnwrap(deletingSnapshot.publications.first)
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      transitions: [.metadataDeleteConflict(
        attachmentID: attachmentID,
        expectedRevision: deleting.revision,
        shadowData: Data("replacement-shadow".utf8),
        systemFields: Data("replacement-fields".utf8),
        payloadIdentity: replacementPayload
      )]
    )
    let conflictedSnapshot = try await library.cloudAttachmentStorageSnapshot(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace")
    )
    let conflicted = try XCTUnwrap(conflictedSnapshot.publications.first)
    XCTAssertEqual(conflicted.metadata.payloadIdentity, replacementPayload)

    try await library.commitCloudAttachmentTransitions(
      namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"),
      transitions: [.metadataDeleteAccepted(
        attachmentID: attachmentID,
        expectedRevision: conflicted.revision
      )]
    )
    let cleaned = try await library.cloudAttachmentStorageSnapshot(namespaceKey: CloudSyncNamespaceKey(rawValue: "namespace"))
    XCTAssertEqual(Set(cleaned.cleanups.map(\.identity)), Set([oldPayload, replacementPayload]))
  }

  func testEncryptedResetKeepsDownloadedBytesAndClearsOldCloudState() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("store"))
    let added = try await library.perform(
      .add(
        content: "remote attachment",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: [],
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    guard case .add(.added(let snipID)) = added.outcome else {
      return XCTFail("Expected a saved snip")
    }
    let namespace = CloudSyncNamespaceKey(rawValue: "reset-namespace")
    let attachmentID = UUID()
    let payload = CloudTextStorageIdentity(
      zoneName: "payload", ownerName: "owner", recordName: UUID().uuidString.lowercased()
    )
    let bytes = Data("downloaded before reset".utf8)
    let metadata = CloudAttachmentMetadataValue(
      attachmentID: attachmentID,
      snipID: snipID,
      position: 0,
      fileName: "kept.txt",
      contentType: "text/plain",
      byteCount: Int64(bytes.count),
      sha256: Data(SHA256.hash(data: bytes)),
      payloadIdentity: payload
    )
    try await library.commitCloudAttachmentTransitions(
      namespaceKey: namespace,
      transitions: [.remoteMetadataAccepted(
        metadata: metadata,
        metadataIdentity: CloudTextStorageIdentity(
          zoneName: "data", ownerName: "owner", recordName: "a-\(attachmentID)"
        ),
        shadowData: Data("shadow".utf8),
        systemFields: Data("fields".utf8)
      )]
    )
    let stagingRoot = try await library.cloudAttachmentStagingRoot(namespaceKey: namespace)
    let staged = stagingRoot.appendingPathComponent("download/payload")
    try FileManager.default.createDirectory(
      at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try bytes.write(to: staged)
    let cached = try await library.installCloudAttachmentCacheFile(
      namespaceKey: namespace,
      attachmentID: attachmentID,
      expectedPayloadIdentity: payload,
      stagedURL: staged,
      expectedByteCount: Int64(bytes.count),
      expectedSHA256: Data(SHA256.hash(data: bytes)),
      maximumBytes: 1_024,
      now: .distantPast
    )
    XCTAssertTrue(cached.path.contains("CloudDownloads"))

    try await library.quarantineCloudNamespaceState(namespaceKey: namespace)

    let snapshot = await library.snapshot(sortedBy: .manual)
    let keptURL = try XCTUnwrap(snapshot.attachmentURLs[attachmentID])
    let cloudState = try await library.cloudAttachmentStorageSnapshot(namespaceKey: namespace)
    XCTAssertFalse(keptURL.path.contains("CloudDownloads"))
    XCTAssertEqual(try Data(contentsOf: keptURL), bytes)
    XCTAssertTrue(cloudState.publications.isEmpty)
    XCTAssertTrue(cloudState.cleanups.isEmpty)
    XCTAssertTrue(cloudState.cacheEntries.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudAttachmentStorageTests-\(UUID().uuidString)", isDirectory: true)
  }
}
